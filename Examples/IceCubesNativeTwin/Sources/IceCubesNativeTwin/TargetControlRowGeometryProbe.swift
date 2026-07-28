import SwiftUI

private struct TargetControlRowFramesKey: PreferenceKey {
    nonisolated static let defaultValue: [String: CGRect] = [:]

    nonisolated static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct TargetControlRowFrameReader: View {
    let name: String
    let rootFrame: CGRect

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear.preference(
                key: TargetControlRowFramesKey.self,
                value: [
                    name: frame.offsetBy(
                        dx: -rootFrame.minX,
                        dy: -rootFrame.minY),
                ])
        }
    }
}

private struct GeometryOnlyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct TargetActionButton: View {
    let rootFrame: CGRect
    let index: Int

    var body: some View {
        Button {} label: {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 19))
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .background {
                    TargetControlRowFrameReader(
                        name: "button-label-\(index)",
                        rootFrame: rootFrame)
                }
        }
        .buttonStyle(GeometryOnlyButtonStyle())
        .background {
            TargetControlRowFrameReader(
                name: "button-\(index)",
                rootFrame: rootFrame)
        }
    }
}

private struct TargetActionMenu: View {
    let rootFrame: CGRect
    let index: Int

    var body: some View {
        Menu {
            Button("Action") {}
        } label: {
            Label("", systemImage: "ellipsis")
                .font(.system(size: 19))
                .padding(.vertical, 6)
                .background {
                    TargetControlRowFrameReader(
                        name: "menu-label-\(index)",
                        rootFrame: rootFrame)
                }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .tint(.primary)
        .contentShape(Rectangle())
        .background {
            TargetControlRowFrameReader(
                name: "menu-\(index)",
                rootFrame: rootFrame)
        }
    }
}

private struct TargetControlRows: View {
    let rootFrame: CGRect

    var body: some View {
        ForEach(0..<2) { index in
            VStack(alignment: .leading, spacing: 6) {
                Color.red.frame(width: 40, height: 40)
                HStack {
                    TargetActionButton(
                        rootFrame: rootFrame, index: index)
                    TargetActionButton(
                        rootFrame: rootFrame, index: index + 2)
                    Spacer()
                    TargetActionMenu(
                        rootFrame: rootFrame, index: index)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    TargetControlRowFrameReader(
                        name: "actions-\(index)",
                        rootFrame: rootFrame)
                }
            }
            .padding(.init(
                top: 12, leading: 0, bottom: 6, trailing: 0))
            .background {
                TargetControlRowFrameReader(
                    name: "row-\(index)",
                    rootFrame: rootFrame)
            }
            .listRowInsets(.init(
                top: 0, leading: 20, bottom: 0, trailing: 20))
        }
    }
}

private struct TargetTrailingControl: View {
    let rootFrame: CGRect
    let rowIndex: Int
    let controlIndex: Int

    var body: some View {
        Button {} label: {
            Text("#control-\(controlIndex)")
                .font(.footnote)
                .fontWeight(.medium)
                .lineLimit(1)
                .background {
                    TargetControlRowFrameReader(
                        name: "trailing-label-\(rowIndex)-\(controlIndex)",
                        rootFrame: rootFrame)
                }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .background {
            TargetControlRowFrameReader(
                name: "trailing-control-\(rowIndex)-\(controlIndex)",
                rootFrame: rootFrame)
        }
    }
}

private struct TargetTrailingControlStrip: View {
    let rootFrame: CGRect
    let rowIndex: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<3) { controlIndex in
                    TargetTrailingControl(
                        rootFrame: rootFrame,
                        rowIndex: rowIndex,
                        controlIndex: controlIndex)
                }
            }
            .background {
                TargetControlRowFrameReader(
                    name: "trailing-stack-\(rowIndex)",
                    rootFrame: rootFrame)
            }
        }
        .scrollClipDisabled()
        .background {
            TargetControlRowFrameReader(
                name: "trailing-scroll-\(rowIndex)",
                rootFrame: rootFrame)
        }
    }
}

private struct TargetTrailingControlRows: View {
    let rootFrame: CGRect

    var body: some View {
        ForEach(0..<2) { index in
            VStack(alignment: .leading, spacing: 6) {
                Color.green.frame(width: 40, height: 40)
                TargetTrailingControlStrip(
                    rootFrame: rootFrame,
                    rowIndex: index)
                    .padding(.top, 8)
                    .background {
                        TargetControlRowFrameReader(
                            name: "trailing-section-\(index)",
                            rootFrame: rootFrame)
                    }
            }
            .padding(.init(
                top: 12, leading: 0, bottom: 6, trailing: 0))
            .background {
                TargetControlRowFrameReader(
                    name: "trailing-row-\(index)",
                    rootFrame: rootFrame)
            }
            .listRowInsets(.init(
                top: 0, leading: 20, bottom: 0, trailing: 20))
        }
    }
}

/// Compiled-target oracle for the intrinsic geometry of a mixed control strip
/// propagated through repeated plain-list rows. The structure is intentionally
/// app-independent: explicit font and padding properties, source-defined
/// label-only button style, button-style Menu, small bordered controls inside
/// a horizontal scroll container, fixed vertical extent, and repeated
/// collection composition.
@MainActor
struct TargetControlRowGeometryProbe: View {
    var body: some View {
        GeometryReader { rootProxy in
            List {
                TargetControlRows(
                    rootFrame: rootProxy.frame(in: .global))
                TargetTrailingControlRows(
                    rootFrame: rootProxy.frame(in: .global))
            }
            .listStyle(.plain)
            .environment(\.colorScheme, .light)
        }
        .onPreferenceChange(TargetControlRowFramesKey.self) { frames in
            for name in frames.keys.sorted() {
                guard let frame = frames[name] else { continue }
                print(
                    "target-control-row-frame"
                        + "\tname=\(name)"
                        + "\tx=\(frame.minX)"
                        + "\ty=\(frame.minY)"
                        + "\twidth=\(frame.width)"
                        + "\theight=\(frame.height)")
            }
        }
    }
}
