import Darwin
import Foundation
import SwiftInterpreter

/// A recorded render-tree node — what the trace registry produces instead of
/// real SwiftUI views, so tests can assert structure headlessly.
public final class TraceNode: InertCallable {
    public let kind: String
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
    public var lifecycle: [ClosureValue] = []
    /// Opaque host objects (`UIPanGestureRecognizer()`, …) are recorded as
    /// nodes but behave like the mutable objects they stand for: property
    /// writes land here and read back (`gesture.name = id … gesture.name`).
    public var config: [String: RuntimeValue] = [:]

    init(kind: String) {
        self.kind = kind
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

    public init() {}

    public func absorbedCValue(named name: String) -> RuntimeValue? {
        .native(TraceNode(kind: name)) // writable bag: out-params fill
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

    public func publishedProjection(current: RuntimeValue) -> RuntimeValue? {
        guard case .replay = NetworkBridge.policy else { return nil }
        return .native(ValuePublisherBox(.success(current)))
    }

    public func constructor(named name: String) -> HostFunction? {
        if let hostObject = bridgeHostObjectConstructor(named: name) { return hostObject }
        if name == "UserDefaults" || name == "NSUserDefaults" {
            return ObjCTrampoline.constructor(named: name)
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
                    let rows: [RuntimeValue]
                    if let interpreter = ctx as? Interpreter {
                        rows = try interpreter.withViewIdentitySalt(salt) {
                            try ctx.callBuilderClosure(content, arguments: [element])
                        }
                    } else {
                        rows = try ctx.callBuilderClosure(content, arguments: [element])
                    }
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
                let node = TraceNode(kind: name)
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
                                let rows: [RuntimeValue]
                                if let interpreter = ctx as? Interpreter {
                                    rows = try interpreter.withViewIdentitySalt(salt) {
                                        try ctx.callBuilderClosure(closure, arguments: [element])
                                    }
                                } else {
                                    rows = try ctx.callBuilderClosure(closure, arguments: [element])
                                }
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
                        node.args.append(argument.value.stringified)
                    }
                }
                return .native(node)
            }
        }
    }

    /// Modifiers whose closure arguments are ViewBuilders (never actions) —
    /// trace mode evaluates them unconditionally so presented/deferred content
    /// (sheet bodies, alert buttons, tab items) still gets deep coverage.
    private static let builderModifiers: Set<String> = [
        "sheet", "alert", "confirmationDialog", "popover",
        "tabItem", "overlay", "background", "safeAreaInset", "toolbar",
    ]

    public func modifier(named name: String) -> HostModifier? {
        HostModifier(name: name) { value, args, ctx in
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
            if name == "task" || name == "onAppear",
               let closure = args.arguments.compactMap({ $0.value.closureValue }).first,
               closure.parameters.isEmpty {
                node.lifecycle.append(closure)
            }
            if Self.builderModifiers.contains(name) {
                // `sheet(item: $route) { $0.makeSheetView() }` — the content
                // BINDS the item: it evaluates only when the binding holds a
                // value, receiving it (nil = not presented, like device).
                let itemValue: RuntimeValue? = args.labeled("item").map { item in
                    if case .host(let any) = item, let stub = any as? BindingStub {
                        return stub.box.value
                    }
                    return item
                }
                for argument in args.arguments {
                    guard let closure = argument.value.closureValue else { continue }
                    if let item = itemValue {
                        guard !item.isNil else { continue }
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

    /// Constructed host OBJECTS (UIPanGestureRecognizer(), AVPlayer(), …)
    /// vs recorded views: UIKit-ish constructor prefixes get property-bag
    /// member semantics; view kinds keep modifier chaining.
    static func isHostObjectKind(_ kind: String) -> Bool {
        for prefix in ["UI", "NS", "CA", "AV", "CL", "MK", "WK", "SK", "PH"]
        where kind.hasPrefix(prefix) && kind.count > 2 {
            return true
        }
        return false
    }

    public func hostProperty(named name: String, on value: Any) -> HostProperty? {
        bridgeHostProperty(name, on: value)
    }

    public func hostMember(_ name: String, on value: Any) -> RuntimeValue? {
        if let node = value as? TraceNode, let stored = node.config[name] {
            return stored
        }
        if let node = value as? TraceNode, Self.isHostObjectKind(node.kind) {
            // Members of hosted objects read as memoized chained bags, so
            // `context.view.frame = x` round-trips and calls absorb.
            let fresh = RuntimeValue.native(TraceNode(kind: "\(node.kind).\(name)"))
            node.config[name] = fresh
            return fresh
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
        return bridgeHostMember(name, on: value)
    }

    /// `Text("a") + Text("b")` — concatenation records a combined node.
    public func combineValues(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) -> RuntimeValue? {
        guard op == "+",
              case .host(let l) = lhs, let left = l as? TraceNode,
              case .host(let r) = rhs, let right = r as? TraceNode else { return nil }
        let node = TraceNode(kind: "TextConcat")
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

    public func hostMutatedCopy(settingMember name: String, on value: Any, to newValue: RuntimeValue) -> Any? {
        bridgeHostMutatedCopy(settingMember: name, on: value, to: newValue)
    }

    /// Recorded nodes stand for their constructor's type (UIColor(...) →
    /// "UIColor"), so user extensions of host types dispatch on them.
    public func hostTypeName(of value: Any) -> String? {
        if let node = value as? TraceNode { return node.kind }
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
