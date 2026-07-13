import CoreGraphics
import Foundation
import SwiftInterpreter

/// A platform value whose API contract came from BridgeGen's AppKit/UIKit
/// symbol-graph sweep. On the framework's native platform `payload` is the
/// real SDK value. On the opposite platform it is nil and the same generated
/// contract supplies deterministic, typed inert behavior.
final class GeneratedPlatformValue: InertCallable, HostValueSemantic,
    CustomStringConvertible
{
    let framework: String
    let typeName: String
    let isValueType: Bool
    var payload: Any?
    var config: [String: RuntimeValue]

    init(
        framework: String,
        typeName: String,
        isValueType: Bool,
        payload: Any?,
        config: [String: RuntimeValue] = [:]
    ) {
        self.framework = framework
        self.typeName = typeName
        self.isValueType = isValueType
        self.payload = payload
        self.config = config
    }

    var description: String {
        payload.map(String.init(describing:)) ?? "<\(framework).\(typeName) stub>"
    }

    func copiedHostValue() -> Any {
        guard isValueType else { return self }
        return GeneratedPlatformValue(
            framework: framework,
            typeName: typeName,
            isValueType: true,
            payload: payload,
            config: config.mapValues { $0.copiedForValueSemantics() })
    }
}

struct GeneratedPlatformTypeKey: Hashable {
    let framework: String
    let type: String
}

struct GeneratedPlatformMemberKey: Hashable {
    let framework: String
    let type: String
    let member: String
}

struct GeneratedPlatformConstructorEntry {
    let framework: String
    let type: String
    let function: HostFunction
}

struct GeneratedPlatformMethodEntry {
    typealias Invoke = @MainActor
        (GeneratedPlatformValue, [RuntimeValue], EvalContext) throws -> RuntimeValue

    let signature: HostSignature
    let framework: String
    let resultType: String
    let invoke: Invoke

    func bound(to base: GeneratedPlatformValue) throws -> HostFunction {
        try HostFunction(signature: signature) { arguments, context in
            if !GeneratedPlatformBridge.frameworkIsNative(framework)
                || base.payload == nil
            {
                return GeneratedPlatformBridge.fallbackResult(
                    framework: framework, type: resultType)
            }
            return try invoke(
                base, arguments.arguments.map(\.value), context)
        }
    }
}

struct GeneratedPlatformStaticMethodEntry {
    typealias Invoke = @MainActor
        ([RuntimeValue], EvalContext) throws -> RuntimeValue

    let signature: HostSignature
    let framework: String
    let resultType: String
    let invoke: Invoke

    func function() throws -> HostFunction {
        try HostFunction(signature: signature) { arguments, context in
            guard GeneratedPlatformBridge.frameworkIsNative(framework) else {
                return GeneratedPlatformBridge.fallbackResult(
                    framework: framework, type: resultType)
            }
            return try invoke(arguments.arguments.map(\.value), context)
        }
    }
}

struct GeneratedPlatformPropertyEntry {
    typealias Get = @MainActor (Any) throws -> RuntimeValue
    typealias Set = @MainActor
        (inout Any, RuntimeValue, EvalContext) throws -> Void

    let framework: String
    let type: String
    let resultType: String
    let contract: HostProperty
}

struct GeneratedPlatformStaticPropertyEntry {
    typealias Get = @MainActor () throws -> RuntimeValue

    let framework: String
    let type: String
    let name: String
    let resultType: String
    let get: Get
}

struct GeneratedPlatformEnumEntry {
    let framework: String
    let type: String
    let name: String
    let get: @MainActor () -> Any
}

/// Runtime half of the generated AppKit/UIKit bridge. The generated file only
/// contains metadata-derived registrations and statically compiled SDK calls;
/// selection, opposite-platform fallback, and value ownership live here once.
enum GeneratedPlatformBridge {
    private static let constructors = buildConstructors()
    private static let methods = buildMethods()
    private static let properties = buildProperties()
    private static let staticMethods = buildStaticMethods()
    private static let staticProperties = buildStaticProperties()
    private static let enumValues = buildEnumValues()
    private static let knownMembers = buildKnownMembers()
    private static let nominalKinds = buildNominalKinds()
    private static let supertypes = buildSupertypes()

    static func frameworkIsNative(_ framework: String) -> Bool {
        switch framework {
        case "AppKit":
#if canImport(AppKit)
            true
#else
            false
#endif
        case "UIKit":
#if canImport(UIKit)
            true
#else
            false
#endif
        default:
            false
        }
    }

    private static var frameworkPreference: [String] {
#if canImport(AppKit)
        ["AppKit", "UIKit"]
#elseif canImport(UIKit)
        ["UIKit", "AppKit"]
#else
        ["UIKit", "AppKit"]
#endif
    }

    static func constructor(named name: String) -> HostFunction? {
        guard let entries = constructors[name] else { return nil }
        for framework in frameworkPreference {
            let candidates = entries.filter { $0.framework == framework }
            guard !candidates.isEmpty else { continue }
            do {
                let typed = candidates.count == 1
                    ? candidates[0].function
                    : try HostFunction(overloads: candidates.map(\.function))
                let type = candidates[0].type
                // Symbol graphs omit some inherited/importer-synthesized
                // initializer shapes. Preserve the established compiled-import
                // absorber only when none of the generated declarations can
                // accept this call; matched calls retain the full typed
                // contract and statically compiled native implementation.
                return HostFunction(name: name) { arguments, context in
                    if typed.signatures.contains(where: {
                        $0.match(arguments: arguments, in: context) != nil
                    }) {
                        return try typed.invoke(arguments, context)
                    }
                    var config: [String: RuntimeValue] = [:]
                    for (index, argument) in arguments.arguments.enumerated() {
                        config[argument.label ?? "_\(index)"] = argument.value
                    }
                    return .native(GeneratedPlatformValue(
                        framework: framework,
                        typeName: type,
                        isValueType: isValueType(framework: framework, type: type),
                        payload: nil,
                        config: config))
                }
            } catch {
                preconditionFailure(
                    "invalid generated \(framework) constructor set '\(name)': \(error)")
            }
        }
        return nil
    }

    static func member(_ name: String, on base: GeneratedPlatformValue) -> RuntimeValue? {
        if let stored = base.config[name] { return stored }
        let entries = typeCandidates(
            framework: base.framework, type: base.typeName)
            .compactMap {
                methods[GeneratedPlatformMemberKey(
                    framework: base.framework, type: $0, member: name)]
            }.first { !$0.isEmpty }
        guard let entries else {
            return unresolvedKnownMember(name, on: base)
        }
        do {
            let functions = try entries.map { try $0.bound(to: base) }
            return .hostFunction(
                functions.count == 1 ? functions[0] : try HostFunction(overloads: functions))
        } catch {
            preconditionFailure(
                "invalid generated \(base.framework) member set '\(base.typeName).\(name)': \(error)")
        }
    }

    static func method(_ name: String, on base: GeneratedPlatformValue) -> RuntimeValue? {
        let entries = typeCandidates(
            framework: base.framework, type: base.typeName)
            .compactMap {
                methods[GeneratedPlatformMemberKey(
                    framework: base.framework, type: $0, member: name)]
            }.first { !$0.isEmpty }
        guard let entries else {
            return unresolvedKnownMember(name, on: base, callableOnly: true)
        }
        do {
            let functions = try entries.map { try $0.bound(to: base) }
            return .hostFunction(
                functions.count == 1 ? functions[0] : try HostFunction(overloads: functions))
        } catch {
            preconditionFailure(
                "invalid generated \(base.framework) method set '\(base.typeName).\(name)': \(error)")
        }
    }

    static func property(_ name: String, on base: GeneratedPlatformValue) -> HostProperty? {
        for type in typeCandidates(
            framework: base.framework, type: base.typeName)
        {
            if let property = properties[GeneratedPlatformMemberKey(
                framework: base.framework, type: type, member: name)] {
                return property.contract
            }
        }
        return nil
    }

    private static func unresolvedKnownMember(
        _ name: String,
        on base: GeneratedPlatformValue,
        callableOnly: Bool = false
    ) -> RuntimeValue? {
        for type in typeCandidates(
            framework: base.framework, type: base.typeName)
        {
            let key = GeneratedPlatformMemberKey(
                framework: base.framework, type: type, member: name)
            guard let isCallable = knownMembers[key],
                  !callableOnly || isCallable else { continue }
            return .native(ChainedImplicitCall(
                base: .native(base), member: name,
                arguments: CallArguments()))
        }
        return nil
    }

    static func staticMember(_ name: String, typeName: String) -> RuntimeValue? {
        for framework in frameworkPreference {
            for type in typeCandidates(framework: framework, type: typeName) {
                let key = GeneratedPlatformMemberKey(
                    framework: framework, type: type, member: name)
                if let property = staticProperties[key] {
                    if frameworkIsNative(framework) {
                        return try? property.get()
                    }
                    return fallbackResult(
                        framework: framework, type: property.resultType)
                }
                if let cases = enumValues[key], let value = cases.first {
                    if frameworkIsNative(framework) {
                        return generatedPlatformResult(
                            value.get(), framework: framework,
                            declaredType: value.type)
                    }
                    return fallbackResult(framework: framework, type: value.type)
                }
                if let entries = staticMethods[key], !entries.isEmpty {
                    do {
                        let functions = try entries.map { try $0.function() }
                        return .hostFunction(
                            functions.count == 1
                                ? functions[0]
                                : try HostFunction(overloads: functions))
                    } catch {
                        preconditionFailure(
                            "invalid generated \(framework) static set '\(typeName).\(name)': \(error)")
                    }
                }
            }
        }
        return nil
    }

    static func enumPayload(
        framework: String, type: String, member: String
    ) -> Any? {
        let key = GeneratedPlatformMemberKey(
            framework: framework, type: type, member: member)
        guard frameworkIsNative(framework), let value = enumValues[key]?.first else {
            return nil
        }
        return value.get()
    }

    static func isValueType(framework: String, type: String) -> Bool {
        nominalKinds[GeneratedPlatformTypeKey(framework: framework, type: type)] ?? true
    }

    static func isPlatformNominal(framework: String, type: String) -> Bool {
        nominalKinds[GeneratedPlatformTypeKey(framework: framework, type: type)] != nil
    }

    static func typeCandidates(framework: String, type: String) -> [String] {
        var result: [String] = []
        var current: String? = type
        var seen = Set<String>()
        while let value = current, seen.insert(value).inserted {
            result.append(value)
            current = supertypes[GeneratedPlatformTypeKey(
                framework: framework, type: value)]
        }
        return result
    }

    static func fallbackResult(framework: String, type rawType: String) -> RuntimeValue {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wrapped = optionalWrappedType(type) {
            return .none(wrappedTypeName: wrapped)
        }
        if collectionElementType(type) != nil { return .native([RuntimeValue]()) }
        switch type {
        case "Void", "()": return .void
        case "Bool": return .native(false)
        case "String", "Substring", "Character": return .native("")
        case "Int", "Int8", "Int16", "Int32", "Int64",
             "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return .native(0)
        case "Double", "Float", "CGFloat", "TimeInterval":
            return .native(0.0)
        case "CGPoint": return .native(CGPoint.zero)
        case "CGSize": return .native(CGSize.zero)
        case "CGRect": return .native(CGRect.zero)
        case "CGVector": return .native(CGVector.zero)
        case "CGAffineTransform": return .native(CGAffineTransform.identity)
        case "NSRange": return .native(NSRange(location: 0, length: 0))
        default:
            return .native(GeneratedPlatformValue(
                framework: framework,
                typeName: type,
                isValueType: isValueType(framework: framework, type: type),
                payload: nil))
        }
    }

    // MARK: Generated registration API

    static func registerConstructor(
        _ table: inout [String: [GeneratedPlatformConstructorEntry]],
        framework: String,
        declaration: String,
        resultType: String,
        invoke: @escaping @MainActor
            ([RuntimeValue], EvalContext) throws -> RuntimeValue
    ) {
        do {
            let signature = try HostSignature(parsing: declaration)
            let function = try HostFunction(signature: signature) { arguments, context in
                if !frameworkIsNative(framework) {
                    var config: [String: RuntimeValue] = [:]
                    for argument in arguments.arguments {
                        if let label = argument.label { config[label] = argument.value }
                    }
                    return .native(GeneratedPlatformValue(
                        framework: framework,
                        typeName: resultType,
                        isValueType: isValueType(framework: framework, type: resultType),
                        payload: nil,
                        config: config))
                }
                return try invoke(arguments.arguments.map(\.value), context)
            }
            table[signature.callableName, default: []].append(
                GeneratedPlatformConstructorEntry(
                    framework: framework, type: resultType, function: function))
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid platform constructor '\(declaration)': \(error)")
        }
    }

    static func registerMethod(
        _ table: inout [GeneratedPlatformMemberKey: [GeneratedPlatformMethodEntry]],
        framework: String,
        declaration: String,
        resultType: String,
        invoke: @escaping GeneratedPlatformMethodEntry.Invoke
    ) {
        do {
            let signature = try HostSignature(parsing: declaration)
            guard let type = signature.receiverType else {
                preconditionFailure("generated platform method has no receiver: \(declaration)")
            }
            let key = GeneratedPlatformMemberKey(
                framework: framework, type: type, member: signature.name)
            table[key, default: []].append(GeneratedPlatformMethodEntry(
                signature: signature, framework: framework,
                resultType: resultType, invoke: invoke))
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid platform method '\(declaration)': \(error)")
        }
    }

    static func registerStaticMethod(
        _ table: inout [GeneratedPlatformMemberKey: [GeneratedPlatformStaticMethodEntry]],
        framework: String,
        declaration: String,
        resultType: String,
        invoke: @escaping GeneratedPlatformStaticMethodEntry.Invoke
    ) {
        do {
            let signature = try HostSignature(parsing: declaration)
            guard let type = signature.receiverType else {
                preconditionFailure("generated platform static method has no receiver: \(declaration)")
            }
            let key = GeneratedPlatformMemberKey(
                framework: framework, type: type, member: signature.name)
            table[key, default: []].append(GeneratedPlatformStaticMethodEntry(
                signature: signature, framework: framework,
                resultType: resultType, invoke: invoke))
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid platform static method '\(declaration)': \(error)")
        }
    }

    static func registerProperty(
        _ table: inout [GeneratedPlatformMemberKey: GeneratedPlatformPropertyEntry],
        framework: String,
        declaration: String,
        resultType: String,
        get: @escaping GeneratedPlatformPropertyEntry.Get,
        set: GeneratedPlatformPropertyEntry.Set?
    ) {
        do {
            let signature = try HostSignature(parsing: declaration)
            guard let type = signature.receiverType else {
                preconditionFailure("generated platform property has no receiver: \(declaration)")
            }
            let propertySetter: HostProperty.Setter?
            if let set {
                propertySetter = { receiver, value, context in
                    guard case .host(let any) = receiver,
                          let base = any as? GeneratedPlatformValue else {
                        throw RuntimeError(
                            message: "generated platform property setter receiver mismatch",
                            fatal: true)
                    }
                    guard frameworkIsNative(framework), var payload = base.payload else {
                        base.config[signature.name] = value
                        return
                    }
                    try set(&payload, value, context)
                    base.payload = payload
                }
            } else {
                propertySetter = nil
            }
            let contract = try HostProperty(
                signature: signature,
                get: { receiver, _ in
                    guard case .host(let any) = receiver,
                          let base = any as? GeneratedPlatformValue else {
                        throw RuntimeError(
                            message: "generated platform property receiver mismatch",
                            fatal: true)
                    }
                    if let stored = base.config[signature.name] { return stored }
                    guard frameworkIsNative(framework), let payload = base.payload else {
                        return fallbackResult(framework: framework, type: resultType)
                    }
                    return try get(payload)
                },
                set: propertySetter)
            let key = GeneratedPlatformMemberKey(
                framework: framework, type: type, member: signature.name)
            table[key] = GeneratedPlatformPropertyEntry(
                framework: framework, type: type,
                resultType: resultType, contract: contract)
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid platform property '\(declaration)': \(error)")
        }
    }

    static func registerStaticProperty(
        _ table: inout [GeneratedPlatformMemberKey: GeneratedPlatformStaticPropertyEntry],
        framework: String,
        type: String,
        name: String,
        resultType: String,
        get: @escaping GeneratedPlatformStaticPropertyEntry.Get
    ) {
        table[GeneratedPlatformMemberKey(
            framework: framework, type: type, member: name)] =
            GeneratedPlatformStaticPropertyEntry(
                framework: framework, type: type, name: name,
                resultType: resultType, get: get)
    }

    static func registerEnumValue(
        _ table: inout [GeneratedPlatformMemberKey: [GeneratedPlatformEnumEntry]],
        framework: String,
        type: String,
        name: String,
        get: @escaping @MainActor () -> Any
    ) {
        let key = GeneratedPlatformMemberKey(
            framework: framework, type: type, member: name)
        table[key, default: []].append(GeneratedPlatformEnumEntry(
            framework: framework, type: type, name: name, get: get))
    }
}

// MARK: - Generated argument/result conversions

private protocol GeneratedPlatformRuntimeConvertible {
    static func generatedPlatformValue(
        from value: RuntimeValue,
        framework: String,
        typeName: String,
        context: EvalContext
    ) throws -> Any
}

extension Optional: GeneratedPlatformRuntimeConvertible {
    fileprivate static func generatedPlatformValue(
        from value: RuntimeValue,
        framework: String,
        typeName: String,
        context: EvalContext
    ) throws -> Any {
        let wrappedType = optionalWrappedType(typeName) ?? typeName
        switch value.optionalState {
        case .none:
            let result: Wrapped? = nil
            return result as Any
        case .some(let wrapped, _):
            let result: Wrapped? = try generatedPlatformArgument(
                wrapped, as: Wrapped.self, framework: framework,
                typeName: wrappedType, context: context)
            return result as Any
        case .notOptional:
            let result: Wrapped? = try generatedPlatformArgument(
                value, as: Wrapped.self, framework: framework,
                typeName: wrappedType, context: context)
            return result as Any
        }
    }
}

extension Array: GeneratedPlatformRuntimeConvertible {
    fileprivate static func generatedPlatformValue(
        from value: RuntimeValue,
        framework: String,
        typeName: String,
        context: EvalContext
    ) throws -> Any {
        guard let values = value.collectionElements else {
            throw RuntimeError(message: "expected an Array for '\(typeName)'")
        }
        let elementType = collectionElementType(typeName) ?? "Element"
        return try values.map {
            try generatedPlatformArgument(
                $0, as: Element.self, framework: framework,
                typeName: elementType, context: context)
        }
    }
}

func generatedPlatformArgument<T>(
    _ value: RuntimeValue,
    as _: T.Type,
    framework: String,
    typeName: String,
    context: EvalContext
) throws -> T {
    if let direct = value.hostPayload as? T { return direct }
    if case .host(let any) = value,
       let box = any as? GeneratedPlatformValue,
       let payload = box.payload as? T {
        return payload
    }
    if let carrier = value.hostPayload as? GeneratedMemberCarrier,
       let payload = carrier.generatedMemberValue as? T {
        return payload
    }
    if T.self == CGFloat.self, let number = value.doubleValue {
        return CGFloat(number) as! T
    }
    if T.self == Float.self, let number = value.doubleValue {
        return Float(number) as! T
    }
    if T.self == Double.self, let number = value.doubleValue {
        return number as! T
    }
    if T.self == Int.self, let number = value.intValue {
        return number as! T
    }
    if T.self == Int8.self, let number = value.intValue,
       let converted = Int8(exactly: number) {
        return converted as! T
    }
    if T.self == Int16.self, let number = value.intValue,
       let converted = Int16(exactly: number) {
        return converted as! T
    }
    if T.self == Int32.self, let number = value.intValue,
       let converted = Int32(exactly: number) {
        return converted as! T
    }
    if T.self == Int64.self, let number = value.intValue {
        return Int64(number) as! T
    }
    if T.self == UInt.self, let number = value.intValue,
       let converted = UInt(exactly: number) {
        return converted as! T
    }
    if T.self == UInt8.self, let number = value.intValue,
       let converted = UInt8(exactly: number) {
        return converted as! T
    }
    if T.self == UInt16.self, let number = value.intValue,
       let converted = UInt16(exactly: number) {
        return converted as! T
    }
    if T.self == UInt32.self, let number = value.intValue,
       let converted = UInt32(exactly: number) {
        return converted as! T
    }
    if T.self == UInt64.self, let number = value.intValue,
       let converted = UInt64(exactly: number) {
        return converted as! T
    }
    if T.self == String.self, let string = value.stringValue {
        return string as! T
    }
    if T.self == Substring.self, let string = value.stringValue {
        return Substring(string) as! T
    }
    if T.self == Character.self, let string = value.stringValue,
       string.count == 1, let character = string.first {
        return character as! T
    }
    if T.self == Bool.self, let flag = value.boolValue {
        return flag as! T
    }
    if case .implicitMember(let member) = value,
       let payload = GeneratedPlatformBridge.enumPayload(
           framework: framework,
           type: optionalWrappedType(typeName) ?? typeName,
           member: member) as? T {
        return payload
    }
    if let convertible = T.self as? GeneratedPlatformRuntimeConvertible.Type,
       let converted = try convertible.generatedPlatformValue(
           from: value, framework: framework, typeName: typeName,
           context: context) as? T {
        return converted
    }
    throw RuntimeError(message:
        "cannot convert '\(value.stringified)' to generated \(framework) type '\(typeName)'")
}

func generatedPlatformResult<T>(
    _ value: T,
    framework: String,
    declaredType: String
) -> RuntimeValue {
    let type = declaredType.trimmingCharacters(in: .whitespacesAndNewlines)
    let any: Any = value
    // Optional<[Element]> reaches this overload with an erased generic
    // Wrapped type. Normalize it here as well as in the statically selected
    // Array overload so SDK collections never leak out as opaque host arrays.
    if let elementType = collectionElementType(type) {
        if let values = any as? [RuntimeValue] { return .native(values) }
        if let values = any as? [Any] {
            return .native(values.map {
                generatedPlatformResult(
                    $0, framework: framework, declaredType: elementType)
            })
        }
    }
    if GeneratedPlatformBridge.isPlatformNominal(
        framework: framework, type: type)
    {
        return .native(GeneratedPlatformValue(
            framework: framework,
            typeName: type,
            isValueType: GeneratedPlatformBridge.isValueType(
                framework: framework, type: type),
            payload: value))
    }
    if let amount = any as? CGFloat { return .native(Double(amount)) }
    if let amount = any as? Float { return .native(Double(amount)) }
    if let amount = any as? Int8 { return .native(Int(amount)) }
    if let amount = any as? Int16 { return .native(Int(amount)) }
    if let amount = any as? Int32 { return .native(Int(amount)) }
    if let amount = any as? Int64 { return .native(Int(amount)) }
    if let amount = any as? UInt { return .native(Int(amount)) }
    if let amount = any as? UInt8 { return .native(Int(amount)) }
    if let amount = any as? UInt16 { return .native(Int(amount)) }
    if let amount = any as? UInt32 { return .native(Int(amount)) }
    if let amount = any as? UInt64, amount <= UInt64(Int.max) {
        return .native(Int(amount))
    }
    return .native(any)
}

func generatedPlatformResult<Wrapped>(
    _ value: Wrapped?,
    framework: String,
    declaredType: String
) -> RuntimeValue {
    let wrappedType = optionalWrappedType(declaredType) ?? declaredType
    guard let value else { return .none(wrappedTypeName: wrappedType) }
    return .some(
        generatedPlatformResult(
            value, framework: framework, declaredType: wrappedType),
        wrappedTypeName: wrappedType)
}

func generatedPlatformResult<Element>(
    _ value: [Element],
    framework: String,
    declaredType: String
) -> RuntimeValue {
    let elementType = collectionElementType(declaredType) ?? "Element"
    return .native(value.map {
        generatedPlatformResult(
            $0, framework: framework, declaredType: elementType)
    })
}

private func optionalWrappedType(_ type: String) -> String? {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("?") { return String(trimmed.dropLast()) }
    guard trimmed.hasPrefix("Optional<"), trimmed.hasSuffix(">") else {
        return nil
    }
    return String(trimmed.dropFirst("Optional<".count).dropLast())
}

private func collectionElementType(_ type: String) -> String? {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.contains(":") {
        return String(trimmed.dropFirst().dropLast())
    }
    guard trimmed.hasPrefix("Array<"), trimmed.hasSuffix(">") else {
        return nil
    }
    return String(trimmed.dropFirst("Array<".count).dropLast())
}
