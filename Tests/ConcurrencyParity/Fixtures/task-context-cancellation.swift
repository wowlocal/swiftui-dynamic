@MainActor
final class CancellationContextProbe {
    var events: [String] = []
    var first: Task<Void, Error>?
}

@MainActor
struct CancellationBetaWorker {
    enum Token: String {
        case value = "beta"
    }
}

extension CancellationBetaWorker {
    @MainActor
    func run(probe: CancellationContextProbe) async {
        let value = await parityYield(Token.value.rawValue)
        probe.events.append(value)
    }
}

@MainActor
func startCancellationContextProbe() -> CancellationContextProbe {
    let probe = CancellationContextProbe()
    probe.first = Task {
        try await parityWaitForever()
    }
    Task {
        await parityAwaitWaitStarted()
        probe.first?.cancel()
    }
    Task {
        await CancellationBetaWorker().run(probe: probe)
    }
    return probe
}

@MainActor
func parityNativeOutput() async throws -> String {
    let probe = startCancellationContextProbe()
    while probe.events.count < 1 {
        await Task.yield()
    }
    guard let first = probe.first else {
        return "missing," + probe.events.joined(separator: ",")
    }
    do {
        try await first.value
        return "succeeded," + probe.events.joined(separator: ",")
    } catch is CancellationError {
        return "cancelled," + probe.events.joined(separator: ",")
    } catch {
        return "failed," + probe.events.joined(separator: ",")
    }
}
