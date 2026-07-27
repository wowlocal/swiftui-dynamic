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
    static func applyTint(
        _ color: Color,
        to view: AnyView,
        context: EvalContext
    ) -> AnyView {
#if os(macOS)
        if context.buildConfiguration.targetEnvironment == "macCatalyst" {
            return AnyView(
                view
                    .tint(color)
                    .environment(\.targetPlatformExplicitTint, color))
        }
#endif
        return AnyView(view.tint(color))
    }

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

/// SwiftUI's public interface exposes the tint modifier but does not expose
/// whether a downstream style is seeing the default accent or an explicitly
/// supplied tint. Preserve that missing semantic property in the environment
/// so any target-owned style adapter can make the same distinction.
private struct TargetPlatformExplicitTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

private extension EnvironmentValues {
    var targetPlatformExplicitTint: Color? {
        get { self[TargetPlatformExplicitTintKey.self] }
        set { self[TargetPlatformExplicitTintKey.self] = newValue }
    }
}

private struct CatalystBorderedButtonStyle: ButtonStyle {
    @SwiftUI.Environment(\.controlSize) private var controlSize
    @SwiftUI.Environment(\.targetPlatformExplicitTint)
    private var explicitTint

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

    private func surfaceColor(isPressed: Bool) -> Color {
        if let explicitTint {
            return explicitTint.opacity(isPressed ? 0.26 : 0.18)
        }
        // Compiled Catalyst's untinted bordered control uses its neutral
        // system-fill surface; the ambient accent remains label-only.
        return Color(
            red: 233.0 / 255.0,
            green: 233.0 / 255.0,
            blue: 235.0 / 255.0)
            .opacity(isPressed ? 0.82 : 1)
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
                .fill(surfaceColor(isPressed: configuration.isPressed))
            }
    }
}
