enum ParityAsyncSubscriptFailure: Error {
    case boom
}

actor ParityAsyncSubscriptExitGate {
    var suspended = false
    var isOpen = false

    func suspendUntilOpen() async {
        suspended = true
        while !isOpen {
            await Task.yield()
        }
    }

    func waitUntilSuspended() async {
        while !suspended {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
    }
}

actor ParityAsyncSubscriptExitTarget {
    var stored = 0
    var entryOwnership = "unset"
    var resumeOwnership = "unset"

    subscript(
        _ shouldThrow: Bool,
        _ gate: ParityAsyncSubscriptExitGate
    ) -> Int {
        get async throws {
            entryOwnership = parityActorSegmentOwnership(self)
            stored += 1
            await gate.suspendUntilOpen()
            resumeOwnership = parityActorSegmentOwnership(self)
            if shouldThrow {
                throw ParityAsyncSubscriptFailure.boom
            }
            return stored
        }
    }

    func recover() -> String {
        let recoveryOwnership = parityActorSegmentOwnership(self)
        stored += 1
        return entryOwnership + ":" + resumeOwnership
            + ":" + recoveryOwnership + ":" + String(stored)
    }
}

actor ParityAsyncSubscriptExitCaller {
    func run(
        _ target: ParityAsyncSubscriptExitTarget,
        gate: ParityAsyncSubscriptExitGate,
        shouldThrow: Bool
    ) async -> String {
        let before = parityActorSegmentOwnership(self)
        var outcome = "missed"
        do {
            let value = try await target[shouldThrow, gate]
            outcome = "value:" + String(value)
        } catch ParityAsyncSubscriptFailure.boom {
            outcome = "caught"
        } catch {
            outcome = "other"
        }
        let afterExit = parityActorSegmentOwnership(self)
        let recovered = await target.recover()
        let afterRecovery = parityActorSegmentOwnership(self)
        return before + "|" + outcome + "|" + afterExit
            + "|" + recovered + "|" + afterRecovery
    }
}

@MainActor
func actorSubscriptAsyncExitRun(_ shouldThrow: Bool) async -> String {
    let target = ParityAsyncSubscriptExitTarget()
    let caller = ParityAsyncSubscriptExitCaller()
    let gate = ParityAsyncSubscriptExitGate()
    let task = Task {
        await caller.run(target, gate: gate, shouldThrow: shouldThrow)
    }
    await gate.waitUntilSuspended()
    await gate.open()
    return await task.value
}

@MainActor
func actorSubscriptAsyncExitsProbe() async -> String {
    let success = await actorSubscriptAsyncExitRun(false)
    let failure = await actorSubscriptAsyncExitRun(true)
    return success + "||" + failure
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorSubscriptAsyncExitsProbe()
}
