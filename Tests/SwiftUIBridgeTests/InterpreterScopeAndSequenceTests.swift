import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck socialfeed FlowLayout class — the three interpreter semantics
/// its FlowResult init needs, distilled: local functions HOIST (a call may
/// precede the declaration in the same scope) and mutate self/captured
/// vars persistently; stdlib zip pairs runtime sequences as unlabeled
/// tuples; nested-struct arrays built by hoisted local funcs read back
/// complete. Plus: the native factory bridges CGFloat/Float into .double
/// (ViewSpacing.distance returned an unaddable host CGFloat).
@Suite struct InterpreterScopeAndSequenceTests {
    @MainActor
    @Test func localFuncsInInitMutateSelfAndHoist() throws {
        let source = """
        struct Builder {
            var items = [Int]()
            var total = 0.0
            init(count: Int) {
                var running = 0.0
                for index in 0..<count {
                    add(index: index)
                }
                func add(index: Int) {
                    running += 1
                    items.append(index)
                    total = running
                }
            }
        }
        let built = Builder(count: 3)
        let count = built.items.count
        let total = built.total
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("count")?.intValue == 3)
        #expect(interpreter.globals.lookup("total")?.doubleValue == 3.0)
    }

    @MainActor
    @Test func zipIteratesPairs() throws {
        let source = """
        var total = 0
        var letters = ""
        for (number, letter) in zip([1, 2, 3].indices, ["a", "b", "c"]) {
            total += number
            letters += letter
        }
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("total")?.intValue == 3)
        #expect(interpreter.globals.lookup("letters")?.stringValue == "abc")
    }

    @MainActor
    @Test func nestedRowAppendPersists() throws {
        let source = """
        struct Result2 {
            var rows = [Row]()
            struct Row {
                var range: Range<Int>
                var xOffsets: [Double]
            }
            init(count: Int) {
                var itemsInRow = 0
                var xOffsets: [Double] = []
                for index in 0..<count {
                    addToRow(index: index)
                    if index == count - 1 {
                        finalizeRow(index: index)
                    }
                }
                func addToRow(index: Int) {
                    xOffsets.append(Double(index) * 10)
                    itemsInRow += 1
                }
                func finalizeRow(index: Int) {
                    rows.append(Row(range: index - max(itemsInRow - 1, 0) ..< index + 1, xOffsets: xOffsets))
                    itemsInRow = 0
                    xOffsets.removeAll()
                }
            }
        }
        let result = Result2(count: 3)
        let rowCount = result.rows.count
        let first = result.rows[0].xOffsets[1]
        let lower = result.rows[0].range.lowerBound
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("rowCount")?.intValue == 1)
        #expect(interpreter.globals.lookup("first")?.doubleValue == 10)
        #expect(interpreter.globals.lookup("lower")?.intValue == 0)
    }
}
