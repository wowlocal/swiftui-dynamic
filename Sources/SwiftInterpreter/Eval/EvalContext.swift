import SwiftSyntax

/// A host-call capability bound to the source task that entered the gateway.
/// Hosts may retain it and re-enter from a newly-created native task; every
/// callback is rebound to the original evaluator context instead of relying
/// on ambient native TaskLocal inheritance.
@MainActor
final class TaskBoundEvalContext: EvalContext {
    let interpreter: Interpreter
    let evaluationContext: EvaluationTaskContext
    private var activeHostOperationID: HostOperationID?

    init(interpreter: Interpreter, evaluationContext: EvaluationTaskContext) {
        self.interpreter = interpreter
        self.evaluationContext = evaluationContext
    }

    var evaluationTaskContextID: UInt64 { evaluationContext.id }
    var sourceExecutor: RuntimeExecutorKind {
        evaluationContext.currentExecutor
    }
    var buildConfiguration: InterpreterBuildConfiguration {
        interpreter.buildConfiguration
    }

    private func bound<T>(_ operation: () throws -> T) rethrows -> T {
        try EvaluationTaskContext.$current.withValue(
            evaluationContext, operation: operation)
    }

    private func bound<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await EvaluationTaskContext.$current.withValue(evaluationContext) {
            try await operation()
        }
    }

    func withHostOperation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        guard activeHostOperationID == nil else {
            preconditionFailure(
                "one host-call context cannot own nested host operations")
        }
        guard let taskID = evaluationContext.runtimeTaskID else {
            throw RuntimeError(message:
                "async host gateway requires a runtime task")
        }
        let operationID = interpreter.concurrencyRuntime.beginHostOperation(
            for: taskID)
        activeHostOperationID = operationID
        do {
            let result = try await operation()
            activeHostOperationID = nil
            await interpreter.concurrencyRuntime.endHostOperation(
                operationID, for: taskID)
            return result
        } catch {
            let failure = error
            activeHostOperationID = nil
            await interpreter.concurrencyRuntime.endHostOperation(
                operationID, for: taskID)
            throw failure
        }
    }

    func runHostWorkerOperation(
        _ makeOperation: () throws -> HostWorkerOperation?
    ) async throws -> RuntimeValue? {
        guard interpreter.canRunPhysicalHostOperation(
            in: evaluationContext) else {
            return nil
        }
        guard let operation = try makeOperation() else {
            return nil
        }
        return try await withHostOperation {
            try await interpreter.runPhysicalHostOperation(
                operation, in: evaluationContext)
        }
    }

    private func callback<T>(_ operation: () throws -> T) throws -> T {
        guard let operationID = activeHostOperationID,
              let taskID = evaluationContext.runtimeTaskID else {
            return try bound(operation)
        }
        try interpreter.concurrencyRuntime
            .resumeHostOperationForSynchronousCallback(
            operationID, taskID: taskID)
        defer {
            interpreter.concurrencyRuntime.suspendHostOperationAfterCallback(
                operationID, taskID: taskID)
        }
        return try bound(operation)
    }

    private func callback<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        guard let operationID = activeHostOperationID,
              let taskID = evaluationContext.runtimeTaskID else {
            return try await bound(operation)
        }
        await interpreter.concurrencyRuntime.resumeHostOperationForCallback(
            operationID, taskID: taskID)
        do {
            let result = try await bound(operation)
            interpreter.concurrencyRuntime.suspendHostOperationAfterCallback(
                operationID, taskID: taskID)
            return result
        } catch {
            let failure = error
            interpreter.concurrencyRuntime.suspendHostOperationAfterCallback(
                operationID, taskID: taskID)
            throw failure
        }
    }

    func callClosure(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try callback {
            try interpreter.callClosure(closure, arguments: arguments)
        }
    }

    func callHostCallback(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        // A framework event is a new runtime entry, not re-entry into the
        // source task that happened to construct the host value. In
        // particular, a SwiftUI action may fire long after rendering ended.
        try interpreter.callHostCallback(closure, arguments: arguments)
    }

    func callClosureAsync(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        try await callback {
            try await interpreter.callClosureAsync(
                closure, arguments: arguments)
        }
    }

    func callSwiftUITask(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        // A view-owned task may begin long after the render task that created
        // this capability has completed. It therefore enters through a fresh
        // runtime session rather than rebinding the retained render context.
        try await interpreter.callSwiftUITask(
            closure, arguments: arguments)
    }

    func spawnBackgroundTask(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try bound {
            try interpreter.spawnBackgroundTask(closure, arguments: arguments)
        }
    }

    func spawnBackgroundTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        try bound {
            try interpreter.spawnBackgroundTask(
                closure, arguments: arguments, priority: priority)
        }
    }

    func spawnBackgroundTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        try bound {
            try interpreter.spawnBackgroundTask(
                closure, arguments: arguments, name: name,
                priority: priority)
        }
    }

    func spawnDetachedTask(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try bound {
            try interpreter.spawnDetachedTask(closure, arguments: arguments)
        }
    }

    func spawnDetachedTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        try bound {
            try interpreter.spawnDetachedTask(
                closure, arguments: arguments, priority: priority)
        }
    }

    func spawnDetachedTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        try bound {
            try interpreter.spawnDetachedTask(
                closure, arguments: arguments, name: name,
                priority: priority)
        }
    }

    func spawnUnstructuredTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        contextInheritance: RuntimeTaskContextInheritance,
        startPolicy: RuntimeTaskStartPolicy,
        operationExecutor: RuntimeExecutorKind,
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        try bound {
            try interpreter.spawnUnstructuredTask(
                closure,
                arguments: arguments,
                contextInheritance: contextInheritance,
                startPolicy: startPolicy,
                operationExecutor: operationExecutor,
                name: name,
                priority: priority)
        }
    }

    func taskLocalValue(for key: RuntimeTaskLocalKey) -> RuntimeValue? {
        bound { interpreter.taskLocalValue(for: key) }
    }

    func withTaskLocalValue(
        _ value: RuntimeValue,
        for key: RuntimeTaskLocalKey,
        operation: ClosureValue,
        arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try callback {
            try interpreter.withTaskLocalValue(
                value, for: key, operation: operation, arguments: arguments)
        }
    }

    func withTaskLocalValue(
        _ value: RuntimeValue,
        for key: RuntimeTaskLocalKey,
        operation: ClosureValue,
        arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        try await callback {
            try await interpreter.withTaskLocalValue(
                value, for: key, operation: operation, arguments: arguments)
        }
    }

    func invokeHostConstructor(
        named name: String, arguments: CallArguments
    ) throws -> RuntimeValue? {
        try bound {
            try interpreter.invokeHostConstructor(named: name, arguments: arguments)
        }
    }

    func callBackgroundClosure(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try callback {
            try interpreter.callBackgroundClosure(closure, arguments: arguments)
        }
    }

    func callBuilderClosure(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> [RuntimeValue] {
        try callback {
            try interpreter.callBuilderClosure(closure, arguments: arguments)
        }
    }

    func callResultBuilderClosure(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        resultProtocol: String
    ) throws -> [RuntimeValue] {
        try callback {
            try interpreter.callResultBuilderClosure(
                closure,
                arguments: arguments,
                resultProtocol: resultProtocol)
        }
    }

    func resultBuilderClosure(
        _ closure: ClosureValue,
        matchesResultProtocol resultProtocol: String
    ) -> Bool? {
        bound {
            interpreter.resultBuilderClosure(
                closure,
                matchesResultProtocol: resultProtocol)
        }
    }

    func withKnownFiniteHostIteration<T>(
        _ operation: () throws -> T
    ) throws -> T {
        try bound {
            try interpreter.withKnownFiniteHostIteration(operation)
        }
    }

    func sourceStaticMember(
        named member: String, ofType typeName: String
    ) throws -> RuntimeValue? {
        try bound {
            try interpreter.sourceStaticMember(
                named: member, ofType: typeName)
        }
    }

    func collectionStorageValuesAreEqual(
        _ lhs: RuntimeValue, _ rhs: RuntimeValue
    ) throws -> Bool {
        try bound {
            try interpreter.collectionStorageValuesAreEqual(lhs, rhs)
        }
    }

    func hostTypeName(of value: RuntimeValue) -> String {
        bound { interpreter.hostTypeName(of: value) }
    }

    func hostValue(
        _ value: RuntimeValue, matchesType typeName: String
    ) -> Bool {
        bound { interpreter.hostValue(value, matchesType: typeName) }
    }

    func hostValue(
        _ value: RuntimeValue, conformsTo protocolName: String
    ) -> Bool {
        bound { interpreter.hostValue(value, conformsTo: protocolName) }
    }
}

// MARK: - EvalContext (what gateways can call back into)

extension Interpreter: EvalContext {
    public var sourceExecutor: RuntimeExecutorKind {
        evaluationTaskContext.currentExecutor
    }

    /// Require the ambient evaluator capability to name the live task record
    /// that owns it. Checking only a retained context's non-nil IDs is unsafe:
    /// a host can re-enter that stale capability after runtime release.
    func requireCanonicalActiveRuntimeTask(
        for api: String
    ) throws -> RuntimeTaskRecord {
        let context = evaluationTaskContext
        guard context.isAsyncSession,
              let taskID = context.runtimeTaskID,
              let record = concurrencyRuntime.records[taskID],
              record.state == .running,
              record.evaluationContext === context else {
            throw RuntimeError(message:
                "\(api) requires an active canonical async runtime task")
        }
        return record
    }

    func canRunPhysicalHostOperation(
        in context: EvaluationTaskContext
    ) -> Bool {
        guard physicalWorkerDriver != nil,
              context.isAsyncSession,
              context.runtimeEntry != nil else {
            return false
        }
        switch context.currentExecutor {
        case .cooperativeDefault, .detached:
            return true
        case .mainActor, .actor:
            // Offloading a synchronous call from an actor-isolated segment
            // would introduce reentrancy that native Swift does not permit at
            // a non-suspending call. Keep those gateways confined.
            return false
        }
    }

    func runPhysicalHostOperation(
        _ operation: HostWorkerOperation,
        in context: EvaluationTaskContext
    ) async throws -> RuntimeValue {
        guard canRunPhysicalHostOperation(in: context),
              let driver = physicalWorkerDriver,
              let entry = context.runtimeEntry else {
            throw RuntimeError(message:
                "physical host operation lost its eligible runtime entry",
                fatal: true)
        }
        let capability = try entry.makeWorkerCapability(copying: [])
        let job = RuntimePhysicalWorkerJob(
            capability: capability,
            priority: context.priority
        ) { capability in
            guard capability.accessManifest.isWorkerSafe else {
                throw RuntimeError(message:
                    "physical host operation received an unsafe worker manifest",
                    fatal: true)
            }
            return try operation.execute().workerSnapshot
        }
        concurrencyRuntime.recordPhysicalHostOperationSubmission()
        let snapshot = try await driver.executeHostOperation(job)
        concurrencyRuntime.recordPhysicalHostOperationExecution()
        return snapshot.materializedRuntimeValue()
    }

    public func hostTypeName(of value: RuntimeValue) -> String {
        if case .host(let any) = value {
            if let concurrency = any as? RuntimeConcurrencyHostValue {
                return concurrency.sourceTypeName
            }
            if let marker = any as? HostTypeMarker { return marker.name + ".Type" }
            if let typeName = registry?.hostTypeName(of: any) { return typeName }
        }
        return HostRuntimeTypeSystem.typeName(of: value)
    }

    public func sourceStaticMember(
        named member: String, ofType typeName: String
    ) throws -> RuntimeValue? {
        guard let symbol = hostExtensionSymbols[typeName] else {
            return nil
        }
        return try staticMember(member, of: symbol)
    }

    public func hostValue(
        _ value: RuntimeValue, matchesType typeName: String
    ) -> Bool {
        if HostRuntimeTypeSystem.matches(value, type: typeName)
            || valueIsType(value, typeName) {
            return true
        }
        if case .instance(let instance) = value,
           let backing = instance.hostSuperclassBacking {
            return hostValue(backing, matchesType: typeName)
        }
        guard case .host(let any) = value else { return false }
        return registry?.hostValue(
            any, matchesImportedType: typeName) == true
    }

    public func hostValue(
        _ value: RuntimeValue, conformsTo protocolName: String
    ) -> Bool {
        if HostRuntimeTypeSystem.conforms(value, to: protocolName)
            || valueIsType(value, protocolName) {
            return true
        }
        if case .instance(let instance) = value,
           let backing = instance.hostSuperclassBacking {
            return hostValue(backing, conformsTo: protocolName)
        }
        if case .host(let any) = value {
            if let concurrency = any as? RuntimeConcurrencyHostValue,
               concurrency.sourceProtocolNames.contains(protocolName) {
                return true
            }
            return registry?.hostProtocolCandidates(of: any)
                .contains(protocolName) == true
        }
        return false
    }

    public func callClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue {
        steps = 0 // fresh entry, e.g. a Button action invoked from the UI
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        return try callWithArguments(closure, args: args, node: nil)
    }

    /// Run a synchronous external host callback with a real logical task and
    /// session. The source callback itself remains inline, matching APIs such
    /// as `Button(action:)`; any source `Task` it creates sees an async session
    /// and is scheduled independently through the canonical runtime.
    public func callHostCallback(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        let entry = concurrencyRuntime.createEntry(
            kind: .hostCallback,
            heap: runtimeHeap,
            programState: closure.programState
                ?? currentProgramState,
            programPlan: closure.programPlan
                ?? currentProgramPlan,
            programMetadata: closure.programMetadata
                ?? currentProgramMetadata,
            interpreter: self)
        let taskLocals = RuntimeTaskLocalStorage()
        let record = concurrencyRuntime.createTask(
            entry: entry,
            kind: .hostCallback,
            parent: nil,
            priority: RuntimeTaskPriority(Task.currentPriority),
            executorPreference: .mainActor,
            taskLocals: taskLocals,
            name: nil)
        precondition(
            concurrencyRuntime.begin(record),
            "a fresh host callback task must begin exactly once")
        let context = concurrencyRuntime.makeEvaluationTaskContext(
            runtimeTaskID: record.id,
            runtimeEntry: entry,
            isAsyncSession: true,
            priority: record.effectivePriority,
            executor: record.executorPreference,
            taskLocals: taskLocals)
        concurrencyRuntime.bind(context, to: record)
        defer {
            context.removeAllDynamicState()
            concurrencyRuntime.release(record.id)
        }

        return try EvaluationTaskContext.$current.withValue(context) {
            do {
                let value = try callClosure(closure, arguments: arguments)
                concurrencyRuntime.succeed(record, with: value)
                return value
            } catch is CancellationError {
                concurrencyRuntime.requestCancellation(
                    record, source: .hostTask)
                concurrencyRuntime.completeCancellation(record)
                throw CancellationError()
            } catch {
                concurrencyRuntime.fail(record, with: error)
                throw error
            }
        }
    }

    public func callClosureAsync(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        steps = 0
        let args = CallArguments(arguments: arguments.map {
            .init(label: nil, value: $0)
        })
        return try await callWithArgumentsSuspending(closure, args: args, node: nil)
    }

    /// Run one SwiftUI-owned async action as a canonical source task.
    ///
    /// Real SwiftUI owns appearance, identity, replacement, and disappearance
    /// of the outer native task. This entry owns only the interpreter runtime
    /// counterpart and keeps the two cancellation lifetimes linked.
    public func callSwiftUITask(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        let entry = concurrencyRuntime.createEntry(
            kind: .swiftUITask,
            heap: runtimeHeap,
            programState: closure.programState
                ?? currentProgramState,
            programPlan: closure.programPlan
                ?? currentProgramPlan,
            programMetadata: closure.programMetadata
                ?? currentProgramMetadata,
            interpreter: self)
        let priority = RuntimeTaskPriority(Task.currentPriority)
        let taskLocals = RuntimeTaskLocalStorage()
        let record = concurrencyRuntime.createTask(
            entry: entry,
            kind: .swiftUITask,
            parent: nil,
            priority: priority,
            executorPreference: .mainActor,
            taskLocals: taskLocals,
            name: nil)
        let handle = RuntimeTaskHandle(
            runtime: concurrencyRuntime, record: record)
        let pending = PendingRuntimeTask(
            entry: entry,
            priority: priority,
            taskLocals: taskLocals,
            record: record,
            handle: handle)

        do {
            try launchRuntimeTask(pending, sessionOwned: false) {
                [weak self] in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during SwiftUI task")
                }
                return try await self.callBackgroundClosureSuspending(
                    closure, arguments: arguments)
            }
        } catch {
            concurrencyRuntime.release(handle.id)
            throw error
        }
        defer { concurrencyRuntime.release(handle.id) }

        let outcome = await withTaskCancellationHandler {
            await handle.waitForOutcome()
        } onCancel: { [weak handle] in
            Task { @MainActor [weak handle] in
                handle?.cancel(source: .swiftUILifecycle)
            }
        }

        switch outcome {
        case .success(let value, _):
            return value
        case .cancelled:
            throw CancellationError()
        case .failure(let value, _):
            if let runtimeFailure = value.hostPayload as? RuntimeError {
                throw runtimeFailure
            }
            throw RuntimeError(
                message: handle.failureDescription ?? value.stringified)
        }
    }

    public func taskLocalValue(
        for key: RuntimeTaskLocalKey
    ) -> RuntimeValue? {
        evaluationTaskContext.taskLocals.value(for: key)
    }

    public func withTaskLocalValue(
        _ value: RuntimeValue,
        for key: RuntimeTaskLocalKey,
        operation: ClosureValue,
        arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try evaluationTaskContext.taskLocals.withValue(
            value, for: key
        ) {
            try callClosure(operation, arguments: arguments)
        }
    }

    public func withTaskLocalValue(
        _ value: RuntimeValue,
        for key: RuntimeTaskLocalKey,
        operation: ClosureValue,
        arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        try await evaluationTaskContext.taskLocals.withValue(
            value, for: key
        ) {
            try await callClosureAsync(operation, arguments: arguments)
        }
    }

    public func spawnBackgroundTask(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try spawnRuntimeTask(
            kind: .unstructured, closure: closure, arguments: arguments,
            name: nil, priority: nil)
    }

    public func spawnBackgroundTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        try spawnRuntimeTask(
            kind: .unstructured, closure: closure, arguments: arguments,
            name: nil, priority: priority)
    }

    public func spawnBackgroundTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        guard evaluationTaskContext.isAsyncSession else {
            throw RuntimeError(message:
                "Task creation requires runAsync")
        }
        return try spawnRuntimeTask(
            kind: .unstructured, closure: closure, arguments: arguments,
            name: name, priority: priority)
    }

    public func spawnDetachedTask(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try spawnRuntimeTask(
            kind: .detached, closure: closure, arguments: arguments,
            name: nil, priority: nil)
    }

    public func spawnDetachedTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        try spawnRuntimeTask(
            kind: .detached, closure: closure, arguments: arguments,
            name: nil, priority: priority)
    }

    public func spawnDetachedTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        guard evaluationTaskContext.isAsyncSession else {
            throw RuntimeError(message:
                "Task creation requires runAsync")
        }
        return try spawnRuntimeTask(
            kind: .detached, closure: closure, arguments: arguments,
            name: name, priority: priority)
    }

    public func spawnUnstructuredTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        contextInheritance: RuntimeTaskContextInheritance,
        startPolicy: RuntimeTaskStartPolicy,
        operationExecutor: RuntimeExecutorKind,
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        guard evaluationTaskContext.isAsyncSession else {
            throw RuntimeError(message:
                "immediate task creation requires runAsync")
        }
        let kind: RuntimeTaskKind = contextInheritance == .detached
            ? .detached : .unstructured
        return try spawnRuntimeTask(
            kind: kind,
            closure: closure,
            arguments: arguments,
            name: name,
            priority: priority,
            startPolicy: startPolicy,
            operationExecutor: operationExecutor)
    }

    func spawnAsyncLetTask(
        initializer: ExprSyntax,
        in environment: Environment,
        annotation: String?
    ) throws -> RuntimeTaskHandle {
        guard evaluationTaskContext.isAsyncSession else {
            throw RuntimeError(message:
                "async let requires runAsync")
        }
        let pending = makePendingRuntimeTask(
            kind: .asyncLet, explicitPriority: nil)
        do {
            try launchRuntimeTask(
                pending, sessionOwned: false,
                body: { [weak self] in
                    guard let self else {
                        throw RuntimeError(message:
                            "interpreter was released during async let")
                    }
                    return try await self.evaluateAsyncLetInitializerSuspending(
                        initializer, in: environment, annotation: annotation)
                })
        } catch {
            concurrencyRuntime.release(pending.handle.id)
            throw error
        }
        return pending.handle
    }

    func spawnTaskGroupChild(
        operation: ClosureValue,
        in group: RuntimeTaskGroup,
        name: String?,
        priority: RuntimeTaskPriority?,
        startPolicy: RuntimeTaskStartPolicy = .enqueued,
        operationExecutor: RuntimeExecutorKind? = nil
    ) throws -> RuntimeTaskHandle {
        guard evaluationTaskContext.isAsyncSession else {
            throw RuntimeError(message:
                "task groups require runAsync")
        }
        try group.requireActive(
            ownerTaskID: evaluationTaskContext.runtimeTaskID)

        let pending = makePendingRuntimeTask(
            kind: .groupChild, explicitPriority: priority, name: name,
            operationExecutor: operationExecutor)
        let discardsResult = group.kind.discardsResults
        for source in group.newChildCancellationSources {
            pending.handle.cancel(source: source)
        }
        // An immediate child may complete before its constructor returns.
        // Install every structured/group ownership edge first so its source
        // prefix and completion publication observe one valid transaction.
        concurrencyRuntime.addGroupChild(
            pending.handle.id, to: group.record)
        group.append(pending.handle)
        do {
            try launchRuntimeTask(
                pending,
                sessionOwned: false,
                startPolicy: startPolicy,
                body: { [weak self] in
                    guard let self else {
                        throw RuntimeError(message:
                            "interpreter was released during task-group child")
                    }
                    let result = try await self.callBackgroundClosureSuspending(
                        operation, arguments: [])
                    return discardsResult ? .void : result
                })
        } catch {
            group.removePending(pending.handle)
            concurrencyRuntime.removePendingGroupChild(
                pending.handle.id, from: group.record)
            concurrencyRuntime.release(pending.handle.id)
            throw error
        }
        return pending.handle
    }

    private struct PendingRuntimeTask {
        let entry: RuntimeEntry
        let priority: RuntimeTaskPriority
        let taskLocals: RuntimeTaskLocalStorage
        let record: RuntimeTaskRecord
        let handle: RuntimeTaskHandle
    }

    private func makePendingRuntimeTask(
        kind: RuntimeTaskKind,
        explicitPriority: RuntimeTaskPriority?,
        name: String? = nil,
        operationExecutor: RuntimeExecutorKind? = nil
    ) -> PendingRuntimeTask {
        let entry = evaluationTaskContext.runtimeEntry
            ?? concurrencyRuntime.createEntry(
                kind: .compatibilityTask,
                heap: runtimeHeap,
                programState: currentProgramState,
                programPlan: currentProgramPlan,
                programMetadata: currentProgramMetadata,
                interpreter: self)
        let priority = explicitPriority ?? (kind == .detached
            ? .medium : evaluationTaskContext.priority)
        let taskLocals = kind == .detached
            ? RuntimeTaskLocalStorage()
            : evaluationTaskContext.taskLocals.inheritedCopy()
        let executorPreference: RuntimeExecutorKind
        if let operationExecutor {
            executorPreference = operationExecutor
        } else {
            switch kind {
            case .detached:
                executorPreference = .detached
            case .asyncLet, .groupChild:
                // The currently supported nonisolated structured-child surface
                // begins on Swift's cooperative executor. Any actor-isolated call
                // made by the operation performs its own declaration-level hop
                // for that dynamic call extent.
                executorPreference = .cooperativeDefault
            case .root, .unstructured, .hostCallback, .swiftUITask:
                executorPreference = evaluationTaskContext.currentExecutor
            }
        }
        let record = concurrencyRuntime.createTask(
            entry: entry,
            kind: kind,
            parent: kind == .detached
                ? nil : evaluationTaskContext.runtimeTaskID,
            priority: priority,
            executorPreference: executorPreference,
            taskLocals: taskLocals,
            name: name)
        return PendingRuntimeTask(
            entry: entry,
            priority: priority,
            taskLocals: taskLocals,
            record: record,
            handle: RuntimeTaskHandle(
                runtime: concurrencyRuntime, record: record))
    }

    private func spawnRuntimeTask(
        kind: RuntimeTaskKind,
        closure: ClosureValue,
        arguments: [RuntimeValue],
        name: String?,
        priority explicitPriority: RuntimeTaskPriority?,
        startPolicy: RuntimeTaskStartPolicy = .enqueued,
        operationExecutor: RuntimeExecutorKind? = nil
    ) throws -> RuntimeValue {
        let pending = makePendingRuntimeTask(
            kind: kind, explicitPriority: explicitPriority, name: name,
            operationExecutor: operationExecutor)
        let handle = pending.handle
        let arguments = arguments
        let physicalKernelJob: RuntimePhysicalSourceKernelJob?
        if evaluationTaskContext.isAsyncSession,
           kind == .detached,
           startPolicy == .enqueued {
            physicalKernelJob = try makePhysicalSourceKernelJob(
                closure: closure,
                arguments: arguments,
                entry: pending.entry,
                record: pending.record,
                priority: pending.priority)
        } else {
            physicalKernelJob = nil
        }

        // Existing synchronous clients cannot suspend to await child work.
        // Preserve their deterministic contract while returning the same
        // observable handle used by async sessions.
        guard evaluationTaskContext.isAsyncSession else {
            defer { concurrencyRuntime.release(handle.id) }
            // Compatibility runs historically execute one task body inline
            // but suppress recursively-created tasks. Without this guard,
            // each nested body resets its background slice and can evade the
            // evaluator budget indefinitely.
            guard synchronousTaskDepth == 0 else {
                handle.succeed(with: .void)
                return .native(handle)
            }
            synchronousTaskDepth += 1
            defer { synchronousTaskDepth -= 1 }
            do {
                let value = try callBackgroundClosure(closure, arguments: arguments)
                handle.succeed(with: value)
            } catch is CancellationError {
                handle.cancel()
                throw CancellationError()
            } catch let error as RuntimeError where !error.fatal {
                handle.fail(with: error)
            }
            return .native(handle)
        }

        do {
            try launchRuntimeTask(
                pending, sessionOwned: true, startPolicy: startPolicy,
                body: { [weak self] in
                    guard let self else {
                        throw RuntimeError(message:
                            "interpreter was released during source task")
                    }
                    if let physicalKernelJob,
                       let driver = self.physicalWorkerDriver {
                        self.concurrencyRuntime
                            .recordPhysicalSourceKernelSubmission()
                        let snapshot = try await driver.executeSourceKernel(
                            physicalKernelJob)
                        self.concurrencyRuntime
                            .recordPhysicalSourceKernelExecution()
                        if let command = physicalKernelJob
                            .confinedContinuationCommand {
                            return try self.concurrencyRuntime
                                .takePhysicalSourceContinuationOutcome(command)
                        }
                        return snapshot.materializedRuntimeValue()
                    }
                    return try await self.callBackgroundClosureSuspending(
                        closure,
                        arguments: arguments,
                        inheritsAnonymousClosureLexicalExecutor:
                            kind != .detached
                                || startPolicy != .enqueued
                                || operationExecutor != nil)
                })
        } catch {
            concurrencyRuntime.release(handle.id)
            throw error
        }
        return .native(handle)
    }

    private func launchRuntimeTask(
        _ pending: PendingRuntimeTask,
        sessionOwned: Bool,
        startPolicy: RuntimeTaskStartPolicy = .enqueued,
        body: @escaping @MainActor @Sendable () async throws -> RuntimeValue
    ) throws {
        try concurrencyRuntime.requireTaskCapacity()

        let handle = pending.handle
        let record = pending.record
        let taskContext = concurrencyRuntime.makeEvaluationTaskContext(
            runtimeTaskID: handle.id,
            runtimeEntry: pending.entry,
            isAsyncSession: true,
            priority: record.effectivePriority,
            executor: record.executorPreference,
            taskLocals: pending.taskLocals)
        concurrencyRuntime.bind(taskContext, to: record)
        let operation: @MainActor @Sendable () async -> Void = {
            [weak self, weak handle] in
            await EvaluationTaskContext.$current.withValue(taskContext) {
                defer { taskContext.removeAllDynamicState() }
                // Ordinary task construction never runs inline. Swift 6's
                // immediate task APIs deliberately run this prefix on the
                // caller until the first real suspension instead.
                if startPolicy == .enqueued {
                    await Task.yield()
                }
                guard let self, let handle else { return }
                guard handle.begin() else {
                    handle.completeCancellation()
                    return
                }
                do {
                    // Source cancellation is cooperative even when requested
                    // before entry. Only an owning session/host abort may
                    // suppress the source body at this boundary.
                    try self.checkRuntimeCancellation()
                    let value = try await body()
                    try self.checkRuntimeCancellation()
                    handle.succeed(with: value)
                } catch is InterpreterSessionAbort {
                    handle.completeCancellation()
                } catch is CancellationError {
                    handle.completeCancellation()
                } catch {
                    handle.fail(with: error)
                }
            }
        }
        let task: Task<Void, Never>
        if startPolicy == .immediate {
            guard #available(macOS 26.0, iOS 26.0, *) else {
                throw RuntimeError(message:
                    "immediate task creation requires macOS or iOS 26")
            }
            if record.kind == .detached {
                task = Task.immediateDetached(
                    priority: pending.priority.nativePriority,
                    operation: operation)
            } else {
                task = Task.immediate(
                    priority: pending.priority.nativePriority,
                    operation: operation)
            }
        } else if record.kind == .detached {
            task = Task.detached(
                priority: pending.priority.nativePriority, operation: operation)
        } else {
            task = Task(
                priority: pending.priority.nativePriority, operation: operation)
        }
        handle.attach(task)
        guard sessionOwned else { return }

        let runtime = concurrencyRuntime
        runtime.retainScheduledTask(handle)
        let cleanup: @MainActor @Sendable () async -> Void = {
            [weak runtime, weak handle] in
            await task.value
            guard let runtime, let handle else { return }
            runtime.releaseScheduledTask(handle)
        }
        Task.detached(operation: cleanup)
    }

    public func invokeHostConstructor(
        named name: String, arguments: CallArguments
    ) throws -> RuntimeValue? {
        guard let constructor = registry?.constructor(named: name) else { return nil }
        return try constructor.invoke(arguments, self)
    }

    /// Background work (`Task { … }` bodies). On device these run
    /// concurrently, so an INTENTIONALLY infinite loop (`while true {
    /// poll(); try? await Task.sleep }`) is legitimate there — it suspends
    /// and never blocks launch. Synchronously we give the body a bounded
    /// slice and PARK it when the slice is spent: execution stops quietly
    /// and the caller's own budget is untouched. Documented divergence:
    /// parked background tasks never resume.
    public func callBackgroundClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue {
        let entrySteps = steps
        let slice = 20_000
        steps = max(0, stepBudget - slice)
        defer { steps = entrySteps }
        do {
            let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
            return try callWithArguments(closure, args: args, node: nil)
        } catch let error as RuntimeError where error.budgetTrip {
            return .void // parked
        }
    }

    /// Async-session task bodies share the same bounded evaluator budget but
    /// keep suspension propagation intact. Cancellation is polled before and
    /// after every host await and at every statement/loop boundary.
    func callBackgroundClosureSuspending(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        inheritsAnonymousClosureLexicalExecutor: Bool = true
    ) async throws -> RuntimeValue {
        try await callBackgroundClosureSuspending(
            closure,
            arguments: CallArguments(arguments: arguments.map {
                .init(label: nil, value: $0)
            }),
            inheritsAnonymousClosureLexicalExecutor:
                inheritsAnonymousClosureLexicalExecutor)
    }

    /// Label-preserving counterpart used by a checked physical source-call
    /// command after its copied arguments re-enter the confined evaluator.
    func callBackgroundClosureSuspending(
        _ closure: ClosureValue,
        arguments: CallArguments,
        inheritsAnonymousClosureLexicalExecutor: Bool = true
    ) async throws -> RuntimeValue {
        let entrySteps = steps
        let slice = 20_000
        steps = max(0, stepBudget - slice)
        defer { steps = entrySteps }
        do {
            return try await callWithArgumentsSuspending(
                closure,
                args: arguments,
                node: nil,
                inheritsAnonymousClosureLexicalExecutor:
                    inheritsAnonymousClosureLexicalExecutor)
        } catch let error as RuntimeError where error.budgetTrip {
            return .void
        }
    }

    public func callBuilderClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> [RuntimeValue] {
        let env = Environment(parent: closure.captured)
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        try bindParameters(of: closure, to: args, into: env, node: nil)
        return try collectBuilderViews(closure.body, in: env)
    }

    public func callResultBuilderClosure(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        resultProtocol: String
    ) throws -> [RuntimeValue] {
        let env = Environment(parent: closure.captured)
        let args = CallArguments(arguments: arguments.map {
            .init(label: nil, value: $0)
        })
        try bindParameters(of: closure, to: args, into: env, node: nil)
        return try collectResultBuilderValues(
            closure.body, in: env, resultProtocol: resultProtocol)
    }

    public func resultBuilderClosure(
        _ closure: ClosureValue,
        matchesResultProtocol resultProtocol: String
    ) -> Bool? {
        resultBuilderStatements(
            closure.body,
            conformTo: resultProtocol,
            lexicalOwner: closure.lexicalOwner as? StructSymbol)
    }

    public func withKnownFiniteHostIteration<T>(
        _ operation: () throws -> T
    ) throws -> T {
        try withFiniteIterationSlice(operation)
    }
}
