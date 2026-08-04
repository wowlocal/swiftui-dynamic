import Foundation

/// The localization-relevant form of a string literal written AT a call site.
///
/// SwiftUI selects between `Text(_: LocalizedStringKey)` and
/// `Text(_: some StringProtocol)` on the STATIC form of the argument: a string
/// literal is a localization key, a `String`-typed expression is verbatim
/// content. The two disagree on what an interpolated number means —
/// `Text("\(4097)")` renders `4,097` while `Text(someString)` renders `4097` —
/// so the distinction cannot live on the runtime value, which is the same
/// `String` either way. It lives here, beside the argument, exactly as
/// `CallArgumentSourceProvenance` already carries "this argument was spelled as
/// a direct declaration reference" for the concurrency intrinsics.
///
/// A host adapter whose parameter is a localization key reads `localizedText`;
/// every other consumer keeps reading the ordinary `String` value and is
/// therefore bit-unchanged by this type's existence.
@MainActor
public final class RuntimeLocalizedStringLiteral {
    public enum Segment {
        /// Literal text between interpolations, used verbatim. Native does not
        /// treat it as a format string: `String(localized: "50% off \(4097)")`
        /// is `50% off 4,097`, so a bare `%` survives rather than opening a
        /// directive.
        case text(String)
        /// An interpolation whose type supplies a format specifier — SwiftUI's
        /// `appendInterpolation<T>(_:) where T: _FormatSpecifiable`, which
        /// forwards to `appendInterpolation(value, specifier: formatSpecifier(T.self))`.
        case formatted(RuntimeValue, specifier: String)
    }

    public let segments: [Segment]
    /// The ordinary `String` reading of the same literal, unchanged.
    public let plainText: String

    init(segments: [Segment], plainText: String) {
        self.segments = segments
        self.plainText = plainText
    }

    /// The literal as a localization key resolves it, under the current locale.
    ///
    /// Each interpolation is formatted INDEPENDENTLY and the results are
    /// concatenated with the verbatim text, which is what the native pipeline
    /// observably does: `String(localized: "\(1234)\(5678)")` is `1,2345,678`,
    /// i.e. `1,234` followed by `5,678` rather than one grouped `12345678`.
    /// Passing the locale is the whole difference from `String(format:)` —
    /// `String(format: "%lld", 4097)` is `4097`, and with `locale: .current` in
    /// en_US it is `4,097`.
    public var localizedText: String {
        var out = ""
        for segment in segments {
            switch segment {
            case .text(let text):
                out += text
            case .formatted(let value, let specifier):
                out += Interpreter.cFormattedString(
                    specifier, values: [value], locale: .current)
            }
        }
        return out
    }
}

extension RuntimeValue {
    /// The format specifier SwiftUI's `_FormatSpecifiable` supplies for this
    /// value's type, or nil when the value interpolates verbatim.
    ///
    /// Dispatch is on the runtime numeric identity — `BinaryInteger` and
    /// `BinaryFloatingPoint` — never on a spelled type name, so `UInt`,
    /// `Int8`, `Float` and `CGFloat` are covered by the same rule that covers
    /// `Int` and `Double` without naming any of them. Types outside those
    /// protocols (`String`, `Bool`, a user struct) have no specifier: native
    /// interpolates them verbatim, and for `Bool` it warns that it is falling
    /// back to an unlocalized debug description.
    var localizedFormatSpecifier: String? {
        switch self {
        case .int: return "%lld"
        case .double: return "%lf"
        case .bool, .string: return nil
        case .host(let any):
            if any is Bool || any is String { return nil }
            if let integer = any as? any BinaryInteger {
                return Self.integerSpecifier(integer)
            }
            if any is any BinaryFloatingPoint { return "%lf" }
            return nil
        default: return nil
        }
    }

    private static func integerSpecifier(_ value: some BinaryInteger) -> String {
        Swift.type(of: value).isSigned ? "%lld" : "%llu"
    }
}
