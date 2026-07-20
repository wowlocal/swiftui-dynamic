import Testing
@testable import SwiftInterpreter

private func evaluateOptionalSemantics(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

private struct OptionalProbeFailure: Error {}

@Suite("Optional semantics")
struct OptionalSemanticsTests {
    @Test func hostOptionalsNormalizeWithoutLosingNestedShape() throws {
        let hostSome: Int? = 3
        let some = RuntimeValue.native(hostSome)
        guard case .optional(let optional) = some,
              case .int(3)? = optional.wrapped else {
            Issue.record("Int?.some should use dedicated Optional storage")
            return
        }
        #expect(optional.wrappedTypeName == "Int")
        if case .optional = some.payload {} else {
            Issue.record("Optional should have a typed runtime payload")
        }

        let hostNested: Int?? = .some(nil)
        guard case .optional(let outer) = RuntimeValue.native(hostNested),
              let innerValue = outer.wrapped,
              case .optional(let inner) = innerValue else {
            Issue.record("Int??.some(.none) should retain both wrappers")
            return
        }
        #expect(outer.wrappedTypeName == "Optional<Int>")
        #expect(inner.wrappedTypeName == "Int")
        #expect(inner.wrapped == nil)
        #expect(!RuntimeValue.optional(innerValue).isNil)

        let erased: Any = hostNested as Any
        guard case .optional(let erasedOuter) = RuntimeValue.nativePreservingOptional(erased),
              case .optional(let erasedInner)? = erasedOuter.wrapped else {
            Issue.record("an explicitly erased Optional boundary lost nesting")
            return
        }
        #expect(erasedInner.wrapped == nil)
    }

    @Test func annotatedStorageRetainsSomeNoneAndEveryNestedLayer() throws {
        let some = try evaluateOptionalSemantics("let value: Int? = 4\nvalue")
        guard case .optional(let optional) = some,
              case .int(4)? = optional.wrapped else {
            Issue.record("annotated non-nil Optional was flattened")
            return
        }
        #expect(optional.wrappedTypeName == "Int")

        let outerSomeInnerNone = try evaluateOptionalSemantics("""
        let inner: Int? = nil
        let outer: Int?? = inner
        outer
        """)
        guard case .optional(let outer) = outerSomeInnerNone,
              let innerValue = outer.wrapped,
              case .optional(let inner) = innerValue else {
            Issue.record("Optional injection should produce .some(.none)")
            return
        }
        #expect(outer.wrappedTypeName == "Int?")
        #expect(inner.wrappedTypeName == "Int")
        #expect(inner.wrapped == nil)

        let outerNone = try evaluateOptionalSemantics("let value: Int?? = nil\nvalue")
        guard case .optional(let optionalNone) = outerNone else {
            Issue.record("typed nested nil should be an explicit outer Optional")
            return
        }
        #expect(optionalNone.wrapped == nil)
        #expect(optionalNone.wrappedTypeName == "Int?")
    }

    @Test func optionalElementsRemainWrappedInsideCollections() throws {
        let value = try evaluateOptionalSemantics("""
        let values: [Int?] = [1, nil, 3]
        values
        """)
        let elements = try #require(value.arrayValue)
        #expect(elements.count == 3)
        guard case .optional(let first) = elements[0],
              case .int(1)? = first.wrapped,
              case .optional(let second) = elements[1] else {
            Issue.record("[Int?] elements should retain Optional storage")
            return
        }
        #expect(second.wrapped == nil)
        #expect(first.wrappedTypeName == "Int")
        #expect(second.wrappedTypeName == "Int")
    }

    @Test func collectionMutationsCanonicalizeOnlyTheirChangedLeaves() throws {
        let result = try evaluateOptionalSemantics("""
        var values: [Int?] = []
        values.append(1)
        values.append(nil)
        values[0] = 3

        var nested: [[Int?]] = [[]]
        nested[0].append(nil)

        var optional: [Int?]? = []
        optional!.append(7)
        [values, nested[0], optional!]
        """)
        let groups = try #require(result.arrayValue)
        #expect(groups.count == 3)
        let expected: [[Int?]] = [[3, nil], [nil], [7]]
        for (group, expectedGroup) in zip(groups, expected) {
            let elements = try #require(group.arrayValue)
            #expect(elements.count == expectedGroup.count)
            for (element, expectedElement) in zip(elements, expectedGroup) {
                guard case .optional(let optional) = element else {
                    Issue.record("a mutated [Int?] element lost Optional storage")
                    continue
                }
                #expect(optional.wrappedTypeName == "Int")
                #expect(optional.wrapped?.intValue == expectedElement)
            }
        }
    }

    @Test func optionalChainedArrayMutationWritesBackToSomeStorage() throws {
        let result = try evaluateOptionalSemantics("""
        var values: [Int]? = [1, 2, 3]
        values?.removeAll(keepingCapacity: true)
        var missing: [Int]? = nil
        missing?.removeAll(keepingCapacity: true)
        "\\(values?.count ?? -1)|\\(missing == nil)"
        """)
        #expect(result.stringValue == "0|true")
    }

    @Test func payloadContextsUnwrapCallsLValuesAndEnumPatterns() throws {
        let result = try evaluateOptionalSemantics("""
        struct Counter { var value: Int }

        var implicit: Counter! = Counter(value: 1)
        implicit.value += 1

        var chained: Counter? = Counter(value: 4)
        chained?.value += 3

        let values: [Int]? = [1, 2, 3]
        let found = values?.first(where: { $0 == 2 })

        enum Result { case object(Int, Int); case text(String) }
        let payload: Result? = .object(2, 3)
        var total = -1
        switch payload {
        case .object(let left, let right): total = left + right
        case .text: total = 0
        case .none: total = -2
        }

        "\\(implicit.value)|\\(chained?.value ?? -1)|\\(found ?? -1)|\\(total)"
        """)
        #expect(result.stringValue == "2|7|2|5")

        let stored = try evaluateOptionalSemantics("""
        struct Counter { var value: Int }
        var counter: Counter? = Counter(value: 4)
        counter?.value += 3
        counter
        """)
        guard case .optional(let optional) = stored,
              case .instance(let counter)? = optional.wrapped else {
            Issue.record("optional-chain write-back flattened its owner")
            return
        }
        #expect(counter.box(for: "value")?.value.intValue == 7)
    }

    @Test func dictionaryValuesAndEnumPayloadsUseAnnotatedOptionalStorage() throws {
        let dictionary = try evaluateOptionalSemantics("""
        let values: [String: Int?] = ["some": 1, "none": nil]
        values
        """)
        let stored = try #require(dictionary.dictValue)
        #expect(stored.count == 2)
        let some = try #require(try stored.value(forKey: .native("some")))
        let none = try #require(try stored.value(forKey: .native("none")))
        guard case .optional(let someOptional) = some,
              case .int(1)? = someOptional.wrapped,
              case .optional(let noneOptional) = none else {
            Issue.record("dictionary value annotation should retain Optional storage")
            return
        }
        #expect(noneOptional.wrapped == nil)

        let mutated = try evaluateOptionalSemantics("""
        var values: [String: Int?] = [:]
        let none: Int? = nil
        values["none"] = none
        values["some"] = 2
        values["removed"] = 3
        values["removed"] = nil
        values
        """)
        let mutatedStorage = try #require(mutated.dictValue)
        #expect(mutatedStorage.count == 2)
        guard case .optional(let assignedNone)? = try mutatedStorage.value(
            forKey: .native("none")),
              case .optional(let assignedSome)? = try mutatedStorage.value(
                forKey: .native("some")) else {
            Issue.record("dictionary assignment flattened an Optional value")
            return
        }
        #expect(assignedNone.wrapped == nil)
        #expect(assignedSome.wrapped?.intValue == 2)

        let lookup = try evaluateOptionalSemantics(#"""
        let values: [String: Int?] = ["none": nil]
        "\(values["none"] == nil)|\(values["missing"] == nil)|\(values.count)"
        """#)
        #expect(lookup.stringValue == "false|true|1")

        let payload = try evaluateOptionalSemantics("""
        enum Payload { case value(Int?) }
        Payload.value(3)
        """)
        guard case .enumCase(let enumCase) = payload,
              case .optional(let associated)? = enumCase.associated.first,
              case .int(3)? = associated.wrapped else {
            Issue.record("enum associated-value annotation should retain Optional storage")
            return
        }
    }

    @Test func equalityCoalescingBindingAndPrintingMatchNativeSwift() throws {
        let none: Int? = nil
        let some: Int? = 4
        let nested: Int?? = none
        let native = "\(none == nil)|\(some == 4)|\(nested == nil)|"
            + "\(nested! == nil)|\(some ?? -1)|\(String(describing: some))"

        let interpreted = try evaluateOptionalSemantics(#"""
        let none: Int? = nil
        let some: Int? = 4
        let nested: Int?? = none
        "\(none == nil)|\(some == 4)|\(nested == nil)|\(nested! == nil)|\(some ?? -1)|\(some)"
        """#)
        #expect(interpreted.stringValue == native)

        let bound = try evaluateOptionalSemantics("""
        let value: Int? = 8
        if let value { value + 1 } else { -1 }
        """)
        #expect(bound.intValue == 9)
    }

    @Test func dynamicCastsMatchNativeOptionalShape() throws {
        let interpreted = try evaluateOptionalSemantics(#"""
        class Node {}
        class Element: Node {
            func isBlock() -> Bool { false }
        }

        let plainParent: Node? = Node()
        let elementParent: Node? = Element()
        let plainBranch = if (plainParent as? Element) != nil {
            "element"
        } else {
            "plain"
        }
        let elementBranch = if (elementParent as? Element) != nil {
            "element"
        } else {
            "plain"
        }
        let forcedBranch = if (elementParent as! Element).isBlock() {
            "block"
        } else {
            "inline"
        }
        "\(plainBranch)|\(elementBranch)|\(forcedBranch)"
        """#)

        #expect(interpreted.stringValue == "plain|element|inline")
    }

    @Test func mapAddsALayerWhileFlatMapFlattens() throws {
        let mapped = try evaluateOptionalSemantics(#"""
        let value: Int? = 1
        value.map { _ in Int("nope") }
        """#)
        guard case .optional(let outer) = mapped,
              let innerValue = outer.wrapped,
              case .optional(let inner) = innerValue else {
            Issue.record("Optional.map returning Optional should produce a nested Optional")
            return
        }
        #expect(inner.wrapped == nil)

        let flatMapped = try evaluateOptionalSemantics(#"""
        let value: Int? = 1
        value.flatMap { _ in Int("nope") }
        """#)
        guard case .optional(let flat) = flatMapped else {
            Issue.record("Optional.flatMap should return an Optional")
            return
        }
        #expect(flat.wrapped == nil)
    }

    /// Native Swift prints 1112: optional chaining invokes `touch()` only for
    /// the present element. The skip metric pins the prepared nil path used by
    /// wide optional-backed tries without changing observable call semantics.
    @Test func arrayMapSkipsPureOptionalChainForNilElements() throws {
        let interpreter = Interpreter()
        let result = try interpreter.run(source: """
        final class Box {
            static var calls = 0

            func touch() -> Int {
                Box.calls += 1
                return 42
            }
        }

        let box = Box()
        let values: [Box?] = [nil, box, nil]
        let mapped = values.map { $0?.touch() }
        (mapped.count == 3 ? 1000 : 0)
            + (mapped[0] == nil ? 100 : 0)
            + (mapped[1] == 42 ? 10 : 0)
            + (mapped[2] == nil ? 1 : 0)
            + Box.calls
        """)

        #expect(result.intValue == 1112)
        #expect(interpreter.preparedOptionalChainNilSkipCount == 2)
    }

    @Test func assignmentAndForceUnwrapPreserveAnnotatedStorage() throws {
        let assigned = try evaluateOptionalSemantics("""
        var value: Int?
        value = 4
        value! += 3
        value
        """)
        guard case .optional(let optional) = assigned,
              case .int(7)? = optional.wrapped else {
            Issue.record("typed assignment or force-unwrap write flattened storage")
            return
        }
        #expect(optional.wrappedTypeName == "Int")

        let implicit = try evaluateOptionalSemantics("""
        let value: String! = "swift"
        value.uppercased()
        """)
        #expect(implicit.stringValue == "SWIFT")

        let storedImplicit = try evaluateOptionalSemantics("""
        let value: Int! = 2
        value
        """)
        guard case .optional(let implicitlyUnwrapped) = storedImplicit else {
            Issue.record("T! should retain Optional storage")
            return
        }
        #expect(implicitlyUnwrapped.isImplicitlyUnwrapped)
        #expect(implicitlyUnwrapped.typeName == "Int!")
    }

    @Test func switchPatternsUnwrapExactlyOneLayer() throws {
        let value = try evaluateOptionalSemantics("""
        func describe(_ value: Int?) -> String {
            switch value {
            case let number?: return "question \\(number)"
            case .none: return "none"
            }
        }
        func explicit(_ value: Int?) -> String {
            switch value {
            case .some(let number): return "some \\(number)"
            case nil: return "nil"
            }
        }
        describe(4) + "," + describe(nil) + "," + explicit(7) + "," + explicit(nil)
        """)
        #expect(value.stringValue == "question 4,none,some 7,nil")
    }

    @Test func collectionCastTryAndFailableInitProduceOptionals() throws {
        let first = try evaluateOptionalSemantics("[1, 2].first")
        guard case .optional(let firstOptional) = first,
              case .int(1)? = firstOptional.wrapped else {
            Issue.record("Collection.first should return Optional storage")
            return
        }

        let cast = try evaluateOptionalSemantics("let value: Any = 3\nvalue as? Int")
        guard case .optional(let castOptional) = cast,
              case .int(3)? = castOptional.wrapped else {
            Issue.record("as? should return Optional storage")
            return
        }
        #expect(castOptional.wrappedTypeName == "Int")

        let attempt = try evaluateOptionalSemantics("""
        enum Failure: Error { case nope }
        func load() throws -> Int { throw Failure.nope }
        try? load()
        """)
        guard case .optional(let tryOptional) = attempt else {
            Issue.record("try? should return Optional storage")
            return
        }
        #expect(tryOptional.wrapped == nil)

        let initialized = try evaluateOptionalSemantics("""
        struct Positive {
            let value: Int
            init?(_ value: Int) {
                if value < 0 { return nil }
                self.value = value
            }
        }
        Positive(2)
        """)
        guard case .optional(let initOptional) = initialized,
              case .instance? = initOptional.wrapped else {
            Issue.record("successful init? should return Optional.some(instance)")
            return
        }
        #expect(initOptional.wrappedTypeName == "Positive")

        for (source, typeName) in [
            ("Float(exactly: 2)", "Float"),
            ("TimeInterval(exactly: 2)", "Double"),
            ("CGFloat(exactly: 2)", "CGFloat"),
        ] {
            let exact = try evaluateOptionalSemantics(source)
            guard case .optional(let optional) = exact else {
                Issue.record("\(source) should retain its failable result wrapper")
                continue
            }
            #expect(optional.wrapped?.doubleValue == 2)
            #expect(optional.wrappedTypeName == typeName)
        }
    }

    @Test func computedPropertiesAndSubscriptsRespectOptionalResultTypes() throws {
        let result = try evaluateOptionalSemantics("""
        struct Source {
            var value: Int? { 3 }
            subscript(_ index: Int) -> Int? {
                if index == 0 { return 4 }
                return nil
            }
        }
        let source = Source()
        [source.value, source[0], source[1]]
        """)
        let values = try #require(result.arrayValue)
        #expect(values.count == 3)
        for (value, expected) in zip(values, [3, 4, nil] as [Int?]) {
            guard case .optional(let optional) = value else {
                Issue.record("typed computed/subscript result was flattened")
                continue
            }
            #expect(optional.wrappedTypeName == "Int")
            #expect(optional.wrapped?.intValue == expected)
        }
    }

    @Test func tryQuestionMarkCatchesArbitraryHostErrors() throws {
        let interpreter = Interpreter()
        interpreter.globals.define("fail", .hostFunction(HostFunction(
            name: "fail",
            invoke: { _, _ in throw OptionalProbeFailure() }
        )))
        let result = try interpreter.run(source: "try? fail()")
        guard case .optional(let optional) = result else {
            Issue.record("try? host failure should return Optional.none")
            return
        }
        #expect(optional.wrapped == nil)
    }

    @Test func emptyTypedOptionalCanBindAHostGeneric() throws {
        let interpreter = Interpreter()
        let inspect = try HostFunction(
            declaration: "func inspect<T>(_ value: T?) -> String"
        ) { arguments, context in
            .native(context.hostTypeName(of: arguments.positional(0)!))
        }
        let result = try inspect.invoke(CallArguments(arguments: [
            .init(label: nil, value: .none(wrappedTypeName: "Int")),
        ]), interpreter)
        #expect(result.stringValue == "Int?")
    }
}
