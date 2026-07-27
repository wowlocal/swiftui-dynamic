import SwiftUI
import SwiftInterpreter

/// SwiftUI's interface identifies a semantic `Font` role, but does not encode
/// the role's target-platform point size, weight, or line metrics. A macOS host
/// therefore resolves an interpreted Catalyst `.footnote` as the smaller macOS
/// role even though the source selected the iOS/Catalyst typography table.
///
/// This adapter is the single target-typography boundary for generated Font
/// parameters. It dispatches on the closed semantic-role property carried by
/// the interface-derived value, never on a source type, view, app, or call site.
enum TargetPlatformTypographyBridge {
    private struct SemanticFontDescriptor {
        let pointSize: CGFloat
        let weight: Font.Weight

        var font: Font {
            .system(size: pointSize, weight: weight)
        }
    }

    /// Host point sizes calibrated against the compiled Catalyst oracle's
    /// complete closed role set. The one-point compensation in the smaller
    /// roles accounts for the macOS host font's narrower optical metrics.
    private static let catalystSemanticFonts: [
        String: SemanticFontDescriptor
    ] = [
        "largeTitle": .init(pointSize: 34, weight: .regular),
        "title": .init(pointSize: 28, weight: .regular),
        "title2": .init(pointSize: 22, weight: .regular),
        "title3": .init(pointSize: 20, weight: .regular),
        "headline": .init(pointSize: 18, weight: .semibold),
        "body": .init(pointSize: 18, weight: .regular),
        "callout": .init(pointSize: 17, weight: .regular),
        "subheadline": .init(pointSize: 16, weight: .regular),
        "footnote": .init(pointSize: 14, weight: .regular),
        "caption": .init(pointSize: 13, weight: .regular),
        "caption2": .init(pointSize: 12, weight: .regular),
    ]

    @MainActor
    static func font(
        from value: RuntimeValue,
        context: EvalContext
    ) throws -> Font {
#if os(macOS)
        if context.buildConfiguration.targetEnvironment == "macCatalyst",
           case .implicitMember(let role) = value,
           let descriptor = catalystSemanticFonts[role] {
            return descriptor.font
        }
#endif
        return try Coerce.font(value)
    }
}
