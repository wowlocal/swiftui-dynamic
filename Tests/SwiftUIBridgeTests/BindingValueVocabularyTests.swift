import SwiftUI
import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// A two-way binding whose VALUE type the generator resolved from a closed list
/// of three SDK spellings.
///
/// BridgeGen mapped `Binding<Bool>`, `Binding<String>` and `Binding<Double>` by
/// name and nothing else, so all 100 other `Binding<…>` parameters the SDK
/// declares left their overloads ungeneratable. A modifier chain absorbs from
/// its FIRST unbridged member, so one unmapped binding takes every later
/// modifier on the chain with it.
///
/// Surfaced by IceCubes' `MediaUIView.swift:44`, `.scrollPosition(id:
/// $scrolledItem)` — declared `Binding<(some Hashable)?>`, an interface generic
/// constrained to Hashable alone. It is the last unbridged member of the
/// media-browser screen's chain: `.focusable()`, `.focused($isFocused)`,
/// `.focusEffectDisabled()`, `.onKeyPress(…)` and `.scrollTargetBehavior(…)`
/// above it all resolve.
///
/// The class is NOT about scroll positions. It is that a binding is a COMPOSITE
/// — a value coercion plus the general host->runtime write-back — and the
/// generator was keying it on the composite's spelling instead of composing it,
/// the way it already composes `[T]` from `T`. `Binding<T>` now resolves `T`
/// through the same vocabulary an ordinary parameter of type `T` resolves
/// through.
///
/// These cases drive `GeneratedDispatch.serves` — the predicate deciding
/// whether the generated tier fits a call — rather than a render, for the
/// reason `WrapperProjectionCarrierTests` and `CallbackResultCoercionTests`
/// both record: when the symptom is a MISSING modifier, a render assertion
/// cannot see it, because an unmatched modifier deliberately leaves its
/// receiver visible and the tree looks identical either way.
@Suite(.serialized)
struct BindingValueVocabularyTests {
    /// One argument at a call site: an ordinary expression, or the `$state`
    /// projection a binding parameter receives. The projection is built
    /// directly because `$x` is only evaluable inside a View body — the
    /// end-to-end case at the bottom of this file covers that path.
    enum Argument {
        case expression(String)
        case stateProjection(RuntimeValue)
    }

    @MainActor
    private static func serves(
        _ modifier: String,
        _ arguments: [(String?, Argument)]
    ) throws -> Bool {
        let interpreter = Interpreter()
        var values: [CallArguments.Argument] = []
        for (label, argument) in arguments {
            let value: RuntimeValue
            switch argument {
            case .expression(let source):
                value = try interpreter.run(source: source)
            case .stateProjection(let initial):
                value = Self.stateProjection(initial)
            }
            values.append(.init(label: label, value: value))
        }
        let overloads = try #require(GeneratedModifiers.table[modifier])
        return GeneratedDispatch.serves(
            overloads: overloads,
            args: CallArguments(arguments: values),
            ctx: interpreter)
    }

    /// A `$state` projection, which is what every binding parameter actually
    /// receives at a call site.
    @MainActor
    private static func stateProjection(
        _ initial: RuntimeValue
    ) -> RuntimeValue {
        .native(BindingStub(box: Box(initial)))
    }

    /// The shape IceCubes writes. Pre-fix `GeneratedModifiers.table` has no
    /// `scrollPosition` KEY at all, so the `#require` above fails outright —
    /// this is RED before the generator change, not merely false.
    @MainActor
    @Test func scrollPositionServesAGenericHashableBinding() throws {
        #expect(try Self.serves(
            "scrollPosition", [("id", .stateProjection(.nilValue))]))
    }

    /// The same modifier's second declared overload, so the win is the
    /// parameter type rather than one arity of one API.
    @MainActor
    @Test func scrollPositionServesWithATrailingAnchor() throws {
        #expect(try Self.serves("scrollPosition", [
            ("id", .stateProjection(.nilValue)),
            ("anchor", .expression(".top")),
        ]))
    }

    /// The negative control. Composing the binding must not turn its parameter
    /// into a hole that accepts anything: a plain value where a binding is
    /// declared must still fit no overload, or the generalization would be
    /// laundering type errors into silent no-ops.
    @MainActor
    @Test func aBareValueStillFitsNoScrollPositionOverload() throws {
        #expect(try !Self.serves(
            "scrollPosition", [("id", .expression("\"row-3\""))]))
    }

    /// Widening the composition is one vocabulary entry plus one projection
    /// arm, and this is the case that proves it: `quickLookPreview(_:)` takes
    /// `Binding<URL?>`, and `URL` was ALREADY in the value vocabulary as an
    /// ordinary one-way parameter. Nothing about this modifier is named
    /// anywhere in the generator — it became available because its value type
    /// had a coercion and its optional-ness had a projection.
    ///
    /// Surfaced by IceCubes' `QuickLookToolbarItem.swift:25`. It is what the
    /// media-browser screen's image block terminates at: the chain absorbs
    /// from its first unbridged member, so an unmapped binding here drops the
    /// rendered view above it.
    @MainActor
    @Test func quickLookPreviewServesAnOptionalURLBinding() throws {
        #expect(try Self.serves(
            "quickLookPreview", [(nil, .stateProjection(.nilValue))]))
    }

    /// Absence must survive the round trip. `Binding<URL?>` is spelled
    /// optional because "nothing to preview yet" is a distinct state from any
    /// URL — collapsing it to a placeholder would make the SDK preview
    /// something the program never asked for.
    @MainActor
    @Test func anAbsentURLRoundTripsAsNilRatherThanAValue() throws {
        let interpreter = Interpreter()
        let box = Box(.nilValue)
        let carrier = try #require(try Coerce.binding(
            .native(BindingStub(box: box)),
            valueTag: .url,
            valueType: "URL?",
            context: interpreter) as? Binding<URL?>)

        #expect(carrier.wrappedValue == nil)
        let url = URL(string: "https://example.org/a.png")!
        carrier.wrappedValue = url
        #expect(box.value.hostPayload as? URL == url)
        carrier.wrappedValue = nil
        #expect(box.value.isNil)
    }

    /// A state that has never been assigned reads as `.void`, not as nil, and
    /// an optional binding must treat that as absent too — otherwise the very
    /// first render hands the SDK a garbage value.
    @MainActor
    @Test func anUninitializedStateReadsAsAbsent() throws {
        let interpreter = Interpreter()
        let carrier = try #require(try Coerce.binding(
            .native(BindingStub(box: Box(.void))),
            valueTag: .url,
            valueType: "URL?",
            context: interpreter) as? Binding<URL?>)
        #expect(carrier.wrappedValue == nil)
    }

    /// The three spellings the composition REPLACED still serve, across both
    /// tiers: a modifier binding (`sheet(isPresented:)` — `Binding<Bool>`), a
    /// modifier binding carrying a value (`searchable(text:)` —
    /// `Binding<String>`), and a constructor binding (`Slider(value:)` —
    /// `Binding<Double>`). That the closed list is GONE rather than extended is
    /// enforced by the compiler, since `bindingBool`/`bindingString`/
    /// `bindingDouble` no longer exist as enum cases; this pins the behaviour
    /// the migration had to preserve.
    @MainActor
    @Test func theReplacedSpellingsAreServedByTheComposedPath() throws {
        #expect(try Self.serves("sheet", [
            ("isPresented", .stateProjection(.bool(false))),
            ("content", .expression("{ Text(\"x\") }")),
        ]))
        #expect(try Self.serves(
            "searchable", [("text", .stateProjection(.string("")))]))

        let overloads = try #require(GeneratedConstructors.table["Slider"])
        let candidates = overloads.byArity[1] ?? []
        #expect(!candidates.isEmpty)
        #expect(candidates.contains { overload in
            overload.params.first?.label == "value"
                && overload.params.first?.tag == .binding(.double, "Double")
        })
    }

    /// The comparator that keeps the two halves of this mechanism honest.
    ///
    /// BridgeGen decides WHICH bindings to emit from `bindingCarrierTags`;
    /// `Coerce.binding` decides which it can actually build. Those are separate
    /// artifacts in separate targets, and a registration the runtime cannot
    /// carry is strictly worse than a blocked overload — an unmatched modifier
    /// keeps its receiver visible, while a matched-then-failing one raises. So
    /// something has to compare them, and this is it: every `.binding` tag in
    /// the emitted tables must produce a carrier from a real `$state`
    /// projection.
    @MainActor
    @Test func everyEmittedBindingTagHasARuntimeCarrier() throws {
        var tags: Set<ParamTag> = []
        for (_, overloads) in GeneratedModifiers.table {
            for overload in overloads.byArity.values.flatMap({ $0 }) {
                for param in overload.params {
                    if case .binding = param.tag { tags.insert(param.tag) }
                }
            }
        }
        for (_, overloads) in GeneratedConstructors.table {
            for overload in overloads.byArity.values.flatMap({ $0 }) {
                for param in overload.params {
                    if case .binding = param.tag { tags.insert(param.tag) }
                }
            }
        }
        // The mechanism is worthless if nothing exercises it, so the sweep
        // asserts it actually found the family before judging it.
        #expect(tags.count >= 4, Comment(rawValue: "\(tags)"))

        let interpreter = Interpreter()
        for tag in tags {
            guard case .binding(let valueTag, let valueType) = tag else {
                continue
            }
            let projection = Self.stateProjection(.nilValue)
            #expect(throws: Never.self, Comment(rawValue: "\(tag)")) {
                _ = try Coerce.binding(
                    projection,
                    valueTag: valueTag,
                    valueType: valueType,
                    context: interpreter)
            }
        }
    }

    /// A carrier is only correct if it is the type the generated call site
    /// casts to. `scrollPosition(id:)` instantiates the SDK's Hashable generic
    /// at `InterpretedHashableValue`, so the coercion must produce exactly
    /// `Binding<InterpretedHashableValue?>` — a near-miss like `Binding<Any?>`
    /// would compile in the generator and trap in the `as!` at the call site.
    @MainActor
    @Test func theHashableCarrierIsTheTypeTheCallSiteCastsTo() throws {
        let interpreter = Interpreter()
        let carrier = try Coerce.binding(
            Self.stateProjection(.nilValue),
            valueTag: .hashable,
            valueType: "InterpretedHashableValue?",
            context: interpreter)
        #expect(carrier is Binding<InterpretedHashableValue?>)
    }

    /// The binding is TWO-WAY, which a `serves` assertion cannot see. A write
    /// through the carrier must land in the interpreted box so the program that
    /// declared the state observes it — the property that separates a real
    /// binding from a one-way argument that happens to type-check.
    @MainActor
    @Test func writesThroughTheCarrierReachTheInterpretedState() throws {
        let interpreter = Interpreter()
        let box = Box(.nilValue)
        let carrier = try #require(try Coerce.binding(
            .native(BindingStub(box: box)),
            valueTag: .hashable,
            valueType: "InterpretedHashableValue?",
            context: interpreter) as? Binding<InterpretedHashableValue?>)

        #expect(carrier.wrappedValue == nil)
        carrier.wrappedValue = InterpretedHashableValue(runtimeValue: .string("row-3"))
        #expect(box.value.stringValue == "row-3")
        carrier.wrappedValue = nil
        #expect(box.value.isNil)
    }

    /// End to end: the chain IceCubes writes renders its content and records no
    /// diagnostic, so a bridged modifier was not traded for a broken render.
    @Test func theSurfacingChainStillRenders() async throws {
        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let strings = try await LiveCheckSupport.renderedStrings(source: """
        struct ContentView: View {
            @State private var scrolled: String?
            @FocusState private var isFocused: Bool

            var body: some View {
                VStack {
                    Text("body-text")
                }
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow, action: { .handled })
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $scrolled)
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
