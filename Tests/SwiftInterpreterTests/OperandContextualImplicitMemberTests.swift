import Testing

@testable import SwiftInterpreter

/// A leading dot on one side of a binary operator takes its contextual type
/// from the OTHER side. `OperatorEvaluator.adoptHostType` was written to do
/// exactly that, and even names the CGFloat case in a comment — but it read
/// the peer as `case .host(let otherAny)`, and the interpreter never
/// represents its own scalars that way: `RuntimeValue.native(Double)` builds
/// `.double`, `native(Int)` builds `.int`, `native(String)` builds `.string`.
/// So the peer type was offered only by an opaque host box, the
/// `otherAny is Double` branch below it was unreachable for every value the
/// interpreter computes itself, and the marker stayed unresolved. An
/// unresolved marker then ABSORBS, so `a + .b` quietly answered `a`
/// — the operator returned its left operand and nothing reported a failure.
///
/// The R2 `hashtag-timeline` screen is where the cost showed up.
/// `StatusRowView.swift:74` pads the tag/reblog/reply header group by
/// `AvatarView.FrameConfig.status.width + .statusColumnsSpacing`
/// (48 + 8 on macCatalyst). The interpreter drew that group at 48, exactly
/// 8pt left of the twin on every scanline of the label, worth 1733 AE. The
/// avatar itself (48 wide) and `HStack(spacing: .statusColumnsSpacing)` (8)
/// were both already correct on the same rows, which is what says the defect
/// is the OPERAND POSITION and not the static, the constant, or the
/// `#if targetEnvironment(macCatalyst)` branch.
///
/// Every expectation below is what `swiftc` prints for the same declarations.
@Suite("Operand-contextual implicit member")
struct OperandContextualImplicitMemberTests {
    private func run(_ source: String) throws -> RuntimeValue {
        try Interpreter().run(source: source)
    }

    /// The distilled `StatusRowView` shape: a static declared in an extension
    /// on the scalar type, reached through the peer operand.
    @Test func scalarPeerLendsItsTypeToTheImplicitMember() throws {
        let source = """
        extension CGFloat { static let columnsSpacing: CGFloat = 8 }
        enum FrameConfig { static let statusWidth: CGFloat = 48 }
        FrameConfig.statusWidth + .columnsSpacing
        """
        #expect(try run(source).doubleValue == 56)
    }

    /// The peer may be on either side; adoption is a property of the operand
    /// that is unresolved, not of a position.
    @Test func theImplicitMemberMayBeTheLeftOperand() throws {
        let source = """
        extension CGFloat { static let columnsSpacing: CGFloat = 8 }
        enum FrameConfig { static let statusWidth: CGFloat = 48 }
        CGFloat.columnsSpacing + FrameConfig.statusWidth
        """
        #expect(try run(source).doubleValue == 56)
    }

    /// `Double`, `CGFloat` and `TimeInterval` are one representation here, so
    /// a static declared on any of those names applies to a `.double` peer —
    /// that is the intent the unreachable branch already carried.
    @Test func doubleAndCGFloatShareOneRepresentation() throws {
        let source = """
        extension Double { static let half: Double = 0.5 }
        1.0 + .half
        """
        #expect(try run(source).doubleValue == 1.5)
    }

    /// Not a float question: `.int` and `.string` peers were equally opaque.
    @Test func integerAndStringPeersLendTheirTypesToo() throws {
        let integers = """
        extension Int { static let two = 2 }
        40 + .two
        """
        #expect(try run(integers).intValue == 42)

        let strings = """
        extension String { static let dash = "-" }
        "a" + .dash
        """
        #expect(try run(strings).stringValue == "a-")
    }

    /// The OTHER shape this reaches in the same corpus: the marker is the
    /// left operand and its peer is an integer LITERAL. Swift types that
    /// literal by the contextual CGFloat rather than as an `Int`, so a `.int`
    /// peer has to offer the float family too. IceCubes spells it in four
    /// files — `NotificationsListView.swift:184`,
    /// `ConversationsListRow.swift:122`, `FamiliarFollowersView.swift:32` —
    /// all as `.padding(.leading, .layoutPadding + 4)`, which absorbed to a
    /// bare `4` where the twin insets by 24.
    @Test func anIntegerLiteralPeerOffersTheFloatFamily() throws {
        let source = """
        extension CGFloat { static let layoutPadding: CGFloat = 20 }
        let inset: CGFloat = .layoutPadding + 4
        inset
        """
        #expect(try run(source).doubleValue == 24)
    }

    /// The float family is offered AFTER `Int`, never instead of it: when both
    /// declare the name, compiled Swift picks `Int` and prints 42. Ordering a
    /// widening is not the same as adding one, and this is what says so.
    @Test func aRealIntegerStaticStillWinsOverTheFloatFamily() throws {
        let source = """
        extension Int { static let two = 2 }
        extension CGFloat { static let two: CGFloat = 99 }
        40 + .two
        """
        #expect(try run(source).intValue == 42)
    }

    /// NON-WEDGE GUARD — this one passes both with and without the fix, and is
    /// here to bound it rather than to demonstrate it. Adoption may only
    /// resolve a static the peer type actually declares; a name it does not
    /// must stay unresolved, so the operator keeps absorbing instead of
    /// manufacturing a plausible number. The failure mode of this fix is the
    /// opposite of the bug it fixes.
    @Test func anUndeclaredNameStillAbsorbs() throws {
        let source = """
        enum FrameConfig { static let statusWidth: CGFloat = 48 }
        FrameConfig.statusWidth + .noSuchSpacing
        """
        #expect(try run(source).doubleValue == 48)
    }
}
