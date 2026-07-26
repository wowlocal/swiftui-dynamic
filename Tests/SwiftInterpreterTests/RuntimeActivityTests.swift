import Testing
import SwiftInterpreter

private actor RuntimeActivityGate {
    private(set) var started = false
    private var open = false

    func wait() async {
        started = true
        while !open {
            await Task.yield()
        }
    }

    func release() {
        open = true
    }
}

@Suite("Runtime activity")
struct RuntimeActivityTests {
    @Test
    func ownershipSnapshotTracksTaskUntilQuiescent() async throws {
        let interpreter = Interpreter()
        #expect(interpreter.runtimeActivity.isQuiescent)

        let gate = RuntimeActivityGate()
        interpreter.globals.define(
            "waitForActivityGate",
            .hostFunction(HostFunction(
                name: "waitForActivityGate",
                asyncInvoke: { _, _ in
                    await gate.wait()
                    return .void
                })))

        _ = try await interpreter.runAsync(
            source: """
            Task {
                await waitForActivityGate()
            }
            """,
            completionPolicy: .topLevel)
        for _ in 0..<10_000 {
            if await gate.started {
                break
            }
            await Task.yield()
        }

        let active = interpreter.runtimeActivity
        #expect(await gate.started)
        #expect(!active.isQuiescent)
        #expect(active.activeTaskCount > 0)
        #expect(active.scheduledTaskCount > 0)

        await gate.release()
        for _ in 0..<10_000
        where !interpreter.runtimeActivity.isQuiescent {
            await Task.yield()
        }
        #expect(interpreter.runtimeActivity.isQuiescent)
        #expect(interpreter.runtimeActivity.activeTaskCount == 0)
        #expect(interpreter.runtimeActivity.scheduledTaskCount == 0)
        #expect(interpreter.runtimeActivity.activeHostOperationCount == 0)
        #expect(interpreter.runtimeActivity.activeContinuationCount == 0)
    }
}
