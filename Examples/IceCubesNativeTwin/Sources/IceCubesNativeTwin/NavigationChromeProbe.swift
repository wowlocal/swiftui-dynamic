import SwiftUI

/// Distilled native oracle for target-platform navigation chrome. The view is
/// deliberately independent of IceCubes packages and fixture data so bridge
/// regressions can be compared with compiled Catalyst semantics in isolation.
@MainActor
struct NavigationChromeProbe: View {
    var body: some View {
        NavigationStack {
            Color.white
                .navigationTitle("Federated")
        }
        .environment(\.colorScheme, .light)
    }
}
