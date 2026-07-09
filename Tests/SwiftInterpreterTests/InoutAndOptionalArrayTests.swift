import Testing
@testable import SwiftInterpreter

// Repros distilled from running External/oss/SwiftUI-2048 unmodified:
// its GameLogic exercises inout write-back, nil padding in optional-element
// arrays, tuple-member optional chains, and log2 — all of which misfired.

private func eval(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

@Suite struct InoutTests {
    @Test func inoutScalarWritesBack() throws {
        let source = """
        func bump(_ value: inout Int) {
            value += 1
        }
        var n = 41
        bump(&n)
        n
        """
        #expect(try eval(source).intValue == 42)
    }

    @Test func inoutArrayElementMutationWritesBack() throws {
        let source = """
        func double(_ values: inout [Int]) {
            for i in 0..<values.count {
                values[i] *= 2
            }
        }
        var numbers = [1, 2, 3]
        double(&numbers)
        numbers[0] + numbers[1] + numbers[2]
        """
        #expect(try eval(source).intValue == 12)
    }

    @Test func inoutWholesaleReassignmentWritesBack() throws {
        // The 2048 shape: merge(blocks: &compactRow) assigns a new array
        // to the parameter; the caller must observe it.
        let source = """
        func replace(_ values: inout [Int]) {
            values = [9, 9]
        }
        var numbers = [1]
        replace(&numbers)
        numbers.count * 10 + numbers[0]
        """
        #expect(try eval(source).intValue == 29)
    }

    @Test func inoutStructPropertyTarget() throws {
        let source = """
        struct Holder {
            var items: [Int] = [1, 2]
        }
        func clearOut(_ values: inout [Int]) {
            values = []
        }
        var holder = Holder()
        clearOut(&holder.items)
        holder.items.count
        """
        #expect(try eval(source).intValue == 0)
    }

    @Test func inoutLabeledArgumentOnMethod() throws {
        let source = """
        class Engine {
            func merge(blocks: inout [Int], reverse: Bool) {
                if reverse {
                    blocks = blocks.reversed()
                }
                blocks.append(99)
            }
        }
        var row = [1, 2]
        Engine().merge(blocks: &row, reverse: true)
        "\\(row[0]) \\(row[2])"
        """
        #expect(try eval(source).stringValue == "2 99")
    }
}

@Suite struct OptionalElementArrayTests {
    @Test func appendNilKeepsSlot() throws {
        let source = """
        var row = [Int?]()
        row.append(nil)
        row.append(7)
        row.append(nil)
        row.count
        """
        #expect(try eval(source).intValue == 3)
    }

    @Test func appendNilInterleavedWithValues() throws {
        // 2048's rowSnapshot: block appended conditionally, nil always.
        let source = """
        var row = [Int?]()
        for i in 0..<4 {
            if i == 2 {
                row.append(i)
            }
            row.append(nil)
        }
        var blanks = 0
        for item in row {
            if item == nil {
                blanks += 1
            }
        }
        "\\(row.count) \\(blanks)"
        """
        #expect(try eval(source).stringValue == "5 4")
    }

    @Test func insertNilAtFront() throws {
        let source = """
        var row: [Int?] = [1]
        row.insert(nil, at: 0)
        "\\(row.count) \\(row[0] == nil) \\(row[1] ?? -1)"
        """
        #expect(try eval(source).stringValue == "2 true 1")
    }
}

@Suite struct TupleMemberChainTests {
    @Test func optionalChainIntoTupleMembers() throws {
        let source = """
        let pairs: [(Bool, Int)] = [(false, 2)]
        let flag = pairs.last?.0
        let number = pairs.last?.1
        "\\(flag == false) \\(number ?? -1)"
        """
        #expect(try eval(source).stringValue == "true 2")
    }

    @Test func mergeFoldWithTupleAccumulator() throws {
        // The exact fold from 2048's GameLogic.merge.
        let source = """
        struct Block {
            var number: Int
        }
        var blocks = [Block(number: 2), Block(number: 2), Block(number: 4)]
        blocks = blocks
            .map { (false, $0) }
            .reduce([(Bool, Block)]()) { acc, item in
                if acc.last?.0 == false && acc.last?.1.number == item.1.number {
                    var accPrefix = Array(acc.dropLast())
                    var mergedBlock = item.1
                    mergedBlock.number *= 2
                    accPrefix.append((true, mergedBlock))
                    return accPrefix
                } else {
                    var accTmp = acc
                    accTmp.append((false, item.1))
                    return accTmp
                }
            }
            .map { $0.1 }
        "\\(blocks.count) \\(blocks[0].number) \\(blocks[1].number)"
        """
        #expect(try eval(source).stringValue == "2 4 4")
    }

    @Test func enumeratedForEachDestructuresOffsetAndElement() throws {
        let source = """
        let items = ["a", "b"]
        var out = ""
        items.enumerated().forEach {
            out += "\\($0)\\($1)"
        }
        out
        """
        #expect(try eval(source).stringValue == "0a1b")
    }
}

@Suite struct MathGlobalTests {
    @Test func log2Global() throws {
        #expect(try eval("Int(log2(Double(8)))").intValue == 3)
    }
}
