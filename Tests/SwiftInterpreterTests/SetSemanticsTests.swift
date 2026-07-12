import Testing
@testable import SwiftInterpreter

private func evaluateSetSemantics(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

@Suite("Set semantics")
struct SetSemanticsTests {
    @Test func annotatedLiteralUsesDedicatedDeduplicatedStorage() throws {
        let native: Set<Int> = [3, 1, 3, 2]
        let expected = "\(native.count)|\(native.sorted())|\(native == Set([2, 3, 1]))"

        let value = try evaluateSetSemantics(#"""
        let values: Set<Int> = [3, 1, 3, 2]
        "\(values.count)|\(values.sorted())|\(values == Set([2, 3, 1]))"
        """#)

        #expect(value.stringValue == expected)
    }

    @Test func equalityContextualizesOnlyArrayLiteralsAsSets() throws {
        let native: Set<Int> = [1, 2]
        let expected = "\(native == [2, 1])|\([2, 1] == native)|\(native != [3])"
        let value = try evaluateSetSemantics(#"""
        let values: Set<Int> = [1, 2]
        "\(values == [2, 1])|\([2, 1] == values)|\(values != [3])"
        """#)
        #expect(value.stringValue == expected)

        #expect(throws: RuntimeError.self) {
            try evaluateSetSemantics("""
            let values: Set<Int> = [1, 2]
            let array = [1, 2]
            values == array
            """)
        }
    }

    @Test func asyncEqualityRetainsArrayLiteralSetContext() async throws {
        let value = try await Interpreter().runAsync(source: #"""
        func compare() async -> Bool {
            let values: Set<Int> = [1, 2]
            return values == [2, 1]
        }
        await compare()
        """#)
        #expect(value.boolValue == true)
    }

    @Test func constructorsAcceptSequencesAndPreserveArrayDistinction() throws {
        let nativeArray = [1, 1, 2, 3]
        let nativeSet = Set(nativeArray)
        let nativeRange = Set(1...3)
        let expected = "\(nativeArray.count)|\(nativeSet.count)|\(nativeRange.sorted())"

        let value = try evaluateSetSemantics(#"""
        let array = [1, 1, 2, 3]
        let set = Set(array)
        let range = Set(1...3)
        "\(array.count)|\(set.count)|\(range.sorted())"
        """#)

        #expect(value.stringValue == expected)
    }

    @Test func valueAssignmentAndAlgebraMatchNativeSwift() throws {
        let nativeOriginal: Set<Int> = [1, 2, 3]
        var nativeCopy = nativeOriginal
        nativeCopy.insert(4)
        let nativeUnion = nativeOriginal.union([3, 4, 5])
        let nativeIntersection = nativeUnion.intersection([2, 4, 8])
        let nativeDifference = nativeUnion.subtracting([1, 5])
        let nativeSymmetric = nativeOriginal.symmetricDifference([3, 4])
        let expected = [
            nativeOriginal.sorted(), nativeCopy.sorted(), nativeUnion.sorted(),
            nativeIntersection.sorted(), nativeDifference.sorted(), nativeSymmetric.sorted(),
        ].description

        let value = try evaluateSetSemantics(#"""
        let original: Set<Int> = [1, 2, 3]
        var copy = original
        copy.insert(4)
        let union = original.union([3, 4, 5])
        let intersection = union.intersection([2, 4, 8])
        let difference = union.subtracting([1, 5])
        let symmetric = original.symmetricDifference([3, 4])
        [original.sorted(), copy.sorted(), union.sorted(), intersection.sorted(), difference.sorted(), symmetric.sorted()].description
        """#)

        #expect(value.stringValue == expected)
    }

    @Test func mutatingOperationsReturnNativeShapesAndResults() throws {
        var native: Set<Int> = [1, 2]
        let duplicate = native.insert(2)
        let inserted = native.insert(3)
        let removed = native.remove(1)
        let missing = native.remove(9)
        native.formUnion([4, 5])
        native.formIntersection([2, 3, 4])
        native.subtract([3])
        native.formSymmetricDifference([4, 6])
        let expected = "\(duplicate.inserted)|\(duplicate.memberAfterInsert)|"
            + "\(inserted.inserted)|\(inserted.memberAfterInsert)|"
            + "\(removed ?? -1)|\(missing == nil)|\(native.sorted())"

        let value = try evaluateSetSemantics(#"""
        var values: Set<Int> = [1, 2]
        let duplicate = values.insert(2)
        let inserted = values.insert(3)
        let removed = values.remove(1)
        let missing = values.remove(9)
        values.formUnion([4, 5])
        values.formIntersection([2, 3, 4])
        values.subtract([3])
        values.formSymmetricDifference([4, 6])
        "\(duplicate.inserted)|\(duplicate.memberAfterInsert)|\(inserted.inserted)|\(inserted.memberAfterInsert)|\(removed ?? -1)|\(missing == nil)|\(values.sorted())"
        """#)

        #expect(value.stringValue == expected)
    }

    @Test func relationsFilteringMappingAndIterationMatchNativeSwift() throws {
        let native: Set<Int> = [1, 2, 3, 4]
        let nativeFiltered: Set<Int> = native.filter { $0 % 2 == 0 }
        let nativeMapped = native.map { $0 * 10 }.sorted()
        var nativeTotal = 0
        for value in native { nativeTotal += value }
        let expected = "\(nativeFiltered.sorted())|\(nativeMapped)|\(nativeTotal)|"
            + "\(native.isSubset(of: [1, 2, 3, 4, 5]))|"
            + "\(native.isSuperset(of: [2, 3]))|\(native.isDisjoint(with: [8, 9]))"

        let value = try evaluateSetSemantics(#"""
        let values: Set<Int> = [1, 2, 3, 4]
        let filtered: Set<Int> = values.filter { $0 % 2 == 0 }
        let mapped = values.map { $0 * 10 }.sorted()
        var total = 0
        for value in values { total += value }
        "\(filtered.sorted())|\(mapped)|\(total)|\(values.isSubset(of: [1, 2, 3, 4, 5]))|\(values.isSuperset(of: [2, 3]))|\(values.isDisjoint(with: [8, 9]))"
        """#)

        #expect(value.stringValue == expected)
    }

    @Test func replacementAndStrictRelationsMatchNativeSwift() throws {
        struct Entry: Hashable {
            let id: Int
            let label: String

            static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
            func hash(into hasher: inout Hasher) { hasher.combine(id) }
        }

        var native: Set<Entry> = [
            Entry(id: 1, label: "old"), Entry(id: 2, label: "even"),
        ]
        let old = native.update(with: Entry(id: 1, label: "new"))
        _ = native.remove(Entry(id: 2, label: "ignored"))
        let small: Set<Int> = [1, 2]
        let large: Set<Int> = [1, 2, 3]
        let expected = "\(old?.label ?? "none")|\(native.first?.label ?? "none")|"
            + "\(small.isStrictSubset(of: large))|\(large.isStrictSuperset(of: small))"

        let value = try evaluateSetSemantics(#"""
        struct Entry: Hashable {
            let id: Int
            let label: String

            static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
            func hash(into hasher: inout Hasher) { hasher.combine(id) }
        }

        var values: Set<Entry> = [
            Entry(id: 1, label: "old"), Entry(id: 2, label: "even"),
        ]
        let old = values.update(with: Entry(id: 1, label: "new"))
        let _ = values.remove(Entry(id: 2, label: "ignored"))
        let small: Set<Int> = [1, 2]
        let large: Set<Int> = [1, 2, 3]
        "\(old?.label ?? "none")|\(values.first?.label ?? "none")|\(small.isStrictSubset(of: large))|\(large.isStrictSuperset(of: small))"
        """#)

        #expect(value.stringValue == expected)
    }

    @Test func sourceHashableValuesUseSynthesizedEquality() throws {
        let value = try evaluateSetSemantics(#"""
        struct Token: Hashable { var id: Int }
        let values = Set([Token(id: 1), Token(id: 1), Token(id: 2)])
        "\(values.count)|\(values.contains(Token(id: 1)))|\(values.contains(Token(id: 3)))"
        """#)

        #expect(value.stringValue == "2|true|false")
    }

    @Test func emptyGenericStorageRetainsElementTypeContext() throws {
        let interpreter = Interpreter()
        let value = try interpreter.run(source: #"""
        enum Direction { case north, south }
        var values: Set<Direction> = []
        let first = values.insert(.north)
        func addSouth(_ target: inout Set<Direction>) {
            target.insert(.south)
        }
        addSouth(&values)
        "\(first.inserted)|\(values.contains(.north))|\(values.contains(.south))|\(values.count)"
        """#)

        #expect(value.stringValue == "true|true|true|2")

        let empty = try interpreter.run(source: #"""
        let values: Set<Direction> = []
        values
        """#)
        #expect(interpreter.hostTypeName(of: empty) == "Set<Direction>")

        let typed = try HostFunction(
            declaration: "func accepts<T: Hashable>(_ values: Set<T>) -> String"
        ) { arguments, context in
            .native(context.hostTypeName(of: arguments.positional(0)!))
        }
        #expect(try typed.invoke(CallArguments(arguments: [
            .init(label: nil, value: empty),
        ]), interpreter).stringValue == "Set<Direction>")

        let specialized = try Interpreter().run(source: #"""
        enum Direction { case north }
        var values = Set<Direction>()
        values.insert(.north)
        values.contains(.north)
        """#)
        #expect(specialized.boolValue == true)

        let annotatedConstructor = try Interpreter().run(source: """
        var values: Set<Int> = Set()
        values.insert(42)
        values.contains(42)
        """)
        #expect(annotatedConstructor.boolValue == true)
    }

    @Test func arraysDoNotExposeSetOnlyOperations() {
        #expect(throws: RuntimeError.self) {
            try evaluateSetSemantics("[1, 2].union([2, 3])")
        }
        #expect(throws: RuntimeError.self) {
            try evaluateSetSemantics("var values = [1, 2]; values.insert(3)")
        }
        #expect(throws: RuntimeError.self) {
            try evaluateSetSemantics(
                "var values: Set<Int> = [1, 2]; values.removeAll { _ in true }")
        }
    }

    @Test func runtimePayloadAndHostTypeKeepSetsDistinctFromArrays() throws {
        let interpreter = Interpreter()
        let value = try interpreter.run(source: "Set([1, 2, 2])")

        guard case .set(let set) = value else {
            Issue.record("Set should use dedicated runtime storage")
            return
        }
        #expect(set.elements.count == 2)
        if case .set(let payload) = value.payload {
            #expect(payload.elements.count == 2)
        } else {
            Issue.record("Set should expose a typed payload")
        }
        #expect(value.arrayValue == nil)
        #expect(value.collectionElements?.count == 2)
        #expect(interpreter.hostTypeName(of: value) == "Set<Int>")
        #expect(interpreter.hostValue(value, matchesType: "Set<Int>"))
        #expect(interpreter.hostValue(value, conformsTo: "SetAlgebra"))
    }
}
