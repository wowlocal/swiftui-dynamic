/// Executes the generic Unicode-decoding constructor shape discovered by
/// BridgeGen. The generated surface supplies every eligible result type,
/// argument label, encoding spelling, and native encoding metatype; this
/// adapter only performs the shared RuntimeValue collection conversion.
@MainActor
enum RuntimeUnicodeDecodingConstructor {
    static func invoke(
        named constructorName: String,
        arguments: CallArguments
    ) throws -> RuntimeValue? {
        let initializers = GeneratedUnicodeDecodingSurface.initializers(
            named: constructorName)
        guard let initializer = initializers.first(where: { initializer in
            arguments.arguments.count == 2
                && arguments.arguments.allSatisfy {
                    $0.label == initializer.codeUnitsLabel
                        || $0.label == initializer.encodingLabel
                }
                && arguments.labeled(initializer.codeUnitsLabel) != nil
                && arguments.labeled(initializer.encodingLabel) != nil
        }) else {
            return nil
        }
        guard let codeUnitsValue = arguments.labeled(
                initializer.codeUnitsLabel),
              let unwrappedCodeUnits =
                codeUnitsValue.unwrappedOptionalOrSelf,
              let collection = unwrappedCodeUnits.collectionElements else {
            throw RuntimeError(
                message: "Unicode decoding needs a collection of code units")
        }
        guard let encodedMetatype = arguments.labeled(
                initializer.encodingLabel),
              let encodingValue = encodedMetatype.unwrappedOptionalOrSelf,
              let encodingTypeName = RuntimeMetatype.name(of: encodingValue) else {
            throw RuntimeError(
                message: "Unicode decoding needs an encoding metatype")
        }
        let codeUnits = try collection.map { element -> UInt64 in
            guard let value = unsignedMagnitude(element) else {
                throw RuntimeError(
                    message: "Unicode code units must be unsigned integers")
            }
            return value
        }
        guard let decoded = GeneratedUnicodeDecodingSurface.decode(
            codeUnits, as: encodingTypeName
        ) else {
            throw RuntimeError(
                message: "encoding metatype is not a generated Unicode encoding")
        }
        return .native(decoded)
    }

    private static func unsignedMagnitude(
        _ value: RuntimeValue
    ) -> UInt64? {
        if let integer = value.intValue {
            return integer >= 0 ? UInt64(integer) : nil
        }
        guard case .host(let payload) = value else { return nil }
        if let integer = payload as? UInt64 { return integer }
        if let integer = payload as? UInt { return UInt64(integer) }
        if let integer = payload as? UInt32 { return UInt64(integer) }
        if let integer = payload as? UInt16 { return UInt64(integer) }
        if let integer = payload as? UInt8 { return UInt64(integer) }
        return nil
    }
}
