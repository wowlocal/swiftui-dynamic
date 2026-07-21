import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// Realm's observation wrappers project like their SwiftUI cousins
/// (SwiftUIRealm, iteration 192): `@ObservedRealmObject var task` gives
/// `$task.member.wrappedValue = …` member bindings (@Bindable-shaped),
/// `@StateRealmObject` owns its object like @StateObject.
@Suite struct RealmWrapperProjectionTests {
    @Test func observedRealmObjectProjectsMemberBindings() throws {
        let source = """
        enum TaskStatus: String {
            case pending, missed, completed
        }

        final class TaskItem: ObservableObject {
            @Published var title = "write tests"
            @Published var taskStatus: TaskStatus = .pending
        }

        struct TaskRow: View {
            @ObservedRealmObject var task: TaskItem

            var body: some View {
                VStack {
                    Text(task.title)
                    Button("Mark Missed") {
                        $task.taskStatus.wrappedValue = .missed
                    }
                    Text(task.taskStatus.rawValue)
                }
            }
        }

        struct ContentView: View {
            @StateRealmObject var task = TaskItem()

            var body: some View {
                TaskRow(task: task)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
        #expect(report.actionsInvoked == 1, "the Mark Missed action must click through the projection")
    }
}

/// `$state` projections: writes through the bound box must be visible on the
/// next body evaluation and fire the state change hook — the same loop
/// Toggle/Slider/TextField drive through their real `Binding` setters.
@Suite struct BindingTests {
    private let source = """
    struct ContentView: View {
        @State var name = ""
        @State var isOn = false
        @State var volume = 5

        var body: some View {
            VStack {
                TextField("Name", text: $name)
                Toggle("Enabled", isOn: $isOn)
                Slider(value: $volume, in: 0...10)
                Text("\\(name): \\(isOn ? "on" : "off") at \\(volume)")
            }
        }
    }
    """

    private func makeInstance() throws -> (Interpreter, Instance) {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            throw RuntimeError(message: "expected an instance")
        }
        return (interpreter, instance)
    }

    @Test func controlsReceiveBindingsToStateBoxes() throws {
        let (interpreter, instance) = try makeInstance()
        let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))

        let textField = try #require(body.findAll("TextField").first)
        let toggle = try #require(body.findAll("Toggle").first)
        let slider = try #require(body.findAll("Slider").first)

        #expect(textField.bindings["text"] != nil)
        #expect(toggle.bindings["isOn"] != nil)
        #expect(slider.bindings["value"] != nil)
        // The stub wraps the instance's actual state box, not a copy.
        #expect(textField.bindings["text"]?.box === instance.stateBoxes["name"])
    }

    @Test func bindingWritesShowUpInNextBodyEvaluation() throws {
        let (interpreter, instance) = try makeInstance()

        func summary() throws -> String? {
            let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            return body.findAll("Text").first?.args.first
        }
        #expect(try summary() == ": off at 5")

        let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        var changes = 0
        instance.stateBoxes["isOn"]?.onChange = { changes += 1 }

        try #require(body.findAll("TextField").first?.bindings["text"]).box.value = .native("Ada")
        try #require(body.findAll("Toggle").first?.bindings["isOn"]).box.value = .native(true)
        try #require(body.findAll("Slider").first?.bindings["value"]).box.value = .native(9)

        #expect(changes == 1)
        #expect(try summary() == "Ada: on at 9")
    }

    @Test func realRegistryRendersBindingControls() throws {
        let outcome = InterpreterHost().render(source: source)
        if case .failure(let error) = outcome {
            Issue.record("render failed: \(error)")
        }
    }

    @Test func wrappedValueReadsAndWritesThroughTheBox() throws {
        let source = """
        struct ContentView: View {
            @State var n = 1

            var body: some View {
                VStack {
                    Text("value \\($n.wrappedValue)")
                    Button("bump") {
                        $n.wrappedValue += 4
                    }
                }
            }
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }
        let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(body.findAll("Text").first?.args.first == "value 1")
        _ = try interpreter.callClosure(
            try #require(body.findAll("Button").first?.actions["action"]), arguments: []
        )
        let rerendered = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(rerendered.findAll("Text").first?.args.first == "value 5")
    }

    @Test func projectionWithoutStatePropertyIsLocatedError() throws {
        // Body evaluation is lazy (InterpreterHost.render only wraps the root),
        // so evaluate the body directly to observe the located error.
        let bad = """
        struct ContentView: View {
            var body: some View {
                Toggle("x", isOn: $missing)
            }
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: bad)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }
        do {
            _ = try interpreter.evaluateBody(of: instance)
            Issue.record("expected an error")
        } catch let error as RuntimeError {
            #expect(error.message.contains("@State"))
            #expect(error.line == 3)
        }
    }
}

/// The @State BACKING-store init spelling (IceCubes' StatusesListView):
/// `_fetcher = .init(initialValue: fetcher)` seeds the state box with the
/// PASSED value — a generic-annotated property must not decay to a marker
/// (the switch over its members would take the first case forever).
@Suite struct StateBackingInitTests {
    @Test func underscoreInitSeedsGenericStateBox() async throws {
        let source = """
        protocol Fetching {
            var state: String { get }
        }

        @Observable
        final class TimelineVM: Fetching {
            var state = "loaded"
        }

        struct ListView<F: Fetching>: View {
            @State private var fetcher: F

            init(fetcher: F) {
                _fetcher = .init(initialValue: fetcher)
            }

            var body: some View {
                Text(fetcher.state)
            }
        }

        struct ContentView: View {
            var body: some View {
                ListView(fetcher: TimelineVM())
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("loaded"), "the seeded VM must reach the body, got \(strings)")
    }

    /// Distilled from IceCubes' `StatusRowView`, whose synthesized memberwise
    /// initializer accepts a model through an `@State`-wrapped property.
    @Test func synthesizedInitializerSeedsStateWrappedModel() async throws {
        let source = """
        struct RowModel {
            let title: String
        }

        struct RowView: View {
            @State var model: RowModel
            let context: String

            var body: some View {
                Text(context + ":" + model.title)
            }
        }

        struct ContentView: View {
            var body: some View {
                RowView(model: RowModel(title: "fixture"), context: "timeline")
            }
        }
        """

        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("timeline:fixture"), "the memberwise seed must reach the body, got \(strings)")
    }

}

/// ForEach element-identity SALTING (iteration 194): sibling rows
/// constructed at the same call site keep DISTINCT per-view state — the
/// cell key carries the element identity (id/scalar/index), so row N's
/// @State seed doesn't clobber row N+1's (the IceCubes StatusRowView
/// shape). AttributedString's labeled ctors wrap/convert for real, and
/// one-argument `insert` on Set-typed storage appends-if-absent.
@Suite struct RowIdentityAndSetInsertTests {
    @Test func forEachRowsKeepDistinctState() async throws {
        let source = """
        struct Item: Identifiable {
            let id: String
            let title: String
        }

        struct RowView: View {
            @State private var label: String

            init(item: Item) {
                _label = .init(initialValue: item.title)
            }

            var body: some View {
                Text(label)
            }
        }

        struct ContentView: View {
            let items = [
                Item(id: "a", title: "alpha"),
                Item(id: "b", title: "beta"),
                Item(id: "c", title: "gamma"),
            ]

            var body: some View {
                ForEach(items) { item in
                    RowView(item: item)
                }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("alpha") && strings.contains("beta") && strings.contains("gamma"),
                "each row must keep its own @State seed, got \(strings)")
    }

    @Test func attributedStringLabeledConstructorsAndSetInsert() async throws {
        let source = """
        final class Registry {
            static var observed: Set<String> = []
        }

        struct ContentView: View {
            var body: some View {
                let _ = Registry.observed.insert("scene-1")
                let _ = Registry.observed.insert("scene-1")
                let _ = Registry.observed.insert("scene-2")
                let literal = AttributedString(stringLiteral: "Sun Dog")
                let markdown = AttributedString(markdown: "plain **bold** text")
                return VStack {
                    Text(literal)
                    Text(markdown)
                    Text("count \\(Registry.observed.count)")
                }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("Sun Dog"), "stringLiteral ctor must carry the text, got \(strings)")
        #expect(strings.contains { $0.contains("plain") && $0.contains("bold") },
                "markdown ctor must convert to readable text, got \(strings)")
        #expect(strings.contains("count 2"), "set insert must dedupe, got \(strings)")
    }
}

/// Foundation's attributed-text surface is a collection pipeline, not just a
/// scalar conversion: EmojiText walks `runs`, slices by each run's range, and
/// reduces those `AttributedSubstring` values back into an `AttributedString`.
/// Keep the distilled shape native-valid and require the interpreted render to
/// preserve the same visible text.
@Suite struct AttributedStringCollectionTests {
    @Test func throwingConversionPreservesFallbackForOpaqueParserOutput() async throws {
        let source = ProjectMaterial.mergedSource(source: """
        import OpaqueMarkdown
        import SwiftUI

        struct PartialText {
            var substrings: [AttributedSubstring] = []

            mutating func append(_ substring: AttributedSubstring) {
                substrings.append(substring)
            }

            mutating func consume() -> [AttributedSubstring] {
                defer { substrings = [] }
                return substrings
            }
        }

        extension AttributedString.Runs.Element {
            func emoji(from values: [String: String]) -> String? {
                guard let imageURL = attributes[
                    AttributeScopes.FoundationAttributes.ImageURLAttribute.self
                ] else { return nil }
                guard imageURL.scheme == "emoji" else { return nil }
                guard let host = imageURL.host else { return nil }
                return values[host]
            }
        }

        extension Text {
            init?(_ partial: inout PartialText) {
                self.init(attributedSubstrings: partial.consume())
            }

            init?(attributedSubstrings: [AttributedSubstring]) {
                guard !attributedSubstrings.isEmpty else { return nil }
                let joined = attributedSubstrings.reduce(AttributedString()) {
                    value, substring in value + substring
                }
                self.init(joined)
            }
        }

        extension [Text] {
            func joined() -> Text {
                guard var result = first else { return Text(verbatim: "") }
                for element in dropFirst() { result = result + element }
                return result
            }
        }

        func converted(_ raw: String) -> AttributedString {
            do {
                let document = OpaqueDocument(parsing: raw)
                let markdown = document.format().joined()
                return try AttributedString(markdown: markdown)
            } catch {
                return AttributedString(stringLiteral: raw)
            }
        }

        func rendered(_ raw: String) -> Text {
            let attributed = converted(raw)
            var result = Text(verbatim: "")
            var partial = PartialText()
            let emojis: [String: String] = [:]
            for run in attributed.runs {
                if let emoji = run.emoji(from: emojis) {
                    result = result + Text(emoji)
                } else {
                    partial.append(attributed[run.range])
                }
            }
            return [result, Text(&partial)].compactMap { $0 }.joined()
        }

        struct ContentView: View {
            var body: some View {
                rendered("verbatim fallback")
            }
        }
        """, moduleName: "Client")

        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("verbatim fallback"),
                "a rejected opaque conversion must enter the source fallback, got \(strings)")
    }

    @Test func runsSliceAndReduceBackIntoRenderableText() async throws {
        let native = AttributedString("booster")
        #expect(native.runs.count == 1)
        #expect(String(native.characters) == "booster")
        #expect(native.runs.first?.attributes[
            AttributeScopes.FoundationAttributes.ImageURLAttribute.self
        ] == nil)

        let source = """
        struct PartialAttributedString {
            var substrings: [AttributedSubstring] = []

            mutating func append(_ substring: AttributedSubstring) {
                substrings.append(substring)
            }

            mutating func consume() -> [AttributedSubstring] {
                defer { substrings = [] }
                return substrings
            }
        }

        extension Text {
            init?(_ partial: inout PartialAttributedString) {
                let substrings = partial.consume()
                guard !substrings.isEmpty else { return nil }
                let joined = substrings.reduce(AttributedString()) {
                    value, substring in value + substring
                }
                self.init(joined)
            }
        }

        extension [Text] {
            func joined() -> Text {
                guard var result = first else { return Text(verbatim: "") }
                for element in dropFirst() {
                    result = result + element
                }
                return result
            }
        }

        func rendered(_ raw: String) -> Text {
            let attributed = AttributedString(raw)
            var partial = PartialAttributedString()
            for run in attributed.runs {
                if let _ = run.attributes[
                    AttributeScopes.FoundationAttributes.ImageURLAttribute.self
                ] {
                    continue
                } else {
                    partial.append(attributed[run.range])
                }
            }
            return [Text(verbatim: ""), Text(&partial)]
                .compactMap { $0 }
                .joined()
        }

        struct ContentView: View {
            var body: some View {
                rendered("booster")
            }
        }
        """

        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("booster"), "attributed runs must preserve text, got \(strings)")
    }

    @Test func computedTextSurvivesTaskPriorityModifier() async throws {
        let source = """
        extension [Text] {
            func joined() -> Text {
                guard var result = first else { return Text(verbatim: "") }
                for element in dropFirst() { result = result + element }
                return result
            }
        }

        protocol TextRenderer {
            func render(_ value: String) -> Text
        }

        struct ConcreteTextRenderer: TextRenderer {
            func render(_ value: String) -> Text {
                [Text(verbatim: ""), Text(value)]
                    .compactMap { $0 }
                    .joined()
            }
        }

        struct ContentView: View {
            let renderer: any TextRenderer = ConcreteTextRenderer()
            let prepend: (() -> Text)? = nil
            let append: (() -> Text)? = nil

            var makeContent: Text {
                let result: Text
                if true {
                    result = renderer.render("booster")
                } else {
                    result = Text(verbatim: "fallback")
                }
                return [prepend?(), result, append?()]
                    .compactMap { $0 }.joined()
            }

            var body: some View {
                makeContent.task(id: 0, priority: .high) {}
            }
        }
        """

        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("booster"),
                "a lifecycle modifier must retain its computed Text receiver, got \(strings)")
    }
}
