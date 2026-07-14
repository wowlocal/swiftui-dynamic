import Foundation

enum ThrowingTaskGroupBodyError: Error {
    case failed
}

@MainActor
var throwingTaskGroupBodyEvents: [String] = []

@MainActor
var throwingTaskGroupChildStarted = false

@MainActor
func recordThrowingTaskGroupBodyEvent(_ event: String) {
    throwingTaskGroupBodyEvents.append(event)
}

@MainActor
func throwingTaskGroupBodyChild() async -> String {
    throwingTaskGroupChildStarted = true
    throwingTaskGroupBodyEvents.append("child-start")
    do {
        try await Task.sleep(for: .seconds(30))
        return "missed"
    } catch {
        recordThrowingTaskGroupBodyEvent("child-cancelled")
        return "cancelled"
    }
}

@MainActor
func throwingTaskGroupBodyThrowProbe() async -> String {
    throwingTaskGroupBodyEvents = []
    throwingTaskGroupChildStarted = false
    do {
        _ = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                await throwingTaskGroupBodyChild()
            }
            while !throwingTaskGroupChildStarted {
                await Task.yield()
            }
            throwingTaskGroupBodyEvents.append("body-throw")
            throw ThrowingTaskGroupBodyError.failed
        }
        throwingTaskGroupBodyEvents.append("missed")
    } catch ThrowingTaskGroupBodyError.failed {
        throwingTaskGroupBodyEvents.append("caught-body")
    } catch {
        throwingTaskGroupBodyEvents.append("wrong-error")
    }
    return throwingTaskGroupBodyEvents.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await throwingTaskGroupBodyThrowProbe()
}
