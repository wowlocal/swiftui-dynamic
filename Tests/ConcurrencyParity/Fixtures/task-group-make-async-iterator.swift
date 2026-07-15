enum TaskGroupIteratorProbeError: Error {
    case child
}

func taskGroupIteratorDefaultNextProbe() async -> String {
    let ordinary = await withTaskGroup(of: Int.self) { group in
        var iterator = group.makeAsyncIterator()
        group.addTask { 5 }
        return await iterator.next() ?? 0
    }

    let throwing = await withThrowingTaskGroup(of: Int.self) { group in
        var iterator = group.makeAsyncIterator()
        group.addTask { 6 }
        return (try? await iterator.next()) ?? 0
    }

    return "default:" + String(ordinary) + ":" + String(throwing)
}

@MainActor
func taskGroupMakeAsyncIteratorProbe() async -> String {
    let defaultNext = await taskGroupIteratorDefaultNextProbe()

    let shared = await withTaskGroup(of: Int.self) { group in
        var iterator = group.makeAsyncIterator()
        group.addTask { 1 }
        group.addTask { 2 }
        let iteratorValue = await iterator.next(
            isolation: MainActor.shared) ?? 0
        let groupValue = await group.next(
            isolation: MainActor.shared) ?? 0
        return "shared:" + String(iteratorValue + groupValue)
    }

    let terminal = await withTaskGroup(of: Int.self) { group in
        var iterator = group.makeAsyncIterator()
        let first = await iterator.next(isolation: MainActor.shared)
        group.addTask { 42 }
        let second = await iterator.next(isolation: MainActor.shared)
        let groupValue = await group.next(isolation: MainActor.shared)
        return "terminal:"
            + (first == nil ? "nil" : "value") + ":"
            + (second == nil ? "nil" : "value") + ":"
            + String(groupValue ?? -1)
    }

    let copied = await withTaskGroup(of: Int.self) { group in
        var first = group.makeAsyncIterator()
        var second = first
        let firstEmpty = await first.next(isolation: MainActor.shared)
        group.addTask { 7 }
        let secondValue = await second.next(isolation: MainActor.shared)
        let firstAgain = await first.next(isolation: MainActor.shared)
        return "copy:"
            + (firstEmpty == nil ? "nil" : "value") + ":"
            + String(secondValue ?? -1) + ":"
            + (firstAgain == nil ? "nil" : "value")
    }

    let throwing = await withThrowingTaskGroup(of: Int.self) { group in
        var iterator = group.makeAsyncIterator()
        group.addTask {
            throw TaskGroupIteratorProbeError.child
        }
        let failure: String
        do {
            _ = try await iterator.next(isolation: MainActor.shared)
            failure = "failure-missing"
        } catch TaskGroupIteratorProbeError.child {
            failure = "failure-child"
        } catch {
            failure = "failure-wrong"
        }

        group.addTask { 9 }
        let iteratorAfterFailure = try? await iterator.next(
            isolation: MainActor.shared)
        let groupAfterFailure = try? await group.next(
            isolation: MainActor.shared)
        return "throwing:" + failure + ":"
            + (iteratorAfterFailure == nil ? "nil" : "value") + ":"
            + String(groupAfterFailure ?? -1)
    }

    let ordinaryCancel = await withTaskGroup(of: Int.self) { group in
        var iterator = group.makeAsyncIterator()
        iterator.cancel()
        let iteratorValue = await iterator.next(
            isolation: MainActor.shared)
        let accepted = group.addTaskUnlessCancelled { 7 }
        return (group.isCancelled ? "cancelled" : "active") + ":"
            + (iteratorValue == nil ? "nil" : "value") + ":"
            + (accepted ? "accepted" : "rejected")
    }

    let throwingCancel = await withThrowingTaskGroup(of: Int.self) { group in
        var iterator = group.makeAsyncIterator()
        iterator.cancel()
        let iteratorValue = try? await iterator.next(
            isolation: MainActor.shared)
        let accepted = group.addTaskUnlessCancelled { 8 }
        return (group.isCancelled ? "cancelled" : "active") + ":"
            + (iteratorValue == nil ? "nil" : "value") + ":"
            + (accepted ? "accepted" : "rejected")
    }

    return defaultNext + "|" + shared + "|" + terminal + "|" + copied
        + "|" + throwing + "|cancel:" + ordinaryCancel + ":"
        + throwingCancel
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupMakeAsyncIteratorProbe()
}
