import Foundation
import SwiftUI

@MainActor
final class TaskObservatoryStore: ObservableObject {
    @Published var workers: [WorkerSnapshot] = []
    @Published var events: [TaskEvent] = []
    @Published var observerOne = "Waiting to run"
    @Published var observerTwo = "Waiting to run"
    @Published var isRunning = false
    @Published var canCancelWorker = false

    private var generation = 0
    private var sequence = 0
    private var finishedWorkers = 0
    private var atlasTask: Task<Void, Never>?
    private var beaconTask: Task<Void, Never>?
    private var cometTask: Task<String, Never>?

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
        isRunning = true
        canCancelWorker = true
        resetWorkers()

        appendEvent(worker: "Root", message: "Created three detached tasks", lane: executionLane(), color: .purple)

        atlasTask = Task.detached {
            await self.runWorker(
                id: 0,
                steps: 5,
                delay: 220_000_000,
                run: run
            )
        }

        beaconTask = Task.detached {
            await self.runWorker(
                id: 1,
                steps: 6,
                delay: 300_000_000,
                run: run
            )
        }

        let shared = Task.detached {
            await self.runSharedWorker(
                id: 2,
                steps: 4,
                delay: 380_000_000,
                run: run
            )
        }
        cometTask = shared

        Task.detached {
            let value = await shared.value
            await self.completeObserver(number: 1, value: value, run: run)
        }

        Task.detached {
            let value = await shared.value
            await self.completeObserver(number: 2, value: value, run: run)
        }
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
        atlasTask = nil
        beaconTask = nil
        cometTask = nil
    }

    private func resetDashboard() {
        sequence = 0
        finishedWorkers = 0
        events = []
        observerOne = "Waiting to run"
        observerTwo = "Waiting to run"
        isRunning = false
        canCancelWorker = false
        resetWorkers()
    }

    private func resetWorkers() {
        workers = [
            WorkerSnapshot(id: 0, name: "Atlas", symbol: "cpu", color: .blue, phase: "Ready", detail: "5 work slices", lane: "Not scheduled", progress: 0),
            WorkerSnapshot(id: 1, name: "Beacon", symbol: "antenna.radiowaves.left.and.right", color: .orange, phase: "Ready", detail: "Cancellable worker", lane: "Not scheduled", progress: 0),
            WorkerSnapshot(id: 2, name: "Comet", symbol: "sparkles", color: .purple, phase: "Ready", detail: "Shared result producer", lane: "Not scheduled", progress: 0)
        ]
    }

    @concurrent
    nonisolated func runWorker(id: Int, steps: Int, delay: UInt64, run: Int) async {
        await updateWorker(id: id, phase: "Running", detail: "Entered task body", progress: 0, lane: executionLane(), run: run)

        for step in 1...steps {
            await updateWorker(id: id, phase: "Suspended", detail: "Sleeping before slice \(step)", progress: Double(step - 1) / Double(steps), lane: executionLane(), run: run)

            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                await finishWorker(id: id, phase: "Cancelled", detail: "Sleep exited with cancellation", lane: executionLane(), run: run)
                return
            }

            await updateWorker(id: id, phase: "Running", detail: "Finished slice \(step)", progress: Double(step) / Double(steps), lane: executionLane(), run: run)
            await Task.yield()
        }

        await finishWorker(id: id, phase: "Completed", detail: "All work slices finished", lane: executionLane(), run: run)
    }

    @concurrent
    nonisolated func runSharedWorker(id: Int, steps: Int, delay: UInt64, run: Int) async -> String {
        await updateWorker(id: id, phase: "Running", detail: "Producing shared value", progress: 0, lane: executionLane(), run: run)

        for step in 1...steps {
            await updateWorker(id: id, phase: "Suspended", detail: "Computing part \(step)", progress: Double(step - 1) / Double(steps), lane: executionLane(), run: run)

            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                await finishWorker(id: id, phase: "Cancelled", detail: "Shared producer cancelled", lane: executionLane(), run: run)
                return "cancelled"
            }

            await updateWorker(id: id, phase: "Running", detail: "Published part \(step)", progress: Double(step) / Double(steps), lane: executionLane(), run: run)
            await Task.yield()
        }

        await finishWorker(id: id, phase: "Completed", detail: "Result: orbit-42", lane: executionLane(), run: run)
        return "orbit-42"
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
        if events.count > 40 {
            events.removeFirst()
        }
    }
}
