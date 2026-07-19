extension Array where Element == Substring {
    func map(_ transform: (Element) -> Int) -> [Int] {
        [41]
    }
}

@MainActor
func parallelShadowedArrayMapProbe() async -> Int {
    let values = "a bb".split(separator: " ")
    return await Task.detached {
        values.map(\.count).reduce(0, +)
    }.value
}

@MainActor
func parallelShadowedArrayMapOutput() async -> String {
    String(await parallelShadowedArrayMapProbe())
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelShadowedArrayMapOutput()
}
