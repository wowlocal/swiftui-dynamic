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
        registerGeometryViews()
    }

    public func constructor(named name: String) -> HostFunction? {
        let hand = constructors[name]
        let generated = GeneratedConstructors.table[name]
        if hand == nil && generated == nil { return nil }
        // Hand-written first; if it rejects this call shape and a generated
        // table exists, fall through — so e.g. Text(verbatim:) can come from
        // codegen while Text("x") stays hand-written.
        return HostFunction(name: name) { args, ctx in
            if let hand {
                do {
                    return try hand.invoke(args, ctx)
                } catch where generated != nil {
                    // fall through to generated overloads
                }
            }
            guard let generated else {
                throw RuntimeError(message: "no constructor for \(name)")
            }
            return .native(try GeneratedDispatch.construct(name: name, overloads: generated, args: args, ctx: ctx))
        }
    }

    public func modifier(named name: String) -> HostModifier? {
        if let handWritten = modifiers[name] { return handWritten }
        guard let overloads = GeneratedModifiers.table[name] else { return nil }
        return HostModifier(name: name) { value, args, ctx in
            let view = try Self.anyView(value)
            return .native(try GeneratedDispatch.dispatch(
                name: name, overloads: overloads, view: view, args: args, ctx: ctx
            ))
        }
    }

    public func isViewValue(_ value: RuntimeValue) -> Bool {
        if case .native(let any) = value {
            return any is AnyView || any is ImageBox || any is ShapeBox || any is LinearGradient
        }
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
        if case .native(let any) = value {
            if let view = any as? AnyView { return view }
            if let box = any as? ImageBox { return AnyView(box.image) }
            if let box = any as? ShapeBox { return AnyView(box.shape) }
            if let gradient = any as? LinearGradient { return AnyView(gradient) }
        }
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

    /// Like `anyView`, but also accepts a bare interpreted-View instance in
    /// argument position (e.g. `NavigationLink(destination: DetailView())`).
    func anyViewResolving(_ value: RuntimeValue, _ ctx: EvalContext) throws -> AnyView {
        if case .instance(let instance) = value, instance.symbol.conformsToView,
           let interpreter = ctx as? Interpreter {
            return try Self.anyView(makeRenderable(instance: instance, interpreter: interpreter))
        }
        return try Self.anyView(value)
    }
}
