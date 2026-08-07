import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// Which SDK types are FORMAT STYLES was answered by scraping generated
/// `format:` parameters, so the family was only ever as wide as the positions
/// that happen to name one. IceCubes' `Models/Alias/ServerDate.swift` writes
/// the shape that scrape cannot see:
/// `Duration.seconds(…).formatted(.units(width: .narrow, maximumUnitCount: 1))`
/// — `Swift.Duration.formatted<S>(_ v: S)` declares its style UNLABELED, so
/// there is no `format:` to scrape and `Duration.UnitsFormatStyle` stayed
/// invisible however many styles the SDK declares.
///
/// The candidate list now comes from the `FormatStyle` CONFORMANCE the
/// interface states, which is the fact that actually defines the family, and
/// the `formatted(_:)` spelling resolves its style through the same list the
/// localization-key interpolation already used.
@Suite struct FormatStyleCandidateTests {
    /// The generated list is read from conformances, so a style reachable only
    /// through an unlabeled parameter is in it.
    @Test func generatedCandidatesCoverConformanceDeclaredStyles() {
        #expect(GeneratedSDKEnumCoercions.formatStyleTypeNames
            .contains("Duration.UnitsFormatStyle"))
    }

    /// Counter-direction: widening the source of truth must not narrow the
    /// search. Every style the `format:` scrape already found is still a
    /// candidate, and the generated list is wholly contained in the candidates.
    @Test func widerSourceOfTruthLosesNoPreviousCandidate() {
        let candidates = Set(LocalizedFormatStyleRendering.candidateStyleTypes)
        #expect(candidates.contains("Date.FormatStyle"))
        #expect(candidates.isSuperset(
            of: GeneratedSDKEnumCoercions.formatStyleTypeNames))
    }

    /// Every name on the list is a type the generated coercion actually
    /// carries an arm for. Without this a list of plausible strings would
    /// satisfy the assertions above; a name with no arm answers with the
    /// unknown-type diagnostic, which is what this rules out.
    @MainActor
    @Test func everyListedStyleIsAGeneratedCoercionArm() {
        let interpreter = Interpreter(registry: ViewRegistry())
        for name in GeneratedSDKEnumCoercions.formatStyleTypeNames {
            // A value no style can be built from: the arm is reached and
            // refuses it, whereas an unlisted type never reaches an arm.
            do {
                _ = try GeneratedSDKEnumCoercions.coerce(
                    name, .native("not a style"), context: interpreter)
            } catch let error as RuntimeError {
                #expect(!error.message.contains(
                    "unknown generated SDK contextual type"),
                    "\(name) is listed but has no generated coercion arm")
            } catch {
                Issue.record("\(name) failed with a non-RuntimeError: \(error)")
            }
        }
    }

    /// The list is not merely present — it selects. `Duration.UnitsFormatStyle`
    /// is chosen for the `.units(…)` chain out of every candidate, and the
    /// reading is the HOST's own for the same spelling.
    @MainActor
    @Test func unitsChainSelectsTheStdlibStyleOutOfEveryCandidate() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let chain = RuntimeValue.native(ImplicitMemberCall(
            name: "units",
            arguments: CallArguments(arguments: [
                CallArguments.Argument(
                    label: "width", value: .implicitMember("narrow")),
                CallArguments.Argument(
                    label: "maximumUnitCount", value: .native(1)),
            ])))
        let rendered = LocalizedFormatStyleRendering.text(
            .native(Duration.seconds(100)), style: chain, interpreter)
        // The "2m" the natively-compiled twin draws for the example post's
        // timestamp on the display-settings screen.
        #expect(rendered == Duration.seconds(100).formatted(
            .units(width: .narrow, maximumUnitCount: 1)))
        // A second duration reads differently through the same chain, so the
        // assertion above cannot pass by answering one memorised string.
        #expect(LocalizedFormatStyleRendering.text(
            .native(Duration.seconds(45)), style: chain, interpreter)
            == Duration.seconds(45).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
    }

    /// Counter-direction on the selection itself: a value no candidate style
    /// accepts is refused rather than rendered through whichever style happens
    /// to sort first.
    @MainActor
    @Test func aValueNoStyleAcceptsIsRefused() {
        let interpreter = Interpreter(registry: ViewRegistry())
        let chain = RuntimeValue.native(ImplicitMemberCall(
            name: "units",
            arguments: CallArguments(arguments: [
                CallArguments.Argument(
                    label: "width", value: .implicitMember("narrow")),
            ])))
        #expect(LocalizedFormatStyleRendering.text(
            .native(UUID()), style: chain, interpreter) == nil)
    }
}
