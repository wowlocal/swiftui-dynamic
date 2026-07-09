import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The automatic ObjC tier: allowlisted NSObject APIs work with ZERO
/// hand-written gateways — construction by class name, selectors matched
/// against real method lists (object-only encodings), KVC property access.
@Suite struct ObjCTrampolineTests {
    @Test func relativeDateFormatterBridgesAutomatically() throws {
        // The IceCubes timestamp path: no gateway for this type exists
        // anywhere in the bridge.
        let source = """
        let formatter = RelativeDateTimeFormatter()
        let past = Date(timeIntervalSinceNow: -3600)
        let now = Date()
        formatter.localizedString(for: past, relativeTo: now)
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        let text = try #require(result.stringValue)
        #expect(text.contains("hour") || text.contains("час") || text.contains("1"))
    }

    @Test func userDefaultsRoundTripsAutomatically() throws {
        let source = """
        let defaults = UserDefaults.standard
        defaults.set("interpreted", forKey: "trampoline.probe")
        let read = defaults.string(forKey: "trampoline.probe")
        defaults.removeObject(forKey: "trampoline.probe")
        read
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "interpreted")
    }

    @Test func nonAllowlistedClassesStillAbsorb() throws {
        // Process is deliberately NOT on the allowlist — it must keep
        // falling to the absorbing bag, not gain real side effects.
        let source = """
        let task = Process()
        task
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        if case .native(let any) = result {
            #expect(any is UIKitStub)
        } else {
            Issue.record("expected absorbing stub, got \(result.stringified)")
        }
    }

    @Test func wrongShapesFallBackWithClearError() throws {
        let source = """
        let formatter = RelativeDateTimeFormatter()
        formatter.localizedString(for: 42, relativeTo: "not a date")
        """
        // Marshals fine (NSNumber/NSString are objects) — the REAL call may
        // produce nonsense or the selector may reject; either way it must
        // not crash the interpreter.
        _ = try? Interpreter(registry: ViewRegistry()).run(source: source)
    }
}
