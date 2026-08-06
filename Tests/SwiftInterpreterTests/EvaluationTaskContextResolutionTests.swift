import Testing
@testable import SwiftInterpreter

/// Every evaluated AST node resolved its owning `EvaluationTaskContext` once
/// per piece of bookkeeping rather than once per node: the step budget's get
/// and set, the nesting depth's get and set, its two reads in the stack-probe
/// condition, the nesting guard, the deferred decrement's get and set, and the
/// stack bounds each read `evaluationTaskContext` independently — ten
/// resolutions per node. That getter is a `@TaskLocal` read plus a weak load
/// of the context's concurrency runtime, and it fell through to a `lazy`
/// stored property whose initialization check carries exclusivity enforcement
/// — all to re-derive a value that provably cannot change inside a
/// synchronous function.
///
/// The pins assert the STRUCTURE — resolutions counted against the interpreter's
/// own step count — rather than a duration, so machine load cannot turn them
/// red. `Interpreter.evaluate(_:in:)` was the hottest named frame in a profile
/// of the IceCubes trending-timeline capture, with the task-context getter and
/// the lazy fallback among the hottest leaves inside it.
@Suite("Evaluation task context resolution")
struct EvaluationTaskContextResolutionTests {
    /// The class itself, as a ceiling over one FIXED program so the pin is a
    /// pure count with no timing in it. This exact source resolved the owning
    /// context 15611 times before the fix and 3430 after it — both measured,
    /// the RED by reverting the evaluator while keeping this counter. The
    /// ceiling sits between the two, and — like the R2 floors — it ratchets
    /// DOWN only: measure below it and tighten it in the same commit.
    ///
    /// `steps` is deliberately NOT the denominator. `withFiniteIterationSlice`
    /// resets it per loop element, so it reads 8 for this program and would
    /// make the ratio meaningless.
    @Test func perNodeEvaluationResolvesOwningContextOncePerNode() throws {
        let interpreter = Interpreter()
        let result = try interpreter.run(source: """
        var total = 0
        for i in 0..<120 {
            total = total + (i * 3) - 1
        }
        total
        """)

        // Native-verified: `swiftc -O` on this same snippet prints 21300.
        #expect(result.intValue == 21300)
        #expect(
            interpreter.evaluationTaskContextResolutions <= 3500,
            """
            resolved the owning task context \
            \(interpreter.evaluationTaskContextResolutions) times \
            (ceiling 3500, was 15611 before the per-node read-once fix)
            """)
    }

    /// The control that keeps the fix from being "resolve it once and cache
    /// it on the interpreter": a context is per-SOURCE-TASK, so an awaiting
    /// program must still observe its own. Two interleaved source tasks
    /// sharing one interpreter must each see their own step accounting.
    @Test func suspendingEvaluationStillResolvesItsOwnContext() async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: """
        func work(_ n: Int) async -> Int {
            var total = 0
            for i in 0..<n {
                total = total + i
            }
            return total
        }
        async let a = work(40)
        async let b = work(40)
        await a + b
        """)

        // Native-verified: `swiftc -O` on this same snippet prints 1560.
        #expect(result.intValue == 1560)
    }
}
