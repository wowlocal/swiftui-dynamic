/// Opt-in copy operation for opaque host carriers that represent a Swift
/// value type. Ordinary host classes retain identity; bridge boxes for SDK
/// structs adopt this protocol so every interpreter storage boundary gives
/// them the same copy-in/copy-out ownership as their native value.
@MainActor
public protocol HostValueSemantic {
    func copiedHostValue() -> Any
}

/// Opt-in equality for opaque values owned by a host bridge.
///
/// The interpreter cannot safely infer `Equatable` conformance after a value
/// has crossed an `Any` boundary. Bridges that preserve that type information
/// can expose concrete equality here, including resolution of a contextual
/// enum spelling such as `.completed`. Returning nil leaves the comparison to
/// the interpreter's ordinary identity and value rules.
@MainActor
public protocol HostRuntimeEquatable {
    func runtimeEquals(_ other: Any) -> Bool?
    func runtimeEquals(implicitMemberNamed name: String) -> Bool?
}

public extension HostRuntimeEquatable {
    func runtimeEquals(implicitMemberNamed name: String) -> Bool? { nil }
}

/// Central ownership rules for values crossing a Swift storage boundary.
///
/// `Instance` is an implementation detail shared by interpreted structs and
/// classes. The source declaration decides its semantics: struct storage
/// envelopes copy while classes and opaque host objects retain identity.
/// Native containers keep their Swift COW storage; composed lvalues detach
/// only the nested source-struct path that is actually mutated. Keeping this
/// policy here lets every boundary agree on one value model.
extension RuntimeValue {
    public var hasSourceValueSemantics: Bool {
        switch self {
        case .instance(let instance):
            return !instance.symbol.isClass
        case .array, .set, .dictionary, .tuple, .range, .enumCase, .optional:
            return true
        default:
            return false
        }
    }

    /// Produce the independent value that native Swift would place in a new
    /// variable, parameter, return slot, stored property, or container slot.
    /// Container payloads remain shallow until mutation, like Swift COW;
    /// source-struct envelopes get new boxes. Closures and reference-bearing
    /// values deliberately retain identity.
    public func copiedForValueSemantics() -> RuntimeValue {
        switch self {
        case .array, .set, .tuple, .dictionary, .range:
            // These cases are Swift value types already. Nested source
            // structs detach through composed member/subscript lvalues when
            // mutation reaches them; walking the whole graph here would turn
            // repeated list updates quadratic.
            return self
        case .optional(let optional):
            return .optional(
                optional.wrapped?.copiedForValueSemantics(),
                wrappedTypeName: optional.wrappedTypeName,
                isImplicitlyUnwrapped: optional.isImplicitlyUnwrapped)
        case .instance(let instance):
            guard !instance.symbol.isClass else { return self }
            return .instance(instance.copiedForValueSemantics())
        case .enumCase:
            // EnumCaseValue is immutable. Associated values copy when a
            // pattern binds them or a mutating method replaces the case.
            return self
        case .host(let any):
            // Compatibility for embedders that still put core containers in
            // `.host`. Interpreter-owned values use the dedicated cases.
            if let array = any as? [RuntimeValue] {
                return .array(array)
            }
            if let tuple = any as? TupleValue {
                return .tuple(tuple)
            }
            if let dictionary = any as? DictValue {
                return .dictionary(dictionary)
            }
            if let value = any as? HostValueSemantic {
                return .native(value.copiedHostValue())
            }
            return self
        default:
            return self
        }
    }

    /// Produce a fully isolated value graph for an escaping host boundary
    /// that may mutate stored values without going through interpreter
    /// lvalues. Most language storage uses the shallow/COW operation above;
    /// snapshot-style bridges such as `CurrentValueSubject` need this
    /// stronger copy-in/copy-out contract.
    public func deeplyCopiedForValueSemantics() -> RuntimeValue {
        var structCopies: [ObjectIdentifier: Instance] = [:]

        func copy(_ value: RuntimeValue) -> RuntimeValue {
            switch value {
            case .array(let array):
                return .array(array.map(copy))
            case .set(let set):
                return .set(RuntimeSetValue(
                    uniqueElements: set.elements.map(copy),
                    elementTypeName: set.elementTypeName))
            case .tuple(let tuple):
                return .tuple(TupleValue(
                    labels: tuple.labels, values: tuple.values.map(copy)))
            case .dictionary(let dictionary):
                return .dictionary(DictValue(
                    keys: dictionary.keys.map(copy),
                    values: dictionary.values.map(copy)))
            case .range(let range):
                return .range(RuntimeRangeValue(
                    lowerBound: range.lowerBound.map(copy),
                    upperBound: range.upperBound.map(copy),
                    includesUpperBound: range.includesUpperBound))
            case .enumCase(let caseValue):
                guard !caseValue.associated.isEmpty else { return value }
                return .enumCase(EnumCaseValue(
                    symbol: caseValue.symbol, name: caseValue.name,
                    associated: caseValue.associated.map(copy)))
            case .optional(let optional):
                return .optional(
                    optional.wrapped.map(copy),
                    wrappedTypeName: optional.wrappedTypeName,
                    isImplicitlyUnwrapped: optional.isImplicitlyUnwrapped)
            case .instance(let instance):
                guard !instance.symbol.isClass else { return value }
                let identity = ObjectIdentifier(instance)
                if let existing = structCopies[identity] {
                    return .instance(existing)
                }
                let isolated = Instance(
                    symbol: instance.symbol,
                    lifecycleOwner: nil,
                    programState: instance.programState)
                isolated.isInitializing = instance.isInitializing
                isolated.synthesizedRootOwners = instance.synthesizedRootOwners
                isolated.constructionViewIdentityPath = instance.constructionViewIdentityPath
                structCopies[identity] = isolated
                for (name, box) in instance.properties {
                    if instance.symbol.storedProperty(named: name)?.wrapper == .binding {
                        isolated.properties[name] = box
                    } else {
                        isolated.properties[name] = Box(copy(box.value))
                    }
                }
                for (name, box) in instance.stateBoxes {
                    isolated.stateBoxes[name] = box
                }
                return .instance(isolated)
            case .host(let any):
                // Compatibility for embedders still carrying core values in
                // `.host`; opaque host objects remain references.
                if let array = any as? [RuntimeValue] {
                    return .array(array.map(copy))
                }
                if let set = any as? RuntimeSetValue {
                    return .set(RuntimeSetValue(
                        uniqueElements: set.elements.map(copy),
                        elementTypeName: set.elementTypeName))
                }
                if let tuple = any as? TupleValue {
                    return .tuple(TupleValue(
                        labels: tuple.labels, values: tuple.values.map(copy)))
                }
                if let dictionary = any as? DictValue {
                    return .dictionary(DictValue(
                        keys: dictionary.keys.map(copy),
                        values: dictionary.values.map(copy)))
                }
                if let value = any as? HostValueSemantic {
                    return .native(value.copiedHostValue())
                }
                return value
            default:
                return value
            }
        }

        return copy(self)
    }
}

extension Instance {
    /// Clone an interpreted struct's ordinary storage. Property-wrapper
    /// locations are reference-bearing by design: @State/@StateObject boxes
    /// represent external SwiftUI storage and @Binding aliases its source.
    /// Copies therefore share those locations while ordinary fields get new
    /// boxes. Nested payloads detach lazily along their composed lvalue path.
    func copiedForValueSemantics() -> Instance {
        precondition(!symbol.isClass, "class instances must retain identity")
        let copy = Instance(
            symbol: symbol,
            lifecycleOwner: nil,
            programState: programState)
        copy.isInitializing = isInitializing
        copy.synthesizedRootOwners = synthesizedRootOwners
        copy.constructionViewIdentityPath = constructionViewIdentityPath
        copy.retainedStateProperties = retainedStateProperties
        for (name, box) in properties {
            if symbol.storedProperty(named: name)?.wrapper == .binding {
                copy.properties[name] = box
            } else {
                copy.properties[name] = Box(box.value)
            }
        }
        for (name, box) in stateBoxes {
            copy.stateBoxes[name] = box
        }
        return copy
    }
}
