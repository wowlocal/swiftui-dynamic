@MainActor
func parallelCapturedStringDistanceProbe() async -> String {
    let atlas = "A🛰️BC"
    let atlasLocation = atlas.index(atlas.startIndex, offsetBy: 2)
    let foodtruck = "food🚚truck"
    let foodtruckLocation = foodtruck.index(
        foodtruck.startIndex, offsetBy: 5)
    let atlasDistance = Task.detached {
        atlas.distance(from: atlas.startIndex, to: atlasLocation)
    }
    let foodtruckDistance = Task.detached {
        foodtruck.distance(
            from: foodtruck.startIndex, to: foodtruckLocation)
    }
    let first = await atlasDistance.value
    let second = await foodtruckDistance.value
    return "\(first):\(second)"
}

@MainActor
func parallelCapturedStringDistanceCancellationProbe() async -> String {
    let text = "A🛰️BC"
    let location = text.index(text.startIndex, offsetBy: 2)
    let task = Task.detached {
        text.distance(from: text.startIndex, to: location)
    }
    task.cancel()
    let distance = await task.value
    return "\(distance):\(task.isCancelled)"
}

@MainActor
func parallelCapturedStringDistanceParityProbe() async -> String {
    let values = await parallelCapturedStringDistanceProbe()
    let cancellation = await parallelCapturedStringDistanceCancellationProbe()
    return values + "|" + cancellation
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelCapturedStringDistanceParityProbe()
}
