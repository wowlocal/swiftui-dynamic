enum ParityActorHopFailure: Error {
    case boom
}

actor ParityFailureTarget {
    var stored = 0
    var failureOwnership = "unset"

    func fail() throws {
        failureOwnership = parityActorSegmentOwnership(self)
        stored += 1
        throw ParityActorHopFailure.boom
    }

    func recover() -> String {
        let recoveryOwnership = parityActorSegmentOwnership(self)
        stored += 1
        return failureOwnership + ":" + recoveryOwnership
            + ":" + String(stored)
    }
}

actor ParityFailureCaller {
    func run(_ target: ParityFailureTarget) async -> String {
        let before = parityActorSegmentOwnership(self)
        var outcome = "missed"
        do {
            try await target.fail()
        } catch {
            outcome = "caught"
        }
        let afterFailure = parityActorSegmentOwnership(self)
        let recovered = await target.recover()
        let afterRecovery = parityActorSegmentOwnership(self)
        return before + "|" + outcome + "|" + afterFailure
            + "|" + recovered + "|" + afterRecovery
    }
}

@MainActor
func actorCrossActorFailureProbe() async -> String {
    let target = ParityFailureTarget()
    let caller = ParityFailureCaller()
    return await caller.run(target)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorCrossActorFailureProbe()
}
