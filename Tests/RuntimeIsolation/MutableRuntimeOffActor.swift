import SwiftInterpreter

nonisolated func illegalMutableRuntimeAccess() {
    _ = RuntimeHeap()
    _ = Interpreter()
    _ = RuntimeValue.native(42)
}
