struct OptionalAsyncWritebackValue {
    var text: String

    mutating func mutate() async -> String {
        text += "-entered"
        await Task.yield()
        text += "-resumed"
        return text
    }
}

struct OptionalAsyncWritebackBox {
    var value: OptionalAsyncWritebackValue?
}

func optionalValueMutatingAsyncWritebackProbe() async -> String {
    var direct: OptionalAsyncWritebackValue? =
        OptionalAsyncWritebackValue(text: "direct")
    let directResult = await direct?.mutate() ?? "nil"

    var nested = OptionalAsyncWritebackBox(
        value: OptionalAsyncWritebackValue(text: "nested"))
    let nestedResult = await nested.value?.mutate() ?? "nil"

    var missing: OptionalAsyncWritebackValue? = nil
    let missingResult = await missing?.mutate() ?? "nil"

    return "\(direct?.text ?? "nil"):\(directResult)"
        + "|\(nested.value?.text ?? "nil"):\(nestedResult)"
        + "|\(missing?.text ?? "nil"):\(missingResult)"
}

func parityNativeOutput() async throws -> String {
    await optionalValueMutatingAsyncWritebackProbe()
}
