enum ScopeExitProbeError: Error {
    case expected
}

@MainActor
final class ScopeExitProbeState {
    var normalExited = false
    var throwingExited = false
    nonisolated(unsafe) var events: [String] = []
}

@MainActor
func taskCancellationHandlerScopeExitProbe() async -> String {
    let state = ScopeExitProbeState()

    let normal = Task {
        let value = await withTaskCancellationHandler(operation: {
            state.events.append("normal-operation")
            return "normal-exit"
        }, onCancel: {
            state.events.append("normal-handler")
        })
        state.events.append(value)
        state.normalExited = true
        while !Task.isCancelled {
            await Task.yield()
        }
        state.events.append("normal-cancelled")
    }

    while !state.normalExited {
        await Task.yield()
    }
    normal.cancel()
    await normal.value

    let throwing = Task {
        do {
            _ = try await withTaskCancellationHandler(operation: {
                () async throws -> String in
                state.events.append("throwing-operation")
                throw ScopeExitProbeError.expected
            }, onCancel: {
                state.events.append("throwing-handler")
            })
            state.events.append("unexpected-success")
        } catch ScopeExitProbeError.expected {
            state.events.append("throwing-exit")
        } catch {
            state.events.append("unexpected-error")
        }
        state.throwingExited = true
        while !Task.isCancelled {
            await Task.yield()
        }
        state.events.append("throwing-cancelled")
    }

    while !state.throwingExited {
        await Task.yield()
    }
    throwing.cancel()
    await throwing.value

    return state.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskCancellationHandlerScopeExitProbe()
}
