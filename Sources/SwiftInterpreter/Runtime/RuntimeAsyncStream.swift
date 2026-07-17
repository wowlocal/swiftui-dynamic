import Foundation

/// Source-facing metadata for interpreter-owned concurrency carriers. Keeping
/// this beside the runtime values lets type and protocol checks stay generic;
/// evaluator dispatch still keys on concrete capabilities, never source names.
protocol RuntimeConcurrencyHostValue: AnyObject {
    var sourceTypeName: String { get }
    var sourceProtocolNames: [String] { get }
}

private enum RuntimeAsyncStreamNext {
    case value(RuntimeValue)
    case finished
    case failed(RuntimeValue)
}

fileprivate enum RuntimeAsyncStreamFlavor {
    case nonthrowing
    case throwing(failureTypeName: String)

    var baseName: String {
        switch self {
        case .nonthrowing: "AsyncStream"
        case .throwing: "AsyncThrowingStream"
        }
    }

    var isThrowing: Bool {
        if case .throwing = self { return true }
        return false
    }

    func sequenceTypeName(elementTypeName: String) -> String {
        switch self {
        case .nonthrowing:
            "AsyncStream<\(elementTypeName)>"
        case .throwing(let failureTypeName):
            "AsyncThrowingStream<\(elementTypeName), \(failureTypeName)>"
        }
    }
}

private enum RuntimeAsyncStreamTermination: CustomStringConvertible {
    case cancelled
    case finished

    var description: String {
        switch self {
        case .cancelled: "cancelled"
        case .finished: "finished"
        }
    }
}

private final class RuntimeAsyncStreamWaiter {
    let taskID: RuntimeTaskID
    let continuation: CheckedContinuation<RuntimeAsyncStreamNext, Never>

    init(
        taskID: RuntimeTaskID,
        continuation: CheckedContinuation<RuntimeAsyncStreamNext, Never>
    ) {
        self.taskID = taskID
        self.continuation = continuation
    }
}

enum RuntimeAsyncStreamYieldResult: CustomStringConvertible {
    case enqueued(remaining: Int)
    case dropped(RuntimeValue)
    case terminated

    var description: String {
        switch self {
        case .enqueued(let remaining):
            "enqueued(remaining: \(remaining))"
        case .dropped(let value):
            "dropped(\(value.debugStringified))"
        case .terminated:
            "terminated"
        }
    }
}

private enum RuntimeAsyncStreamBufferingPolicy {
    case unbounded
    case bufferingOldest(Int)
    case bufferingNewest(Int)

    var isUnbounded: Bool {
        if case .unbounded = self { return true }
        return false
    }

    func remainingCapacity(bufferedCount: Int) -> Int {
        switch self {
        case .unbounded:
            Int.max
        case .bufferingOldest(let limit), .bufferingNewest(let limit):
            max(0, limit - bufferedCount)
        }
    }
}

final class RuntimeAsyncStreamStorage {
    weak var runtime: CooperativeConcurrencyRuntime?
    weak var callbackOwner: Interpreter?
    let id: RuntimeAsyncStreamID
    let elementTypeName: String
    fileprivate let flavor: RuntimeAsyncStreamFlavor
    private let bufferingPolicy: RuntimeAsyncStreamBufferingPolicy
    private var buffered: [RuntimeValue] = []
    private var waiters: [RuntimeAsyncStreamWaiter] = []
    private var onTermination: ClosureValue?
    private var terminal = false
    private var terminalFailure: RuntimeValue?
    private var closed = false

    fileprivate init(
        runtime: CooperativeConcurrencyRuntime,
        callbackOwner: Interpreter,
        flavor: RuntimeAsyncStreamFlavor,
        bufferingPolicy: RuntimeAsyncStreamBufferingPolicy,
        elementTypeName: String
    ) {
        self.runtime = runtime
        self.callbackOwner = callbackOwner
        self.flavor = flavor
        self.bufferingPolicy = bufferingPolicy
        self.elementTypeName = elementTypeName
        id = runtime.createAsyncStream()
    }

    isolated deinit {
        guard !closed else { return }
        precondition(
            waiters.isEmpty,
            "an async stream storage cannot die with suspended consumers")
        if !terminal, let handler = onTermination {
            // The final sequence/iterator release owns the native stream's
            // implicit cancellation edge. Run the callback
            // before releasing the runtime record, synchronously with ARC.
            onTermination = nil
            let taskID = callbackOwner?.evaluationTaskContext.runtimeTaskID
            do {
                _ = try callbackOwner?.callRuntimeAsyncStreamTermination(
                    handler, value: .cancelled)
            } catch {
                runtime?.recordNonthrowingCallbackFailure(
                    error, taskID: taskID)
            }
        }
        runtime?.closeAsyncStream(id)
    }

    fileprivate func poll() -> RuntimeAsyncStreamNext? {
        if !buffered.isEmpty {
            let value = buffered.removeFirst()
            closeIfPossible()
            return .value(value)
        }
        guard terminal else { return nil }
        closeIfPossible()
        if let terminalFailure { return .failed(terminalFailure) }
        return .finished
    }

    fileprivate func wait(
        taskID: RuntimeTaskID
    ) async -> RuntimeAsyncStreamNext {
        await withCheckedContinuation { continuation in
            if let immediate = poll() {
                continuation.resume(returning: immediate)
                return
            }
            precondition(
                !waiters.contains { $0.taskID == taskID },
                "one task cannot await the same AsyncStream twice")
            waiters.append(RuntimeAsyncStreamWaiter(
                taskID: taskID,
                continuation: continuation))
        }
    }

    func yield(_ value: RuntimeValue) -> RuntimeAsyncStreamYieldResult {
        guard !terminal else { return .terminated }
        let delivered = value.copiedForValueSemantics()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: .value(delivered))
            return .enqueued(remaining:
                bufferingPolicy.remainingCapacity(
                    bufferedCount: buffered.count))
        }

        switch bufferingPolicy {
        case .unbounded:
            buffered.append(delivered)
            return .enqueued(remaining: Int.max)
        case .bufferingOldest(let limit):
            guard buffered.count < limit else {
                return .dropped(delivered)
            }
            buffered.append(delivered)
            return .enqueued(remaining: limit - buffered.count)
        case .bufferingNewest(let limit):
            guard buffered.count < limit else {
                if limit == 0 { return .dropped(delivered) }
                let dropped = buffered.removeFirst()
                buffered.append(delivered)
                return .dropped(dropped)
            }
            buffered.append(delivered)
            return .enqueued(remaining: limit - buffered.count)
        }
    }

    func setOnTermination(_ handler: ClosureValue?) {
        onTermination = handler
    }

    func getOnTermination() -> ClosureValue? {
        onTermination
    }

    func finish(
        in context: EvalContext,
        failure: RuntimeValue? = nil
    ) throws {
        guard !terminal else { return }
        terminal = true
        terminalFailure = failure?.copiedForValueSemantics()
        let handler = onTermination
        onTermination = nil
        var handlerFailure: Error?
        if let handler {
            do {
                _ = try context.callClosure(
                    handler,
                    arguments: [.native(RuntimeAsyncStreamTermination.finished)])
            } catch {
                handlerFailure = error
            }
        }
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            if let terminalFailure {
                waiter.continuation.resume(returning: .failed(terminalFailure))
            } else {
                waiter.continuation.resume(returning: .finished)
            }
        }
        closeIfPossible()
        if let handlerFailure { throw handlerFailure }
    }

    func cancel(in context: EvalContext) throws {
        guard !terminal else { return }
        let handler = onTermination
        onTermination = nil
        var handlerFailure: Error?
        if let handler {
            do {
                _ = try context.callClosure(
                    handler,
                    arguments: [.native(RuntimeAsyncStreamTermination.cancelled)])
            } catch {
                handlerFailure = error
            }
        }
        // Swift invokes the cancellation callback before it marks the stream
        // terminal. A callback may therefore yield or finish recursively.
        if !terminal {
            try finish(in: context)
        }
        if let handlerFailure { throw handlerFailure }
    }

    func closeIfPossible() {
        guard !closed, terminal, buffered.isEmpty, waiters.isEmpty else {
            return
        }
        guard let runtime else {
            closed = true
            return
        }
        guard !runtime.asyncStreamHasWaiters(id) else { return }
        runtime.closeAsyncStream(id)
        closed = true
    }
}

final class RuntimeAsyncStreamSequence: RuntimeConcurrencyHostValue {
    let storage: RuntimeAsyncStreamStorage

    init(storage: RuntimeAsyncStreamStorage) {
        self.storage = storage
    }

    var sourceTypeName: String {
        storage.flavor.sequenceTypeName(
            elementTypeName: storage.elementTypeName)
    }

    var sourceProtocolNames: [String] { ["AsyncSequence"] }
}

final class RuntimeAsyncStreamIterator: RuntimeConcurrencyHostValue,
    HostValueSemantic {
    let storage: RuntimeAsyncStreamStorage
    var isAwaitingNext = false

    init(storage: RuntimeAsyncStreamStorage) {
        self.storage = storage
    }

    var sourceTypeName: String {
        storage.flavor.sequenceTypeName(
            elementTypeName: storage.elementTypeName) + ".Iterator"
    }

    var sourceProtocolNames: [String] { ["AsyncIteratorProtocol"] }

    func copiedHostValue() -> Any {
        RuntimeAsyncStreamIterator(storage: storage)
    }
}

final class RuntimeAsyncStreamContinuation: RuntimeConcurrencyHostValue {
    /// Producer handles do not own native stream lifetime. The sequence
    /// and its iterators retain storage; once those owners disappear, this
    /// handle remains usable only to report terminal/no-op outcomes.
    weak var storage: RuntimeAsyncStreamStorage?
    let elementTypeName: String
    fileprivate let flavor: RuntimeAsyncStreamFlavor

    init(storage: RuntimeAsyncStreamStorage) {
        self.storage = storage
        elementTypeName = storage.elementTypeName
        flavor = storage.flavor
    }

    var sourceTypeName: String {
        flavor.sequenceTypeName(
            elementTypeName: elementTypeName) + ".Continuation"
    }

    var sourceProtocolNames: [String] { ["Sendable"] }
}

extension Interpreter {
    func sourceAsyncStreamFunction() -> HostFunction {
        HostFunction(name: "AsyncStream") { [weak self] arguments, context in
            guard let self else {
                throw RuntimeError(message:
                    "interpreter was released while creating AsyncStream")
            }
            let specializedElementType = arguments
                .labeled("__genericArguments")?.stringValue
            let explicitElementType = arguments.positional(0)?
                .hostPayload as? HostTypeMarker
            guard let elementType = specializedElementType
                    ?? explicitElementType?.name,
                  !elementType.isEmpty,
                  !elementType.contains(",") else {
                throw RuntimeError(message:
                    "AsyncStream currently requires one explicit element type")
            }
            return try self.makeRuntimeAsyncStream(
                sourceName: "AsyncStream",
                elementTypeName: elementType,
                flavor: .nonthrowing,
                arguments: arguments,
                context: context)
        }
    }

    func sourceAsyncThrowingStreamFunction() -> HostFunction {
        HostFunction(name: "AsyncThrowingStream") {
            [weak self] arguments, context in
            guard let self else {
                throw RuntimeError(message:
                    "interpreter was released while creating AsyncThrowingStream")
            }
            guard let specialization = arguments
                    .labeled("__genericArguments")?.stringValue else {
                throw RuntimeError(message:
                    "AsyncThrowingStream requires explicit Element and Error types")
            }
            let genericArguments = Self.splitTopLevel(specialization)
            guard genericArguments.count == 2,
                  !genericArguments[0].isEmpty,
                  Self.isAnyErrorType(genericArguments[1]) else {
                throw RuntimeError(message:
                    "AsyncThrowingStream currently requires <Element, Error>")
            }
            return try self.makeRuntimeAsyncStream(
                sourceName: "AsyncThrowingStream",
                elementTypeName: genericArguments[0],
                flavor: .throwing(failureTypeName: genericArguments[1]),
                arguments: arguments,
                context: context)
        }
    }

    private func makeRuntimeAsyncStream(
        sourceName: String,
        elementTypeName: String,
        flavor: RuntimeAsyncStreamFlavor,
        arguments: CallArguments,
        context: EvalContext
    ) throws -> RuntimeValue {
        let bufferingPolicy = try Self.runtimeAsyncStreamBufferingPolicy(
            arguments.labeled("bufferingPolicy"))
        guard !flavor.isThrowing || bufferingPolicy.isUnbounded else {
            throw RuntimeError(message:
                "AsyncThrowingStream bounded buffering is not yet supported")
        }
        guard let build = arguments.lastUnlabeledClosure else {
            throw RuntimeError(message:
                "\(sourceName) requires a continuation builder closure")
        }
        let storage = RuntimeAsyncStreamStorage(
            runtime: concurrencyRuntime,
            callbackOwner: self,
            flavor: flavor,
            bufferingPolicy: bufferingPolicy,
            elementTypeName: elementTypeName)
        let continuation = RuntimeAsyncStreamContinuation(storage: storage)
        _ = try context.callClosure(
            build, arguments: [.native(continuation)])
        return .native(RuntimeAsyncStreamSequence(storage: storage))
    }

    func runtimeAsyncStreamMember(
        _ name: String,
        on payload: Any
    ) -> RuntimeValue? {
        if let sequence = payload as? RuntimeAsyncStreamSequence,
           name == "makeAsyncIterator" {
            return .hostFunction(HostFunction(name: name) { _, _ in
                .native(RuntimeAsyncStreamIterator(
                    storage: sequence.storage))
            })
        }
        if let iterator = payload as? RuntimeAsyncStreamIterator,
           name == "next" {
            let streamName = iterator.storage.flavor.baseName
            return .hostFunction(HostFunction(
                name: name,
                tracksHostOperation: false,
                asyncInvoke: { [weak self, weak iterator] _, _ in
                    guard let self, let iterator else {
                        throw RuntimeError(message:
                            "\(streamName) iterator was released while awaiting next()")
                    }
                    guard !iterator.isAwaitingNext else {
                        throw RuntimeError(
                            message: "attempt to await "
                                + "\(streamName).Iterator.next() concurrently",
                            fatal: true)
                    }
                    iterator.isAwaitingNext = true
                    defer { iterator.isAwaitingNext = false }
                    let value = try await self.nextRuntimeAsyncStreamValue(
                        from: iterator.storage)
                    return .optional(
                        value,
                        wrappedTypeName: iterator.storage.elementTypeName)
                }))
        }
        if let continuation = payload as? RuntimeAsyncStreamContinuation {
            switch name {
            case "yield":
                return .hostFunction(HostFunction(name: name) {
                    arguments, _ in
                    guard let value = arguments.positional(0) else {
                        throw RuntimeError(message:
                            "\(continuation.flavor.baseName).Continuation.yield requires a value")
                    }
                    guard let storage = continuation.storage else {
                        return .native(RuntimeAsyncStreamYieldResult.terminated)
                    }
                    return .native(storage.yield(value))
                })
            case "finish":
                return .hostFunction(HostFunction(name: name) {
                    arguments, context in
                    let failure = Self.runtimeOptionalPayload(
                        arguments.labeled("throwing"))
                    if continuation.flavor.isThrowing, failure == nil {
                        throw RuntimeError(message:
                            "AsyncThrowingStream normal finish is not yet supported")
                    }
                    try continuation.storage?.finish(
                        in: context, failure: failure)
                    return .void
                })
            case "onTermination":
                guard !continuation.flavor.isThrowing else { return nil }
                return .optional(
                    continuation.storage?.getOnTermination().map {
                        .closure($0)
                    },
                    wrappedTypeName:
                        "@Sendable (AsyncStream.Continuation.Termination) -> Void")
            default:
                break
            }
        }
        return nil
    }

    private func nextRuntimeAsyncStreamValue(
        from storage: RuntimeAsyncStreamStorage
    ) async throws -> RuntimeValue? {
        let streamName = storage.flavor.baseName
        guard storage.runtime === concurrencyRuntime else {
            throw RuntimeError(message:
                "\(streamName) belongs to a released interpreter runtime")
        }
        if let immediate = storage.poll() {
            switch immediate {
            case .value(let value): return value
            case .finished: return nil
            case .failed(let failure):
                throw InterpretedThrow(value: failure)
            }
        }

        let task = try requireCanonicalActiveRuntimeTask(
            for: "\(streamName).Iterator.next")
        let lease = concurrencyRuntime.beginWaitingForAsyncStream(
            storage.id, taskID: task.id)
        let cancellationHandler = concurrencyRuntime.addCancellationHandler(
            to: task.id
        ) { [weak self, weak storage] in
            guard let self else {
                throw RuntimeError(message:
                    "interpreter was released while cancelling \(streamName)")
            }
            try storage?.cancel(in: self)
        }
        let next = await storage.wait(taskID: task.id)
        concurrencyRuntime.removeCancellationHandler(
            cancellationHandler, from: task.id)
        await concurrencyRuntime.endWaitingForAsyncStream(
            storage.id, taskID: task.id, lease: lease)
        storage.closeIfPossible()

        switch next {
        case .value(let value): return value
        case .finished: return nil
        case .failed(let failure):
            throw InterpretedThrow(value: failure)
        }
    }

    func writeRuntimeAsyncStreamMember(
        _ name: String,
        on payload: Any,
        to value: RuntimeValue
    ) throws -> Bool {
        guard name == "onTermination",
              let continuation = payload as? RuntimeAsyncStreamContinuation,
              !continuation.flavor.isThrowing else {
            return false
        }
        if value.isNil {
            continuation.storage?.setOnTermination(nil)
            return true
        }
        let candidate: RuntimeValue
        if case .optional(let optional) = value,
           let wrapped = optional.wrapped {
            candidate = wrapped
        } else {
            candidate = value
        }
        guard let handler = candidate.closureValue else {
            throw RuntimeError(message:
                "AsyncStream.Continuation.onTermination requires a closure or nil")
        }
        continuation.storage?.setOnTermination(handler)
        return true
    }

    func hasRuntimeAsyncStreamMember(_ name: String, on payload: Any) -> Bool {
        guard name == "onTermination",
              let continuation = payload as? RuntimeAsyncStreamContinuation else {
            return false
        }
        return !continuation.flavor.isThrowing
    }

    private static func runtimeOptionalPayload(
        _ value: RuntimeValue?
    ) -> RuntimeValue? {
        guard let value else { return nil }
        if case .optional(let optional) = value {
            return optional.wrapped
        }
        return value.isNil ? nil : value
    }

    private static func isAnyErrorType(_ typeName: String) -> Bool {
        let normalized = typeName
            .replacingOccurrences(of: "Swift.", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized == "Error" || normalized == "any Error"
    }

    private static func runtimeAsyncStreamBufferingPolicy(
        _ value: RuntimeValue?
    ) throws -> RuntimeAsyncStreamBufferingPolicy {
        guard let value else { return .unbounded }
        if case .implicitMember("unbounded") = value {
            return .unbounded
        }
        guard case .host(let any) = value,
              let call = any as? ImplicitMemberCall else {
            throw RuntimeError(message:
                "AsyncStream buffering policy is unsupported")
        }
        if call.name == "unbounded", call.arguments.arguments.isEmpty {
            return .unbounded
        }
        guard ["bufferingOldest", "bufferingNewest"].contains(call.name),
              let limit = call.arguments.positional(0)?.intValue,
              call.arguments.arguments.count == 1 else {
            throw RuntimeError(message:
                "AsyncStream buffering policy '.\(call.name)' is unsupported")
        }
        guard limit >= 0 else {
            throw RuntimeError(message:
                "AsyncStream buffering policy '.\(call.name)(\(limit))' is unsupported")
        }
        if call.name == "bufferingOldest" {
            return .bufferingOldest(limit)
        }
        return .bufferingNewest(limit)
    }

    /// Internal source callback entry for synchronous runtime destruction.
    /// Unlike an external host event, this remains inside the ambient source
    /// task and therefore must not reset that task's evaluation budget.
    fileprivate func callRuntimeAsyncStreamTermination(
        _ handler: ClosureValue,
        value: RuntimeAsyncStreamTermination
    ) throws -> RuntimeValue {
        let arguments = CallArguments(arguments: [
            .init(label: nil, value: .native(value))
        ])
        return try callWithArguments(handler, args: arguments, node: nil)
    }
}
