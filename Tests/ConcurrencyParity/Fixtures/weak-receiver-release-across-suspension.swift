actor WeakReceiverReleaseGate {
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

final class WeakReceiverReleaseProbe: @unchecked Sendable {
    func result() async -> String {
        "alive"
    }
}

func weakReceiverReleaseAcrossSuspensionProbe() async -> String {
    let gate = WeakReceiverReleaseGate()
    var receiver: WeakReceiverReleaseProbe? = WeakReceiverReleaseProbe()
    let task = Task.detached { [weak receiver] in
        await gate.suspendUntilOpen()
        return await receiver?.result() ?? "released"
    }

    await gate.waitUntilStarted()
    receiver = nil
    await gate.release()
    return await task.value
}

func parityNativeOutput() async throws -> String {
    await weakReceiverReleaseAcrossSuspensionProbe()
}
