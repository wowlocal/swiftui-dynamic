import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Runtime payload migration boundary")
struct RuntimePayloadTests {
    @Test func classifiesSwiftShapedValuesBeforeTheHostBoundary() {
        if case .string("hello") = RuntimeValue.native("hello").payload {} else {
            Issue.record("String should have a typed payload")
        }

        let elements: [RuntimeValue] = [.native(1), .native(2)]
        if case .array(let values) = RuntimeValue.native(elements).payload {
            #expect(values.count == 2)
        } else {
            Issue.record("Array should have a typed payload")
        }

        let dictionary = DictValue(keys: [.native("key")], values: [.native(7)])
        if case .dictionary(let value) = RuntimeValue.native(dictionary).payload {
            #expect(value === dictionary)
        } else {
            Issue.record("Dictionary should have a typed payload")
        }

        let tuple = TupleValue(labels: ["value"], values: [.native(3)])
        if case .tuple(let value) = RuntimeValue.native(tuple).payload {
            #expect(value === tuple)
        } else {
            Issue.record("Tuple should have a typed payload")
        }

        if case .range(let value) = RuntimeValue.native(1..<4).payload {
            #expect(value.halfOpenIntRange == 1..<4)
        } else {
            Issue.record("Range should have a typed payload")
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
}
