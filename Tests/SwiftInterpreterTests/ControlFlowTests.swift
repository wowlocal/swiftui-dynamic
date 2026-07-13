import Testing
@testable import SwiftInterpreter

private func eval(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

@Suite struct ControlFlowTests {
    @Test func ifElse() throws {
        let source = """
        func sign(n: Int) -> Int {
            if n > 0 {
                return 1
            } else if n < 0 {
                return -1
            } else {
                return 0
            }
        }
        sign(n: -5)
        """
        #expect(try eval(source).intValue == -1)
    }

    @Test func ifAsStatementMutating() throws {
        let source = """
        var x = 0
        if true {
            x = 5
        }
        x
        """
        #expect(try eval(source).intValue == 5)
    }

    @Test func whileLoop() throws {
        let source = """
        var sum = 0
        var i = 1
        while i <= 4 {
            sum += i
            i += 1
        }
        sum
        """
        #expect(try eval(source).intValue == 10)
    }

    @Test func forInRange() throws {
        let source = """
        var s = 0
        for i in 0..<5 {
            s += i
        }
        s
        """
        #expect(try eval(source).intValue == 10)
    }

    @Test func forInClosedRange() throws {
        let source = """
        var s = 0
        for i in 1...3 {
            s += i
        }
        s
        """
        #expect(try eval(source).intValue == 6)
    }

    @Test func forInArray() throws {
        let source = """
        var joined = ""
        for name in ["a", "b", "c"] {
            joined += name
        }
        joined
        """
        #expect(try eval(source).stringValue == "abc")
    }

    @Test func switchCastPatternsRejectUnrelatedSourceTypes() throws {
        let source = """
        protocol Action {}
        enum Actions {
            struct Load: Action { let amount: Int }
            struct Reset: Action {}
        }

        func classify(_ action: Action) -> String {
            switch action {
            case let load as Actions.Load:
                return "load \\(load.amount)"
            case _ as Actions.Reset:
                return "reset"
            default:
                return "other"
            }
        }

        "\\(classify(Actions.Load(amount: 3)))|\\(classify(Actions.Reset()))"
        """
        #expect(try eval(source).stringValue == "load 3|reset")
    }

    @Test func breakAndContinue() throws {
        let source = """
        var s = 0
        for i in 0..<10 {
            if i == 3 {
                continue
            }
            if i == 6 {
                break
            }
            s += i
        }
        s
        """
        // 0+1+2+4+5 = 12
        #expect(try eval(source).intValue == 12)
    }

    @Test func infiniteLoopHitsStepBudget() throws {
        do {
            _ = try eval("while true { }")
            Issue.record("expected the step budget to trip")
        } catch let e as RuntimeError {
            #expect(e.message.contains("budget"))
        }
    }

    @Test func nestedFiniteLoopsReceiveBoundedPerIterationSlices() throws {
        let source = """
        var count = 0
        for _ in 0..<400 {
            for _ in 0..<400 {
                count += 1
            }
        }
        count
        """
        #expect(try eval(source).intValue == 160_000)

        do {
            _ = try eval("for _ in 0..<1 { while true { } }")
            Issue.record("expected an infinite element body to trip the budget")
        } catch let error as RuntimeError {
            #expect(error.message.contains("budget"))
        }
    }

    @Test func largeMaterializedLoopDoesNotImitateInfiniteWork() throws {
        let source = """
        var count = 0
        for _ in 0..<120_000 { count += 1 }
        count
        """
        #expect(try eval(source).intValue == 120_000)
    }

    @Test func preparedIntegerLoopsPreserveImageStatisticsSemantics() throws {
        let nativeBytes = (0..<4_096).map { ($0 * 37 + 11) & 255 }
        let interpreter = Interpreter()
        interpreter.globals.define(
            "bytes", .native(nativeBytes.map(RuntimeValue.native)))

        let result = try #require(try interpreter.run(source: """
        var checksum = 17
        var redTotal = 0
        var greenTotal = 0
        var blueTotal = 0
        var minimumLuma = 255
        var maximumLuma = 0
        var sampledTotal = 0
        var pixel = 0

        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let blue = Int(bytes[offset + 2])
            redTotal += red
            greenTotal += green
            blueTotal += blue
            let luma = (red * 54 + green * 183 + blue * 19) / 256
            minimumLuma = min(minimumLuma, luma)
            maximumLuma = max(maximumLuma, luma)
            if pixel % 97 == 0 {
                sampledTotal += red << 16 | green << 8 | blue
            }
            pixel += 1
        }

        for byte in bytes {
            checksum = (checksum * 31 + Int(byte)) % 1_000_003
        }
        (checksum, redTotal, greenTotal, blueTotal,
         minimumLuma, maximumLuma, sampledTotal, pixel)
        """).tupleValue)

        var expectedChecksum = 17
        var expectedRed = 0
        var expectedGreen = 0
        var expectedBlue = 0
        var expectedMinimumLuma = 255
        var expectedMaximumLuma = 0
        var expectedSampledTotal = 0
        var expectedPixel = 0
        for offset in stride(from: 0, to: nativeBytes.count, by: 4) {
            let red = nativeBytes[offset]
            let green = nativeBytes[offset + 1]
            let blue = nativeBytes[offset + 2]
            expectedRed += red
            expectedGreen += green
            expectedBlue += blue
            let luma = (red * 54 + green * 183 + blue * 19) / 256
            expectedMinimumLuma = min(expectedMinimumLuma, luma)
            expectedMaximumLuma = max(expectedMaximumLuma, luma)
            if expectedPixel % 97 == 0 {
                expectedSampledTotal += red << 16 | green << 8 | blue
            }
            expectedPixel += 1
        }
        for byte in nativeBytes {
            expectedChecksum = (expectedChecksum * 31 + byte) % 1_000_003
        }

        #expect(result.values.compactMap(\.intValue) == [
            expectedChecksum, expectedRed, expectedGreen, expectedBlue,
            expectedMinimumLuma, expectedMaximumLuma,
            expectedSampledTotal, expectedPixel,
        ])
        #expect(interpreter.preparedFiniteLoopPlanCount == 2)
    }

    @Test func preparedLoopPropagatesContinueBreakAndBudgetFailures() throws {
        let interpreter = Interpreter()
        let value = try interpreter.run(source: """
        var total = 0
        for value in 0..<1_000 {
            if value % 17 == 0 { continue }
            if value == 900 { break }
            total += value
        }
        total
        """)
        let expected = (0..<900).filter { $0 % 17 != 0 }.reduce(0, +)
        #expect(value.intValue == expected)
        #expect(interpreter.preparedFiniteLoopPlanCount == 1)

        let runaway = Interpreter()
        do {
            _ = try runaway.run(source: """
            for value in 0..<300 {
                if value == 0 { while true {} }
            }
            """)
            Issue.record("expected an infinite prepared-loop branch to trip the budget")
        } catch let error as RuntimeError {
            #expect(error.message.contains("budget"))
        }
        #expect(runaway.preparedFiniteLoopPlanCount == 1)
    }

    @Test func preparedLoopRefreshesCollectionsAfterFallbackExecution() throws {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "bytes", .native([3, 4, 5].map(RuntimeValue.native)))

        let tuple = try #require(try interpreter.run(source: """
        var total = 0
        for index in 0..<300 {
            if index == 100 {
                bytes[0] = 9
            }
            total += Int(bytes[0])
        }
        (total, Int(bytes[0]))
        """).tupleValue)

        #expect(tuple.values.compactMap(\.intValue) == [2_100, 9])
        #expect(interpreter.preparedFiniteLoopPlanCount == 1)
    }

    @Test func observedIntegerWritesRemainOnTheOrdinaryEvaluatorPath() throws {
        let interpreter = Interpreter()
        interpreter.globals.define("observedTotal", .native(0))
        var notificationCount = 0
        interpreter.globals.box(for: "observedTotal")?.onChange = {
            notificationCount += 1
        }

        let value = try interpreter.run(source: """
        for value in 0..<300 {
            observedTotal += value
        }
        observedTotal
        """)

        #expect(value.intValue == 44_850)
        #expect(notificationCount == 300)
        #expect(interpreter.preparedFiniteLoopPlanCount == 0)
    }

    @Test func loopsWithCapturesKeepFreshIterationBindings() throws {
        let interpreter = Interpreter()
        let tuple = try #require(try interpreter.run(source: """
        var callbacks: [() -> Int] = []
        for value in 0..<300 {
            callbacks.append({ value })
        }
        (callbacks[0](), callbacks[299]())
        """).tupleValue)
        #expect(tuple.values.compactMap(\.intValue) == [0, 299])
        #expect(interpreter.preparedFiniteLoopPlanCount == 0)
    }

    @Test func preparedLoopsRespectShadowedCoreFunctions() throws {
        let interpreter = Interpreter()
        let value = try interpreter.run(source: """
        func min(_ lhs: Int, _ rhs: Int) -> Int { 42 }
        var total = 0
        for value in 0..<300 {
            total += min(value, 1)
        }
        total
        """)
        #expect(value.intValue == 12_600)
        #expect(interpreter.preparedFiniteLoopPlanCount == 0)
    }

    @Test func asyncSessionsSharePreparedFiniteLoopSemantics() async throws {
        let interpreter = Interpreter()
        let value = try await interpreter.runAsync(source: """
        var checksum = 17
        for byte in 0..<10_000 {
            checksum = (checksum * 31 + byte) % 1_000_003
        }
        checksum
        """)
        var expected = 17
        for byte in 0..<10_000 {
            expected = (expected * 31 + byte) % 1_000_003
        }
        #expect(value.intValue == expected)
        #expect(interpreter.preparedFiniteLoopPlanCount == 1)
    }

    @Test func strideSequencesUseNativeBoundsAndDirection() throws {
        let source = """
        var forward: [Int] = []
        for value in stride(from: 0, to: 10, by: 3) { forward.append(value) }
        var backward: [Int] = []
        for value in stride(from: 5, through: -1, by: -2) { backward.append(value) }
        (forward, backward)
        """
        let tuple = try #require(try eval(source).tupleValue)
        #expect(tuple.values[0].arrayValue?.compactMap(\.intValue) == [0, 3, 6, 9])
        #expect(tuple.values[1].arrayValue?.compactMap(\.intValue) == [5, 3, 1, -1])
    }

    @Test func runawayRecursionIsAFatalLocatedError() throws {
        // WHICH guard trips (call-depth counter vs native stack probe)
        // depends on per-frame stack cost; the INVARIANT is a fatal,
        // located stop either way.
        do {
            _ = try eval("func f() -> Int { return f() }\nf()")
            Issue.record("expected the depth guard to trip")
        } catch let e as RuntimeError {
            #expect(e.message.contains("call depth") || e.message.contains("nesting exceeded"))
            #expect(e.fatal)
        }
        // Self-recursive computed properties too.
        do {
            _ = try eval("struct S { var x: Int { x } }\nS().x")
            Issue.record("expected the depth guard to trip")
        } catch let e as RuntimeError {
            #expect(e.message.contains("call depth") || e.message.contains("nesting exceeded"))
            #expect(e.fatal)
        }
    }

    @Test func nestedFunctionAndRecursion() throws {
        let source = """
        func fib(n: Int) -> Int {
            if n < 2 {
                return n
            }
            return fib(n: n - 1) + fib(n: n - 2)
        }
        fib(n: 10)
        """
        #expect(try eval(source).intValue == 55)
    }
}
