import Foundation
import SwiftUI

@MainActor
final class TaskObservatoryStore: ObservableObject {
    @Published var workers: [WorkerSnapshot] = []
    @Published var events: [TaskEvent] = []
    @Published var observerOne = "Waiting to run"
    @Published var observerTwo = "Waiting to run"
    @Published var groupStatus = "Task group is idle"
    @Published var isRunning = false
    @Published var canCancelWorker = false

    private var generation = 0
    private var sequence = 0
    private var finishedWorkers = 0
    private var atlasTask: Task<Void, Never>?
    private var beaconTask: Task<Void, Never>?
    private var cometTask: Task<String, Never>?
    private var observerTasks: [Task<Void, Never>] = []

    init() {
        resetDashboard()
    }

    func start() {
        cancelTasks()
        generation += 1
        let run = generation
        sequence = 0
        finishedWorkers = 0
        events = []
        observerOne = "Waiting for Comet.value"
        observerTwo = "Waiting for Comet.value"
        groupStatus = "Four group children are ready to launch"
        isRunning = true
        canCancelWorker = true
        resetWorkers()

        appendEvent(
            worker: "Root",
            message: "Created prioritized tasks and structured child scopes",
            lane: executionLane(),
            color: .purple
        )

        atlasTask = Task.detached(priority: .userInitiated) {
            await self.runAsyncLetWorker(
                id: 0,
                run: run
            )
        }

        beaconTask = Task.detached(priority: .utility) {
            await self.runCancellableWorker(
                id: 1,
                steps: 6,
                delay: 240,
                run: run
            )
        }

        let shared = Task.detached(priority: .background) {
            await self.runTaskGroupWorker(
                id: 2,
                parts: 4,
                run: run
            )
        }
        cometTask = shared

        let firstObserver = Task(priority: .high) {
            let value = await shared.value
            self.completeObserver(number: 1, value: value, run: run)
        }

        let secondObserver = Task(priority: .utility) {
            let value = await shared.value
            self.completeObserver(number: 2, value: value, run: run)
        }
        observerTasks = [firstObserver, secondObserver]
    }

    func cancelBeacon() {
        guard canCancelWorker else { return }
        canCancelWorker = false
        appendEvent(worker: "Beacon", message: "Cancellation requested", lane: executionLane(), color: .orange)
        beaconTask?.cancel()
    }

    func reset() {
        cancelTasks()
        generation += 1
        resetDashboard()
    }

    private func cancelTasks() {
        atlasTask?.cancel()
        beaconTask?.cancel()
        cometTask?.cancel()
        for task in observerTasks {
            task.cancel()
        }
        atlasTask = nil
        beaconTask = nil
        cometTask = nil
        observerTasks = []
    }

    private func resetDashboard() {
        sequence = 0
        finishedWorkers = 0
        events = []
        observerOne = "Waiting to run"
        observerTwo = "Waiting to run"
        groupStatus = "Task group is idle"
        isRunning = false
        canCancelWorker = false
        resetWorkers()
    }

    private func resetWorkers() {
        workers = [
            WorkerSnapshot(
                id: 0,
                name: "Atlas",
                symbol: "cpu",
                color: .blue,
                primitive: "async let × 2",
                priority: "userInitiated",
                phase: "Ready",
                detail: "Two structured child bindings",
                lane: "Not scheduled",
                progress: 0
            ),
            WorkerSnapshot(
                id: 1,
                name: "Beacon",
                symbol: "antenna.radiowaves.left.and.right",
                color: .orange,
                primitive: "cancellation handler",
                priority: "utility",
                phase: "Ready",
                detail: "Cancellable Task.sleep loop",
                lane: "Not scheduled",
                progress: 0
            ),
            WorkerSnapshot(
                id: 2,
                name: "Comet",
                symbol: "sparkles",
                color: .purple,
                primitive: "TaskGroup × 4",
                priority: "background",
                phase: "Ready",
                detail: "Shared group reduction",
                lane: "Not scheduled",
                progress: 0
            )
        ]
    }

    @concurrent
    nonisolated func runAsyncLetWorker(id: Int, run: Int) async {
        await updateWorker(
            id: id,
            phase: "Running",
            detail: "Created two async-let children",
            progress: 0,
            lane: executionLane(),
            run: run
        )

        async let ephemeris = runAsyncLetSlice(
            id: id,
            name: "Ephemeris",
            delay: 520,
            run: run
        )
        async let telemetry = runAsyncLetSlice(
            id: id,
            name: "Telemetry",
            delay: 780,
            run: run
        )

        let first = await ephemeris
        await updateWorker(
            id: id,
            phase: "Running",
            detail: "Awaited \(first); Telemetry may still run",
            progress: 0.5,
            lane: executionLane(),
            run: run
        )
        let second = await telemetry

        if Task.isCancelled {
            await finishWorker(
                id: id,
                phase: "Cancelled",
                detail: "async-let children inherited cancellation",
                lane: executionLane(),
                run: run
            )
        } else {
            await finishWorker(
                id: id,
                phase: "Completed",
                detail: "Joined \(first) + \(second)",
                lane: executionLane(),
                run: run
            )
        }
    }

    @concurrent
    nonisolated func runAsyncLetSlice(
        id: Int,
        name: String,
        delay: Int64,
        run: Int
    ) async -> String {
        await recordWorkerEvent(
            id: id,
            message: "\(name) child started",
            lane: executionLane(),
            run: run
        )

        do {
            await recordWorkerEvent(
                id: id,
                message: "\(name) sleeping for \(delay) ms",
                lane: executionLane(),
                run: run
            )
            try await Task.sleep(for: .milliseconds(delay))
            try Task.checkCancellation()
        } catch {
            await recordWorkerEvent(
                id: id,
                message: "\(name) observed cancellation",
                lane: executionLane(),
                run: run
            )
            return name + " cancelled"
        }

        await recordWorkerEvent(
            id: id,
            message: "\(name) resumed after Task.sleep",
            lane: executionLane(),
            run: run
        )
        await Task.yield()
        return name
    }

    @concurrent
    nonisolated func runCancellableWorker(
        id: Int,
        steps: Int,
        delay: Int64,
        run: Int
    ) async {
        await updateWorker(
            id: id,
            phase: "Running",
            detail: "Installed cancellation handler",
            progress: 0,
            lane: executionLane(),
            run: run
        )

        let completed = await withTaskCancellationHandler(operation: {
            for step in 1...steps {
                await self.updateWorker(
                    id: id,
                    phase: "Suspended",
                    detail: "Task.sleep before heartbeat \(step)",
                    progress: Double(step - 1) / Double(steps),
                    lane: self.executionLane(),
                    run: run
                )

                do {
                    try await Task.sleep(for: .milliseconds(delay))
                    try Task.checkCancellation()
                } catch {
                    await self.recordWorkerEvent(
                        id: id,
                        message: "Task.sleep threw after cancellation",
                        lane: self.executionLane(),
                        run: run
                    )
                    return false
                }

                await self.updateWorker(
                    id: id,
                    phase: "Running",
                    detail: "Heartbeat \(step) delivered",
                    progress: Double(step) / Double(steps),
                    lane: self.executionLane(),
                    run: run
                )
                await Task.yield()
            }
            return true
        }, onCancel: {
            Task {
                await self.cancellationHandlerFired(id: id, run: run)
            }
        })

        await finishWorker(
            id: id,
            phase: completed ? "Completed" : "Cancelled",
            detail: completed
                ? "All heartbeats delivered"
                : "Cancellation handler interrupted sleep",
            lane: executionLane(),
            run: run
        )
    }

    @concurrent
    nonisolated func runTaskGroupWorker(
        id: Int,
        parts: Int,
        run: Int
    ) async -> String {
        await updateWorker(
            id: id,
            phase: "Running",
            detail: "Adding \(parts) TaskGroup children",
            progress: 0,
            lane: executionLane(),
            run: run
        )

        let checksum = await withTaskGroup(of: Int.self) { group in
            for part in 1...parts {
                group.addTask(priority: .utility) {
                    await self.recordWorkerEvent(
                        id: id,
                        message: "Group child \(part) started",
                        lane: self.executionLane(),
                        run: run
                    )

                    do {
                        let delay = Int64(160 + part * 120)
                        await self.recordWorkerEvent(
                            id: id,
                            message: "Child \(part) sleeping for \(delay) ms",
                            lane: self.executionLane(),
                            run: run
                        )
                        try await Task.sleep(for: .milliseconds(delay))
                        try Task.checkCancellation()
                    } catch {
                        await self.recordWorkerEvent(
                            id: id,
                            message: "Group child \(part) cancelled",
                            lane: self.executionLane(),
                            run: run
                        )
                        return 0
                    }

                    await self.recordWorkerEvent(
                        id: id,
                        message: "Group child \(part) produced a value",
                        lane: self.executionLane(),
                        run: run
                    )
                    return part
                }
            }

            var total = 0
            for completion in 1...parts {
                let part = await group.next() ?? 0
                total += part
                await self.updateWorker(
                    id: id,
                    phase: "Running",
                    detail: "group.next() received part \(part)",
                    progress: Double(completion) / Double(parts),
                    lane: self.executionLane(),
                    run: run
                )
            }
            return total
        }

        if Task.isCancelled {
            await finishWorker(
                id: id,
                phase: "Cancelled",
                detail: "Parent cancellation reached the task group",
                lane: executionLane(),
                run: run
            )
            return "cancelled"
        }

        let value = "orbit-\(checksum)"
        await finishWorker(
            id: id,
            phase: "Completed",
            detail: "Reduced group result: \(value)",
            lane: executionLane(),
            run: run
        )
        await completeGroup(value: value, parts: parts, run: run)
        return value
    }

    nonisolated func executionLane() -> String {
        Thread.isMainThread ? "Main thread" : "Worker pool"
    }

    private func updateWorker(
        id: Int,
        phase: String,
        detail: String,
        progress: Double,
        lane: String,
        run: Int
    ) {
        guard run == generation else { return }
        var worker = workers[id]
        worker.phase = phase
        worker.detail = detail
        worker.progress = progress
        worker.lane = lane
        workers[id] = worker
        appendEvent(worker: worker.name, message: phase + " — " + detail, lane: lane, color: worker.color)
    }

    private func finishWorker(
        id: Int,
        phase: String,
        detail: String,
        lane: String,
        run: Int
    ) {
        guard run == generation else { return }
        var worker = workers[id]
        worker.phase = phase
        worker.detail = detail
        worker.progress = phase == "Completed" ? 1 : worker.progress
        worker.lane = lane
        workers[id] = worker
        finishedWorkers += 1
        if id == 1 {
            canCancelWorker = false
        }
        appendEvent(worker: worker.name, message: phase + " — " + detail, lane: lane, color: worker.color)
        if finishedWorkers == workers.count {
            isRunning = false
            appendEvent(worker: "Root", message: "All child tasks reached a terminal state", lane: executionLane(), color: .green)
        }
    }

    private func recordWorkerEvent(
        id: Int,
        message: String,
        lane: String,
        run: Int
    ) {
        guard run == generation else { return }
        let worker = workers[id]
        appendEvent(
            worker: worker.name,
            message: message,
            lane: lane,
            color: worker.color
        )
    }

    private func cancellationHandlerFired(id: Int, run: Int) {
        guard run == generation else { return }
        recordWorkerEvent(
            id: id,
            message: "onCancel handler fired",
            lane: executionLane(),
            run: run
        )
    }

    private func completeGroup(value: String, parts: Int, run: Int) {
        guard run == generation else { return }
        groupStatus = "TaskGroup reduced \(parts) values into \(value)"
    }

    private func completeObserver(number: Int, value: String, run: Int) {
        guard run == generation else { return }
        if number == 1 {
            observerOne = "Received \(value)"
        } else {
            observerTwo = "Received \(value)"
        }
        appendEvent(worker: "Waiter \(number)", message: "Resumed from Comet.value", lane: executionLane(), color: .pink)
    }

    private func appendEvent(worker: String, message: String, lane: String, color: Color) {
        sequence += 1
        events.append(TaskEvent(sequence: sequence, worker: worker, message: message, lane: lane, color: color))
        if events.count > 80 {
            events.removeFirst()
        }
    }
}
