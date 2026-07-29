func asyncLetTupleValue(_ value: String) async throws -> String {
    await Task.yield()
    return value
}

func asyncLetTupleValueProbe() async throws -> String {
    async let left = asyncLetTupleValue("left")
    async let right = asyncLetTupleValue("right")
    let values = try await (left, right)
    return values.0 + ":" + values.1
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await asyncLetTupleValueProbe()
}
