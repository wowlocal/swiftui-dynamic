import SwiftUI
import Charts
import SwiftInterpreter

/// The real SwiftUI `HostRegistry`: hand-written gateway tables mapping
/// constructor and modifier names to the actual framework calls. Structured as
/// dictionaries so a codegen step could replace the entries later.
public final class ViewRegistry: HostRegistry {
    var constructors: [String: HostFunction] = [:]
    var modifiers: [String: HostModifier] = [:]
    let mainQueueDeliveryMode: MainQueueDeliveryMode
    private let generatedPlatformFallbacks = GeneratedPlatformFallbackRuntime()

    public var compilerPreflightHostModule: CompilerPreflightHostModule? {
        GeneratedCompilerPreflightSurface.module
    }

    public convenience init() {
        self.init(mainQueueDeliveryMode: .wallClock)
    }

    init(mainQueueDeliveryMode: MainQueueDeliveryMode) {
        self.mainQueueDeliveryMode = mainQueueDeliveryMode
        registerViews()
        registerModifiers()
        registerGeometryViews()
        registerChartViews()
    }

    public func hostSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool {
        if networkHostSetMember(name, on: value, to: newValue) { return true }
        if objcTrampolineSetMember(name, on: value, to: newValue) { return true }
        return hostObjectSetMember(name, on: value, to: newValue)
    }

    public func absorbedCValue(named name: String) -> RuntimeValue? {
        GeneratedCMemoryBridge.record(named: name).map(RuntimeValue.native)
    }

    public func cFunction(named name: String) -> HostFunction? {
        if let memory = GeneratedCMemoryBridge.function(named: name) {
            return memory
        }
        if let generated = GeneratedPlatformBridge.globalFunction(
            named: name,
            fallbackRuntime: generatedPlatformFallbacks
        ) {
            return generated
        }
        return nil
    }

    /// One registry owns one sandbox/blob container — the fresh-container
    /// guarantee is per registry, never process-global.
    let fileManagerBox = FileManagerBox()
    let applicationShells = FrameworkApplicationShellStore()

    public func storeBlob(_ value: RuntimeValue, at path: String) {
        fileManagerBox.blobStore[path] = value
    }

    public func hostObjectConstructor(named name: String) -> HostFunction? {
        interfaceValidatedHostObjectConstructor(
            named: name, fileManager: fileManagerBox)
    }

    public func hostGlobal(named name: String) -> RuntimeValue? {
        GeneratedPlatformBridge.globalValue(
            named: name, applicationShells: applicationShells)
    }

    public func importedNestedTypeName(for path: String) -> String? {
        GeneratedMembers.knownImportedNestedTypePaths.contains(path)
            ? path : nil
    }

    public func hostValue(
        _ value: Any, matchesImportedType typeName: String
    ) -> Bool {
        if GeneratedPlatformBridge.value(value, matchesType: typeName) {
            return true
        }
        guard value is UIKitStub else { return false }
        return GeneratedPlatformBridge.acceptsOpaqueReference(for: typeName)
    }

    public func importedType(
        named typeName: String, matchesImportedType expectedTypeName: String
    ) -> Bool {
        GeneratedPlatformBridge.importedType(
            named: typeName, matchesType: expectedTypeName)
    }

    public func hostMemberHasWorkerOperation(
        _ name: String,
        onStaticMember staticMember: String,
        ofType typeName: String
    ) -> Bool {
        typeName == FileServiceRouting.serviceTypeName
            && staticMember == FileServiceRouting.serviceAccessor
            && FileServiceRouting.workerRoutedMembers.contains(name)
    }

    public func constructor(named name: String) -> HostFunction? {
        let resolvedName = GeneratedPlatformBridge.canonicalTypeName(name)
        // Native SDK constructors come from BridgeGen before compatibility
        // boxes. The boxes remain the cross-platform fallback when the named
        // framework is unavailable on this host.
        if let nativePlatform = GeneratedPlatformBridge.nativeConstructor(
            named: resolvedName
        ) {
            return nativePlatform
        }
        if let hostObject = interfaceValidatedHostObjectConstructor(
            named: resolvedName,
            fileManager: fileManagerBox
        ) {
            return hostObject
        }
        if let task = interpretedTaskConstructor(named: resolvedName) { return task }
        if let platform = GeneratedPlatformBridge.constructor(named: resolvedName) {
            return platform
        }
        // Generic-carrier Foundation values (Measurement) construct from
        // the swept table before any absorbing fallback.
        if constructors[resolvedName] == nil,
           let carrier = GeneratedMembers.carrierConstructors[resolvedName] {
            return carrier
        }
        let hand = constructors[resolvedName]
        let generated = GeneratedConstructors.table[resolvedName]
        if hand == nil && generated == nil {
            // The automatic ObjC tier constructs allowlisted NSObject types
            // for REAL before anything absorbs.
            if let trampoline = ObjCTrampoline.constructor(named: resolvedName) {
                return trampoline
            }
            // Unknown TYPE-looking constructors (external SDKs: KeychainSwift,
            // ChatClient) build absorbing bags, the live-render analog of the
            // trace registry's opaque recorder. Lowercase names stay
            // unresolved so genuine errors surface. The bag PLAYS the type
            // (roles), so user extensions of the host type dispatch on it
            // (`UNAuthorizationStatus(rawValue: 10)?.map`).
            guard resolvedName.first?.isUppercase == true else { return nil }
        return HostFunction(name: name) { args, _ in
                let stub = UIKitStub(roles: [resolvedName])
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
                } catch let handError where generated != nil {
                    // Fall through to generated overloads; when BOTH tiers
                    // reject, the handwritten error is the curated message
                    // ("Slider(in:) needs a closed range ...") and wins over
                    // the generic no-matching-initializer report.
                    do {
                        return .native(try GeneratedDispatch.construct(
                            name: resolvedName, overloads: generated!,
                            args: args, ctx: ctx))
                    } catch {
                        throw handError
                    }
                }
            }
            guard let generated else {
                throw RuntimeError(message: "no constructor for \(resolvedName)")
            }
            return .native(try GeneratedDispatch.construct(
                name: resolvedName, overloads: generated,
                args: args, ctx: ctx))
        }
    }

    public func hostSuperclassBacking(
        named typeName: String, in context: EvalContext
    ) throws -> RuntimeValue? {
        try GeneratedPlatformBridge.hostSuperclassBacking(
            named: typeName, in: context)
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
            if any is AnyView || any is TextBox || any is ImageBox || any is ShapeBox || any is LinearGradient
                || any is PathDrawStub || any is ForEachFan || any is SectionSpec {
                return true
            }
            if any is any View { return true }
        }
        return Coerce.colorLike(value) != nil // Color IS a View
    }

    public func makeRenderable(instance: Instance, interpreter: Interpreter) -> RuntimeValue {
        if instance.symbol.isRepresentable {
#if canImport(AppKit)
            // macOS controller representables EXECUTE — the interpreted
            // make/update/loadView drive a real NSViewController host and
            // the generated platform tier supplies what they construct.
            if let representable = InterpretedControllerRepresentable.hosting(
                instance: instance, interpreter: interpreter
            ) {
                return .native(AnyView(representable))
            }
#endif
            // Other representables embed host views we can't run — the
            // honest stand-in remains an inert empty view (Lottie precedent).
            return .native(AnyView(EmptyView()))
        }
        if instance.symbol.conformsToLayout {
            // REAL layout: the interpreted sizeThatFits/placeSubviews run
            // through InterpretedLayout (the InterpretedShape pattern).
            let children = instance.properties[StructSymbol.layoutChildrenKey]?.value.arrayValue ?? []
            // ForEach fans SPLICE: the layout must see one subview per
            // element, exactly like native variadic expansion.
            var views: [AnyView] = []
            for child in children {
                if case .host(let any) = child, let fan = any as? ForEachFan {
                    views += fan.views
                } else if let view = try? Self.anyView(child) {
                    views.append(view)
                }
            }
            if RenderDiagnostics.traceEnabled {
                FileHandle.standardError.write(Data(
                    "MAKELAYOUT \(instance.symbol.name) children=\(children.count) views=\(views.count)\n".utf8))
            }
            let layout = InterpretedLayout(instance: instance, interpreter: interpreter)
            return .native(AnyView(layout {
                Self.indexed(views)
            }))
        }
        if instance.symbol.conformsToShape {
            // Shape-typed so .fill/.stroke/.trim apply; the real path comes
            // from the interpreted path(in:).
            return .native(ShapeBox(InterpretedShape(instance: instance, interpreter: interpreter)))
        }
        return .native(AnyView(InterpretedView(instance: instance, interpreter: interpreter)))
    }

    public func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue {
        // @ChartContentBuilder functions group MARKS, not views — keep the
        // chart contents raw so mark modifiers and the Chart builder see them.
        let marks = Self.chartContents(views)
        if !marks.isEmpty, marks.count >= views.count {
            return .native(marks)
        }
        let anyViews = try views.map(Self.anyView)
        // Multi-view builder output is a TupleView in native SwiftUI: the
        // members SPLICE as siblings of whatever container the value lands
        // in (variadic-tree expansion reaches through custom view bodies).
        // The fan carrier preserves that — containers and custom Layouts
        // splice fan.views, section-aware containers (Form) unpack the raw
        // values, and anyView degrades to an indexed ForEach, which SwiftUI
        // expands into the enclosing container exactly like a TupleView.
        return .native(ForEachFan(views: anyViews, rawValues: views))
    }

    // MARK: - Helpers shared by gateways

    static func anyView(_ value: RuntimeValue) throws -> AnyView {
        if case .host(let any) = value {
            if let view = any as? AnyView { return view }
            if let fan = any as? ForEachFan { return AnyView(Self.indexed(fan.views)) }
            if any is UIKitStub || any is ImplicitMemberCall || any is ChainedImplicitCall {
                // Unknown SDK views render empty — the documented inert
                // degrade (Lottie precedent), live-render edition. When the
                // absorbed chain WRAPS a real view, an unbridged modifier
                // just swallowed renderable content — every such blank cost
                // a bisect hunt (formStyle) until this diagnostic.
                if let chain = any as? ChainedImplicitCall {
                    // Walk nested chains (`.toolbar{}.navigationTitle()`)
                    // to the ROOT base.
                    var members = [chain.member]
                    var root = chain.base
                    while case .host(let inner) = root, let next = inner as? ChainedImplicitCall {
                        members.append(next.member)
                        root = next.base
                    }
                    // Opaque View preservation is SwiftUI magic: an
                    // unbridged modifier can lose its own semantics, but it
                    // must not erase a host value already proven renderable.
                    // Keep the diagnostic as the demand signal and recover
                    // only the root—not an unresolved SDK marker or stub.
                    let preservedRoot: AnyView? = {
                        guard case .host(let base) = root,
                              !(base is UIKitStub),
                              !(base is ImplicitMemberCall),
                              !(base is ChainedImplicitCall) else {
                            return nil
                        }
                        return try? Self.anyView(root)
                    }()
                    var wrapsView = preservedRoot != nil
                    if case .instance = root { wrapsView = true }
                    if wrapsView {
                        var rootType = "?"
                        if case .host(let base) = root { rootType = String(describing: type(of: base)) }
                        if case .instance(let instance) = root { rootType = instance.symbol.name }
                        let outcome = preservedRoot == nil
                            ? "renders EMPTY"
                            : "modifier semantics unavailable; preserving rendered root"
                        RenderDiagnostics.record(
                            RuntimeError(message: "[platform=\(Interpreter.interpretsAsPlatform) root=\(rootType)] unbridged view modifier chain '.\(members.reversed().joined(separator: "."))' absorbed a rendered view; \(outcome)"),
                            in: "anyView")
                        if let preservedRoot { return preservedRoot }
                    }
                }
                return AnyView(EmptyView())
            }
            if let spec = any as? SectionSpec {
                if let header = spec.header {
                    return AnyView(Section { Self.indexed(spec.rows) } header: { header })
                }
                return AnyView(Section { Self.indexed(spec.rows) })
            }
            if let box = any as? TextBox { return AnyView(box.text) }
            if let box = any as? ImageBox { return AnyView(box.image) }
            if let box = any as? ShapeBox { return AnyView(box.shape) }
            if let stub = any as? PathDrawStub { return AnyView(stub.path) }
            if let gradient = any as? LinearGradient { return AnyView(gradient) }
            if let view = any as? any View { return AnyView(view) }
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
