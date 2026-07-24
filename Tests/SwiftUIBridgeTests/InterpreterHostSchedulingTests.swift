import Dispatch
import Foundation
import SwiftInterpreter
import Testing
@testable import SwiftUIBridge

private final class NativeQueueRecorder: @unchecked Sendable {
    nonisolated(unsafe) var fired = false
}

@Suite(.serialized) struct InterpreterHostSchedulingTests {
    @Test func deliveryPolicyBelongsToEachRegistry() {
        let interactive = Interpreter(registry: ViewRegistry())
        let testHarness = Interpreter(registry: ViewRegistry(
            mainQueueDeliveryMode: .deterministicDrain
        ))
        let headless = Interpreter(registry: TraceRegistry())

        #expect(MainQueueDrain.deliveryMode(for: interactive) == .wallClock)
        #expect(MainQueueDrain.deliveryMode(for: testHarness) == .deterministicDrain)
        #expect(MainQueueDrain.deliveryMode(for: headless) == .deterministicDrain)
    }

    /// Nuke's ImagePipeline owns a labeled serial DispatchQueue and starts
    /// every request by submitting a closure to that queue. The callback
    /// capability belongs to every constructed queue, not only `.main`.
    @Test func constructedDispatchQueuesDeliverAsyncCallbacks() throws {
        let nativeRecorder = NativeQueueRecorder()
        let nativeQueue = DispatchQueue(label: "native-parity-queue")
        nativeQueue.async { nativeRecorder.fired = true }
        nativeQueue.sync {} // serial FIFO fence
        #expect(nativeRecorder.fired)

        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: """
        final class Recorder {
            var fired = false
        }
        let recorder = Recorder()
        let queue = DispatchQueue(label: "interpreted-queue")
        queue.async {
            recorder.fired = true
        }
        """)
        MainQueueDrain.drain()
        guard case .instance(let recorder)? = interpreter.globals.lookup(
            "recorder") else {
            Issue.record("recorder missing")
            return
        }
        #expect(recorder.box(for: "fired")?.value.boolValue == true)
    }

    /// A retained view lifecycle callback is an external host callback, so a
    /// Task created by it must own a real async runtime session. The operation
    /// can then suspend while a constructed queue retains and later resumes an
    /// unsafe continuation, matching the reusable image-pipeline shape.
    @Test func liveCheckLifecycleTasksCanSuspendThroughConstructedQueues() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(source: """
        @Observable
        final class Loader {
            var phase = "pending"

            func start() {
                Task {
                    do {
                        let value: String = try await withUnsafeThrowingContinuation {
                            continuation in
                            let queue = DispatchQueue(
                                label: "interpreted-async-loader",
                                qos: .userInitiated)
                            queue.async {
                                continuation.resume(with: .success("loaded"))
                            }
                        }
                        phase = value
                    } catch {
                        phase = "failed"
                    }
                }
            }
        }

        struct ContentView: View {
            @State private var loader = Loader()

            var body: some View {
                Text(loader.phase)
                    .onAppear { loader.start() }
            }
        }
        """)

        #expect(strings.contains("loaded"), "rendered strings: \(strings)")
    }

    /// Generated modifier metadata distinguishes an async lifecycle action
    /// from a synchronous callback. The headless verifier must preserve that
    /// property so a `.task` body enters the suspending evaluator directly.
    @Test func liveCheckAsyncLifecycleUsesSwiftUITaskRuntime() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(source: """
        @Observable
        final class Loader {
            var phase = "pending"

            func load() async {
                phase = await withTaskGroup(of: String.self) { group in
                    group.addTask { "loaded" }
                    return await group.next() ?? "missing"
                }
            }
        }

        struct ContentView: View {
            @State private var loader = Loader()

            var body: some View {
                Text(loader.phase)
                    .task { await loader.load() }
            }
        }
        """)

        #expect(strings.contains("loaded"), "rendered strings: \(strings)")
    }

    /// EmojiText uses the complete generated `task(id:priority:_:)` row.
    /// Its priority argument must not erase the async closure property at the
    /// headless lifecycle boundary.
    @Test func liveCheckPrioritizedAsyncLifecycleUsesSwiftUITaskRuntime() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(source: """
        @Observable
        final class Loader {
            var phase = "pending"

            func load() async {
                phase = await withTaskGroup(of: String.self) { group in
                    group.addTask { "loaded" }
                    return await group.next() ?? "missing"
                }
            }
        }

        struct ContentView: View {
            @State private var loader = Loader()

            var body: some View {
                Text(loader.phase)
                    .task(id: 1, priority: .high) {
                        await loader.load()
                    }
            }
        }
        """)

        #expect(strings.contains("loaded"), "rendered strings: \(strings)")
    }

    /// Foundation exposes queue submission and the operation lifecycle in its
    /// SDK symbol graph. An interpreted Operation subclass must retain that
    /// native scheduling boundary instead of becoming an inert host object.
    @Test func operationQueuesStartInterpretedOperations() throws {
        let nativeRecorder = NativeQueueRecorder()
        let nativeQueue = OperationQueue()
        let nativeOperation = BlockOperation {
            nativeRecorder.fired = true
        }
        #expect(!nativeOperation.isCancelled)
        nativeQueue.addOperation(nativeOperation)
        nativeQueue.waitUntilAllOperationsAreFinished()
        #expect(nativeRecorder.fired)

        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: """
        import Foundation

        final class Recorder {
            var fired = false
        }
        final class DeferredOperation: Foundation.Operation {
            let action: () -> Void

            init(_ action: @escaping () -> Void) {
                self.action = action
            }

            override func start() {
                guard !isCancelled else { return }
                action()
            }
        }
        let recorder = Recorder()
        let queue = OperationQueue()
        queue.addOperation(DeferredOperation {
            recorder.fired = true
        })
        """)
        MainQueueDrain.drain()
        guard case .instance(let recorder)? = interpreter.globals.lookup(
            "recorder") else {
            Issue.record("recorder missing")
            return
        }
        #expect(recorder.box(for: "fired")?.value.boolValue == true)
    }

    /// A Scheduler's closure-taking submission cannot execute an interpreted
    /// closure on an arbitrary physical worker. It joins the registry's
    /// callback delivery queue, retaining submission order and actor safety.
    @Test func operationQueueClosuresUseInterpreterDeliveryOrder() throws {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: """
        import Foundation

        final class Recorder {
            var events: [String] = []
        }

        let recorder = Recorder()
        let queue = OperationQueue()
        queue.addOperation {
            recorder.events.append("first")
        }
        queue.addOperation {
            recorder.events.append("second")
        }
        """)
        guard case .instance(let recorder)? = interpreter.globals.lookup(
            "recorder") else {
            Issue.record("recorder missing")
            return
        }
        #expect(recorder.box(for: "events")?.value.arrayValue?.isEmpty == true)

        MainQueueDrain.drain()

        #expect(
            recorder.box(for: "events")?.value.arrayValue?
                .compactMap(\.stringValue)
                == ["first", "second"])
    }

    /// Nuke combines host-extension overloads, a nested function alias, and a
    /// source subclass whose unqualified name matches its Foundation base.
    /// The selected overload must still submit the source instance so its
    /// interpreted `start()` override runs.
    @Test func nestedAliasSchedulerKeepsSourceSubclassIdentity() throws {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: """
        import Foundation

        final class Recorder {
            var fired = false
        }

        final class Operation: Foundation.Operation, @unchecked Sendable {
            typealias Starter = @Sendable (
                _ finish: @Sendable @escaping () -> Void
            ) -> Void

            let starter: Starter

            init(starter: @escaping Starter) {
                self.starter = starter
            }

            override func start() {
                starter({})
            }
        }

        extension OperationQueue {
            func add(
                _ action: @Sendable @escaping () -> Void
            ) -> BlockOperation {
                let operation = BlockOperation(block: action)
                addOperation(operation)
                return operation
            }

            func add(_ starter: @escaping Operation.Starter) -> Operation {
                let operation = Operation(starter: starter)
                addOperation(operation)
                return operation
            }
        }

        let recorder = Recorder()
        let queue = OperationQueue()
        _ = queue.add { finish in
            recorder.fired = true
            finish()
        }
        """)
        MainQueueDrain.drain()
        guard case .instance(let recorder)? = interpreter.globals.lookup(
            "recorder") else {
            Issue.record("recorder missing")
            return
        }
        #expect(recorder.box(for: "fired")?.value.boolValue == true)
    }

    /// Nuke's `OperationQueue.add(_:)` block overload constructs the
    /// Foundation `BlockOperation` subclass, then submits that value through
    /// the generated `Operation` parameter. Native Foundation accepts the
    /// subclass and runs its block; imported inheritance must remain visible
    /// at the generated overload boundary.
    @Test func importedHostSubclassMatchesGeneratedSuperclassParameter() throws {
        let nativeRecorder = NativeQueueRecorder()
        let nativeQueue = OperationQueue()
        let nativeOperation = BlockOperation {
            nativeRecorder.fired = true
        }
        nativeQueue.addOperation(nativeOperation)
        nativeQueue.waitUntilAllOperationsAreFinished()
        #expect(nativeRecorder.fired)

        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: """
        import Foundation

        final class Recorder {
            var fired = false
        }

        extension OperationQueue {
            func add(
                _ action: @Sendable @escaping () -> Void
            ) -> BlockOperation {
                let operation = BlockOperation(block: action)
                addOperation(operation)
                return operation
            }
        }

        let recorder = Recorder()
        let queue = OperationQueue()
        _ = queue.add {
            recorder.fired = true
        }
        """)
        guard case .instance(let recorder)? = interpreter.globals.lookup(
            "recorder") else {
            Issue.record("recorder missing")
            return
        }
        #expect(recorder.box(for: "fired")?.value.boolValue == false)

        MainQueueDrain.drain()

        #expect(recorder.box(for: "fired")?.value.boolValue == true)
    }

    /// A generated scheduler may be an inert platform value (an opposite-
    /// platform fallback or a source value materialized without native
    /// backing). Its interface-derived lifecycle adapter still owns source
    /// operations; only the native SDK invocation depends on receiver payload.
    @Test func inertGeneratedSchedulerStartsInterpretedLifecycle() throws {
        let nativeRecorder = NativeQueueRecorder()
        let nativeQueue = OperationQueue()
        nativeQueue.addOperation(BlockOperation {
            nativeRecorder.fired = true
        })
        nativeQueue.waitUntilAllOperationsAreFinished()
        #expect(nativeRecorder.fired)

        let registry = TraceRegistry()
        let interpreter = Interpreter(registry: registry)
        try interpreter.run(source: """
        import Foundation

        final class Recorder {
            var fired = false
        }

        final class DeferredOperation: Foundation.Operation {
            let action: () -> Void

            init(_ action: @escaping () -> Void) {
                self.action = action
            }

            override func start() {
                action()
            }
        }

        let recorder = Recorder()
        let operation = DeferredOperation {
            recorder.fired = true
        }
        """)

        let scheduler = GeneratedPlatformValue(
            framework: "Foundation",
            typeName: "OperationQueue",
            isValueType: false,
            payload: nil)
        let member = try #require(
            registry.hostMember("addOperation", on: scheduler))
        guard case .hostFunction(let addOperation) = member else {
            Issue.record("generated addOperation gateway missing")
            return
        }
        let operation = try #require(interpreter.globals.lookup("operation"))
        _ = try addOperation.invoke(
            CallArguments(arguments: [
                .init(label: nil, value: operation)
            ]),
            interpreter)

        MainQueueDrain.drain()
        guard case .instance(let recorder)? = interpreter.globals.lookup(
            "recorder") else {
            Issue.record("recorder missing")
            return
        }
        #expect(recorder.box(for: "fired")?.value.boolValue == true)
    }

    @Test func viewRegistryWallClockDeliverySurvivesHeadlessReset() async throws {
        let source = """
        final class Recorder {
            var fired = false
        }
        let recorder = Recorder()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
            recorder.fired = true
        }
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        guard case .instance(let recorder)? = interpreter.globals.lookup("recorder") else {
            Issue.record("recorder missing")
            return
        }

        // Resetting a separate headless environment must neither deliver nor
        // cancel this interactive registry's host timer.
        HeadlessVerifier.resetBridgeEnvironment()
        MainQueueDrain.drain()
        #expect(recorder.box(for: "fired")?.value.boolValue == false)

        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.box(for: "fired")?.value.boolValue == true)
    }
}
