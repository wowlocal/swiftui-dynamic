import SwiftUI
import SwiftInterpreter

/// SwiftUI interfaces describe collection constructors and row-inset
/// modifiers, but not the platform-owned baseline outside those row insets.
/// A macOS host adds a horizontal scroll-content margin that compiled Catalyst
/// lists do not. Apply the selected target's baseline at the
/// collection boundary so every row keeps its interface-declared inset.
///
/// This is the first instance of the target-platform scroll-collection
/// baseline pattern. It is a narrowly documented SwiftUI-magic primitive:
/// dispatch is on immutable target identity, not on an app, source type,
/// modifier spelling, row value, or literal from interpreted source.
enum TargetPlatformCollectionBridge {
    @MainActor
    static func apply(
        to collection: AnyView, context: EvalContext
    ) -> AnyView {
#if os(macOS)
        guard context.buildConfiguration.targetEnvironment == "macCatalyst"
        else {
            return collection
        }
        // Native `ListRowGeometryProbe`: Catalyst x=20; macOS host x=28.
        let macOSScrollCollectionHorizontalBaseline: CGFloat = 8
        return AnyView(collection.padding(
            .horizontal, -macOSScrollCollectionHorizontalBaseline))
#else
        return collection
#endif
    }
}
