import Testing
@testable import SwiftInterpreter

@Suite("Runtime heap ownership")
struct RuntimeHeapOwnershipTests {
    @Test func interpreterExposesItsActualGlobalStorageRoot() throws {
        let interpreter = Interpreter()

        #expect(interpreter.globals === interpreter.runtimeHeap.globals)
        _ = try interpreter.run(source: "let heapProbe = 42")
        #expect(interpreter.runtimeHeap.globals.lookup("heapProbe")?.intValue == 42)
    }

    @Test func independentInterpretersDoNotShareMutableHeap() throws {
        let first = Interpreter()
        let second = Interpreter()

        #expect(first.runtimeHeap !== second.runtimeHeap)
        _ = try first.run(source: "var isolatedHeapValue = 7")
        #expect(first.globals.lookup("isolatedHeapValue")?.intValue == 7)
        #expect(second.globals.lookup("isolatedHeapValue") == nil)
    }

    @Test func heapLifetimeIsOwnedByInterpreterFacade() throws {
        weak var releasedHeap: RuntimeHeap?
        do {
            var interpreter: Interpreter? = Interpreter()
            releasedHeap = interpreter?.runtimeHeap
            _ = try interpreter?.run(source: "final class Token {}\nToken()")
            #expect(releasedHeap != nil)
            interpreter = nil
        }

        #expect(releasedHeap == nil)
    }
}
