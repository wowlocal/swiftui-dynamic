import SwiftUI
import SwiftInterpreter

/// SwiftUI's interface identifies `BorderedButtonStyle` and `ControlSize`, but
/// does not encode the target framework's chrome padding, corner treatment, or
/// tint rendering. A macOS host otherwise supplies macOS control semantics to
/// source that selected Catalyst.
///
/// This is the single target-control-style boundary. Its layout dispatches on
/// the closed `ControlSize` property supplied through SwiftUI's environment,
/// never on a source view, app, label, fixture, or call site.
enum TargetPlatformControlBridge {
    @MainActor
    static func applyBorderedButtonStyle(
        to view: AnyView,
        context: EvalContext
    ) -> AnyView {
#if os(macOS)
        if context.buildConfiguration.targetEnvironment == "macCatalyst" {
            return AnyView(view.buttonStyle(CatalystBorderedButtonStyle()))
        }
#endif
        return AnyView(view.buttonStyle(.bordered))
    }
}

private struct CatalystBorderedButtonStyle: ButtonStyle {
    @SwiftUI.Environment(\.controlSize) private var controlSize

    private var chrome: (
        horizontal: CGFloat,
        vertical: CGFloat,
        cornerRadius: CGFloat
    ) {
        if controlSize == .regular {
            return (horizontal: 12, vertical: 7, cornerRadius: 8)
        }
        if controlSize == .large || controlSize == .extraLarge {
            return (horizontal: 20, vertical: 15, cornerRadius: 12)
        }
        // Compiled Catalyst gives `.mini` and `.small` the same intrinsic
        // bordered-control chrome.
        return (horizontal: 10, vertical: 5, cornerRadius: 7)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, chrome.horizontal)
            .padding(.vertical, chrome.vertical)
            .foregroundStyle(.tint)
            .background {
                RoundedRectangle(
                    cornerRadius: chrome.cornerRadius,
                    style: .continuous
                )
                .fill(.tint)
                .opacity(configuration.isPressed ? 0.18 : 0.10)
            }
    }
}
