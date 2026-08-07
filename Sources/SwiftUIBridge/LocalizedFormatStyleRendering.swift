import Foundation
import SwiftInterpreter
import SwiftUI

/// Applies an SDK format style carried by a localization-key interpolation:
/// `Text("account.label.followers \(n, format: .number.notation(.compactName))")`,
/// the shape IceCubes' `AccountsListRow` writes.
///
/// The segment arrives from `LiteralEvaluator` with its style UNRESOLVED,
/// because the style is an SDK generic only the generated coercions can build.
/// Which style type a leading-dot chain denotes is decided by the INTERPOLATED
/// VALUE: the SDK spells the interpolation as
/// `appendInterpolation<F: FormatStyle>(_ value: F.FormatInput, format: F)`, so
/// the governing constraint is `F.FormatInput == the value's type`.
///
/// That correspondence is therefore NOT restated as a table here. The candidate
/// style types are read out of the generated `format:` parameters — the same
/// interface facts that make `Text(n, format: .number)` work as a call — and
/// `FormatInput` selects among them exactly as the constraint solver would, so
/// a style family added to the interface is picked up without edits here.
enum LocalizedFormatStyleRendering {
    /// Every contextual type the interface declares for a `format:` parameter,
    /// sorted so candidate order cannot vary between runs.
    ///
    /// Both generated tables are scanned, not just the constructors that
    /// happen to declare all of them today. A candidate that is not a
    /// `FormatStyle` rules itself out below, so widening the scan can only
    /// admit styles the interface actually spells.
    static let candidateStyleTypes: [String] = {
        var types = Set<String>()
        func collect(_ overloads: [[ParamSpec]]) {
            for params in overloads {
                for param in params where param.label == "format" {
                    if let type = param.contextualType { types.insert(type) }
                }
            }
        }
        for set in GeneratedConstructors.table.values {
            collect(set.byArity.values.joined().map(\.params))
        }
        for set in GeneratedModifiers.table.values {
            collect(set.byArity.values.joined().map(\.params))
        }
        return types.sorted()
    }()

    /// The value rendered through its style, or nil when no declared style type
    /// both builds from this chain and accepts this value.
    @MainActor
    static func text(
        _ value: RuntimeValue, style: RuntimeValue, _ ctx: EvalContext
    ) -> String? {
        guard let input = value.hostPayload else { return nil }
        for candidate in candidateStyleTypes {
            guard let resolved = try? GeneratedDispatch.coerce(
                .sdkEnum(candidate), style, ctx, contextualType: candidate),
                  let formatStyle = resolved as? any FormatStyle,
                  let text = apply(formatStyle, to: input) else { continue }
            return text
        }
        return nil
    }

    /// Opens the existential so `format(_:)` can be called at all: `FormatInput`
    /// appears in parameter position, which is exactly the position that makes
    /// a protocol requirement unavailable on `any FormatStyle`. A candidate
    /// whose `FormatInput` does not accept the value rules ITSELF out here,
    /// which is what keeps the selection above free of a spelled-type table.
    @MainActor
    private static func apply<F: FormatStyle>(
        _ style: F, to input: Any
    ) -> String? {
        guard let typed = input as? F.FormatInput else { return nil }
        return style.format(typed) as? String
    }
}
