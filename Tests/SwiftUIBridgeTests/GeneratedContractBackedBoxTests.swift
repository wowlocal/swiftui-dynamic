import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// A handwritten host box keeps only the members that need genuine
/// interpreted behavior; every OTHER property its logical SDK type declares
/// must reach the generated reference contract and drive the live Foundation
/// object. Surfaced by `oss:home-assistant-ios`, which resolved a settings
/// collection into code that writes `DateFormatter.formattingContext` — a
/// property `GeneratedFoundationReferenceProperties` already declares but the
/// handwritten `DateFormatterBox` switch failed closed on.
///
/// Every expectation is the output of the same program compiled with real
/// `swiftc` (see the string literals below, captured once from the native
/// run), never hand-written.
@Suite struct GeneratedContractBackedBoxTests {
    /// `false|M11|Today|today|true` — native, and identical under `TZ=UTC`
    /// and `TZ=Pacific/Auckland`. The format deliberately omits the day:
    /// `DateFormatter.timeZone` is typed `TimeZone!`, so BridgeGen's
    /// class-and-enum result-type filter never emitted its contract and the
    /// handwritten box still drops the write. That is a separate emission
    /// gap, tracked on its own; pinning it here would measure it instead of
    /// this routing.
    @Test func dateFormatterServesPropertiesOutsideItsHandwrittenSurface()
        throws {
        let source = """
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let before = formatter.doesRelativeDateFormatting
        formatter.monthSymbols = [
            "M01", "M02", "M03", "M04", "M05", "M06",
            "M07", "M08", "M09", "M10", "M11", "M12",
        ]
        formatter.dateFormat = "MMMM"
        let month = formatter.string(from: Date(timeIntervalSince1970: 1700000000))
        formatter.formattingContext = .beginningOfSentence
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let relative = formatter.string(from: Date())
        formatter.formattingContext = .middleOfSentence
        let midSentence = formatter.string(from: Date())
        "\\(before)|\\(month)|\\(relative)|\\(midSentence)|\\(formatter.doesRelativeDateFormatting)"
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "false|M11|Today|today|true")
    }

    /// The same fall-through on the other handwritten Foundation formatter
    /// box, so the mechanism is shared rather than one box's repair.
    /// `1,234.50|1.234,50` — native.
    @Test func numberFormatterServesPropertiesOutsideItsHandwrittenSurface()
        throws {
        let source = """
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        let grouped = formatter.string(from: 1234.5)!
        formatter.groupingSeparator = "."
        formatter.decimalSeparator = ","
        let european = formatter.string(from: 1234.5)!
        "\\(grouped)|\\(european)"
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "1,234.50|1.234,50")
    }
}
