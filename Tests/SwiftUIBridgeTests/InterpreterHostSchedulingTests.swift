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
