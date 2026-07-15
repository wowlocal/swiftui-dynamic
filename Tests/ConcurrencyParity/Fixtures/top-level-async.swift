enum TopLevelAsyncProbeError: Error {
    case boom
}

@MainActor
final class TopLevelAsyncProbeState {
    var started = false
    var release = false
    var priority = 0
}

@MainActor
func makeTopLevelAsyncProbeTask(
    state: TopLevelAsyncProbeState
) -> Task<String, Never> {
    async(priority: .utility) {
        state.priority = Int(Task.currentPriority.rawValue)
        state.started = true
        while !state.release {
            await Task.yield()
        }
        return "value:" + (Task.name ?? "nil")
    }
}

@MainActor
func topLevelAsyncProbe() async -> String {
    let state = TopLevelAsyncProbeState()
    let successful = makeTopLevelAsyncProbeTask(state: state)
    let failing = async { () async throws -> String in
        await Task.yield()
        throw TopLevelAsyncProbeError.boom
    }

    while !state.started {
        await Task.yield()
    }
    state.release = true

    let value = await successful.value
    let failure: String
    do {
        _ = try await failing.value
        failure = "unexpected-success"
    } catch TopLevelAsyncProbeError.boom {
        failure = "boom"
    } catch {
        failure = "unexpected-error"
    }
    return value + "|" + String(state.priority) + "|" + failure
}

@MainActor
func parityNativeOutput() async throws -> String {
    await topLevelAsyncProbe()
}
