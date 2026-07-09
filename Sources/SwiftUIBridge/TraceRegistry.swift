import Foundation
import SwiftInterpreter

/// A recorded render-tree node — what the trace registry produces instead of
/// real SwiftUI views, so tests can assert structure headlessly.
public final class TraceNode {
    public let kind: String
    public var args: [String] = []
    public var children: [TraceNode] = []
    public var modifiers: [String] = []
    public var actions: [String: ClosureValue] = [:]
    public var bindings: [String: BindingStub] = [:]
    public var environmentModels: [String: Instance] = [:]
    public var instance: Instance?
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
    public init() {}

    public func constructor(named name: String) -> HostFunction? {
        if let hostObject = bridgeHostObjectConstructor(named: name) { return hostObject }
        switch name {
        case "Text", "Image", "Spacer", "Divider", "Toggle", "TextField", "Slider":
            return HostFunction(name: name) { args, _ in
                let node = TraceNode(kind: name)
                for argument in args.arguments {
                    if case .native(let any) = argument.value, let stub = any as? BindingStub {
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
                if let content = args.closure(labeled: "content") ?? args.unlabeledClosures.last {
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
                if let content = args.unlabeledClosures.first {
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
                if let content = args.unlabeledClosures.first {
                    node.children = try ctx.callBuilderClosure(content, arguments: [seed]).map(Self.node)
                }
                return .native(node)
            }
        case "Canvas":
            // The renderer draws (side effects on the context), it doesn't
            // build children — run it with an inert context + canvas size.
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: "Canvas")
                if let renderer = args.unlabeledClosures.first {
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
                if let builder = args.unlabeledClosures.first {
                    _ = try ctx.callClosure(builder, arguments: [.native(path)])
                }
                return .native(path)
            }
        case "withAnimation":
            return HostFunction(name: name) { args, ctx in
                guard let closure = args.unlabeledClosures.first else { return .void }
                return try ctx.callClosure(closure, arguments: [])
            }
        case "ForEach":
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: "ForEach")
                guard let data = args.positional(0),
                      let content = args.closure(labeled: "content") ?? args.unlabeledClosures.last else {
                    throw RuntimeError(message: "ForEach needs data and a content closure")
                }
                // `ForEach($items) { $item in … }` — element bindings.
                let elements: [RuntimeValue]
                if case .native(let any) = data, let stub = any as? BindingStub,
                   let bindings = stub.elementBindings() {
                    elements = bindings
                } else {
                    elements = try Self.elements(of: data)
                }
                for element in elements {
                    node.children += try ctx.callBuilderClosure(content, arguments: [element]).map(Self.node)
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
                    if case .native(let any) = argument.value, let stub = any as? BindingStub {
                        node.bindings[argument.label ?? "_"] = stub
                    } else if let closure = argument.value.closureValue {
                        if argument.label == "action" {
                            node.actions["action"] = closure
                            continue
                        }
                        if let data, let elements = try? Self.elements(of: data) {
                            for element in elements {
                                node.children += try ctx.callBuilderClosure(closure, arguments: [element]).map(Self.node)
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
                        if argument.label == nil { data = argument.value }
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
            if Self.builderModifiers.contains(name) {
                for argument in args.arguments {
                    if let closure = argument.value.closureValue, closure.parameters.isEmpty {
                        node.children += try ctx.callBuilderClosure(closure, arguments: []).map(Self.node)
                    }
                }
            }
            let argText = args.arguments
                .map { ($0.label.map { "\($0): " } ?? "") + $0.value.stringified }
                .joined(separator: ", ")
            node.modifiers.append(argText.isEmpty ? name : "\(name)(\(argText))")
            return .native(node)
        }
    }

    public func isViewValue(_ value: RuntimeValue) -> Bool {
        if case .native(let any) = value, any is TraceNode { return true }
        return Coerce.colorLike(value) != nil // Color IS a View
    }

    public func makeRenderable(instance: Instance, interpreter: Interpreter) -> RuntimeValue {
        if instance.symbol.isRepresentable {
            // No body to deep-render; recorded inert.
            return .native(TraceNode(kind: "Representable:\(instance.symbol.name)"))
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
            default: break
            }
        }
        return bridgeHostMember(name, on: value)
    }

    /// `Text("a") + Text("b")` — concatenation records a combined node.
    public func combineValues(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) -> RuntimeValue? {
        guard op == "+",
              case .native(let l) = lhs, let left = l as? TraceNode,
              case .native(let r) = rhs, let right = r as? TraceNode else { return nil }
        let node = TraceNode(kind: "TextConcat")
        node.children = [left, right]
        return .native(node)
    }

    public func hostSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool {
        if let node = value as? TraceNode {
            node.config[name] = newValue
            return true
        }
        return hostObjectSetMember(name, on: value, to: newValue)
    }

    static func node(_ value: RuntimeValue) throws -> TraceNode {
        if case .native(let any) = value, let node = any as? TraceNode { return node }
        if Coerce.colorLike(value) != nil {
            let node = TraceNode(kind: "Color")
            node.args = [value.stringified]
            return node
        }
        throw RuntimeError(message: "expected a view, got \(value.stringified)")
    }

    static func elements(of data: RuntimeValue) throws -> [RuntimeValue] {
        if case .native(let any) = data, let range = any as? Range<Int> {
            return range.map { .native($0) }
        }
        if let array = data.arrayValue { return array }
        throw RuntimeError(message: "ForEach needs a range or an array, got \(data.stringified)")
    }
}
