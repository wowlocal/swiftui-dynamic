actor ParityMailboxStressCounter {
    let participants: Int
    let resumeYieldCount: Int
    var currentRound = 0
    var arrived = 0
    var mutations = 0
    var ownershipViolations = 0

    init(participants: Int, resumeYieldCount: Int) {
        self.participants = participants
        self.resumeYieldCount = resumeYieldCount
    }

    func step(round: Int) async -> Bool {
        var owned = parityActorSegmentOwnership(self) == "owned"
        if round != currentRound {
            ownershipViolations += 1
            owned = false
        }

        arrived += 1
        if arrived == participants {
            arrived = 0
            currentRound += 1
        } else {
            while currentRound == round {
                await Task.yield()
            }
        }

        for _ in 0..<resumeYieldCount {
            await Task.yield()
            owned = owned
                && parityActorSegmentOwnership(self) == "owned"
        }
        owned = owned && parityActorSegmentOwnership(self) == "owned"
        if !owned {
            ownershipViolations += 1
        }
        mutations += 1
        return owned
    }

    func summary(validChildren: Int) -> String {
        String(mutations) + ":" + String(currentRound)
            + ":" + String(arrived) + ":" + String(ownershipViolations)
            + ":" + String(validChildren)
    }
}

func actorMailboxStress(
    fanout: Int,
    rounds: Int,
    resumeYieldCount: Int,
    yieldBeforeCall: Bool
) async -> String {
    let counter = ParityMailboxStressCounter(
        participants: fanout,
        resumeYieldCount: resumeYieldCount)
    let validChildren = await withTaskGroup(
        of: Bool.self,
        returning: Int.self
    ) { group in
        for _ in 0..<fanout {
            group.addTask {
                var valid = true
                for round in 0..<rounds {
                    if yieldBeforeCall {
                        await Task.yield()
                    }
                    valid = await counter.step(round: round) && valid
                }
                return valid
            }
        }

        var valid = 0
        for await childIsValid in group {
            if childIsValid {
                valid += 1
            }
        }
        return valid
    }
    return await counter.summary(validChildren: validChildren)
}

@MainActor
func actorMailboxStressProbe() async -> String {
    await actorMailboxStress(
        fanout: 8,
        rounds: 4,
        resumeYieldCount: 2,
        yieldBeforeCall: true)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorMailboxStressProbe()
}
