enum ParityAsyncComputedFailure: Error {
    case boom
}

actor ParityAsyncComputedExitGate {
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

actor ParityAsyncComputedExitTarget {
    let gate: ParityAsyncComputedExitGate
    let shouldThrow: Bool
    var stored = 0
    var entryOwnership = "unset"
    var resumeOwnership = "unset"

    init(gate: ParityAsyncComputedExitGate, shouldThrow: Bool) {
        self.gate = gate
        self.shouldThrow = shouldThrow
    }

    var value: Int {
        get async throws {
            entryOwnership = parityActorSegmentOwnership(self)
            stored += 1
            await gate.suspendUntilOpen()
            resumeOwnership = parityActorSegmentOwnership(self)
            if shouldThrow {
                throw ParityAsyncComputedFailure.boom
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

actor ParityAsyncComputedExitCaller {
    func run(_ target: ParityAsyncComputedExitTarget) async -> String {
        let before = parityActorSegmentOwnership(self)
        var outcome = "missed"
        do {
            let value = try await target.value
            outcome = "value:" + String(value)
        } catch ParityAsyncComputedFailure.boom {
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
func actorComputedPropertyAsyncExitRun(_ shouldThrow: Bool) async -> String {
    let gate = ParityAsyncComputedExitGate()
    let target = ParityAsyncComputedExitTarget(
        gate: gate,
        shouldThrow: shouldThrow)
    let caller = ParityAsyncComputedExitCaller()
    let task = Task { await caller.run(target) }
    await gate.waitUntilSuspended()
    await gate.open()
    return await task.value
}

@MainActor
func actorComputedPropertyAsyncExitsProbe() async -> String {
    let success = await actorComputedPropertyAsyncExitRun(false)
    let failure = await actorComputedPropertyAsyncExitRun(true)
    return success + "||" + failure
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorComputedPropertyAsyncExitsProbe()
}
