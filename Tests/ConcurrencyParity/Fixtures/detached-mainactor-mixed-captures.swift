actor DetachedMainActorMixedCaptureGate {
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
final class DetachedMainActorCapturedResponders {
    let label = "responders"
}

@MainActor
final class DetachedMainActorWeakTarget {}

@MainActor
func launchMixedCaptureLive(
    responders: DetachedMainActorCapturedResponders,
    webView: DetachedMainActorWeakTarget,
    webViewDeinitObserver: DetachedMainActorWeakTarget
) -> Task<String, Never> {
    Task.detached {
        @MainActor @Sendable [responders, weak webView, weak webViewDeinitObserver] in
        let before = parityCurrentIsolationMatches(MainActor.shared)
        await Task.yield()
        let after = parityCurrentIsolationMatches(MainActor.shared)
        return "\(before)|\(after):\(responders.label):"
            + "\(webView == nil ? "released" : "alive"):"
            + "\(webViewDeinitObserver == nil ? "released" : "alive")"
    }
}

@MainActor
func launchMixedCaptureReleased(
    responders: DetachedMainActorCapturedResponders,
    webView: DetachedMainActorWeakTarget,
    webViewDeinitObserver: DetachedMainActorWeakTarget,
    through gate: DetachedMainActorMixedCaptureGate
) -> Task<String, Never> {
    Task.detached {
        @MainActor @Sendable [responders, weak webView, weak webViewDeinitObserver] in
        let before = parityCurrentIsolationMatches(MainActor.shared)
        await gate.suspendUntilOpen()
        let after = parityCurrentIsolationMatches(MainActor.shared)
        return "\(before)|\(after):\(responders.label):"
            + "\(webView == nil ? "released" : "alive"):"
            + "\(webViewDeinitObserver == nil ? "released" : "alive")"
    }
}

@MainActor
func detachedMainActorMixedCaptureProbe() async -> String {
    let liveResponders = DetachedMainActorCapturedResponders()
    let liveWebView = DetachedMainActorWeakTarget()
    let liveObserver = DetachedMainActorWeakTarget()
    let liveTask = launchMixedCaptureLive(
        responders: liveResponders,
        webView: liveWebView,
        webViewDeinitObserver: liveObserver)
    let live = await liveTask.value

    let gate = DetachedMainActorMixedCaptureGate()
    var releasedResponders: DetachedMainActorCapturedResponders? =
        DetachedMainActorCapturedResponders()
    var releasedWebView: DetachedMainActorWeakTarget? =
        DetachedMainActorWeakTarget()
    var releasedObserver: DetachedMainActorWeakTarget? =
        DetachedMainActorWeakTarget()
    let releasedTask = launchMixedCaptureReleased(
        responders: releasedResponders!,
        webView: releasedWebView!,
        webViewDeinitObserver: releasedObserver!,
        through: gate)
    await gate.waitUntilStarted()
    releasedResponders = nil
    releasedWebView = nil
    releasedObserver = nil
    await gate.release()
    let released = await releasedTask.value

    return "\(live)#\(released)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await detachedMainActorMixedCaptureProbe()
}
