import SwiftInterpreter

/// XCTest's assertion surface as host functions. XCTAssert* are plain
/// (uppercase) global functions, so resolveIdentifier finds them through the
/// registry constructor table — no interpreter changes needed. Failures are
/// recorded, not thrown, matching XCTest's continue-after-failure default.
///
/// Known MVP divergence: the interpreter evaluates arguments eagerly, so
/// `XCTAssertThrowsError(try f())` propagates f's error before the assertion
/// runs — such tests surface as `errored`, not `failed`.
extension ViewRegistry {
    public func registerXCTestGateways(_ recorder: AssertionRecorder) {
        let message: (CallArguments, Int) -> String = { args, index in
            args.positional(index)?.stringValue.map { " — \($0)" } ?? ""
        }

        constructors["XCTAssertEqual"] = HostFunction(name: "XCTAssertEqual") { args, _ in
            guard let a = args.positional(0), let b = args.positional(1) else { return .void }
            if let accuracy = args.labeled("accuracy")?.doubleValue,
               let x = a.doubleValue, let y = b.doubleValue {
                if abs(x - y) > accuracy {
                    recorder.record("XCTAssertEqual failed: \(a.stringified) != \(b.stringified) ±\(accuracy)\(message(args, 2))")
                }
                return .void
            }
            do {
                if try !Builtins.equalValues(a, b) {
                    recorder.record("XCTAssertEqual failed: \(a.stringified) != \(b.stringified)\(message(args, 2))")
                }
            } catch {
                recorder.record("XCTAssertEqual could not compare: \(error)")
            }
            return .void
        }
        constructors["XCTAssertNotEqual"] = HostFunction(name: "XCTAssertNotEqual") { args, _ in
            guard let a = args.positional(0), let b = args.positional(1) else { return .void }
            do {
                if try Builtins.equalValues(a, b) {
                    recorder.record("XCTAssertNotEqual failed: both are \(a.stringified)\(message(args, 2))")
                }
            } catch {
                recorder.record("XCTAssertNotEqual could not compare: \(error)")
            }
            return .void
        }
        constructors["XCTAssertTrue"] = HostFunction(name: "XCTAssertTrue") { args, _ in
            if args.positional(0)?.boolValue != true {
                recorder.record("XCTAssertTrue failed\(message(args, 1))")
            }
            return .void
        }
        constructors["XCTAssert"] = self.constructors["XCTAssertTrue"]!
        constructors["XCTAssertFalse"] = HostFunction(name: "XCTAssertFalse") { args, _ in
            if args.positional(0)?.boolValue != false {
                recorder.record("XCTAssertFalse failed\(message(args, 1))")
            }
            return .void
        }
        constructors["XCTAssertNil"] = HostFunction(name: "XCTAssertNil") { args, _ in
            if args.positional(0)?.isNil != true {
                recorder.record("XCTAssertNil failed: \(args.positional(0)?.stringified ?? "?")\(message(args, 1))")
            }
            return .void
        }
        constructors["XCTAssertNotNil"] = HostFunction(name: "XCTAssertNotNil") { args, _ in
            if args.positional(0)?.isNil != false {
                recorder.record("XCTAssertNotNil failed\(message(args, 1))")
            }
            return .void
        }
        let comparisons: [(String, String)] = [
            ("XCTAssertGreaterThan", ">"),
            ("XCTAssertGreaterThanOrEqual", ">="),
            ("XCTAssertLessThan", "<"),
            ("XCTAssertLessThanOrEqual", "<="),
        ]
        for (name, op) in comparisons {
            constructors[name] = HostFunction(name: name) { args, _ in
                guard let a = args.positional(0), let b = args.positional(1) else { return .void }
                do {
                    if try Builtins.compareValues(op, a, b).boolValue != true {
                        recorder.record("\(name) failed: \(a.stringified) \(op) \(b.stringified)\(message(args, 2))")
                    }
                } catch {
                    recorder.record("\(name) could not compare: \(error)")
                }
                return .void
            }
        }
        constructors["XCTFail"] = HostFunction(name: "XCTFail") { args, _ in
            recorder.record("XCTFail\(message(args, 0))")
            return .void
        }
        constructors["XCTUnwrap"] = HostFunction(name: "XCTUnwrap") { args, _ in
            guard let value = args.positional(0), !value.isNil else {
                throw RuntimeError(message: "XCTUnwrap failed: found nil")
            }
            return value
        }
        // Eager evaluation means a throwing argument never reaches these;
        // reaching them means the expression completed.
        constructors["XCTAssertNoThrow"] = HostFunction(name: "XCTAssertNoThrow") { _, _ in .void }
        constructors["XCTAssertThrowsError"] = HostFunction(name: "XCTAssertThrowsError") { args, _ in
            recorder.record("XCTAssertThrowsError failed: expression did not throw\(message(args, 1))")
            return .void
        }

        // Swift Testing's macros, executed via the macro-host dispatch (the
        // interpreter hands us evaluated arguments — no expansion involved).
        constructors["#expect"] = HostFunction(name: "#expect") { args, ctx in
            // `#expect(throws: E.self) { body }` — the closure must throw.
            if args.labeled("throws") != nil {
                guard case .closure(let closure)? = args.arguments.first(where: { $0.isTrailing })?.value else {
                    return .void
                }
                do {
                    _ = try ctx.callClosure(closure, arguments: [])
                    recorder.record("#expect(throws:) failed: expression did not throw")
                } catch {
                    // threw as expected
                }
                return .void
            }
            if args.positional(0)?.boolValue != true {
                let comment = args.positional(1)?.stringValue.map { " — \($0)" } ?? ""
                let source = args.labeled("__source")?.stringValue.map { ": \($0)" } ?? ""
                recorder.record("#expect failed\(source)\(comment)")
            }
            return .void
        }
        constructors["#require"] = HostFunction(name: "#require") { args, _ in
            guard let value = args.positional(0), !value.isNil else {
                recorder.record("#require failed: found nil")
                throw RuntimeError(message: "#require failed: found nil")
            }
            if value.boolValue == false {
                recorder.record("#require failed: condition is false")
                throw RuntimeError(message: "#require failed: condition is false")
            }
            return value
        }
    }
}
