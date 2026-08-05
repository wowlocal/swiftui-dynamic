import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// `FocusState<Value>.Binding` is a property-wrapper projection the SwiftUI
/// interface publishes as a parameter type and gives no way to build: it
/// stores a `private var _binding` and declares `wrappedValue` /
/// `projectedValue` and not one initializer. So unlike every other bridged
/// parameter, no value can be cast, constructed, or adapted into it — the
/// projection exists only where the enclosing wrapper is DECLARED on a real
/// view.
///
/// Every overload taking one was therefore unreachable: `.focused($x)` fit no
/// generated overload, so the modifier never applied. Surfaced by IceCubes'
/// `MediaUIView.swift:27`, whose `ScrollView` carries
/// `.focusable().focused($isFocused)`.
///
/// The class is NOT about focus. It is about a parameter type that admits no
/// argument conversion, answered by restructuring the RECEIVER — a generated
/// carrier declaring the real wrapper — instead of converting the argument.
/// `AccessibilityFocusState` is the same shape and is covered for that reason,
/// not as a second special case.
///
/// These cases drive `GeneratedDispatch.serves`, the predicate that decides
/// whether the generated tier fits a call at all. A render-level assertion
/// would NOT reproduce this: an unmatched modifier leaves its receiver
/// visible, so the content survives either way and the tree looks identical.
/// What was lost is the MODIFIER, which is exactly what this predicate sees.
@Suite(.serialized)
struct WrapperProjectionCarrierTests {
    private static let declarations = """
    struct ContentView: View {
        @FocusState private var isFocused: Bool
        @FocusState private var field: String?

        var body: some View { Text("body-text") }
    }
    """

    /// Evaluate `expression` in a program declaring the focus state, then ask
    /// the generated tier whether `modifier` fits that argument list.
    @MainActor
    private static func serves(
        _ modifier: String,
        _ arguments: [(String?, String)]
    ) throws -> Bool {
        let interpreter = Interpreter()
        var values: [CallArguments.Argument] = []
        for (label, expression) in arguments {
            let value = try interpreter.run(source: """
            \(declarations)

            \(expression)
            """)
            values.append(.init(label: label, value: value))
        }
        let overloads = try #require(GeneratedModifiers.table[modifier])
        return GeneratedDispatch.serves(
            overloads: overloads,
            args: CallArguments(arguments: values),
            ctx: interpreter)
    }

    /// The exact shape IceCubes writes.
    @MainActor
    @Test func aFocusStateProjectionFitsFocused() throws {
        #expect(try Self.serves("focused", [(nil, "ContentView().$isFocused")]))
    }

    /// The `equals:` overload, whose projection is the interface's
    /// optional-Hashable shape rather than the Bool one.
    @MainActor
    @Test func anOptionalFocusStateProjectionFitsFocusedEquals() throws {
        #expect(try Self.serves("focused", [
            (nil, "ContentView().$field"),
            ("equals", "\"name\""),
        ]))
    }

    /// The accessibility wrapper: a distinct SDK type with the identical
    /// uninitializable-projection shape, so one carrier family answers both.
    @MainActor
    @Test func anAccessibilityFocusStateProjectionFitsAccessibilityFocused()
        throws
    {
        #expect(try Self.serves(
            "accessibilityFocused", [(nil, "ContentView().$isFocused")]))
    }

    /// The negative control. A projection parameter must not become a hole
    /// that accepts anything: a plain `Bool` is not a binding and must still
    /// fit no overload, or the carrier would be laundering type errors into
    /// silent no-ops.
    @MainActor
    @Test func aBareBoolStillFitsNoFocusedOverload() throws {
        #expect(try !Self.serves("focused", [(nil, "true")]))
    }

    /// The carrier must not disturb the modifiers already reaching this view:
    /// `.focusable()` was bridged before this change and stays bridged.
    @MainActor
    @Test func focusableIsUnaffected() throws {
        #expect(try Self.serves("focusable", []))
    }

    /// End to end: the chain IceCubes writes still renders its content, so the
    /// carrier did not trade a working render for a working modifier.
    @Test func theSurfacingChainStillRenders() async throws {
        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let strings = try await LiveCheckSupport.renderedStrings(source: """
        struct ContentView: View {
            @FocusState private var isFocused: Bool

            var body: some View {
                VStack {
                    Text("body-text")
                        .focusable()
                        .focused($isFocused)
                        .focusEffectDisabled()
                }
            }
        }
        """)
        #expect(strings.contains("body-text"),
                Comment(rawValue: "\(strings.filter { !$0.isEmpty })"))
        #expect(RenderDiagnostics.errors.isEmpty,
                Comment(rawValue:
                    "\(RenderDiagnostics.errors.map(\.error.message))"))
    }
}
