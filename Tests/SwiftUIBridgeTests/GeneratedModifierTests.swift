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

    /// Some SDK generic parameters are constrained by a composition of
    /// protocols rather than by a nominal enum. The Symbols interface exposes
    /// `.pulse` through `SymbolEffect where Self == PulseSymbolEffect`, then
    /// declares the concrete effect's protocol conformances separately.
    /// BridgeGen must derive that contextual value from those relationships.
    @MainActor
    @Test func protocolCompositionContextualValueMatchesNativeRendering() throws {
        let composition =
            "Symbols.DiscreteSymbolEffect&Symbols.SymbolEffect"
        let overloads = GeneratedModifiers.table["symbolEffect"]?
            .byArity[2] ?? []
        #expect(overloads.contains {
            $0.params.map(\.tag) == [
                .sdkProtocolValue(composition), .equatable,
            ]
        })
        let pulse = try GeneratedSDKProtocolValueCoercions.coerce(
            composition, .implicitMember("pulse"))
        #expect(pulse is PulseSymbolEffect)
        let options = try GeneratedSDKEnumCoercions.coerce(
            "Symbols.SymbolEffectOptions", .implicitMember("repeating"))
            as? SymbolEffectOptions
        #expect(options == .repeating)

        let source = """
        Image(systemName: "arrow.down")
            .symbolEffect(.pulse, value: false)
            .foregroundStyle(Color.black)
            .frame(width: 64, height: 64)
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source,
            lazyTopLevelGlobals: true
        )
        guard case .success(let interpreted) = rendered else {
            Issue.record("interpreted symbol effect failed to render: \(rendered)")
            return
        }
        for (viewName, error) in RenderDiagnostics.errors {
            Issue.record("\(viewName): \(error)")
        }

        let native = AnyView(
            Image(systemName: "arrow.down")
                .symbolEffect(.pulse, value: false)
                .foregroundStyle(Color.black)
                .frame(width: 64, height: 64)
        )
        let size = NSSize(width: 64, height: 64)
        #expect(
            Self.mismatchedPixels(
                Self.bitmap(interpreted, size: size),
                Self.bitmap(native, size: size),
                size: size
            ) == 0
        )
    }

    /// Public `.swiftcrossimport/SwiftUI.swiftoverlay` metadata is part of the
    /// SDK API surface. The generated overload retains both the interface
    /// parameter shape and the triggering source import.
    @Test func swiftUICrossImportMetadataGeneratesModifierCoverage() {
        let variants = GeneratedModifiers.table[
            "translationPresentation"]?.byArity[2] ?? []
        #expect(variants.contains {
            $0.params.map(\.label) == ["isPresented", "text"]
                && $0.params.map(\.tag) == [.bindingBool, .string]
                && $0.requiredImports == ["Translation"]
        })
    }

    /// Primary SwiftUI interfaces describe style parameters with protocol
    /// constraints and expose their leading-dot values through same-type
    /// extensions. Those relationships should drive both generated dispatch
    /// and contextual coercion just as they already do for support modules.
    @MainActor
    @Test func primaryInterfaceProtocolsGenerateStyleCoverage() throws {
        let composition = "SwiftUI.ProgressViewStyle"
        let overloads = GeneratedModifiers.table["progressViewStyle"]?
            .byArity[1] ?? []
        #expect(overloads.contains {
            $0.params.map(\.tag) == [.sdkProtocolValue(composition)]
        })

        let linear = try GeneratedSDKProtocolValueCoercions.coerce(
            composition, .implicitMember("linear"))
        #expect(linear is LinearProgressViewStyle)

        let registry = ViewRegistry()
        let result = try Interpreter(registry: registry).run(source: """
        Text("generated primary protocol")
            .progressViewStyle(.linear)
        """)
        #expect(registry.isViewValue(result))
    }

    /// A protocol-constrained SDK overload remains part of the imported
    /// surface even when the SDK has no concrete `Self == Concrete` factory.
    /// Custom ButtonStyle values are source-defined and receive a
    /// framework-supplied Configuration at runtime, so BridgeGen must retain
    /// that interface shape for overload resolution without learning a
    /// project style or member name.
    @MainActor
    @Test func sourceProtocolStyleOverloadSurvivesCompetingSourceOverload()
        throws
    {
        let descriptor = try #require(
            GeneratedSDKProtocolValueCoercions
                .frameworkConfigurationProtocols["SwiftUI.ButtonStyle"])
        #expect(descriptor.configurationType
            == "SwiftUI.ButtonStyleConfiguration")
        #expect(descriptor.bodyMethod == "makeBody")
        #expect(descriptor.configurationLabel == "configuration")
        #expect(GeneratedSDKProtocolValueCoercions
            .frameworkConfigurationProtocols["SwiftUI.LabelStyle"] != nil)

        let overloads = GeneratedModifiers.table["buttonStyle"]?
            .byArity[1] ?? []
        #expect(overloads.contains {
            $0.params.map(\.tag)
                == [.sdkProtocolValue("SwiftUI.ButtonStyle")]
                && $0.params.map(\.contextualType)
                    == ["SwiftUI.ButtonStyle"]
        })
        #expect(overloads.contains {
            $0.params.map(\.tag)
                == [.sdkProtocolValue("SwiftUI.PrimitiveButtonStyle")]
        })

        let source = """
        struct ProjectButtonStyle: ButtonStyle {
            func makeBody(configuration: Configuration) -> some View {
                configuration.label
            }
        }

        extension ButtonStyle where Self == ProjectButtonStyle {
            static var projectPrimary: Self { .init() }
        }

        extension View {
            func buttonStyle(
                _ style: (some PrimitiveButtonStyle)?
            ) -> some View {
                self
            }
        }

        struct ContentView: View {
            var body: some View {
                Button("Action") {}
                    .buttonStyle(.projectPrimary)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount > 0)

        let sourceInterpreter = Interpreter(registry: ViewRegistry())
        let sourceStyle = try sourceInterpreter.run(
            source: source + """

            ProjectButtonStyle()
            """)
        let generatedStyle =
            try GeneratedSDKProtocolValueCoercions.coerce(
                "SwiftUI.ButtonStyle",
                sourceStyle,
                context: sourceInterpreter)
        let nativeStyle = try #require(
            generatedStyle as? any ButtonStyle)
        func applying<S: ButtonStyle>(_ style: S) -> AnyView {
            AnyView(Button("Generated source style") {}
                .buttonStyle(style))
        }
        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let generatedBitmap = Self.bitmap(
            applying(nativeStyle),
            size: NSSize(width: 240, height: 100))
        let hasInk = (0..<240).contains { x in
            (0..<100).contains { y in
                guard let color = generatedBitmap.colorAt(x: x, y: y)
                else { return false }
                return color.redComponent < 0.8
                    || color.greenComponent < 0.8
                    || color.blueComponent < 0.8
            }
        }
        #expect(hasInk)
        #expect(RenderDiagnostics.errors.isEmpty)

        let registry = ViewRegistry()
        let modifier = try #require(registry.modifier(named: "buttonStyle"))
        #expect(modifier.exposesInterfaceParameterTypes)
        let rendered = try Interpreter(registry: registry).run(
            source: source + """

            Button("Direct action") {}
                .buttonStyle(.projectPrimary)
            """)
        #expect(registry.isViewValue(rendered))
    }

    /// Configuration properties belong to the same generated protocol
    /// adapter as its conformer. ToggleStyle is a neutral proof: it has no
    /// handwritten modifier gateway or configuration host-member switch.
    @MainActor
    @Test func sourceProtocolConfigurationMembersComeFromInterfaces() throws {
        let descriptor = try #require(
            GeneratedSDKProtocolValueCoercions
                .frameworkConfigurationProtocols["SwiftUI.ToggleStyle"])
        #expect(descriptor.configurationType
            == "SwiftUI.ToggleStyleConfiguration")
        #expect(descriptor.members
            == ["$isOn", "isMixed", "isOn", "label"])

        let source = """
        struct ProjectToggleStyle: ToggleStyle {
            func makeBody(configuration: Configuration) -> some View {
                HStack(spacing: 0) {
                    configuration.label
                    Rectangle()
                        .fill(configuration.isOn ? Color.black : Color.white)
                        .frame(width: 44, height: 26)
                }
            }
        }

        @main
        struct ProbeApp: App {
            @State private var enabled = true

            var body: some Scene {
                WindowGroup {
                    Toggle("Interface members", isOn: $enabled)
                        .toggleStyle(ProjectToggleStyle())
                }
            }
        }
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("generated ToggleStyle failed to render: \(rendered)")
            return
        }
        let bitmap = Self.bitmap(
            view, size: NSSize(width: 240, height: 100))
        var blackPixels = 0
        for x in 0..<240 {
            for y in 0..<100 {
                guard let color = bitmap.colorAt(x: x, y: y) else {
                    continue
                }
                if color.redComponent < 0.15,
                   color.greenComponent < 0.15,
                   color.blueComponent < 0.15 {
                    blackPixels += 1
                }
            }
        }
        #expect(blackPixels > 500)
        #expect(RenderDiagnostics.errors.isEmpty)
    }

    @MainActor
    @Test func generatedProtocolValueCarriesTargetSemanticAdapter() throws {
        let composition = "SwiftUI.MenuStyle"
        let overloads = GeneratedModifiers.table["menuStyle"]?
            .byArity[1] ?? []
        #expect(overloads.contains {
            $0.params.map(\.tag) == [.sdkProtocolValue(composition)]
                && $0.semanticAdapter != nil
        })

        let button = try GeneratedSDKProtocolValueCoercions.coerce(
            composition, .implicitMember("button"))
        #expect(button is ButtonMenuStyle)
    }

    @MainActor
    @Test func generatedTintPreservesGenericShapeStyleAndTargetSemantics() throws {
        let overloads = GeneratedModifiers.table["tint"]?.byArity[1] ?? []
        #expect(overloads.contains {
            $0.params.map(\.tag) == [.genericShapeStyle]
                && !$0.isDisfavored
                && $0.semanticAdapter != nil
        })
        #expect(overloads.contains {
            $0.params.map(\.tag) == [.color]
                && $0.isDisfavored
                && $0.semanticAdapter != nil
        })

        let registry = ViewRegistry()
        let result = try Interpreter(registry: registry).run(source: """
        Text("generated generic tint")
            .tint(.quaternary.opacity(0.5))
        """)
        #expect(registry.isViewValue(result))
    }

    @Test func generatedShapeStyleCoercionPreservesConcreteType() throws {
        let primary = try Coerce.genericShapeStyle(
            .implicitMember("primary"))
        #expect(primary is HierarchicalShapeStyle)

        let generatedColor = try Coerce.genericShapeStyle(
            .implicitMember("red"))
        #expect(generatedColor is Color)
    }

    @Test func suffixDefaultVariantsMatchBothCallShapes() throws {
        // autocorrectionDisabled() and autocorrectionDisabled(false) are the
        // zero-arg and full variants of one defaulted-parameter overload.
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: #"Text("a").autocorrectionDisabled()"#)
        _ = try interpreter.run(source: #"Text("b").autocorrectionDisabled(false)"#)
    }

    /// An omitted default and an explicitly supplied nil are distinct source
    /// shapes. BridgeGen must retain the Optional marker from the interface so
    /// concrete SDK calls such as `frame(maxWidth: CGFloat?)` receive native
    /// nil instead of asking the wrapped-number coercer to consume it.
    @Test func concreteOptionalParameterAcceptsExplicitNil() throws {
        let maxWidth = GeneratedModifiers.table["frame"]?
            .byArity[1]?.first {
                $0.params.map(\.label) == ["maxWidth"]
            }
        #expect(maxWidth?.params.first?.tag == .cgFloat)
        #expect(maxWidth?.params.first?.isOptional == true)
        let installedFrame = try #require(
            ViewRegistry().modifier(named: "frame"))
        #expect(installedFrame.exposesInterfaceParameterTypes)

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: """
            struct ContentView: View {
                let maxWidth: CGFloat? = nil

                var body: some View {
                    Text("explicit optional frame")
                        .frame(maxWidth: maxWidth)
                }
            }
            """,
            lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("explicit Optional modifier failed: \(rendered)")
            return
        }
        let hosting = NSHostingView(
            rootView: view.frame(width: 260, height: 100))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(RenderDiagnostics.errors.isEmpty)
    }

    @Test func defaultBeforeTrailingClosureProducesShorthandVariant() throws {
        // Native Swift can omit an unlabeled default immediately before a
        // trailing closure. BridgeGen must preserve that interface-derived
        // call shape instead of treating the closure as a positional value.
        _ = Text("native").accessibilityAction {}

        let shorthand = GeneratedModifiers.table["accessibilityAction"]?
            .byArity[1] ?? []
        #expect(shorthand.contains { $0.params.map(\.tag) == [.action] })

        _ = try Interpreter(registry: ViewRegistry()).run(source: """
        Text("interpreted").accessibilityAction {}
        """)
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

        // RoundedRectangle declares Shape, not View directly. BridgeGen must
        // follow the interface's protocol-refinement graph and preserve the
        // defaulted style by emitting the one-argument constructor shape.
        let roundedRectangle =
            GeneratedConstructors.table["RoundedRectangle"]?.byArity[1] ?? []
        #expect(roundedRectangle.contains {
            $0.params.map(\.label) == ["cornerRadius"]
                && $0.params.map(\.tag) == [.cgFloat]
        })

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

        let onHover = GeneratedModifiers.table["onHover"]?.byArity[1] ?? []
        #expect(onHover.contains {
            $0.params.map(\.label) == ["perform"]
                && $0.params.map(\.tag) == [.syncVoidClosure]
        })
    }

    /// IceCubes' status rows pass their URL through SwiftUI's
    /// `@autoclosure () -> T where T: Transferable` payload shape. Native
    /// Swift accepts that value directly; BridgeGen must map the payload's
    /// result type and keep the receiver a rendered View.
    @Test func autoclosureGenericModifierMapsPayloadResult() throws {
        let nativePayload = URL(string: "https://example.com/status/1")!
        _ = Text("native row").draggable(nativePayload)

        let draggable = GeneratedModifiers.table["draggable"]?.byArity[1] ?? []
        #expect(draggable.contains { $0.params.map(\.tag) == [.url] })

        let registry = ViewRegistry()
        let result = try Interpreter(registry: registry).run(source: """
        Text("interpreted row")
            .draggable(URL(string: "https://example.com/status/1")!)
            .padding()
        """)
        #expect(registry.isViewValue(result))
    }

    /// IceCubes still uses SwiftUI's compatibility spelling
    /// `accessibility(addTraits:)`. Its interface rename is deprecated only at
    /// the sentinel version 100000, so native Swift continues to accept it and
    /// BridgeGen must not mistake that future marker for unavailability.
    @Test func futureDeprecatedCompatibilityModifierRemainsGenerated() throws {
        _ = Text("native avatar").accessibility(addTraits: .isButton)

        let accessibility = GeneratedModifiers.table["accessibility"]?
            .byArity[1] ?? []
        #expect(accessibility.contains {
            $0.params.map(\.label) == ["addTraits"]
                && $0.params.map(\.tag) == [
                    .sdkEnum("AccessibilityTraits"),
                ]
        })

        let registry = ViewRegistry()
        let result = try Interpreter(registry: registry).run(source: """
        Text("interpreted avatar")
            .accessibility(addTraits: .isButton)
        """)
        #expect(registry.isViewValue(result))
    }

    /// SwiftUI's target overlay declares modifiers that are source-valid on
    /// iOS even when the macOS host interface marks them unavailable. Their
    /// generated off-host adapter must preserve the rendered receiver for an
    /// iOS interpreter without making the same API legal for a macOS target.
    @Test func targetOverlayModifierPreservesReceiverForMatchingTarget() throws {
        let hoverEffect = GeneratedModifiers.table["hoverEffect"]?
            .byArity[0] ?? []
        #expect(!hoverEffect.isEmpty)

        let registry = ViewRegistry()
        let result = try Interpreter(registry: registry).run(source: """
        Text("target avatar")
            .hoverEffect()
            .onTapGesture {}
        """)
        #expect(registry.isViewValue(result))

        #expect(throws: RuntimeError.self) {
            _ = try Interpreter(registry: ViewRegistry()).run(source: """
            Text("invalid target title")
                .navigationBarTitleDisplayMode(.notAnInterfaceCase)
            """)
        }

        let macOSInterpreter = Interpreter(
            registry: ViewRegistry(),
            buildConfiguration: .init(platformName: "macOS"))
        #expect(throws: RuntimeError.self) {
            _ = try macOSInterpreter.run(source: """
            Text("macOS target").hoverEffect()
            """)
        }
    }

    /// Target-overlay collection must include the contextual values consumed
    /// by its declarations, not only zero-argument modifiers. The nested enum
    /// is unavailable to the macOS host but public on the interpreted iOS
    /// target, so the generated off-host adapter validates `.inline` from
    /// interface metadata and preserves the receiver without naming the
    /// consuming modifier in handwritten dispatch.
    @Test func targetOverlayContextualEnumModifierPreservesReceiver() throws {
        let titleDisplayMode =
            GeneratedModifiers.table["navigationBarTitleDisplayMode"]?
                .byArity[1] ?? []
        #expect(titleDisplayMode.contains {
            $0.params.map(\.label) == [nil]
                && $0.params.map(\.tag) == [
                    .sdkEnum("NavigationBarItem.TitleDisplayMode"),
                ]
                && $0.requiredImports == ["UIKit"]
        })

        let registry = ViewRegistry()
        let result = try Interpreter(registry: registry).run(source: """
        Text("target title")
            .navigationBarTitleDisplayMode(.inline)
            .onTapGesture {}
        """)
        #expect(registry.isViewValue(result))

        let macOSInterpreter = Interpreter(
            registry: ViewRegistry(),
            buildConfiguration: .init(platformName: "macOS"))
        #expect(throws: RuntimeError.self) {
            _ = try macOSInterpreter.run(source: """
            Text("macOS title").navigationBarTitleDisplayMode(.inline)
            """)
        }
    }

    /// Target declarations are split across SwiftUI's public implementation
    /// modules, and declarations newer than the package deployment floor
    /// remain source-valid inside availability checks. The interface sweep
    /// must retain both properties instead of limiting generated target
    /// coverage to one umbrella module or dropping newer declarations.
    @Test func newerTargetOverlayModifierPreservesReceiver() throws {
        let variants = GeneratedModifiers.table["glassEffect"]?
            .byArity[0] ?? []
        #expect(variants.contains {
            $0.requiredImports == ["UIKit"]
        })

        let registry = ViewRegistry()
        let interpreter = Interpreter(
            registry: registry,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"))
        let result = try interpreter.run(source: """
        Text("target field")
            .glassEffect()
            .glassEffect(.regular.interactive())
            .onTapGesture {}
        """)
        #expect(registry.isViewValue(result))
    }

    /// A generated off-host adapter only promises to preserve its receiver;
    /// parameter metadata must not make trace mode execute a deferred builder
    /// that the selected adapter itself ignores.
    @Test func targetOverlayReceiverFallbackDoesNotExecuteDeferredBuilder() throws {
        let report = try HeadlessVerifier.verify(source: """
        struct ContentView: View {
            @State var presented = false

            var body: some View {
                Text("base")
                    .fullScreenCover(isPresented: $presented) {
                        fatalError("off-host fallback executed content")
                    }
            }
        }
        """, interactions: false)

        #expect(report.nodeCount == 1)
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

    /// Native Swift resolves `.footnote` here to SwiftUI.Font.footnote. The
    /// same module's other source file has a private sizing constant with the
    /// same spelling, but file-private declarations cannot shadow SDK members
    /// at this call site. IceCubes DesignSystem/Font.swift has this exact shape.
    @Test func privateSourceExtensionStaticDoesNotShadowSDKStaticAcrossFiles() throws {
        let definitions = ProjectMaterial.mergedSource(
            source: """
            import SwiftUI

            extension Font {
                private static let footnote = 13.0
                public static var fixtureScaledFootnote: Font { .footnote }
            }
            """,
            moduleName: "FontScopeProbe")
        let consumer = ProjectMaterial.mergedSource(
            source: """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    Text("public SDK font").font(.footnote)
                }
            }
            """,
            moduleName: "FontScopeProbe")

        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: definitions + consumer) {
        case .failure(let error):
            Issue.record("render failed: \(error)")
        case .success(let view):
            let hosting = NSHostingView(rootView: view)
            hosting.layoutSubtreeIfNeeded()
            for (viewName, error) in RenderDiagnostics.errors {
                Issue.record("\(viewName): \(error)")
            }
        }
    }

    /// A stored static initializer executes in its declaring compiler input,
    /// even when another file triggers lazy initialization through an
    /// internal/public sibling. SwiftGen plist namespaces use this shape:
    /// the exported key reads a private document owned by the same file.
    @Test func crossFileStaticReadUsesInitializerDeclarationScope() throws {
        let definitions = ProjectMaterial.mergedSource(
            source: """
            enum FixtureNamespace {
                private static let document = "1.2.3"
                internal static let version = document
            }
            """,
            moduleName: "StaticInitializerProbe")
        let consumer = ProjectMaterial.mergedSource(
            source: """
            struct ContentView: View {
                var body: some View {
                    let value = FixtureNamespace.version
                    if value != "1.2.3" {
                        fatalError("static initializer lost declaration scope")
                    }
                    return Text(value)
                }
            }
            """,
            moduleName: "StaticInitializerProbe")

        let report = try HeadlessVerifier.verify(
            source: definitions + consumer)
        #expect(report.nodeCount >= 1)
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

    private static func mismatchedPixels(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        size: NSSize
    ) -> Int {
        var mismatched = 0
        for x in 0..<Int(size.width) {
            for y in 0..<Int(size.height)
                where lhs.colorAt(x: x, y: y) != rhs.colorAt(x: x, y: y) {
                mismatched += 1
            }
        }
        return mismatched
    }

    @MainActor
    private static func bitmap(_ view: AnyView, size: NSSize) -> NSBitmapImageRep {
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
                .background(Color.white))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }
}
