import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge
#if canImport(AppKit)
import AppKit
#endif

/// An array literal is how Swift spells an `OptionSet` value, and the elements
/// of that literal have no type of their own — `[.width, .height]` is typed
/// only by the contract it is assigned to. Distilled from
/// `MediaUIZoomableContainer.swift:58`
/// (`hostedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]`), which
/// is the first statement of the IceCubes media browser's representable and
/// took the whole screen down with
/// `host contract violation: property 'var UIView.autoresizingMask:
/// UIView.AutoresizingMask { get set }' was assigned '[ImplicitMember]',
/// expected 'UIView.AutoresizingMask'`.
///
/// The repro uses AppKit's `NSView.autoresizingMask` rather than the UIKit
/// property that surfaced it: the suite runs on macOS, the two properties are
/// the same shape through the same generated platform tier, and an expectation
/// that cannot run natively here could not be native-verified. Every expected
/// value below is what `xcrun swift` prints for the same three assignments —
/// `[.width, .height]` is 18, `[]` is 0, and a literal mixing a leading-dot
/// member with an existing mask value is 18.
@Suite(.serialized) struct PlatformOptionSetLiteralTests {
#if canImport(AppKit)
    private func run(_ body: String) throws -> RuntimeValue {
        try Interpreter(registry: TraceRegistry()).run(
            source: ProjectMaterial.mergedSource(
                source: """
                import AppKit

                \(body)
                """,
                moduleName: "PlatformOptionSetLiteral"))
    }

    /// The failing shape itself: two leading-dot members in an array literal
    /// assigned to an `OptionSet` property. RED before the fix at the host
    /// contract check, which rejected the literal before any gateway could
    /// convert it.
    @Test func arrayLiteralOfImplicitMembersFormsAnOptionSet() throws {
        let value = try run("""
            let view = NSView()
            view.autoresizingMask = [.width, .height]
            view.autoresizingMask.rawValue
            """)
        #expect(value.intValue == 18)
    }

    /// `[]` is the empty option set, not an empty array: the same literal
    /// syntax, with nothing in it to carry a type.
    @Test func emptyArrayLiteralFormsTheEmptyOptionSet() throws {
        let value = try run("""
            let view = NSView()
            view.autoresizingMask = [.width, .height]
            view.autoresizingMask = []
            view.autoresizingMask.rawValue
            """)
        #expect(value.intValue == 0)
    }

    /// An option-set literal may mix leading-dot members with values that
    /// already have the contract's type — `Element == Self`, so both spellings
    /// are the same conversion and the result is their union.
    @Test func optionSetLiteralUnionsMembersWithExistingValues() throws {
        let value = try run("""
            let view = NSView()
            view.autoresizingMask = [.width]
            view.autoresizingMask = [.height, view.autoresizingMask]
            view.autoresizingMask.rawValue
            """)
        #expect(value.intValue == 18)
    }

    /// The conversion belongs to the OPTION SET, not to the property that
    /// happens to hold one: the same literal has to cross an ARGUMENT contract
    /// too, through a different framework and a different declaration shape.
    /// `ProcessInfo.performActivity(options:reason:using:)` runs its body
    /// natively, so an admitted literal is observable as the body's effect
    /// rather than as a value read back out of the receiver.
    @Test func optionSetLiteralCrossesAnArgumentContract() throws {
        let value = try run("""
            final class ActivityRecorder {
                var value = "pending"
            }

            let activityRecorder = ActivityRecorder()
            ProcessInfo.processInfo.performActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "option-set literal repro"
            ) {
                activityRecorder.value = "entered"
            }
            activityRecorder.value
            """)
        #expect(value.stringValue == "entered")
    }

    /// The deferral must stay a rule about literals whose elements carry no
    /// type of their own. An array of typed values reaching a scalar contract
    /// is not an option-set literal, and it must still be refused rather than
    /// silently converted.
    @Test func arrayOfUnrelatedValuesStillFailsTheContract() throws {
        #expect(throws: (any Error).self) {
            try run("""
                let view = NSView()
                view.autoresizingMask = ["width", "height"]
                view.autoresizingMask.rawValue
                """)
        }
    }
#endif
}
