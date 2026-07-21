import AppKit
import SwiftUI
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// Breadth probes for the GENERATED gateway table: every modifier here was
/// never hand-written — it exists only because BridgeGen emitted it from the
/// SDK's swiftinterface and the ArgumentMatcher dispatched it.
@Suite struct GeneratedModifierTests {
    @Test func generatedTableIsSubstantial() {
        #expect(GeneratedModifiers.table.count >= 130)
        let variants = GeneratedModifiers.table.values.map(\.count).reduce(0, +)
        #expect(variants >= 420)
        for set in GeneratedModifiers.table.values {
            for (arity, overloads) in set.byArity {
                #expect(overloads.allSatisfy { $0.params.count == arity })
            }
        }
    }

    @Test func generatedModifiersDispatchThroughRealRendering() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("typography")
                        .kerning(1.5)
                        .tracking(0.5)
                        .baselineOffset(2)
                        .lineSpacing(4)
                        .allowsHitTesting(true)
                        .accessibilityLabel("probe label")
                    Text("effects")
                        .hueRotation(.degrees(45))
                        .contrast(1.2)
                        .flipsForRightToLeftLayoutDirection(false)
                        .drawingGroup()
                    Text("sdk enums")
                        .blendMode(.multiply)
                        .controlSize(.regular)
                        .fontDesign(.serif)
                        .preferredColorScheme(.dark)
                        .textCase(.uppercase)
                        .truncationMode(.tail)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: source) {
        case .failure(let error):
            Issue.record("render failed: \(error)")
        case .success(let view):
            let hosting = NSHostingView(rootView: view.frame(width: 300, height: 300))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for (viewName, error) in RenderDiagnostics.errors {
                Issue.record("\(viewName): \(error)")
            }
        }
    }

    @Test func suffixDefaultVariantsMatchBothCallShapes() throws {
        // autocorrectionDisabled() and autocorrectionDisabled(false) are the
        // zero-arg and full variants of one defaulted-parameter overload.
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: #"Text("a").autocorrectionDisabled()"#)
        _ = try interpreter.run(source: #"Text("b").autocorrectionDisabled(false)"#)
    }

    @Test func mismatchedArgumentsAreLocatedErrors() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        do {
            _ = try interpreter.run(source: #"Text("x").kerning("nope")"#)
            Issue.record("expected a dispatch error")
        } catch let error as RuntimeError {
            #expect(error.message.contains("no matching overload"))
            #expect(error.line == 1)
        }
    }

    @Test func generatedConstructorsAreSubstantial() {
        #expect(GeneratedConstructors.table.count >= 25)
        let variants = GeneratedConstructors.table.values.map(\.count).reduce(0, +)
        #expect(variants >= 110)
        for set in GeneratedConstructors.table.values {
            for (arity, overloads) in set.byArity {
                #expect(overloads.allSatisfy { $0.params.count == arity })
            }
        }
    }

    @Test func sdkBuilderAndFoundationShapesAreGenerated() {
        let form = GeneratedConstructors.table["Form"]?.byArity[1] ?? []
        #expect(form.contains { $0.params.map(\.tag) == [.builder] })

        let verticalStack = GeneratedConstructors.table["VStack"]?.byArity[2] ?? []
        #expect(verticalStack.contains {
            $0.params.map(\.label) == ["spacing", "content"]
                && $0.params.map(\.tag) == [.cgFloat, .builder]
        })

        let split = GeneratedConstructors.table["NavigationSplitView"]?.byArity[2] ?? []
        #expect(split.contains { $0.params.map(\.tag) == [.builder, .builder] })

        let unavailable = GeneratedConstructors.table["ContentUnavailableView"]?.byArity[3] ?? []
        #expect(unavailable.contains {
            $0.params.map(\.label) == [nil, "systemImage", "description"]
                && $0.params.map(\.tag) == [.string, .string, .text]
        })

        let asyncImage = GeneratedConstructors.table["AsyncImage"]?.byArity[1] ?? []
        #expect(asyncImage.contains { $0.params.map(\.tag) == [.url] })

        let link = GeneratedConstructors.table["Link"]?.byArity[2] ?? []
        #expect(link.contains { $0.params.map(\.tag) == [.url, .builder] })

        let alert = GeneratedModifiers.table["alert"]?.byArity[3] ?? []
        #expect(alert.contains {
            $0.params.map(\.tag) == [.string, .bindingBool, .builder]
        })

        let navigationDocument = GeneratedModifiers.table["navigationDocument"]?.byArity[1] ?? []
        #expect(navigationDocument.contains { $0.params.map(\.tag) == [.url] })

        let blendMode = GeneratedModifiers.table["blendMode"]?.byArity[1] ?? []
        #expect(blendMode.contains {
            $0.params.map(\.tag) == [.sdkEnum("BlendMode")]
        })
    }

    @Test func generatedSDKEnumsCoerceImplicitMembers() throws {
        let blend = try GeneratedSDKEnumCoercions.coerce(
            "BlendMode", .implicitMember("multiply")) as? BlendMode
        #expect(blend == .multiply)

        let design = try GeneratedSDKEnumCoercions.coerce(
            "Font.Design", .implicitMember("default")) as? Font.Design
        #expect(design == .default)

        #expect(throws: RuntimeError.self) {
            _ = try GeneratedSDKEnumCoercions.coerce(
                "BlendMode", .implicitMember("notARealCase"))
        }
    }

    /// IceCubes' DesignSystem extends Font with scaledBody/scaledSubheadline.
    /// Native Swift resolves the leading-dot member from font(_:) parameter
    /// context; the bridge must do the same for every source extension static.
    @Test func sourceExtensionStaticUsesGeneratedParameterTypeContext() throws {
        let registry = ViewRegistry()
        let result = try Interpreter(registry: registry).run(source: """
        @MainActor
        extension Font {
            static var fixtureScaledBody: Font { .body }
        }

        Text("typed source static").font(.fixtureScaledBody)
        """)
        #expect(registry.isViewValue(result))
    }

    /// The SDK spells contextual constants on both ordinary value structs and
    /// nested OptionSets. They are the same interface property: a public static
    /// member whose declared value type is its enclosing type.
    @Test func sameTypeSDKStaticsGenerateModifierCoverage() throws {
        let accessibility = GeneratedModifiers.table["accessibilityElement"]?
            .byArity[1] ?? []
        #expect(accessibility.contains {
            $0.params.map(\.tag) == [.sdkEnum("AccessibilityChildBehavior")]
        })

        let separator = GeneratedModifiers.table["listRowSeparator"]?
            .byArity[2] ?? []
        #expect(separator.contains {
            $0.params.map(\.tag) == [
                .visibility, .sdkEnum("VerticalEdge.Set"),
            ]
        })

        let behavior = try GeneratedSDKEnumCoercions.coerce(
            "AccessibilityChildBehavior", .implicitMember("combine"))
            as? AccessibilityChildBehavior
        #expect(behavior == .combine)

        let edges = try GeneratedSDKEnumCoercions.coerce(
            "VerticalEdge.Set", .implicitMember("all")) as? VerticalEdge.Set
        #expect(edges == .all)

        _ = try Interpreter(registry: ViewRegistry()).run(source: """
        Text("accessible")
            .accessibilityElement(children: .combine)
            .listRowSeparator(.hidden, edges: .all)
        """)
    }

    /// SetAlgebra contextual values also accept Swift's array-literal syntax.
    /// IceCubes composes accessibility traits this way, including an empty
    /// literal selected by a conditional expression.
    @Test func generatedSDKSetAlgebraCoercesArrayLiterals() throws {
        let traits = try GeneratedSDKEnumCoercions.coerce(
            "AccessibilityTraits",
            .array([.implicitMember("isButton"), .implicitMember("isImage")]))
            as? AccessibilityTraits
        #expect(traits?.contains(.isButton) == true)
        #expect(traits?.contains(.isImage) == true)

        let empty = try GeneratedSDKEnumCoercions.coerce(
            "AccessibilityTraits", .array([])) as? AccessibilityTraits
        #expect(empty?.isEmpty == true)

        _ = try Interpreter(registry: ViewRegistry()).run(source: """
        let selected = true
        Text("accessible")
            .accessibilityAddTraits([.isButton, .isImage])
            .accessibilityAddTraits(selected ? .isSelected : [])
        """)
    }

    @Test func generatedConstructorsDispatchThroughRealRendering() throws {
        // None of these View inits were ever hand-written.
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack(spacing: 11) {
                    HStack(spacing: 7) {
                        Text("Defaults before builders")
                        Text("work")
                    }
                    ContentUnavailableView("No results", systemImage: "magnifyingglass")
                    ContentUnavailableView {
                        Label("Generated builder", systemImage: "wand.and.stars")
                    } description: {
                        Text("Builder attributes came from the SDK interface")
                    }
                    Link("Generated URL", destination: URL(string: "https://example.com")!)
                    Button("Generated asset", image: "bridgegen-missing-asset") {}
                    RenameButton()
                    EmptyView()
                    AngularGradient(gradient: Gradient(colors: [.red, .blue]), center: .center)
                        .frame(width: 40, height: 40)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: source) {
        case .failure(let error):
            Issue.record("render failed: \(error)")
        case .success(let view):
            let hosting = NSHostingView(rootView: view.frame(width: 300, height: 400))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for (viewName, error) in RenderDiagnostics.errors {
                Issue.record("\(viewName): \(error)")
            }
        }
    }

    @Test func taskObservatoryExampleDispatchesThroughRealRendering() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectRoot = repositoryRoot
            .appendingPathComponent("Examples/TaskObservatory")
            .path
        let source = ProjectMaterial.mergedSource(at: projectRoot)

        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: source) {
        case .failure(let error):
            Issue.record("TaskObservatory render failed: \(error)")
        case .success(let view):
            let hosting = NSHostingView(rootView: view.frame(width: 980, height: 720))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for (viewName, error) in RenderDiagnostics.errors {
                Issue.record("\(viewName): \(error)")
            }
        }
    }

    @Test func colorsActAsViews() throws {
        // Bare colors, opacity chains, and view modifiers on colors.
        let interpreter = Interpreter(registry: TraceRegistry())
        let result = try interpreter.run(source: """
        VStack {
            Color.clear
            Color.black.opacity(0.3)
            Color.red.frame(height: 4.0)
        }
        """)
        let node = try TraceRegistry.node(result)
        #expect(node.children.count == 3)
        #expect(node.children[0].kind == "Color")
        #expect(node.children[1].kind == "Color")

        let real = Interpreter(registry: ViewRegistry())
        _ = try real.run(source: #"ZStack { Color.black.ignoresSafeArea()\#nText("x") }"#)
    }

    @Test func hostTypeStaticMembersActAsImplicitMembers() throws {
        // Color.black ≡ .black — including chains through .opacity.
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: #"Text("x").foregroundStyle(Color.red)"#)
        _ = try interpreter.run(source: #"Text("x").background(Color.black.opacity(0.4))"#)
        _ = try interpreter.run(source: #"Text("x").font(Font.headline)"#)
    }

    @Test func handWrittenGatewaysStillWin() throws {
        // padding is in both tables; the hand-written one accepts
        // (.horizontal, 8) which has no generated equivalent shape.
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: #"Text("x").padding(.horizontal, 8)"#)
    }
}
