import Darwin
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

    public func hostSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool {
        if networkHostSetMember(name, on: value, to: newValue) { return true }
        return hostObjectSetMember(name, on: value, to: newValue)
    }

    public func absorbedCValue(named name: String) -> RuntimeValue? {
        .native(UIKitStub()) // writable bag: out-params fill
    }

    public func cFunction(named name: String) -> HostFunction? {
        switch name {
        case "uname":
            // The host hardware is REAL: fill the interpreted struct with
            // actual utsname values and return success.
            return HostFunction(name: name) { args, _ in
                if case .host(let any)? = args.positional(0), let node = any as? TraceNode {
                    var info = utsname()
                    _ = Darwin.uname(&info)
                    func field<T>(_ keyPath: KeyPath<utsname, T>) -> String {
                        var copy = info[keyPath: keyPath]
                        return withUnsafeBytes(of: &copy) { raw in
                            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                        }
                    }
                    node.config["machine"] = .native(field(\.machine))
                    node.config["sysname"] = .native(field(\.sysname))
                    node.config["release"] = .native(field(\.release))
                    node.config["nodename"] = .native(field(\.nodename))
                    node.config["version"] = .native(field(\.version))
                }
                return .native(0) // success, like the real call
            }
        default:
            return nil
        }
    }

    public func storeBlob(_ value: RuntimeValue, at path: String) {
        FileManagerBox.blobStore[path] = value
    }

    public func constructor(named name: String) -> HostFunction? {
        if let hostObject = bridgeHostObjectConstructor(named: name) { return hostObject }
        let hand = constructors[name]
        let generated = GeneratedConstructors.table[name]
        if hand == nil && generated == nil {
            // Unknown TYPE-looking constructors (external SDKs: KeychainSwift,
            // ChatClient) build absorbing bags, the live-render analog of the
            // trace registry's opaque recorder. Lowercase names stay
            // unresolved so genuine errors surface.
            guard name.first?.isUppercase == true else { return nil }
            return HostFunction(name: name) { args, _ in
                let stub = UIKitStub()
                for argument in args.arguments {
                    if let label = argument.label { stub.config[label] = argument.value }
                }
                return .native(stub)
            }
        }
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
        if case .host(let any) = value {
            if any is AnyView || any is ImageBox || any is ShapeBox || any is LinearGradient
                || any is PathDrawStub {
                return true
            }
        }
        return Coerce.colorLike(value) != nil // Color IS a View
    }

    public func makeRenderable(instance: Instance, interpreter: Interpreter) -> RuntimeValue {
        if instance.symbol.isRepresentable {
            // UIKit/AppKit representables embed host views we can't run —
            // the honest stand-in is an inert empty view.
            return .native(AnyView(EmptyView()))
        }
        if instance.symbol.conformsToLayout {
            // Children in a default flow; the interpreted sizeThatFits/
            // placeSubviews never run (documented divergence).
            let children = instance.properties[StructSymbol.layoutChildrenKey]?.value.arrayValue ?? []
            let views = (try? children.map(Self.anyView)) ?? []
            return .native(AnyView(VStack(alignment: .leading) { Self.indexed(views) }))
        }
        if instance.symbol.conformsToShape {
            // Shape-typed so .fill/.stroke/.trim apply; the real path comes
            // from the interpreted path(in:).
            return .native(ShapeBox(InterpretedShape(instance: instance, interpreter: interpreter)))
        }
        return .native(AnyView(InterpretedView(instance: instance, interpreter: interpreter)))
    }

    public func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue {
        let anyViews = try views.map(Self.anyView)
        return .native(AnyView(VStack { Self.indexed(anyViews) }))
    }

    // MARK: - Helpers shared by gateways

    static func anyView(_ value: RuntimeValue) throws -> AnyView {
        if case .host(let any) = value {
            if let view = any as? AnyView { return view }
            if any is UIKitStub || any is ImplicitMemberCall || any is ChainedImplicitCall {
                // Unknown SDK views render empty — the documented inert
                // degrade (Lottie precedent), live-render edition.
                return AnyView(EmptyView())
            }
            if let box = any as? ImageBox { return AnyView(box.image) }
            if let box = any as? ShapeBox { return AnyView(box.shape) }
            if let stub = any as? PathDrawStub { return AnyView(stub.path) }
            if let gradient = any as? LinearGradient { return AnyView(gradient) }
        }
        if let color = Coerce.colorLike(value) { return AnyView(color) }
        throw RuntimeError(message: "expected a View, got \(value.stringified)")
    }

    /// Positional identity is fine here: interpreted bodies are re-evaluated
    /// wholesale on every change anyway.
    static func indexed(_ views: [AnyView]) -> some View {
        ForEach(views.indices, id: \.self) { views[$0] }
    }

    static func builderContent(_ args: CallArguments, _ ctx: EvalContext) throws -> [AnyView] {
        guard let closure = args.closure(labeled: "content") ?? args.lastUnlabeledClosure else {
            throw RuntimeError(message: "missing content closure")
        }
        return try ctx.callBuilderClosure(closure, arguments: []).map(Self.anyView)
    }

    /// Like `anyView`, but also accepts a bare interpreted-View instance in
    /// argument position (e.g. `NavigationLink(destination: DetailView())`).
    func anyViewResolving(_ value: RuntimeValue, _ ctx: EvalContext) throws -> AnyView {
        if case .instance(let instance) = value,
           instance.symbol.conformsToView || instance.symbol.isRepresentable,
           let interpreter = ctx as? Interpreter {
            return try Self.anyView(makeRenderable(instance: instance, interpreter: interpreter))
        }
        return try Self.anyView(value)
    }
}
