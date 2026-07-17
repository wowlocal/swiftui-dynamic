@MainActor
func parallelCapturedStringCountProbe() async -> String {
    let atlas = "atlas"
    let foodtruck = "foodtruck"
    let atlasCount = Task.detached { atlas.count }
    let foodtruckCount = Task.detached { foodtruck.count }
    let first = await atlasCount.value
    let second = await foodtruckCount.value
    return "\(first):\(second)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelCapturedStringCountProbe()
}
