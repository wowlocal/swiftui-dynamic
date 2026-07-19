extension String {
    func distance(from start: Index, to end: Index) -> Int {
        77
    }
}

@MainActor
func parallelShadowedStringDistanceProbe() async -> Int {
    let value = "A🛰️BC"
    let location = value.index(value.startIndex, offsetBy: 2)
    return await Task.detached {
        value.distance(from: value.startIndex, to: location)
    }.value
}

@MainActor
func parallelShadowedStringDistanceOutput() async -> String {
    String(await parallelShadowedStringDistanceProbe())
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelShadowedStringDistanceOutput()
}
