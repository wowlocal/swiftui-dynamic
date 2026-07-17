/// One logical entry from the host into interpreted execution.
///
/// A program root, synchronous framework callback, and SwiftUI-owned async
/// action are distinct entries even when they operate on the same program
/// heap. Every source task created by an entry retains this object, making
/// runtime identity, immutable program metadata, mutable program registries,
/// and heap ownership an explicit capability instead of a bare numeric
/// session ID.
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
    let programState: RuntimeProgramState?
    let programPlan: ResolvedProgramPlan?
    let programMetadata: ParsedProgramMetadata?
    var callableMetadataIndex: ParsedCallableMetadataIndex? {
        programMetadata?.callableMetadataIndex
    }
    private(set) weak var interpreter: Interpreter?

    init(
        id: RuntimeSessionID,
        kind: Kind,
        heap: RuntimeHeap?,
        programState: RuntimeProgramState?,
        programPlan: ResolvedProgramPlan?,
        programMetadata: ParsedProgramMetadata?,
        interpreter: Interpreter?
    ) {
        self.id = id
        self.kind = kind
        self.heap = heap
        self.programState = programState
        if let statePlan = programState?.programPlan, let programPlan {
            precondition(
                statePlan === programPlan,
                "runtime entry program state and plan must match")
        }
        self.programPlan = programPlan
        self.programMetadata = programPlan?.metadata ?? programMetadata
        self.interpreter = interpreter
    }
}
