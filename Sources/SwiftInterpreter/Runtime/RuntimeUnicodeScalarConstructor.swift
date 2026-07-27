/// Executes scalar constructors selected from the standard-library
/// swiftinterface. Runtime storage intentionally remains the interpreter's
/// established one-Unicode-scalar String representation, so collection views,
/// `.value`, and generated SDK coercions all share one value model.
@MainActor
enum RuntimeUnicodeScalarConstructor {
    static func invoke(
        named constructorName: String,
        arguments: CallArguments
    ) throws -> RuntimeValue? {
        guard arguments.arguments.count == 1,
              let argument = arguments.arguments.first,
              !argument.isTrailing,
              let argumentTypeName = runtimeTypeName(of: argument.value),
              let initializer = GeneratedUnicodeScalarSurface
                .initializers(named: constructorName)
                .first(where: {
                    $0.parameterTypeName == argumentTypeName
                        && $0.label == argument.label
                })
        else {
            return nil
        }

        let scalar: Unicode.Scalar?
        switch initializer.inputKind {
        case .integer:
            scalar = integerValue(argument.value).flatMap(Unicode.Scalar.init)
        case .string:
            scalar = argument.value.stringValue.flatMap(Unicode.Scalar.init)
        case .scalar:
            if let native = argument.value.hostPayload as? Unicode.Scalar {
                scalar = native
            } else {
                scalar = argument.value.stringValue.flatMap(Unicode.Scalar.init)
            }
        }

        if initializer.isFailable {
            guard let scalar else {
                return .none(wrappedTypeName: initializer.resultTypeName)
            }
            return .some(
                .native(String(scalar)),
                wrappedTypeName: initializer.resultTypeName)
        }
        guard let scalar else {
            throw RuntimeError(
                message: "Unicode scalar constructor argument is out of range")
        }
        return .native(String(scalar))
    }

    private static func runtimeTypeName(of value: RuntimeValue) -> String? {
        switch value {
        case .int:
            return "Int"
        case .string:
            return "String"
        case .host(let payload):
            var name = String(reflecting: Swift.type(of: payload))
            if name.hasPrefix("Swift.") {
                name.removeFirst("Swift.".count)
            }
            return name
        default:
            return nil
        }
    }

    private static func integerValue(_ value: RuntimeValue) -> Int? {
        if let value = value.intValue {
            return value
        }
        guard let payload = value.hostPayload else { return nil }
        if let value = payload as? Int8 { return Int(value) }
        if let value = payload as? Int16 { return Int(value) }
        if let value = payload as? Int32 { return Int(value) }
        if let value = payload as? Int64 { return Int(exactly: value) }
        if let value = payload as? UInt8 { return Int(value) }
        if let value = payload as? UInt16 { return Int(value) }
        if let value = payload as? UInt32 { return Int(exactly: value) }
        if let value = payload as? UInt64 { return Int(exactly: value) }
        if let value = payload as? UInt { return Int(exactly: value) }
        return nil
    }
}
