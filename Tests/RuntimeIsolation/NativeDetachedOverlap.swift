import Synchronization

private nonisolated final class NativeOverlapState: Sendable {
    let entered = Atomic<Int>(0)
    let release = Atomic<Bool>(false)
}

@main
private struct NativeDetachedOverlapProbe {
    static func main() async {
        let state = NativeOverlapState()
        let tasks = (0..<2).map { index in
            Task.detached {
                state.entered.wrappingAdd(
                    1, ordering: .acquiringAndReleasing)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while !state.release.load(ordering: .acquiring) {
                    guard ContinuousClock.now < deadline else { return -1 }
                }
                return index
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while state.entered.load(ordering: .acquiring) < 2,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        let observedOverlap = state.entered.load(ordering: .acquiring) == 2
        state.release.store(true, ordering: .releasing)

        var values: [Int] = []
        for task in tasks {
            values.append(await task.value)
        }
        guard observedOverlap, values.sorted() == [0, 1] else {
            fatalError("detached tasks did not overlap before the deadline")
        }
        print("overlap:2")
    }
}
