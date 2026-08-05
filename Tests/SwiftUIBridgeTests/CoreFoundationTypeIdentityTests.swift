import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A value whose declared type is a CoreFoundation type.
///
/// Every CF type shares ONE opaque dynamic class. Reflection therefore reports
/// `CGColor`, `CGPath`, `CGImage` and the rest of the family under the single
/// name `__NSCFType`, so a host declaration returning any of them reads as
/// violated the moment the interpreter type-checks it:
///
///     host contract violation: property 'var NSColor.cgColor: CGColor { get }'
///     produced '__NSCFType', expected 'CGColor'
///
/// NATIVE BASELINE, measured with real `swiftc` rather than assumed — this is
/// a fact about the Swift/CF runtime, not an interpreter defect:
///
///     type(of: NSColor.red.cgColor)                     // __NSCFType
///     CFCopyTypeIDDescription(CFGetTypeID(…))           // CGColor
///     type(of: CGMutablePath() as Any)                  // __NSCFType
///     CFCopyTypeIDDescription(CFGetTypeID(…))           // CGPath
///
/// So the fix resolves the CFTypeID, which answers the WHOLE family at once —
/// not a list of CF types enumerated one interface at a time.
///
/// Surfaced by IceCubes' media browser: `MediaUIZoomableContainer`'s
/// representable sets `view.layer?.backgroundColor` from a `cgColor`, and the
/// contract violation aborted the representable's `makeUIView` before it could
/// return a view at all.
@Suite(.serialized)
struct CoreFoundationTypeIdentityTests {
    /// The exact shape the diagnostic named: a CF-typed SDK property read
    /// through a host declaration that DECLARES the CF type. RED before the
    /// fix — the read itself threw, because the produced value matched no
    /// `CGColor` contract.
    @Test
    @MainActor
    func cfTypedPropertyMeetsItsDeclaredContract() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let value = try interpreter.run(source: """
        import AppKit

        return NSColor.red.cgColor
        """)
        // Reaching here at all is the regression pin: pre-fix this threw
        // "host contract violation: … produced '__NSCFType', expected
        // 'CGColor'". The name the interpreter now reports for it is the
        // nominal the SDK declares.
        #expect(interpreter.hostTypeName(of: value) == "CGColor")
    }

    /// The same read in the position that actually surfaced it — assigned
    /// onto a layer, the way a representable's `make` configures the view it
    /// is about to return.
    @Test
    @MainActor
    func cfValueAssignsOntoAPlatformProperty() throws {
        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(source: """
        import AppKit

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.red.cgColor
        return view
        """)
        #expect(RenderDiagnostics.errors.isEmpty)
    }

    /// The mechanism itself, over two unrelated CF types, so the fix cannot be
    /// satisfied by special-casing the one type that surfaced it.
    @Test
    @MainActor
    func cfTypeIdentityResolvesAcrossTheFamily() throws {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let color: Any = NSColor.red.cgColor
#else
        let color: Any = UIColor.red.cgColor
#endif
        let path: Any = CGMutablePath()

        #expect(HostRuntimeTypeSystem.coreFoundationTypeName(of: color) == "CGColor")
        #expect(HostRuntimeTypeSystem.coreFoundationTypeName(of: path) == "CGPath")

        // A non-CF value must be left entirely alone: the resolution is keyed
        // on the opaque class, so an ordinary object keeps its own nominal.
        #expect(HostRuntimeTypeSystem.coreFoundationTypeName(of: NSObject()) == nil)
        #expect(HostRuntimeTypeSystem.coreFoundationTypeName(of: "text") == nil)
    }

    /// Type MATCHING, not just naming: a declared `CGColor` contract must
    /// accept the value, which is the half that actually unblocked the render.
    @Test
    @MainActor
    func cfValueMatchesItsDeclaredTypeName() throws {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let color = RuntimeValue.host(NSColor.red.cgColor)
#else
        let color = RuntimeValue.host(UIColor.red.cgColor)
#endif
        #expect(HostRuntimeTypeSystem.matches(color, type: "CGColor"))
        // Negative control: the family is resolved, not waved through — a
        // CGColor still does not satisfy a CGPath contract.
        #expect(!HostRuntimeTypeSystem.matches(color, type: "CGPath"))
    }
}
