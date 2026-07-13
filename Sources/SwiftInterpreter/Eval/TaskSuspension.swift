import Foundation

extension Interpreter {
    func sourceTaskSleepFunction() -> HostFunction {
        HostFunction(name: "sleep", asyncInvoke: { [weak self] arguments, _ in
            guard let self else {
                throw RuntimeError(message: "interpreter was released during Task.sleep")
            }
            let duration = try Self.sourceSleepDuration(from: arguments)
            try await sleepCurrentTask(for: duration)
            return .void
        })
    }

    private func sleepCurrentTask(for duration: RuntimeDuration) async throws {
        guard let taskID = evaluationTaskContext.runtimeTaskID else {
            throw RuntimeError(message: "Task.sleep requires an async runtime task")
        }
        let deadline = runtimeClock.now.advanced(by: duration)
        let suspension = RuntimeSuspension.sleeping(until: deadline)
        concurrencyRuntime.suspend(taskID, for: suspension)
        defer { concurrencyRuntime.resume(taskID, from: suspension) }
        do {
            try await runtimeClock.sleep(
                task: taskID, until: deadline, tolerance: nil)
        } catch is CancellationError {
            concurrencyRuntime.observeCancellation(taskID)
            throw CancellationError()
        }
    }

    private static func sourceSleepDuration(
        from arguments: CallArguments
    ) throws -> RuntimeDuration {
        if let value = arguments.labeled("nanoseconds") {
            guard let nanoseconds = value.intValue, nanoseconds >= 0 else {
                throw RuntimeError(message:
                    "Task.sleep(nanoseconds:) requires a nonnegative integer")
            }
            return .nanoseconds(Int64(nanoseconds))
        }
        if let value = arguments.labeled("for"),
           let duration = sourceDuration(from: value) {
            return duration
        }
        throw RuntimeError(message:
            "Task.sleep requires nanoseconds: or a supported Duration value")
    }

    private static func sourceDuration(
        from value: RuntimeValue
    ) -> RuntimeDuration? {
        guard case .host(let payload) = value,
              let call = payload as? ImplicitMemberCall,
              let amount = call.arguments.positional(0)?.doubleValue,
              amount.isFinite else { return nil }
        let scale: Double
        switch call.name {
        case "seconds": scale = 1_000_000_000
        case "milliseconds": scale = 1_000_000
        case "microseconds": scale = 1_000
        case "nanoseconds": scale = 1
        default: return nil
        }
        let nanoseconds = amount * scale
        guard nanoseconds <= Double(Int64.max),
              nanoseconds >= Double(Int64.min) else { return nil }
        return .nanoseconds(Int64(nanoseconds.rounded(.towardZero)))
    }
}
