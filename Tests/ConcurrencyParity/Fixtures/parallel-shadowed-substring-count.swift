extension Substring {
    var count: Int { 89 }
}

@MainActor
func parallelShadowedSubstringCountProbe() async -> Int {
    let values: [Substring] = ["a", "bb"]
    return await Task.detached {
        values.map(\.count).reduce(0, +)
    }.value
}

@MainActor
func parallelStringCountControlProbe() async -> Int {
    let values: [String] = ["a", "bb"]
    return await Task.detached {
        values.map(\.count).reduce(0, +)
    }.value
}

@MainActor
func parallelShadowedSubstringCountOutput() async -> String {
    let substringCount = await parallelShadowedSubstringCountProbe()
    let stringCount = await parallelStringCountControlProbe()
    return "\(substringCount):\(stringCount)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelShadowedSubstringCountOutput()
}
