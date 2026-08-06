import Testing

@testable import SwiftInterpreter

/// A `RawRepresentable` conformance added in an extension carries its OWN
/// `rawValue`, and that written property is the type's `rawValue`.
///
/// An enum with associated values is not raw-valued and has no implicit
/// ordinal to expose. IceCubes' `TimelineFilter`
/// (`Packages/Timeline/Sources/Timeline/TimelineFilter.swift:375`) is exactly
/// that shape: plain cases plus `case hashtag(tag:accountId:)`, conforming in
/// an extension whose `var rawValue: String` JSON-encodes `self`. Reading the
/// ordinal instead returns an `Int`, and the R2 `trending-timeline` screen
/// showed what that costs — `Telemetry.signal(parameters:)` takes
/// `[String: String]`, so the mistyped value fails the call inside the
/// `timeline` observer's `Task`, which returns before ever reaching
/// `fetchNewestStatuses`. No request, no error state, full quiescence: a
/// silently dead fetch.
///
/// Expectations here are what `swiftc` prints for the same declarations.
@Suite("Extension-supplied rawValue")
struct ExtensionSuppliedRawValueTests {
    /// The written property wins over any synthesized ordinal, and its result
    /// is a `String` — so it composes where a `String` is required.
    @Test func writtenRawValueAnswersForAnEnumWithAssociatedValues() throws {
        let source = """
        enum Filter: Hashable {
            case home, local, federated, trending
            case hashtag(tag: String)
        }

        extension Filter: RawRepresentable {
            init?(rawValue: String) { return nil }

            var rawValue: String {
                switch self {
                case .home: "home"
                case .local: "local"
                case .federated: "federated"
                case .trending: "trending"
                case .hashtag(let tag): "hashtag:" + tag
                }
            }
        }

        let parameters: [String: String] = ["timeline": Filter.trending.rawValue]
        (parameters["timeline"] ?? "missing")
            + "|" + Filter.hashtag(tag: "swift").rawValue
            + "|" + Filter.home.rawValue
        """
        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "trending|hashtag:swift|home")
    }

    /// The same rule when the conformance is declared on the type itself
    /// rather than in an extension: a written `rawValue` is still the
    /// `rawValue`, so the fix cannot key on where the conformance was spelled.
    @Test func writtenRawValueAnswersOnTheTypeDeclarationToo() throws {
        let source = """
        enum Filter: RawRepresentable, Hashable {
            case home
            case hashtag(tag: String)

            init?(rawValue: String) { return nil }

            var rawValue: String {
                switch self {
                case .home: "home"
                case .hashtag(let tag): "hashtag:" + tag
                }
            }
        }

        Filter.hashtag(tag: "ios").rawValue + "|" + Filter.home.rawValue
        """
        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "hashtag:ios|home")
    }

    /// The negative half: a genuinely raw-valued enum keeps the raw values the
    /// compiler assigns it, including the implicit-successor rule. A fix that
    /// simply stopped synthesizing `rawValue` would break this.
    @Test func declaredRawValuesAreUnchanged() throws {
        let source = """
        enum StringFilter: String {
            case home
            case trending = "trend"
        }

        enum IntFilter: Int {
            case zero
            case five = 5
            case six
        }

        StringFilter.home.rawValue + "|" + StringFilter.trending.rawValue
            + "|" + String(IntFilter.zero.rawValue)
            + "|" + String(IntFilter.five.rawValue)
            + "|" + String(IntFilter.six.rawValue)
        """
        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "home|trend|0|5|6")
    }
}
