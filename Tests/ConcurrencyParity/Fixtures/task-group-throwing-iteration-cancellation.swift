import Foundation

@MainActor
var throwingIterationCancellationCompletions = 0

@MainActor
var throwingIterationCancellationSiblingStarted = false

@MainActor
func throwingIterationCancellationSibling() async -> String {
    throwingIterationCancellationSiblingStarted = true
    do {
        try await Task.sleep(for: .seconds(30))
        return "missed"
    } catch {
        throwingIterationCancellationCompletions += 1
        return "sibling"
    }
}

@MainActor
func throwingIterationCancelledChild() async throws -> String {
    throwingIterationCancellationCompletions += 1
    try Task.checkCancellation()
    return "missed"
}

@MainActor
func throwingTaskGroupIterationCancellationProbe() async -> String {
    throwingIterationCancellationCompletions = 0
    throwingIterationCancellationSiblingStarted = false
    do {
        _ = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                await throwingIterationCancellationSibling()
            }
            while !throwingIterationCancellationSiblingStarted {
                await Task.yield()
            }
            group.cancelAll()
            group.addTask {
                try await throwingIterationCancelledChild()
            }
            for try await _ in group {}
            return "missed"
        }
        return "missed"
    } catch {
        let kind = type(of: error) == CancellationError.self
            ? "cancellation"
            : "wrong-error"
        let owner = Task.isCancelled ? "owner-cancelled" : "owner-active"
        let joined = throwingIterationCancellationCompletions == 2
            ? "joined"
            : "not-joined"
        return kind + ":" + owner + ":" + joined
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await throwingTaskGroupIterationCancellationProbe()
}
