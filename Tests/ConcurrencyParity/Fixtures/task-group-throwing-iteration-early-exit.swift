import Foundation

@MainActor
var earlyExitSiblingStarted = false

@MainActor
var earlyExitReleaseSibling = false

@MainActor
var earlyExitSiblingState = "missing"

@MainActor
var earlyExitCompletions = 0

@MainActor
func earlyExitSibling() async -> String {
    earlyExitSiblingStarted = true
    while !earlyExitReleaseSibling {
        await Task.yield()
    }
    earlyExitSiblingState = Task.isCancelled ? "cancelled" : "active"
    earlyExitCompletions += 1
    return "sibling"
}

@MainActor
func earlyExitFirst() async -> String {
    while !earlyExitSiblingStarted {
        await Task.yield()
    }
    earlyExitCompletions += 1
    return "first"
}

@MainActor
func throwingTaskGroupIterationEarlyExitProbe() async -> String {
    earlyExitSiblingStarted = false
    earlyExitReleaseSibling = false
    earlyExitSiblingState = "missing"
    earlyExitCompletions = 0

    do {
        let first = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                await earlyExitSibling()
            }
            group.addTask {
                await earlyExitFirst()
            }

            var observed = "none"
            for try await value in group {
                observed = value
                earlyExitReleaseSibling = true
                break
            }
            return observed
        }
        let owner = Task.isCancelled ? "owner-cancelled" : "owner-active"
        let joined = earlyExitCompletions == 2 ? "joined" : "not-joined"
        return first + ":" + earlyExitSiblingState + ":" + owner + ":" + joined
    } catch {
        earlyExitReleaseSibling = true
        return "error"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await throwingTaskGroupIterationEarlyExitProbe()
}
