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
