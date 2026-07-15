enum TaskGroupAddUnlessCancelledError: Error {
    case child
}

@MainActor
func taskGroupAddUnlessCancelledOrdinaryProbe() async -> String {
    await withTaskGroup(of: String.self) { group in
        let accepted = group.addTaskUnlessCancelled(priority: .high) {
            "ordinary-value"
        }
        let success = await group.next() ?? "ordinary-missing"

        group.cancelAll()
        let acceptedAfterCancel = group.addTaskUnlessCancelled {
            "ordinary-late"
        }
        let tail = await group.next()
        return (accepted ? "ordinary-accepted" : "ordinary-rejected")
            + ":" + success + ":"
            + (acceptedAfterCancel ? "ordinary-late" : "ordinary-rejected")
            + ":" + (tail == nil ? "ordinary-empty" : "ordinary-nonempty")
    }
}

@MainActor
func taskGroupAddUnlessCancelledThrowingProbe() async -> String {
    await withThrowingTaskGroup(of: String.self) { group in
        let accepted = group.addTaskUnlessCancelled(priority: .high) {
            "throwing-value"
        }
        let success = (try? await group.next()) ?? "throwing-missing"

        let failureAccepted = group.addTaskUnlessCancelled {
            throw TaskGroupAddUnlessCancelledError.child
        }
        let failure: String
        do {
            _ = try await group.next()
            failure = "failure-missing"
        } catch TaskGroupAddUnlessCancelledError.child {
            failure = "failure-child"
        } catch {
            failure = "failure-wrong"
        }

        group.cancelAll()
        let acceptedAfterCancel = group.addTaskUnlessCancelled {
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

@MainActor
func taskGroupAddUnlessCancelledDiscardingProbe() async -> String {
    await withDiscardingTaskGroup(returning: String.self) { group in
        let accepted = group.addTaskUnlessCancelled(priority: .high) {}
        while !group.isEmpty {
            await Task.yield()
        }

        group.cancelAll()
        let acceptedAfterCancel = group.addTaskUnlessCancelled {}
        return (accepted ? "discarding-accepted" : "discarding-rejected")
            + ":discarding-drained:"
            + (acceptedAfterCancel ? "discarding-late" : "discarding-rejected")
            + ":" + (group.isEmpty
                ? "discarding-empty" : "discarding-nonempty")
    }
}

@MainActor
func taskGroupAddUnlessCancelledThrowingDiscardingProbe() async -> String {
    do {
        return try await withThrowingDiscardingTaskGroup(
            returning: String.self
        ) { group in
            let accepted = group.addTaskUnlessCancelled(priority: .high) {}
            while !group.isEmpty {
                await Task.yield()
            }

            group.cancelAll()
            let acceptedAfterCancel = group.addTaskUnlessCancelled {
                throw TaskGroupAddUnlessCancelledError.child
            }
            return (accepted
                ? "throwing-discarding-accepted"
                : "throwing-discarding-rejected")
                + ":throwing-discarding-drained:"
                + (acceptedAfterCancel
                    ? "throwing-discarding-late"
                    : "throwing-discarding-rejected")
                + ":" + (group.isEmpty
                    ? "throwing-discarding-empty"
                    : "throwing-discarding-nonempty")
        }
    } catch {
        return "throwing-discarding-wrong-error"
    }
}

@MainActor
func taskGroupAddUnlessCancelledProbe() async -> String {
    let ordinary = await taskGroupAddUnlessCancelledOrdinaryProbe()
    let throwing = await taskGroupAddUnlessCancelledThrowingProbe()
    let discarding = await taskGroupAddUnlessCancelledDiscardingProbe()
    let throwingDiscarding = await
        taskGroupAddUnlessCancelledThrowingDiscardingProbe()
    return ordinary + "|" + throwing + "|" + discarding
        + "|" + throwingDiscarding
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupAddUnlessCancelledProbe()
}
