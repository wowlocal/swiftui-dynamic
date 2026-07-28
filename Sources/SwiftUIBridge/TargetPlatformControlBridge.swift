import SwiftUI
import SwiftInterpreter

/// Runtime half of BridgeGen's small SwiftUI-magic allowlist. Generated
/// overload metadata selects an adapter from an interface-derived concrete
/// protocol value; execution then checks that property rather than a modifier
/// name or source spelling.
enum GeneratedModifierSemanticAdapter {
    case targetButtonMenuStyle(parameter: Int)
    case targetExplicitTint(parameter: Int)

    @MainActor
    func apply(
        to native: AnyView,
        receiver: AnyView,
        values: [Any],
        context: EvalContext
    ) -> AnyView {
        switch self {
        case .targetButtonMenuStyle(let parameter):
            guard values.indices.contains(parameter),
                  values[parameter] is ButtonMenuStyle else {
                return native
            }
            return TargetPlatformControlBridge.adaptButtonMenuStyle(
                native, context: context)
        case .targetExplicitTint(let parameter):
            guard values.indices.contains(parameter) else { return native }
            let style: AnyShapeStyle
            if let erased = values[parameter] as? AnyShapeStyle {
                style = erased
            } else if let color = values[parameter] as? Color {
                style = AnyShapeStyle(color)
            } else if let concrete = values[parameter] as? any ShapeStyle {
                style = Self.eraseShapeStyle(concrete)
            } else {
                return native
            }
            return TargetPlatformControlBridge.adaptExplicitTint(
                style, to: native, context: context)
        }
    }

    private static func eraseShapeStyle<S: ShapeStyle>(
        _ style: S
    ) -> AnyShapeStyle {
        AnyShapeStyle(style)
    }
}

/// SwiftUI's interface identifies control/menu styles and `ControlSize`, but
/// does not encode the target framework's chrome padding, corner treatment,
/// tint rendering, or default menu-indicator visibility. A macOS host otherwise
/// supplies macOS control semantics to source that selected Catalyst.
///
/// This is the single target-control-style boundary. Its layout dispatches on
/// the closed `ControlSize` property supplied through SwiftUI's environment,
/// never on a source view, app, label, fixture, or call site.
enum TargetPlatformControlBridge {
    @MainActor
    static func adaptExplicitTint(
        _ style: AnyShapeStyle,
        to native: AnyView,
        context: EvalContext
    ) -> AnyView {
#if os(macOS)
        if context.buildConfiguration.targetEnvironment == "macCatalyst" {
            return AnyView(
                native.environment(\.targetPlatformExplicitTint, style))
        }
#endif
        return native
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

    @MainActor
    static func adaptButtonMenuStyle(
        _ styled: AnyView,
        context: EvalContext
    ) -> AnyView {
#if os(macOS)
        // Compiled Catalyst's button-style menu presents only the supplied
        // label; macOS adds a disclosure indicator by default. This is the
        // third facet of the existing target-control-style primitive, selected
        // by the style property and immutable target rather than a source/API
        // call site, label, app, or fixture identity.
        if context.buildConfiguration.targetEnvironment == "macCatalyst" {
            return AnyView(styled.menuIndicator(.hidden))
        }
#endif
        return styled
    }
}

/// SwiftUI's public interface exposes the tint modifier but does not expose
/// whether a downstream style is seeing the default accent or an explicitly
/// supplied tint. Preserve that missing semantic property in the environment
/// so any target-owned style adapter can make the same distinction.
private struct TargetPlatformExplicitTintKey: EnvironmentKey {
    static let defaultValue: AnyShapeStyle? = nil
}

private extension EnvironmentValues {
    var targetPlatformExplicitTint: AnyShapeStyle? {
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

    private func surfaceStyle(isPressed: Bool) -> AnyShapeStyle {
        if let explicitTint {
            return AnyShapeStyle(
                explicitTint.opacity(isPressed ? 0.26 : 0.18))
        }
        // Compiled Catalyst's untinted bordered control uses its neutral
        // system-fill surface; the ambient accent remains label-only.
        return AnyShapeStyle(
            Color(
                red: 233.0 / 255.0,
                green: 233.0 / 255.0,
                blue: 235.0 / 255.0)
                .opacity(isPressed ? 0.82 : 1))
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
                .fill(surfaceStyle(isPressed: configuration.isPressed))
            }
    }
}
