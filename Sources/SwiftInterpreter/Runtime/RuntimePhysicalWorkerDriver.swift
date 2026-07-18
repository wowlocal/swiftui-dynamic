/// Configuration failures are values rather than preconditions so an opt-in
/// host cannot crash itself while selecting a worker bound.
nonisolated enum RuntimePhysicalWorkerDriverError: Error, Sendable, Equatable {
    case invalidParallelism(Int)
}

/// A finite snapshot kernel owns one worker permit until completion. A source
/// call that immediately hops to a confined executor relinquishes the permit
/// at that hop so an indefinitely suspended MainActor method (FoodTruck's
/// updates loop) cannot starve unrelated physical kernels.
nonisolated enum RuntimePhysicalSourcePermitLifetime: Sendable {
    case operation
    case untilConfinedExecutorEntry(RuntimePhysicalSourceExecutorHandoff)
}

/// One-shot synchronization between the detached wrapper, its confined
/// executor relay, and the bounded worker driver. Completion also opens the
/// gate so a validation failure before executor entry cannot leak a permit.
actor RuntimePhysicalSourceExecutorHandoff {
    private var mayReleasePermit = false
    private var waiter: CheckedContinuation<Void, Never>?

    func reachedConfinedExecutor() {
        open()
    }

    func completed() {
        open()
    }

    func waitUntilPermitMayBeReleased() async {
        guard !mayReleasePermit else { return }
        await withCheckedContinuation { continuation in
            precondition(waiter == nil)
            waiter = continuation
        }
    }

    private func open() {
        guard !mayReleasePermit else { return }
        mayReleasePermit = true
        waiter?.resume()
        waiter = nil
    }
}

/// One pure job accepted by the physical-worker boundary.
///
/// Both input and output use checked-Sendable snapshots. The operation may
/// capture other Sendable helpers, but it cannot receive an Interpreter,
/// RuntimeHeap, RuntimeProgramState, RuntimeValue, or evaluator context from
/// this API.
nonisolated struct RuntimePhysicalWorkerJob: Sendable {
    typealias Operation = @Sendable (
        RuntimeWorkerCapability
    ) async throws -> RuntimeWorkerValueSnapshot

    let capability: RuntimeWorkerCapability
    let priority: RuntimeTaskPriority
    let operation: Operation

    init(
        capability: RuntimeWorkerCapability,
        priority: RuntimeTaskPriority = .medium,
        operation: @escaping Operation
    ) {
        precondition(capability.accessManifest.isWorkerSafe)
        self.capability = capability
        self.priority = priority
        self.operation = operation
    }
}

/// Opt-in driver for bounded physical work. Copies share one permit pool, so
/// the configured limit applies across every concurrently submitted batch.
///
/// The cooperative interpreter never constructs this driver implicitly.
/// Callers must first project a RuntimeEntry through the checked worker-data
/// boundary, then submit a pure snapshot job. Every active slot owns one real
/// `Task.detached`; cancellation of the structured slot is forwarded to that
/// native task, and the throwing task-group scope drains every slot before
/// returning or throwing.
nonisolated struct RuntimePhysicalWorkerDriver: Sendable {
    let maximumParallelism: Int
    private let permits: RuntimePhysicalWorkerPermitPool

    init(maximumParallelism: Int) throws {
        guard maximumParallelism > 0 else {
            throw RuntimePhysicalWorkerDriverError.invalidParallelism(
                maximumParallelism)
        }
        self.maximumParallelism = maximumParallelism
        permits = RuntimePhysicalWorkerPermitPool(
            maximumParallelism: maximumParallelism)
    }

    init(configuration: RuntimeParallelismConfiguration) {
        maximumParallelism = configuration.maximumParallelism
        permits = RuntimePhysicalWorkerPermitPool(
            maximumParallelism: configuration.maximumParallelism)
    }

    /// Execute at most `maximumParallelism` jobs simultaneously and return
    /// successful snapshots in input order. The first observed failure exits
    /// the batch; structured cancellation reaches every detached worker, and
    /// scope exit waits for their cleanup.
    func execute(
        _ jobs: [RuntimePhysicalWorkerJob]
    ) async throws -> [RuntimeWorkerValueSnapshot] {
        guard !jobs.isEmpty else { return [] }

        return try await withThrowingTaskGroup(
            of: IndexedWorkerResult.self,
            returning: [RuntimeWorkerValueSnapshot].self
        ) { group in
            let initialCount = min(maximumParallelism, jobs.count)
            for index in 0..<initialCount {
                add(jobs[index], at: index, to: &group)
            }

            var nextIndex = initialCount
            var results = Array<RuntimeWorkerValueSnapshot?>(
                repeating: nil, count: jobs.count)
            do {
                while let result = try await group.next() {
                    results[result.index] = result.value
                    if nextIndex < jobs.count {
                        add(jobs[nextIndex], at: nextIndex, to: &group)
                        nextIndex += 1
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }

            return results.enumerated().map { index, result in
                guard let result else {
                    preconditionFailure(
                        "physical worker batch omitted result \(index)")
                }
                return result
            }
        }
    }

    /// Execute one finite source kernel without turning a source task's
    /// cooperative cancellation bit into infrastructure cancellation unless
    /// the admitted source operation itself observes cancellation. Swift still
    /// enters a cancelled non-checking task body and permits it to return a
    /// value; a throwing sleep instead receives the request and throws.
    func executeSourceKernel(
        _ sourceJob: RuntimePhysicalSourceKernelJob
    ) async throws -> RuntimeWorkerValueSnapshot {
        if case .untilConfinedExecutorEntry(let handoff) =
            sourceJob.permitLifetime {
            return try await executeConfinedReentrySourceKernel(
                sourceJob.workerJob,
                handoff: handoff)
        }
        switch sourceJob.cancellationBehavior {
        case .unobserved:
            let job = sourceJob.workerJob
            let execution = Task.detached(
                priority: job.priority.nativePriority
            ) {
                try await execute([job])
            }
            return try await Self.onlySourceSnapshot(
                from: execution.value)
        case .observed:
            return try await executeCancellationObservingSourceKernel(
                sourceJob.workerJob)
        }
    }

    /// Launch the source wrapper from an uncancelled infrastructure task,
    /// hold one worker permit only through its physical prefix, then release
    /// that permit as soon as the operation reaches its confined executor.
    /// The detached task itself remains alive and publishes the copied result
    /// after the MainActor method completes.
    private func executeConfinedReentrySourceKernel(
        _ job: RuntimePhysicalWorkerJob,
        handoff: RuntimePhysicalSourceExecutorHandoff
    ) async throws -> RuntimeWorkerValueSnapshot {
        let execution = Task.detached(priority: job.priority.nativePriority) {
            try await Self.executeConfinedReentryDetached(
                job,
                permits: permits,
                handoff: handoff)
        }
        return try await execution.value
    }

    private static func executeConfinedReentryDetached(
        _ job: RuntimePhysicalWorkerJob,
        permits: RuntimePhysicalWorkerPermitPool,
        handoff: RuntimePhysicalSourceExecutorHandoff
    ) async throws -> RuntimeWorkerValueSnapshot {
        try await permits.acquire()
        let sourceTask = Task.detached(priority: job.priority.nativePriority) {
            do {
                let value = try await job.operation(job.capability)
                await handoff.completed()
                return value
            } catch {
                await handoff.completed()
                throw error
            }
        }
        await handoff.waitUntilPermitMayBeReleased()
        await permits.release()
        return try await sourceTask.value
    }

    /// Infrastructure acquires capacity independently from source
    /// cancellation, then attaches that request to the actual detached source
    /// worker. This preserves Swift's rule that a pre-cancelled unstructured
    /// operation still enters and observes cancellation inside Task.sleep.
    private func executeCancellationObservingSourceKernel(
        _ job: RuntimePhysicalWorkerJob
    ) async throws -> RuntimeWorkerValueSnapshot {
        let cancellation = RuntimePhysicalSourceCancellationRelay()
        let execution = Task.detached(priority: job.priority.nativePriority) {
            try await Self.executeCancellationObservingDetached(
                job, permits: permits, cancellation: cancellation)
        }
        return try await withTaskCancellationHandler {
            if Task.isCancelled {
                await cancellation.requestCancellation()
            }
            return try await execution.value
        } onCancel: {
            Task { await cancellation.requestCancellation() }
        }
    }

    private static func onlySourceSnapshot(
        from output: [RuntimeWorkerValueSnapshot]
    ) throws -> RuntimeWorkerValueSnapshot {
        guard let snapshot = output.first else {
            throw RuntimeError(message:
                "physical source kernel returned no result")
        }
        return snapshot
    }

    private func add(
        _ job: RuntimePhysicalWorkerJob,
        at index: Int,
        to group: inout ThrowingTaskGroup<IndexedWorkerResult, any Error>
    ) {
        group.addTask(priority: job.priority.nativePriority) {
            IndexedWorkerResult(
                index: index,
                value: try await Self.executeDetached(
                    job, permits: permits))
        }
    }

    private static func executeDetached(
        _ job: RuntimePhysicalWorkerJob,
        permits: RuntimePhysicalWorkerPermitPool
    ) async throws -> RuntimeWorkerValueSnapshot {
        try await permits.acquire()
        do {
            let value = try await runDetached(job)
            await permits.release()
            return value
        } catch {
            await permits.release()
            throw error
        }
    }

    private static func runDetached(
        _ job: RuntimePhysicalWorkerJob
    ) async throws -> RuntimeWorkerValueSnapshot {
        let task = Task.detached(priority: job.priority.nativePriority) {
            try Task.checkCancellation()
            return try await job.operation(job.capability)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func executeCancellationObservingDetached(
        _ job: RuntimePhysicalWorkerJob,
        permits: RuntimePhysicalWorkerPermitPool,
        cancellation: RuntimePhysicalSourceCancellationRelay
    ) async throws -> RuntimeWorkerValueSnapshot {
        try await permits.acquire()
        let task = Task.detached(priority: job.priority.nativePriority) {
            try await job.operation(job.capability)
        }
        await cancellation.attach(task)
        do {
            let value = try await task.value
            await cancellation.finish()
            await permits.release()
            return value
        } catch {
            await cancellation.finish()
            await permits.release()
            throw error
        }
    }
}

/// Races a source cancellation request with physical-worker attachment without
/// unchecked Sendable storage. A request arriving before attachment is applied
/// immediately when the real source worker is created.
private actor RuntimePhysicalSourceCancellationRelay {
    typealias SourceTask = Task<RuntimeWorkerValueSnapshot, any Error>

    private var cancellationRequested = false
    private var sourceTask: SourceTask?

    func attach(_ task: SourceTask) {
        precondition(sourceTask == nil)
        sourceTask = task
        if cancellationRequested {
            task.cancel()
        }
    }

    func requestCancellation() {
        cancellationRequested = true
        sourceTask?.cancel()
    }

    func finish() {
        sourceTask = nil
    }
}

/// FIFO permits are shared by every batch submitted through one driver. A
/// cancelled waiter is removed and resumed immediately, so it cannot consume
/// a later permit or retain its job until unrelated work finishes.
private actor RuntimePhysicalWorkerPermitPool {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let maximumParallelism: Int
    private var available: Int
    private var nextWaiterID: UInt64 = 1
    private var waiters: [Waiter] = []

    init(maximumParallelism: Int) {
        precondition(maximumParallelism > 0)
        self.maximumParallelism = maximumParallelism
        available = maximumParallelism
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }

        let id = nextWaiterID
        nextWaiterID &+= 1
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(
                    id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        guard granted else { throw CancellationError() }
        // Once release() transfers a permit to this waiter, the caller owns
        // that permit and must reach executeDetached's release path. A second
        // cancellation check here could throw before that path and leak the
        // slot. runDetached observes already-requested cancellation and its
        // surrounding catch returns the permit.
    }

    func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: true)
            return
        }
        available += 1
        precondition(available <= maximumParallelism)
    }

    private func cancel(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

private nonisolated struct IndexedWorkerResult: Sendable {
    let index: Int
    let value: RuntimeWorkerValueSnapshot
}
