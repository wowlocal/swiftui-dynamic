import Testing
@testable import SwiftInterpreter

@Suite("Async execution")
struct AsyncExecutionTests {
    private func stringArray(
        named property: String, in value: RuntimeValue
    ) throws -> [String] {
        guard case .instance(let instance) = value else {
            Issue.record("expected an interpreted instance")
            return []
        }
        return try #require(instance.box(for: property)?.value.arrayValue).compactMap(\.stringValue)
    }

    @Test func runAsyncMatchesNativeTaskOrdering() async throws {
        var nativeEvents: [String] = []
        let nativeTask = Task { @MainActor in
            nativeEvents.append("task")
        }
        nativeEvents.append("sync")
        await nativeTask.value

        let interpreter = Interpreter()
        let state = try await interpreter.runAsync(source: """
        class State { var events = [String]() }
        let state = State()
        let handle = Task { state.events.append("task") }
        state.events.append("sync")
        state
        """)

        #expect(try stringArray(named: "events", in: state) == nativeEvents)
        guard case .host(let any)? = interpreter.globals.lookup("handle"),
              let handle = any as? RuntimeTaskHandle else {
            Issue.record("Task should return a runtime task handle")
            return
        }
        #expect(handle.state == .succeeded)
        #expect(handle.isCompleted)
    }

    @Test func cancellationBeforeStartMatchesNativeTask() async throws {
        var nativeRan = false
        let nativeTask = Task { @MainActor in
            await Task.yield()
            if !Task.isCancelled { nativeRan = true }
        }
        nativeTask.cancel()
        await nativeTask.value

        let interpreter = Interpreter()
        let state = try await interpreter.runAsync(source: """
        class State { var ran = false }
        let state = State()
        let handle = Task { state.ran = true }
        handle.cancel()
        state
        """)

        guard case .instance(let instance) = state else {
            Issue.record("expected an interpreted State")
            return
        }
        #expect(instance.box(for: "ran")?.value.boolValue == nativeRan)
        guard case .host(let any)? = interpreter.globals.lookup("handle"),
              let handle = any as? RuntimeTaskHandle else {
            Issue.record("Task should return a runtime task handle")
            return
        }
        #expect(handle.state == .cancelled)
        #expect(handle.isCancelled)
        #expect(handle.isCompleted)
    }

    @Test func runAsyncWaitsForDescendantTasks() async throws {
        let interpreter = Interpreter()
        let state = try await interpreter.runAsync(source: """
        class State { var events = [String]() }
        let state = State()
        Task {
            state.events.append("parent")
            Task { state.events.append("child") }
        }
        state.events.append("sync")
        state
        """)

        #expect(try stringArray(named: "events", in: state) == ["sync", "parent", "child"])
    }

    @Test func synchronousRunRetainsInlineTaskCompatibility() throws {
        let interpreter = Interpreter()
        let state = try interpreter.run(source: """
        class State { var events = [String]() }
        let state = State()
        Task { state.events.append("task") }
        state.events.append("sync")
        state
        """)

        #expect(try stringArray(named: "events", in: state) == ["task", "sync"])
    }

    @Test func synchronousRunBoundsRecursivelyCreatedTasks() throws {
        let interpreter = Interpreter()
        let state = try interpreter.run(source: """
        class State { var events = [String]() }
        let state = State()
        Task {
            state.events.append("parent")
            Task { state.events.append("child") }
        }
        state
        """)

        #expect(try stringArray(named: "events", in: state) == ["parent"])
    }

    @Test func completedSessionsReleaseSchedulerTracking() async throws {
        let interpreter = Interpreter()

        _ = try await interpreter.runAsync(source: "Task { _ = 1 }")
        #expect(interpreter.scheduledTasks.isEmpty)
        _ = try await interpreter.runAsync(source: "Task { _ = 2 }")
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func runtimeTaskHandleDispatchesCancellableExtensions() throws {
        let interpreter = Interpreter()
        let result = try interpreter.run(source: """
        protocol Cancellable {}
        extension Cancellable {
            func lifecycleName() -> String { "cancellable" }
        }
        let handle = Task {}
        handle.lifecycleName()
        """)

        #expect(result.stringValue == "cancellable")
    }

    @Test func cancelledEvaluationThrowsCancellationError() async {
        let interpreter = Interpreter()
        let evaluation = Task { @MainActor in
            try await interpreter.runAsync(source: "while true { _ = 1 + 1 }")
        }
        evaluation.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await evaluation.value
        }
    }
}
