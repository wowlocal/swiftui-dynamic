import SwiftSyntax

/// The runtime value of a `&argument` at a call site. A user function's
/// `inout` parameter aliases `box` when the argument is a plain variable
/// (mutations are live), or copies in and writes back through `target` for
/// member/subscript lvalues. Every other consumer — host functions, enum
/// inits, markers — unwraps to `current`, the value at call time, preserving
/// the old tolerated behavior for host sinks like `.store(in: &cancellables)`.
final class InoutSlot {
    let box: Box?
    let target: Interpreter.LValue?
    let current: RuntimeValue

    init(box: Box?, target: Interpreter.LValue?, current: RuntimeValue) {
        self.box = box
        self.target = target
        self.current = current
    }
}

extension RuntimeValue {
    var inoutSlot: InoutSlot? {
        if case .host(let any) = self { return any as? InoutSlot }
        return nil
    }

    var unwrappingInoutSlot: RuntimeValue {
        inoutSlot?.current ?? self
    }
}

extension CallArguments {
    /// Callees that can't write back see the value a `&argument` had at call
    /// time instead of the slot.
    func unwrappingInoutSlots() -> CallArguments {
        guard arguments.contains(where: { $0.value.inoutSlot != nil }) else { return self }
        return CallArguments(arguments: arguments.map {
            Argument(
                label: $0.label,
                value: $0.value.unwrappingInoutSlot,
                isTrailing: $0.isTrailing,
                sourceProvenance: $0.sourceProvenance)
        })
    }
}

/// Does a closure body reference `$1` outside any nested closure? Decides
/// whether a single tuple argument splats across `$0`/`$1`/… (the
/// `enumerated().forEach { rowSnapshot[$0] … $1 }` idiom) or stays whole in
/// `$0` (`flatten.map { $0.item }`) — mirroring Swift's anonymous-parameter
/// arity inference.
enum ShorthandTupleScanner {
    static func splats(_ body: CodeBlockItemListSyntax) -> Bool {
        body.contains { referencesDollarOne(Syntax($0)) }
    }

    private static func referencesDollarOne(_ node: Syntax) -> Bool {
        if node.is(ClosureExprSyntax.self) {
            return false // a nested closure's $1 is its own
        }
        if let reference = node.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text == "$1"
        }
        return node.children(viewMode: .sourceAccurate).contains { referencesDollarOne($0) }
    }
}
