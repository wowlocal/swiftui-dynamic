import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// Programmatic, path-driven navigation — the half of value-based navigation a
/// `NavigationLink` tag never reaches. IceCubes navigates ONLY this way:
/// StatusRowView.swift:191 taps into StatusRowViewModel.navigateToDetail(),
/// which appends a `RouterDestination` to `RouterPath.path`, and every tab
/// hosts `NavigationStack(path: $routerPath.path) { content().withAppRouter() }`
/// (NavigationTab.swift:25). Without the pushed element rendering its
/// destination, no tap in the app can reach a detail screen.
@Suite(.serialized)
struct PathDrivenNavigationTests {
    /// The compiled expectation: a stack whose path holds one element shows
    /// that element's DESTINATION, and the root is no longer visible.
    private struct NativePushedDestination: View {
        @State private var path: [String] = ["alpha"]
        var body: some View {
            NavigationStack(path: $path) {
                Text("root-content")
                    .navigationDestination(for: String.self) { value in
                        Text("detail-" + value)
                    }
            }
        }
    }

    private struct NativeRootOnly: View {
        var body: some View { Text("root-content") }
    }

    private struct NativeDestinationOnly: View {
        var body: some View { Text("detail-alpha") }
    }

    /// The assumption every test below rests on, pinned against the real
    /// compiler rather than assumed: in THIS harness a compiled
    /// `NavigationStack(path:)` holding one element paints the destination
    /// and not the root. If SwiftUI ever stopped doing that here, the
    /// interpreter's matching behavior would be wrong and this fails first.
    @Test @MainActor func compiledStackPaintsTheDestinationNotTheRoot() throws {
        let size = NSSize(width: 360, height: 140)
        let pushed = ObservableBindingProbe.bitmap(
            AnyView(NativePushedDestination()), size: size)
        let rootOnly = ObservableBindingProbe.bitmap(
            AnyView(NativeRootOnly()), size: size)
        let destinationOnly = ObservableBindingProbe.bitmap(
            AnyView(NativeDestinationOnly()), size: size)

        func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
            var count = 0
            for x in 0..<Int(size.width) {
                for y in 0..<Int(size.height)
                where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                    count += 1
                }
            }
            return count
        }
        #expect(differing(pushed, destinationOnly) == 0,
                "compiled stack must paint the pushed destination")
        #expect(differing(pushed, rootOnly) > 0,
                "compiled stack must not paint the covered root")
    }

    private static let pushedSource = """
    struct ContentView: View {
        @State private var path: [String] = ["alpha"]

        var body: some View {
            NavigationStack(path: $path) {
                Text("root-content")
                    .navigationDestination(for: String.self) { value in
                        Text("detail-" + value)
                    }
            }
        }
    }
    """

    @Test func pushedPathElementRendersItsDestination() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.pushedSource)
        #expect(strings.contains("detail-alpha"),
                Comment(rawValue:
                    "a non-empty NavigationStack path must render the pushed "
                        + "element's destination; got \(strings)"))
        #expect(!strings.contains("root-content"),
                Comment(rawValue:
                    "the pushed destination covers the stack root, as the "
                        + "compiled stack does; got \(strings)"))
    }

    /// The pixel pin for the same semantics: what the compiled stack actually
    /// paints when its path is non-empty is the expectation, never a
    /// hand-written guess.
    @Test @MainActor func pushedDestinationMatchesCompiledStackPixels() throws {
        try TupleViewSpliceProbe.compare(
            source: Self.pushedSource,
            native: AnyView(NativePushedDestination()),
            label: "path-driven-pushed-destination")
    }

    /// A tap is how the app gets there: appending to the path from an action
    /// closure must land on the destination on the next render.
    private static let tapPushesSource = """
    struct ContentView: View {
        @State private var path: [String] = []

        var body: some View {
            NavigationStack(path: $path) {
                VStack {
                    Text("row-alpha")
                        .onTapGesture { path.append("alpha") }
                }
                .navigationDestination(for: String.self) { value in
                    Text("detail-" + value)
                }
            }
        }
    }
    """

    @Test func tapAppendingToThePathPushesItsDestination() async throws {
        let before = try await LiveCheckSupport.renderedStrings(
            source: Self.tapPushesSource)
        #expect(before.contains("row-alpha"))
        #expect(!before.contains("detail-alpha"))

        let after = try await LiveCheckSupport.renderedStrings(
            source: Self.tapPushesSource, afterActions: 1)
        #expect(after.contains("detail-alpha"),
                Comment(rawValue:
                    "tapping a row that appends to the NavigationStack path "
                        + "must push its detail; got \(after)"))
    }

    /// Several destinations on one path dispatch on the element's TYPE, the
    /// property real SwiftUI keys on — not on declaration order.
    private static let typedDestinationsSource = """
    enum Route {
        case detail(String)
    }

    struct ContentView: View {
        @State private var path: [Route] = [.detail("alpha")]

        var body: some View {
            NavigationStack(path: $path) {
                Text("root-content")
                    .navigationDestination(for: String.self) { value in
                        Text("string-" + value)
                    }
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .detail(let name):
                            Text("route-" + name)
                        }
                    }
            }
        }
    }
    """

    @Test func destinationDispatchesOnThePathElementType() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.typedDestinationsSource)
        #expect(strings.contains("route-alpha"),
                Comment(rawValue:
                    "a Route path element must reach the Route destination, "
                        + "not the String one; got \(strings)"))
        #expect(!strings.contains("string-alpha"))
    }

    /// An empty path keeps the existing root-only behavior exactly — the
    /// change is additive.
    @Test func emptyPathStillRendersTheStackRoot() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.tapPushesSource)
        #expect(strings.contains("row-alpha"))
    }
}
