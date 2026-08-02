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
    /// One `.navigationDestination(for: T.self) { value in … }` a descendant
    /// registered while its enclosing `NavigationStack` built its content.
    struct PendingDestination {
        let typeName: String?
        let builder: ClosureValue
    }

    /// Destination builders are declared on a DESCENDANT of the stack, but
    /// only the stack knows the path, and the descendant is evaluated first.
    /// A scope stack hands each `NavigationStack` exactly the destinations
    /// its own content registered — nested stacks stay independent.
    @MainActor private static var destinationScopes: [[PendingDestination]] = []

    @MainActor
    static func collectingDestinations<T>(
        _ body: () throws -> T
    ) rethrows -> (T, [PendingDestination]) {
        destinationScopes.append([])
        do {
            let value = try body()
            return (value, destinationScopes.removeLast())
        } catch {
            destinationScopes.removeLast()
            throw error
        }
    }

    @MainActor
    static func recordDestination(typeName: String?, builder: ClosureValue) {
        guard !destinationScopes.isEmpty else { return }
        destinationScopes[destinationScopes.count - 1].append(
            PendingDestination(typeName: typeName, builder: builder))
    }

    /// The name of the type a value would dispatch on in a real
    /// `navigationDestination(for:)` — how SwiftUI picks among several
    /// registered destinations for one path.
    static func dispatchTypeName(of value: RuntimeValue) -> String? {
        switch value {
        case .enumCase(let enumCase): enumCase.symbol.name
        case .instance(let instance): instance.symbol.name
        case .string: "String"
        case .int: "Int"
        case .double: "Double"
        case .bool: "Bool"
        case .type(let symbol): symbol.name
        case .enumType(let symbol): symbol.name
        case .host(let any): String(describing: Swift.type(of: any))
        default: nil
        }
    }

    /// SwiftUI shows the TOP of the navigation stack, not its root: a
    /// `NavigationStack(path:)` whose path holds one element renders that
    /// element's destination over the root. The interpreter cannot satisfy
    /// `navigationDestination`'s static `Hashable` element generic (the same
    /// constraint the NavigationLink identity design documents), so the
    /// stack resolves the pushed element against the destinations its
    /// content registered and renders the builder's view itself.
    ///
    /// Nil means "nothing is pushed" — an empty path, a path that is not an
    /// array, or a top element no registered destination claims — and the
    /// caller keeps its existing root-only behavior unchanged.
    @MainActor
    static func pushedDestination(
        path: RuntimeValue?, destinations: [PendingDestination],
        context: EvalContext
    ) -> [RuntimeValue]? {
        guard case .host(let any) = path, let stub = any as? BindingStub,
              let elements = stub.box.value.arrayValue,
              let top = elements.last, !destinations.isEmpty
        else { return nil }
        let typeName = dispatchTypeName(of: top)
        let match = destinations.first { $0.typeName == typeName }
            ?? destinations.first { $0.typeName == nil }
        guard let match else { return nil }
        return try? context.callBuilderClosure(
            match.builder, arguments: [top])
    }

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
    static func contain(
        _ content: AnyView, context: EvalContext
    ) -> AnyView {
#if os(macOS)
        guard context.buildConfiguration.platformName == "iOS" else {
            return content
        }
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
