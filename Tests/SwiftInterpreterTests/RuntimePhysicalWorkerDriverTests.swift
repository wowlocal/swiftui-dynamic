import Synchronization
import Testing
@testable import SwiftInterpreter

@Suite("Runtime physical worker driver")
nonisolated struct RuntimePhysicalWorkerDriverTests {
    @Test func boundedJobsPhysicallyOverlapAndPreserveInputOrder() async throws {
        let capabilities = try await Self.makeIndexedCapabilities(0..<3)
        let gate = PhysicalWorkerBatchGate()
        let jobs = capabilities.map { capability in
            RuntimePhysicalWorkerJob(capability: capability) { capability in
                gate.entered.wrappingAdd(
                    1, ordering: .acquiringAndReleasing)
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !gate.release.load(ordering: .acquiring) {
                    guard ContinuousClock.now < deadline else {
                        throw PhysicalWorkerProbeError.deadline
                    }
                }
                return capability.bindings[0].value
            }
        }
        let driver = try RuntimePhysicalWorkerDriver(maximumParallelism: 2)

        let execution = Task.detached {
            try await driver.execute(jobs)
        }
        #expect(await waitUntil {
            gate.entered.load(ordering: .acquiring) == 2
        })
        try await Task.sleep(for: .milliseconds(100))
        #expect(gate.entered.load(ordering: .acquiring) == 2,
            "a third job crossed the configured two-worker bound")
        gate.release.store(true, ordering: .releasing)

        let output = try await execution.value
        #expect(gate.entered.load(ordering: .acquiring) == 3)
        #expect(output == [.int(0), .int(1), .int(2)])
    }

    @Test func cancellingExecutionCancelsTheDetachedWorker() async throws {
        let capability = try await Self.makeEmptyCapability()
        let probe = PhysicalWorkerCancellationProbe()
        let job = RuntimePhysicalWorkerJob(capability: capability) { _ in
            probe.started.store(true, ordering: .releasing)
            do {
                try await Task.sleep(for: .seconds(30))
                return .void
            } catch is CancellationError {
                probe.observedCancellation.store(true, ordering: .releasing)
                throw CancellationError()
            }
        }
        let driver = try RuntimePhysicalWorkerDriver(maximumParallelism: 1)
        let execution = Task.detached {
            try await driver.execute([job])
        }

        #expect(await waitUntil {
            probe.started.load(ordering: .acquiring)
        })
        execution.cancel()
        await #expect(throws: CancellationError.self) {
            try await execution.value
        }
        #expect(await waitUntil {
            probe.observedCancellation.load(ordering: .acquiring)
        })
    }

    @Test func sourceKernelExecutionPreservesCooperativeCallerCancellation()
        async throws
    {
        let capability = try await Self.makeEmptyCapability()
        let gate = PhysicalWorkerSourceCancellationGate()
        let job = RuntimePhysicalWorkerJob(capability: capability) { _ in
            .int(23)
        }
        let sourceJob = RuntimePhysicalSourceKernelJob(
            workerJob: job, cancellationBehavior: .unobserved)
        let driver = try RuntimePhysicalWorkerDriver(maximumParallelism: 1)
        let execution = Task.detached {
            gate.callerEntered.store(true, ordering: .releasing)
            while !gate.releaseCaller.load(ordering: .acquiring) {
                await Task.yield()
            }
            return try await driver.executeSourceKernel(sourceJob)
        }

        #expect(await waitUntil {
            gate.callerEntered.load(ordering: .acquiring)
        })
        execution.cancel()
        gate.releaseCaller.store(true, ordering: .releasing)

        #expect(try await execution.value == .int(23))
        #expect(execution.isCancelled)
    }

    @Test func cancellationObservingSourceKernelEntersBeforeThrowing()
        async throws
    {
        let capability = try await Self.makeEmptyCapability()
        let gate = PhysicalWorkerSourceCancellationGate()
        let probe = PhysicalWorkerCancellationProbe()
        let job = RuntimePhysicalWorkerJob(capability: capability) { _ in
            probe.started.store(true, ordering: .releasing)
            do {
                try await Task.sleep(for: .seconds(30))
                return .void
            } catch is CancellationError {
                probe.observedCancellation.store(
                    true, ordering: .releasing)
                throw CancellationError()
            }
        }
        let sourceJob = RuntimePhysicalSourceKernelJob(
            workerJob: job, cancellationBehavior: .observed)
        let driver = try RuntimePhysicalWorkerDriver(maximumParallelism: 1)
        let execution = Task.detached {
            gate.callerEntered.store(true, ordering: .releasing)
            while !gate.releaseCaller.load(ordering: .acquiring) {
                await Task.yield()
            }
            return try await driver.executeSourceKernel(sourceJob)
        }

        #expect(await waitUntil {
            gate.callerEntered.load(ordering: .acquiring)
        })
        execution.cancel()
        gate.releaseCaller.store(true, ordering: .releasing)

        await #expect(throws: CancellationError.self) {
            try await execution.value
        }
        let started = probe.started.load(ordering: .acquiring)
        let observedCancellation = probe.observedCancellation.load(
            ordering: .acquiring)
        #expect(started)
        #expect(observedCancellation)
    }

    @Test func workerFailureCancelsSiblingAndDrainsTheBatch() async throws {
        let capability = try await Self.makeEmptyCapability()
        let probe = PhysicalWorkerFailureProbe()
        let sibling = RuntimePhysicalWorkerJob(capability: capability) { _ in
            probe.siblingStarted.store(true, ordering: .releasing)
            do {
                try await Task.sleep(for: .seconds(30))
                return .void
            } catch is CancellationError {
                probe.siblingCancelled.store(true, ordering: .releasing)
                throw CancellationError()
            }
        }
        let failure = RuntimePhysicalWorkerJob(capability: capability) { _ in
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !probe.failureGate.load(ordering: .acquiring) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw PhysicalWorkerProbeError.deadline
                }
                await Task.yield()
            }
            throw PhysicalWorkerProbeError.expectedFailure
        }
        let driver = try RuntimePhysicalWorkerDriver(maximumParallelism: 2)
        let execution = Task.detached {
            try await driver.execute([sibling, failure])
        }

        #expect(await waitUntil {
            probe.siblingStarted.load(ordering: .acquiring)
        })
        probe.failureGate.store(true, ordering: .releasing)
        await #expect(throws: PhysicalWorkerProbeError.expectedFailure) {
            try await execution.value
        }
        #expect(await waitUntil {
            probe.siblingCancelled.load(ordering: .acquiring)
        })
    }

    @Test func invalidWorkerBoundFailsClosed() {
        #expect(throws: RuntimePhysicalWorkerDriverError.invalidParallelism(0)) {
            try RuntimePhysicalWorkerDriver(maximumParallelism: 0)
        }
        #expect(throws: RuntimePhysicalWorkerDriverError.invalidParallelism(-1)) {
            try RuntimePhysicalWorkerDriver(maximumParallelism: -1)
        }
    }

    @Test func completedBatchReleasesOperationCaptures() async throws {
        let capability = try await Self.makeEmptyCapability()
        let driver = try RuntimePhysicalWorkerDriver(maximumParallelism: 1)
        weak var releasedSentinel: PhysicalWorkerLifetimeSentinel?

        do {
            let sentinel = PhysicalWorkerLifetimeSentinel()
            releasedSentinel = sentinel
            let job = RuntimePhysicalWorkerJob(
                capability: capability
            ) { [sentinel] _ in
                _ = sentinel
                return .void
            }
            #expect(try await driver.execute([job]) == [.void])
        }

        #expect(releasedSentinel == nil)
        #expect(try await driver.execute([]).isEmpty)
    }

    @Test func concurrentBatchesShareOneGlobalWorkerBound() async throws {
        let capabilities = try await Self.makeIndexedCapabilities(0..<4)
        let gate = PhysicalWorkerBatchGate()
        let jobs = capabilities.map { capability in
            RuntimePhysicalWorkerJob(capability: capability) { capability in
                gate.entered.wrappingAdd(
                    1, ordering: .acquiringAndReleasing)
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !gate.release.load(ordering: .acquiring) {
                    guard ContinuousClock.now < deadline else {
                        throw PhysicalWorkerProbeError.deadline
                    }
                }
                return capability.bindings[0].value
            }
        }
        let driver = try RuntimePhysicalWorkerDriver(maximumParallelism: 2)

        let first = Task.detached {
            try await driver.execute(Array(jobs[0..<2]))
        }
        let second = Task.detached {
            try await driver.execute(Array(jobs[2..<4]))
        }
        #expect(await waitUntil {
            gate.entered.load(ordering: .acquiring) >= 2
        })
        try await Task.sleep(for: .milliseconds(100))
        #expect(gate.entered.load(ordering: .acquiring) == 2,
            "concurrent batches crossed the driver's global worker bound")
        gate.release.store(true, ordering: .releasing)

        let firstOutput = try await first.value
        let secondOutput = try await second.value
        let output = firstOutput + secondOutput
        #expect(output == [.int(0), .int(1), .int(2), .int(3)])
    }

    @Test func cancellingAQueuedBatchRemovesItsPermitWaiter() async throws {
        let capability = try await Self.makeEmptyCapability()
        let gate = PhysicalWorkerBatchGate()
        let queuedStarted = Atomic<Bool>(false)
        let blocking = RuntimePhysicalWorkerJob(
            capability: capability
        ) { _ in
            gate.entered.wrappingAdd(1, ordering: .acquiringAndReleasing)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !gate.release.load(ordering: .acquiring) {
                guard ContinuousClock.now < deadline else {
                    throw PhysicalWorkerProbeError.deadline
                }
            }
            return .void
        }
        let queued = RuntimePhysicalWorkerJob(capability: capability) { _ in
            queuedStarted.store(true, ordering: .releasing)
            return .void
        }
        let driver = try RuntimePhysicalWorkerDriver(maximumParallelism: 1)
        let first = Task.detached {
            try await driver.execute([blocking])
        }
        #expect(await waitUntil {
            gate.entered.load(ordering: .acquiring) == 1
        })
        let second = Task.detached {
            try await driver.execute([queued])
        }
        await Task.yield()
        second.cancel()
        await #expect(throws: CancellationError.self) {
            try await second.value
        }
        let startedBeforeRelease = queuedStarted.load(ordering: .acquiring)
        #expect(!startedBeforeRelease)

        gate.release.store(true, ordering: .releasing)
        #expect(try await first.value == [.void])
        try await Task.sleep(for: .milliseconds(20))
        let startedAfterRelease = queuedStarted.load(ordering: .acquiring)
        #expect(!startedAfterRelease,
            "a cancelled permit waiter ran after capacity became available")
    }

    private static func makeEmptyCapability() async throws
        -> RuntimeWorkerCapability
    {
        try await MainActor.run {
            let interpreter = Interpreter()
            let entry = interpreter.concurrencyRuntime.createEntry(kind: .test)
            return try entry.makeWorkerCapability(copying: [])
        }
    }

    private static func makeIndexedCapabilities(
        _ indices: Range<Int>
    ) async throws -> [RuntimeWorkerCapability] {
        try await MainActor.run {
            let interpreter = Interpreter()
            let entry = interpreter.concurrencyRuntime.createEntry(kind: .test)
            return try indices.map { index in
                try entry.makeWorkerCapability(copying: [
                    .init(name: "index", value: .native(index)),
                ])
            }
        }
    }
}

private nonisolated enum PhysicalWorkerProbeError: Error, Equatable {
    case deadline
    case expectedFailure
}

private nonisolated final class PhysicalWorkerBatchGate: Sendable {
    let entered = Atomic<Int>(0)
    let release = Atomic<Bool>(false)
}

private nonisolated final class PhysicalWorkerCancellationProbe: Sendable {
    let started = Atomic<Bool>(false)
    let observedCancellation = Atomic<Bool>(false)
}

private nonisolated final class PhysicalWorkerSourceCancellationGate: Sendable {
    let callerEntered = Atomic<Bool>(false)
    let releaseCaller = Atomic<Bool>(false)
}

private nonisolated final class PhysicalWorkerFailureProbe: Sendable {
    let siblingStarted = Atomic<Bool>(false)
    let siblingCancelled = Atomic<Bool>(false)
    let failureGate = Atomic<Bool>(false)
}

private nonisolated final class PhysicalWorkerLifetimeSentinel: Sendable {}

private nonisolated func waitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() {
        guard ContinuousClock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}
