import SwiftUI

private struct RepeatedRowFramesKey: PreferenceKey {
    nonisolated static let defaultValue: [Int: CGRect] = [:]

    nonisolated static func reduce(
        value: inout [Int: CGRect],
        nextValue: () -> [Int: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct RepeatedRows: View {
    let rootFrame: CGRect

    var body: some View {
        ForEach(0..<2) { index in
            VStack(alignment: .leading, spacing: 8) {
                Color.red.frame(width: 16, height: 16)
                Color.red.frame(width: 16, height: 16)
            }
            .padding(.init(
                top: 12, leading: 0, bottom: 6, trailing: 0))
            .background {
                GeometryReader { rowProxy in
                    let rowFrame = rowProxy.frame(in: .global)
                    Color.clear.preference(
                        key: RepeatedRowFramesKey.self,
                        value: [
                            index: rowFrame.offsetBy(
                                dx: -rootFrame.minX,
                                dy: -rootFrame.minY),
                        ])
                }
            }
            .listRowInsets(.init(
                top: 0, leading: 20, bottom: 0, trailing: 20))
        }
    }
}

/// Compiled-target oracle for vertical geometry propagated through a custom
/// collection body. It uses only structural view properties shared by the
/// IceCubes rows: repeated children, explicit content padding, and zero
/// collection-row insets.
@MainActor
struct RepeatedRowGeometryProbe: View {
    var body: some View {
        GeometryReader { rootProxy in
            List {
                RepeatedRows(
                    rootFrame: rootProxy.frame(in: .global))
            }
            .listStyle(.plain)
            .environment(\.colorScheme, .light)
        }
        .onPreferenceChange(RepeatedRowFramesKey.self) { frames in
            for index in frames.keys.sorted() {
                guard let frame = frames[index] else { continue }
                print(
                    "repeated-row-frame"
                        + "\tindex=\(index)"
                        + "\tx=\(frame.minX)"
                        + "\ty=\(frame.minY)"
                        + "\twidth=\(frame.width)"
                        + "\theight=\(frame.height)")
            }
        }
    }
}
