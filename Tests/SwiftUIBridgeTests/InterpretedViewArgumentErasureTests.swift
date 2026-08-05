import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// An interpreted type conforming to `View`, passed where the interface
/// declares `any View` — under EITHER instrument.
///
/// `AnyView.generatedPlatformValue` resolved a bare interpreted instance only
/// when `interpreter.registry as? ViewRegistry` held, and otherwise fell to
/// the host-only static erasure, which rejects `.instance`:
///
///     host contract violation: nonthrowing
///     'init NSHostingView(rootView p0: any View)' threw:
///     expected a View, got AccessibilityPermissionView()
///
/// So the SAME source that rendered under the pixel harness threw under the
/// trace harness at the same line. Which registry drives a run is a property
/// of the HARNESS, never of the argument, and it must not decide whether a
/// conforming View is a View. The resolution now goes through the
/// `HostRegistry.makeRenderable` requirement, so both instruments answer it.
///
/// Surfaced by the corpus under `ProjectCheck`, which runs the trace
/// instrument: `oss:Gifski` (`CropOverlayView`) and `oss:linearmouse`
/// (`AccessibilityPermissionView`), both through `NSHostingView(rootView:)`.
///
/// NATIVE BASELINE: `NSHostingView(rootView: MyView())` compiles and runs
/// under real `swiftc` for any `struct MyView: View` — the argument satisfies
/// `any View` by conformance. Nothing here is an interpreter-only
/// expectation.
///
/// MEASURED AT THE COERCION, NOT THROUGH A RENDER. An earlier draft asserted
/// on `LiveCheckSupport.renderedStrings`, which cannot see this class at all:
/// the trace instrument walks the INTERPRETED tree, so content handed to a
/// native container's non-builder argument is invisible to it whether or not
/// the erasure succeeded — a native `Text` label reads as dropped exactly
/// like a failed one. The defect is a throw at a host boundary, so the throw
/// is what is asserted.
@Suite(.serialized)
struct InterpretedViewArgumentErasureTests {
    private static let source = """
    import SwiftUI
    import AppKit

    struct CropOverlay: View {
        var body: some View { Text("overlay") }
    }

    return NSHostingView(rootView: CropOverlay())
    """

    /// The instrument the corpus runs, and the one that was RED. Before the
    /// fix this threw the host contract violation quoted above.
    @Test
    @MainActor
    func aHostBoundaryAcceptsAnInterpretedViewUnderTheTraceInstrument() throws
    {
        let interpreter = Interpreter(registry: TraceRegistry())
        let value = try interpreter.run(source: Self.source)
        #expect(interpreter.hostTypeName(of: value) == "NSHostingView")
    }

    /// The instrument that was already GREEN, kept as the control that names
    /// the disagreement: the assertion is identical and only the registry
    /// differs, so a future change that fixes one instrument by breaking the
    /// other cannot pass this file.
    @Test
    @MainActor
    func aHostBoundaryAcceptsAnInterpretedViewUnderThePixelInstrument() throws
    {
        let interpreter = Interpreter(registry: ViewRegistry())
        let value = try interpreter.run(source: Self.source)
        #expect(interpreter.hostTypeName(of: value) == "NSHostingView")
    }

    /// A source type conforming through a PROTOCOL EXTENSION body rather than
    /// declaring `body` itself still conforms, so it is still a legal
    /// `any View`. This pins the rule to conformance rather than to the
    /// presence of a stored body.
    @Test
    @MainActor
    func conformanceIsWhatTheArgumentMustSatisfy() throws {
        let interpreter = Interpreter(registry: TraceRegistry())
        let value = try interpreter.run(source: """
        import SwiftUI
        import AppKit

        protocol Captioned: View {}

        extension Captioned {
            var body: some View { Text("from-extension") }
        }

        struct Caption: Captioned {}

        return NSHostingView(rootView: Caption())
        """)
        #expect(interpreter.hostTypeName(of: value) == "NSHostingView")
    }
}
