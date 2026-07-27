/// Central dispatch for constructor semantics whose callable surface comes
/// from the active standard-library interface but whose generic/native body
/// cannot execute directly over `RuntimeValue`.
@MainActor
enum RuntimeGeneratedConstructor {
    static func invoke(
        named constructorName: String,
        arguments: CallArguments
    ) throws -> RuntimeValue? {
        if let value = try RuntimeUnicodeScalarConstructor.invoke(
            named: constructorName,
            arguments: arguments)
        {
            return value
        }
        return try RuntimeUnicodeDecodingConstructor.invoke(
            named: constructorName,
            arguments: arguments)
    }
}
