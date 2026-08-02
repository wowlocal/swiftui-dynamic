import Foundation
import ObjectiveC
import SwiftInterpreter

/// Capability for a host reference box whose SDK property contracts come from
/// BridgeGen. The box owns only its logical native type and property payload;
/// the generated table owns which names, accessors, and types are legal.
@MainActor
protocol GeneratedReferencePropertyCarrier: AnyObject {
    var generatedReferenceTypeName: String { get }
    var generatedReferencePropertyValues: [String: RuntimeValue] { get set }
    func generatedReferencePropertyValue(
        _ name: String, declaredType: String
    ) throws -> RuntimeValue?
    func applyGeneratedReferenceProperty(
        _ name: String, declaredType: String, value: RuntimeValue
    ) throws -> Bool
}

extension GeneratedReferencePropertyCarrier {
    func generatedReferencePropertyValue(
        _ name: String, declaredType: String
    ) throws -> RuntimeValue? {
        nil
    }

    func applyGeneratedReferenceProperty(
        _ name: String, declaredType: String, value: RuntimeValue
    ) throws -> Bool {
        false
    }
}

/// A carrier whose payload is a LIVE Foundation reference. The box keeps only
/// the members that need genuine interpreted behavior — real formatting, or
/// coercion of operands the interpreter owns rather than Objective-C — and
/// every other property its logical type declares reaches the generated
/// contract and drives the live object through the shared Objective-C
/// property path. An adopting box therefore names no property: the generated
/// table decides which names are legal, and KVC performs the write.
@MainActor
protocol GeneratedReferenceBackedBox: GeneratedReferencePropertyCarrier {
    /// The live object the generated contract reads and writes.
    var generatedReferenceObject: NSObject { get }
}

extension GeneratedReferenceBackedBox {
    func applyGeneratedReferenceProperty(
        _ name: String, declaredType: String, value: RuntimeValue
    ) throws -> Bool {
        try ObjCTrampoline.applyGeneratedReferenceProperty(
            name, declaredType: declaredType, value: value,
            on: generatedReferenceObject)
    }

    func generatedReferencePropertyValue(
        _ name: String, declaredType: String
    ) throws -> RuntimeValue? {
        try ObjCTrampoline.generatedReferencePropertyRead(
            name, declaredType: declaredType, on: generatedReferenceObject)
    }
}

@MainActor
enum GeneratedReferencePropertySupport {
    private static let properties: [String: HostProperty] = {
        var result: [String: HostProperty] = [:]
        for (key, declaration) in
            GeneratedFoundationReferenceProperties.declarationsByKey
        {
            do {
                let signature = try HostSignature(parsing: declaration)
                let name = signature.name
                let setter: HostProperty.Setter?
                if signature.isSettable {
                    setter = { receiver, value, _ in
                        guard case .host(let raw) = receiver,
                              let carrier = raw as?
                                GeneratedReferencePropertyCarrier else {
                            throw RuntimeError(
                                message: "generated reference property setter receiver mismatch",
                                fatal: true)
                        }
                        if let declaredType = signature.returnType {
                            _ = try carrier.applyGeneratedReferenceProperty(
                                name, declaredType: declaredType, value: value)
                        }
                        carrier.generatedReferencePropertyValues[name] = value
                    }
                } else {
                    setter = nil
                }
                result[key] = try HostProperty(
                    signature: signature,
                    get: { receiver, _ in
                        guard case .host(let raw) = receiver,
                              let carrier = raw as?
                                GeneratedReferencePropertyCarrier else {
                            throw RuntimeError(
                                message: "generated reference property receiver mismatch",
                                fatal: true)
                        }
                        if let value =
                            carrier.generatedReferencePropertyValues[name] {
                            return value
                        }
                        if let declaredType = signature.returnType,
                           let value = try carrier
                            .generatedReferencePropertyValue(
                                name, declaredType: declaredType) {
                            return value
                        }
                        if let typeName = signature.returnType,
                           let wrapped = RuntimeOptionalValue.wrappedType(
                               in: typeName) {
                            return .none(wrappedTypeName: wrapped)
                        }
                        throw RuntimeError(message:
                            "generated reference property '\(declaration)' "
                                + "has no host value")
                    },
                    set: setter)
            } catch {
                preconditionFailure(
                    "BridgeGen emitted an invalid reference property "
                        + "'\(declaration)': \(error)")
            }
        }
        return result
    }()

    static func property(
        _ name: String, on carrier: GeneratedReferencePropertyCarrier
    ) -> HostProperty? {
        var type: String? = carrier.generatedReferenceTypeName
        var visited = Set<String>()
        while let current = type, visited.insert(current).inserted {
            if let property = properties["\(current).\(name)"] {
                return property
            }
            type = GeneratedFoundationReferenceProperties
                .superclassByType[current]
        }
        return nil
    }

    /// Swift Foundation values can be toll-free bridged to an Objective-C
    /// reference whose property contract is emitted from the SDK symbol
    /// graph. Serve only read-only contracts: mutating a temporary bridge
    /// would not preserve Swift value semantics. Runtime class ancestry plus
    /// generated declarations select the member, so this adapter contains no
    /// property-name or bridged-type cases.
    private static let bridgedReadOnlyProperties: [String: HostProperty] = {
        var result: [String: HostProperty] = [:]
        for (key, property) in properties
        where !property.signature.isSettable {
            guard let receiverType = property.signature.receiverType else {
                continue
            }
            do {
                result[key] = try HostProperty(
                    signature: property.signature,
                    get: { receiver, context in
                        guard let raw = receiver.hostPayload,
                              let box = bridgedBox(
                                raw, matchingImportedType: receiverType)
                        else {
                            throw RuntimeError(
                                message:
                                    "generated bridged reference property "
                                    + "receiver mismatch for "
                                    + "\(receiverType).\(property.name)",
                                fatal: true)
                        }
                        return try property.read(
                            from: .native(box), in: context)
                    })
            } catch {
                preconditionFailure(
                    "generated bridged reference property became invalid: "
                        + "\(error)")
            }
        }
        return result
    }()

    static func bridgedReadOnlyProperty(
        _ name: String, on value: Any
    ) -> HostProperty? {
        guard let object = bridgedNSObject(value) else { return nil }
        for typeName in runtimeReferenceTypeNames(of: object) {
            if object.responds(to: Selector(name)),
               let property =
                   bridgedReadOnlyProperties["\(typeName).\(name)"] {
                return property
            }
        }
        return nil
    }

    static func bridgedValue(
        _ value: Any, matchesImportedType expectedType: String
    ) -> Bool {
        guard let object = bridgedNSObject(value) else { return false }
        return runtimeReferenceTypeNames(of: object).contains {
            type($0, matchesImportedType: expectedType)
        }
    }

    private static func bridgedBox(
        _ value: Any, matchingImportedType expectedType: String
    ) -> ObjCBox? {
        guard let object = bridgedNSObject(value),
              runtimeReferenceTypeNames(of: object).contains(where: {
                type($0, matchesImportedType: expectedType)
              })
        else {
            return nil
        }
        return ObjCBox(
            object, generatedReferenceTypeName: expectedType)
    }

    private static func bridgedNSObject(_ value: Any) -> NSObject? {
        guard !(value is GeneratedReferencePropertyCarrier) else {
            return nil
        }
        guard let object = value as AnyObject as? NSObject,
              !(object is NSFastEnumeration) else {
            // KVC deliberately broadcasts ordinary keys across Foundation
            // collections. Those receivers keep the interpreter's native
            // collection surface instead of treating an element property as
            // the collection's generated scalar property.
            return nil
        }
        return object
    }

    private static func runtimeReferenceTypeNames(
        of object: NSObject
    ) -> [String] {
        var result: [String] = []
        var current: AnyClass? = Swift.type(of: object)
        while let type = current {
            let qualified = NSStringFromClass(type)
            result.append(
                qualified.split(separator: ".").last.map(String.init)
                    ?? qualified)
            current = class_getSuperclass(type)
        }
        return result
    }

    static func carrier(
        _ carrier: GeneratedReferencePropertyCarrier,
        matchesImportedType expectedType: String
    ) -> Bool {
        type(
            carrier.generatedReferenceTypeName,
            matchesImportedType: expectedType)
    }

    static func type(
        _ observedType: String,
        matchesImportedType expectedType: String
    ) -> Bool {
        var type: String? = observedType
        var visited = Set<String>()
        while let current = type, visited.insert(current).inserted {
            if HostSignature.equivalentTypeName(current, expectedType) {
                return true
            }
            type = GeneratedFoundationReferenceProperties
                .superclassByType[current]
        }
        return false
    }
}
