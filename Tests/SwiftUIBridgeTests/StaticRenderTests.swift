import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

private func traceRun(_ source: String) throws -> (interpreter: Interpreter, result: RuntimeValue) {
    let interpreter = Interpreter(registry: TraceRegistry())
    let result = try interpreter.run(source: source)
    return (interpreter, result)
}

@Suite struct StaticRenderTests {
    @Test func textWithModifiers() throws {
        let (_, result) = try traceRun(#"Text("hi").padding().font(.title)"#)
        let node = try TraceRegistry.node(result)
        #expect(node.kind == "Text")
        #expect(node.args == ["hi"])
        #expect(node.modifiers == ["padding", "font(.title)"])
    }

    @Test func genericRecorderPublishesOnlyDirectScalarArguments() throws {
        let source = """
        struct Payload {
            let title: String
            let values: [String]
        }

        OpaqueWidget(
            "visible",
            payload: Payload(title: "configuration", values: ["nested"]))
        """

        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.args == ["visible"])
        #expect(node.config.keys.contains("payload"))
    }

    /// Generic recorder nodes also stand for native views. Their dynamic
    /// fallback members must not swallow a declared View modifier before its
    /// result-builder closure can be composed into the render tree.
    @Test func viewModifierBuilderPrecedesOpaqueMemberFallback() throws {
        let source = """
        RoundedRectangle(cornerRadius: 10)
            .overlay {
                Text("overlay leaf")
            }
        """

        // The production registry dispatches this source through real
        // SwiftUI, establishing that the distilled source is native-valid.
        _ = try Interpreter(registry: ViewRegistry()).run(source: source)

        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.children.map(\.args).contains(["overlay leaf"]),
                "the dynamic member fallback swallowed the builder: \(node.children)")
    }

    @Test func stackCollectsChildren() throws {
        let source = """
        VStack(spacing: 8) {
            Text("a")
            Text("b")
        }
        """
        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.kind == "VStack")
        #expect(node.children.count == 2)
        #expect(node.children.map(\.kind) == ["Text", "Text"])
        #expect(node.children.map(\.args) == [["a"], ["b"]])
    }

    /// IceCubes qualifies `SwiftUI.List` to avoid its model-layer `List`
    /// symbol. Module qualification must retain the ordinary trailing
    /// result-builder argument, just as the native constructor call does.
    @Test func namespacedContainerPreservesTrailingBuilder() throws {
        let source = """
        import SwiftUI

        struct FixtureRow: View {
            var body: some View { Text("fixture row") }
        }

        SwiftUI.List {
            FixtureRow()
        }
        """

        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.kind == "List")
        #expect(node.children.count == 1)
        #expect(node.children.first?.instance?.symbol.name == "FixtureRow")
    }

    @Test func forEachOverRange() throws {
        let source = """
        ForEach(0..<3) { i in
            Text("Row \\(i)")
        }
        """
        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.kind == "ForEach")
        #expect(node.children.count == 3)
        #expect(node.children.last?.args == ["Row 2"])
    }

    @Test func forEachOverArray() throws {
        let source = """
        ForEach(["x", "y"], id: \\.self) { s in
            Text(s)
        }
        """
        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.children.map(\.args) == [["x"], ["y"]])
    }

    @Test func materializedForEachRowsHaveIndependentFiniteBudgets() throws {
        let source = """
        ForEach(0..<30) { row in
            var cursor = 0
            while cursor < 1_000 {
                cursor += 1
            }
            Text("Row \\(row): \\(cursor)")
        }
        """

        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.children.count == 30)
        #expect(node.children.last?.args == ["Row 29: 1000"])
    }

    @Test func finiteHostIterationStillRejectsAnInfiniteElement() {
        #expect(throws: RuntimeError.self) {
            try traceRun("""
            ForEach(0..<1) { _ in
                while true {}
                Text("unreachable")
            }
            """)
        }
    }

    @Test func builderIfIncludesOnlyTakenBranch() throws {
        let source = """
        VStack {
            if true {
                Text("yes")
            }
            if false {
                Text("no")
            } else {
                Text("fallback")
            }
        }
        """
        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.children.map(\.args) == [["yes"], ["fallback"]])
    }

    @Test func userViewStructRenders() throws {
        let source = """
        struct Card: View {
            var title = "untitled"

            var body: some View {
                Text(title)
            }
        }

        struct ContentView: View {
            var body: some View {
                VStack {
                    Card(title: "hello")
                    Card()
                }
            }
        }
        """
        let (interpreter, _) = try traceRun(source)
        let symbol = try #require(interpreter.rootViewSymbol())
        #expect(symbol.name == "ContentView")
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }
        let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(body.kind == "VStack")
        #expect(body.children.map(\.kind) == ["View:Card", "View:Card"])

        // Evaluate the nested interpreted view's body too.
        let card = try #require(body.children.first?.instance)
        let cardBody = try TraceRegistry.node(interpreter.evaluateBody(of: card))
        #expect(cardBody.args == ["hello"])
    }

    @Test func buttonRecordsTitleAndAction() throws {
        let (_, result) = try traceRun(#"Button("tap") { }"#)
        let node = try TraceRegistry.node(result)
        #expect(node.kind == "Button")
        #expect(node.args == ["tap"])
        #expect(node.actions["action"] != nil)
    }

    @Test func realRegistryRendersCounterSource() throws {
        let source = """
        struct ContentView: View {
            @State var count = 0

            var body: some View {
                VStack(spacing: 16) {
                    Text("Count: \\(count)")
                        .font(.largeTitle)
                    HStack(spacing: 12) {
                        Button("-") {
                            count -= 1
                        }
                        Button("+") {
                            count += 1
                        }
                    }
                }
                .padding()
            }
        }
        """
        let outcome = InterpreterHost().render(source: source)
        switch outcome {
        case .success:
            break
        case .failure(let error):
            Issue.record("render failed: \(error)")
        }
    }

    @Test func realRegistryRendersNavigationSplitViewAndValueLink() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let result = try interpreter.run(source: """
        NavigationSplitView {
            NavigationLink(value: "truck") {
                Text("Truck")
            }
        } detail: {
            Text("Dashboard")
        }
        """)

        #expect(registry.isViewValue(result))
    }

    @Test func pathBoundNavigationStackPreservesRootContent() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        _ = try interpreter.run(source: """
        struct ContentView: View {
            @State var path = NavigationPath()
            var body: some View {
                NavigationStack(path: $path) {
                    Text("Dashboard")
                }
            }
        }
        """)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
            Issue.record("expected ContentView instance")
            return
        }
        let result = try interpreter.evaluateBody(of: instance)
        #expect(registry.isViewValue(result))
    }

    @Test func realRegistryAcceptsLegacyOneParameterOnChange() throws {
        let outcome = InterpreterHost().render(source: """
        struct ContentView: View {
            @State var selection = "truck"

            var body: some View {
                Text(selection)
                    .onChange(of: selection) { newValue in
                        selection = newValue
                    }
            }
        }
        """)

        if case .failure(let error) = outcome {
            Issue.record("render failed: \(error)")
        }
    }

    @Test func iOSAppLifecycleModifiersPreserveContent() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        _ = try interpreter.run(source: """
        struct DeferredKey: PreferenceKey {
            static var defaultValue = false
        }
        struct ContentView: View {
            var body: some View {
                Text("Dashboard")
                    .onPreferenceChange(DeferredKey.self) { _ in }
                    .onOpenURL { _ in }
            }
        }
        """)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
            Issue.record("expected ContentView instance")
            return
        }
        let result = try interpreter.evaluateBody(of: instance)
        #expect(registry.isViewValue(result))
    }

    @Test func realRegistryRendersGridRowsAndEmptyBackground() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let result = try interpreter.run(source: """
        Grid(horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Orders")
                Text("Weather")
            }
        }
        .background()
        """)

        #expect(registry.isViewValue(result))
    }

    @Test func navigationDestinationKeepsCurrentContentRenderable() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let result = try interpreter.run(source: """
        Text("Dashboard")
            .navigationDestination(for: String.self) { value in
                Text(value)
            }
        """)

        #expect(registry.isViewValue(result))
    }

    @Test func namedProjectImageIsRenderable() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let result = try interpreter.run(source: #"Image("header/truck", bundle: .module)"#)
        #expect(registry.isViewValue(result))
    }

    @Test func containerShapeKeepsGridRenderable() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let result = try interpreter.run(source: """
        Grid { Text("Card") }
            .containerShape(RoundedRectangle(cornerRadius: 12))
        """)
        #expect(registry.isViewValue(result))
    }

    @Test func paddingAcceptsArrayLiteralAndDedicatedEdgeSet() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let literal = try interpreter.run(
            source: #"Text("Card").padding([.horizontal, .bottom], 16)"#)
        #expect(registry.isViewValue(literal))

        let dedicated = try interpreter.run(source: #"""
        let edges: Set<Edge> = [.horizontal, .bottom]
        Text("Card").padding(edges, 16)
        """#)
        #expect(registry.isViewValue(dedicated))
    }

    @Test func parenthesizedCustomLayoutBuildsContent() throws {
        let source = """
        struct FlowLayout: Layout {
            var spacing: Double = 8
        }

        (FlowLayout(spacing: 10)) {
            Text("one")
            Text("two")
        }
        """
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let result = try interpreter.run(source: source)
        #expect(registry.isViewValue(result))
    }

    @Test func labelAcceptsTitleAndIconBuilders() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let result = try interpreter.run(source: """
        Label {
            Text("Donuts")
        } icon: {
            Image(systemName: "circle")
        }
        """)
        #expect(registry.isViewValue(result))
    }

    @Test func chartSurfaceSurvivesChartModifiersAndFrame() throws {
        let registry = ViewRegistry()
        #expect(registry.modifiers["chartYScale"] == nil)
        #expect((GeneratedModifiers.table["chartYScale"]?.count ?? 0) > 0)
        let interpreter = Interpreter(registry: registry)
        let result = try interpreter.run(source: """
        Chart {
            AreaMark(x: .value("Day", 1), y: .value("Sales", 2))
        }
        .chartXAxis { AxisMarks() }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis { AxisMarks() }
        .frame(minHeight: 180)
        """)
        #expect(registry.isViewValue(result))
    }

    @Test func animationCombinatorChainRenders() throws {
        let source = """
        struct ContentView: View {
            @State var spin = false

            var body: some View {
                Text("wave")
                    .scaleEffect(spin ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.4).delay(0.1).repeatForever(autoreverses: true), value: spin)
                    .animation(.linear.speed(2).repeatCount(3), value: spin)
            }
        }
        """
        let outcome = InterpreterHost().render(source: source)
        if case .failure(let error) = outcome {
            Issue.record("render failed: \(error)")
        }
    }

    @Test func doubleStyleChainRenders() throws {
        let outcome = InterpreterHost().render(
            source: #"Text("x").background(.blue.opacity(0.3).gradient)"#
        )
        if case .failure(let error) = outcome {
            Issue.record("render failed: \(error)")
        }
    }

    /// A user View extension can shadow a built-in modifier under different
    /// labels; calls that don't bind the extension retry the modifier table.
    @Test func extensionShadowedModifierRetriesBuiltin() throws {
        let source = """
        extension View {
            func offset(coordinateSpace: String, completion: (CGFloat) -> Void) -> some View {
                self
            }

            func offset(named name: String) -> some View {
                self
            }
        }

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("builtin").offset(x: 12, y: 4)
                    Text("custom").offset(coordinateSpace: "SCROLL") { _ in }
                }
            }
        }
        """
        let outcome = InterpreterHost().render(source: source)
        if case .failure(let error) = outcome {
            Issue.record("render failed: \(error)")
        }
    }

    /// An implicit static member is viable only for overload parameter types
    /// that actually declare that member. A source View overload must not
    /// claim a native Font value merely because the argument is still an
    /// unresolved `.preset` marker at the call site.
    @Test func contextualStaticMemberChoosesImportedModifier() throws {
        let source = """
        struct SourceStyle {
            let label: String
        }

        extension View {
            func font(_ style: SourceStyle) -> some View {
                Text("source \\(style.label)")
            }
        }

        extension Font {
            static let preset = Font.system(size: 16)
        }

        Text("native").font(.preset)
        """

        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.args == ["native"])
        #expect(node.modifiers == ["font(.preset)"])
    }

    /// A generated modifier whose labels fit remains viable when no argument
    /// needs contextual static-member lookup. An incompatible source overload
    /// must not turn ordinary generated dispatch into "no matching overload".
    @Test func generatedModifierWithoutContextualMarkerKeepsFallback() throws {
        let source = """
        extension View {
            func offset(
                _ coordinateSpace: String,
                completion: (CGRect) -> Void
            ) -> some View {
                Text("source \\(coordinateSpace)")
            }
        }

        Text("native").offset(y: 5)
        """

        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.args == ["native"])
        #expect(node.modifiers == ["offset(y: 5)"])
    }

    /// Chaining from an unresolved leading-dot value remains provisional for
    /// source overload matching just like the root marker itself.
    @Test func chainedContextualMemberKeepsSourceOverloadViable() throws {
        let source = """
        extension View {
            func border(_ width: CGFloat, _ color: Color) -> some View {
                Text("source")
            }
        }

        Text("native").border(1, .gray.opacity(0.5))
        """

        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.args == ["source"])
    }

    /// A same-name generated modifier that owns no matching call shape does
    /// not make an opaque imported source parameter fail closed.
    @Test func noncompetingModifierKeepsOpaqueSourceShapeDispatch() throws {
        let source = """
        extension View {
            func offset(
                _ coordinateSpace: AnyHashable,
                completion: (CGRect) -> Void
            ) -> some View {
                Text("source")
            }
        }

        Text("native").offset("CONTENTVIEW") { _ in }
        """

        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.args == ["source"])
    }

    /// Protocol-extension overloads whose imported argument values remain
    /// opaque still dispatch by their source labels. They must not enter the
    /// concrete-host overload matcher merely because the receiver conforms to
    /// the extended protocol.
    @Test func protocolExtensionOpaqueOverloadUsesSourceLabelDispatch() throws {
        let source = """
        extension View {
            func onKeyboardShortcut(
                _ shortcut: KeyboardShortcut?,
                perform action: @escaping () -> Void
            ) -> some View {
                self
            }

            func onKeyboardShortcut(
                _ key: KeyEquivalent,
                modifiers: SwiftUI.EventModifiers = .command,
                isEnabled: Bool = true,
                perform action: @escaping () -> Void
            ) -> some View {
                self
            }
        }

        Text("shortcut")
            .onKeyboardShortcut(.escape, modifiers: []) {}
        """
        _ = try Interpreter(registry: ViewRegistry()).run(source: source)
    }

    /// IceCubes' `ConditionalModifier.swift` declares the keyword-named
    /// helper as ``func `if`(...)``. Swift resolves an escaped declaration
    /// through the unescaped `.if(...)` member spelling; the false builder
    /// branch therefore returns the original rendered view before later
    /// modifiers are applied.
    @Test func escapedGenericViewExtensionKeepsRenderedReceiver() throws {
        let source = """
        extension View {
            @ViewBuilder
            func `if`<Content: View>(
                _ condition: Bool,
                transform: (Self) -> Content
            ) -> some View {
                if condition {
                    transform(self)
                } else {
                    self
                }
            }
        }

        Text("kept")
            .if(false) { $0.opacity(0) }
            .padding()
        """

        let (_, result) = try traceRun(source)
        let node = try TraceRegistry.node(result)
        #expect(node.kind == "Text")
        #expect(node.args == ["kept"])
        #expect(node.modifiers == ["padding"])
    }

    /// The Chips pattern: a user String extension named `size` wrapping the
    /// NSString measurement API. The extension must win plain member access
    /// while the inner labeled call reaches real font metrics.
    @Test func textMeasurementCoexistsWithUserSizeExtension() throws {
        let source = """
        extension String {
            func size(_ font: UIFont) -> CGSize {
                let attributes = [NSAttributedString.Key.font: font]
                return self.size(withAttributes: attributes)
            }
        }

        struct ContentView: View {
            var body: some View {
                let width = "Chip".size(.preferredFont(forTextStyle: .body)).width
                Text(width > 5 ? "measured" : "empty")
            }
        }
        """
        let outcome = InterpreterHost().render(source: source)
        if case .failure(let error) = outcome {
            Issue.record("render failed: \(error)")
        }
    }

    @Test func unknownModifierIsLocatedError() throws {
        let outcome = InterpreterHost().render(source: #"Text("x").wobble()"#)
        switch outcome {
        case .success:
            Issue.record("expected failure")
        case .failure(let error):
            #expect(error.message.contains("wobble"))
            #expect(error.line == 1)
        }
    }
}
