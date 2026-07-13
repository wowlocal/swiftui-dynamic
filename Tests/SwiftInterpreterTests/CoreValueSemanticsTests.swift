import Testing
@testable import SwiftInterpreter

private func evaluateValueSemantics(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

private struct NativeValueCounter {
    var value: Int

    mutating func bump() {
        value += 1
    }

    func reader() -> () -> Int {
        { value }
    }
}

private struct NativeNestedMutator {
    var values: [Int]
    var revision: Int

    mutating func update() {
        replaceValues()
        markUpdated()
    }

    private mutating func replaceValues() {
        values[0] = 9
    }

    private mutating func markUpdated() {
        revision = 2
    }
}

private struct NativeValueHolder {
    var counter: NativeValueCounter
}

private final class NativeReferenceCounter {
    var value: Int

    init(value: Int) {
        self.value = value
    }
}

private struct NativeReferenceHolder {
    var counter: NativeReferenceCounter
}

private struct NativeValueBag {
    var values: [Int]

    subscript(index: Int) -> Int {
        get { values[index] }
        set { values[index] = newValue }
    }
}

private struct NativeValueBagHolder {
    var bag: NativeValueBag
}

private struct NativeDelegatingValue {
    var first: Int
    var second: Int

    init(first: Int, second: Int) {
        self.first = first
        self.second = second
    }

    init(_ seed: Int) {
        self.init(first: seed, second: seed + 1)
    }
}

private protocol NativeIncrementable {
    var value: Int { get set }
}

private extension NativeIncrementable {
    mutating func increment() {
        value += 1
    }
}

private struct NativeProtocolCounter: NativeIncrementable {
    var value: Int
}

private final class NativeObserverProbe {
    var runs = 0
}

private final class NativeHostValueCarrier: HostValueSemantic {
    var value: Int

    init(_ value: Int) {
        self.value = value
    }

    func copiedHostValue() -> Any {
        NativeHostValueCarrier(value)
    }
}

private struct NativeObservedHolder {
    let observer: NativeObserverProbe
    var counter: NativeValueCounter {
        didSet { observer.runs += 1 }
    }
}

private struct NativeInitializationObservedValue {
    let observer: NativeObserverProbe
    var value: Int {
        didSet { observer.runs += 1 }
    }

    init(observer: NativeObserverProbe) {
        self.observer = observer
        self.value = 1
    }
}

@Suite("Core value semantics")
struct CoreValueSemanticsTests {
    @Test func optedInOpaqueHostCarriersCopyAtStorageBoundaries() throws {
        let original = NativeHostValueCarrier(1)
        let runtime = RuntimeValue.native(original)
        guard case .host(let shallowPayload) = runtime.copiedForValueSemantics(),
              let shallow = shallowPayload as? NativeHostValueCarrier,
              case .host(let deepPayload) = runtime.deeplyCopiedForValueSemantics(),
              let deep = deepPayload as? NativeHostValueCarrier else {
            Issue.record("opted-in host carrier copies were not preserved")
            return
        }

        shallow.value = 2
        deep.value = 3
        #expect(original.value == 1)
        #expect(shallow !== original)
        #expect(deep !== original)
    }

    @Test func structInitializerSuppressesObserversAcrossValueCopies() throws {
        let nativeObserver = NativeObserverProbe()
        var nativeValue = NativeInitializationObservedValue(observer: nativeObserver)
        nativeValue.value = 2
        let native = "\(nativeValue.value) \(nativeObserver.runs)"

        let source = #"""
        var observerRuns = 0
        struct Value {
            var value: Int {
                didSet { observerRuns += 1 }
            }

            init() {
                self.value = 1
            }
        }
        var value = Value()
        value.value = 2
        "\(value.value) \(observerRuns)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func sourceStructAssignmentAndNestedMutationMatchNativeSwift() throws {
        let nativeOriginal = NativeValueHolder(counter: NativeValueCounter(value: 1))
        var nativeCopy = nativeOriginal
        nativeCopy.counter.value = 9
        let native = "\(nativeOriginal.counter.value) \(nativeCopy.counter.value)"

        let source = #"""
        struct Counter { var value: Int }
        struct Holder { var counter: Counter }
        var original = Holder(counter: Counter(value: 1))
        var copy = original
        copy.counter.value = 9
        "\(original.counter.value) \(copy.counter.value)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func sourceStructArgumentsReturnsAndMutatingMethodsMatchNativeSwift() throws {
        func nativeChanged(_ input: NativeValueCounter) -> NativeValueCounter {
            var result = input
            result.bump()
            return result
        }
        let nativeOriginal = NativeValueCounter(value: 3)
        let nativeChangedValue = nativeChanged(nativeOriginal)
        let native = "\(nativeOriginal.value) \(nativeChangedValue.value)"

        let source = #"""
        struct Counter {
            var value: Int
            mutating func bump() { value += 1 }
        }
        func changed(_ input: Counter) -> Counter {
            var result = input
            result.bump()
            return result
        }
        let original = Counter(value: 3)
        let changedValue = changed(original)
        "\(original.value) \(changedValue.value)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func nestedImplicitSelfMutatingCallsWriteBackLikeNativeSwift() throws {
        var nativeValue = NativeNestedMutator(values: [1], revision: 1)
        nativeValue.update()
        let native = "\(nativeValue.values[0]) \(nativeValue.revision)"

        let source = #"""
        struct Value {
            var values: [Int]
            var revision: Int

            mutating func update() {
                replaceValues()
                markUpdated()
            }

            private mutating func replaceValues() {
                values[0] = 9
            }

            private mutating func markUpdated() {
                revision = 2
            }
        }

        var value = Value(values: [1], revision: 1)
        value.update()
        "\(value.values[0]) \(value.revision)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func sourceStructsInsideArraysMatchNativeSwift() throws {
        let nativeOriginal = [NativeValueHolder(counter: NativeValueCounter(value: 2))]
        var nativeCopy = nativeOriginal
        nativeCopy[0].counter.value = 8
        let native = "\(nativeOriginal[0].counter.value) \(nativeCopy[0].counter.value)"

        let source = #"""
        struct Counter { var value: Int }
        struct Holder { var counter: Counter }
        var original = [Holder(counter: Counter(value: 2))]
        var copy = original
        copy[0].counter.value = 8
        "\(original[0].counter.value) \(copy[0].counter.value)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func classReferencesInsideCopiedStructsMatchNativeSwift() throws {
        let nativeOriginal = NativeReferenceHolder(counter: NativeReferenceCounter(value: 4))
        let nativeCopy = nativeOriginal
        nativeCopy.counter.value = 7
        let native = "\(nativeOriginal.counter.value) \(nativeCopy.counter.value)"

        let source = #"""
        class Counter { var value: Int }
        struct Holder { var counter: Counter }
        let original = Holder(counter: Counter(value: 4))
        let copy = original
        copy.counter.value = 7
        "\(original.counter.value) \(copy.counter.value)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func nestedMutatingMethodWritesBackThroughPropertyObserver() throws {
        let nativeObserver = NativeObserverProbe()
        var nativeHolder = NativeObservedHolder(
            observer: nativeObserver, counter: NativeValueCounter(value: 5))
        nativeHolder.counter.bump()
        let native = "\(nativeHolder.counter.value) \(nativeObserver.runs)"

        let source = #"""
        var observerRuns = 0
        struct Counter {
            var value: Int
            mutating func bump() { value += 1 }
        }
        struct Holder {
            var counter: Counter {
                didSet { observerRuns += 1 }
            }
        }
        var holder = Holder(counter: Counter(value: 5))
        holder.counter.bump()
        "\(holder.counter.value) \(observerRuns)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func methodClosureCapturesStructSelfByValueLikeNativeSwift() throws {
        var nativeCounter = NativeValueCounter(value: 6)
        let nativeReader = nativeCounter.reader()
        nativeCounter.value = 10
        let native = "\(nativeReader()) \(nativeCounter.value)"

        let source = #"""
        struct Counter {
            var value: Int
            func reader() -> () -> Int { { value } }
        }
        var counter = Counter(value: 6)
        let reader = counter.reader()
        counter.value = 10
        "\(reader()) \(counter.value)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func explicitClosureCaptureListSnapshotsStructValuesLikeNativeSwift() throws {
        var nativeCounter = NativeValueCounter(value: 11)
        let nativeReader = { [snapshot = nativeCounter] in snapshot.value }
        nativeCounter.value = 12
        let native = "\(nativeReader()) \(nativeCounter.value)"

        let source = #"""
        struct Counter { var value: Int }
        var counter = Counter(value: 11)
        let reader = { [snapshot = counter] in snapshot.value }
        counter.value = 12
        "\(reader()) \(counter.value)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func structCopiesKeepWrapperLocationsButSeparateOrdinaryStorage() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: """
        struct Sample {
            @State var state = 1
            @Binding var binding: Int
            var ordinary: Int
        }
        """)
        let symbol = try #require(
            interpreter.structSymbols.first { $0.name == "Sample" })
        let external = Box(.native(2))
        let original = try interpreter.instantiate(symbol, with: CallArguments(arguments: [
            .init(label: "binding", value: .native(BindingStub(box: external))),
            .init(label: "ordinary", value: .native(3)),
        ]))
        guard case .instance(let originalInstance) = original,
              case .instance(let copiedInstance) = original.copiedForValueSemantics() else {
            Issue.record("Sample should copy as an interpreted struct")
            return
        }

        #expect(copiedInstance !== originalInstance)
        #expect(copiedInstance.stateBoxes["state"] === originalInstance.stateBoxes["state"])
        #expect(copiedInstance.properties["binding"] === external)
        #expect(copiedInstance.properties["ordinary"] !== originalInstance.properties["ordinary"])
    }

    @Test func nestedSourceStructSubscriptCopiesOutLikeNativeSwift() throws {
        let nativeOriginal = NativeValueBagHolder(
            bag: NativeValueBag(values: [1, 2]))
        var nativeCopy = nativeOriginal
        nativeCopy.bag[0] = 9
        let native = "\(nativeOriginal.bag[0]) \(nativeCopy.bag[0])"

        let source = #"""
        struct Bag {
            var values: [Int]
            subscript(index: Int) -> Int {
                get { values[index] }
                set { values[index] = newValue }
            }
        }
        struct Holder { var bag: Bag }
        let original = Holder(bag: Bag(values: [1, 2]))
        var copy = original
        copy.bag[0] = 9
        "\(original.bag[0]) \(copy.bag[0])"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func delegatingStructInitializerCommitsReplacementSelfLikeNativeSwift() throws {
        let nativeValue = NativeDelegatingValue(4)
        let native = "\(nativeValue.first) \(nativeValue.second)"

        let source = #"""
        struct Value {
            var first: Int
            var second: Int

            init(first: Int, second: Int) {
                self.first = first
                self.second = second
            }

            init(_ seed: Int) {
                self.init(first: seed, second: seed + 1)
            }
        }
        let value = Value(4)
        "\(value.first) \(value.second)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func protocolDefaultMutatingMethodCopiesOutLikeNativeSwift() throws {
        let nativeOriginal = NativeProtocolCounter(value: 7)
        var nativeCopy = nativeOriginal
        nativeCopy.increment()
        let native = "\(nativeOriginal.value) \(nativeCopy.value)"

        let source = #"""
        protocol Incrementable {
            var value: Int { get set }
        }
        extension Incrementable {
            mutating func increment() { value += 1 }
        }
        struct Counter: Incrementable { var value: Int }
        let original = Counter(value: 7)
        var copy = original
        copy.increment()
        "\(original.value) \(copy.value)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == native)
    }

    @Test func dictionaryAssignmentDoesNotAlias() throws {
        let source = #"""
        var original = ["count": 1]
        var copy = original
        copy["count"] = 2
        "\(original["count"]!) \(copy["count"]!)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "1 2")
    }

    @Test func tupleAssignmentDoesNotAlias() throws {
        let source = #"""
        var original = (x: 1, y: 2)
        var copy = original
        copy.x = 9
        "\(original.x) \(copy.x)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "1 9")
    }

    @Test func nestedContainerMutationUsesCopyInCopyOut() throws {
        let source = #"""
        var original = [["count": 1]]
        var copy = original
        copy[0]["count"] = 3
        "\(original[0]["count"]!) \(copy[0]["count"]!)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "1 3")
    }

    @Test func functionArgumentAndReturnPreserveValueSemantics() throws {
        let source = #"""
        func changed(_ input: [String: Int]) -> [String: Int] {
            var result = input
            result["count"] = 4
            return result
        }

        var original = ["count": 1]
        let result = changed(original)
        "\(original["count"]!) \(result["count"]!)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "1 4")
    }

    @Test func dictionaryDefaultSubscriptMatchesNativeReadAndMutation() throws {
        let source = #"""
        var fallbackCalls = 0
        func fallback(_ value: Int) -> Int {
            fallbackCalls += 1
            return value
        }

        var values = ["present": 2]
        let present = values["present", default: fallback(10)]
        let missing = values["missing", default: fallback(20)]
        values["direct", default: fallback(30)] = 7
        values["present", default: fallback(40)] += 3
        values["compound", default: fallback(50)] += 1

        let optionalValues: [String: Int?] = ["presentNil": nil]
        let retainedNil = optionalValues["presentNil", default: 9] == nil
        let injectedDefault = optionalValues["missing", default: 9] == 9

        "\(present)|\(missing)|\(values["present"]!)|\(values["direct"]!)|\(values["compound"]!)|\(fallbackCalls)|\(retainedNil)|\(injectedDefault)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue ==
            "2|20|5|7|51|3|true|true")
    }

    @Test func dictionaryDefaultSubscriptCombinesFoodTruckSummaries() throws {
        let source = #"""
        struct Summary {
            var sales: [Int: Int]

            func union(_ other: Summary) -> Summary {
                var copy = self
                for key in Set(copy.sales.keys).union(Set(other.sales.keys)) {
                    copy.sales[key, default: 0] += other.sales[key, default: 0]
                }
                return copy
            }
        }

        let combined = Summary(sales: [1: 2])
            .union(Summary(sales: [1: 41, 2: 3]))
        "\(combined.sales[1]!)|\(combined.sales[2]!)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "43|3")
    }

    @Test func reduceIntoMutatesItsValueAccumulator() throws {
        let source = #"""
        let counts = ["a", "bb", "a"].reduce(into: [:]) { result, value in
            result[value, default: 0] += 1
        }
        "\(counts["a"]!) \(counts["bb"]!)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "2 1")
    }

    @Test func arrayInsertContentsUsesCopyInCopyOut() throws {
        let source = #"""
        var values = [1, 4]
        values.insert(contentsOf: [2, 3], at: 1)
        values.map(String.init).joined(separator: ",")
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "1,2,3,4")
    }

    @Test func initializerUsesItsOwnLexicalNestedTypes() throws {
        let source = """
        struct Settings {
            struct Keys { static let value = 7 }
            var value: Int
            init() { self.value = Keys.value }
        }
        struct Container {
            func load() -> Settings { Settings() }
        }
        Container().load().value
        """

        #expect(try evaluateValueSemantics(source).intValue == 7)
    }

    @Test func computedPropertyUsesItsOwnLexicalNestedTypes() throws {
        let source = """
        struct First {
            enum Layout { static let unrelated = 1 }
        }
        struct Second {
            enum Layout { static let menuWidth = 220 }
            var width: Int { Layout.menuWidth }
        }
        Second().width
        """

        #expect(try evaluateValueSemantics(source).intValue == 220)
    }

    @Test func deferredClosureKeepsItsLexicalNestedTypes() throws {
        let source = """
        var deferred: (() -> Int)!
        struct Owner {
            enum Layout { static let value = 7 }
            func install() { deferred = { Layout.value } }
        }
        struct Caller {
            enum Layout { static let unrelated = 1 }
            func call() -> Int { deferred() }
        }
        Owner().install()
        Caller().call()
        """

        #expect(try evaluateValueSemantics(source).intValue == 7)
    }

    @Test func viewBodyUsesItsOwnLexicalNestedTypes() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: """
        struct First {
            enum Layout { static let unrelated = 1 }
        }
        struct Root: View {
            enum Layout { static let value = 9 }
            var body: some View { Layout.value }
        }
        """)
        let root = try #require(interpreter.structSymbols.first { $0.name == "Root" })
        guard case .instance(let instance) = try interpreter.instantiateRoot(root) else {
            Issue.record("root should instantiate as an interpreted instance")
            return
        }

        #expect(try interpreter.evaluateBody(of: instance).intValue == 9)
    }

    @Test func nestedTypeLookupSearchesOutwardThroughLexicalFrames() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: """
        struct Outer {
            enum Layout { static let value = 11 }
        }
        struct Inner {}
        """)
        let outer = try #require(interpreter.structSymbols.first { $0.name == "Outer" })
        let inner = try #require(interpreter.structSymbols.first { $0.name == "Inner" })
        interpreter.lexicalOwnerFrames = [outer, inner]

        guard case .enumType(let layout)? = interpreter.lexicalNestedType("Layout", runtime: inner) else {
            Issue.record("outer lexical frame's nested type should remain visible")
            return
        }
        #expect(try interpreter.staticMember("value", of: layout)?.intValue == 11)
    }

    @Test func rootInstantiationGetsAFreshEvaluationBudget() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: "struct Root { var value = 7 }")
        let root = try #require(interpreter.structSymbols.first { $0.name == "Root" })

        interpreter.steps = interpreter.stepBudget

        let value = try interpreter.instantiateRoot(root)
        guard case .instance(let instance) = value else {
            Issue.record("root should instantiate as an interpreted instance")
            return
        }
        #expect(instance.box(for: "value")?.value.intValue == 7)
    }

    @Test func typedComputedReceiverUsesItsUserSubscriptSetter() throws {
        let source = """
        class Token {}
        class Controller {}
        class Manager {
            static let shared = Manager()
            private var values = [Token: Controller]()

            subscript(_ token: Token) -> Controller? {
                get { values[token] }
                set { values[token] = newValue }
            }
        }
        struct Action {
            private var manager: Manager { .shared }

            func open() -> Bool {
                let token = Token()
                manager[token] = Controller()
                return manager[token] != nil
            }
        }
        Action().open()
        """

        #expect(try evaluateValueSemantics(source).boolValue == true)
    }

    @Test func contextualReceiverEvaluatesItsMemberBaseOnce() throws {
        let source = #"""
        class Token {}
        class Manager {
            static let shared = Manager()
            subscript(_ token: Token) -> Int? { 7 }
        }
        struct Owner {
            var manager: Manager { .shared }
        }
        var constructions = 0
        func makeOwner() -> Owner {
            constructions += 1
            return Owner()
        }
        let token = Token()
        let result = makeOwner().manager[token]
        "\(result!) \(constructions)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "7 1")
    }
}
