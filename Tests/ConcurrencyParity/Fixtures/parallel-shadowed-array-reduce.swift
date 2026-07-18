extension Array where Element == Int {
    func reduce(
        _ initial: Int,
        _ combine: (Int, Element) -> Int
    ) -> Int {
        73
    }
}

@MainActor
func parallelShadowedArrayReduceProbe() async -> Int {
    let values = "a bb".split(separator: " ")
    return await Task.detached {
        values.map(\.count).reduce(0, +)
    }.value
}

@MainActor
func parallelShadowedArrayReduceOutput() async -> String {
    String(await parallelShadowedArrayReduceProbe())
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelShadowedArrayReduceOutput()
}
