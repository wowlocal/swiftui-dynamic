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

/// Stateless opt-in driver for bounded physical work.
///
/// The cooperative interpreter never constructs this driver implicitly.
/// Callers must first project a RuntimeEntry through the checked worker-data
/// boundary, then submit a pure snapshot job. Every active slot owns one real
/// `Task.detached`; cancellation of the structured slot is forwarded to that
/// native task, and the throwing task-group scope drains every slot before
/// returning or throwing.
nonisolated struct RuntimePhysicalWorkerDriver: Sendable {
    let maximumParallelism: Int

    init(maximumParallelism: Int) throws {
        guard maximumParallelism > 0 else {
            throw RuntimePhysicalWorkerDriverError.invalidParallelism(
                maximumParallelism)
        }
        self.maximumParallelism = maximumParallelism
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
                Self.add(jobs[index], at: index, to: &group)
            }

            var nextIndex = initialCount
            var results = Array<RuntimeWorkerValueSnapshot?>(
                repeating: nil, count: jobs.count)
            do {
                while let result = try await group.next() {
                    results[result.index] = result.value
                    if nextIndex < jobs.count {
                        Self.add(jobs[nextIndex], at: nextIndex, to: &group)
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

    private static func add(
        _ job: RuntimePhysicalWorkerJob,
        at index: Int,
        to group: inout ThrowingTaskGroup<IndexedWorkerResult, any Error>
    ) {
        group.addTask(priority: job.priority.nativePriority) {
            IndexedWorkerResult(
                index: index,
                value: try await executeDetached(job))
        }
    }

    private static func executeDetached(
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

private nonisolated struct IndexedWorkerResult: Sendable {
    let index: Int
    let value: RuntimeWorkerValueSnapshot
}
