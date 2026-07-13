import Testing
@testable import SwiftInterpreter

@Suite("Task suspension diagnostics")
struct TaskSuspensionDiagnosticsTests {
    @Test
    func taskReadsWithoutAwaitNeverReturnPlaceholders() async {
        for member in ["value", "result"] {
            let interpreter = Interpreter()
            interpreter.globals.define(
                "parityYield", .hostFunction(HostFunction(
                    name: "parityYield",
                    asyncInvoke: { arguments, _ in
                        await Task.yield()
                        return arguments.positional(0) ?? .nilValue
                    }
                )))

            do {
                let value = try await interpreter.runAsync(source: """
                let missingAwaitHandle = Task {
                    await parityYield("value")
                }
                missingAwaitHandle.\(member)
                """)
                Issue.record(
                    "Task.\(member) without await returned \(value.stringified)")
            } catch let error as RuntimeError {
                #expect(error.message == "Task.\(member) requires await")
            } catch {
                Issue.record("unexpected Task.\(member) error: \(error)")
            }

            #expect(interpreter.scheduledTasks.isEmpty)
            #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        }
    }
}
