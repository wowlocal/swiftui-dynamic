/// One logical entry from the host into interpreted execution.
///
/// A program root, synchronous framework callback, and SwiftUI-owned async
/// action are distinct entries even when they operate on the same program
/// heap. Every source task created by an entry retains this object, making
/// runtime identity and heap ownership an explicit capability instead of a
/// bare numeric session ID.
///
/// Entries may overlap cooperatively. Their heap remains MainActor-confined;
/// this type does not make `Environment`, `Box`, or `Instance` worker-safe.
@MainActor
final class RuntimeEntry {
    enum Kind: Sendable, Equatable {
        case program
        case hostCallback
        case swiftUITask
        case compatibilityTask
        case test
    }

    let id: RuntimeSessionID
    let kind: Kind
    let heap: RuntimeHeap?
    private(set) weak var interpreter: Interpreter?

    init(
        id: RuntimeSessionID,
        kind: Kind,
        heap: RuntimeHeap?,
        interpreter: Interpreter?
    ) {
        self.id = id
        self.kind = kind
        self.heap = heap
        self.interpreter = interpreter
    }
}
