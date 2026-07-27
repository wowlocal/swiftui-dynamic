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

private struct SmallBorderedControl: View {
    let name: String
    let rootFrame: CGRect
    let tint: Color?

    var body: some View {
        let button = Button {} label: {
            Text("Control")
                .font(.footnote)
                .fontWeight(.medium)
                .lineLimit(1)
                .background {
                    frameReader(named: "\(name)-label")
                }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .background {
            frameReader(named: "\(name)-button")
        }

        if let tint {
            button.tint(tint)
        } else {
            button
        }
    }

    private func frameReader(named name: String) -> some View {
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

/// Compiled-target oracle for the platform-owned chrome supplied by
/// `BorderedButtonStyle` at a selected control size. The interface describes
/// both modifiers, but not the target framework's intrinsic padding, corner
/// radius, tint treatment, or resulting control extent.
@MainActor
struct SmallBorderedControlProbe: View {
    var body: some View {
        GeometryReader { rootProxy in
            VStack(alignment: .leading, spacing: 16) {
                SmallBorderedControl(
                    name: "default",
                    rootFrame: rootProxy.frame(in: .global),
                    tint: nil)
                SmallBorderedControl(
                    name: "red",
                    rootFrame: rootProxy.frame(in: .global),
                    tint: .red)
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
