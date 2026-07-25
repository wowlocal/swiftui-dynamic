import Testing
@testable import SwiftInterpreter

private func eval(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

@Suite struct OptionalTests {
    @Test func wildcardAndTupleOptionalBindings() throws {
        let source = """
        let maybe: Int? = 5
        let missing: Int? = nil
        var status = "none"
        if let _ = maybe {
            status = "present"
        }
        if let _ = missing {
            status = "wrong"
        }
        let pair: (Int, Int)? = (1, 2)
        if let (a, b) = pair {
            status += " \\(a + b)"
        }
        status
        """
        #expect(try eval(source).stringValue == "present 3")
    }


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

    @Test func barePatternMatchesPayloadCase() throws {
        // Compiled Swift accepts the payload-less spelling for payload cases:
        // `case .error:` matches `.error(anything)`.
        let source = """
        enum State {
            case loading
            case display(items: Int)
            case error(code: Int)
        }
        func label(s: State) -> String {
            switch s {
            case .loading:
                return "loading"
            case .display:
                return "display"
            case .error:
                return "error"
            }
        }
        label(s: .loading) + " " + label(s: .display(items: 3)) + " " + label(s: .error(code: 404))
        """
        #expect(try eval(source).stringValue == "loading display error")
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

    @Test func dictionaryUsesDeclaredStructKeyEquality() throws {
        let source = """
        struct Key: Hashable {
            let bytes: [Int]

            static func == (lhs: Key, rhs: Key) -> Bool {
                lhs.bytes == rhs.bytes
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine(bytes.count)
            }
        }

        var index: [Key: [Int]] = [:]
        index[Key(bytes: [1, 2]), default: []].append(7)
        index[Key(bytes: [1, 2]), default: []].append(8)
        let found = index[Key(bytes: [1, 2])]?.count ?? -1
        let same = index == [Key(bytes: [1, 2]): [7, 8]]
        let removed = index.removeValue(
            forKey: Key(bytes: [1, 2]))?.count ?? -1
        "\\(index.count)|\\(found)|\\(same)|\\(removed)"
        """

        #expect(try eval(source).stringValue == "0|2|true|2")
    }

    /// Distilled from Nuke's `TaskLoadImage: AsyncPipelineTask<ImageResponse>`:
    /// a subclass with no initializer inherits the designated initializer of
    /// a generic superclass. Native Swift prints `7`; losing the generic
    /// superclass identity routes construction to an unrelated host fallback.
    @Test func genericSubclassRunsInheritedDesignatedInit() throws {
        let source = """
        final class PipelineTask<Value> {
            let value: Value

            init(_ value: Value) {
                self.value = value
            }
        }

        final class ConcreteTask: PipelineTask<Int> {}
        ConcreteTask(7).value
        """

        #expect(try eval(source).intValue == 7)
    }
}

@Suite struct StdlibTests {
    /// Custom @resultBuilder properties (`@ActionBuilder var actions:
    /// [Action]`) collect their block's items into an array.
    @Test func customResultBuilderCollectsArray() throws {
        let source = """
        @resultBuilder
        struct ActionBuilder {
            static func buildBlock(_ components: Action...) -> [Action] {
                return components
            }
        }

        struct Action: Identifiable {
            let id: Int
            var isEnabled = true
        }

        struct SwipeRow {
            @ActionBuilder var actions: [Action]

            var enabledCount: Int {
                return actions.filter { $0.isEnabled }.count
            }
        }

        let row = SwipeRow {
            Action(id: 1)
            Action(id: 2, isEnabled: false)
            Action(id: 3)
        }
        row.enabledCount
        """
        #expect(try eval(source).intValue == 2)
    }

    /// Protocol declarations are inert; protocol-EXTENSION members serve as
    /// defaults for conformers, and a conformer's own definition wins.
    @Test func protocolExtensionDefaultsDispatch() throws {
        let source = """
        protocol GameLogic {
            func label() -> String
        }

        extension GameLogic {
            func label() -> String {
                return "default"
            }

            var badge: String {
                return "star"
            }
        }

        struct TriviaGame: GameLogic {
        }

        struct CustomGame: GameLogic {
            func label() -> String {
                return "custom"
            }
        }
        TriviaGame().label() + "/" + CustomGame().label() + "/" + TriviaGame().badge
        """
        #expect(try eval(source).stringValue == "default/custom/star")
    }

    /// `super.method()` dispatches to the interpreted superclass with self
    /// unchanged; host superclasses (NSObject) make super.* inert.
    @Test func superDispatchesToInterpretedParent() throws {
        let source = """
        class Base {
            func greeting() -> String {
                return "base"
            }
        }
        class Child: Base {
            func combined() -> String {
                return super.greeting() + "+child"
            }
        }
        Child().combined()
        """
        #expect(try eval(source).stringValue == "base+child")
    }

    /// A wrapper can inherit an unavailable SDK/package class with the same
    /// basename (`Client: Vendor.Client`). Dropping the imported module
    /// qualifier must not bind the wrapper as its own interpreted parent.
    @Test func moduleQualifiedSameBasenameSuperclassRemainsHostBound() throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: """
        import VendorKit

        final class Client: VendorKit.Client {}
        """)

        let client = try #require(interpreter.structSymbols.first {
            $0.name == "Client"
        })
        #expect(client.superclassName == "VendorKit.Client")
        #expect(client.superclassSymbol == nil)
        #expect(try interpreter.staticMember("unavailable", of: client) == nil)
    }

    /// A subclass inherits the superclass's complete overload family. Call
    /// syntax must choose within that family after seeing the arguments,
    /// rather than binding whichever inherited declaration was collected
    /// first as a bare member value.
    @Test func inheritedOverloadFamilyUsesCallShape() throws {
        let source = """
        class Base {
            func label() -> String {
                "empty"
            }

            func label(_ value: String) -> String {
                value
            }
        }

        final class Child: Base {}
        Child().label("chosen")
        """

        #expect(try eval(source).stringValue == "chosen")
    }

    @Test func inheritedOverloadFamilyUsesRuntimeType() throws {
        let source = """
        struct Slice {}

        class Base {
            func matches(_ value: [Int]) -> String {
                "array"
            }

            func matches(_ value: Slice) -> String {
                "slice"
            }
        }

        final class Child: Base {}
        Child().matches(Slice())
        """

        #expect(try eval(source).stringValue == "slice")
    }

    /// A candidate with an unfilled required positional parameter is not a
    /// match merely because the supplied positional count fits its capacity.
    /// SwiftSoup's Element overloads differ by exactly this third argument.
    @Test func initializerOverloadRejectsMissingUnlabeledArgument() throws {
        let source = """
        final class Tag {}

        final class Element {
            let marker: Int

            init(
                _ tag: Tag, _ bytes: [Int], _ attributes: Int,
                skip: Bool = false
            ) {
                marker = 1
            }

            init(_ tag: Tag, _ bytes: [Int], skip: Bool = false) {
                marker = 2
            }
        }

        Element(Tag(), [], skip: false).marker
        """

        #expect(try eval(source).intValue == 2)
    }

    /// Native Swift keeps an unlabeled standard-library conversion separate
    /// from a labeled extension initializer. IceCubes' UInt RawRepresentable
    /// conformance exposed this through SwiftSoup pointer arithmetic:
    /// baseAddress &+ UInt(i) must not call init?(rawValue:).
    @Test func unlabeledNativeInitializerRejectsLabeledExtensionOverload() throws {
        let source = """
        extension UInt: @retroactive RawRepresentable {
            var rawValue: Int { Int(self) }

            init?(rawValue: Int) {
                guard rawValue >= 0 else { return nil }
                self.init(rawValue)
            }
        }

        let offset = 0
        4096 &+ UInt(offset)
        """

        #expect(try eval(source).intValue == 4096)
    }

    @Test func dynamicSelfFindsInheritedStaticMethod() throws {
        let source = """
        class Base {
            static func identify(_ value: Int) -> Int {
                value
            }

            func resolved() -> Int {
                Self.identify(42)
            }
        }

        final class Child: Base {}
        Child().resolved()
        """

        #expect(try eval(source).intValue == 42)
    }

    /// A stored static property's initializer closure retains its declaring
    /// type as lexical scope, including unqualified sibling static members.
    @Test func staticPropertyClosureSeesSiblingStaticMember() throws {
        let source = """
        final class Box {
            let value: Int
            init(_ value: Int) { self.value = value }
        }

        final class Catalog {
            private static let seed = Box(42)
            private static let selected: Box = {
                seed
            }()

            static func value() -> Int {
                selected.value
            }
        }

        Catalog.value()
        """

        #expect(try eval(source).intValue == 42)
    }

    /// A stored static property's ordinary expression has the same lexical
    /// sibling-static lookup as an initializer closure.
    @Test func staticPropertyExpressionSeesSiblingStaticMember() throws {
        let source = """
        final class Box {
            let value: Int
            init(_ value: Int) { self.value = value }
        }

        final class Catalog {
            private static let seeds = [1: Box(42)]
            private static let selected = seeds[1]!

            static func value() -> Int {
                selected.value
            }
        }

        Catalog.value()
        """

        #expect(try eval(source).intValue == 42)
    }

    /// A bare reference to the enclosing nominal keeps that lexical identity
    /// even when another imported module later declares the same base name.
    @Test func lexicalTypeNameWinsOverLaterModuleCollision() throws {
        let source = """
        // swift-interpreter-source-module Parser
        final class Entry {
            let bytes: [UInt8]

            private init(_ bytes: [UInt8]) {
                self.bytes = bytes
            }

            static func make(_ bytes: [UInt8]) -> Entry {
                Entry(bytes)
            }
        }
        // swift-interpreter-source-module-end

        // swift-interpreter-source-module Models
        struct Entry {
            let marker: String
        }
        // swift-interpreter-source-module-end

        // swift-interpreter-module Parser
        Parser.Entry.make([65, 66, 67]).bytes.count
        """

        #expect(try eval(source).intValue == 3)
    }

    /// A qualified global function selects only overloads exported by that
    /// compiler module. Flattening another target with the same function name
    /// must not let declaration order steal `Module.function(...)`.
    @Test func moduleQualifiedGlobalOverloadsStayInDeclaringModule() throws {
        let source = """
        // swift-interpreter-source-module OtherParser
        public func parse(_ input: String) -> String {
            "wrong " + input
        }
        // swift-interpreter-source-module-end

        // swift-interpreter-source-module MarkupParser
        public func parse(_ input: String) -> String {
            "right " + input
        }
        // swift-interpreter-source-module-end

        // swift-interpreter-module MarkupParser
        MarkupParser.parse("document")
        """

        #expect(try eval(source).stringValue == "right document")
    }

    /// Unqualified sibling type annotations and references are bound in the
    /// declaration's source module, not to a same-named nominal from a later
    /// flattened module.
    @Test func siblingTypeLookupUsesItsSourceModule() throws {
        let source = """
        // swift-interpreter-source-module Parser
        final class Node {
            let value: Int

            init(_ value: Int) {
                self.value = value
            }
        }

        final class Builder {
            func build() -> Node {
                let node: Node = .init(20)
                return Node(node.value + 22)
            }
        }
        // swift-interpreter-source-module-end

        // swift-interpreter-source-module Models
        struct Node {
            let marker: String

            init(_ marker: String) {
                self.marker = marker
            }
        }
        // swift-interpreter-source-module-end

        // swift-interpreter-module Parser
        Parser.Builder().build().value
        """

        #expect(try eval(source).intValue == 42)
    }

    /// A nested nominal reached through an imported outer type keeps the
    /// outer type's module path in annotation context. Nuke's
    /// `ImageProcessors.Resize` surfaced this when a flattened dependency's
    /// unrelated bare nested types gained source-module ownership.
    @Test func importedQualifiedNestedAnnotationUsesDeclaringModule() throws {
        let source = """
        // swift-interpreter-source-module ImagePipeline
        public enum ImageProcessors {
            public struct Resize {
                public init() {}

                public var marker: Int { 42 }
            }
        }
        // swift-interpreter-source-module-end

        // swift-interpreter-source-module RowFeature
        // swift-interpreter-source-import ImagePipeline
        struct Row {
            let processor: ImageProcessors.Resize = .init()

            func marker() -> Int {
                processor.marker
            }
        }
        // swift-interpreter-source-module-end

        // swift-interpreter-module RowFeature
        RowFeature.Row().marker()
        """

        #expect(try eval(source).intValue == 42)
    }

    /// Optional class elements survive assignment into and retrieval from a
    /// collection built inside a stored static property's initializer.
    @Test func staticOptionalArrayLookupPreservesClassElement() throws {
        let source = """
        final class Box {
            let value: Int
            init(_ value: Int) { self.value = value }
        }

        final class Catalog {
            private static let seed = Box(42)
            private static let lookup: [Box?] = {
                var result = [Box?](repeating: nil, count: 3)
                result[1] = seed
                result[2] = Box(7)
                return result
            }()

            static func selected() -> Box? {
                lookup[1]
            }

            static func value() -> Int {
                selected()!.value
            }
        }

        Catalog.value()
        """

        #expect(try eval(source).intValue == 42)
    }

    /// A fully-qualified nested raw-value enum remains the same enum case
    /// when it is bound to a function parameter.
    @Test func qualifiedNestedEnumParameterPreservesRawValue() throws {
        let source = """
        enum Token {
            final class Tag {
                enum ID: UInt16 {
                    case none = 0
                    case chosen = 1
                }
            }
        }

        final class Catalog {
            private static let values = [0, 42]

            static func value(for id: Token.Tag.ID) -> Int {
                values[Int(id.rawValue)]
            }
        }

        Catalog.value(for: .chosen)
        """

        #expect(try eval(source).intValue == 42)
    }

    /// An already-resolved nested enum case fits a parameter spelled with
    /// the same qualified type path during overload selection.
    @Test func qualifiedNestedEnumArgumentFitsQualifiedParameter() throws {
        let source = """
        enum Token {
            final class Tag {
                enum ID: UInt16 {
                    case none = 0
                    case chosen = 1
                }
            }
        }

        final class Catalog {
            private static let values = [0, 42]

            static func value(for id: Token.Tag.ID) -> Int? {
                values[Int(id.rawValue)]
            }
        }

        Catalog.value(for: Token.Tag.ID.chosen)!
        """

        #expect(try eval(source).intValue == 42)
    }

    /// A typed local initialized through optional binding preserves the bound
    /// class reference when it is cached and returned after the branch.
    @Test func typedLocalAssignedFromOptionalBindingPreservesReference() throws {
        let source = """
        final class Model {
            let value: Int
            init(_ value: Int) { self.value = value }
        }

        final class Catalog {
            static func lookup(_ id: Int) -> Model? {
                id == 1 ? Model(42) : nil
            }
        }

        final class Resolver {
            var cached: Model? = nil

            func resolve(_ id: Int) -> Model {
                if let cached {
                    return cached
                }

                let resolved: Model
                if let fast = Catalog.lookup(id) {
                    resolved = fast
                } else {
                    resolved = Model(-1)
                }
                cached = resolved
                return resolved
            }
        }

        Resolver().resolve(1).value
        """

        #expect(try eval(source).intValue == 42)
    }

    /// Fixed-width integers share the runtime's scalar representation but
    /// retain their declared nominal type for overload fitting.
    @Test func fixedWidthIntegerOverloadFitsRuntimeScalar() throws {
        let source = """
        struct Matcher {
            func contains(_ values: [UInt8]) -> String {
                "array"
            }

            func contains(_ value: UInt8) -> String {
                "byte"
            }
        }

        Matcher().contains(UInt8(112))
        """

        #expect(try eval(source).stringValue == "byte")
    }

    /// `Array(sequence)` materializes an interpreted integer-indexed
    /// Collection through its structural witnesses, just as `for in` does.
    @Test func arrayConstructorMaterializesInterpretedCollection() throws {
        let source = """
        struct Window: RandomAccessCollection {
            let storage: [Int]
            var startIndex: Int { 1 }
            var endIndex: Int { 3 }

            func index(after value: Int) -> Int {
                value + 1
            }

            subscript(position: Int) -> Int {
                storage[position]
            }
        }

        Array(Window(storage: [10, 20, 30, 40]))
        """

        let result = try eval(source).arrayValue
        #expect(result?.compactMap(\.intValue) == [20, 30])
    }

    /// Collection's interface-provided `first` getter remains available to
    /// an interpreted conformer that only declares the protocol witnesses.
    @Test func generatedCollectionDefaultSuppliesFirstProperty() throws {
        let source = """
        struct Window: RandomAccessCollection {
            let storage: [Int]
            var startIndex: Int { 1 }
            var endIndex: Int { 3 }

            func index(after value: Int) -> Int {
                value + 1
            }

            subscript(position: Int) -> Int {
                storage[position]
            }
        }

        Window(storage: [10, 20, 30, 40]).first ?? -1
        """

        #expect(try eval(source).intValue == 20)
    }

    @Test func superInitializerPopulatesInheritedStorage() throws {
        let source = """
        class Base {
            let id: Int
            var title: String

            init(id: Int, title: String) {
                self.id = id
                self.title = title
            }
        }
        class Child: Base {
            let note: String

            init(id: Int, title: String, note: String) {
                self.note = note
                super.init(id: id, title: title)
            }
        }
        let value = Child(id: 7, title: "native", note: "child")
        "\\(value.id)|\\(value.title)|\\(value.note)"
        """
        #expect(try eval(source).stringValue == "7|native|child")
    }

    @Test func nestedSuperclassWinsOverSameNamedGlobal() throws {
        let source = """
        class Tag {
            init(_ value: Int) {}
        }
        class Token {
            private init() {}

            class Tag: Token {
                override init() {
                    super.init()
                }
            }

            final class EndTag: Tag {
                override init() {
                    super.init()
                }
            }
        }
        _ = Token.EndTag()
        "nested"
        """
        #expect(try eval(source).stringValue == "nested")
    }

    @Test func hostSuperclassInitIsInertAndIUOIsNil() throws {
        let source = """
        class Recognizer: NSObject, ObservableObject {
            @Published var found: String!
            var configured = false

            override init() {
                super.init()
                configured = true
            }
        }
        let r = Recognizer()
        "\\(r.configured) \\(r.found == nil)"
        """
        #expect(try eval(source).stringValue == "true true")
    }

    @Test func markerComparisonsAreNameBased() throws {
        #expect(try eval(".authorized(for: 1) == .denied").boolValue == false)
        #expect(try eval(".video(a: 1) == .video").boolValue == true)
    }

    @Test func stringFormatAndFloat() throws {
        #expect(try eval(#"String(format: "%.1f", 12.345)"#).stringValue == "12.3")
        #expect(try eval(#"String(format: "%d items", 7)"#).stringValue == "7 items")
        #expect(try eval(#"Float("2.5") ?? 0"#).doubleValue == 2.5)
        #expect(try eval("Float(3)").doubleValue == 3.0)
    }

    /// The harness identifies as an iOS-shaped canvas: os(iOS)/canImport/
    /// DEBUG hold, os(macOS) takes the #else branch.
    @Test func conditionalCompilationTakesIOSBranches() throws {
        let source = """
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        #if os(macOS)
        let extra = "-mac"
        #else
        let extra = "-touch"
        #endif
        #if canImport(UIKit) && DEBUG
        let debug = true
        #endif
        platform + extra + (debug ? "!" : "?")
        """
        #expect(try eval(source).stringValue == "iOS-touch!")
    }

    /// Globals are lazily forceable, so forward references work (real Swift
    /// non-main-file semantics) while statement order still executes eagerly.
    @Test func globalsSupportForwardReferences() throws {
        let source = """
        let combined = [first, second].joined(separator: "-")
        let first = "a"
        let second = "b"
        combined
        """
        #expect(try eval(source).stringValue == "a-b")
    }

    /// Property initializers see the type's own statics bare.
    @Test func propertyInitializersSeeOwnStatics() throws {
        let source = """
        struct Carousel {
            var duration = defaultDuration * 2
            static var defaultDuration: Double {
                return 1.5
            }
        }
        Carousel().duration
        """
        #expect(try eval(source).doubleValue == 3.0)
    }

    /// Enum static computed properties + trig builtins + bare numeric markers.
    @Test func enumStaticComputedAndTrig() throws {
        let source = """
        enum Tab: String, CaseIterable {
            case play
            case store
            case search

            static var count: CGFloat {
                return CGFloat(Tab.allCases.count)
            }
        }
        let width = 390.0 / Tab.count
        let angle = atan2(1.0, 1.0) / .pi
        "\\(width) \\(angle == 0.25)"
        """
        #expect(try eval(source).stringValue == "130.0 true")
    }

    @Test func staticComputedPropertiesEvaluate() throws {
        let source = """
        struct Config {
            static let base = 21
            static var doubledBase: Int {
                return base * 2
            }
        }
        Config.doubledBase
        """
        #expect(try eval(source).intValue == 42)
    }

    /// The card-formatting genre: mutating String append/insert, enumerated
    /// tuples with (offset, element) labels + closure splat, count(where:),
    /// components(separatedBy:).
    @Test func stringMutationAndEnumeration() throws {
        let source = """
        var grouped = ""
        let digits = "12345678"
        for (index, digit) in digits.enumerated() {
            if index % 4 == 0 && index != 0 {
                grouped.append(contentsOf: " ")
            }
            grouped.append(digit)
        }
        let spaces = grouped.count(where: { $0 == " " })
        let idx = grouped.index(grouped.startIndex, offsetBy: 4)
        grouped.insert("-", at: idx)
        let parts = grouped.components(separatedBy: " ")
        "\\(grouped) \\(spaces) \\(parts.count)"
        """
        #expect(try eval(source).stringValue == "1234- 5678 1 2")
    }

    /// Static-context self/Self, Type.init, and flatMap — the batch that
    /// carried oss:SwiftUI-2048 to a full pass.
    @Test func staticSelfTypeInitFlatMap() throws {
        let source = """
        struct Block {
            var value: Int

            static func blank() -> Block {
                return Self.init(value: 0)
            }

            static func pair() -> [Block] {
                return [self.blank(), Self(value: 2)]
            }
        }
        let rows = [[1, 2], [3], []]
        let flat = rows.flatMap { $0 }
        let blocks = Block.pair()
        "\\(flat.count) \\(blocks[1].value) \\(Block.blank().value)"
        """
        #expect(try eval(source).stringValue == "3 2 0")
    }

    /// Custom postfix/prefix operator functions, backticked labels, and
    /// deferred-init locals — the second 2048 batch.
    @Test func customOperatorsBacktickLabelsDeferredInit() throws {
        let source = """
        postfix operator >*
        postfix func >*(lhs: Int) -> Int {
            return lhs * 10
        }

        prefix operator √
        prefix func √(value: Double) -> Double {
            return sqrt(value)
        }

        func pick(`for` kind: String) -> Int {
            return kind == "big" ? 100 : 1
        }

        let scaled = 4>*
        let root = √16.0
        let chosen: Int
        if scaled > 20 {
            chosen = pick(for: "big")
        } else {
            chosen = pick(for: "small")
        }
        "\\(scaled) \\(root) \\(chosen)"
        """
        #expect(try eval(source).stringValue == "40 4.0 100")
    }

    /// Native Swift prints `selected`: escaping a keyword makes it a legal
    /// declaration name, but lookup uses the identifier's canonical spelling
    /// after `.` rather than treating the backticks as part of its identity.
    @Test func escapedMethodDeclarationUsesCanonicalIdentifier() throws {
        let source = """
        struct Choice {
            func `if`(_ condition: Bool) -> String {
                condition ? "selected" : "skipped"
            }
        }
        Choice().if(true)
        """
        #expect(try eval(source).stringValue == "selected")
    }

    /// User subscripts (get + set, tuple indices), typed empty containers,
    /// member typealiases, and defer LIFO semantics — the 2048 quartet.
    @Test func userSubscriptsTypealiasesAndDefer() throws {
        let source = """
        struct Grid {
            typealias Index = (Int, Int)
            var cells: [[Int]] = [[1, 2], [3, 4]]

            subscript(index: Index) -> Int {
                get {
                    return cells[index.1][index.0]
                }
                set {
                    cells[index.1][index.0] = newValue
                }
            }
        }

        typealias Board = Grid

        func trace() -> String {
            var log = [String]()
            defer {
                log.append("outer")
            }
            var board = Board()
            board[(1, 0)] = 20
            let picked = [Board.Index]()
            log.append("cell=\\(board[(1, 0)]) empty=\\(picked.count)")
            return log.joined(separator: "/")
        }
        trace()
        """
        // The deferred append runs AFTER the return value is built.
        #expect(try eval(source).stringValue == "cell=20 empty=0")
    }

    /// Fresh-state numerics: markers/hosted objects read 0 in arithmetic and
    /// false in ordered comparisons; nil-optional switches match .none/nil;
    /// break exits a switch.
    @Test func freshStateNumericsAndSwitchNil() throws {
        let source = """
        enum Field {
            case number
            case name
        }
        let active: Field? = nil
        var log = ""
        switch active {
        case .number:
            log = "number"
            break
        case .name:
            log = "name"
        case .none:
            log = "inactive"
        }
        let comparisons = "\\(.zero > 0.0) \\(false == .cardHolderName)"
        log + " " + comparisons
        """
        #expect(try eval(source).stringValue == "inactive false false")
    }

    @Test func minMaxWithPredicates() throws {
        let source = """
        struct Sale {
            var value: Int
        }
        let sales = [Sale(value: 200), Sale(value: 710), Sale(value: 90)]
        let biggest = sales.max { a, b in a.value < b.value }
        let smallest = sales.min(by: { $0.value < $1.value })
        "\\(biggest?.value ?? 0) \\(smallest?.value ?? 0)"
        """
        #expect(try eval(source).stringValue == "710 90")
    }

    @Test func appendContentsOfSplices() throws {
        let source = """
        var downloads: [Int] = [1]
        downloads.append(contentsOf: [2, 3])
        downloads.append(4)
        downloads.count
        """
        #expect(try eval(source).intValue == 4)
    }

    @Test func stringIndexBasics() throws {
        let source = """
        let text = "hello"
        let third = text.index(text.startIndex, offsetBy: 2)
        text.distance(from: text.startIndex, to: third)
        """
        #expect(try eval(source).intValue == 2)
        #expect(try eval(#""abc".distance(from: "abc".startIndex, to: "abc".endIndex)"#).intValue == 3)
        #expect(try eval("""
            let text = "abc"
            text.startIndex < text.endIndex && text.endIndex > text.startIndex
            """).boolValue == true)
        #expect(throws: RuntimeError.self) {
            try eval(#""ab".index("ab".startIndex, offsetBy: 99)"#)
        }
    }

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

    @Test func mathBuiltins() throws {
        #expect(try eval("Int(round(2.6))").intValue == 3)
        #expect(try eval("Int(round(2.4))").intValue == 2)
        #expect(try eval("floor(2.9)").doubleValue == 2.0)
        #expect(try eval("ceil(2.1)").doubleValue == 3.0)
        #expect(try eval("sqrt(81.0)").doubleValue == 9.0)
        #expect(try eval("pow(2.0, 10.0)").doubleValue == 1024.0)
        #expect(try eval("round(7)").doubleValue == 7.0) // Int promotes
    }

    @Test func globalFunctions() throws {
        #expect(try eval("abs(-5)").intValue == 5)
        #expect(try eval("min(3, 1, 2)").intValue == 1)
        #expect(try eval("max(3, 1, 2)").intValue == 3)
        #expect(try eval("String(42)").stringValue == "42")
        #expect(try eval("Double(\"2.5\") ?? 0").doubleValue == 2.5)
        #expect(try eval("Array(0..<3).count").intValue == 3)
    }

    @Test func ifCaseConditions() throws {
        let source = """
        enum Phase {
            case idle
            case loading(Int)
        }
        func describe(p: Phase) -> String {
            if case .loading(let percent) = p {
                return "loading \\(percent)"
            }
            if case .idle = p {
                return "idle"
            }
            return "?"
        }
        describe(p: .loading(40)) + " / " + describe(p: .idle)
        """
        #expect(try eval(source).stringValue == "loading 40 / idle")
    }

    @Test func doCatchThrowTry() throws {
        let source = """
        enum LoadError: Error {
            case missing
        }

        func load(ok: Bool) throws -> Int {
            if !ok {
                throw LoadError.missing
            }
            return 5
        }

        var result = 0
        var caught = ""
        do {
            result = try load(ok: true)
            result = try load(ok: false)
        } catch {
            caught = "\\(error)"
        }

        var named = ""
        do {
            _ = try load(ok: false)
        } catch let failure {
            named = "\\(failure)"
        }

        let fallback = (try? load(ok: false)) ?? -1
        let fine = (try? load(ok: true)) ?? -1
        let awaited = try! load(ok: true)

        "\\(result) \\(caught) \\(named) \\(fallback) \\(fine) \\(awaited)"
        """
        #expect(try eval(source).stringValue == "5 LoadError.missing LoadError.missing -1 5 5")
    }

    @Test func catchHandlesHostErrorsButNotBudget() throws {
        let hostError = """
        var caught = ""
        do {
            let x = [1, 2][9]
        } catch {
            caught = error.localizedDescription
        }
        caught
        """
        #expect(try eval(hostError).stringValue?.contains("out of range") == true)

        // The infinite-loop guard must NOT be swallowed by user catch blocks.
        do {
            _ = try eval("do { while true { } } catch { }")
            Issue.record("expected the budget to trip")
        } catch let e as RuntimeError {
            #expect(e.message.contains("budget"))
        }
    }

    @Test func awaitEvaluatesInline() throws {
        let source = """
        func fetch() async throws -> Int {
            return 9
        }
        let v = try await fetch()
        v
        """
        #expect(try eval(source).intValue == 9)
    }

    @Test func uninitializedOptionalsAreNil() throws {
        let source = """
        class Observer {
            var attachedView: Item?
            var count = 0
        }
        struct Item {
            var width = 44.0
        }
        let o = Observer()
        let beforeAttach = o.attachedView?.width ?? 1.0
        o.attachedView = Item()
        let after = o.attachedView?.width ?? 1.0
        var pending: Item?
        let localNil = pending == nil
        pending = Item(width: 9.0)
        "\\(beforeAttach) \\(after) \\(localNil) \\(pending?.width ?? 0.0)"
        """
        #expect(try eval(source).stringValue == "1.0 44.0 true 9.0")
    }

    @Test func labelAwareParameterBinding() throws {
        let source = """
        func box(width: Int, padding: Int = 2, title: String = "t", height: Int) -> String {
            "\\(width)x\\(height) p\\(padding) \\(title)"
        }
        struct Card {
            var size = 0
            var corner = 4
            var label = ""

            init(size: Int, corner: Int = 8, label: String) {
                self.size = size
                self.corner = corner
                self.label = label
            }
        }
        let a = box(width: 3, height: 9)
        let b = box(width: 1, title: "x", height: 2)
        let c = Card(size: 5, label: "hi")
        let d = Card(size: 6, corner: 1, label: "yo")
        "\\(a) | \\(b) | \\(c.corner)\\(c.label) | \\(d.corner)\\(d.label)"
        """
        #expect(try eval(source).stringValue == "3x9 p2 t | 1x2 p2 x | 8hi | 1yo")
    }

    @Test func repeatedOverloadMetadataPreservesSelection() throws {
        let source = """
        struct Picker {
            var value = 0

            init(text: String, enabled: Bool = false) { value = -1 }
            init(left: Int, right: Int, scale: Int = 1) { value = (left + right) * scale }
            init(value: Int, scale: Int = 1) { self.value = value * scale }

            func select(text: String, fallback: Int = -1) -> Int { fallback }
            func select(number: Int, scale: Int = 1) -> Int { number * scale }
        }

        var total = 0
        for index in 0..<20 {
            let picker = Picker(value: index, scale: 2)
            total += picker.select(number: picker.value, scale: 3)
            total += Picker(left: index, right: 1).value
        }
        total
        """
        #expect(try eval(source).intValue == 1350)
    }

    @Test func trailingClosureBindsLastUnbound() throws {
        let source = """
        func retry(times: Int = 3, label: String = "op", work: (Int) -> Int) -> Int {
            work(times)
        }
        retry { $0 * 10 } + retry(times: 5) { $0 }
        """
        #expect(try eval(source).intValue == 35)
    }

    @Test func sugarTypedArrayExtensions() throws {
        let source = """
        struct Item {
            var id = 0
        }

        extension [Item] {
            func zIndex(_ item: Item) -> CGFloat {
                if let index = firstIndex(where: { $0.id == item.id }) {
                    return CGFloat(count) - CGFloat(index)
                }
                return 0.0
            }
        }

        extension Array {
            func middle() -> Int {
                count / 2
            }
        }

        let items = [Item(id: 1), Item(id: 2), Item(id: 3)]
        "\\(items.zIndex(items[1])) \\(items.middle())"
        """
        #expect(try eval(source).stringValue == "2.0 1")
    }

    @Test func incompatibleArrayExtensionOverloadDefersToNativeMethod() throws {
        let source = """
        struct Record {}

        extension Array where Element == Record {
            func sorted(by keyword: String) -> Self {
                _ = keyword.trimmingCharacters(in: .whitespaces)
                return self
            }
        }

        [3, 1, 2].sorted { $0 < $1 }.first!
        """
        #expect(try eval(source).intValue == 1)
    }

    @Test func unavailableContiguousStorageRunsDeclaredFallback() throws {
        let source = """
        let values = [1, 2, 3]
        let result = values.withContiguousStorageIfAvailable { _ in 99 }
            ?? values.count
        result
        """
        #expect(try eval(source).intValue == 3)
    }

    @Test func readOnlyUnsafeBufferRetainsBackingCollection() throws {
        let source = """
        final class Reader {
            let input: UnsafeBufferPointer<Int>

            init(_ values: [Int]) {
                var base: UnsafePointer<Int>? = nil
                values.withUnsafeBufferPointer { buffer in
                    base = buffer.baseAddress
                }
                input = UnsafeBufferPointer(
                    start: base, count: values.count)
            }
        }

        let reader = Reader([65, 66])
        reader.input[0] + reader.input[1]
        """
        #expect(try eval(source).intValue == 131)
    }

    @Test func convenienceInitializerRetainsUTF8BufferCollection() throws {
        let source = """
        extension String {
            var utf8Array: [UInt8] {
                if let out = self.utf8.withContiguousStorageIfAvailable({ _ in
                    [UInt8]()
                }) {
                    return out
                }
                return Array(self.utf8)
            }
        }

        final class Reader {
            let input: UnsafeBufferPointer<UInt8>

            init(_ values: [UInt8]) {
                var base: UnsafePointer<UInt8>? = nil
                values.withUnsafeBufferPointer { buffer in
                    base = buffer.baseAddress
                }
                input = UnsafeBufferPointer(
                    start: base, count: values.count)
            }

            convenience init(_ value: String) {
                self.init(value.utf8Array)
            }
        }

        let reader = Reader("AB")
        reader.input[0] + reader.input[1]
        """
        #expect(try eval(source).intValue == 131)
    }

    @Test func inferredArrayRepeatingInitializerUsesAnnotatedElementType() throws {
        let source = """
        final class Trie {
            var children: [Trie?] = .init(repeating: nil, count: 256)
        }

        let root = Trie()
        root.children[44] = Trie()
        root.children[44] != nil
        """
        #expect(try eval(source).boolValue == true)
    }

    @Test func arraySubscriptPreservesDeclaredElementTypeForExtensions() throws {
        let source = """
        extension UInt8 {
            var isSpace: Bool { self == 32 }
        }

        let bytes: [UInt8] = [32]
        bytes[0].isSpace
        """
        #expect(try eval(source).boolValue == true)
    }

    @Test func optionalChainPreservesDeclaredWrappedTypeForExtensions() throws {
        let source = """
        extension UInt8 {
            var isSpace: Bool { self == 32 }
        }

        let bytes: [UInt8] = [32]
        bytes.first?.isSpace ?? false
        """
        #expect(try eval(source).boolValue == true)
    }

    @Test func uint64CarrierSupportsBitPackingOperators() throws {
        let source = """
        var value: UInt64 = 0
        var shift: UInt64 = 0
        let byte: UInt8 = 44
        value |= UInt64(byte) << shift
        shift &+= 8
        Int(value) + Int(shift)
        """
        #expect(try eval(source).intValue == 52)
    }

    @Test func interpretedIntegerIndexedCollectionSupportsForIn() throws {
        let source = """
        struct Slice: RandomAccessCollection {
            let storage: [Int]
            let start: Int
            let end: Int

            var startIndex: Int { 0 }
            var endIndex: Int { end - start }

            subscript(position: Int) -> Int {
                storage[start + position]
            }
        }

        var total = 0
        for value in Slice(storage: [3, 5, 7], start: 1, end: 3) {
            total += value
        }
        total
        """
        #expect(try eval(source).intValue == 12)
    }

    @Test func sugarTypedArrayFilterOverloadRetainsStaticEmptyType() throws {
        let source = """
        struct Cargo { let marker: String }
        struct Other { let marker: String }

        extension [Cargo] {
            func filter(_ query: String) -> Self {
                [Cargo(marker: "cargo:\\(query)")]
            }
        }
        extension [Other] {
            func filter(_ query: String) -> Self {
                [Other(marker: "other:\\(query)")]
            }
        }

        let cargo: [Cargo] = []
        cargo.filter { _ in true }.filter("harbour").first?.marker ?? "nil"
        """
        #expect(try eval(source).stringValue == "cargo:harbour")
    }

    @Test func asCasts() throws {
        let source = """
        struct Item {
            var n = 1
        }
        let any = Item(n: 7)
        let cast = any as? Item
        let bridged = 3 as Double
        let narrowed = 9.9 as Int
        let missing: Int? = nil
        let nilCast = missing as? Int
        "\\(cast?.n ?? -1) \\(bridged) \\(narrowed) \\(nilCast == nil)"
        """
        #expect(try eval(source).stringValue == "7 3.0 9 true")
    }

    @Test func typeDotSelf() throws {
        let source = """
        struct SizeKey {
            static var defaultValue = 0
        }
        let key = SizeKey.self
        let viaSelf = key.defaultValue
        let chained = SizeKey.self.defaultValue
        "\\(viaSelf) \\(chained) \\(5.self)"
        """
        #expect(try eval(source).stringValue == "0 0 5")
    }

    @Test func nestedTypes() throws {
        let source = """
        struct DockProgress {
            enum ProgressType: String {
                case linear
                case circular
            }

            struct Badge {
                var count = 7
            }

            var type: ProgressType = .linear
        }
        let explicit: DockProgress.ProgressType = .circular
        let viaMember = DockProgress.ProgressType.linear
        let badge = DockProgress.Badge()
        let d = DockProgress()
        func describe(t: DockProgress.ProgressType) -> String {
            switch t {
            case .linear: return "lin"
            case .circular: return "circ"
            }
        }
        "\\(explicit.rawValue) \\(viaMember.rawValue) \\(badge.count) \\(describe(t: d.type))"
        """
        #expect(try eval(source).stringValue == "circular linear 7 lin")
    }

    @Test func memberwiseTrailingClosureProperties() throws {
        let source = """
        struct Hook {
            var factor = 1
            var transform: (Int) -> Int
        }
        let h = Hook(factor: 3) { $0 * 2 }
        h.transform(h.factor + 1)
        """
        #expect(try eval(source).intValue == 8)
    }

    @Test func annotatedStaticsAndHostInits() throws {
        let source = """
        struct Item {
            var name = ""
            var tag = 0

            static let samples: [Item] = [.init(name: "a", tag: 1), .init(name: "b", tag: 2)]
        }
        struct Ledger {
            var items: [Item] = []
            mutating func add() {
                items.append(.init(name: "c", tag: 3))
            }
        }
        let second = Item.samples[1].name
        let start: Date = .init()
        let epoch = start.timeIntervalSince1970 > 0.0
        let ledger = Ledger()
        ledger.add()
        "\\(second) \\(epoch) \\(ledger.items[0].tag)"
        """
        let interpreter = Interpreter()
        #expect(try interpreter.run(source: source).stringValue == "b true 3")
    }

    @Test func annotatedImplicitInitAndFactories() throws {
        let source = """
        struct Point {
            var x = 0
            var y = 0

            static func origin() -> Point {
                Point(x: 0, y: 0)
            }

            static let unit = Point(x: 1, y: 1)
        }
        class Store {
            var items: [Int] = [1, 2]
        }
        let p: Point = .init(x: 3, y: 4)
        let o: Point = .origin()
        let u: Point = .unit
        let s: Store = .init()
        let made: [Point] = (1...3).map { .init(x: $0, y: 0) }
        "\\(p.x + p.y) \\(o.x) \\(u.y) \\(s.items.count) \\(made[2].x)"
        """
        #expect(try eval(source).stringValue == "7 0 1 2 3")
    }

    @Test func computedPropertySetters() throws {
        let source = """
        struct Temperature {
            var fahrenheit = 32.0

            var celsius: Double {
                get { (fahrenheit - 32) * 5 / 9 }
                set { fahrenheit = newValue * 9 / 5 + 32 }
            }

            mutating func warmUp() {
                celsius += 10
            }
        }
        let t = Temperature()
        t.celsius = 100.0
        let boiling = t.fahrenheit
        t.warmUp()
        "\\(boiling) \\(t.celsius)"
        """
        #expect(try eval(source).stringValue == "212.0 110.0")
    }

    @Test func customSetterParameterName() throws {
        let source = """
        struct Box {
            var stored = 0
            var doubled: Int {
                get { stored * 2 }
                set(fresh) { stored = fresh / 2 }
            }
        }
        let b = Box()
        b.doubled = 10
        b.stored
        """
        #expect(try eval(source).intValue == 5)
    }

    @Test func getOnlyAssignmentIsError() throws {
        let source = """
        struct S {
            var x: Int { 4 }
        }
        let s = S()
        s.x = 9
        """
        do {
            _ = try eval(source)
            Issue.record("expected an error")
        } catch let e as RuntimeError {
            #expect(e.message.contains("get-only"))
        }
    }

    @Test func propertyObserversRunWithCompiledSemantics() throws {
        // didSet runs on assignment; assigning to the property INSIDE its
        // own didSet writes without re-triggering — native output is 999.
        let source = """
        struct Counter {
            var count = 0 {
                didSet {
                    count = 999
                }
            }
        }
        let c = Counter()
        c.count = 5
        c.count
        """
        #expect(try eval(source).intValue == 999)
    }

    @Test func boolToggle() throws {
        #expect(try eval("var on = false\non.toggle()\non").boolValue == true)
        let viaSelf = """
        struct Switch {
            var flag = true
            mutating func flip() {
                flag.toggle()
            }
        }
        let s = Switch()
        s.flip()
        s.flag
        """
        #expect(try eval(viaSelf).boolValue == false)
        #expect(try eval("var d = [true]\nd[0].toggle()\nd[0]").boolValue == false)
    }

    @Test func toggleFiresStateNotification() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: """
        class Model: ObservableObject {
            @Published var on = false
            func flip() {
                on.toggle()
            }
        }
        let m = Model()
        """)
        guard case .instance(let model)? = interpreter.globals.lookup("m") else {
            Issue.record("expected a model")
            return
        }
        var fires = 0
        model.changeSignal.subscribe(ObjectIdentifier(model)) { fires += 1 }
        try interpreter.run(source: "m.flip()")
        #expect(fires == 1)
        #expect(model.box(for: "on")?.value.boolValue == true)
    }

    @Test func previewMacrosAreInert() throws {
        // Real project files end in #Preview blocks; both the expression and
        // declaration parse forms must be skipped, not errors.
        let source = """
        struct Card: View {
            var body: some View {
                Text("x")
            }
        }

        #Preview {
            Card()
        }

        #Preview("named", traits: .sizeThatFitsLayout) {
            Card()
        }

        7
        """
        #expect(try eval(source).intValue == 7)
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
