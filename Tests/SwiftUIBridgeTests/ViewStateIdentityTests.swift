import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// Compiled SwiftUI keeps per-identity @State alive across re-renders —
/// the probe's multi-pass render must see pass-N writes in pass N+1
/// (the icecubes genre: .onAppear assigns the view model's client, the
/// NEXT pass fetches with it).
@Suite struct ViewStateIdentityTests {
    @Test func onAppearWriteSurvivesRerender() throws {
        let source = """
        class FeedModel {
            var status = "empty"
        }
        struct FeedView: View {
            @State var model = FeedModel()
            var body: some View {
                Text(model.status)
                    .onAppear { model.status = "loaded" }
            }
        }
        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup { FeedView() }
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains { $0.contains("loaded") },
                "re-render lost the onAppear write: \(strings)")
    }

    @Test func stateBoxReusedAcrossInstantiations() throws {
        let source = """
        class Counter {
            var value = 0
        }
        struct CounterView: View {
            @State var counter = Counter()
            var body: some View {
                Text("count \\(counter.value)")
                    .onAppear { counter.value += 1 }
            }
        }
        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup { CounterView() }
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        // Passes fire onAppear once per NEW closure only; the count must
        // exceed zero in the final tree (identity held), never reset.
        #expect(strings.contains { $0.contains("count") && !$0.contains("count 0") },
                "state reset across renders: \(strings)")
    }
}
