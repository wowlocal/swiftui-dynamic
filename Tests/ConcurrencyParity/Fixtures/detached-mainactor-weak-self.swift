actor DetachedMainActorWeakGate {
    private var started = false
    private var open = false

    func suspendUntilOpen() async {
        started = true
        while !open {
            await Task.yield()
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        open = true
    }
}

@MainActor
final class DetachedMainActorWeakReceiver {
    func launchLive() -> Task<String, Never> {
        Task.detached { @MainActor @Sendable [weak self] in
            let before = parityCurrentIsolationMatches(MainActor.shared)
            await Task.yield()
            let after = parityCurrentIsolationMatches(MainActor.shared)
            return "\(before)|\(after):\(self == nil ? "released" : "alive")"
        }
    }

    func launchReleased(
        through gate: DetachedMainActorWeakGate
    ) -> Task<String, Never> {
        Task.detached { @MainActor @Sendable [weak self] in
            let before = parityCurrentIsolationMatches(MainActor.shared)
            await gate.suspendUntilOpen()
            let after = parityCurrentIsolationMatches(MainActor.shared)
            return "\(before)|\(after):\(self == nil ? "released" : "alive")"
        }
    }
}

@MainActor
func detachedMainActorWeakSelfProbe() async -> String {
    let liveReceiver = DetachedMainActorWeakReceiver()
    let liveTask = liveReceiver.launchLive()
    let live = await liveTask.value

    let gate = DetachedMainActorWeakGate()
    var releasedReceiver: DetachedMainActorWeakReceiver? =
        DetachedMainActorWeakReceiver()
    let releasedTask = releasedReceiver!.launchReleased(through: gate)
    await gate.waitUntilStarted()
    releasedReceiver = nil
    await gate.release()
    let released = await releasedTask.value

    return "\(live)#\(released)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await detachedMainActorWeakSelfProbe()
}
