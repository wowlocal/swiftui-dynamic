@MainActor
private final class NativeHeap {
    var values = [2, 3, 5]
}

private func illegallyReadHeapOffActor(_ heap: NativeHeap) async -> Int {
    await Task.detached {
        heap.values.reduce(0, +)
    }.value
}
