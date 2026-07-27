import SwiftUI

/// Distilled native oracle for target-platform plain-list row geometry.
/// The view is independent of IceCubes packages and fixture data so a macOS
/// interpreter targeting Catalyst can be compared with compiled Catalyst
/// semantics without the full timeline obscuring the row baseline.
@MainActor
struct ListRowGeometryProbe: View {
    var body: some View {
        List {
            HStack {
                Color.red
                    .frame(width: 16, height: 16)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .listRowInsets(.init(
                top: 0, leading: 20, bottom: 0, trailing: 20))
        }
        .listStyle(.plain)
        .environment(\.colorScheme, .light)
    }
}
