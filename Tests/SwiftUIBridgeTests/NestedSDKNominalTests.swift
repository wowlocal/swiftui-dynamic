import SwiftUI
import Testing

@testable import SwiftUIBridge

/// A native SDK value declared NESTED inside another nominal could not flow
/// through any generated signature, while the identical declaration at top
/// level could. The interface sweep that decides which nominals are carriable
/// read only a file's TOP-LEVEL statements, so `Namespace.ID` — as ordinary a
/// value as `Color` — was carried by no tier at all, and every declaration
/// mentioning one stayed blocked.
///
/// Surfaced by IceCubes' media screen, whose remaining pixel debt is
/// `.matchedTransitionSource(id:in:)` absorbed
/// (StatusRowMediaPreviewView.swift:162). `Namespace.ID` appears in 29 blocked
/// overloads across 13 names — matchedGeometryEffect, focusScope,
/// glassEffectID/Union, draggable, dragContainer, mapScope, prefersDefaultFocus
/// and the three accessibility pairings — so this is not one modifier's gap.
@Suite(.serialized)
struct NestedSDKNominalTests {
    /// The two modifiers whose FIRST blocked parameter was `Namespace.ID`, so
    /// carrying it is the whole of what they were waiting for. The others in
    /// the family also carry an opaque `Hashable` id and fall separately.
    @MainActor
    @Test func aNestedNominalParameterReachesTheGeneratedTable() {
        let focusScope = GeneratedModifiers.table["focusScope"]?
            .byArity[1]?.first
        #expect(focusScope != nil,
                "focusScope(_ namespace: Namespace.ID) is generatable")
        #expect(focusScope?.params.first?.tag
                    == .nativeSwiftUIValue("Namespace.ID"))
        let prefersDefaultFocus = GeneratedModifiers.table["prefersDefaultFocus"]?
            .byArity[2]?.first
        #expect(prefersDefaultFocus?.params.last?.tag
                    == .nativeSwiftUIValue("Namespace.ID"))
    }

    /// The sweep walks nesting; it does not know about namespaces. These are
    /// SwiftUI's own nested value types, each now reachable by the declaration
    /// path a parameter spells it with.
    @MainActor
    @Test func theSweepIsAboutNestingRatherThanOneType() {
        let stops = GeneratedConstructors.table["LinearGradient"]?
            .byArity[3]?.contains {
                $0.params.first?.tag
                    == .array(.nativeSwiftUIValue("Gradient.Stop"),
                              "Gradient.Stop")
            }
        #expect(stops == true, Comment(rawValue:
            "LinearGradient(stops:startPoint:endPoint:) carries the "
                + "nested Gradient.Stop"))
    }

    /// WHY the identity check had to change, stated as a measurement rather
    /// than an assertion about the fix: the runtime's printed name for a
    /// nested value is its LEAF, and seven SwiftUI nominals declare a nested
    /// `ID`, so the printed name cannot say which type a value is. The
    /// qualified declaration path can.
    @MainActor
    @Test func aNestedValueIsIdentifiedByItsPathNotItsLeaf() {
        let namespace = Namespace().wrappedValue
        #expect(GeneratedMembers.keyTypeName(of: namespace) == "ID")
        #expect(GeneratedMembers.declarationPath(of: namespace)
                    == "Namespace.ID")
        // A top-level nominal keeps answering exactly as before.
        #expect(GeneratedMembers.declarationPath(of: Color.red) == "Color")
    }
}
