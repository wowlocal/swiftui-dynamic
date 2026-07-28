import SwiftUI
import SwiftInterpreter

/// SwiftUI interfaces expose a scroll container's axes and indicator
/// selection, but not the target framework's intrinsic cross-axis extent. A
/// macOS host contributes one extra bottom point to a content-sized horizontal
/// scroll container with hidden indicators; compiled Catalyst does not.
///
/// This target-scroll primitive dispatches on those interface-declared
/// properties and immutable target selection, never on child, app, source
/// type, fixture, or literal identity.
enum TargetPlatformScrollBridge {
    @MainActor
    static func applyGenerated(
        to view: AnyView,
        axes: Axis.Set,
        showsIndicators: Bool,
        builderValue: Any
    ) -> AnyView {
        guard let builder = builderValue as? BuilderValue else {
            return view
        }
        return apply(
            to: view,
            axes: axes,
            showsIndicators: showsIndicators,
            context: builder.context)
    }

    @MainActor
    private static func apply(
        to view: AnyView,
        axes: Axis.Set,
        showsIndicators: Bool,
        context: EvalContext
    ) -> AnyView {
#if os(macOS)
        if context.buildConfiguration.targetEnvironment == "macCatalyst",
           axes == .horizontal,
           !showsIndicators {
            return AnyView(view.padding(.bottom, -1))
        }
#endif
        return view
    }
}
