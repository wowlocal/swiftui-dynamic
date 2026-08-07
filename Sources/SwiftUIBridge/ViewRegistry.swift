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
        self.init(
            mainQueueDeliveryMode: .wallClock,
            projectResourceRoot: nil)
    }

    public convenience init(projectResourceRoot: String?) {
        self.init(
            mainQueueDeliveryMode: .wallClock,
            projectResourceRoot: projectResourceRoot)
    }

    init(
        mainQueueDeliveryMode: MainQueueDeliveryMode,
        projectResourceRoot: String? = nil
    ) {
        self.mainQueueDeliveryMode = mainQueueDeliveryMode
        fileManagerBox = FileManagerBox(
            projectResourceRoot: projectResourceRoot)
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
    let fileManagerBox: FileManagerBox
    let applicationShells = FrameworkApplicationShellStore()

    public func storeBlob(_ value: RuntimeValue, at path: String) {
        fileManagerBox.blobStore[path] = value
    }

    public func hostObjectConstructor(named name: String) -> HostFunction? {
        interfaceValidatedHostObjectConstructor(
            named: name, fileManager: fileManagerBox)
    }

    public func frameworkSuppliedWrapperValue(
        forAttributes attributes: [String]
    ) -> RuntimeValue? {
        generatedFrameworkSuppliedWrapperValue(forAttributes: attributes)
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
        if GeneratedReferencePropertySupport.bridgedValue(
            value, matchesImportedType: typeName) {
            return true
        }
        if let observedType = bridgeHostTypeName(of: value),
           GeneratedReferencePropertySupport.type(
               observedType, matchesImportedType: typeName) {
            return true
        }
        guard value is any GeneratedPlatformOpaqueReferenceCarrier else {
            return false
        }
        return GeneratedPlatformBridge.acceptsOpaqueReference(for: typeName)
    }

    public func contextualizeOpaqueHostValue(
        _ value: RuntimeValue, as typeName: String
    ) -> RuntimeValue? {
        GeneratedPlatformBridge.contextualizedOpaqueReference(
            named: typeName)
    }

    public func importedType(
        named typeName: String, matchesImportedType expectedTypeName: String
    ) -> Bool {
        GeneratedPlatformBridge.importedType(
            named: typeName, matchesType: expectedTypeName)
    }

    public func importedType(
        named typeName: String,
        conformsToImportedProtocol protocolName: String
    ) -> Bool? {
        GeneratedResultBuilderCarriers.importedType(
            named: typeName, conformsTo: protocolName)
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
        if let nativeValue = generatedNativeValueConstructor(
            named: resolvedName
        ) {
            return nativeValue
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
        return HostFunction(name: name) { rawArgs, ctx in
            // Both tiers below see the interface's reading of the call, so a
            // gateway that stays handwritten for interface-inexpressible
            // reasons inherits it without naming the rule.
            let args = GeneratedDispatch.readingLocalizationKeys(
                rawArgs, constructor: generated, ctx: ctx)
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
        if let handWritten = modifiers[name] {
            return GeneratedDispatch.exposingInterfaceMetadata(
                for: handWritten, named: name)
        }
        guard let overloads = GeneratedModifiers.table[name] else { return nil }
        return HostModifier(
            name: name,
            parameterTypeCandidates: { args, ctx in
                GeneratedDispatch.contextualParameterTypeCandidates(
                    overloads: overloads, args: args, ctx: ctx)
            },
            argumentMatch: { args, ctx in
                GeneratedDispatch.contextualArgumentsMatch(
                    overloads: overloads, args: args, ctx: ctx)
            },
            apply: { value, rawArgs, ctx in
                let view = try Self.anyView(value)
                return .native(try GeneratedDispatch.dispatch(
                    name: name, overloads: overloads, view: view,
                    args: GeneratedDispatch.readingLocalizationKeys(
                        rawArgs, modifier: name, ctx: ctx),
                    ctx: ctx
                ))
            })
    }

    public func isViewValue(_ value: RuntimeValue) -> Bool {
        if case .host(let any) = value {
            if Self.isHostViewValue(any) { return true }
        }
        return Coerce.colorLike(value) != nil // Color IS a View
    }

    public func makeRenderable(instance: Instance, interpreter: Interpreter) -> RuntimeValue {
        if instance.symbol.isRepresentable {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
            // macOS controller representables EXECUTE — the interpreted
            // make/update/loadView drive a real NSViewController host and
            // the generated platform tier supplies what they construct.
            if let representable = InterpretedControllerRepresentable.hosting(
                instance: instance, interpreter: interpreter
            ) {
                return .native(AnyView(representable))
            }
#endif
#if (canImport(AppKit) && !targetEnvironment(macCatalyst)) || canImport(UIKit)
            // View representables EXECUTE the same way, under whichever
            // framework this build hosts through: the interpreted
            // makeCoordinator/make/update run and the platform view they
            // construct IS the represented view.
            if let representable = InterpretedViewRepresentable.hosting(
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
        // splice fan.views, and anyView degrades to an indexed ForEach, which
        // SwiftUI expands into the enclosing container exactly like a
        // TupleView. Sections need no special case on this path: fan.views is
        // already mapped through anyView, so a SectionSpec riding a fan is a
        // real Section by the time any container sees it.
        return .native(ForEachFan(views: anyViews))
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
                    var wrapsView = false
                    if case .host(let base) = root {
                        wrapsView = Self.isHostViewValue(base)
                    }
                    if case .instance = root { wrapsView = true }
                    if wrapsView {
                        var rootType = "?"
                        if case .host(let base) = root { rootType = String(describing: type(of: base)) }
                        if case .instance(let instance) = root { rootType = instance.symbol.name }
                        RenderDiagnostics.record(
                            RuntimeError(message: "[platform=\(Interpreter.interpretsAsPlatform) root=\(rootType)] unbridged view modifier chain '.\(members.reversed().joined(separator: "."))' absorbed a rendered view; preserves an invisible collection placeholder"),
                            in: "anyView")
                        // SwiftUI magic: erasing a rendered collection child
                        // to zero-sized EmptyView also erases its composition
                        // slot, moving later siblings into the missing row —
                        // so the receiver is kept. It is kept VISIBLE, because
                        // what is unknown is the MODIFIER's pixels, never the
                        // receiver's: hiding the receiver answers "this view
                        // draws nothing", which is a far stronger claim than
                        // "this modifier is unimplemented" and is wrong for
                        // every modifier that is not itself `.hidden()`.
                        // Identity is the closest reachable approximation of
                        // an unapplied modifier, and it keeps both the
                        // composition slot and the content. A now-visible row
                        // paints its separator exactly like any other.
                        if let receiver = try? Self.anyView(root) {
                            return receiver
                        }
                    }
                }
                return AnyView(EmptyView())
            }
            if let spec = any as? SectionSpec {
                // All four initializer shapes the interface declares, because
                // a `Section` is a different TYPE per accessory it carries and
                // the accessories are not optional parameters: passing an
                // `EmptyView` footer is not the same as passing none — it
                // reserves footer space the no-footer overload never lays out.
                switch (spec.header, spec.footer) {
                case (let header?, let footer?):
                    return AnyView(Section {
                        Self.indexed(spec.rows)
                    } header: { header } footer: { footer })
                case (let header?, nil):
                    return AnyView(Section {
                        Self.indexed(spec.rows)
                    } header: { header })
                case (nil, let footer?):
                    return AnyView(Section {
                        Self.indexed(spec.rows)
                    } footer: { footer })
                case (nil, nil):
                    return AnyView(Section { Self.indexed(spec.rows) })
                }
            }
            if let box = any as? TextBox { return AnyView(box.text) }
            if let box = any as? ImageBox { return AnyView(box.image) }
            if let box = any as? ShapeBox { return AnyView(box.shape) }
            if let stub = any as? PathDrawStub { return AnyView(stub.path) }
            if let gradient = any as? LinearGradient { return AnyView(gradient) }
            if let view = any as? any View { return AnyView(view) }
            if let node = any as? TraceNode {
                // The trace instrument's recorded view. It is a VIEW — the
                // registry that made it says so — but it carries no native
                // SwiftUI rendering, because that instrument records a tree
                // instead of drawing one. A native boundary asking for a
                // real `AnyView` therefore takes the same inert placeholder
                // the absorbed-view degrade above uses.
                //
                // This is the erasure declining to render, never declining
                // to ACCEPT: throwing here would make an ordinary conforming
                // View illegal under one of the two instruments, which is
                // how a corpus project that renders under the pixel harness
                // failed under the trace harness at the same source line.
                //
                // Recorded, because the placeholder DOES cost coverage: the
                // node's subtree is not walked from here, so a screen hosted
                // this way is counted by neither instrument. That is what
                // the boundary did before it had a contract at all, so it
                // takes nothing away — but it is a gap, and this file's own
                // history is that every silent blank cost a bisect hunt.
                RenderDiagnostics.record(
                    RuntimeError(message:
                        "native view boundary took '\(node.kind)' as a "
                            + "placeholder; its subtree is recorded by the "
                            + "trace instrument, not rendered here"),
                    in: "anyView")
                return AnyView(EmptyView())
            }
        }
        if let color = Coerce.colorLike(value) { return AnyView(color) }
        throw RuntimeError(message: "expected a View, got \(value.stringified)")
    }

    /// One semantic predicate serves every host-value rendering boundary.
    /// Native SDK Views are recognized by conformance; only the small
    /// interface-inexpressible composition carriers require explicit cases.
    private static func isHostViewValue(_ value: Any) -> Bool {
        value is any View
            || value is TextBox
            || value is ImageBox
            || value is ShapeBox
            || value is PathDrawStub
            || value is ForEachFan
            || value is SectionSpec
    }

    /// Positional identity is fine here: interpreted bodies are re-evaluated
    /// wholesale on every change anyway.
    static func indexed(_ views: [AnyView]) -> some View {
        ForEach(views.indices, id: \.self) { views[$0] }
    }

    /// Builder output as STATIC siblings, which is what native multi-statement
    /// builder output is: a `TupleView` whose members splice into the
    /// enclosing container and are classified one by one.
    ///
    /// `indexed` is the other spelling and it is a DYNAMIC fan. A collection
    /// that groups by section reads a dynamic fan's kind once, from its first
    /// element, so `Form { row; Section; Section }` — where the fan opens on a
    /// row — degraded every section in it to a plain row. Splicing removes the
    /// fan instead of teaching the container to look past it, so no value has
    /// to be classified as section-like on the way in and every route into the
    /// container keeps whatever it already was.
    ///
    /// Halving keeps the nesting depth logarithmic; `Group` is transparent to
    /// the enclosing container, so the tree flattens back to the same sibling
    /// sequence whatever shape it is built in.
    static func spliced(_ views: [AnyView]) -> AnyView {
        guard let first = views.first else { return AnyView(EmptyView()) }
        guard views.count > 1 else { return first }
        let middle = views.count / 2
        let leading = Self.spliced(Array(views[..<middle]))
        let trailing = Self.spliced(Array(views[middle...]))
        return AnyView(Group {
            leading
            trailing
        })
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
        try Self.anyView(value, resolving: ctx, preferring: self)
    }

    /// Erase a value the interface types `any View`.
    ///
    /// A source type declaring `: View` CONFORMS, and conformance is the whole
    /// contract `any View` states — so a bare interpreted instance is a legal
    /// argument and must reach a renderable through the registry's own
    /// `makeRenderable` before erasure. `Self.anyView` alone reads host
    /// payloads only, so it rejects the one shape interpreted source passes
    /// most often.
    ///
    /// This is the SINGLE spelling of that rule. The handwritten gateways
    /// reached it through `anyViewResolving` while the generated tier called
    /// the host-only static, so the two tiers disagreed about what `any View`
    /// accepts and only the generated one was wrong.
    ///
    /// The resolution goes through the `HostRegistry` requirement rather than
    /// this type's own method, so the rule holds for whichever registry is
    /// driving — the generated tier serves the trace and view registries
    /// alike, and they render through different instruments.
    static func anyView(
        _ value: RuntimeValue, resolving ctx: EvalContext,
        preferring registry: HostRegistry? = nil
    ) throws -> AnyView {
        guard case .instance(let instance) = value,
              instance.symbol.conformsToView || instance.symbol.isRepresentable,
              let interpreter = ctx as? Interpreter,
              let host = registry ?? interpreter.registry
        else {
            return try Self.anyView(value)
        }
        return try Self.anyView(
            host.makeRenderable(instance: instance, interpreter: interpreter))
    }
}
