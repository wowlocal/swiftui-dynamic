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
/// view model DOES fetch, decode and reach
/// `.displayWithGaps` — measured in the capture process itself — but the
/// screen kept drawing `Status.placeholders()` under `.redacted`, because
/// nothing ever re-evaluated the body that had read `.loading`.
///
/// The distinction is exactly which wrapper the view spells. The bridge wired
/// change subscriptions for `@StateObject` / `@ObservedObject` /
/// `@EnvironmentObject` only, so the pre-Observation spelling re-rendered and
/// the Observation spelling did not. The three controls below stay green in
/// BOTH directions on purpose, and were checked that way rather than assumed:
/// they are what says the gap is the wrapper rather than observation in
/// general, and they are what a fix that simply subscribed every `@State`
/// class would break.
///
/// Rendering goes through a real `NSHostingView`, deliberately: a headless
/// deep-render re-reads every body from scratch, so it reports the model's
/// FINAL value whether or not any invalidation happened, and cannot see this
/// class at all.
@MainActor
@Suite("State-held @Observable invalidation", .serialized)
struct StateHeldObservableInvalidationTests {
    /// `@State` + `@Observable` — the spelling IceCubes uses.
    @Test func stateHeldObservableModelRerendersOnMutation() async throws {
        #expect(try await inkAfterRerender(source: Self.stateObservable) > 1000)
    }

    /// Control: the same shape through `@StateObject`, which always worked.
    /// Green before and after the fix — it pins that the missing piece was the
    /// wrapper, not the change signal.
    @Test func stateObjectModelRerendersOnMutation() async throws {
        #expect(try await inkAfterRerender(source: Self.stateObjectObservable) > 1000)
    }

    /// Control: `@State` over a class that is NOT observable must NOT
    /// re-render on member mutation — that is what the compiler does, and a
    /// fix that subscribes every `@State` class would render this black too.
    @Test func stateHeldPlainClassDoesNotRerenderOnMutation() async throws {
        #expect(try await inkWithoutRerender(source: Self.statePlainClass) < 100)
    }

    /// Control: reassigning the whole `@State` reference re-renders even for a
    /// plain class — the box changed, which is a different signal from a
    /// member mutation.
    @Test func stateReferenceReassignmentRerenders() async throws {
        #expect(try await inkAfterRerender(source: Self.stateReassignment) > 1000)
    }

    // MARK: - Sources

    /// Every source paints white until its model flips, then paints black over
    /// the whole 60x60 frame, so "did the view re-render" is a pixel count
    /// rather than a string an assertion could read out of a stale tree.
    private static func program(
        model: String, storage: String, flip: String
    ) -> String {
        """
        \(model)

        struct ContentView: View {
            \(storage)
            var body: some View {
                ZStack {
                    Color.white
                    if model.ready { Color.black }
                }
                .task {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    \(flip)
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
        storage: "@State private var model = Model()",
        flip: "model.ready = true")

    private static let stateObjectObservable = program(
        model: """
        final class Model: ObservableObject {
            @Published var ready = false
        }
        """,
        storage: "@StateObject private var model = Model()",
        flip: "model.ready = true")

    private static let statePlainClass = program(
        model: """
        final class Model {
            var ready = false
        }
        """,
        storage: "@State private var model = Model()",
        flip: "model.ready = true")

    private static let stateReassignment = program(
        model: """
        final class Model {
            var ready: Bool
            init(ready: Bool) { self.ready = ready }
        }
        """,
        storage: "@State private var model = Model(ready: false)",
        flip: "model = Model(ready: true)")

    // MARK: - Harness

    private static let size = NSSize(width: 60, height: 60)

    /// Renders, then pumps until the view has repainted — returning as soon as
    /// it has. A fixed pump window is a load-dependent assertion: the same
    /// program that repaints in 40ms on an idle machine needs longer than two
    /// seconds while the rest of this suite runs, and the resulting red is
    /// indistinguishable from the bug.
    private func inkAfterRerender(source: String) async throws -> Int {
        try await ink(
            source: source, settlingWhen: { $0 > 1000 }, within: .seconds(30))
    }

    /// The negative reading of the same measurement. "Nothing happened" cannot
    /// settle early, so this one does pump its whole window — but nothing about
    /// it is timing-sensitive in the direction that matters: a LATE repaint
    /// would still be a repaint, and a longer window can only make it stricter.
    private func inkWithoutRerender(source: String) async throws -> Int {
        try await ink(
            source: source, settlingWhen: { _ in false }, within: .seconds(4))
    }

    /// Renders through a real hosting view, pumps the main actor until
    /// `settlingWhen` accepts the pixel count or the window expires, and
    /// returns how many pixels are dark.
    private func ink(
        source: String,
        settlingWhen settled: (Int) -> Bool,
        within timeout: Duration
    ) async throws -> Int {
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed: \(rendered)")
            return -1
        }
        let hosting = NSHostingView(
            rootView: view
                .frame(width: Self.size.width, height: Self.size.height))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // Pumped by yielding the main actor, never by blocking it: a
        // `CFRunLoopRunInMode` spin from a `@MainActor` test holds the
        // executor, so the interpreted `.task` this test is waiting for runs
        // only AFTER the pixels are read — which reads exactly like a view
        // that never re-rendered.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var ink = 0
        repeat {
            try? await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(
                in: hosting.bounds)
            else {
                Issue.record("no bitmap representation")
                return -1
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            ink = 0
            for x in 0..<Int(Self.size.width) {
                for y in 0..<Int(Self.size.height) {
                    if let color = rep.colorAt(x: x, y: y),
                       color.brightnessComponent < 0.5 {
                        ink += 1
                    }
                }
            }
        } while !settled(ink) && ContinuousClock.now < deadline
        return ink
    }
}
