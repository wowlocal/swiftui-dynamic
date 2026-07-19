actor DetachedMainActorWeakStrongCaptureGate {
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
final class DetachedMainActorStrongKey {
    let label = "key"
}

@MainActor
final class DetachedMainActorWeakOwner {
    let key: DetachedMainActorStrongKey

    init(key: DetachedMainActorStrongKey) {
        self.key = key
    }

    func launchLive() -> Task<String, Never> {
        .detached(priority: .userInitiated) {
            @MainActor @Sendable [weak self, key] in
            let before = parityCurrentIsolationMatches(MainActor.shared)
            await Task.yield()
            let after = parityCurrentIsolationMatches(MainActor.shared)
            return "\(before)|\(after):"
                + "\(self == nil ? "released" : "alive"):\(key.label)"
        }
    }

    func launchReleased(
        through gate: DetachedMainActorWeakStrongCaptureGate
    ) -> Task<String, Never> {
        .detached(priority: .userInitiated) {
            @MainActor @Sendable [weak self, key] in
            let before = parityCurrentIsolationMatches(MainActor.shared)
            await gate.suspendUntilOpen()
            let after = parityCurrentIsolationMatches(MainActor.shared)
            return "\(before)|\(after):"
                + "\(self == nil ? "released" : "alive"):\(key.label)"
        }
    }
}

@MainActor
func detachedMainActorWeakStrongCaptureProbe() async -> String {
    let liveOwner = DetachedMainActorWeakOwner(
        key: DetachedMainActorStrongKey())
    let live = await liveOwner.launchLive().value

    let gate = DetachedMainActorWeakStrongCaptureGate()
    var releasedKey: DetachedMainActorStrongKey? =
        DetachedMainActorStrongKey()
    var releasedOwner: DetachedMainActorWeakOwner? =
        DetachedMainActorWeakOwner(key: releasedKey!)
    let releasedTask = releasedOwner!.launchReleased(through: gate)
    await gate.waitUntilStarted()
    releasedOwner = nil
    releasedKey = nil
    await gate.release()
    let released = await releasedTask.value

    return "\(live)#\(released)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await detachedMainActorWeakStrongCaptureProbe()
}
