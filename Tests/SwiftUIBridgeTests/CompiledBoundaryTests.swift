import Foundation
import SwiftInterpreter
import Testing
@testable import SwiftUIBridge

/// EXPERIMENT: prove an SDK member call can be serviced by a shim compiled
/// from its already-parsed `HostSignature`, with no per-API code anywhere.
@Suite(.serialized)
@MainActor
struct CompiledBoundaryTests {

    /// The emitter is driven purely off the signature — no SDK knowledge.
    @Test func emitsShimFromSignatureAlone() throws {
        let signature = try HostSignature(
            parsing: "func Calendar.component("
                + "_ p0: Calendar.Component, from p1: Date) -> Int")
        let shim = try #require(
            CompiledBoundary.shimSource(for: signature, symbol: "cb_probe"))
        #expect(shim.contains("as? Calendar"))
        #expect(shim.contains("as? Calendar.Component"))
        #expect(shim.contains("as? Date"))
        #expect(shim.contains("receiver.component(p0, from: p1)"))
    }

    /// Native marshalling: a real Calendar receiver, real Calendar.Component
    /// and Date arguments, a real Int back — all as Swift `Any`, no encoding.
    @Test func compilesAndCallsRealSDKMethod() throws {
        let signature = try HostSignature(
            parsing: "func Calendar.component("
                + "_ p0: Calendar.Component, from p1: Date) -> Int")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(
            DateComponents(
                calendar: calendar, timeZone: calendar.timeZone,
                year: 2026, month: 7, day: 28).date)

        let value = try CompiledBoundary.shared.invoke(
            signature: signature,
            receiver: calendar,
            arguments: [Calendar.Component.year, date])
        #expect(value.intValue == 2026)

        let month = try CompiledBoundary.shared.invoke(
            signature: signature,
            receiver: calendar,
            arguments: [Calendar.Component.month, date])
        #expect(month.intValue == 7)
    }

    /// A reference-typed receiver crosses by identity, not by copy — the thing
    /// a JSON boundary cannot do.
    @Test func referenceTypeReceiverCrossesByIdentity() throws {
        let signature = try HostSignature(
            parsing: "func NSMutableArray.add(_ p0: Any) -> Void")
        let array = NSMutableArray()
        _ = try CompiledBoundary.shared.invoke(
            signature: signature, receiver: array, arguments: [42])
        _ = try CompiledBoundary.shared.invoke(
            signature: signature, receiver: array, arguments: [43])
        // Mutation landed on the caller's own object.
        #expect(array.count == 2)
        #expect(array[0] as? Int == 42)
    }

    /// The second call for the same signature must not recompile.
    @Test func cachesCompiledShims() throws {
        let signature = try HostSignature(
            parsing: "func Calendar.isDateInWeekend(_ p0: Date) -> Bool")
        let calendar = Calendar(identifier: .gregorian)
        let cold = ContinuousClock.now
        _ = try CompiledBoundary.shared.invoke(
            signature: signature, receiver: calendar, arguments: [Date()])
        let coldElapsed = ContinuousClock.now - cold
        let warm = ContinuousClock.now
        _ = try CompiledBoundary.shared.invoke(
            signature: signature, receiver: calendar, arguments: [Date()])
        let warmElapsed = ContinuousClock.now - warm
        #expect(warmElapsed < coldElapsed)
        #expect(warmElapsed < .milliseconds(5))
    }

    /// END TO END: the same interpreted source, dispatched through the real
    /// bridge, must produce the SAME answer whether generated members run
    /// their hand-emitted `invoke` closures or shims compiled from signatures.
    ///
    /// URL/TimeZone/Locale have no hand box, so these calls genuinely reach
    /// `GeneratedDispatch` — the seam every generated member flows through.
    @Test func interpretedSourceMatchesWithAndWithoutCompiledBoundary() throws {
        // Shaped like the Mastodon client's URL building.
        let source = """
        let base = URL(string: "https://mstdn.social/api/v1")!
        let timelines = base.appendingPathComponent("timelines")
        let parent = timelines.deletingLastPathComponent()
        let zone = TimeZone(identifier: "America/New_York")!
        let offset = zone.secondsFromGMT()
        let dst = zone.isDaylightSavingTime()
        let english = Locale(identifier: "en_US")
            .localizedString(forLanguageCode: "fr")!
        "\\(timelines.absoluteString)|\\(parent.absoluteString)"
            + "|\\(offset)|\\(dst)|\\(english)"
        """

        func evaluate() throws -> String? {
            let interpreter = Interpreter(
                registry: ViewRegistry(projectResourceRoot: nil))
            return try interpreter.run(source: source).stringValue
        }

        let baseline = try evaluate()
        #expect(baseline != nil)
        #expect(baseline?.contains("api/v1/timelines") == true)

        var jitted: String?
        try withBoundaryJIT {
            CompiledBoundary.resetTelemetry()
            jitted = try evaluate()
            print("serviced by compiled shims:")
            for declaration in CompiledBoundary.serviced.sorted() {
                print("  \(declaration)")
            }
            if !CompiledBoundary.fellBack.isEmpty {
                print("fell back:")
                for (declaration, reason) in CompiledBoundary.fellBack.sorted(
                    by: { $0.key < $1.key }
                ) {
                    print("  \(declaration) — \(reason)")
                }
            }
        }

        #expect(jitted == baseline)
        #expect(!CompiledBoundary.serviced.isEmpty)
    }

    private func withBoundaryJIT(_ body: () throws -> Void) rethrows {
        setenv("BOUNDARY_JIT", "1", 1)
        defer { unsetenv("BOUNDARY_JIT") }
        try body()
    }
}
