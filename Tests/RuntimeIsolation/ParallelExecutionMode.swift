import SwiftInterpreter

nonisolated func parallelMode() throws -> RuntimeExecutionMode {
    .parallel(try RuntimeParallelismConfiguration(maximumParallelism: 2))
}

@MainActor
func constructBothInterpreterModes() throws {
    _ = Interpreter()
    _ = Interpreter(executionMode: try parallelMode())
}
