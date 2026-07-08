import SwiftInterpreter

/// A recorded render-tree node — what the trace registry produces instead of
/// real SwiftUI views, so tests can assert structure headlessly.
public final class TraceNode {
    public let kind: String
    public var args: [String] = []
    public var children: [TraceNode] = []
    public var modifiers: [String] = []
    public var actions: [String: ClosureValue] = [:]
    public var instance: Instance?

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
        switch name {
        case "Text", "Image", "Spacer", "Divider":
            return HostFunction(name: name) { args, _ in
                let node = TraceNode(kind: name)
                node.args = args.arguments.compactMap { argument in
                    argument.value.closureValue == nil ? argument.value.stringified : nil
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
        case "ForEach":
            return HostFunction(name: name) { args, ctx in
                let node = TraceNode(kind: "ForEach")
                guard let data = args.positional(0),
                      let content = args.closure(labeled: "content") ?? args.unlabeledClosures.last else {
                    throw RuntimeError(message: "ForEach needs data and a content closure")
                }
                for element in try Self.elements(of: data) {
                    node.children += try ctx.callBuilderClosure(content, arguments: [element]).map(Self.node)
                }
                return .native(node)
            }
        default:
            return nil
        }
    }

    public func modifier(named name: String) -> HostModifier? {
        HostModifier(name: name) { value, args, _ in
            let node = try Self.node(value)
            let argText = args.arguments
                .map { ($0.label.map { "\($0): " } ?? "") + $0.value.stringified }
                .joined(separator: ", ")
            node.modifiers.append(argText.isEmpty ? name : "\(name)(\(argText))")
            return .native(node)
        }
    }

    public func isViewValue(_ value: RuntimeValue) -> Bool {
        if case .native(let any) = value { return any is TraceNode }
        return false
    }

    public func makeRenderable(instance: Instance, interpreter: Interpreter) -> RuntimeValue {
        let node = TraceNode(kind: "View:\(instance.symbol.name)")
        node.instance = instance
        return .native(node)
    }

    public func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue {
        let node = TraceNode(kind: "Group")
        node.children = try views.map(Self.node)
        return .native(node)
    }

    static func node(_ value: RuntimeValue) throws -> TraceNode {
        if case .native(let any) = value, let node = any as? TraceNode { return node }
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
