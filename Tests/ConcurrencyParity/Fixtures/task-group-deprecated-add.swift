enum TaskGroupDeprecatedAddError: Error {
    case child
}

func taskGroupDeprecatedAddProbe() async -> String {
    let ordinary = await withTaskGroup(of: String.self) { group in
        let accepted = await group.add(priority: .high) {
            "ordinary-value"
        }
        let success = await group.next() ?? "ordinary-missing"
        group.cancelAll()
        let acceptedAfterCancel = await group.add {
            "ordinary-late"
        }
        let tail = await group.next()
        return (accepted ? "ordinary-accepted" : "ordinary-rejected")
            + ":" + success + ":"
            + (acceptedAfterCancel ? "ordinary-late" : "ordinary-rejected")
            + ":" + (tail == nil ? "ordinary-empty" : "ordinary-nonempty")
    }

    let throwing = await withThrowingTaskGroup(of: String.self) { group in
        let accepted = await group.add(priority: .high) {
            "throwing-value"
        }
        let success = (try? await group.next()) ?? "throwing-missing"

        let failureAccepted = await group.add {
            throw TaskGroupDeprecatedAddError.child
        }
        let failure: String
        do {
            _ = try await group.next()
            failure = "failure-missing"
        } catch TaskGroupDeprecatedAddError.child {
            failure = "failure-child"
        } catch {
            failure = "failure-wrong"
        }

        group.cancelAll()
        let acceptedAfterCancel = await group.add {
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
    await taskGroupDeprecatedAddProbe()
}
