enum ParityComputedPropertyFailure: Error {
    case boom
}

actor ParityThrowingComputedTarget {
    var stored = 0
    var failureOwnership = "unset"

    var failingValue: Int {
        get throws {
            failureOwnership = parityActorSegmentOwnership(self)
            stored += 1
            throw ParityComputedPropertyFailure.boom
        }
    }

    func recover() -> String {
        let recoveryOwnership = parityActorSegmentOwnership(self)
        stored += 1
        return failureOwnership + ":" + recoveryOwnership
            + ":" + String(stored)
    }
}

actor ParityThrowingComputedCaller {
    func run(_ target: ParityThrowingComputedTarget) async -> String {
        let before = parityActorSegmentOwnership(self)
        var outcome = "missed"
        do {
            _ = try await target.failingValue
        } catch ParityComputedPropertyFailure.boom {
            outcome = "caught"
        } catch {
            outcome = "other"
        }
        let afterFailure = parityActorSegmentOwnership(self)
        let recovered = await target.recover()
        let afterRecovery = parityActorSegmentOwnership(self)
        return before + "|" + outcome + "|" + afterFailure
            + "|" + recovered + "|" + afterRecovery
    }
}

func actorComputedPropertyFailureProbe() async -> String {
    let target = ParityThrowingComputedTarget()
    let caller = ParityThrowingComputedCaller()
    return await caller.run(target)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorComputedPropertyFailureProbe()
}
