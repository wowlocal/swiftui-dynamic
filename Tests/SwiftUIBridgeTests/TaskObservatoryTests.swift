import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct TaskObservatoryTests {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func experimentRunsStructuredConcurrencyAndSleep() async throws {
        let projectRoot = repositoryRoot()
            .appendingPathComponent("Examples/TaskObservatory")
            .path
        let source = ProjectMaterial.mergedSource(at: projectRoot) + """

        @MainActor
        func runTaskObservatoryIntegrationProbe() async -> String {
            let store = TaskObservatoryStore()
            store.start()

            try? await Task.sleep(for: .milliseconds(320))
            store.cancelBeacon()

            while store.isRunning {
                try? await Task.sleep(for: .milliseconds(20))
            }
            while !store.observerTwo.hasPrefix("Received") {
                try? await Task.sleep(for: .milliseconds(10))
            }

            return store.workers[0].phase + ","
                + store.workers[1].phase + ","
                + store.workers[2].phase + ","
                + store.observerOne + ","
                + store.observerTwo + ","
                + store.groupStatus
        }

        await runTaskObservatoryIntegrationProbe()
        """

        let result = try await Interpreter(registry: ViewRegistry()).runAsync(
            source: source,
            lazyTopLevelGlobals: true
        )

        #expect(result.stringValue == "Completed,Cancelled,Completed,"
            + "Received orbit-10,Received orbit-10,"
            + "TaskGroup reduced 4 values into orbit-10")
    }

    @Test func parallelExperimentUsesThreePhysicalConcurrentWrappers()
        async throws
    {
        let projectRoot = repositoryRoot()
            .appendingPathComponent("Examples/TaskObservatory")
            .path
        let source = ProjectMaterial.mergedSource(at: projectRoot) + """

        @MainActor
        func runParallelTaskObservatoryProbe() async -> String {
            let store = TaskObservatoryStore()
            store.start()

            try? await Task.sleep(for: .milliseconds(320))
            store.cancelBeacon()

            while store.isRunning {
                try? await Task.sleep(for: .milliseconds(20))
            }
            while !store.observerTwo.hasPrefix("Received") {
                try? await Task.sleep(for: .milliseconds(10))
            }

            return store.workers[0].phase + ","
                + store.workers[1].phase + ","
                + store.workers[2].phase + ","
                + store.observerOne + ","
                + store.observerTwo + ","
                + store.groupStatus
        }

        await runParallelTaskObservatoryProbe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let result = try await interpreter.runAsync(
            source: source,
            lazyTopLevelGlobals: true)

        #expect(result.stringValue == "Completed,Cancelled,Completed,"
            + "Received orbit-10,Received orbit-10,"
            + "TaskGroup reduced 4 values into orbit-10")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 3)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 3)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
    }

    @Test func hostedRunButtonCompletesItsConcurrencyTree() async throws {
        let projectRoot = repositoryRoot()
            .appendingPathComponent("Examples/TaskObservatory")
            .path
        let source = ProjectMaterial.mergedSource(at: projectRoot)
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        try interpreter.run(source: source, lazyTopLevelGlobals: true)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
            Issue.record("TaskObservatory root did not instantiate")
            return
        }
        let rendered = try ViewRegistry.anyView(
            registry.makeRenderable(instance: instance, interpreter: interpreter))
        let hostingView = NSHostingView(
            rootView: rendered.frame(width: 980, height: 720))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        HeadlessWindowTestLifetime.retain(window)
        defer { HeadlessWindowTestLifetime.retire(window) }
        window.contentView = hostingView
        window.orderFrontRegardless()

        guard case .instance(let store)? = instance.box(for: "store")?.value else {
            Issue.record("TaskObservatory @StateObject store is missing")
            return
        }

        func send(_ type: NSEvent.EventType, at point: NSPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else {
                Issue.record("could not construct a mouse event")
                return
            }
            window.sendEvent(event)
        }
        let runButtonPoint = NSPoint(x: 100, y: 60)
        for _ in 0..<100 {
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            send(.leftMouseDown, at: runButtonPoint)
            send(.leftMouseUp, at: runButtonPoint)
            if store.box(for: "isRunning")?.value.boolValue == true {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.box(for: "isRunning")?.value.boolValue == true,
            "the hosted Run experiment Button must invoke its source action")
        #expect(interpreter.concurrencyRuntime.activeRecordCount > 0,
            "Button-created source tasks must enter the concurrency runtime")

        func workerPhases() -> [String] {
            store.box(for: "workers")?.value.arrayValue?.compactMap { value in
                guard case .instance(let worker) = value else { return nil }
                return worker.box(for: "phase")?.value.stringValue
            } ?? []
        }
        func eventLines() -> [String] {
            store.box(for: "events")?.value.arrayValue?.compactMap { value in
                guard case .instance(let event) = value else { return nil }
                let worker = event.box(for: "worker")?.value.stringValue ?? "-"
                let message = event.box(for: "message")?.value.stringValue ?? "-"
                let lane = event.box(for: "lane")?.value.stringValue ?? "-"
                return "\(worker)|\(message)|\(lane)"
            } ?? []
        }
        for _ in 0..<1_000 {
            let events = eventLines()
            if events.contains(where: { $0.contains("Ephemeris child started") })
                && events.contains(where: { $0.contains("Telemetry child started") })
                && events.contains(where: { $0.contains("Installed cancellation handler") })
                && events.contains(where: { $0.contains("Group child 4 started") }) {
                break
            }
            await Task.yield()
        }
        let enteredEvents = eventLines()
        #expect(enteredEvents.contains { $0.contains("Ephemeris child started") })
        #expect(enteredEvents.contains { $0.contains("Telemetry child started") })
        #expect(enteredEvents.contains { $0.contains("Installed cancellation handler") })
        #expect(enteredEvents.contains { $0.contains("Group child 4 started") })

        for _ in 0..<1_000 {
            if store.box(for: "isRunning")?.value.boolValue == false,
               store.box(for: "observerTwo")?.value.stringValue?.hasPrefix("Received") == true {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.box(for: "isRunning")?.value.boolValue == false)
        #expect(workerPhases() == ["Completed", "Completed", "Completed"])
        #expect(store.box(for: "observerOne")?.value.stringValue
            == "Received orbit-10")
        #expect(store.box(for: "observerTwo")?.value.stringValue
            == "Received orbit-10")
        #expect(store.box(for: "groupStatus")?.value.stringValue
            == "TaskGroup reduced 4 values into orbit-10")

        let events = eventLines()
        func eventIndex(worker: String, fragment: String) -> Int? {
            events.firstIndex {
                $0.hasPrefix(worker + "|") && $0.contains(fragment)
            }
        }
        let atlasCompletion = try #require(eventIndex(
            worker: "Atlas", fragment: "Completed — Joined"))
        for fragment in [
            "Ephemeris child started",
            "Telemetry child started",
            "Ephemeris resumed after Task.sleep",
            "Telemetry resumed after Task.sleep",
        ] {
            let childEvent = try #require(eventIndex(
                worker: "Atlas", fragment: fragment))
            #expect(childEvent < atlasCompletion)
        }
        #expect((1...4).allSatisfy { part in
            eventIndex(worker: "Comet", fragment: "Group child \(part) started")
                != nil
        })
        for worker in ["Atlas", "Beacon", "Comet"] {
            let workerEvents = events.filter { $0.hasPrefix(worker + "|") }
            #expect(!workerEvents.isEmpty)
            #expect(workerEvents.allSatisfy { $0.hasSuffix("|Worker pool") })
        }

        for _ in 0..<1_000
        where !interpreter.scheduledTasks.isEmpty
            || interpreter.concurrencyRuntime.activeRecordCount != 0 {
            await Task.yield()
        }
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
    }
}
