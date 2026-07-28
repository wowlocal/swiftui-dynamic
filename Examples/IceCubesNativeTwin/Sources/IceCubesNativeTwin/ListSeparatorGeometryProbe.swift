import SwiftUI

private struct ListSeparatorFramesKey: PreferenceKey {
    nonisolated static let defaultValue: [Int: CGRect] = [:]

    nonisolated static func reduce(
        value: inout [Int: CGRect],
        nextValue: () -> [Int: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct ListSeparatorFrameReader: View {
    let index: Int
    let rootFrame: CGRect

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear.preference(
                key: ListSeparatorFramesKey.self,
                value: [
                    index: frame.offsetBy(
                        dx: -rootFrame.minX,
                        dy: -rootFrame.minY),
                ])
        }
    }
}

/// Distilled native oracle for target-platform plain-list separators.
/// The row trailing inset deliberately varies while every row supplies the
/// same separator-leading guide. Compiled Catalyst keeps the separator's
/// trailing edge at x=879 in the 900-point harness for every variant, proving
/// that its 20-point trailing baseline is platform-owned rather than copied
/// from the row inset. Root-relative row frames expose the geometric phase
/// Catalyst uses to rasterize otherwise-identical horizontal boundaries.
@MainActor
struct ListSeparatorGeometryProbe: View {
    private let trailingInsets: [CGFloat] = [0, 8, 20, 40, 20]

    var body: some View {
        GeometryReader { rootProxy in
            let rootFrame = rootProxy.frame(in: .global)
            List {
                ForEach(trailingInsets.indices, id: \.self) { index in
                    let trailingInset = trailingInsets[index]
                    HStack {
                        Color.red
                            .frame(width: 16, height: 16)
                        Text(index == trailingInsets.indices.last
                            ? "SENTINEL"
                            : "TRAILING \(Int(trailingInset))")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background {
                        ListSeparatorFrameReader(
                            index: index, rootFrame: rootFrame)
                    }
                    .listRowInsets(.init(
                        top: 0,
                        leading: 20,
                        bottom: 0,
                        trailing: trailingInset))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in
                        -100
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.colorScheme, .light)
            .background(Color.white)
            .onPreferenceChange(ListSeparatorFramesKey.self) { frames in
                for index in frames.keys.sorted() {
                    guard let frame = frames[index] else { continue }
                    print(
                        "list-separator-row-frame"
                            + "\tindex=\(index)"
                            + "\tx=\(frame.minX)"
                            + "\ty=\(frame.minY)"
                            + "\twidth=\(frame.width)"
                            + "\theight=\(frame.height)")
                }
            }
        }
    }
}
