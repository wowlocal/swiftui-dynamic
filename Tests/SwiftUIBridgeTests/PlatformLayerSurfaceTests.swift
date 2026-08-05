import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// `view.layer` — the boundary an interpreted view crosses to configure what
/// it actually draws.
///
/// QuartzCore was absent from BridgeGen's platform sweep, so `CALayer` had no
/// generated contract at all. `view.layer` did not resolve to a property; it
/// degraded into an absorbing call chain, and every write through it —
/// `view.layer?.backgroundColor = …` — was accepted and silently discarded.
/// Nothing reported it, which is the same silence that let the representable
/// class survive: the source ran, the assignment "succeeded", and no pixel
/// moved.
///
/// The fix is one entry in the type-level framework policy (`CALayer` as a
/// QuartzCore root), not a layer-shaped adapter — the sweep then emits that
/// type's whole surface the way it does for every other platform root.
@Suite(.serialized)
struct PlatformLayerSurfaceTests {
    /// RED before the sweep: `bg` stayed nil because the write went to an
    /// absorbing chain rather than the real layer.
    @Test
    @MainActor
    func layerWritesReachTheRealLayer() throws {
        let value = try Interpreter(registry: ViewRegistry()).run(source: """
        import AppKit

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.red.cgColor
        return view
        """)
        guard case .host(let any) = value,
              let platform = any as? GeneratedPlatformValue,
              let view = platform.payload as? NSView else {
            Issue.record("expected a real view, got \(value)")
            return
        }
        let background = try #require(view.layer?.backgroundColor)
        #expect(background.components?.count == 4)
        // Red, read back off the REAL layer rather than off the value the
        // interpreter handed around.
        #expect(background.components?[0] == 1)
        #expect(background.components?[1] == 0)
        #expect(background.components?[2] == 0)
    }

    /// The read itself must be a typed property, not an absorbing chain — the
    /// distinction the whole class turns on.
    @Test
    @MainActor
    func layerReadsResolveToTheRealLayerType() throws {
        let value = try Interpreter(registry: ViewRegistry()).run(source: """
        import AppKit

        let view = NSView()
        view.wantsLayer = true
        return view.layer
        """)
        var inner: RuntimeValue? = value
        if case .optional(let optional) = value { inner = optional.wrapped }
        guard case .host(let any)? = inner else {
            Issue.record("view.layer produced \(value)")
            return
        }
        // Pre-sweep this was a ChainedImplicitCall — an absorbing fallback
        // that answers any member and owns no object.
        #expect(!(any is ChainedImplicitCall))
        let platform = try #require(any as? GeneratedPlatformValue)
        #expect(platform.payload is CALayer)
    }

    /// A layer constructed directly, so the surface is the TYPE's and not a
    /// property's — `CALayer()` is the same swept root reached another way.
    @Test
    @MainActor
    func layerConstructsAndCarriesItsOwnProperties() throws {
        let value = try Interpreter(registry: ViewRegistry()).run(source: """
        import QuartzCore

        let layer = CALayer()
        layer.cornerRadius = 12
        return layer
        """)
        guard case .host(let any) = value,
              let platform = any as? GeneratedPlatformValue,
              let layer = platform.payload as? CALayer else {
            Issue.record("CALayer() produced \(value)")
            return
        }
        #expect(layer.cornerRadius == 12)
    }
}
