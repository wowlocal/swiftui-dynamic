enum TaskGroupDeprecatedAsyncUnlessCancelledError: Error {
    case child
}

func taskGroupDeprecatedAsyncUnlessCancelledProbe() async -> String {
    let ordinary = await withTaskGroup(of: String.self) { group in
        let accepted = group.asyncUnlessCancelled(priority: .high) {
            "ordinary-value"
        }
        let success = await group.next() ?? "ordinary-missing"
        group.cancelAll()
        let acceptedAfterCancel = group.asyncUnlessCancelled {
            "ordinary-late"
        }
        let tail = await group.next()
        return (accepted ? "ordinary-accepted" : "ordinary-rejected")
            + ":" + success + ":"
            + (acceptedAfterCancel ? "ordinary-late" : "ordinary-rejected")
            + ":" + (tail == nil ? "ordinary-empty" : "ordinary-nonempty")
    }

    let throwing = await withThrowingTaskGroup(of: String.self) { group in
        let accepted = group.asyncUnlessCancelled(priority: .high) {
            "throwing-value"
        }
        let success = (try? await group.next()) ?? "throwing-missing"

        let failureAccepted = group.asyncUnlessCancelled {
            throw TaskGroupDeprecatedAsyncUnlessCancelledError.child
        }
        let failure: String
        do {
            _ = try await group.next()
            failure = "failure-missing"
        } catch TaskGroupDeprecatedAsyncUnlessCancelledError.child {
            failure = "failure-child"
        } catch {
            failure = "failure-wrong"
        }

        group.cancelAll()
        let acceptedAfterCancel = group.asyncUnlessCancelled {
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

    return ordinary + "|" + throwing
}

func parityNativeOutput() async throws -> String {
    await taskGroupDeprecatedAsyncUnlessCancelledProbe()
}
