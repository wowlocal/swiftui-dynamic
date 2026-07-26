import AppKit
import Foundation
import SwiftUI
import SwiftInterpreter
import Testing
@testable import SwiftUIBridge

private actor AsyncImagePresentationGate {
    private(set) var started = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

private struct NativeAsyncImagePresentationTwin: View {
    let isPresented: Bool

    var body: some View {
        ZStack {
            Color.white
            if isPresented {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.blue)
                    .frame(width: 48, height: 48)
            } else {
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 48, height: 48)
            }
        }
        .frame(width: 96, height: 72)
    }
}

/// A pixel-level decomposition of the asynchronous presentation boundary
/// surfaced by IceCubes media rows. The fixture contains no application or
/// image-pipeline code: an owned source task alone separates placeholder
/// pixels from a delivered native Image.
@Suite(.serialized)
struct AsyncImagePresentationMicroTwinTests {
    @MainActor
    @Test
    func captureFollowsOwnedTaskThroughPresentation() async throws {
        let source = """
        var presentationFinished = false
        var presentationBodyObserved = false

        struct AsyncImagePresentationTwin: View {
            @State private var isPresented = false

            var body: some View {
                ZStack {
                    Color.white
                    if isPresented {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.blue)
                            .frame(width: 48, height: 48)
                            .onAppear {
                                presentationBodyObserved = true
                            }
                    } else {
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 48, height: 48)
                    }
                }
                .frame(width: 96, height: 72)
                .task {
                    await waitForAsyncImagePresentation()
                    isPresented = true
                    presentationFinished = true
                }
            }
        }

        AsyncImagePresentationTwin()
        """

        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let gate = AsyncImagePresentationGate()
        interpreter.globals.define(
            "waitForAsyncImagePresentation",
            .hostFunction(HostFunction(
                name: "waitForAsyncImagePresentation",
                asyncInvoke: { _, _ in
                    await gate.wait()
                    return .void
                })))
        let result = try interpreter.run(
            source: source, lazyTopLevelGlobals: true)
        guard case .instance(let instance) = result else {
            Issue.record("micro-twin root did not instantiate: \(result)")
            return
        }
        let interpreted = try ViewRegistry.anyView(
            registry.makeRenderable(
                instance: instance, interpreter: interpreter))

        let size = NSSize(width: 96, height: 72)
        let hosting = NSHostingView(rootView: interpreted)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        let becameActive = await Self.waitUntil(
            hosting: hosting, window: window
        ) {
            await gate.started
                && !interpreter.runtimeActivity.isQuiescent
        }
        #expect(becameActive)
        #expect(!interpreter.runtimeActivity.isQuiescent)

        let pending = Self.bitmap(hosting, window: window, size: size)
        let nativePending = Self.bitmap(
            AnyView(NativeAsyncImagePresentationTwin(isPresented: false)),
            size: size)
        let nativePresented = Self.bitmap(
            AnyView(NativeAsyncImagePresentationTwin(isPresented: true)),
            size: size)
        let pendingAE = Self.pixelAE(pending, nativePending, size: size)
        let prematureAE = Self.pixelAE(
            pending, nativePresented, size: size)
        #expect(pendingAE == 0)
        #expect(prematureAE > 0)

        await gate.release()
        let becamePresentable = await Self.waitUntil(
            hosting: hosting, window: window
        ) {
            interpreter.globals.lookup("presentationFinished")?
                .boolValue == true
                && interpreter.globals.lookup("presentationBodyObserved")?
                    .boolValue == true
                && interpreter.runtimeActivity.isQuiescent
        }
        #expect(becamePresentable)
        #expect(interpreter.runtimeActivity.isQuiescent)

        let presented = Self.bitmap(hosting, window: window, size: size)
        let presentedAE = Self.pixelAE(
            presented, nativePresented, size: size)
        print(
            "@@async-image-presentation-microtwin"
                + " pendingAE=\(pendingAE)"
                + " prematureAE=\(prematureAE)"
                + " presentedAE=\(presentedAE)")
        #expect(presentedAE == 0)
    }

    @MainActor
    private static func waitUntil(
        hosting: NSHostingView<AnyView>,
        window: NSWindow,
        timeout: Duration = .seconds(20),
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) && clock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // Leave MainActor's runnable queue so SwiftUI's view task can
            // advance under the repository's fully parallel test process.
            try? await Task.sleep(for: .milliseconds(10))
        }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return await condition()
    }

    @MainActor
    private static func bitmap(
        _ view: AnyView,
        size: NSSize
    ) -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        return bitmap(hosting, window: window, size: size)
    }

    @MainActor
    private static func bitmap(
        _ hosting: NSHostingView<AnyView>,
        window: NSWindow,
        size: NSSize
    ) -> NSBitmapImageRep {
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)!
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private static func pixelAE(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        size: NSSize
    ) -> Int {
        var mismatched = 0
        for x in 0..<Int(size.width) {
            for y in 0..<Int(size.height)
            where lhs.colorAt(x: x, y: y)
                != rhs.colorAt(x: x, y: y) {
                mismatched += 1
            }
        }
        return mismatched
    }
}
