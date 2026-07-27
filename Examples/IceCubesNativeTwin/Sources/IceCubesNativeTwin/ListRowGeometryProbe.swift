import SwiftUI

private struct ListRowGeometryFrameKey: PreferenceKey {
    nonisolated static let defaultValue: CGRect? = nil

    nonisolated static func reduce(
        value: inout CGRect?, nextValue: () -> CGRect?
    ) {
        value = nextValue() ?? value
    }
}

/// Distilled native oracle for target-platform plain-list row geometry.
/// The view is independent of IceCubes packages and fixture data so a macOS
/// interpreter targeting Catalyst can be compared with compiled Catalyst
/// semantics without the full timeline obscuring the row baseline.
@MainActor
struct ListRowGeometryProbe: View {
    var body: some View {
        GeometryReader { rootProxy in
            List {
                HStack {
                    Color.red
                        .frame(width: 16, height: 16)
                        .background {
                            GeometryReader { rowProxy in
                                let rootFrame = rootProxy.frame(in: .global)
                                let rowFrame = rowProxy.frame(in: .global)
                                Color.clear.preference(
                                    key: ListRowGeometryFrameKey.self,
                                    value: rowFrame.offsetBy(
                                        dx: -rootFrame.minX,
                                        dy: -rootFrame.minY))
                            }
                        }
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .listRowInsets(.init(
                    top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            .listStyle(.plain)
            .environment(\.colorScheme, .light)
        }
        .onPreferenceChange(ListRowGeometryFrameKey.self) { frame in
            guard let frame else { return }
            print(
                "list-row-frame"
                    + "\tx=\(frame.minX)"
                    + "\ty=\(frame.minY)"
                    + "\twidth=\(frame.width)"
                    + "\theight=\(frame.height)")
        }
    }
}
