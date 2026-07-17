/// One execution binding between immutable source and mutable runtime state.
///
/// The current cooperative implementation is deliberately MainActor-
/// confined. A session owns the build-resolved declaration plan plus the heap
/// and runtime capabilities needed by one async entry, while holding only a
/// weak link to the compatibility `Interpreter` facade. This makes the
/// ownership boundary real without claiming that the heap is safe to hand to
/// physical workers.
@MainActor
public final class InterpreterSession {
    public enum State: Sendable, Equatable {
        case ready
        case running
        case finished
    }

    public let program: ParsedProgram
    public let heap: RuntimeHeap
    public let id: RuntimeSessionID
    public let lazyTopLevelGlobals: Bool
    public let completionPolicy: SessionCompletionPolicy
    public private(set) var state: State = .ready

    let concurrencyRuntime: CooperativeConcurrencyRuntime
    let runtimeEntry: RuntimeEntry
    let executionPlan: ResolvedDeclarationPlan
    private weak var owner: Interpreter?

    init(
        program: ParsedProgram,
        heap: RuntimeHeap,
        concurrencyRuntime: CooperativeConcurrencyRuntime,
        executionPlan: ResolvedDeclarationPlan,
        lazyTopLevelGlobals: Bool,
        completionPolicy: SessionCompletionPolicy,
        owner: Interpreter
    ) {
        self.program = program
        self.heap = heap
        self.concurrencyRuntime = concurrencyRuntime
        self.executionPlan = executionPlan
        self.lazyTopLevelGlobals = lazyTopLevelGlobals
        self.completionPolicy = completionPolicy
        self.owner = owner
        runtimeEntry = concurrencyRuntime.createEntry(
            kind: .program, heap: heap, interpreter: owner)
        id = runtimeEntry.id
    }

    func validateExecution(on interpreter: Interpreter) throws {
        guard let owner else {
            throw RuntimeError(message:
                "interpreter session's owning interpreter was released")
        }
        guard owner === interpreter,
              heap === interpreter.runtimeHeap,
              concurrencyRuntime === interpreter.concurrencyRuntime,
              runtimeEntry.heap === interpreter.runtimeHeap,
              runtimeEntry.interpreter === interpreter else {
            throw RuntimeError(message:
                "interpreter session belongs to a different interpreter")
        }
        guard state == .ready else {
            throw RuntimeError(message:
                "interpreter session has already started")
        }
    }

    func beginExecution(on interpreter: Interpreter) throws {
        try validateExecution(on: interpreter)
        state = .running
    }

    func finishExecution() {
        precondition(
            state == .running,
            "only a running interpreter session may finish")
        state = .finished
    }
}
