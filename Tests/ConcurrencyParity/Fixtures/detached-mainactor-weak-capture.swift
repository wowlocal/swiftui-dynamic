actor DetachedMainActorNamedWeakGate {
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
final class DetachedMainActorNamedWeakNotification {}

@MainActor
func launchNamedWeakLive(
    _ notifications: DetachedMainActorNamedWeakNotification
) -> Task<String, Never> {
    Task.detached { @MainActor @Sendable [weak notifications] in
        let before = parityCurrentIsolationMatches(MainActor.shared)
        await Task.yield()
        let after = parityCurrentIsolationMatches(MainActor.shared)
        return "\(before)|\(after):\(notifications == nil ? "released" : "alive")"
    }
}

@MainActor
func launchNamedWeakReleased(
    _ notifications: DetachedMainActorNamedWeakNotification,
    through gate: DetachedMainActorNamedWeakGate
) -> Task<String, Never> {
    Task.detached { @MainActor @Sendable [weak notifications] in
        let before = parityCurrentIsolationMatches(MainActor.shared)
        await gate.suspendUntilOpen()
        let after = parityCurrentIsolationMatches(MainActor.shared)
        return "\(before)|\(after):\(notifications == nil ? "released" : "alive")"
    }
}

@MainActor
func detachedMainActorNamedWeakCaptureProbe() async -> String {
    let liveNotifications = DetachedMainActorNamedWeakNotification()
    let liveTask = launchNamedWeakLive(liveNotifications)
    let live = await liveTask.value

    let gate = DetachedMainActorNamedWeakGate()
    var releasedNotifications: DetachedMainActorNamedWeakNotification? =
        DetachedMainActorNamedWeakNotification()
    let releasedTask = launchNamedWeakReleased(
        releasedNotifications!, through: gate)
    await gate.waitUntilStarted()
    releasedNotifications = nil
    await gate.release()
    let released = await releasedTask.value

    return "\(live)#\(released)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await detachedMainActorNamedWeakCaptureProbe()
}
