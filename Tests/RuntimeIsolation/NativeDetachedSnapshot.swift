@MainActor
private final class NativeHeap {
    var values = [2, 3, 5]
}

@main
private struct NativeDetachedSnapshotProbe {
    @MainActor
    static func main() async {
        let heap = NativeHeap()
        let snapshot = heap.values
        let total = await Task.detached {
            snapshot.reduce(0, +)
        }.value
        heap.values.append(total)
        print(heap.values.map(String.init).joined(separator: ",") + "|\(total)")
    }
}
