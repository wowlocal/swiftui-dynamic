import Foundation

enum ThrowingTaskGroupIterationFailure: Error {
    case failed
}

@MainActor
var throwingIterationFailureEvents: [String] = []

@MainActor
var throwingIterationSiblingStarted = false

@MainActor
func throwingIterationSlowSibling() async -> Int {
    throwingIterationSiblingStarted = true
    throwingIterationFailureEvents.append("sibling-start")
    do {
        try await Task.sleep(for: .seconds(30))
        return 1
    } catch {
        throwingIterationFailureEvents.append("sibling-cancelled")
        return 2
    }
}

@MainActor
func throwingIterationFailingChild() async throws -> Int {
    while !throwingIterationSiblingStarted {
        await Task.yield()
    }
    throwingIterationFailureEvents.append("child-failed")
    throw ThrowingTaskGroupIterationFailure.failed
}

@MainActor
func throwingTaskGroupIterationFailureProbe() async -> String {
    throwingIterationFailureEvents = []
    throwingIterationSiblingStarted = false
    do {
        _ = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                await throwingIterationSlowSibling()
            }
            group.addTask {
                try await throwingIterationFailingChild()
            }
            for try await _ in group {
                throwingIterationFailureEvents.append("unexpected-value")
            }
            return "missed"
        }
        throwingIterationFailureEvents.append("missed")
    } catch ThrowingTaskGroupIterationFailure.failed {
        throwingIterationFailureEvents.append("caught-child")
    } catch {
        throwingIterationFailureEvents.append("wrong-error")
    }
    return throwingIterationFailureEvents.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await throwingTaskGroupIterationFailureProbe()
}
