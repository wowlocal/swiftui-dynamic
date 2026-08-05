import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Constructing a platform class with NO arguments.
///
/// A symbol graph lists an initializer on the type that DECLARES it. `init()`
/// is NSObject's, so no subclass carries an entry for it, and BridgeGen's
/// sweep — which emits what the graph declares — had nothing to emit. Every
/// `NSView()` / `UIScrollView()` therefore missed the typed contract and
/// absorbed into a payload-less stub: an object that answers every member
/// inertly and reaches no real view hierarchy.
///
/// The absorber's own comment already named the cause ("Symbol graphs omit
/// some inherited/importer-synthesized initializer shapes") while leaving the
/// zero-argument case to degrade. The runtime has the real class, and a
/// no-argument construction is exactly what `init()` names, so resolving it
/// there answers the whole swept family rather than re-declaring initializers
/// one type at a time.
///
/// Surfaced by IceCubes' `MediaUIZoomableContainer`, whose representable opens
/// `let scrollView = UIScrollView()`.
@Suite(.serialized)
struct PlatformClassConstructionTests {
    @Test
    @MainActor
    func zeroArgumentConstructionYieldsARealObject() throws {
        let value = try Interpreter(registry: ViewRegistry()).run(source: """
        import AppKit

        return NSView()
        """)
        guard case .host(let any) = value,
              let platform = any as? GeneratedPlatformValue else {
            Issue.record("NSView() produced \(value), not a platform value")
            return
        }
        // The payload is the whole point: pre-fix this was nil, which is what
        // made the object inert rather than merely untyped.
        #expect(platform.typeName == "NSView")
        #expect(platform.payload is NSView)
    }

    /// An initializer the sweep DOES declare must keep taking the typed path,
    /// so the fallback cannot quietly shadow the generated contract.
    @Test
    @MainActor
    func declaredInitializerStillUsesItsGeneratedContract() throws {
        let value = try Interpreter(registry: ViewRegistry()).run(source: """
        import AppKit

        return NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        """)
        guard case .host(let any) = value,
              let platform = any as? GeneratedPlatformValue,
              let view = platform.payload as? NSView else {
            Issue.record("NSView(frame:) produced \(value)")
            return
        }
        // The declared initializer carries its argument through; the
        // zero-argument fallback could not have produced this frame.
        #expect(view.frame.width == 40)
        #expect(view.frame.height == 20)
    }

    /// The resolution is keyed on the ObjC runtime, so a name that is not an
    /// ObjC class resolves to nothing and keeps the established stub rather
    /// than inventing an object.
    @Test
    @MainActor
    func nonObjectiveCNamesKeepTheEstablishedStub() throws {
        #expect(GeneratedPlatformBridge.objectiveCInstance(ofType: "NSView") is NSView)
        #expect(GeneratedPlatformBridge.objectiveCInstance(
            ofType: "NoSuchPlatformClass") == nil)
        // A nested type names no ObjC class and already has real generated
        // initializers of its own.
        #expect(GeneratedPlatformBridge.objectiveCInstance(
            ofType: "NSView.AutoresizingMask") == nil)
    }
}
