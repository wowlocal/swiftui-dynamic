import Dispatch
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
