@MainActor
func taskGroupThrowingIterationProbe() async -> String {
    do {
        return try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask { 1 }
            group.addTask { 2 }
            group.addTask { 3 }

            var count = 0
            var total = 0
            for try await value in group {
                count += 1
                total += value
            }
            let remaining = try await group.next()
            let drained = remaining == nil ? "empty" : "value"
            return "\(count):\(total):\(drained)"
        }
    } catch {
        return "error"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupThrowingIterationProbe()
}
