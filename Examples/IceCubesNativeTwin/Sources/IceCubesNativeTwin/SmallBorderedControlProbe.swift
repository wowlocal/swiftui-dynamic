import SwiftUI

private struct SmallBorderedControlFramesKey: PreferenceKey {
    nonisolated static let defaultValue: [String: CGRect] = [:]

    nonisolated static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SmallBorderedControlFrameReader: View {
    let name: String
    let rootFrame: CGRect

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear.preference(
                key: SmallBorderedControlFramesKey.self,
                value: [
                    name: frame.offsetBy(
                        dx: -rootFrame.minX,
                        dy: -rootFrame.minY),
                ])
        }
    }
}

private struct SmallBorderedControl: View {
    let name: String
    let rootFrame: CGRect
    let tint: Color?
    let controlSize: ControlSize

    var body: some View {
        let button = Button {} label: {
            Text("Control")
                .font(.footnote)
                .fontWeight(.medium)
                .lineLimit(1)
                .background {
                    SmallBorderedControlFrameReader(
                        name: "\(name)-label",
                        rootFrame: rootFrame)
                }
        }
        .buttonStyle(.bordered)
        .controlSize(controlSize)
        .background {
            SmallBorderedControlFrameReader(
                name: "\(name)-button",
                rootFrame: rootFrame)
        }

        if let tint {
            button.tint(tint)
        } else {
            button
        }
    }

}

private struct SemanticFontLabel: View {
    let name: String
    let font: Font
    let rootFrame: CGRect

    var body: some View {
        Text("Control")
            .font(font)
            .fontWeight(.medium)
            .lineLimit(1)
            .background {
                SmallBorderedControlFrameReader(
                    name: "semantic-\(name)",
                    rootFrame: rootFrame)
            }
    }
}

/// Compiled-target oracle for the platform-owned chrome supplied by
/// `BorderedButtonStyle` at a selected control size. The interface describes
/// both modifiers, but not the target framework's intrinsic padding, corner
/// radius, tint treatment, or resulting control extent.
@MainActor
struct SmallBorderedControlProbe: View {
    var body: some View {
        GeometryReader { rootProxy in
            VStack(alignment: .leading, spacing: 16) {
                Text("Control")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .background {
                        SmallBorderedControlFrameReader(
                            name: "bare-label",
                            rootFrame: rootProxy.frame(in: .global))
                    }
                SmallBorderedControl(
                    name: "default",
                    rootFrame: rootProxy.frame(in: .global),
                    tint: nil,
                    controlSize: .small)
                SmallBorderedControl(
                    name: "red",
                    rootFrame: rootProxy.frame(in: .global),
                    tint: .red,
                    controlSize: .small)
                SmallBorderedControl(
                    name: "mini",
                    rootFrame: rootProxy.frame(in: .global),
                    tint: nil,
                    controlSize: .mini)
                SmallBorderedControl(
                    name: "regular",
                    rootFrame: rootProxy.frame(in: .global),
                    tint: nil,
                    controlSize: .regular)
                SmallBorderedControl(
                    name: "large",
                    rootFrame: rootProxy.frame(in: .global),
                    tint: nil,
                    controlSize: .large)
                SmallBorderedControl(
                    name: "extra-large",
                    rootFrame: rootProxy.frame(in: .global),
                    tint: nil,
                    controlSize: .extraLarge)
                Group {
                    SemanticFontLabel(
                        name: "largeTitle", font: .largeTitle,
                        rootFrame: rootProxy.frame(in: .global))
                    SemanticFontLabel(
                        name: "title", font: .title,
                        rootFrame: rootProxy.frame(in: .global))
                    SemanticFontLabel(
                        name: "title2", font: .title2,
                        rootFrame: rootProxy.frame(in: .global))
                    SemanticFontLabel(
                        name: "title3", font: .title3,
                        rootFrame: rootProxy.frame(in: .global))
                    SemanticFontLabel(
                        name: "headline", font: .headline,
                        rootFrame: rootProxy.frame(in: .global))
                    SemanticFontLabel(
                        name: "body", font: .body,
                        rootFrame: rootProxy.frame(in: .global))
                    SemanticFontLabel(
                        name: "callout", font: .callout,
                        rootFrame: rootProxy.frame(in: .global))
                    SemanticFontLabel(
                        name: "subheadline", font: .subheadline,
                        rootFrame: rootProxy.frame(in: .global))
                    SemanticFontLabel(
                        name: "footnote", font: .footnote,
                        rootFrame: rootProxy.frame(in: .global))
                    SemanticFontLabel(
                        name: "caption", font: .caption,
                        rootFrame: rootProxy.frame(in: .global))
                    SemanticFontLabel(
                        name: "caption2", font: .caption2,
                        rootFrame: rootProxy.frame(in: .global))
                }
            }
            .padding(20)
            .environment(\.colorScheme, .light)
        }
        .onPreferenceChange(SmallBorderedControlFramesKey.self) { frames in
            for name in frames.keys.sorted() {
                guard let frame = frames[name] else { continue }
                print(
                    "small-bordered-control-frame"
                        + "\tname=\(name)"
                        + "\tx=\(frame.minX)"
                        + "\ty=\(frame.minY)"
                        + "\twidth=\(frame.width)"
                        + "\theight=\(frame.height)")
            }
        }
    }
}
