/// Configuration failures are values rather than preconditions so an opt-in
/// host cannot crash itself while selecting a worker bound.
nonisolated enum RuntimePhysicalWorkerDriverError: Error, Sendable, Equatable {
    case invalidParallelism(Int)
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
    /// cooperative cancellation bit into infrastructure cancellation of the
    /// physical job. Swift still enters a cancelled non-checking task body and
    /// permits it to return a value. The surrounding runtime separately
    /// observes session/host abort after this bounded job completes.
    func executeSourceKernel(
        _ job: RuntimePhysicalWorkerJob
    ) async throws -> RuntimeWorkerValueSnapshot {
        let execution = Task.detached(priority: job.priority.nativePriority) {
            try await execute([job])
        }
        let output = try await execution.value
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
