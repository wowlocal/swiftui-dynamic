import SwiftUI
import SwiftInterpreter

/// SwiftUI's interfaces describe the `navigationTitle` modifier and
/// `NavigationStack` initializer, but not which process-owned surface presents
/// the title. On iOS/Catalyst it is content chrome; on macOS it is window
/// chrome. A macOS interpreter targeting iOS therefore needs one semantic
/// handoff from the modified descendant to its navigation container.
///
/// This is the first instance of the target-platform, container-owned
/// navigation-chrome pattern. The API calls themselves remain generated from
/// swiftinterfaces; this narrowly documented SwiftUI-magic allowlist entry
/// carries only the missing placement relationship.
private struct InterpretedNavigationTitleKey: PreferenceKey {
    nonisolated static let defaultValue: String? = nil

    nonisolated static func reduce(
        value: inout String?, nextValue: () -> String?
    ) {
        value = nextValue() ?? value
    }
}

enum NavigationPresentationBridge {
    @MainActor
    static func applyTitle(
        to view: AnyView, args: CallArguments, context: EvalContext
    ) throws -> AnyView {
        guard let overloads = GeneratedModifiers.table["navigationTitle"] else {
            throw RuntimeError(message: "generated navigationTitle overloads are missing")
        }
        let titled = try GeneratedDispatch.dispatch(
            name: "navigationTitle", overloads: overloads,
            view: view, args: args, ctx: context)
        guard let title = args.positional(0)?.stringValue else {
            return titled
        }
        return AnyView(titled.preference(
            key: InterpretedNavigationTitleKey.self, value: title))
    }

    @MainActor
    static func contain(_ content: AnyView) -> AnyView {
#if os(macOS)
        guard Interpreter.interpretsAsPlatform == "iOS" else { return content }
        return AnyView(IOSNavigationChromeContainer(content: content))
#else
        return content
#endif
    }
}

#if os(macOS)
private struct IOSNavigationChromeContainer: View {
    let content: AnyView
    @State private var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 64)
                    Text(title)
                        .font(.system(size: 34, weight: .bold))
                        .offset(y: -3)
                        .frame(height: 52, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            content
        }
        .onPreferenceChange(InterpretedNavigationTitleKey.self) {
            title = $0
        }
    }
}
#endif
