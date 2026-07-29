struct AsyncLetCallValues {
    let left: String
    let right: String
}

func asyncLetCallValue(_ value: String) async throws -> String {
    await Task.yield()
    return value
}

func asyncLetAwaitedCallProbe() async throws -> String {
    async let left = asyncLetCallValue("left")
    async let right = asyncLetCallValue("right")
    let values: AsyncLetCallValues = try await .init(
        left: left,
        right: right)
    return values.left + ":" + values.right
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await asyncLetAwaitedCallProbe()
}
