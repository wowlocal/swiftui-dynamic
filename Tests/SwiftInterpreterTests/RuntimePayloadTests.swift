import Foundation
import Testing
@testable import SwiftInterpreter

private final class OpaqueHostReference {}

@Suite("Typed runtime storage")
struct RuntimePayloadTests {
    @Test func classifiesSwiftShapedValuesBeforeTheHostBoundary() throws {
        let string = RuntimeValue.native("hello")
        if case .string("hello") = string {} else {
            Issue.record("String should use dedicated runtime storage")
        }
        if case .string("hello") = string.payload {} else {
            Issue.record("String should have a typed payload")
        }
        #expect(string.hostPayload as? String == "hello")

        let elements: [RuntimeValue] = [.native(1), .native(2)]
        let array = RuntimeValue.native(elements)
        if case .array(let values) = array {
            #expect(values.count == 2)
        } else {
            Issue.record("Array should use dedicated runtime storage")
        }
        if case .array(let values) = array.payload {
            #expect(values.count == 2)
        } else {
            Issue.record("Array should have a typed payload")
        }

        let dictionary = DictValue(keys: [.native("key")], values: [.native(7)])
        let dictionaryValue = RuntimeValue.native(dictionary)
        if case .dictionary(let value) = dictionaryValue {
            #expect(value.count == dictionary.count)
            #expect(try value.lookup(.native("key")).intValue == 7)
        } else {
            Issue.record("Dictionary should use dedicated runtime storage")
        }
        if case .dictionary(let value) = dictionaryValue.payload {
            #expect(value.count == dictionary.count)
        } else {
            Issue.record("Dictionary should have a typed payload")
        }

        let tuple = TupleValue(labels: ["value"], values: [.native(3)])
        let tupleValue = RuntimeValue.native(tuple)
        if case .tuple(let value) = tupleValue {
            #expect(value.labels == tuple.labels)
            #expect(value.values.first?.intValue == 3)
        } else {
            Issue.record("Tuple should use dedicated runtime storage")
        }
        if case .tuple(let value) = tupleValue.payload {
            #expect(value.labels == tuple.labels)
        } else {
            Issue.record("Tuple should have a typed payload")
        }

        let range = RuntimeValue.native(1..<4)
        if case .range(let value) = range {
            #expect(value.halfOpenIntRange == 1..<4)
        } else {
            Issue.record("Range should use dedicated runtime storage")
        }
        if case .range(let value) = range.payload {
            #expect(value.halfOpenIntRange == 1..<4)
        } else {
            Issue.record("Range should have a typed payload")
        }
    }

    @Test func evaluatedCoreValuesNeverEnterOpaqueHostStorage() throws {
        let interpreter = Interpreter()

        if case .string("hello") = try interpreter.run(source: #""hello""#) {} else {
            Issue.record("evaluated string literal should be typed")
        }
        if case .array(let values) = try interpreter.run(source: "[1, 2]") {
            #expect(values.count == 2)
        } else {
            Issue.record("evaluated array literal should be typed")
        }
        if case .dictionary(let value) = try interpreter.run(source: #"["a": 1]"#) {
            #expect(value.count == 1)
        } else {
            Issue.record("evaluated dictionary literal should be typed")
        }
        if case .tuple(let value) = try interpreter.run(source: "(x: 1, y: 2)") {
            #expect(value.values.count == 2)
        } else {
            Issue.record("evaluated tuple literal should be typed")
        }
        if case .range(let value) = try interpreter.run(source: "1..<3") {
            #expect(value.halfOpenIntRange == 1..<3)
        } else {
            Issue.record("evaluated range should be typed")
        }
    }

    @Test func leavesFrameworkValuesAtTheHostBoundary() {
        let date = Date(timeIntervalSince1970: 42)
        if case .host(let value) = RuntimeValue.native(date).payload {
            #expect((value as? Date) == date)
        } else {
            Issue.record("Foundation values should remain host payloads")
        }
    }

    @Test func opaqueHostReferencesUseIdentityAsCollectionKeys() throws {
        let first = OpaqueHostReference()
        let second = OpaqueHostReference()
        let interpreter = Interpreter()
        var dictionary = DictValue()

        try dictionary.setValue(
            .native(first), to: .native("registered"),
            by: interpreter.collectionStorageValuesAreEqual)

        #expect(
            try dictionary.value(
                forKey: .native(first),
                by: interpreter.collectionStorageValuesAreEqual)?
                .stringValue == "registered")
        #expect(
            try dictionary.value(
                forKey: .native(second),
                by: interpreter.collectionStorageValuesAreEqual) == nil)
    }
}
