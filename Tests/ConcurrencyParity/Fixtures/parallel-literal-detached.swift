@MainActor
func parallelLiteralDetachedProbe() async -> String {
    let text = Task.detached { "atlas" }
    let number = Task.detached { 42 }
    let textValue = await text.value
    let numberValue = await number.value
    return textValue + ":\(numberValue)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelLiteralDetachedProbe()
}
