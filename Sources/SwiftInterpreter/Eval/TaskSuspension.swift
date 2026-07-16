import Foundation

extension Interpreter {
    func sourceTaskYieldFunction() -> HostFunction {
        HostFunction(
            name: "yield",
            tracksHostOperation: false,
            asyncInvoke: { [weak self] _, _ in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during Task.yield")
                }
                try await yieldCurrentTask()
                return .void
            })
    }

    private func yieldCurrentTask() async throws {
        guard let taskID = evaluationTaskContext.runtimeTaskID else {
            throw RuntimeError(message: "Task.yield requires an async runtime task")
        }
        let suspension = RuntimeSuspension.yielding
        let lease = concurrencyRuntime.beginTaskSuspension(
            taskID, for: suspension)
        await Task.yield()
        await concurrencyRuntime.endTaskSuspension(lease)
    }

    func sourceTaskSleepFunction() -> HostFunction {
        HostFunction(
            name: "sleep",
            tracksHostOperation: false,
            asyncInvoke: { [weak self] arguments, _ in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during Task.sleep")
                }
                let request = try Self.sourceSleepRequest(from: arguments)
                try await sleepCurrentTask(
                    for: request.duration,
                    propagatesCancellation: request.declaration.isThrowing)
                return .void
            })
    }

    private func sleepCurrentTask(
        for duration: RuntimeDuration,
        propagatesCancellation: Bool
    ) async throws {
        guard let taskID = evaluationTaskContext.runtimeTaskID else {
            throw RuntimeError(message: "Task.sleep requires an async runtime task")
        }
        if isSourceTaskCancellationRequested() {
            observeSourceCancellation()
            if propagatesCancellation { throw CancellationError() }
            return
        }
        let deadline = runtimeClock.now.advanced(by: duration)
        let suspension = RuntimeSuspension.sleeping(until: deadline)
        let lease = concurrencyRuntime.beginTaskSuspension(
            taskID, for: suspension)
        var sleepFailure: Error?
        do {
            try await runtimeClock.sleep(
                task: taskID, until: deadline, tolerance: nil)
        } catch {
            sleepFailure = error
        }
        await concurrencyRuntime.endTaskSuspension(lease)
        if sleepFailure is CancellationError {
            concurrencyRuntime.observeCancellation(taskID)
            if propagatesCancellation {
                throw CancellationError()
            }
        } else if let sleepFailure {
            throw sleepFailure
        }
    }

    private struct SourceSleepRequest {
        let duration: RuntimeDuration
        let declaration: GeneratedConcurrencyDeclaration
    }

    private static func sourceSleepRequest(
        from arguments: CallArguments
    ) throws -> SourceSleepRequest {
        let duration: RuntimeDuration
        let primaryLabel: String?
        if let value = arguments.labeled("nanoseconds") {
            guard let nanoseconds = value.intValue, nanoseconds >= 0 else {
                throw RuntimeError(message:
                    "Task.sleep(nanoseconds:) requires a nonnegative integer")
            }
            duration = .nanoseconds(Int64(nanoseconds))
            primaryLabel = "nanoseconds"
        } else if let value = arguments.positional(0) {
            guard let nanoseconds = value.intValue, nanoseconds >= 0 else {
                throw RuntimeError(message:
                    "Task.sleep(_:) requires a nonnegative integer")
            }
            duration = .nanoseconds(Int64(nanoseconds))
            primaryLabel = nil
        } else if let value = arguments.labeled("for"),
                  let parsedDuration = sourceDuration(from: value) {
            duration = parsedDuration
            primaryLabel = "for"
        } else {
            throw RuntimeError(message:
                "Task.sleep requires nanoseconds: or a supported Duration value")
        }

        guard let declaration = GeneratedConcurrencySurface
                .taskStaticMemberDeclarations["sleep"]?.first(where: {
                    $0.kind == .function
                        && $0.parameters.first?.label == primaryLabel
                }) else {
            let shape = primaryLabel.map { "\($0):" } ?? "_:"
            throw RuntimeError(message:
                "Task.sleep(\(shape)) is not declared by the active "
                    + "_Concurrency.swiftinterface")
        }
        return SourceSleepRequest(
            duration: duration, declaration: declaration)
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
