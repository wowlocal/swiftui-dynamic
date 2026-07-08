import SwiftUI
import SwiftInterpreter

/// The real SwiftUI `HostRegistry`: hand-written gateway tables mapping
/// constructor and modifier names to the actual framework calls. Structured as
/// dictionaries so a codegen step could replace the entries later.
public final class ViewRegistry: HostRegistry {
    var constructors: [String: HostFunction] = [:]
    var modifiers: [String: HostModifier] = [:]

    public init() {
        registerViews()
        registerModifiers()
    }

    public func constructor(named name: String) -> HostFunction? {
        constructors[name]
    }

    public func modifier(named name: String) -> HostModifier? {
        modifiers[name]
    }

    public func isViewValue(_ value: RuntimeValue) -> Bool {
        if case .native(let any) = value { return any is AnyView }
        return false
    }

    public func makeRenderable(instance: Instance, interpreter: Interpreter) -> RuntimeValue {
        .native(AnyView(InterpretedView(instance: instance, interpreter: interpreter)))
    }

    public func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue {
        let anyViews = try views.map(Self.anyView)
        return .native(AnyView(VStack { Self.indexed(anyViews) }))
    }

    // MARK: - Helpers shared by gateways

    static func anyView(_ value: RuntimeValue) throws -> AnyView {
        if case .native(let any) = value, let view = any as? AnyView { return view }
        throw RuntimeError(message: "expected a View, got \(value.stringified)")
    }

    /// Positional identity is fine here: interpreted bodies are re-evaluated
    /// wholesale on every change anyway.
    static func indexed(_ views: [AnyView]) -> some View {
        ForEach(views.indices, id: \.self) { views[$0] }
    }

    static func builderContent(_ args: CallArguments, _ ctx: EvalContext) throws -> [AnyView] {
        guard let closure = args.closure(labeled: "content") ?? args.unlabeledClosures.last else {
            throw RuntimeError(message: "missing content closure")
        }
        return try ctx.callBuilderClosure(closure, arguments: []).map(Self.anyView)
    }
}
