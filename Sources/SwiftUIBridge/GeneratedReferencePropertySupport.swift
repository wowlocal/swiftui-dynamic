import SwiftInterpreter

/// Capability for a host reference box whose writable SDK property contracts
/// come from BridgeGen. The box owns only its logical native type and inert
/// property storage; the generated table owns which names and types are legal.
@MainActor
protocol GeneratedReferencePropertyCarrier: AnyObject {
    var generatedReferenceTypeName: String { get }
    var generatedReferencePropertyValues: [String: RuntimeValue] { get set }
    func applyGeneratedReferenceProperty(
        _ name: String, declaredType: String, value: RuntimeValue
    ) throws -> Bool
}

extension GeneratedReferencePropertyCarrier {
    func applyGeneratedReferenceProperty(
        _ name: String, declaredType: String, value: RuntimeValue
    ) throws -> Bool {
        false
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

    static func carrier(
        _ carrier: GeneratedReferencePropertyCarrier,
        matchesImportedType expectedType: String
    ) -> Bool {
        var type: String? = carrier.generatedReferenceTypeName
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
