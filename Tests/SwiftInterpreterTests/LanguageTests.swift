import Testing
@testable import SwiftInterpreter

private func eval(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

@Suite struct OptionalTests {
    @Test func nilCoalescing() throws {
        #expect(try eval("nil ?? 5").intValue == 5)
        #expect(try eval("let x = 3\nx ?? 5").intValue == 3)
        #expect(try eval(#"Int("nope") ?? -1"#).intValue == -1)
        #expect(try eval(#"Int("42") ?? -1"#).intValue == 42)
    }

    @Test func ifLetBindsUnwrapped() throws {
        let source = """
        func describe(s: String) -> String {
            if let n = Int(s) {
                return "number \\(n)"
            } else {
                return "not a number"
            }
        }
        describe(s: "7") + ", " + describe(s: "x")
        """
        #expect(try eval(source).stringValue == "number 7, not a number")
    }

    @Test func ifLetShorthand() throws {
        let source = """
        let maybe = Int("12")
        var result = 0
        if let maybe {
            result = maybe + 1
        }
        result
        """
        #expect(try eval(source).intValue == 13)
    }

    @Test func guardLetExitsOnNil() throws {
        let source = """
        func firstUpper(names: [String]) -> String {
            guard let first = names.first else {
                return "empty"
            }
            return first.uppercased()
        }
        firstUpper(names: ["ada"]) + firstUpper(names: [])
        """
        #expect(try eval(source).stringValue == "ADAempty")
    }

    @Test func optionalChainingAndForceUnwrap() throws {
        #expect(try eval("[].first?.count ?? -1").intValue == -1)
        #expect(try eval(#"["hi"].first?.count ?? -1"#).intValue == 2)
        #expect(try eval(#"["hi"].first!"#).stringValue == "hi")
        #expect(throws: RuntimeError.self) { try eval("[].first!") }
    }
}

@Suite struct EnumAndSwitchTests {
    @Test func simpleEnumEquality() throws {
        let source = """
        enum Status {
            case idle
            case running
        }
        let s: Status = .running
        s == .running
        """
        #expect(try eval(source).boolValue == true)
    }

    @Test func rawValueEnums() throws {
        let source = """
        enum Planet: String {
            case earth
            case mars = "the red planet"
        }
        Planet.earth.rawValue + "/" + Planet.mars.rawValue
        """
        #expect(try eval(source).stringValue == "earth/the red planet")
    }

    @Test func intRawValuesAutoIncrement() throws {
        let source = """
        enum Level: Int {
            case low = 1
            case medium
            case high
        }
        Level.high.rawValue
        """
        #expect(try eval(source).intValue == 3)
    }

    @Test func switchOverEnum() throws {
        let source = """
        enum Weather {
            case sunny
            case rainy
            case snowy
        }
        func icon(w: Weather) -> String {
            switch w {
            case .sunny:
                return "sun.max"
            case .rainy:
                return "cloud.rain"
            default:
                return "snowflake"
            }
        }
        icon(w: .rainy) + " " + icon(w: Weather.snowy)
        """
        #expect(try eval(source).stringValue == "cloud.rain snowflake")
    }

    @Test func switchWithAssociatedValues() throws {
        let source = """
        enum Result {
            case success(String)
            case failure(code: Int)
        }
        func report(r: Result) -> String {
            switch r {
            case .success(let message):
                return "ok: " + message
            case .failure(let code):
                return "err \\(code)"
            }
        }
        report(r: .success("done")) + ", " + report(r: .failure(code: 404))
        """
        #expect(try eval(source).stringValue == "ok: done, err 404")
    }

    @Test func switchOverRangesAndValues() throws {
        let source = """
        func bucket(n: Int) -> String {
            switch n {
            case 0:
                return "zero"
            case 1...9:
                return "small"
            case let x where x < 0:
                return "negative"
            default:
                return "big"
            }
        }
        bucket(n: 0) + bucket(n: 5) + bucket(n: -2) + bucket(n: 100)
        """
        #expect(try eval(source).stringValue == "zerosmallnegativebig")
    }

    @Test func switchAsExpression() throws {
        let source = """
        let n = 2
        let label = switch n {
        case 1: "one"
        case 2: "two"
        default: "many"
        }
        label
        """
        #expect(try eval(source).stringValue == "two")
    }

    @Test func enumMethodsAndComputedProperties() throws {
        let source = """
        enum Direction: String {
            case north
            case south

            var arrow: String {
                switch self {
                case .north: return "up"
                case .south: return "down"
                }
            }

            func flipped() -> Direction {
                switch self {
                case .north: return .south
                case .south: return .north
                }
            }
        }
        Direction.north.arrow + "/" + Direction.north.flipped().rawValue
        """
        #expect(try eval(source).stringValue == "up/south")
    }

    @Test func allCases() throws {
        let source = """
        enum Size: String, CaseIterable {
            case small
            case large
        }
        Size.allCases.count
        """
        #expect(try eval(source).intValue == 2)
    }
}

@Suite struct TypeFeatureTests {
    @Test func customInitializer() throws {
        let source = """
        struct Temperature {
            var celsius = 0.0

            init(fahrenheit: Double) {
                self.celsius = (fahrenheit - 32) * 5 / 9
            }
        }
        Temperature(fahrenheit: 212).celsius
        """
        #expect(try eval(source).doubleValue == 100.0)
    }

    @Test func staticPropertiesAndMethods() throws {
        let source = """
        struct Config {
            static let version = "2.1"
            static func banner() -> String {
                return "v" + Config.version
            }
        }
        Config.banner()
        """
        #expect(try eval(source).stringValue == "v2.1")
    }

    @Test func extensionsAddMembers() throws {
        let source = """
        struct Point {
            var x = 1
            var y = 2
        }
        extension Point {
            var sum: Int { x + y }
            func scaled(by factor: Int) -> Int { sum * factor }
        }
        Point().scaled(by: 10)
        """
        #expect(try eval(source).intValue == 30)
    }

    @Test func tuples() throws {
        let source = """
        let pair = (name: "ada", age: 36)
        pair.name + " \\(pair.age) \\(pair.0)"
        """
        #expect(try eval(source).stringValue == "ada 36 ada")
    }

    @Test func dictionaries() throws {
        let source = """
        var scores = ["ada": 10, "grace": 8]
        scores["ada"] = 11
        scores["katherine"] = 9
        "\\(scores["ada"] ?? 0) \\(scores.count)"
        """
        #expect(try eval(source).stringValue == "11 3")
    }
}

@Suite struct StdlibTests {
    @Test func mapFilterReduce() throws {
        #expect(try eval("[1, 2, 3, 4].map { $0 * 2 }.reduce(0) { $0 + $1 }").intValue == 20)
        #expect(try eval("[1, 2, 3, 4].filter { $0 % 2 == 0 }.count").intValue == 2)
        #expect(try eval("(1...4).map { $0 }.count").intValue == 4)
        #expect(try eval(#"[1, 2, 3].compactMap { $0 == 2 ? nil : $0 }.count"#).intValue == 2)
    }

    @Test func sortedJoinedContains() throws {
        #expect(try eval(#"["b", "a", "c"].sorted().joined(separator: "-")"#).stringValue == "a-b-c")
        #expect(try eval("[3, 1, 2].sorted { $0 > $1 }.first ?? 0").intValue == 3)
        #expect(try eval(#"["x", "y"].contains("y")"#).boolValue == true)
        #expect(try eval("[1, 2, 3].contains { $0 > 2 }").boolValue == true)
    }

    @Test func firstWhereAndIndex() throws {
        #expect(try eval("[1, 2, 3, 4].first { $0 > 2 } ?? 0").intValue == 3)
        #expect(try eval("[1, 2, 3].firstIndex(of: 3) ?? -1").intValue == 2)
        #expect(try eval("[1, 2, 3].firstIndex { $0 == 9 } ?? -1").intValue == -1)
    }

    @Test func mutatingArrayMethods() throws {
        let source = """
        var items = [1, 2]
        items.append(3)
        items.insert(0, at: 0)
        items.remove(at: 1)
        items.count
        """
        #expect(try eval(source).intValue == 3)
    }

    @Test func mutatingInstanceArrayProperty() throws {
        let source = """
        struct Store {
            var items: [String] = []
            mutating func add(item: String) {
                items.append(item)
            }
        }
        let s = Store()
        s.add(item: "a")
        s.add(item: "b")
        s.items.count
        """
        #expect(try eval(source).intValue == 2)
    }

    @Test func stringMethods() throws {
        #expect(try eval(#""Hello World".hasPrefix("Hello")"#).boolValue == true)
        #expect(try eval(#""a,b,c".split(separator: ",").count"#).intValue == 3)
        #expect(try eval(#""swift".capitalized"#).stringValue == "Swift")
        #expect(try eval(#""  hi  ".trimmingCharacters(in: .whitespaces)"#).stringValue == "hi")
        #expect(try eval(#""abc".replacingOccurrences(of: "b", with: "-")"#).stringValue == "a-c")
    }

    @Test func globalFunctions() throws {
        #expect(try eval("abs(-5)").intValue == 5)
        #expect(try eval("min(3, 1, 2)").intValue == 1)
        #expect(try eval("max(3, 1, 2)").intValue == 3)
        #expect(try eval("String(42)").stringValue == "42")
        #expect(try eval("Double(\"2.5\") ?? 0").doubleValue == 2.5)
        #expect(try eval("Array(0..<3).count").intValue == 3)
    }

    @Test func enumeratedTuples() throws {
        let source = """
        var out = ""
        for entry in ["a", "b"].enumerated() {
            out += "\\(entry.offset)\\(entry.element)"
        }
        out
        """
        #expect(try eval(source).stringValue == "0a1b")
    }
}
