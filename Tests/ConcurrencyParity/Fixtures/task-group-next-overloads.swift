enum GroupNextProbeError: Error {
    case child
}

protocol LegacyTaskGroupNext {
    associatedtype LegacyChild: Sendable
    mutating func next() async -> LegacyChild?
}

extension TaskGroup: LegacyTaskGroupNext {
    typealias LegacyChild = ChildTaskResult
}

protocol LegacyThrowingTaskGroupNext {
    associatedtype LegacyChild: Sendable
    mutating func next() async throws -> LegacyChild?
}

extension ThrowingTaskGroup: LegacyThrowingTaskGroupNext {
    typealias LegacyChild = ChildTaskResult
}

nonisolated func invokeLegacy<G: LegacyTaskGroupNext>(
    _ group: inout G
) async -> G.LegacyChild? {
    await group.next()
}

nonisolated func invokeLegacy<G: LegacyThrowingTaskGroupNext>(
    _ group: inout G
) async throws -> G.LegacyChild? {
    try await group.next()
}

nonisolated func ordinaryLegacyNextProbe() async -> String {
    await withTaskGroup(of: String.self) { group in
        let initial = await invokeLegacy(&group)
        group.addTask { "value" }
        let success = await invokeLegacy(&group)
        let drained = await invokeLegacy(&group)

        group.cancelAll()
        group.addTask {
            Task.isCancelled ? "cancelled-child" : "active-child"
        }
        let afterCancel = await invokeLegacy(&group)
        let final = await invokeLegacy(&group)

        return "ordinary-legacy:"
            + (initial == nil ? "empty" : "wrong") + ":"
            + (success ?? "missing") + ":"
            + (drained == nil ? "empty" : "wrong") + ":"
            + (group.isCancelled ? "cancelled" : "active") + ":"
            + (afterCancel ?? "missing") + ":"
            + (final == nil ? "empty" : "wrong")
    }
}

nonisolated func throwingLegacyNextProbe() async -> String {
    await withThrowingTaskGroup(of: String.self) { group in
        let initial = try? await invokeLegacy(&group)
        group.addTask { "value" }
        let success = try? await invokeLegacy(&group)

        group.addTask { throw GroupNextProbeError.child }
        let failure: String
        do {
            _ = try await invokeLegacy(&group)
            failure = "wrong"
        } catch GroupNextProbeError.child {
            failure = "child-error"
        } catch {
            failure = "wrong-error"
        }

        group.addTask { "post-error" }
        let recovered = try? await invokeLegacy(&group)
        let drained = try? await invokeLegacy(&group)

        group.cancelAll()
        group.addTask {
            try Task.checkCancellation()
            return "wrong-active"
        }
        let cancellation: String
        do {
            _ = try await invokeLegacy(&group)
            cancellation = "wrong"
        } catch is CancellationError {
            cancellation = "cancellation"
        } catch {
            cancellation = "wrong-error"
        }
        let final = try? await invokeLegacy(&group)

        return "throwing-legacy:"
            + (initial == nil ? "empty" : "wrong") + ":"
            + (success ?? "missing") + ":" + failure + ":"
            + (recovered ?? "missing") + ":"
            + (drained == nil ? "empty" : "wrong") + ":"
            + cancellation + ":"
            + (group.isCancelled ? "cancelled" : "active") + ":"
            + (final == nil ? "empty" : "wrong")
    }
}

nonisolated func ordinaryDefaultedGroupNextProbe() async -> String {
    await withTaskGroup(of: String.self) { group in
        let initial = await group.next()
        group.addTask { "value" }
        let success = await group.next()
        let final = await group.next()

        return "ordinary-defaulted:"
            + (initial == nil ? "empty" : "wrong") + ":"
            + (success ?? "missing") + ":"
            + (final == nil ? "empty" : "wrong")
    }
}

nonisolated func throwingDefaultedGroupNextProbe() async -> String {
    await withThrowingTaskGroup(of: String.self) { group in
        let initial = try? await group.next()
        group.addTask { "value" }
        let success = try? await group.next()

        group.addTask { throw GroupNextProbeError.child }
        let failure: String
        do {
            _ = try await group.next()
            failure = "wrong"
        } catch GroupNextProbeError.child {
            failure = "child-error"
        } catch {
            failure = "wrong-error"
        }

        group.addTask { "post-error" }
        let recovered = try? await group.next()
        let final = try? await group.next()

        return "throwing-defaulted:"
            + (initial == nil ? "empty" : "wrong") + ":"
            + (success ?? "missing") + ":" + failure + ":"
            + (recovered ?? "missing") + ":"
            + (final == nil ? "empty" : "wrong")
    }
}

nonisolated func ordinaryExplicitNilGroupNextProbe() async -> String {
    await withTaskGroup(of: String.self) { group in
        group.addTask { "nil-value" }
        let success = await group.next(isolation: nil)
        let final = await group.next(isolation: nil)
        return "ordinary-nil:" + (success ?? "missing") + ":"
            + (final == nil ? "empty" : "wrong")
    }
}

nonisolated func throwingExplicitNilGroupNextProbe() async -> String {
    await withThrowingTaskGroup(of: String.self) { group in
        group.addTask { throw GroupNextProbeError.child }
        let failure: String
        do {
            _ = try await group.next(isolation: nil)
            failure = "wrong"
        } catch GroupNextProbeError.child {
            failure = "child-error"
        } catch {
            failure = "wrong-error"
        }

        group.addTask { "post-error" }
        let recovered = try? await group.next(isolation: nil)
        let final = try? await group.next(isolation: nil)
        return "throwing-nil:" + failure + ":"
            + (recovered ?? "missing") + ":"
            + (final == nil ? "empty" : "wrong")
    }
}

@MainActor
func ordinaryExplicitGroupNextProbe() async -> String {
    await withTaskGroup(of: String.self) { group in
        let initial = await group.next(isolation: MainActor.shared)
        group.addTask { "isolated-value" }
        let success = await group.next(isolation: MainActor.shared)
        let final = await group.next(isolation: MainActor.shared)
        MainActor.assertIsolated()

        return "ordinary-explicit:"
            + (initial == nil ? "empty" : "wrong") + ":"
            + (success ?? "missing") + ":"
            + (final == nil ? "empty" : "wrong") + ":main-actor"
    }
}

@MainActor
func throwingExplicitGroupNextProbe() async -> String {
    await withThrowingTaskGroup(of: String.self) { group in
        let initial = try? await group.next(isolation: MainActor.shared)
        group.addTask { "isolated-value" }
        let success = try? await group.next(isolation: MainActor.shared)

        group.addTask { throw GroupNextProbeError.child }
        let failure: String
        do {
            _ = try await group.next(isolation: MainActor.shared)
            failure = "wrong"
        } catch GroupNextProbeError.child {
            failure = "child-error"
        } catch {
            failure = "wrong-error"
        }

        group.addTask { "post-error" }
        let recovered = try? await group.next(
            isolation: MainActor.shared)
        let final = try? await group.next(isolation: MainActor.shared)
        MainActor.assertIsolated()

        return "throwing-explicit:"
            + (initial == nil ? "empty" : "wrong") + ":"
            + (success ?? "missing") + ":" + failure + ":"
            + (recovered ?? "missing") + ":"
            + (final == nil ? "empty" : "wrong") + ":main-actor"
    }
}

@MainActor
var groupNextSuspendedChildStarted = false

@MainActor
func groupNextCancellationAwareChild() async -> String {
    groupNextSuspendedChildStarted = true
    do {
        try await Task.sleep(for: .seconds(3600))
        return "wrong-finished"
    } catch is CancellationError {
        return Task.isCancelled ? "child-cancelled" : "wrong-active"
    } catch {
        return "wrong-error"
    }
}

@MainActor
func groupNextWaitingOwnerBody() async -> String {
    await withTaskGroup(of: String.self) { group in
        group.addTask { await groupNextCancellationAwareChild() }
        let value = await group.next(isolation: MainActor.shared)
        return (value ?? "missing") + ":"
            + (group.isCancelled ? "group-cancelled" : "group-active")
    }
}

@MainActor
func groupNextCancellationResumptionProbe() async -> String {
    groupNextSuspendedChildStarted = false
    let owner = Task { await groupNextWaitingOwnerBody() }
    while !groupNextSuspendedChildStarted {
        await Task.yield()
    }
    owner.cancel()
    let value = await owner.value

    return "resumption:" + value + ":"
        + (owner.isCancelled ? "owner-cancelled" : "owner-active")
}

@MainActor
func taskGroupNextOverloadProbe() async -> String {
    await ordinaryLegacyNextProbe() + "|"
        + throwingLegacyNextProbe() + "|"
        + ordinaryDefaultedGroupNextProbe() + "|"
        + throwingDefaultedGroupNextProbe() + "|"
        + ordinaryExplicitNilGroupNextProbe() + "|"
        + throwingExplicitNilGroupNextProbe() + "|"
        + ordinaryExplicitGroupNextProbe() + "|"
        + throwingExplicitGroupNextProbe() + "|"
        + groupNextCancellationResumptionProbe()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupNextOverloadProbe()
}
