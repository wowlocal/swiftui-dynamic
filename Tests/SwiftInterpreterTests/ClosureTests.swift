import Testing
@testable import SwiftInterpreter

private func eval(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

@Suite struct ClosureTests {
    @Test func closureCapturesVarByReference() throws {
        let source = """
        var x = 0
        let inc = { x += 1 }
        inc()
        inc()
        x
        """
        #expect(try eval(source).intValue == 2)
    }

    @Test func closureWithTypedParameters() throws {
        let source = """
        let f = { (a: Int) in a * 2 }
        f(3)
        """
        #expect(try eval(source).intValue == 6)
    }

    @Test func closureWithBareParameters() throws {
        let source = """
        let f = { a, b in a + b }
        f(3, 4)
        """
        #expect(try eval(source).intValue == 7)
    }

    @Test func shorthandArguments() throws {
        let source = """
        let g = { $0 + 1 }
        g(4)
        """
        #expect(try eval(source).intValue == 5)
    }

    @Test func trailingClosureBindsToLastParameter() throws {
        let source = """
        func twice(f: () -> Int) -> Int {
            return f() + f()
        }
        twice { 5 }
        """
        #expect(try eval(source).intValue == 10)
    }

    /// Multiple trailing closures on a memberwise init: the unlabeled one
    /// binds to the FIRST unclaimed closure property (SE-0286 forward scan);
    /// later labeled trailing closures claim theirs by name first.
    @Test func multipleTrailingClosuresBindMemberwiseInOrder() throws {
        let source = """
        struct Runner {
            var task: () -> Int
            var fallback: () -> Int
        }
        let r = Runner { 1 } fallback: { 2 }
        r.task() * 10 + r.fallback()
        """
        #expect(try eval(source).intValue == 12)
    }

    @Test func closureAsArgument() throws {
        let source = """
        func apply(n: Int, f: (Int) -> Int) -> Int { f(n) }
        apply(n: 10) { v in v + 1 }
        """
        #expect(try eval(source).intValue == 11)
    }

    @Test func closureCapturesLoopAccumulator() throws {
        let source = """
        var total = 0
        let add = { n in total += n }
        add(1)
        add(2)
        add(3)
        total
        """
        #expect(try eval(source).intValue == 6)
    }

    /// Native Swift 6 strict-concurrency probe: a nested closure that uses
    /// `$local.flag` retains the body-local `@Bindable` storage and writes
    /// through to its observable model (`true`).
    @Test func projectedLocalCaptureKeepsUnderlyingBindableStorage() throws {
        let source = """
        @Observable
        final class Model {
            var flag = false
        }

        func probe() -> Bool {
            let model = Model()
            @Bindable var local = model
            let outer = {
                let inner = {
                    $local.flag.wrappedValue = true
                }
                inner()
            }
            outer()
            return model.flag
        }

        probe()
        """
        #expect(try eval(source).boolValue == true)
    }
}
