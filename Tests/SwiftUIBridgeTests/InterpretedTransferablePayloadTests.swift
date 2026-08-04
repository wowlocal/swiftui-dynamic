import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// A generic constrained to `Transferable` was specialized to the single
/// concrete conformer `URL`, so every other Transferable payload — including
/// one DECLARED BY THE SOURCE PROGRAM — fitted no overload at all.
///
/// Surfaced by IceCubes' full-screen media browser
/// (`Packages/MediaUI/Sources/MediaUI/MediaUIAttachmentImageView.swift:27`),
/// which hangs `.draggable(MediaUIImageTransferable(url:))` off the image. The
/// R2 board's own capture log names it twice per capture pass:
///
///     diagnostic MediaUIAttachmentImageView no matching overload for
///     .draggable(_:) — argument types or labels don't fit
///
/// A body that throws is replaced by an error label, so an inert modifier
/// costs the whole subtree it was applied to.
///
/// These cases drive `GeneratedDispatch.serves` — the exact predicate whose
/// false answer raises that diagnostic — rather than a rendered tree: the
/// deep-render probe resolves modifiers through `TraceRegistry`, which
/// classifies a modifier by its table entry and never dispatches it, so no
/// rendered string can observe this class.
///
/// The class is NOT about `.draggable`, media, or IceCubes: `copyable`,
/// `exportableToServices` and `ShareLink(item:)` take the same constraint, so
/// what is pinned is the constraint's meaning, not one modifier's.
@Suite(.serialized)
struct InterpretedTransferablePayloadTests {
    /// A source-declared conformance in the app's own spelling: a struct that
    /// says `: Transferable` and answers the protocol's static requirement.
    private static let declarations = """
    struct ImagePayload: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(exportedContentType: .jpeg) { payload in
                Data()
            }
        }
    }

    struct PlainPayload {
        let url: URL
    }
    """

    /// Evaluate `expression` in a program that declares both payload types and
    /// ask the generated tier whether `.draggable(_:)` fits it.
    @MainActor
    private static func draggableServes(_ expression: String) throws -> Bool {
        let interpreter = Interpreter()
        let payload = try interpreter.run(source: """
        \(declarations)

        \(expression)
        """)
        let overloads = try #require(GeneratedModifiers.table["draggable"])
        return GeneratedDispatch.serves(
            overloads: overloads,
            args: CallArguments(
                arguments: [.init(label: nil, value: payload)]),
            ctx: interpreter)
    }

    /// The failing shape: the payload is an interpreted value, not a `URL`.
    @MainActor
    @Test func aSourceDeclaredTransferablePayloadFitsTheConstraint() throws {
        #expect(try Self.draggableServes(
            "ImagePayload(url: URL(string: \"https://e.co/a.jpg\")!)"))
    }

    /// The payload that already worked, pinned so generalizing the constraint
    /// cannot quietly drop it: `URL` is a Transferable too, and IceCubes drags
    /// one off every status row (`StatusKit/Row/StatusRowView.swift:135`).
    @MainActor
    @Test func aURLPayloadStillFitsTheConstraint() throws {
        #expect(try Self.draggableServes(
            "URL(string: \"https://e.co/a.jpg\")!"))
    }

    /// The constraint still MEANS something: a value conforming to nothing is
    /// not a Transferable and real `swiftc` rejects the call. A carrier that
    /// answered the constraint by accepting anything handed to it would trade
    /// one wrong answer for a quieter one.
    @MainActor
    @Test func aPayloadConformingToNothingDoesNotFitTheConstraint() throws {
        #expect(!(try Self.draggableServes(
            "PlainPayload(url: URL(string: \"https://e.co/a.jpg\")!)")))
    }

    /// And the generated tier reaches the constraint through its carrier
    /// rather than through one concrete conformer — the same shape the
    /// Equatable and Hashable constraints already use.
    @Test func draggableCarriesTheTransferableConstraint() {
        let single = GeneratedModifiers.table["draggable"]?.byArity[1] ?? []
        #expect(single.contains { $0.params.map(\.tag) == [.transferable] })
        #expect(!single.contains { $0.params.map(\.tag) == [.url] })
    }
}
