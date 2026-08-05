import SwiftUI
import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// `SharePreview<Image, Icon>` is a compound type over TWO constrained
/// generics. BridgeGen substituted a compound's sole generic argument
/// (`Binding<V>`, `ClosedRange<V>`) and had no spelling for a second one, so
/// the whole type stayed unmapped — and with it every
/// `ShareLink(item:…preview:)` initializer, all six of which reported exactly
/// `blocked[SharePreview<PreviewImage, PreviewIcon>]` under
/// `BRIDGEGEN_DUMP_BLOCKED` at `2399683f`.
///
/// Surfaced by the IceCubes media browser: `MediaUIShareLink.swift:15` builds
/// `ShareLink(item: transferable, preview: .init(…, image: transferable))`, so
/// its share toolbar button drew the interpreter's error placeholder instead
/// of the share glyph. Because toolbar items are trailing-aligned, the wrong
/// width displaced the two buttons beside it as well — one failure, three
/// divergent regions.
///
/// The carrier for `Transferable` itself is NOT new here; it already answered
/// `draggable` and friends. What was missing was the ability to spell a type
/// that holds two of them.
@Suite(.serialized)
struct SharePreviewInstantiationTests {
    /// The instantiation the app actually builds. `SharePreview(_:image:)` is
    /// declared in `extension SharePreview where Icon == Never`, so the value
    /// that reaches `ShareLink` is `<Image, Never>` — an initializer emitted
    /// only at `<Image, Image>` would type-check and then fail every cast.
    @MainActor
    @Test func shareLinkAcceptsEveryPreviewShapeTheSDKDeclares() throws {
        let overloads = try #require(GeneratedConstructors.table["ShareLink"])
            .byArity.values.flatMap { $0 }
        let previewTags: Set<String> = Set(
            overloads.flatMap(\.params)
                .filter { $0.label == "preview" }
                .map { "\($0.tag)" })
        for shape in [
            "SharePreview<InterpretedTransferableValue, Never>",
            "SharePreview<Never, InterpretedTransferableValue>",
            "SharePreview<InterpretedTransferableValue, "
                + "InterpretedTransferableValue>",
            "SharePreview<Never, Never>",
        ] {
            #expect(
                previewTags.contains { $0.contains(shape) },
                Comment(rawValue: "no ShareLink overload takes \(shape)"))
        }
    }

    /// `SharePreview` has to be CONSTRUCTIBLE too, or the leading-dot
    /// `preview: .init(…)` the app writes resolves against nothing. It became
    /// scannable only once a demanded generic instantiation could name it.
    @MainActor
    @Test func sharePreviewIsConstructibleAtItsDeclaredShapes() throws {
        let overloads = try #require(GeneratedConstructors.table["SharePreview"])
            .byArity.values.flatMap { $0 }
        let labelSets = Set(overloads.map { $0.params.map { $0.label ?? "_" } })
        #expect(labelSets.contains(["_", "image"]))
        #expect(labelSets.contains(["_", "icon"]))
        #expect(labelSets.contains(["_"]))
    }

    /// The negative half: an uninhabited slot is a phantom, never a value, so
    /// the four-way fan-out over instantiations must not become a four-way
    /// multiplication of CALL SHAPES. `init(_:image:icon:)` is callable only
    /// where both slots are inhabited — at `<Image, Never>` it would need an
    /// `icon: Never` argument no call can produce, and BridgeGen reports it
    /// there as `blocked[== Never]`. So every shape appears exactly once per
    /// title spelling, however many instantiations were enumerated to find it.
    @MainActor
    @Test func enumeratingInstantiationsDoesNotDuplicateCallShapes() throws {
        let overloads = try #require(GeneratedConstructors.table["SharePreview"])
            .byArity.values.flatMap { $0 }
        let shapeCounts = overloads.reduce(into: [[String]: Int]()) {
            $0[$1.params.map { $0.label ?? "_" }, default: 0] += 1
        }
        let titleSpellings = try #require(shapeCounts[["_", "image"]])
        #expect(titleSpellings > 1, "expected several title spellings")
        // The icon-taking, image-taking and both-taking shapes each exist once
        // per title spelling — not once per (Image, Icon) combination.
        #expect(shapeCounts[["_", "icon"]] == titleSpellings)
        #expect(shapeCounts[["_", "image", "icon"]] == titleSpellings)
    }

}

// A BEHAVIOURAL test was written for this class and deleted, for the same
// reason the `scrollPosition` carrier's was. Rendering
// `ShareLink(item: payload, preview: .init(…)) { Text("x") }` through
// `LiveCheckSupport.renderedStrings` reports "x" whether or not the
// initializer resolves, because that harness renders a label builder's content
// either way — it passed with this whole change STASHED. And the form the app
// actually writes takes no label at all: its `DefaultShareLinkLabel` draws the
// share glyph and no string, so the trace registry cannot see it succeed OR
// fail. A test that cannot go red pins nothing, so the behavioural half is
// left to the R2 board, which the close gate enforces, and where this class
// is worth 1136 AE on the media-browser screen.
