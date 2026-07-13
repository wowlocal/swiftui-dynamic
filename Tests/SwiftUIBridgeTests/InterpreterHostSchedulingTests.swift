import SwiftInterpreter
import Testing
@testable import SwiftUIBridge

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
