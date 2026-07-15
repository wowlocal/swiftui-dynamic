enum TaskGroupDeprecatedThrowingSpawnUnlessCancelledError: Error {
    case child
}

func taskGroupDeprecatedThrowingSpawnUnlessCancelledProbe() async -> String {
    await withThrowingTaskGroup(of: String.self) { group in
        let accepted = group.spawnUnlessCancelled(priority: .high) {
            "throwing-value"
        }
        let success = (try? await group.next()) ?? "throwing-missing"

        let failureAccepted = group.spawnUnlessCancelled {
            throw TaskGroupDeprecatedThrowingSpawnUnlessCancelledError.child
        }
        let failure: String
        do {
            _ = try await group.next()
            failure = "failure-missing"
        } catch TaskGroupDeprecatedThrowingSpawnUnlessCancelledError.child {
            failure = "failure-child"
        } catch {
            failure = "failure-wrong"
        }

        group.cancelAll()
        let acceptedAfterCancel = group.spawnUnlessCancelled {
            "throwing-late"
        }
        let tail = try? await group.next()
        return (accepted ? "throwing-accepted" : "throwing-rejected")
            + ":" + success + ":"
            + (failureAccepted ? "failure-accepted" : "failure-rejected")
            + ":" + failure + ":"
            + (acceptedAfterCancel ? "throwing-late" : "throwing-rejected")
            + ":" + (tail == nil ? "throwing-empty" : "throwing-nonempty")
    }
}

func parityNativeOutput() async throws -> String {
    await taskGroupDeprecatedThrowingSpawnUnlessCancelledProbe()
}
