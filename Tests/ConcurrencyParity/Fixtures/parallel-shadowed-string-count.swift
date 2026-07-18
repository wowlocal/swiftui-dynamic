extension String {
    var count: Int {
        41
    }
}

@MainActor
func parallelShadowedStringCountProbe() async -> Int {
    let value = "atlas"
    return await Task.detached {
        value.count
    }.value
}

@MainActor
func parallelShadowedStringCountOutput() async -> String {
    String(await parallelShadowedStringCountProbe())
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelShadowedStringCountOutput()
}
