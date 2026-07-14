@MainActor
func taskGroupIterationProbe() async -> String {
    await withTaskGroup(of: Int.self) { group in
        group.addTask { 1 }
        group.addTask { 2 }
        group.addTask { 3 }

        var count = 0
        var total = 0
        for await value in group {
            count += 1
            total += value
        }

        let tailValue = await group.next()
        let tail = tailValue == nil ? "empty" : "not-empty"
        return "\(count):\(total):" + tail
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupIterationProbe()
}
