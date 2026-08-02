import Foundation
import SwiftInterpreter

public struct TraceLifecycleIdentity: Hashable {
    public let sourceSiteID: UInt64
    public let modifier: String
    public let viewIdentityPath: String
    public let restartToken: String?
}

public struct TraceLifecycle {
    public let identity: TraceLifecycleIdentity
    public let closure: ClosureValue
    public let isAsyncAction: Bool
}

/// A recorded render-tree node — what the trace registry produces instead of
/// real SwiftUI views, so tests can assert structure headlessly.
public final class TraceNode: InertCallable {
    public let kind: String
    /// The source-level nominal type when a semantic operation changes the
    /// diagnostic tree shape. Combining two values may produce a
    /// `TextConcat` node while the result remains the same nominal type for
    /// overload and constrained-extension dispatch.
    public var nominalTypeName: String?
    public var args: [String] = []
    /// Pushed-screen coverage (NavigationLink destinations): body failures
    /// SKIP the subtree instead of failing the walk — on device the screen
    /// only exists after a tap.
    public var optionalCoverage = false
    public var children: [TraceNode] = []
    public var modifiers: [String] = []
    public var actions: [String: ClosureValue] = [:]
    public var bindings: [String: BindingStub] = [:]
    public var environmentModels: [String: Instance] = [:]
    public var instance: Instance?
    /// `.task`/`.onAppear` closures, retained for LiveCheck's probe to fire.
    public var lifecycle: [TraceLifecycle] = []
    /// Headless launch has no layout engine, but viewport-materialized
    /// containers still must not make every child lifecycle-visible.
    /// LiveCheck supplies the row capacity from a native target observation;
    /// this flag carries only the interface-inexpressible SwiftUI behavior.
    public var viewportMaterializesLifecycleRows = false
    /// Opaque host objects (`UIPanGestureRecognizer()`, …) are recorded as
    /// nodes but behave like the mutable objects they stand for: property
    /// writes land here and read back (`gesture.name = id … gesture.name`).
    public var config: [String: RuntimeValue] = [:]
    /// Generic constructors without view-building closures may represent
    /// imported objects. Their unknown members remain concrete, memoized
    /// recorder values instead of being mistaken for arbitrary modifiers.
    var absorbsUnknownMembers = false

    init(kind: String, absorbsUnknownMembers: Bool = false) {
        self.kind = kind
        self.absorbsUnknownMembers = absorbsUnknownMembers
    }

    public func findAll(_ kind: String) -> [TraceNode] {
        var result: [TraceNode] = []
        if self.kind == kind { result.append(self) }
        for child in children { result += child.findAll(kind) }
        return result
    }
}

/// A `HostRegistry` that records the render tree instead of building SwiftUI
/// views. No SwiftUI hosting needed: `makeRenderable` is lazy (tests call
/// `evaluateBody` themselves), and any modifier name is accepted and recorded.
public final class TraceRegistry: HostRegistry {
    /// Nested `Task {}` bodies are scheduled, never run synchronously.
    var taskDepth = 0
    let fileManagerBox: FileManagerBox
    let applicationShells = FrameworkApplicationShellStore()
    private let generatedPlatformFallbacks = GeneratedPlatformFallbackRuntime()
    /// Projection delivery is a property of this verification environment.
    /// Snapshotting it prevents a concurrent replay scope from changing an
    /// already-created absorbed registry halfway through a render.
    private let publishedProjectionPolicy: NetworkPolicy

    /// Swiftinterface metadata exposes List's builder but not its lazy,
    /// viewport-owned lifecycle semantics. Keep that missing SwiftUI magic in
    /// one explicit allowlist. Runtime capacity is deliberately absent: row
    /// heights are compiled framework/layout behavior and come from the
    /// executing native target instead of a calibrated constant.
    private static let viewportMaterializedContainers: Set<String> = ["List"]

    public init(
        networkPolicy: NetworkPolicy? = nil,
        projectResourceRoot: String? = nil
    ) {
        fileManagerBox = FileManagerBox(
            projectResourceRoot: projectResourceRoot)
        publishedProjectionPolicy = networkPolicy ?? NetworkBridge.activePolicy
    }

    public func absorbedCValue(named name: String) -> RuntimeValue? {
        GeneratedCMemoryBridge.record(named: name).map(RuntimeValue.native)
    }

    public func hostGlobal(named name: String) -> RuntimeValue? {
        GeneratedPlatformBridge.globalValue(
            named: name, applicationShells: applicationShells)
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
        guard value is any GeneratedPlatformOpaqueReferenceCarrier
                || (value as? TraceNode)?.absorbsUnknownMembers == true
        else {
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

    public func storeBlob(_ value: RuntimeValue, at path: String) {
        fileManagerBox.blobStore[path] = value
    }

    public func hostObjectConstructor(named name: String) -> HostFunction? {
        interfaceValidatedHostObjectConstructor(
            named: name, fileManager: fileManagerBox)
    }

    public func importedNestedTypeName(for path: String) -> String? {
        GeneratedMembers.knownImportedNestedTypePaths.contains(path)
            ? path : nil
    }

    /// The element's identity for state salting: an Identifiable `id`
    /// when present, the scalar itself, else the position.
    static func identitySalt(of element: RuntimeValue, index: Int) -> String {
        if case .instance(let instance) = element,
           let id = instance.box(for: "id")?.value {
            return id.stringValue ?? id.stringified
        }
        if let text = element.stringValue { return text }
        if let number = element.intValue { return String(number) }
        return String(index)
    }

    /// Only direct scalar constructor arguments are visible text. Structured
    /// values are configuration/model inputs, and recursively describing them
    /// both invents UI strings and can repeatedly walk a large object graph.
    private static func directTraceText(
        from value: RuntimeValue
    ) -> String? {
        switch value {
        case .string(let text):
            return text
        case .int(let integer):
            return String(integer)
        case .double(let double):
            return String(double)
        case .bool(let boolean):
            return boolean ? "true" : "false"
        case .optional(let optional):
            return optional.wrapped.flatMap(directTraceText(from:))
        case .host:
            return value.stringValue
        default:
            return nil
        }
    }

    /// A host collection has already been materialized before this entry, so
    /// every builder row is finite in cardinality while retaining its own
    /// ordinary infinite-work guard. Identity salting and budget slicing are
    /// applied uniformly to every registry constructor that expands data.
    @MainActor
    private static func finiteBuilderRows(
        _ content: ClosureValue,
        element: RuntimeValue,
        salt: String,
        context: EvalContext
    ) throws -> [RuntimeValue] {
        try context.withKnownFiniteHostIteration {
            if let interpreter = context as? Interpreter {
                return try interpreter.withViewIdentitySalt(salt) {
                    try context.callBuilderClosure(
                        content, arguments: [element])
                }
            }
            return try context.callBuilderClosure(
                content, arguments: [element])
        }
    }

    public func publishedProjection(current: RuntimeValue) -> RuntimeValue? {
        switch publishedProjectionPolicy {
        case .absorbed:
            return nil
        case .replay, .live:
            return .native(ValuePublisherBox(.success(current)))
        }
    }

    public func constructor(named name: String) -> HostFunction? {
        if let nativeValue = generatedNativeValueConstructor(named: name) {
            return nativeValue
        }
        if let hostObject = interfaceValidatedHostObjectConstructor(
            named: name,
            fileManager: fileManagerBox
        ) { return hostObject }
        if let platform = GeneratedPlatformBridge.constructor(named: name) {
            return platform
        }
        if name == "UserDefaults" || name == "NSUserDefaults" {
            return ObjCTrampoline.constructor(named: name)
        }
        if let dataAsset = ObjCTrampoline.projectDataAssetConstructor(
            named: name,
            projectResourceRoot: fileManagerBox.projectResourceRoot
        ) {
            return dataAsset
        }
        switch name {
        case "Text", "Image", "Spacer", "Divider", "Toggle", "TextField", "Slider":
            return HostFunction(name: name) { args, _ in
                let node = TraceNode(kind: name)
                for argument in args.arguments {
                    if case .host(let any) = argument.value, let stub = any as? BindingStub {
                        node.bindings[argument.label ?? "_"] = stub
                    } else if argument.value.closureValue == nil {
                        node.args.append(argument.value.stringified)
                    }
                }
                return .native(node)
            }
        case "VStack", "HStack", "ZStack":
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: name)
                if let content = args.closure(labeled: "content") ?? args.lastUnlabeledClosure {
                    node.children = try ctx.callBuilderClosure(content, arguments: []).map(Self.node)
                }
                return .native(node)
            }
        case "Button":
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: "Button")
                if let title = args.positional(0)?.stringValue { node.args = [title] }
                let unlabeled = args.unlabeledClosures
                if let action = args.closure(labeled: "action") ?? unlabeled.first {
                    node.actions["action"] = action
                }
                if let label = args.closure(labeled: "label") {
                    node.children = try ctx.callBuilderClosure(label, arguments: []).map(Self.node)
                }
                return .native(node)
            }
        case "GeometryReader", "TimelineView", "ScrollViewReader", "MapReader":
            // Layout/time/scroll/map proxies don't exist headlessly; bind
            // honest stubs so the content still deep-renders.
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: name)
                if let content = args.firstUnlabeledClosure {
                    let argument: RuntimeValue
                    switch name {
                    case "GeometryReader": argument = .native(GeometryProxyStub())
                    case "ScrollViewReader": argument = .native(ScrollViewProxyStub())
                    case "MapReader": argument = .native(MapProxyStub())
                    default: argument = .native(TimelineContextStub())
                    }
                    node.children = try ctx.callBuilderClosure(content, arguments: [argument]).map(Self.node)
                }
                return .native(node)
            }
        case "KeyframeAnimator", "PhaseAnimator":
            // Content receives the animated value — headlessly that's the
            // initialValue (keyframes) or the first phase. The keyframes/
            // animation timing DSL closure deliberately never runs.
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: name)
                let seed = (args.labeled("initialValue")
                    ?? args.positional(0)?.arrayValue?.first
                    ?? args.positional(0)) ?? .void
                if let content = args.firstUnlabeledClosure {
                    node.children = try ctx.callBuilderClosure(content, arguments: [seed]).map(Self.node)
                }
                return .native(node)
            }
        case "Task", "MainActor":
            // Synchronous-render compatibility for `Task { try await … }`:
            // unhandled errors end the task silently, exactly as on device.
            // Async sessions are claimed by the interpreter-core scheduler.
            // NESTED compatibility tasks are SCHEDULED, not run:
            // recursive retry loops (`func poll() { Task { poll() } }`)
            // terminate exactly like real async scheduling.
            return HostFunction(name: name) { [weak self] args, ctx in
                if let body = args.firstUnlabeledClosure ?? args.closure(labeled: "operation"),
                   let self, self.taskDepth == 0 {
                    self.taskDepth += 1
                    defer { self.taskDepth -= 1 }
                    do {
                        _ = try ctx.callBackgroundClosure(body, arguments: [])
                    } catch let error as RuntimeError where !error.fatal {
                        // unhandled task error: logged on device, silent here
                        if LiveCheckSupport.traceLifecycle {
                            print("   ⚠ task body died: \(error)")
                        }
                    }
                }
                return .native(TraceNode(kind: name))
            }
        case "AsyncImage":
            // Headlessly there's no network: the CONTENT closure still
            // verifies against a stub image (GeometryReader-proxy
            // precedent), and the placeholder renders — the phase a fresh
            // launch actually shows.
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: name)
                if let url = args.labeled("url") { node.args.append(url.stringified) }
                if let content = args.firstUnlabeledClosure {
                    // The stub is what trace Image constructors produce, so
                    // every image modifier chains natively.
                    let stub = RuntimeValue.native(TraceNode(kind: "Image"))
                    do {
                        node.children += try ctx.callBuilderClosure(content, arguments: [stub]).map(Self.node)
                    } catch let error as RuntimeError where !error.fatal {
                        // Phase-form closures (`{ phase in … }`) read members
                        // a plain image lacks — record without invoking.
                        node.args.append("closure")
                    }
                }
                if let placeholder = args.closure(labeled: "placeholder") {
                    node.children += try ctx.callBuilderClosure(placeholder, arguments: []).map(Self.node)
                }
                return .native(node)
            }
        case "Canvas":
            // The renderer draws (side effects on the context), it doesn't
            // build children — run it with an inert context + canvas size.
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: "Canvas")
                if let renderer = args.firstUnlabeledClosure {
                    _ = try ctx.callClosure(renderer, arguments: [
                        .native(GraphicsContextStub()),
                        .native(CGSize(width: 390, height: 844)),
                    ])
                }
                return .native(node)
            }
        case "Path":
            return HostFunction(name: name) { args, ctx in
                let path = PathDrawStub()
                if let builder = args.firstUnlabeledClosure {
                    _ = try ctx.callClosure(builder, arguments: [.native(path)])
                }
                return .native(path)
            }
        case "AnyView":
            // Identity: interpreted views are already type-erased.
            return HostFunction(name: name) { args, _ in
                args.positional(0) ?? .void
            }
        case "NavigationStack", "NavigationView":
            // The trace tree must show the screen the app is ON. A non-empty
            // path means a pushed destination covers the root — the same
            // semantic the compiled stack paints (verified against a real
            // NavigationStack in PathDrivenNavigationTests) and the reason a
            // row tap can reach a detail screen at all.
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: name)
                let content = args.closure(labeled: "root")
                    ?? args.closure(labeled: "content")
                    ?? args.lastUnlabeledClosure
                let (rootRows, destinations) = try NavigationPresentationBridge
                    .collectingDestinations { () -> [RuntimeValue] in
                        guard let content else { return [] }
                        return try ctx.callBuilderClosure(
                            content, arguments: [])
                    }
                let path = args.labeled("path")
                if case .host(let any) = path, let stub = any as? BindingStub {
                    node.bindings["path"] = stub
                }
                if let pushed = NavigationPresentationBridge.pushedDestination(
                    path: path, destinations: destinations, context: ctx)
                {
                    node.children = try pushed.map(Self.node)
                } else {
                    node.children = try rootRows.map(Self.node)
                }
                return .native(node)
            }
        case "NavigationLink":
            // Destinations get deep coverage like other PRESENTED content
            // (sheet bodies, tab items): on device they render on tap; the
            // probe walks them so pushed screens' data reaches the tree.
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: name)
                if let title = args.positional(0)?.stringValue { node.args.append(title) }
                for argument in args.arguments {
                    if let closure = argument.value.closureValue {
                        if closure.parameters.isEmpty {
                            node.children += try ctx.callBuilderClosure(closure, arguments: []).map(Self.node)
                        }
                        continue
                    }
                    if argument.label == "destination" {
                        // Interpreted view instances arrive raw (builder
                        // collection normally converts them) — wrap so the
                        // pushed screen's body walks like any child.
                        var destinationValue = argument.value
                        if case .instance(let viewInstance) = destinationValue,
                           viewInstance.symbol.conformances.contains("View"),
                           let interpreter = ctx as? Interpreter {
                            destinationValue = self.makeRenderable(
                                instance: viewInstance, interpreter: interpreter)
                        }
                        if let destination = try? Self.node(destinationValue) {
                            destination.optionalCoverage = true
                            node.children.append(destination)
                        }
                    }
                }
                return .native(node)
            }
        case "withAnimation":
            return HostFunction(name: name) { args, ctx in
                if LiveCheckSupport.traceLifecycle {
                    let body = args.firstUnlabeledClosure?.body.description
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ") ?? "nil"
                    print("   ⟲ withAnimation: \(body.prefix(80))")
                }
                guard let closure = args.firstUnlabeledClosure else { return .void }
                return try ctx.callClosure(closure, arguments: [])
            }
        case "ForEach":
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: "ForEach")
                guard let data = args.positional(0),
                      let content = args.closure(labeled: "content") ?? args.lastUnlabeledClosure else {
                    throw RuntimeError(message: "ForEach needs data and a content closure")
                }
                // `ForEach($items) { $item in … }` — element bindings.
                let elements: [RuntimeValue]
                if case .host(let any) = data, let stub = any as? BindingStub,
                   let bindings = stub.elementBindings() {
                    elements = bindings
                } else {
                    elements = try Self.elements(of: data)
                }
                for (index, element) in elements.enumerated() {
                    let salt = Self.identitySalt(of: element, index: index)
                    let rows = try Self.finiteBuilderRows(
                        content, element: element, salt: salt, context: ctx)
                    node.children += try rows.map(Self.node)
                }
                return .native(node)
            }
        default:
            // Generic recorder: any other TYPE-looking constructor becomes a
            // node; builder closures expand (over leading array/range data
            // when they take a parameter), `action:` closures are stored for
            // tests. Lowercase names stay unresolved so genuine identifier
            // errors surface truthfully instead of becoming fake recorders.
            guard name.first?.isUppercase == true else { return nil }
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(
                    kind: name,
                    absorbsUnknownMembers: !args.arguments.contains {
                        $0.value.closureValue != nil
                    })
                node.viewportMaterializesLifecycleRows =
                    Self.viewportMaterializedContainers.contains(name)
                var data: RuntimeValue?
                for argument in args.arguments {
                    if case .host(let any) = argument.value, let stub = any as? BindingStub {
                        node.bindings[argument.label ?? "_"] = stub
                    } else if let closure = argument.value.closureValue {
                        if argument.label == "action" {
                            node.actions["action"] = closure
                            continue
                        }
                        if let data, let elements = try? Self.elements(of: data) {
                            for (index, element) in elements.enumerated() {
                                let salt = Self.identitySalt(of: element, index: index)
                                let rows = try Self.finiteBuilderRows(
                                    closure, element: element, salt: salt,
                                    context: ctx)
                                node.children += try rows.map(Self.node)
                            }
                        } else if closure.parameters.isEmpty {
                            do {
                                node.children += try ctx.callBuilderClosure(closure, arguments: []).map(Self.node)
                            } catch let error as RuntimeError
                                where !error.fatal && error.message.hasPrefix("expected a view") {
                                // Unknown API whose closure isn't a view
                                // builder after all — `LottieView { await
                                // LottieAnimation.loadedFrom(url:) }` loads
                                // data. Record it as configuration.
                                node.args.append("closure")
                            }
                        } else {
                            // Parameterized closures on unknown APIs are
                            // callbacks we can't honestly drive —
                            // `SignInWithAppleButton { request in }`,
                            // `UIAction(…) { _ in }`. Record, never invoke.
                            node.args.append("closure")
                        }
                    } else {
                        if let label = argument.label {
                            // Labeled configuration round-trips through the
                            // bag: Key("size", default: NSSize(…)).default
                            // and NSSize(width:…).width read back.
                            node.config[label] = argument.value
                        } else {
                            data = argument.value
                        }
                        if let text = Self.directTraceText(
                            from: argument.value
                        ) {
                            node.args.append(text)
                        }
                    }
                }
                return .native(node)
            }
        }
    }

    public func hostSuperclassBacking(
        named typeName: String, in context: EvalContext
    ) throws -> RuntimeValue? {
        try GeneratedPlatformBridge.hostSuperclassBacking(
            named: typeName, in: context)
    }

    /// Whether interface metadata says a modifier's closure arguments build
    /// views rather than perform actions. Trace mode evaluates these builders
    /// unconditionally so presented/deferred content still gets deep coverage.
    /// `tabItem` is the one compatibility gateway not emitted by BridgeGen;
    /// SwiftUI nevertheless declares its closure as `@ViewBuilder`.
    private static func isBuilderOnlyModifier(_ name: String) -> Bool {
        if name == "tabItem" { return true }
        guard let set = GeneratedModifiers.table[name] else { return false }
        let parameters = set.byArity.values
            .flatMap { $0 }
            .flatMap(\.params)
        return parameters.contains { $0.tag == .builder }
            && !parameters.contains {
                $0.tag == .action || $0.tag == .asyncAction
            }
    }

    /// Whether interface metadata says a modifier performs a caller-supplied
    /// action rather than building content — `.onTapGesture { }` and its
    /// siblings. Trace mode retains those closures as fireable node actions,
    /// so the interaction rung can drive tap-initiated screen transitions
    /// (a status row pushing its detail) exactly as it drives Button actions.
    private static func isActionModifier(_ name: String) -> Bool {
        guard let set = GeneratedModifiers.table[name] else { return false }
        let parameters = set.byArity.values
            .flatMap { $0 }
            .flatMap(\.params)
        return parameters.contains {
            $0.tag == .action || $0.tag == .syncVoidClosure
        } && !parameters.contains { $0.tag == .builder }
    }

    private static func executesBuilderOnlyModifier(
        _ name: String,
        context: EvalContext
    ) -> Bool {
        if name == "tabItem" { return true }
        guard let set = GeneratedModifiers.table[name] else { return false }
        let parameters = set.byArity.values
            .flatMap { $0 }
            .filter {
                $0.executesBuilderArguments
                    && GeneratedDispatch.isAvailable($0, in: context)
            }
            .flatMap(\.params)
        return parameters.contains { $0.tag == .builder }
            && !parameters.contains {
                $0.tag == .action || $0.tag == .asyncAction
            }
    }

    public func modifier(named name: String) -> HostModifier? {
        let modifier = HostModifier(name: name) { value, args, ctx in
            let node = try Self.node(value)
            if name == "environmentObject" || name == "environment",
               let first = args.positional(0),
               case .instance(let model) = first {
                node.environmentModels[model.symbol.name] = model
            }
            // Lifecycle closures are RETAINED (not run): LiveCheck's probe
            // fires them and re-renders, so `.task`-fetched data reaches the
            // tree. ProjectCheck/HeadlessVerifier never invoke them —
            // M0 behavior is unchanged.
            let retainsLifecycle = name == "task" || name == "onAppear"
            if retainsLifecycle,
               let closure = args.arguments.compactMap({ $0.value.closureValue }).first,
               closure.parameters.isEmpty {
                let closureIndex = args.arguments.firstIndex {
                    $0.value.closureValue != nil
                }
                let parameters = GeneratedModifiers.table[name].flatMap {
                    GeneratedDispatch.matchingParameters(
                        overloads: $0, args: args, ctx: ctx)
                }
                let isAsyncAction = closureIndex.flatMap { index in
                    parameters?.indices.contains(index) == true
                        ? parameters?[index].tag : nil
                } == .asyncAction
                // SwiftUI owns lifecycle by structural view identity, not by
                // the callback's ordinal in a freshly rendered tree. The
                // syntax call site distinguishes sibling modifiers, the
                // collection path distinguishes ForEach rows, and task(id:)
                // contributes its documented restart token.
                node.lifecycle.append(TraceLifecycle(
                    identity: TraceLifecycleIdentity(
                        sourceSiteID: args.sourceSiteID ?? closure.sourceSiteID,
                        modifier: name,
                        viewIdentityPath: ctx.currentViewIdentityPath,
                        restartToken: name == "task"
                            ? args.labeled("id")?.stringified : nil),
                    closure: closure,
                    isAsyncAction: isAsyncAction))
            }
            // Tap-driven transitions are real screen changes: IceCubes'
            // StatusRowView taps into navigateToDetail(), which appends to the
            // RouterPath the NavigationStack renders. Retain the closure so
            // the interaction rung can fire it; lifecycle modifiers already
            // retained above keep their own firing discipline.
            if !retainsLifecycle, Self.isActionModifier(name),
               let closure = args.arguments.compactMap({ $0.value.closureValue }).first,
               closure.parameters.isEmpty {
                node.actions[name] = closure
            }
            // Hand the enclosing NavigationStack the destination this
            // descendant declares. The builder takes the path element as a
            // parameter, so the generic recorder below can only record it as
            // configuration — only the stack knows what to pass.
            if name == "navigationDestination",
               let closure = args.arguments.compactMap({
                   $0.value.closureValue
               }).first, closure.parameters.count == 1 {
                NavigationPresentationBridge.recordDestination(
                    typeName: args.labeled("for").flatMap(
                        NavigationPresentationBridge.dispatchTypeName(of:)),
                    builder: closure)
            }
            if Self.executesBuilderOnlyModifier(name, context: ctx) {
                // `sheet(item: $route) { $0.makeSheetView() }` — the content
                // BINDS the item: it evaluates only when the binding holds a
                // value, receiving it (nil = not presented, like device).
                let hasItemArgument = args.labeled("item") != nil
                let itemValue: RuntimeValue? = args.labeled("item").flatMap { item in
                    if case .host(let any) = item, let stub = any as? BindingStub {
                        return stub.box.value.unwrappedOptionalOrSelf
                    }
                    return item.unwrappedOptionalOrSelf
                }
                for argument in args.arguments {
                    guard let closure = argument.value.closureValue else { continue }
                    if hasItemArgument {
                        guard let item = itemValue else { continue }
                        do {
                            node.children += try ctx.callBuilderClosure(closure, arguments: [item]).map(Self.node)
                        } catch let unbindable as RuntimeError where !unbindable.fatal {
                            // Content shapes the plain item can't satisfy
                            // (TCA's scoped-store sheets) stay unpresented —
                            // the pre-gating behavior for parameterized
                            // closures.
                        }
                    } else if closure.parameters.isEmpty {
                        node.children += try ctx.callBuilderClosure(closure, arguments: []).map(Self.node)
                    }
                }
            }
            // Title chrome IS rendered content natively (the navigation
            // bar shows it) — surface it to the strings collector.
            if ["navigationTitle", "navigationBarTitle"].contains(name),
               let title = args.positional(0)?.stringValue {
                node.args.append(title)
            }
            let argText = args.arguments
                .map { ($0.label.map { "\($0): " } ?? "") + $0.value.stringified }
                .joined(separator: ", ")
            node.modifiers.append(argText.isEmpty ? name : "\(name)(\(argText))")
            return .native(node)
        }
        return GeneratedDispatch.exposingInterfaceMetadata(
            for: modifier, named: name)
    }

    public func isViewValue(_ value: RuntimeValue) -> Bool {
        if case .host(let any) = value, any is TraceNode { return true }
        return Coerce.colorLike(value) != nil // Color IS a View
    }

    public func makeRenderable(instance: Instance, interpreter: Interpreter) -> RuntimeValue {
        if instance.symbol.isRepresentable {
            // No body to deep-render; recorded inert.
            return .native(TraceNode(kind: "Representable:\(instance.symbol.name)"))
        }
        if instance.symbol.conformsToLayout {
            let node = TraceNode(kind: "Layout:\(instance.symbol.name)")
            let children = instance.properties[StructSymbol.layoutChildrenKey]?.value.arrayValue ?? []
            node.children = children.compactMap { try? Self.node($0) }
            return .native(node)
        }
        if instance.symbol.conformsToShape {
            // No body — execute the geometry math against the standard
            // canvas rect so errors in path(in:) still surface.
            _ = try? interpreter.callMethod(
                named: "path", on: instance,
                arguments: [.native(CGRect(x: 0, y: 0, width: 390, height: 844))])
            return .native(TraceNode(kind: "Shape:\(instance.symbol.name)"))
        }
        let node = TraceNode(kind: "View:\(instance.symbol.name)")
        node.instance = instance
        return .native(node)
    }

    public func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue {
        let node = TraceNode(kind: "Group")
        node.children = try views.map(Self.node)
        return .native(node)
    }

    public func hostProperty(named name: String, on value: Any) -> HostProperty? {
        bridgeHostProperty(name, on: value)
    }

    public func fallbackHostProperty(
        named name: String, on value: Any
    ) -> HostProperty? {
        bridgeFallbackHostProperty(name, on: value)
    }

    public func hostMember(_ name: String, on value: Any) -> RuntimeValue? {
        if let node = value as? TraceNode, let stored = node.config[name] {
            return stored
        }
        if value is TraceNode {
            // Unknown store-query objects (realm.objects(...)) act like a
            // fresh empty store when iterated — the same doctrine as the
            // query-wrapper flatten.
            switch name {
            case "map", "compactMap", "filter", "sorted", "reversed":
                return .hostFunction(HostFunction(name: name) { _, _ in .native([RuntimeValue]()) })
            case "count": return .native(0)
            case "isEmpty": return .native(true)
            case "decode":
                // Decoding a blob that came from an interpreted encode
                // round-trips the ORIGINAL value; anything else fails like
                // a fresh store (nothing persisted).
                return .hostFunction(HostFunction(name: name) { args, _ in
                    if case .host(let blobAny)? = args.labeled("from") ?? args.positional(1) ?? args.positional(0),
                       let blob = blobAny as? EncodedValueBlob {
                        return blob.value
                    }
                    throw RuntimeError(message: "nothing to decode (fresh store)")
                })
            case "encode":
                // `encoder.encode(value)` captures the value as a blob.
                return .hostFunction(HostFunction(name: name) { args, _ in
                    .native(EncodedValueBlob(value: args.positional(0) ?? .void))
                })
            default: break
            }
        }
        if let bridged = bridgeHostMember(
            name, on: value, fileManager: fileManagerBox,
            applicationShells: applicationShells)
        {
            return bridged
        }
        return nil
    }

    public func fallbackHostMember(_ name: String, on value: Any) -> RuntimeValue? {
        if let bridged = bridgeFallbackHostMember(name, on: value) {
            return bridged
        }
        guard !Self.isBuilderOnlyModifier(name),
              let node = value as? TraceNode, node.absorbsUnknownMembers else {
            return nil
        }
        // Members of opaque imported objects read as memoized chained bags,
        // so `context.view.frame = x` round-trips and calls absorb. This hook
        // runs only after declared/bridged capabilities have declined.
        let fresh = RuntimeValue.native(TraceNode(
            kind: "\(node.kind).\(name)",
            absorbsUnknownMembers: true))
        node.config[name] = fresh
        return fresh
    }

    public func hostMethod(_ name: String, on value: Any) -> RuntimeValue? {
        if let platform = value as? GeneratedPlatformValue {
            return GeneratedPlatformBridge.method(name, on: platform)
        }
        return GeneratedMembers.method(name, on: value)
            ?? objcTrampolineMethod(name, on: value)
    }

    /// `Text("a") + Text("b")` — concatenation records a combined node.
    public func combineValues(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) -> RuntimeValue? {
        if let attributed = generatedAttributedTextCombination(op, lhs, rhs) {
            return attributed
        }
        guard op == "+",
              case .host(let l) = lhs, let left = l as? TraceNode,
              case .host(let r) = rhs, let right = r as? TraceNode else { return nil }
        let node = TraceNode(kind: "TextConcat")
        let leftType = left.nominalTypeName ?? left.kind
        let rightType = right.nominalTypeName ?? right.kind
        if leftType == rightType {
            node.nominalTypeName = leftType
        }
        node.children = [left, right]
        return .native(node)
    }

    public func hostSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool {
        if let node = value as? TraceNode {
            node.config[name] = newValue
            return true
        }
        if networkHostSetMember(name, on: value, to: newValue) { return true }
        return hostObjectSetMember(name, on: value, to: newValue)
    }

    public func hostMutatedCopy(
        settingMember name: String, on value: Any, to newValue: RuntimeValue
    ) throws -> Any? {
        try bridgeHostMutatedCopy(
            settingMember: name, on: value, to: newValue)
    }

    /// Recorded nodes stand for their constructor's type (UIColor(...) →
    /// "UIColor"), so user extensions of host types dispatch on them.
    public func hostTypeName(of value: Any) -> String? {
        if let node = value as? TraceNode {
            return node.nominalTypeName ?? node.kind
        }
        return bridgeHostTypeName(of: value)
    }

    public func hostProtocolCandidates(of value: Any) -> [String] {
        bridgeHostProtocolCandidates(of: value)
    }

    static func node(_ value: RuntimeValue) throws -> TraceNode {
        if case .host(let any) = value, let node = any as? TraceNode { return node }
        if case .host(let any) = value, any is PathDrawStub {
            return TraceNode(kind: "Path") // Path IS a Shape/View
        }
        if Coerce.colorLike(value) != nil {
            let node = TraceNode(kind: "Color")
            node.args = [value.stringified]
            return node
        }
        // Unknown host views reached via member calls (WishKit.
        // FeedbackListView()) render as opaque nodes — the Lottie-degrade
        // precedent for external SDK views.
        if case .host(let any) = value, let call = any as? ImplicitMemberCall,
           call.name.first?.isUppercase == true {
            return TraceNode(kind: call.name)
        }
        if case .host(let any) = value, let chain = any as? ChainedImplicitCall {
            // Modifier chains hanging off an unresolved root (an unmerged
            // asset extension's `.atSymbol` with .aspectRatio/.blendMode
            // chained) render as opaque leaf nodes named for the ROOT —
            // the Lottie-degrade precedent.
            var rootName = chain.member
            var cursor: Any? = chain
            while let c = cursor as? ChainedImplicitCall {
                if case .implicitMember(let name) = c.base { rootName = name; break }
                if case .host(let inner) = c.base { cursor = inner } else { break }
            }
            return TraceNode(kind: rootName)
        }
        throw RuntimeError(message: "expected a view, got \(value.stringified)")
    }

    static func elements(of data: RuntimeValue) throws -> [RuntimeValue] {
        // A Query-shaped `.init(filter:sort:…)` marker is a fresh store: empty.
        if case .host(let any) = data, let call = any as? ImplicitMemberCall,
           call.name == "init",
           call.arguments.labeled("filter") != nil || call.arguments.labeled("sort") != nil
            || call.arguments.labeled("sortDescriptors") != nil {
            return []
        }
        // Unknowable host collections (GraphQL fragment chains, unresolved
        // statics) iterate EMPTY — the fresh-store reading, same as for-in.
        if case .host(let any) = data,
           any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
            return []
        }
        if case .implicitMember = data { return [] }
        if case .hostFunction = data { return [] } // unresolvable member read
        if case .host(let dataAny) = data, let bytes = dataAny as? Data {
            return bytes.map { .native(Int($0)) } // Data IS a byte collection
        }
        if let range = data.rangeValue, let values = range.integerValues() {
            return values
        }
        if let elements = data.collectionElements { return elements }
        if case .instance(let instance) = data {
            // Library collection WRAPPERS (TCA's Store-of-IdentifiedArray,
            // IdentifiedArray itself): the conformance lives in the
            // unmerged runtime. An elements-shaped property iterates;
            // otherwise the fresh store reads EMPTY.
            for candidate in ["elements", "_elements", "items", "rows"] {
                if let box = instance.box(for: candidate), let array = box.value.arrayValue {
                    return array
                }
            }
            return []
        }
        throw RuntimeError(message: "ForEach needs a range or a collection, got \(data.stringified)")
    }
}
