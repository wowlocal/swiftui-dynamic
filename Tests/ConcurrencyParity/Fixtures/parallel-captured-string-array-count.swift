@MainActor
func parallelCapturedStringArrayCountProbe() async -> String {
    let atlas: [Substring] = ["Atlas", "🛰️"]
    let foodtruck: [Substring] = ["food", "truck", "🚚"]
    let atlasCount = Task.detached {
        atlas.map(\.count).reduce(0, +)
    }
    let foodtruckCount = Task.detached {
        foodtruck.map(\.count).reduce(0, +)
    }
    let first = await atlasCount.value
    let second = await foodtruckCount.value
    return "\(first):\(second)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelCapturedStringArrayCountProbe()
}
