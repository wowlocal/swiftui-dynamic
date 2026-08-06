import AppKit
import SwiftUI
import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// A model held in `@State` and marked `@Observable` must re-render the view
/// that read it when one of its properties mutates — the same as the older
/// `@StateObject` + `ObservableObject` spelling it replaced.
///
/// IceCubes surfaced this on the R2 `trending-timeline` screen.
/// `TimelineView` declares `@State private var viewModel = TimelineViewModel()`
/// (`Packages/Timeline/Sources/Timeline/View/TimelineView.swift:27`) and
/// `StatusesListView` declares `@State private var fetcher: Fetcher`
/// (`Packages/StatusKit/Sources/StatusKit/List/StatusesListView.swift:11`),
/// both over `@Observable` classes. Driven with the app's own arguments the
/// view model DOES fetch, decode and reach `.displayWithGaps` — measured in
/// the capture process itself — but the screen kept drawing
/// `Status.placeholders()` under `.redacted`, because nothing ever
/// re-evaluated the body that had read `.loading`.
///
/// The distinction is exactly which wrapper the view spells. The bridge wired
/// change subscriptions for `@StateObject` / `@ObservedObject` /
/// `@EnvironmentObject` only, so the pre-Observation spelling re-rendered and
/// the Observation spelling did not. The two controls below stay green in BOTH
/// directions on purpose, and were checked that way rather than assumed: they
/// are what says the gap is the wrapper rather than observation in general,
/// and the plain-class one is what a fix that simply subscribed every `@State`
/// class would break.
///
/// Rendering goes through a real `NSHostingView`, deliberately: a headless
/// deep-render re-reads every body from scratch, so it reports the model's
/// FINAL value whether or not any invalidation happened, and cannot see this
/// class at all.
///
/// The mutation is driven FROM THE HOST, by calling the program's own
/// `__flip()` through `Interpreter.callClosure`. Two earlier spellings put it
/// in an interpreted `.task` and both went red on machine load rather than on
/// the bug: inside the full suite, and again inside the gate, where 120s of
/// pumping was not enough for a cooperative thread to reach the mutation while
/// other `@MainActor` suites held the executor. Driving it directly removes
/// scheduling from an assertion that was never about scheduling — what is left
/// under test is exactly "the model changed; did the view repaint".
@MainActor
@Suite("State-held @Observable invalidation", .serialized)
struct StateHeldObservableInvalidationTests {
    /// `@State` + `@Observable` — the spelling IceCubes uses.
    @Test func stateHeldObservableModelRerendersOnMutation() async throws {
        #expect(try await inkAfterFlip(source: Self.stateObservable) > 1000)
    }

    /// Control: the same shape through `@StateObject`, which always worked.
    /// Green before and after the fix — it pins that the missing piece was the
    /// wrapper, not the change signal.
    @Test func stateObjectModelRerendersOnMutation() async throws {
        #expect(try await inkAfterFlip(source: Self.stateObjectObservable) > 1000)
    }

    /// Control: `@State` over a class that is NOT observable must NOT
    /// re-render on member mutation — that is what the compiler does, and a
    /// fix that subscribed every `@State` class would render this black too.
    @Test func stateHeldPlainClassDoesNotRerenderOnMutation() async throws {
        #expect(try await inkAfterFlip(source: Self.statePlainClass) < 100)
    }

    // MARK: - Sources

    /// Every source paints white until its model flips, then paints black over
    /// the whole 60x60 frame, so "did the view re-render" is a pixel count
    /// rather than a string an assertion could read out of a stale tree.
    ///
    /// The model is a top-level value so the view's storage and the host's
    /// `__flip()` name the SAME instance — the view holds it through the
    /// wrapper under test, and the mutation reaches it without going through
    /// that wrapper.
    private static func program(model: String, storage: String) -> String {
        """
        \(model)

        let __model = Model()

        func __flip() { __model.ready = true }

        struct ContentView: View {
            \(storage)
            var body: some View {
                ZStack {
                    Color.white
                    if model.ready { Color.black }
                }
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup { ContentView() }
            }
        }
        """
    }

    private static let stateObservable = program(
        model: """
        @Observable final class Model {
            var ready = false
        }
        """,
        storage: "@State private var model = __model")

    private static let stateObjectObservable = program(
        model: """
        final class Model: ObservableObject {
            @Published var ready = false
        }
        """,
        storage: "@StateObject private var model = __model")

    private static let statePlainClass = program(
        model: """
        final class Model {
            var ready = false
        }
        """,
        storage: "@State private var model = __model")

    // MARK: - Harness

    private static let size = NSSize(width: 60, height: 60)

    /// Renders, flips the model from the host, and returns how many pixels are
    /// dark once the view has had a bounded chance to repaint. The window is
    /// generous rather than tight: a slow machine can only delay the repaint,
    /// and waiting longer for one that never comes cannot turn a red green.
    private func inkAfterFlip(source: String) async throws -> Int {
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().renderSession(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let session) = rendered else {
            Issue.record("render failed: \(rendered)")
            return -1
        }
        let hosting = NSHostingView(
            rootView: session.view
                .frame(width: Self.size.width, height: Self.size.height))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        // Pumped by yielding the main actor, never by blocking it: a
        // `CFRunLoopRunInMode` spin from a `@MainActor` test holds the
        // executor, so anything this test is waiting for runs only AFTER the
        // pixels are read — which reads exactly like a view that never
        // re-rendered.
        func pump() async {
            try? await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        await pump()
        #expect(ink(of: hosting) < 100, "the view started out already black")
        guard let flip = session.interpreter.globals
            .lookup("__flip")?.closureValue
        else {
            Issue.record("the program's __flip() is not in globals")
            return -1
        }
        _ = try session.interpreter.callClosure(flip, arguments: [])
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var dark = 0
        repeat {
            await pump()
            dark = ink(of: hosting)
        } while dark <= 1000 && ContinuousClock.now < deadline
        return dark
    }

    private func ink(of hosting: NSHostingView<some View>) -> Int {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(
            in: hosting.bounds)
        else {
            Issue.record("no bitmap representation")
            return -1
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        var dark = 0
        for x in 0..<Int(Self.size.width) {
            for y in 0..<Int(Self.size.height) {
                if let color = rep.colorAt(x: x, y: y),
                   color.brightnessComponent < 0.5 {
                    dark += 1
                }
            }
        }
        return dark
    }
}
