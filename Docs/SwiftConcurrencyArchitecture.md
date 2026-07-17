# Swift Concurrency: Target Architecture and Native-Parity Plan

Status: normative target design; live implementation status is tracked in
`ConcurrencyParity.md` and the machine-checked milestone acceptance manifest
Scope: `SwiftInterpreter`, host gateways, SwiftUI lifecycle integration, and
native differential verification
Primary compatibility target: Swift 6 as implemented by the active Apple
toolchain

Operational verification rules, evidence workflows, process-isolation policy,
and milestone closure criteria live in
[`ConcurrencyVerificationMethodology.md`](ConcurrencyVerificationMethodology.md).
The target architecture is intentionally not rewritten as a chronological
implementation log.

## 1. Purpose

This document defines the stable architectural foundation required for the
interpreter to approach real Swift Concurrency semantics. It is both:

1. a target architecture specification; and
2. an execution contract for an autonomous GOAL agent implementing the design.

The objective is not merely to parse concurrency syntax or make common source
files stop failing. The objective is to reproduce the observable guarantees of
compiled Swift wherever practical, and to identify every remaining divergence
explicitly.

Every semantic claim must be verified against a minimal program compiled and
executed by the real `swiftc`. Documentation, recollection, existing
interpreter behavior, and scheduler observations are not sufficient sources of
truth by themselves.

## 2. Executive summary

The implementation has completed the first ownership migration: every source
task has an `EvaluationTaskContext`, and the shared parked-frame protocol has
been removed. A cooperative runtime now owns task IDs/records, typed outcomes,
wait edges, cancellation state, priorities, task locals, clocks, suspension
reasons, async-let scopes, and the currently covered task-group semantics.
`ConcurrencyParity.md` records the exact supported subset and known gaps.

This is a strong migration base, but it is not yet the full target concurrency
runtime. Source execution is still driven by native Swift tasks/continuations,
the interpreter still combines program/session/heap responsibilities. A
runtime-owned mailbox now serializes actor-function segments and releases a
complete depth-counted segment across canonical runtime waits before queuing
the same task to reacquire it on resume. There is still no general runnable-
executor queue. M6 now includes a bounded checked-continuation registry for
the explicit-`nil` isolation, `resume(returning:)` value slice; each active
record is owned by one task, names its required resume executor, uses the
canonical suspension lease, and is removed on success or infrastructure abort.
M6 began with protocol-driven
`for await` over interpreted witnesses, including suspending mutating iterator
copy-out, typed source-error propagation, and cooperative user-iterator
cancellation. Early `break` and its per-iteration `defer` cleanup are also
covered together with `continue` and `return` cleanup; protocol-extension
defaults for both requirements are covered as well. Host-backed sequences,
including typed opaque gateways with tracked host suspension, are covered as
well. Both stream flavors' evidenced cancellation, buffering, iterator-copy,
and lifetime tails are covered. Throwing/unsafe continuations, broader
isolation and resume spellings, and checked-continuation diagnostic/lifetime
edges remain open. The remaining
Task API work is a
bounded M4/M7 closeout tail. The next major runtime cycle is actor/executor
architecture built on scheduler/session ownership, not broader
name-dispatched Task API surface.

The stable target separates five concerns:

```text
Immutable ParsedProgram
          │
          ▼
InterpreterSession ─────────────── HostGatewayRuntime
          │                               │
          ├── RuntimeHeap                 │
          │     ├── globals               │
          │     ├── class storage         │
          │     └── actor storage         │
          │                               │
          └── ConcurrencyRuntime ◀────────┘
                ├── TaskRecord graph
                ├── StructuredScope graph
                ├── Executor registry
                ├── Cancellation state
                ├── Clock
                └── Continuation registry
                         │
                         ▼
                EvaluationTaskContext
                ├── lexical environments
                ├── evaluator frames
                ├── type-context stacks
                ├── task locals
                ├── current executor
                └── evaluation budget
```

The first two mandatory architectural changes—task-owned evaluator context and
a real logical task runtime—are implemented for the ledgered subset. M2 now
includes weak ownership proof that an escaped completed handle releases its
session and native driver. M3 now includes seeded, exactly replayable
cancellation-race exploration; terminal outcome and cancellation remain
independent dimensions.

Actors and global actors are built on top of the task runtime and executor
model. They are not special classes and cannot be implemented faithfully as
name-based gateways.

Compiler-enforced isolation and `Sendable` diagnostics should not be
reimplemented from scratch unless unavoidable. The target design uses the real
Swift compiler as a semantic preflight layer, fed by generated host declaration
stubs. Runtime executor enforcement remains necessary even after successful
type checking.

Physical parallelism is deliberately last. Most Swift Concurrency semantics do
not promise parallel execution. A deterministic cooperative executor can first
provide correct task lifetime, suspension, cancellation, actor serialization,
and reentrancy without introducing data races into the existing mutable runtime
heap.

## 3. Compatibility doctrine

### 3.1 The native compiler is the oracle

For each behavior under development, the implementation process begins with a
standalone Swift probe compiled using the active `swiftc` in Swift 6 mode. The
probe establishes one of the following kinds of facts:

- an exact deterministic result;
- a set of permitted results;
- a partial ordering or happens-before relationship;
- a runtime error or cancellation outcome;
- a compile-time diagnostic;
- behavior for which Swift deliberately provides no guarantee.

The interpreter test must assert only the guarantee established by the probe.
It must not accidentally encode the current scheduling order of one toolchain
run.

### 3.2 Same program whenever possible

Native and interpreted execution should consume the same source fixture. When
the probe needs a controllable suspension primitive, both runners may supply a
small host wrapper with the same Swift declaration and observable semantics.
Any unavoidable wrapper difference must be recorded next to the test.

### 3.3 Semantics, not scheduler imitation

Swift does not specify which of two ready tasks starts first in many cases.
Exact trace equality is therefore valid only when ordering is forced by:

- program order within one task;
- an awaited result;
- actor serialization;
- a continuation/barrier controlled by the probe;
- a documented structured-concurrency rule.

Otherwise tests compare invariants or an allowed set of traces.

### 3.4 No silent support

Every concurrency feature has one explicit status:

- `native-parity`: covered behavior matches the established native guarantee;
- `partial`: a documented subset is implemented;
- `compatibility-only`: accepted to keep an existing synchronous client alive,
  but not Swift-equivalent;
- `compile-time-only`: checked by compiler preflight and erased at runtime;
- `unsupported`: diagnosed clearly;
- `intentionally-divergent`: a justified divergence with a regression test.

An absorbed marker, inert callback, immediate fake result, or swallowed error
never counts as support.

### 3.5 Differential tests are permanent assets

Once a native probe establishes a rule, it becomes a committed fixture. A
handwritten expected value without the native source is insufficient evidence.
Toolchain identity is persisted by every closing parity gate so SDK or compiler
changes can be audited rather than silently accepted. Focused parity tests
validate the active toolchain but are not historical receipts.

## 4. Current architecture and its ceiling

### 4.1 Package-wide main-actor isolation

The package currently applies `defaultIsolation(MainActor.self)` broadly. This
protects the mutable interpreter and fits SwiftUI, but it also means all source
tasks ultimately execute through one native actor. Interleaving is possible at
suspension points; physical parallelism is not.

Keeping the interpreter on the main actor is acceptable during the cooperative
executor phases. It must not be confused with source-level `@MainActor`
semantics: a source actor and the native actor hosting the interpreter are
different abstraction layers.

Source-visible host APIs must observe the logical source executor when the
physical hosting actor is only an interpreter implementation detail. For
example, a toolchain-characterized `Thread.isMainThread` read in supported
`@concurrent`/`@MainActor` code projects logical MainActor membership during the
cooperative phase; returning the evaluator's physical thread would collapse
the two abstraction layers. This projection does not claim physical
parallelism.

Eventually the targets should separate:

- `SwiftInterpreterCore`: executor-neutral runtime and evaluator;
- `SwiftUIBridge`: `@MainActor`-isolated UI integration;
- host adapters: isolation determined by their declared contracts.

This split happens only after runtime ownership is explicit.

### 4.2 Task-owned evaluator state; shared session state remains

Step/call-depth counters, active declarations and recursion guards, lexical
owner frames, type/return context, temporary async identifiers, task locals,
priority, current logical executor, and structured-scope frames now belong to
one `EvaluationTaskContext`. Host callbacks carry that context explicitly, and
task completion clears it. `withParkedEvaluatorFrames` no longer exists.

The remaining ceiling is one level higher: `Interpreter` still combines
parsed declarations, global/runtime heap state, scheduled task handles, and the
cooperative runtime. Overlapping sessions on one interpreter would therefore
share mutable program/global state even though their per-task dynamic state is
independent. The target `ParsedProgram`/`InterpreterSession`/`RuntimeHeap`
separation remains required before executor-neutral or parallel operation.

### 4.3 Async overlay over synchronous evaluation

The async evaluator currently identifies suspension-bearing roots, evaluates
them asynchronously, rewrites the eager expression with temporary values, and
delegates the remainder to mature synchronous machinery. This successfully
reuses operator, assignment, lvalue, and member semantics.

Task-owned structured frames now cover the ledgered async-let, task-group,
iteration, cancellation-handler, and `defer` combinations. The overlay still
becomes progressively harder to extend for constructs requiring a runtime-owned
resume point or executor queue:

- actor executor hops;
- continuations;
- stream producer/consumer suspension and continuation-backed sequences;
- runtime-controlled scheduling and replay.

The target evaluator must represent suspension as a first-class execution
outcome and preserve one task-owned frame stack across it.

### 4.4 Logical task values and driver detachment are implemented

`RuntimeTaskHandle` now exposes runtime-owned IDs, typed logical outcomes,
suspending `value`/`result`, multiple waiters, task-kind and structured-scope
relationships, task-local/priority/executor inheritance, and explicit
cancellation state. Incomplete reads do not return placeholders.

When active bookkeeping releases a completed task, its escaped source handle
switches to a compact value-only snapshot and drops the runtime record, session,
and native driver. Weak-reference coverage proves those execution resources
deallocate. The snapshot retains the typed immutable outcome and a separate
cancellation state, so later reads remain stable and late source `cancel()`
updates the handle flag without changing its terminal outcome.

### 4.5 Actors have runtime identity and a suspension-aware mailbox foundation

Actor declarations retain reference semantics and their nominal actor kind.
Each source actor instance now receives a distinct runtime actor ID with a
non-owning lifetime record. A synchronous actor initializer runs in its
lexically nonisolated context, initializes the new instance's storage without
an executor hop, and leaves subsequent isolated entry to the registered
mailbox. Synchronous and async isolated functions acquire a
depth-counted lease on that actor record before entering its logical executor.
A canonical host, task, clock, or group wait parks the complete nested segment,
hands ownership to another waiter, and queues the suspended task on that actor
before source evaluation resumes. A competing source task records
`.waitingForActor`; explicit executor hops park the caller actor before entering
a different actor. An explicit `nonisolated` method inherits its caller instead.
A function
annotated with a collected user-defined global actor lazily resolves the
declaration's canonical `static shared` actor and enters that same logical
identity. Mutable stored-property read/write funnels require the matching
runtime-task lease. Native Swift 6 probes establish that ordinary immutable
actor `let` storage and explicitly nonisolated storage remain directly
readable, so neither is over-guarded. An externally awaited synchronous
computed-property getter enters through the same actor mailbox for its complete
accessor segment; explicit `nonisolated` accessor metadata remains outside that
entry. A synchronous computed setter does not synthesize an external hop:
native Swift rejects external mutation even with `await`, so the shared
accessor context requires the caller to already own the receiver actor. An
externally awaited synchronous subscript getter uses that same mailbox and
accessor context after evaluating its base once and its indices before the hop;
an explicit `nonisolated` subscript stays on the caller executor. A synchronous
subscript setter also uses the common accessor context and requires an
already-owned actor segment. Native Swift rejects external subscript mutation
even when it is prefixed with `await`; no setter hop is synthesized. A
cross-actor throwing-function call parks the caller actor, owns the callee for
its throwing segment, releases the callee on error, and restores the caller
before source `catch` handling continues. If cancellation is requested while
that callee is suspended, the task reacquires the callee before observing
cancellation, then performs the same balanced callee release and caller
restoration before typed catch handling.

Computed getter declarations retain their `async` and `throws` effects. An
awaited async actor getter executes through a suspension-aware accessor context
rather than the eager member evaluator. If cancellation is requested while
that getter is suspended, the task first reacquires the receiver actor, then
observes cancellation and balances receiver release plus caller-actor
restoration before source `catch` handling. Normal return and a typed
source-thrown error after controlled suspension use the same
reacquire-before-exit path and restore the caller before its next source
statement or catch handling. Canonical async sessions reject an eager entry
into an async getter instead of silently running it synchronously.

Subscript getter declarations likewise retain their `async` and `throws`
effects. Awaited user-subscript dispatch selects the same suspension-aware
accessor context for actor instances, ordinary interpreted instances, and host
extension receivers; only a receiver actor adds mailbox acquisition. A
cancelled async-throwing actor subscript getter reacquires that mailbox before
observing cancellation, then balances target release and caller restoration.
After controlled suspension, normal return and a typed source-thrown error use
the same reacquire-before-exit path and restore the caller before its next
source statement or catch handling.
Canonical async sessions reject eager async-subscript entry.

This establishes runtime-owned synchronous prefixes plus controlled
release/interleaving/reacquisition for async actor messages. It is not yet
complete actor isolation. Remaining actor work includes the per-feature
compile-time restrictions on access. Struct- and enum-backed user global
actors now resolve an arbitrary source-actor `static shared` capability through
`#isolation` and defaulted isolated-parameter dispatch; function-value
isolation reflection remains the separate bounded gap described in section
6.10.

Mailbox/reentrancy stress is now replayable and covered: an exact same-source
fixture anchors Swift's terminal invariants, while a 64-seed interpreter board
varies fanout, repeated rounds, pre-entry yielding, and post-barrier resume
yields. It checks actor ownership after every resumed segment, exactly one
mutation per message, complete child collection, and empty task, actor, scope,
group, host-operation, and scheduler registries. It deliberately makes no FIFO,
child-order, physical-thread, or cross-actor-parallelism claim.

These rules belong to the concurrency runtime and semantic preflight, not the
ordinary class member dispatcher.

### 4.6 Synchronous compatibility is intentionally divergent

The synchronous renderer cannot await source work. It currently preserves
legacy behavior by executing one task body inline and bounding recursive
background work. This should remain available while existing SwiftUI and
embedding paths migrate, but it must be an explicit compatibility policy.

Canonical concurrency semantics belong to `runAsync`. New features must not
silently take the synchronous compatibility route.

## 5. Design principles

### 5.1 Ownership before concurrency surface

Every mutable value must have an owner:

- task-local evaluator state is owned by `EvaluationTaskContext`;
- class state is owned by the runtime heap;
- actor state is owned by its actor executor;
- SwiftUI state is owned by the main actor and view identity store;
- structured children are owned by a structured scope;
- continuations are owned by the suspended task record.

If ownership cannot be named, the feature is not ready for implementation.

### 5.2 One semantic core

There must not be separate, drifting implementations of assignment, lvalue
write-back, optionals, operators, and member access for sync and async code.
Those operations remain shared pure or non-suspending kernels. The execution
driver decides whether a suspension is legal and how to resume afterward.

### 5.3 Explicit execution context

Evaluator functions receive or operate through an explicit task context. A
hidden global or process-wide `@TaskLocal` may be used as an integration aid,
but it must not be the sole source of truth. Explicit context is required for
host callbacks, nested interpreter sessions, deterministic tests, and later
executor separation.

### 5.4 Cooperative correctness before parallelism

The first executor implementation may run all interpreter instructions on one
native actor. It must still model:

- distinct source tasks;
- suspension and wake-up;
- structured lifetime;
- cancellation;
- executor ownership;
- actor reentrancy.

This supplies most observable guarantees while preventing data races in the
current heap representation.

### 5.5 Compiler diagnostics and runtime semantics are separate

The compiler answers whether source is legal. The runtime answers how legal
source executes. A successful compiler preflight does not replace executor
enforcement; runtime enforcement does not attempt to produce every compiler
diagnostic.

### 5.6 No app-specific fixes

No concurrency implementation may dispatch on application names, source file
names, literal strings, or one probe's symbol names. A fix must operate on the
language construct or runtime abstraction represented by the probe.

### 5.7 Bounded execution and cleanup

Every task, continuation, stream, group, and actor message must have bounded
test behavior and defined cleanup. Tests use process timeouts. Session teardown
must not leave native tasks retaining interpreter sessions.

## 6. Target component model

### 6.1 `ParsedProgram`

`ParsedProgram` is immutable after construction and safe to share across source
tasks. It contains:

- the parsed and operator-folded syntax tree;
- declaration and extension tables;
- protocol/conformance metadata;
- function and initializer metadata;
- source locations;
- effect/isolation annotations;
- generated host declaration identities;
- compiler-preflight result and toolchain fingerprint.

Conceptual interface:

```swift
public struct ParsedProgram: Sendable {
    let syntax: SourceFileSyntax
    let declarations: DeclarationIndex
    let callMetadata: CallMetadataIndex
    let isolationMetadata: IsolationIndex
    let sourceLocations: SourceLocationIndex
    let compilerFingerprint: CompilerFingerprint?
}
```

SwiftSyntax values may require an internal immutable wrapper rather than direct
`Sendable` conformance. The semantic requirement is immutability and absence of
task-specific state.

### 6.2 `InterpreterSession`

An `InterpreterSession` binds one parsed program to one runtime heap and
concurrency runtime. Separate sessions do not share mutable globals unless an
explicit host resource is injected.

```swift
public final class InterpreterSession {
    let program: ParsedProgram
    let heap: RuntimeHeap
    let concurrency: ConcurrencyRuntime
    let host: HostGatewayRuntime?
    let policy: SessionPolicy
}
```

The existing public `Interpreter` facade may initially own or forward to a
session to preserve API compatibility.

### 6.3 `RuntimeHeap`

The runtime heap contains long-lived language storage:

- global bindings and lazy globals;
- class instances;
- actor instances;
- captured closure environments;
- persistent SwiftUI state cells;
- explicitly shared host carriers.

The heap does not contain call stacks, expected-type stacks, cancellation
state, or current-executor state.

During cooperative execution, the heap can remain main-actor confined. Before
parallel execution, every heap access must be classified as:

- immutable and `Sendable`;
- actor/executor confined;
- protected by a synchronization primitive;
- copied across the boundary;
- rejected as non-`Sendable`.

### 6.4 `EvaluationTaskContext`

Every source task owns exactly one context:

```swift
struct EvaluationTaskContext {
    let taskID: RuntimeTaskID
    var frames: [EvaluationFrame]
    var currentEnvironment: EnvironmentID
    var lexicalOwners: [DeclarationOwnerID]
    var expectedAnnotations: [RuntimeType?]
    var returnAnnotations: [RuntimeType?]
    var activeDeclarations: ActiveDeclarationSet
    var stepBudget: EvaluationBudget
    var currentExecutor: RuntimeExecutorID
    var currentActor: RuntimeActorID?
    var taskLocals: TaskLocalMap
    var priority: RuntimeTaskPriority
    var cancellation: CancellationView
}
```

The precise representation may evolve, but the ownership boundary is
non-negotiable. No task-specific stack remains on the shared `Interpreter`.

### 6.5 `EvaluationFrame` and suspension

The stable long-term evaluator uses explicit frames rather than relying on a
single shared collection of dynamic stacks. A machine step produces one of:

```swift
enum EvaluationStep {
    case continueRunning
    case suspend(RuntimeSuspension)
    case completed(RuntimeValue)
    case failed(RuntimeFailure)
}
```

`RuntimeSuspension` describes why the task cannot continue:

```swift
enum RuntimeSuspension {
    case awaitingTask(RuntimeTaskID)
    case awaitingHost(HostOperationID)
    case sleeping(ClockDeadline)
    case yielding
    case waitingForActor(RuntimeActorID)
    case waitingForGroup(RuntimeTaskGroupID)
    case waitingForStream(RuntimeAsyncStreamID)
    case waitingForContinuation(RuntimeContinuationID)
}
```

The concurrency runtime registers the waiter, changes the task state, and
reschedules the same context when the suspension resolves.

A staged implementation may retain recursive async evaluator functions while
introducing `EvaluationTaskContext`. The explicit frame machine remains the
target because it also solves native call-stack depth, pause/resume inspection,
and deterministic scheduler testing.

### 6.6 `ConcurrencyRuntime`

The concurrency runtime owns task and executor lifecycle, not language values
in general.

Responsibilities:

- create tasks;
- establish inheritance and structured scopes;
- schedule runnable task contexts;
- suspend and wake tasks;
- complete task results;
- notify waiters;
- propagate cancellation;
- manage clocks and continuations;
- route work to actor/global executors;
- enforce task and continuation limits;
- tear down a session safely.

Conceptual interface:

```swift
protocol ConcurrencyRuntime: AnyObject {
    func createTask(
        kind: RuntimeTaskKind,
        parent: RuntimeTaskID?,
        scope: RuntimeStructuredScopeID?,
        inheritedFrom context: EvaluationTaskContext,
        operation: ClosureValue
    ) throws -> RuntimeTaskID

    func suspend(
        _ task: RuntimeTaskID,
        for reason: RuntimeSuspension
    )

    func complete(
        _ task: RuntimeTaskID,
        with outcome: RuntimeTaskOutcome
    )

    func cancel(_ task: RuntimeTaskID, source: CancellationSource)
}
```

The implementation may itself be a native actor while execution remains
cooperative.

### 6.7 `RuntimeTaskRecord`

```swift
struct RuntimeTaskRecord {
    let id: RuntimeTaskID
    let kind: RuntimeTaskKind
    let parent: RuntimeTaskID?
    let structuredScope: RuntimeStructuredScopeID?
    var state: RuntimeTaskState
    var context: EvaluationTaskContext?
    var outcome: RuntimeTaskOutcome?
    var waiters: Set<RuntimeTaskID>
    var spawnedTasks: Set<RuntimeTaskID>
    var structuredChildren: Set<RuntimeTaskID>
    var cancellation: RuntimeCancellationState
    var taskLocals: TaskLocalMap
    var basePriority: RuntimeTaskPriority
    var effectivePriority: RuntimeTaskPriority
    var executorPreference: RuntimeExecutorID?
}
```

`parent` and `spawnedTasks` describe creation/inheritance lineage. They do not
imply structured ownership: an unstructured `Task {}` may have a creator while
remaining outside that creator's cancellation and scope-exit graph. Only
`structuredChildren`, populated by constructs such as `async let` and task
groups, is a cancellation-propagation edge. Detached tasks have no parent.
Both sets contain IDs rather than retaining task records, so an escaped handle
can preserve lineage for inspection without keeping completed session work
alive.

Task kinds are semantically distinct:

```swift
enum RuntimeTaskKind {
    case root
    case unstructured
    case detached
    case asyncLet
    case groupChild
    case hostCallback
    case swiftUITask
}
```

Task context inheritance, the operation executor, and task start policy are
separate semantic axes:

```swift
enum RuntimeTaskContextInheritance {
    case inherited
    case detached
}

enum RuntimeTaskStartPolicy {
    case enqueued
    case immediate
}

struct RuntimeTaskLaunchSemantics {
    let contextInheritance: RuntimeTaskContextInheritance
    let operationExecutor: RuntimeExecutorKind
    let startPolicy: RuntimeTaskStartPolicy
}
```

Context inheritance determines creation lineage and task-local state; it does
not turn an unstructured task into a structured cancellation child. The
operation executor comes from the closure's actor isolation and is not derived
from detached versus inherited lineage. Start policy determines only when
execution begins. An enqueued task begins through the executor queue. An
immediate task runs the operation's synchronous prefix on its selected actor
before the constructor returns, then follows the ordinary suspension and
resumption machinery after the first real suspension.

These axes must compose rather than be inferred from an API spelling.
`Task.immediate` is inherited context plus the operation's executor plus
immediate start. `Task.immediateDetached` changes only the first component to
detached context; its `_inheritActorContext(always)` operation retains its own
actor. The runtime creates and registers the task record before either launch.
Its native driving task uses `Task.immediateDetached` for the detached
combination; implementing that form with native `Task.immediate` would
accidentally inherit native task-local context even if the logical record were
marked detached. Both forms otherwise share outcome publication, waiters,
cleanup, name, priority, and source-handle behavior.

The operation executor is lexical metadata, not a snapshot of the executor on
which a closure expression happened to be evaluated. A plain nonisolated
factory invoked by a `MainActor` caller still forms a nonisolated closure.
Dynamic caller inheritance would silently misclassify it as `MainActor`, so
the evaluator carries a task-owned stack of statically known declaration
executors, stores that proof on closure expressions, and fails closed when the
lexical actor is unknown.

Immediate launch also makes the logical cancellation record authoritative
before a native driver can be attached. A task-group child may inherit
`cancelAll()` before `Task.immediate` starts its synchronous prefix, while the
native task handle is not returned until that prefix suspends or completes.
`Task.isCancelled`, `Task.checkCancellation()`, cancellable-suspension
prechecks, and cancellation handlers consult the logical record during that
interval. Attachment then forwards the recorded request to the native driver.

Until arbitrary executor queues and actor-resumption ownership are supplied by
M5, the ledgered incremental implementation claims only an explicit-`nil`
`TaskExecutor` preference with an operation inherited from `MainActor`.
Non-`nil` preferences and arbitrary `@isolated(any)` operation actors fail
closed; they must not be approximated by discarding the preference or running
on the interpreter's physical hosting actor.

The source-level task value refers to `RuntimeTaskID`; it does not directly
expose or own the native Swift task used to drive the runtime.

Dropping the last source-level task value does not request cancellation and
does not shorten an active task's operation. The runtime/session or structured
scope retains active execution independently until a terminal outcome. Once
bookkeeping has released a completed task from the active registry, an escaped
source handle may still retain access to that task's immutable outcome without
retaining the interpreter session or native driver.

### 6.8 Task result and failure model

The task outcome retains logical generic types even though storage is dynamic:

```swift
enum RuntimeTaskOutcome {
    case success(RuntimeValue, successType: RuntimeType)
    case failure(RuntimeValue, failureType: RuntimeType)
    case cancelled
}
```

`await task.value`:

- returns immediately only when the task has completed successfully;
- suspends the current task otherwise;
- resumes on the current task's required executor;
- throws or traps according to the task's failure contract;
- observes cancellation according to native behavior established by a probe.

`task.result` produces the corresponding result value without inventing a
placeholder for an incomplete task.

Both properties remain suspending language operations after the task has
completed. Source that omits `await` must be diagnosed; synchronous native
member dispatch is never a compatibility path for reading either an incomplete
or a completed task handle.

The first completed read does not consume an outcome. Later `value` and
`result` reads reproduce the same stored logical success or failure, including
its interpreted payload and nominal type. Active-registry cleanup may release
session ownership while an escaped handle retains this immutable outcome.

### 6.9 Structured scopes

An explicit structured scope owns `async let` and task-group children:

```swift
struct RuntimeStructuredScope {
    let id: RuntimeStructuredScopeID
    let ownerTask: RuntimeTaskID
    let kind: RuntimeStructuredScopeKind
    var children: Set<RuntimeTaskID>
    var pendingResults: Deque<RuntimeTaskID>
    var cancellation: RuntimeCancellationState
    var firstFailure: RuntimeTaskOutcome?
}
```

Scope exit executes the native rule established for the construct:

- await outstanding children;
- cancel children;
- propagate an error;
- discard or retain completed values.

These rules are not shared blindly between `async let` and task groups. Each is
verified with compiled probes for normal return, early return, throw, parent
cancellation, and child cancellation.

Task-group cancellation retains its reasons rather than collapsing them into
one anonymous Boolean. An explicit `cancelAll` request and cancellation of the
owning task both make an active group cancelled, but they remain distinct
runtime facts and produce distinct cancellation sources on children. Existing
children receive structured-parent propagation from the task graph. A child
added later through ordinary `addTask` starts with every already-active group
cancellation reason, while `addTaskUnlessCancelled` checks the combined state
before allocating a child record.

The committed active-owner and pre-cancelled-owner probes establish that
combined state, conditional-add decision, and late-child inheritance. Group
creation snapshots an already-requested owner cancellation before exposing the
source capability, while later owner cancellation updates every active owned
group through the runtime identity graph.

Nonthrowing and throwing task groups share one scheduler, completion log,
structured scope, cancellation graph, and cleanup path. Their runtime record
retains an immutable kind because successful result delivery is shared while
failure and cancellation projection are language-contract-specific. A throwing
group must not reuse a nonthrowing failure diagnostic or silently swallow an
outcome. A failed child consumed by throwing `next` rethrows its stored source
value; a cancelled child makes `next` throw `CancellationError` without marking
the owning task cancelled. Explicit throwing `waitForAll` consumes the same
completion-ordered queue as `next`. It retains the first failed or cancelled
outcome, continues draining every remaining outcome, returns normally if no
error occurred, and otherwise projects that first error only after the drain
completes. A failed outcome rethrows its stored source value; a cancelled
outcome throws `CancellationError` without marking the owning task cancelled.
Outcomes already consumed by an earlier `next` are not reconsidered.
Exceptional-exit rules remain explicitly unsupported until established by
dedicated native probes.

### 6.10 Executor model

```swift
enum RuntimeExecutorKind {
    case cooperativeDefault
    case mainActor
    case actor(RuntimeActorID)
    case globalActor(RuntimeGlobalActorID)
    case detached
    case host(HostExecutorID)
}
```

An executor owns a queue of runnable task IDs. In the first implementation all
queues may be drained on the native main actor, but their logical ownership and
serialization remain distinct.

The incremental foundation establishes identity before general queues: every runtime
task records its initial executor preference, every task-owned evaluation
context carries the current executor, and a declaration-level hop installs its
callee executor for the dynamic call extent before restoring the caller. Host
bridges read that explicit context. Source actor instances additionally own a
stable logical actor ID, isolated instance-method closures select its executor
identity, and user-declared global-actor attributes resolve lazily through the
declared type's canonical `static shared` actor. Synchronous and async actor
functions acquire a runtime-owned mailbox lease, so their non-suspending
segments serialize independently of the physical MainActor host. Canonical
runtime waits release the complete nested segment and reacquire it before the
evaluator returns from suspension. This partial M5 phase is not yet a general
executor scheduler or arbitrary-executor implementation.

Executor rules include:

- a task runs instructions only while scheduled on its current executor;
- actor-isolated storage is accessed only from that actor executor;
- an actor call from another executor creates an executor-hop suspension;
- an actor releases its executor when its running task suspends;
- another queued actor message may then run;
- resumption reacquires the required actor executor;
- a non-suspending actor method is atomic with respect to other actor messages;
- global actors use the same abstraction;
- `MainActor` maps to the native main actor at the host boundary.

#### `withTaskExecutorPreference` is a same-task dynamic scope

`withTaskExecutorPreference` does not create a child task. Its operation runs
under the caller's existing `RuntimeTaskID`, evaluation context, task-local
storage, cancellation record, name, and effective priority. The adapter calls
the operation through the ordinary suspending closure path and must not create
a task record, copy a context, or mutate logical executor identity merely to
represent scope entry and exit. Exact values and source errors propagate
unchanged.

Before argument validation, the adapter requires that the ambient task-owned
context is still bound to a live `.running` runtime record with the same
`RuntimeTaskID`. A retained host callback context whose record has already been
released fails closed; non-nil IDs alone are not an active-task capability.

The committed incremental subset is deliberately narrow:

- there is no ambient custom `TaskExecutor` preference;
- the unlabeled task-executor argument is explicitly `nil`;
- `isolation:` is present and explicitly `nil` rather than omitted as
  `#isolation`;
- `operation:` is a bare, unqualified identifier reference to a global `async`
  function declaration with a plain explicit `nonisolated` modifier and no
  declaration-level executor preference; `@concurrent` is outside this subset.

Plain explicit nonisolation is tracked as independent closure metadata. A nil
`ClosureValue.executorPreference` is not sufficient proof: it also represents
custom actor kinds whose identity is not modeled yet. Call-site provenance
separately proves the bare, unqualified global declaration boundary, so
qualified or parenthesized references, local aliases, annotated conversions,
member references, closure expressions, `@concurrent`/actor-isolated
functions, and `nonisolated(nonsending)` functions fail closed instead of
reusing stale declaration metadata or being reclassified from dynamic caller
state.

Native `withTaskExecutorPreference(nil)` inherits an ambient custom preference;
it does not clear one. Consequently, the absence of an ambient custom
preference is part of the positive contract, not an implementation shortcut.
Future custom-executor support needs a distinct preference identity and
dynamic scope stack. It must not reuse `RuntimeTaskRecord.executorPreference`
or `RuntimeExecutorKind`, which currently describe logical source executor
ownership rather than a Swift `TaskExecutor` value.

Focused and same-source tests prove the same-task boundary causally: cancelling
the current task inside the operation remains visible to the caller after the
scope returns. They also cover suspension, native high-priority raw value,
name, task-local state, exact success/failure, and cleanup. Non-nil task
executors, ambient-preference inheritance, omitted or non-nil isolation,
arbitrary actors, and resume-executor behavior remain M5 work.

#### `extractIsolation` reflects function-value metadata

`extractIsolation` is synchronous reflection over a function value. It never
invokes the supplied operation, creates a source task, suspends, or changes the
current executor. The incremental M7 subset accepts only a bare, unqualified
identifier reference to a global `async` function declaration carrying a plain
explicit `nonisolated` modifier, including a function that also carries
`@concurrent`, and returns `nil`.

This result comes from declaration provenance, not from a nil executor
preference or the executor on which the function value is inspected. Implicitly
nonisolated declarations, synchronous functions, qualified or parenthesized
references, local aliases, closure expressions, annotated function-value
conversions, member references, `nonisolated(nonsending)`, and
MainActor/custom-actor functions therefore fail closed until their value-level
isolation identity is modeled. The runtime must not infer an actor from the
current executor, a receiver, captured `self`, or declaration metadata that
survived a conversion.

The complete M5 model attaches canonical function-value isolation metadata at
formation and conversion boundaries, conceptually distinguishing
`nonisolated`, `actor(capability)`, and `unknown`. Both `extractIsolation` and
the replacement closure `.isolation` property consume that shared metadata.
An actor capability must identify the exact source actor instance without
retaining an evaluator task or borrowing dynamic caller state.

### 6.11 Actor storage

```swift
struct RuntimeActorRecord {
    let id: RuntimeActorID
    weak var instance: Instance?
    var executorOwnerTaskID: RuntimeTaskID?
    var executorOwnerDepth: Int
    var mailbox: [RuntimeActorMailboxWaiter]
}
```

The incremental runtime currently allocates a distinct `RuntimeActorID` for
each source actor instance and keeps only a weak instance reference in its
record. The source reference graph still owns the instance and property boxes;
final release removes the runtime record. A collected user-defined global actor
uses the runtime ID of its lazily evaluated `static shared` actor, so global-
actor and direct instance isolation share one canonical executor capability.
The actor record now owns a bounded mailbox and a depth-counted source-task
lease. Acquisition changes a competing task from `.running` to `.waiting` with
`.waitingForActor(actorID)`; release either clears ownership or transfers it to
one waiter, restores that task to `.running`, and resumes its continuation.
Actor and task teardown assert that no ownership or queue edge remains.

The actor instance remains a reference value, but its stored properties are
executor-confined. Member resolution must identify whether a declaration is:

- actor-isolated;
- `nonisolated`;
- isolated to a global actor;
- callable through an `isolated` parameter;
- immutable and safe to read without a hop under a verified Swift rule.

The current property metadata records mutability and explicit nonisolation.
Every common mutable stored-property read/write/projection funnel checks that
the current logical executor matches the actor and that the canonical runtime
task owns its lease. Ordinary immutable `let` reads and explicit
`nonisolated(unsafe)` storage follow the verified compiler rule. The
compiler-preflight layer diagnoses illegal source, while runtime checks prevent
a host callback or dynamically constructed call from bypassing isolation.
Externally awaited synchronous computed-property getters now acquire the exact
receiver actor and execute through a common accessor context; unawaited dynamic
entry fails closed, and explicit `nonisolated` metadata avoids over-isolation.
Computed and subscript setters use that common context but require an
already-owned actor segment; external mutation is rejected by native/compiler
preflight rather than turned into a setter hop. Awaited subscript getters use
the same receiver-selected executor path; their declared `async`/`throws`
effects select a suspending accessor body, and eager async entry fails closed.
`isolated` parameters retain syntax metadata and select their executor from the
bound runtime argument before invocation. A defaulted isolated argument is
evaluated exactly once in the caller's lexical isolation before any hop, and
that same value is reused for ordinary parameter binding. `#isolation`
projects a source actor, MainActor, or nil independently of the native
MainActor physically hosting the evaluator; explicit source actors and nil use
the same path. Synchronous actor entry is legal only when that actor is already
owned. A throwing computed getter balances its
target lease on failure and restores a parked caller actor before source catch
handling. An async-throwing computed getter preserves its declared effects,
uses the suspension-aware statement evaluator, reacquires its target mailbox
before cancellation observation, and then performs the same balanced target
release and caller restoration. Its normal-return and typed source-error paths
perform the same reacquire and balanced exit after suspension. An
async-throwing subscript getter follows those same paths for cancellation,
normal return, and typed source error. Struct- and enum-backed user global
actors whose `static shared` value has an arbitrary source-actor type now
preserve their nominal attribute metadata and select that exact actor
capability through both `#isolation` and defaulted isolated parameters.
Function-value isolation identity and conversion remain the separate section
6.10 boundary; they are not inferred from dispatch metadata.

A synchronous actor initializer remains lexically nonisolated while its new
instance is marked as initializing. It may seed and mutate that instance's
stored state without acquiring its mailbox; after initialization ends, the
same mutable-storage funnels require ownership and the first external isolated
method enters through the registered actor ID. The committed initialization
fixture pins this transition and final actor-record cleanup.

### 6.12 Actor reentrancy

When an actor-isolated method suspends:

1. its task context and continuation are retained;
2. the actor executor becomes available;
3. another queued actor message may mutate actor state;
4. when the awaited operation completes, the suspended task is queued on the
   actor executor;
5. it resumes only after reacquiring that executor.

Tests must never assume actor state is unchanged across `await` unless the
program establishes that invariant itself.

The current runtime represents both synchronous and async actor invocations as
depth-counted leases. A balanced runtime suspension token parks the entire
nested segment, makes the actor available, and restores the same depth only
after the task has regained the actor mailbox. The controlled same-source
`actor-reentrancy` fixture proves successful host-suspension interleaving and
resume ownership. The `actor-computed-property` fixture separately proves that
an externally awaited synchronous getter owns the receiver actor for its whole
accessor segment. `actor-computed-property-failure` proves that a throwing
getter releases its target lease and restores a parked caller before source
catch handling and later target work.
`actor-computed-property-cancellation` uses a controlled gate to prove that an
async-throwing getter releases the target actor while suspended, reacquires it
before observing cancellation, then releases it and restores the parked caller
before catch handling and later target work.
`actor-computed-property-async-exits` uses separate source-owned gates to prove
the same target reacquisition, balanced release, and caller restoration on
normal return and typed source-thrown error. The `actor-computed-setter` fixture
proves legal setter execution inside an already-owned actor method, while a
diagnostic fixture proves that external mutation cannot be made into a hop
with `await`. The
`actor-subscript-getter` fixture proves the corresponding externally awaited
getter segment and explicit-nonisolated exception.
`actor-subscript-cancellation` uses a controlled gate to prove target release
at suspension, target reacquisition before cancellation observation, balanced
target release, caller restoration before catch, and later target progress for
an async-throwing subscript getter. `actor-subscript-async-exits` uses separate
source-owned gates to prove the same target reacquisition, balanced release,
and caller restoration on normal return and typed source-thrown error. The
`actor-subscript-setter` fixture plus its compiler-diagnostic twin prove legal
already-owned execution and reject an invented external hop. The
`actor-cross-actor-failure` fixture proves callee release and caller restoration
around a throwing function hop. `actor-cross-actor-cancellation` uses a
controlled gate to prove callee reacquisition before cancellation observation,
followed by callee release and caller restoration. The
`actor-isolated-parameter` fixture proves that ordinary argument matching and
executor selection share one mapping: the required explicit actor argument is
resolved before a hop, its mailbox is acquired for the complete synchronous
body, and an already-owned same-actor call stays synchronous. Eager unowned
entry and malformed dynamic values fail closed. `actor-mailbox-stress` proves
the commutative native terminal invariant across repeated mailbox rounds, and a
64-seed replayable board varies fanout plus suspension placement while checking
ownership, mutation totals, child collection, and complete runtime draining.
`actor-isolated-parameter-defaults` additionally proves caller-lexical
`#isolation` inheritance from a source actor, explicit source-actor selection,
explicit nil, and a nil default from nonisolated code. A separate MainActor
fixture proves that its default is non-nil and selects the logical main lane,
while explicit nil remains nil. The
`actor-arbitrary-global-actor-isolation` fixture proves the corresponding
canonical capability and mailbox ownership for both struct- and enum-backed
global actors whose `shared` values have distinct source-actor types. The
`actor-task-local-propagation` fixture proves that actor entry changes only
the task's required executor: the same task-owned local map remains visible
inside the actor, survives release/reacquisition across suspension, and is
restored at dynamic-scope exit while each source segment owns the mailbox.
The `actor-queued-message-cancellation` fixture holds one actor segment behind
a controlled gate, proves a second cross-actor call has suspended, cancels its
task, and then releases the owner. Swift retains that mailbox message: the
cancelled task receives ownership, enters the method, and observes its request.
The runtime therefore keeps `waitingForActor` independent from cancellation;
handoff removes the queue edge, and source observation remains cooperative.
An unchanged pinned swiftlang runtime test also proves that an ordinary actor
deinitializer runs after the final source reference is released following an
isolated method entry. This is lifetime evidence only: executor-scheduled or
globally isolated deinitializers require a separate native question and must
not inherit that claim.
The unchanged pinned `isolated_deinit_main_sync.swift` fixture answers the
narrow next question: an explicitly `@MainActor` deinitializer runs
synchronously when its final release already owns MainActor. That legal fast
path is available to the interpreter for a structural reason: the host
`Instance` representation is itself `@MainActor`, and its host
`isolated deinit` is scheduled by Swift before it calls back into the source
deinitializer runner. The collector therefore records `.mainActor` executor
metadata for an explicit `@MainActor deinit` and for `isolated deinit` on a
MainActor nominal. The common runner applies that metadata to both the dynamic
and lexical source executor while executing the body, restores the caller,
and then continues superclass teardown. The unchanged upstream FileCheck and
the repository-owned same-source probe both have exact parity for this
MainActor-owned path. Ordinary deinitializers remain nonisolated, including on
actor-annotated enclosing types.

This support is intentionally capability-based rather than syntax-wide.
`isolated deinit` on a source actor still needs that instance's mailbox, and
an explicit user-global-actor deinitializer needs its canonical source actor;
the MainActor-owned host lifetime provides neither capability. Those forms are
classified after forward declarations, qualified nested types, and aliases
resolve, and their owning nominal fails closed at first construction. Explicit
`nonisolated deinit` remains supported. A second repository-owned same-source
probe establishes the corresponding already-owned fast path for an explicit
user-declared global-actor deinitializer. The interpreter now resolves
forward declarations, qualified nested types, and typealiases before deciding
whether an explicit deinitializer attribute names `@globalActor`, then marks
the owning nominal so construction fails before its body can ever run. An
actor annotation on the enclosing class
alone does not change Swift's ordinary nonisolated-deinitializer rule.

The unchanged pinned swiftlang `custom_executors.swift` fixture establishes
that a source actor's `unownedExecutor` changes isolated dispatch: Swift asks
for the property on every isolated entry, and the method runs on the returned
serial executor rather than the actor's default executor. The interpreter's
cooperative actor mailbox is therefore not an equivalent fallback. After
extensions and protocol refinements are resolved, actor symbols are marked
when `unownedExecutor` is supplied directly as computed or stored state, or by
a protocol-extension default. Declaration and initialization remain legal;
the common isolated method, accessor, isolated-parameter, global-actor, and
stored-property entry paths fail closed before running source-isolated code.
Nonisolated members remain available, and a same-named non-actor property is
ordinary. This preserves real projects that collect a custom-executor actor
without silently pretending its isolated work uses Swift's chosen executor.
Full custom serial-executor scheduling remains unsupported and is not confused
with logical actor mailbox ownership or M9 physical parallelism.

That disposition closes the demand-scoped per-feature M5 safety boundary. M5
is provisional rather than complete while its broad M4 and M7 prerequisite
milestones retain explicitly owned partial-surface gaps.

### 6.13 Cancellation

Cancellation is an explicit state transition, not an ordinary host error.

The runtime records:

- whether cancellation was requested;
- who requested it;
- when it was first observed;
- registered cancellation handlers;
- structured descendants that must receive propagation.

Cancellation remains cooperative. Evaluation checks it at defined safe points:

- before and after suspension;
- statement and loop boundaries;
- function entry;
- task-group operations;
- actor queue waits;
- continuation/stream waits;
- bounded budget ticks.

Whether a thrown `CancellationError` can be caught and suppressed by source is
not assumed. It is established using native probes, and session teardown may
still use a separate non-catchable host-abort mechanism when the entire
interpreter run is being force-cancelled.

This distinction prevents infrastructure cancellation from being confused
with source-observable task cancellation.

A true source read of `Task.isCancelled` is itself an observation and records
the first observation sequence without forcing an error or terminal cancelled
outcome. Reading another task handle's `isCancelled` does not observe the
current task's cancellation.

A source cancellation request made before an unstructured task enters its
operation does not suppress operation entry. The task begins with its
cancellation flag set, may explicitly observe it, and may still return a
successful value while its handle remains marked cancelled. Pending, running,
terminal outcome, cancellation request, and cancellation observation are
therefore independent runtime dimensions. A separate session/host abort may
prevent entry because it is infrastructure teardown rather than source task
cancellation.

Likewise, cancelling a task already waiting for an actor does not remove its
mailbox entry or synthesize a thrown result. The task remains
`.waitingForActor` until ordinary handoff, enters the actor with the request
still set, and observes or ignores cancellation according to its source body.
Queue ownership and cancellation state are separate edges and both must drain
before the task record can be released.

The committed Swift 6 probe for an ordinary unstructured task establishes one
additional value-wait rule: cancelling the waiter while it is suspended on
`await target.value` does not by itself interrupt that wait or cancel the
target. The waiter remains registered until the target completes, receives the
value, and may finish successfully while its own cancellation flag remains
true. Runtime wait edges must therefore be removed on actual wait completion,
not merely on cancellation request. Other suspension kinds require their own
native probes and may be cancellable.

### 6.14 Task locals

Task-local values live in a logical inherited map owned by the task record.
The evaluator context for that task receives a capability to the same storage;
no other task shares the mutable storage object. Creation semantics differ by
task kind:

- child and unstructured task inheritance is verified natively;
- detached task inheritance is verified separately;
- scoped `withValue` pushes a binding for the dynamic extent, including across
  suspension;
- child mutation cannot mutate the parent's inherited binding.

Ordinary task creation snapshots the map with interpreter value semantics;
detached creation starts from an empty map unless a separately verified task
kind says otherwise. Dynamic binding restoration uses structured cleanup so
throwing and cancelled exits cannot strand the replacement value. Completed
task contexts clear their maps together with the rest of their dynamic state.
An actor hop does not create a task or copy its task-local map. It changes the
current task's logical executor, releases that actor lease at suspension, and
reacquires the lease before continuing with the same map. The committed actor
task-local fixture pins the binding before and after that transition plus
scope restoration and task/actor cleanup.

A source `@TaskLocal` declaration is keyed by declaration identity, never by
its textual member name. Host integrations may use explicitly namespaced
runtime keys and a task-bound read/scope capability. A host context without
that capability must diagnose scoped binding as unsupported rather than
silently run the operation without the binding.

The collected declaration owns an immutable identity/default descriptor. A
direct member read consults the current task map and falls back to the one
static default; `$member` is a dedicated scoped-binding capability, not a
general property-wrapper absorber. Its synchronous and suspending `withValue`
paths enter the same task-owned storage and share structured unwind cleanup.
Source declaration identities and host string keys occupy disjoint key domains.
An optional `@TaskLocal` may omit its initializer, in which case Swift supplies
a typed `nil` default. A non-optional declaration must provide an initializer;
the interpreter diagnoses the invalid form rather than inventing a value.

Task locals are never stored in shared interpreter globals.

### 6.15 Priority

The runtime preserves source priority even before it affects physical native
scheduling. It records:

- base priority;
- inherited priority;
- effective priority;
- escalation caused by awaiting a task.

`basePriority` is immutable creation state; `effectivePriority` may change as
the result of a separately verified escalation rule. An ordinary unstructured
task inherits the creator context's effective value unless an explicit
priority is supplied. Detached defaults and explicit-priority behavior are
characterized independently. The native task used to drive cooperative
execution receives the logical value, but querying that native driver is not
the source of truth for an interpreted task after creation.

An interpreted value wait is a runtime-owned dependency edge. A waiter donates
its current effective priority to the awaited task when higher; the runtime
updates both the record and its live evaluator context before the awaited task
can resume. Donation propagates transitively when that task is itself waiting
on another task, and a child created after escalation inherits the updated
effective value. Dependency edges are removed when the wait exits and must not
retain completed records. Escalation is modeled monotonically for a task's
lifetime; de-escalation is not invented without a separate native guarantee.

A task-priority escalation handler is a dynamically scoped registration on
the target task record, not a separate task kind or name-specific gateway. Its
runtime contract is:

- registration observes only future strict increases; an earlier donation is
  never replayed;
- on each strict increase, the runtime captures the previous effective value,
  updates the target record and live evaluator context, and then invokes every
  registration active for that dynamic extent with the exact old/new pair;
- an operation that resumes after delivery observes the new effective
  priority, and transitive donation proceeds from that updated value;
- every registration is removed with structured cleanup on value, source
  error, cancellation, or interpreter failure;
- a legal source handler is nonthrowing; an interpreter-only callback failure
  is retained on the target record and surfaced at its next safe point rather
  than being swallowed by the donating task.

Relative order between nested handlers, callback-versus-operation scheduling,
physical thread identity, and unrelated ready-task order are not semantic
claims. Both active SDK spellings route through this one construct. Until M5
owns arbitrary actors and isolated resume executors, the isolated-parameter
wrapper accepts only an explicitly supplied `nil`; omitted `#isolation` and a
non-`nil` actor fail closed. The `nonisolated(nonsending)` spelling likewise
retains a known divergence for actor/executor shapes outside the evidenced
cooperative subset.

Tests assert priority values and inheritance. They do not assert that a
higher-priority task always executes first unless Swift guarantees it.

### 6.16 Clock and sleep

Time-dependent behavior uses an injected runtime clock:

```swift
protocol RuntimeClock {
    var now: RuntimeInstant { get }
    func registerSleep(
        task: RuntimeTaskID,
        until: RuntimeInstant,
        tolerance: RuntimeDuration?
    )
    func cancelSleep(task: RuntimeTaskID)
}
```

Implementations:

- `ContinuousRuntimeClock`: backed by native Swift clock APIs;
- `ManualRuntimeClock`: advanced deterministically by tests;
- optional wall clock for APIs that explicitly require calendar time.

`Task.sleep` suspends rather than blocking an executor. Cancellation removes the
waiter and resumes the task with the native outcome.

### 6.17 Continuations

A continuation registry maps continuation IDs to one suspended task and its
required resume executor.

Checked continuations enforce:

- exactly one successful resume;
- a diagnostic for double resume;
- a diagnostic for abandonment according to the selected debug policy;
- preservation of result/error type;
- executor-correct resumption.

Native probes determine which properties are guaranteed and which diagnostics
are debug implementation behavior.

The current first slice implements a bounded runtime-owned record and opaque
source carrier for `withCheckedContinuation(isolation:nil)` plus
`resume(returning:)`. A delayed resume records
`.waitingForContinuation(id)`, restores the owner's required logical executor,
and closes both the registry entry and task-owner edge before returning the
copied value. Immediate resume uses the same exactly-once transition without a
synthetic suspension. Infrastructure cancellation may abort the internal
native waiter so session teardown cannot hang; ordinary source cancellation
does not resolve the continuation. Throwing/error projection, broader
isolation, checked diagnostics/lifetime, and unsafe variants remain open.

### 6.18 Async sequences and streams

`AsyncSequence` support is protocol-driven, not a collection special case.
The evaluator implements `for await` in terms of:

1. `makeAsyncIterator()`;
2. repeated suspending `next()` calls;
3. optional end-of-sequence;
4. error and cancellation propagation;
5. `break`, `continue`, `return`, and `defer` cleanup.

`AsyncStream` and `AsyncThrowingStream` are runtime objects with:

- buffered elements;
- suspended consumers;
- termination state;
- producer continuations;
- cancellation and termination callbacks;
- a documented buffering policy.

The current M6 slices implement the protocol lowering for finite interpreted
sequences. The runtime evaluates the sequence once, calls
`makeAsyncIterator()` once, repeatedly invokes suspending `next()`, unwraps
exactly one optional layer, and stops requesting elements after `nil`. A
value-type iterator uses the same suspension-aware
mutating-method copy-in/copy-out kernel as an explicit
`await iterator.next()` call; direct witness dispatch may not discard its
state. A typed error from `next()` exits the loop and propagates through the
ordinary source-error path without delivering an element for that call.
Cancellation of the consuming task does not itself end a general protocol
iteration: after a controlled suspension the iterator may resume, observe the
request, return an element, and later return `nil`, while the successful task
and its handle remain marked cancelled. This is cooperative iterator behavior,
not evidence for `AsyncStream` consumer termination.
An iterator with no terminal `nil` path proves the first early-exit slice:
`break` after the second suspended element causes the current iteration's
`defer` to run and reaches post-loop code without a third `next()` request.
The companion control-flow slice proves that `continue` runs its iteration
defer before requesting again, while `return` stops requests and unwinds the
current body defer plus the enclosing function defer before caller resumption.
Compiler preflight owns conformance legality. Runtime dispatch remains
value-based so protocol-extension witnesses and generated host methods can use
the same path once their focused evidence lands. Refining-protocol extensions
now have exact evidence for default `makeAsyncIterator()` and mutating async
`next()` witnesses with suspension-aware iterator copy-out. An opaque
host-backed sequence has separate exact evidence: parsed factory, iterator,
and async-next gateway contracts feed this same dispatch path, each `next()`
owns a runtime host operation, and terminal `nil` drains every registry.
The first stream slice implements an interpreter-owned unbounded
`AsyncStream<Element>` storage, producer continuation, iterator, and runtime
wait registry. An empty `next()` moves the current task to
`.waitingForStream(streamID)` under a suspension lease; `yield` resumes one
consumer, `finish` resumes all remaining consumers with terminal `nil`, and
the record closes only after the buffer and wait edges drain. Cancelling a task
parked in `next()` synchronously invokes the installed termination closure with
`.cancelled` before making that call return `nil`; the callback registration is
one-shot and is cleared at termination. Explicit `finish()` similarly invokes
one `.finished` callback synchronously before returning, retains values already
buffered, makes later `next()` calls stably return `nil`, and rejects later
`yield` calls as `.terminated`. Construction accepts an explicit element
specialization and stores an explicit buffering policy. The evidenced
`.bufferingNewest(2)` path reports remaining capacity after successful inserts,
evicts and returns the oldest buffered element once full, and retains only the
newest values. The companion `.bufferingOldest(2)` path rejects and returns the
new element once full while preserving the first buffered values. At capacity
zero both policies keep no buffer and return the supplied value as `.dropped`.
Unknown policies and negative capacities still fail closed. Multiple
independently-created iterators may own simultaneous wait edges on one storage,
and `finish()` resumes all of them with terminal `nil`.
Iterator carriers opt into the interpreter's generic host value-semantics
boundary: each source copy owns a distinct mutable `next()` token while all
copies retain the same stream storage. Sequence and iterator carriers own that
storage; producer continuations are non-owning handles. When the last unfinished
sequence/iterator owner is released, storage destruction invokes the one-shot
`.cancelled` callback synchronously before closing its runtime record. An
escaped producer handle then returns `.terminated` from `yield`, and releasing
it cannot invoke termination again. Because destruction cannot throw, an
interpreter failure from this source-level nonthrowing callback is retained by
the concurrency runtime and surfaced at the next throwing evaluator safe point.
The first `AsyncThrowingStream<Element, Error>` slice reuses this same
flavor-aware storage, waiter, suspension, producer-handle, iterator-carrier, and
cleanup kernel. Its terminal state may retain an original source error value;
after a waiter receives its prior value, the next `next()` rethrows the error
through `InterpretedThrow`. Exact evidence covers one suspended unbounded
consumer, one delivered value, case-specific failure projection, and complete
cleanup.
Normal throwing-stream finish now also has exact evidence: it synchronously
delivers `.finished(nil)` to one registered callback, preserves a buffered
value, produces stable terminal nil, and rejects later yield. Failure finish
has companion evidence: `.finished(error)` carries the original source
value synchronously before return, iteration drains the prior value then
rethrows that error, and later yield is terminated. Cancelling a task parked in
throwing-stream `next()` now synchronously delivers `.cancelled` before
resuming that call with terminal `nil`; the task may return normally while its
cancellation bit remains set. Positive-capacity `.bufferingNewest` now reports
remaining capacity after insertion, evicts and returns the oldest element once
full, and retains only the newest values. Its `.bufferingOldest` counterpart
reports the same capacity, preserves the first values, and returns each newly
rejected element. At capacity zero both policies retain no element and return
the supplied value as `.dropped`. Unlike `AsyncStream`, a throwing stream owns
one pending-`next()` capability in shared storage: after one copied iterator
has suspended, a second copied iterator call is a runtime trap. The capability
is storage-wide rather than attached to a source carrier, and its fatal error
metadata survives gateway source-location attachment. Final release of an
unfinished throwing-stream sequence/iterator also synchronously delivers the
flavor-correct `.cancelled` callback before storage destruction closes its
record. The producer continuation is non-owning for this flavor too: an escaped
handle observes `.terminated` after final sequence/iterator release and cannot
invoke termination again when it dies. Source checked continuations are not
yet claimed.

### 6.19 Host gateway runtime

Host declarations already retain parsed call contracts. Concurrency extends a
host contract with:

- `async` and throwing effects;
- global-actor isolation;
- `nonisolated` state;
- `@Sendable` closure parameters;
- `isolated` parameters;
- generic `Sendable` constraints;
- cancellation behavior;
- preferred resume executor.

Ordinary SDK work should be forwarded, not reimplemented. A generated gateway
converts source runtime values, performs a statically compiled native Swift
call when the framework is present in-process, and converts the result back.
This is the default API-coverage strategy.

Native forwarding does not replace source-language concurrency semantics. A
native runtime cannot execute an interpreted AST closure, mutate its captured
environment, or infer the logical parent, cancellation graph, structured
lifetime, task locals, actor, and resume executor of a source task. The
interpreter therefore owns those identities and parks its task around the
native operation; callbacks re-enter through the bound task/executor
capability below. Compiling arbitrary source closures into forwarding wrappers
would be a JIT/AOT compiler and would discard the dynamic interpreter model.

If a required framework is unavailable in the host process, the same gateway
protocol may later target a simulator/device worker with RPC, native-object
handles, and callback re-entry. That backend can improve platform fidelity,
but it still uses the same logical suspension and callback machinery and is
not a substitute for it.

An async host gateway receives a context-bound callback capability. It may:

- suspend the current source task;
- re-enter an interpreted closure asynchronously;
- register cancellation cleanup;
- resume with a typed value or error;
- request a main-actor or actor executor hop.

It must not call a synchronous interpreter API from an arbitrary native
executor and mutate shared evaluation state.

Conceptual contract:

```swift
struct HostAsyncCallContext {
    let session: InterpreterSessionID
    let task: RuntimeTaskID
    let executor: RuntimeExecutorID
    let cancellation: CancellationView

    func callInterpretedClosure(
        _ closure: ClosureValue,
        arguments: [RuntimeValue]
    ) async throws -> RuntimeValue
}
```

### 6.20 Compiler semantic preflight

Full Swift concurrency legality is deeply integrated with the Swift type
checker. The interpreter should use the real compiler rather than reproduce all
of these rules dynamically.

The preflight pipeline is:

```text
HostRegistry declarations + generated SDK declarations
                         │
                         ▼
              Generated host stub module
                         │
User/project source ─────┼──▶ swiftc/SourceKit typecheck
                         │
                         ▼
         diagnostics + isolation/effect metadata
                         │
                         ▼
                ParsedProgram / execution
```

The generated stub module exposes only declarations, not implementations. It is
keyed by:

- Swift compiler version;
- SDK path and version;
- target platform and deployment version;
- generated gateway manifest hash.

Real-project entry points additionally use one immutable target manifest as the
shared semantic identity of native checking and interpretation. The manifest
contains the canonical project root, exact ordered target source membership and
bytes, module name, SDK, exact target triple and deployment floor, compiler and
effective `#if swift` versions, language/strict-concurrency/default-isolation
modes, defines, normalized import/framework search paths, feature flags, and
authoritative import/conditional-compilation answers. Directory walking is not
part of this contract: files from sibling targets must never enter preflight or
the interpreter accidentally.

The native side typechecks the original files as one module. A separate merged
source is only a derived runtime projection; stripping imports or adding file
markers there must not change the material checked by `swiftc`. The project
root is propagated independently for resource lookup and participates in the
manifest fingerprint.

Conditional compilation uses two ownership rules:

- fields such as platform, architecture, target environment, defines, compiler
  version, and exact unversioned module membership are evaluated directly from
  the immutable target identity;
- compiler-owned predicates such as `hasFeature`, `hasAttribute`,
  `objectFormat`, `_endian`, `_runtime`, and version-qualified `canImport` have
  explicit answers that are verified by a hidden source in the same native
  client module.

An unrecorded compiler-owned predicate is a target-manifest error, not `false`.
The interpreter validates the complete syntax tree and fails before declaration
collection or top-level mutation, preventing native preflight from accepting
one branch while interpreted execution silently selects another.

Preflight should cover, through native diagnostics:

- missing `await`;
- async calls from synchronous contexts;
- actor-isolated access;
- global-actor mismatches;
- `@Sendable` capture violations;
- `Sendable` boundary violations;
- illegal `isolated`/`nonisolated` use;
- task-group generic constraints;
- concurrency availability.

When a runtime-editor environment intentionally permits incomplete source,
preflight diagnostics may be non-blocking until execution. The distinction
between a recoverable editor diagnostic and an executable program remains
explicit.

### 6.21 SwiftUI integration

SwiftUI remains main-actor-bound. Its concurrency integration must model view
lifetime:

- `.task` creates a `swiftUITask` associated with view identity;
- `.task(id:)` cancels the previous task when the ID changes;
- removing the view cancels its task;
- `.refreshable` invokes an async interpreted closure and propagates its
  lifetime;
- host callbacks resume interpreted code on the required executor;
- UI-observable model mutation respects source global-actor requirements;
- a synchronous `body` never blocks waiting for async work.

Synchronous framework callbacks and asynchronous view-lifecycle work are two
different runtime entries. A callback such as `Button(action:)` must execute
the source action inline so state mutations are visible before the host call
returns. It nevertheless owns a fresh logical `hostCallback` task and session;
therefore any source `Task` created by the action is scheduled by the canonical
runtime and may suspend independently. Scheduling the whole action onto a new
host task would be observably wrong. Calling it through the legacy synchronous
compatibility evaluator is also wrong because that collapses nested tasks and
suspensions inline.

All retained synchronous framework closures use one host-callback adapter. It
creates the logical entry, binds task-local/runtime context, executes the
closure synchronously, releases the entry after its own dynamic state is
clean, and reports an uncaught callback error through bridge diagnostics.
Buttons, generated actions, gestures, bindings, lifecycle event modifiers,
and Objective-C completions share this path. Queued GCD deliveries retain
their own deterministic/wall-clock bridge policy and require a separate
follow-up before they can adopt the same runtime entry without changing test
or delivery semantics.
Async `.task`, `.task(id:)`, and `.refreshable` closures instead require the
separate `swiftUITask` lifecycle contract above; they must not be implemented
by extending the synchronous adapter.

The current synchronous rendering compatibility path remains separate. A view
task must use the canonical concurrency runtime even when it was created by a
synchronous render pass.

## 7. Ownership and isolation matrix

| Component | Mutable? | Initial owner | Parallel target |
|---|---:|---|---|
| `ParsedProgram` | No | Session | Immutable/Sendable |
| Declaration metadata | No after build | Program | Immutable/Sendable |
| `InterpreterSession` | Yes | Cooperative runtime | Actor or explicit synchronization |
| Global environment | Yes | Runtime heap | Executor-confined or synchronized |
| `EvaluationTaskContext` | Yes | One task | Never shared concurrently |
| Lexical `Environment` | Yes | Owning task/closure | Capture rules plus executor checks |
| Local `Box` | Yes | One task/capture graph | Not shared without legal capture |
| Class `Instance` | Yes | Runtime heap/reference graph | Checked Sendable/executor policy |
| Actor `Instance` | Yes | Actor executor | Actor-confined |
| SwiftUI state boxes | Yes | Main actor/view identity | Main-actor-confined |
| `RuntimeTaskRecord` | Yes | Concurrency runtime | Runtime actor-confined |
| `RuntimeStructuredScopeRecord` | Yes | Concurrency runtime/owner task | Runtime actor-confined |
| `RuntimeTaskGroupRecord` | Yes | Concurrency runtime/owner task | Runtime actor-confined |
| Lexical cleanup frame | Yes | One evaluation task | Never shared concurrently |
| Task-local map | Persistent value | One task | Copied/inherited structurally |
| Host opaque value | Varies | Declared host contract | Contract-specific Sendable/isolation |
| Continuation record | Yes | Concurrency runtime | Exactly-once synchronized transition |
| Stream buffer | Yes | Stream runtime object | Serialized producer/consumer access |

This matrix must be updated whenever a new mutable runtime component is added.

## 8. Task state machine

```text
                         create
                           │
                           ▼
                        pending
                           │ schedule
                           ▼
                        running
                 ┌─────────┼──────────┐
                 │         │          │
              suspend    success     failure
                 │         │          │
                 ▼         ▼          ▼
               waiting  succeeded   failed
                 │
          wake / actor acquired
                 │
                 └──────────────▶ running

Cancellation request is an orthogonal state dimension and may occur in
pending, running, waiting, or terminal state. It records the request
immediately without itself selecting a terminal outcome:

  pending  ──request──────▶ pending + cancellation requested
  waiting  ──request──────▶ waiting + cancellation requested; a cancellable
                             suspension may wake or throw
  running  ──observe──────▶ source handles/returns/throws, or completes as
                             cancelled according to the native operation
  terminal ──request──────▶ same immutable outcome + handle marked cancelled

Source cancellation before entry does not suppress an unstructured operation.
Only the separate session/host-abort path may prevent source entry during
infrastructure teardown.
```

Completion is immutable. Double completion or double continuation resume is a
runtime invariant violation, never silently ignored.

## 9. Session policies

Language task lifetime and test-harness draining are separate concepts.

```swift
enum SessionCompletionPolicy {
    /// Return when the top-level source task completes. Unstructured tasks may
    /// continue according to session ownership rules.
    case topLevel

    /// Deterministic test/application compatibility: wait for all tasks owned
    /// by the session, with a deadline.
    case drainOwnedTasks

    /// Cancel all remaining session-owned tasks, await cleanup, then return.
    case cancelRemainingTasks
}
```

No policy changes whether a source `Task {}` is a structured child. Policy only
controls the host session boundary.

## 10. Error model

The runtime distinguishes:

- source-thrown values;
- host gateway errors visible to source;
- task cancellation visible to source;
- fatal interpreter resource errors;
- host-requested session abortion;
- compiler-preflight diagnostics;
- invariant failures in the concurrency runtime.

A fatal session abort must not be catchable as an ordinary source error.
Conversely, a source-observable `CancellationError` must follow native catch and
propagation behavior. These two paths require distinct types.

## 11. Resource limits

Concurrency expands denial-of-service and leak risk. Limits are session policy,
not scattered constants:

- maximum live tasks;
- maximum structured depth;
- maximum waiters per task;
- maximum actor mailbox length;
- maximum live continuations;
- maximum stream buffer size;
- maximum task-local depth/size;
- evaluator step and frame limits;
- wall-clock deadline for parity probes and session teardown.

Limit failures are deterministic and diagnostic. Cleanup cancels owned native
operations and releases captured environments.

## 12. Native differential harness design

### 12.1 Repository layout

Recommended layout:

```text
Tests/ConcurrencyParity/
├── Fixtures/
│   ├── task-value.swift
│   ├── cancellation-before-start.swift
│   ├── async-let-scope-exit.swift
│   ├── task-group-error.swift
│   ├── actor-reentrancy.swift
│   └── ...
├── Manifests/
│   └── parity-cases.json
└── Support/
    ├── NativeProbeSupport.swift
    └── InterpretedProbeSupport.swift

Sources/ConcurrencyParityRunner/
└── main.swift
```

The exact target structure may be adapted to SwiftPM, but fixtures remain
readable standalone Swift programs.

### 12.2 Manifest

Each case records:

```json
{
  "id": "actor-reentrancy",
  "fixture": "Fixtures/actor-reentrancy.swift",
  "mode": "runtime",
  "assertion": "partial-order",
  "repetitions": 20,
  "timeoutSeconds": 5,
  "platform": "macOS",
  "notes": "The barrier forces the first method to suspend before message 2."
}
```

Assertion kinds:

- `exact`: identical normalized output;
- `allowed-set`: every result belongs to a native-established set;
- `partial-order`: named events satisfy precedence constraints;
- `predicate`: both outputs satisfy the same invariant checker;
- `diagnostic`: compiler failure category and source position;
- `runtime-trap`: each isolated process exits nonzero and contains its
  authored diagnostic fragment; timeout is a failure, never a trap;
- `stress`: no deadlock, crash, leak threshold, or invariant failure.

### 12.3 Native compilation

Runtime probes use a form equivalent to:

```sh
xcrun swiftc \
  -swift-version 6 \
  -strict-concurrency=complete \
  -parse-as-library \
  probe.swift \
  -o probe
```

Diagnostic probes use `-typecheck`. The harness captures:

- full compiler version;
- compiler path;
- SDK path/version;
- compilation flags;
- exit status;
- stdout and stderr;
- execution timeout;
- repetition results.

Optional debug runs may add actor data-race checks when supported by the active
toolchain. Such flags are recorded rather than assumed.

### 12.4 Probe form

```swift
import Foundation

@main
struct Probe {
    static func main() async throws {
        // Use controlled barriers, actors, or continuations.
        // Print stable, machine-readable events or final state.
    }
}
```

Probes do not use arbitrary sleeps for synchronization. Testing sleep itself is
the exception and uses generous timing invariants or a separately characterized
clock abstraction.

### 12.5 Stable trace format

Recommended output is one JSON object or tab-separated event per line:

```text
event\t1\tparent-start
event\t2\tchild-start
state\tbalance\t80
outcome\tsuccess
```

Normalization may remove process IDs, addresses, absolute timestamps, and
unordered dictionary formatting. It must not erase a semantic difference.

### 12.6 Establishing a guarantee

Before adding the interpreter assertion, the agent writes a short conclusion:

```text
Native fact:
- `async let` begins before its first explicit read.
- Exiting this scope waits for or cancels it according to the observed rule.
- Event A precedes B because of the barrier.
- Relative order of C and D is unspecified and is not asserted.
```

This conclusion is stored with the fixture or parity ledger.

### 12.7 Diagnostic probes

Diagnostic tests compare semantic categories rather than the complete message:

- compiler exits non-zero;
- diagnostic points at the expected declaration/expression;
- message contains stable concepts such as `actor-isolated`, `await`, or
  `Sendable`;
- interpreter preflight surfaces the same native diagnostic rather than a
  later unrelated runtime error.

### 12.8 Fresh-process doctrine

Native and interpreted parity cases run in fresh processes when static state,
task-local state, executor queues, or cancellation could leak between cases.
In-process focused unit tests remain useful but cannot be the sole closing
evidence for global runtime cleanup.

## 13. Required semantic test matrix

### 13.1 Async functions and suspension

- async global function;
- async instance/static method;
- async mutating struct method and copy-out;
- async throwing function;
- nested `try? await`;
- suspension inside lazy control flow;
- `defer` across suspension;
- recursion across suspension;
- host gateway suspension;
- host gateway re-entry into an async interpreted closure.

### 13.2 Task values

- task starts independently of constructor return;
- successful `value`;
- throwing `value`;
- multiple waiters;
- cancellation before start;
- cancellation while running;
- cancellation while waiting;
- task result after completion;
- task handle deallocation;
- unstructured lifetime at top-level return;
- detached inheritance differences;
- priority and task-local inheritance.

### 13.3 Structured concurrency

- `async let` eager start;
- read of `async let`;
- unused `async let` at normal scope exit;
- early return;
- thrown scope;
- parent cancellation;
- group child completion order;
- throwing group first-error behavior;
- `next()` until nil;
- `waitForAll`;
- `cancelAll`;
- child adding child tasks;
- group escape restrictions through compiler preflight.

### 13.4 Actors

- serial mutation;
- cross-actor call requires await;
- same-actor call;
- immutable property access rule;
- reentrancy across await;
- non-reentrant segment before await;
- `nonisolated` method/property;
- `isolated` parameter;
- actor initialization;
- actor method throwing/cancellation;
- MainActor call and hop;
- custom global actor;
- actor task-local propagation;
- queued message cancellation.

### 13.5 Sendability and isolation diagnostics

- non-Sendable capture in `@Sendable` closure;
- mutable captured local;
- class crossing actor boundary;
- Sendable struct synthesis;
- unchecked Sendable;
- global-actor-isolated conformance;
- protocol isolation;
- closure conversion losing global actor;
- detached-task captures.

### 13.6 Async sequences and continuations

- normal async iteration;
- throwing iterator;
- break/return cleanup;
- consumer cancellation;
- stream finish;
- throwing stream failure;
- buffering policy;
- termination callback;
- continuation value/error resume;
- double resume;
- never-resumed checked continuation policy;
- resume from another executor.

### 13.7 SwiftUI lifecycle

- `.task` begins after view appearance;
- task cancellation when view disappears;
- `.task(id:)` replacement;
- model mutation visibility;
- MainActor enforcement;
- refresh completion;
- repeated render identity;
- no retained view/session after cancellation.

## 14. Migration plan

Each milestone is independently gated through
`Tests/ConcurrencyParity/Manifests/milestone-acceptance.json`. Its
`executionPlan` records the active cycle and the queued next cycle explicitly:

- M0 through M3 are the completed task-runtime foundation;
- M4 and M7 closed their bounded Task API/compiler-surface disposition work on
  2026-07-16: every generated declaration carries an authored disposition and
  the target-aware escape boundary is covered. The remaining M4 semantics
  (repeated-wait/new-work cycles, non-nil TaskExecutor preferences,
  arbitrary-actor operation executors) are demand-deferred — they reopen only
  when a real interpreted program fails on a cited declaration — so M4 stays
  partial by design;
- M5 actor/executor architecture has closed its demand-scoped cycle: actor
  identity/storage and serial hops, reentrancy/isolated dispatch, and the
  per-feature fail-closed boundary are covered; the milestone is provisional
  while its broad M4/M7 dependencies remain partial;
- the M6 demand slice is active and partial. Finite success, typed source
  failure, and cooperative user-iterator cancellation for protocol `for await`
  over interpreted witnesses are covered together with early `break` and
  `continue`/`return` plus per-iteration and function-level `defer` cleanup;
  protocol-extension defaults for both requirements and typed opaque
  host-bridged iteration are also covered. The first unbounded `AsyncStream`
  producer/consumer slice now owns empty-stream suspension, value delivery,
  finish-to-`nil`, one-shot `.finished`/`.cancelled` callback ordering,
  stable terminal reads, rejected post-finish yield, multiple parked consumers,
  independent and copied iterators, scope-exit cancellation termination,
  non-owning escaped producer handles, and exact positive-capacity
  `.bufferingNewest(2)` plus `.bufferingOldest(2)` result/retention semantics
  and both zero-capacity boundaries. The shared kernel also owns one unbounded
  `AsyncThrowingStream` suspended-consumer/value/source-error/cleanup slice;
  normal finish, `.finished(nil)` callback timing, buffered retention, stable
  nil, and rejected post-finish yield are also covered. Failure finish adds the
  associated source error callback and later exact rethrow. A cancelled parked
  consumer also receives `.cancelled` synchronously before terminal `nil`.
  Positive-capacity `.bufferingNewest` result/eviction/retention and
  `.bufferingOldest` result/rejection/retention semantics are covered as well.
  At capacity zero both policies return the supplied value as `.dropped` and
  retain nothing. Copied throwing-stream iterators also share the storage's
  single pending-`next()` capability, and a causally overlapping call has
  process-isolated native/interpreter runtime-trap parity. Final-owner
  scope-exit cancellation and non-owning escaped producer-continuation lifetime
  also have exact parity. The first checked-continuation value slice now owns
  explicit-`nil` isolation, one detached-producer resume, required-executor
  restoration, and teardown cleanup. MainActor-specific evidence, throwing and
  unsafe variants, other resume spellings, and diagnostic/lifetime edges remain
  active; complete custom-executor scheduling is not required for those slices;
- M8 view-owned async lifecycle has only covered prerequisites left
  (M2 driver release, M5 logical executor identity, M7 preflight) and follows
  the M6 slice; and
- M9 remains deferred until the ownership/isolation/lifecycle prerequisites are
  complete.

M5 was intentionally decomposed, and its slices were ordered so that no flip to
fail-closed rejection lands before the replacement runtime exists. The covered
entry slice installs actor identity/storage, serial executor hops, and
replayable mailbox stress for the measured demand shapes — `@MainActor`
isolation and user-declared global actors of the FoodTruck StoreActor shape —
while valid actor declarations keep executing through the documented
class-like compatibility path. The second slice now covers arbitrary
struct-/enum-backed global-actor capabilities and defaulted isolated dispatch.
The final slice flipped each remaining actor feature to fail-closed diagnosis
as its replacement landed. Custom-executor declarations are collected, but
their isolated entry fails explicitly; a global up-front rejection remains
forbidden because corpus and application ratchets may never decrease.

A dependency-ready characterization may land before an earlier partial
milestone closes. It must not claim guarantees supplied by an open dependency,
and unexplained failures still block all dependent work. The executable matrix,
not chronological prose, determines what may close.

### Demand-ordered scheduling

Measured 2026-07-16 across the 669-project `External/` corpus and the
FoodTruck primary target (source grep; corpus counts are projects using the
construct at least once):

| Construct | Corpus projects | FoodTruck |
| --- | --- | --- |
| `Task {}` | 41 | 13 uses |
| `Task.sleep` | 41 | yes |
| `.task {}` modifier | 30 | 4 uses |
| `Task.detached` | 12 | 1 use |
| `actor` declarations | 9 | `@globalActor StoreActor` |
| `@MainActor` | 5 | 17 uses |
| `withCheckedContinuation` family | 2 | 0 |
| `withTaskGroup` family | 2 | 0 |
| `for await` | 2 | StoreKit update streams |
| `async let` | 1 | 0 |
| `AsyncStream` | 1 | 0 |
| `@TaskLocal` | 1 | 0 |
| `withTaskExecutorPreference` | 0 | 0 |

Scheduling rule: work is selected from the `executionPlan` active cycle in
its listed `requirementRefs` order, not from interface enumeration order.
Surface work on constructs with zero measured demand is not schedulable; it
reopens only when a real interpreted program (corpus, FoodTruck, LiveCheck,
TestCheck) fails on a cited declaration. FoodTruck function parity — `.task`
view lifecycle, `@MainActor` model mutation, StoreActor-shaped global actors,
and `for await` over host-bridged async sequences — outranks completeness of
rarely used API families.

### Milestone 0: native parity infrastructure

Deliverables:

- reusable native/interpreter runner;
- compiler fingerprinting;
- bounded process execution;
- exact, allowed-set, partial-order, predicate, diagnostic, and process-isolated
  runtime-trap assertions;
- initial `Docs/ConcurrencyParity.md` ledger;
- existing async tests classified by whether they have a native baseline.

Proof:

- at least one passing exact probe;
- one nondeterministic allowed-set or partial-order probe;
- one compile-time diagnostic probe;
- one intentionally failing interpreter parity case demonstrating the harness.

Exit criterion:

- every subsequent semantic change can start with a committed native fixture.

### Milestone 1: task-owned evaluator context

Deliverables:

- `EvaluationTaskContext` introduced;
- dynamic stacks/counters removed from shared interpreter ownership;
- host callbacks carry the correct task context;
- frame parking no longer resets a global evaluator instance;
- explicit context cleanup at task completion.

Proof:

- controlled interleaving of at least 100 source tasks;
- nested generic/type contexts survive interleaving;
- simultaneous async initializers and extension dispatch do not interfere;
- cancellation cannot restore another task's frames;
- targeted and full suites remain green.

Exit criterion:

- task frame independence is architectural, not dependent on main-actor task
  ordering.

### Milestone 2: task runtime

Deliverables:

- task IDs and records;
- typed logical outcomes;
- suspending `value` and `result`;
- waiter lists;
- task-kind distinction;
- session completion policies;
- cancellation graph and cleanup;
- priority/task-local storage foundations.

Proof:

- native differential tests for all Task cases in the semantic matrix;
- no placeholder reads from incomplete tasks;
- unstructured task behavior is not mislabeled as structured;
- session drain policy is tested separately from language lifetime.

### Milestone 3: suspension, clocks, and cancellation handlers

Deliverables:

- first-class suspension reasons;
- real non-blocking yield;
- real cancellable sleep;
- manual test clock;
- cancellation handlers;
- distinct source cancellation and host session abortion.

Proof:

- no wall-clock sleeps in deterministic unit tests;
- cancellation races covered by repeat/stress probes;
- executor is free to run another task while one sleeps.

### Milestone 4: structured concurrency

Deliverables:

- syntax/evaluation for `async let`;
- structured scope records;
- task and throwing task groups;
- group iteration and cancellation;
- scope-exit cleanup.

Proof:

- native differential coverage for normal, early-return, throwing, and
  cancellation paths;
- no structured child outlives its required scope;
- no group rule inferred solely from documentation.

### Milestone 5: actor support and executor architecture

Slice order (2026-07-16 demand cycle): the covered first slice supplies actor
identity/storage, serial executor hops, and replayable mailbox stress for the
measured demand shapes (`@MainActor` isolation and user-declared global actors
of the FoodTruck StoreActor shape); the covered second slice completes
arbitrary struct-/enum-backed global-actor capability dispatch; the active
final slice applies
per-feature fail-closed flips to the class-like compatibility path. A feature
fails closed only once its actor-runtime replacement lands — never as an
up-front global rejection — because board ratchets may never decrease.

Deliverables:

- actor storage and IDs;
- logical executor queues;
- actor/global-actor hops;
- actor reentrancy;
- runtime isolation checks;
- MainActor bridge;
- nonisolated and isolated metadata.

Proof:

- actor semantic matrix passes;
- controlled reentrancy matches compiled Swift;
- no actor storage access outside its executor;
- scheduler-order accidents are not asserted.

### Milestone 6: async sequences and continuations

Entry gate (2026-07-16 demand re-plan): executor-owned resume from the M5
identity/storage slice — full M5 reentrancy closure is not required. The
demand slice covers protocol `for await` iteration,
`AsyncStream`/`AsyncThrowingStream`, and checked continuations resuming on
cooperative-default and MainActor executors, including host-bridged async
sequences of the StoreKit update-stream shape, before the remaining surface.
The finite interpreted-witness success and typed-error paths are covered;
cooperative cancellation of a consuming task while `next()` is suspended and
`break`/`continue`/`return` with per-iteration and function-level `defer`
cleanup plus protocol-extension defaults for both requirements are also
characterized. Typed opaque host sequences of the StoreKit update-stream shape
also dispatch through the same requirements with runtime-owned host
suspension. The first unbounded `AsyncStream` slice also suspends an empty
consumer in a runtime-owned stream registry, delivers two producer values, and
terminates at `nil` after `finish()` with complete cleanup. A controlled
follow-up cancels a parked consumer and proves the one-shot `.cancelled`
termination callback occurs before `next()` resumes with `nil`. Another exact
characterization proves explicit `finish()` invokes `.finished` before
returning, retains buffered values, produces stable terminal `nil`, and rejects
post-terminal yield. Two independently-created iterators are also proven to
park simultaneously and drain from one `finish()`. Value-copied iterators also
own independent mutable next tokens while sharing storage and distributing
yielded elements. Releasing the final unfinished storage reference at scope
exit synchronously invokes `.cancelled` before the caller continues.
An escaped producer continuation does not extend that lifetime, returns
`.terminated` from later `yield`, and cannot invoke the callback again when it
is released. A synchronous bounded-buffer probe additionally proves that
`.bufferingNewest(2)` reports remaining capacities `1` then `0`, returns the
displaced values `1` then `2`, and drains only `3`, `4`, then `nil`.
Its `.bufferingOldest(2)` counterpart reports the same capacities, rejects and
returns new values `3` then `4`, and drains only `1`, `2`, then `nil`.
At capacity zero both policies return the supplied element as `.dropped`, keep
no buffered value, and read terminal `nil` after finish. Negative capacities
remain explicitly unsupported. The first unbounded throwing-stream slice also
suspends an empty consumer, delivers one value, then rethrows the exact source
error supplied to `finish(throwing:)` after that value drains, using the same
runtime record and cleanup kernel. Normal throwing finish,
`.finished(nil)` callback timing, buffered retention, stable nil, and rejected
post-terminal yield are covered separately. Failure finish also synchronously
delivers `.finished(error)` with the original source value before that value is
re-thrown after the prior element drains. Cancelling a parked throwing-stream
consumer synchronously delivers `.cancelled` before terminal `nil`, matching
the nonthrowing storage edge. Positive-capacity `.bufferingNewest` also reports
the same capacity, eviction, and retention semantics through the shared kernel;
positive-capacity `.bufferingOldest` preserves the first values and returns
each later rejected element. At capacity zero both policies return the supplied
element as `.dropped`, keep no value, and read terminal `nil`. A copied-iterator
probe additionally proves that one throwing stream permits only one pending
`next()` across copies: after `Task.immediate` causally reaches the first
suspension, a second call traps in both isolated native and interpreted
processes. Final-owner scope exit also synchronously delivers `.cancelled`
before its caller continues. An escaped throwing producer continuation likewise
does not retain storage, returns `.terminated` after owner release, and is inert
on its own release. The first source checked-continuation slice separately owns
a bounded runtime record, delayed value resume, required-executor restoration,
and infrastructure-abort cleanup. Its remaining isolation, error, diagnostic,
and lifetime edges remain active rather than being inferred from stream
behavior.

Deliverables:

- async protocol iteration;
- `for await` control flow;
- streams and termination;
- checked continuations;
- executor-correct resume.

Proof:

- sequence/continuation matrix passes;
- double resume and leaks are diagnosed;
- cancellation cleans suspended consumers.

### Milestone 7: compiler-backed concurrency checking

Deliverables:

- generated host declaration module;
- cached compiler preflight;
- native diagnostics surfaced with source locations;
- isolation/effect metadata attached to declarations;
- clear editor-recovery policy.

Proof:

- diagnostic matrix matches real compiler categories;
- legal programs continue to execute;
- gateway declarations participate in type checking;
- toolchain/SDK changes invalidate the cache.

### Milestone 8: SwiftUI lifecycle

Deliverables:

- canonical concurrency runtime used by view tasks;
- view-identity task ownership;
- cancellation on removal/ID change;
- async modifiers and callbacks;
- main-actor model mutation rules.

Proof:

- compiled SwiftUI twin probes where headless execution is stable;
- lifecycle-specific tests where pixels are irrelevant;
- no task/session retention after view teardown.

### Milestone 9: optional physical parallelism

Prerequisites:

- completed ownership matrix;
- executor isolation in runtime;
- Sendable preflight;
- no shared evaluator state;
- stress suite and leak detection.

Deliverables:

- core target no longer package-wide MainActor by necessity;
- detached/background executors;
- synchronized or confined heap components;
- Thread Sanitizer runs;
- deterministic cooperative executor remains available for tests.

Proof:

- parallel stress tests have no races or invariant violations;
- semantic parity is unchanged between cooperative and parallel runtime modes.

## 15. Verification gates

### Per iteration

- declare the change as gap closure or characterization under
  `ConcurrencyVerificationMethodology.md`;
- compile and run the new native probe in a bounded process;
- run the equivalent interpreted case in a bounded process;
- for gap closure, capture the failing interpreter observation before the fix;
- for characterization, record that no production change was required;
- add a focused ownership/state/cleanup regression where applicable;
- run the relevant test filter;
- inspect the diff for app/probe-specific behavior;
- update the acceptance matrix and parity ledger.

### Per milestone

- all milestone native parity fixtures;
- `swift test --filter AsyncExecutionTests`;
- `swift test --filter HostSignatureTests`;
- relevant SwiftUI bridge tests;
- full `swift test`;
- repository closing gate (`Scripts/gate.sh`) when supported by the current
  environment;
- fresh-process cleanup/leak check;
- non-vacuous milestone stress/race requirements;
- retained machine-readable verification receipt;
- documentation/status audit.

Tests and thresholds are never weakened merely to preserve a previous claim.
If native Swift disproves an existing expectation, the expectation is changed
only together with the native fixture and an explanation.

## 16. Design risks and mitigations

### Risk: copying more fields into a task snapshot instead of fixing ownership

Mitigation: reject new shared dynamic evaluator fields. Every such field must
be placed in `EvaluationTaskContext`, immutable program metadata, or an
explicitly shared runtime service.

### Risk: conflating native main actor with interpreted MainActor

Mitigation: represent source executors logically even while all instructions
are physically driven on the native main actor. Executor hops remain visible to
the scheduler and tests.

### Risk: testing accidental scheduling order

Mitigation: require barriers and a written native guarantee classification.
Use partial-order assertions and repeat probes.

### Risk: implementing a second incomplete Swift type checker

Mitigation: use compiler-backed preflight for isolation and Sendable rules.
Keep dynamic runtime validation focused on executor safety and host bypasses.

### Risk: duplicated sync and async semantics

Mitigation: keep non-suspending semantic kernels shared. Move toward an
explicit frame machine that both sync and async drivers can execute.

### Risk: actual parallelism races through `Box` and `Instance`

Mitigation: remain cooperative until ownership, isolation, Sendability, and
stress tests are complete.

### Risk: session waits hiding incorrect unstructured-task semantics

Mitigation: separate source task relationships from host session completion
policy and test both.

### Risk: host gateways resume on the wrong context

Mitigation: every async host operation captures task and executor IDs, not a
bare interpreter reference. Resume always routes through `ConcurrencyRuntime`.

### Risk: continuations or streams leak sessions

Mitigation: explicit registries, task/session ownership, bounded teardown, and
fresh-process leak tests.

### Risk: toolchain changes alter native behavior

Mitigation: fingerprint compiler and SDK, rerun the entire parity board, and
review changed baselines rather than updating them automatically.

## 17. Architectural decisions to record

Implementation should add short ADRs or a decision section for at least:

1. cooperative executor before physical parallelism;
2. explicit task context rather than shared parked frames;
3. session drain policy separated from structured task semantics;
4. compiler-backed concurrency preflight;
5. logical source MainActor separated from native host MainActor;
6. runtime clock injection;
7. source cancellation separated from fatal session abortion;
8. explicit feature-status taxonomy;
9. same-source native/interpreted fixture doctrine;
10. task/actor limits and teardown policy.

## 18. Definition of done

### One feature

A concurrency feature is complete only when:

1. a minimal native source fixture exists;
2. the active real compiler has compiled or diagnosed it;
3. the guaranteed part of the native behavior is written down;
4. the same semantic source executes through the interpreter;
5. gap closure preserves a captured RED-to-GREEN result, or characterization
   records that the same-source case was already GREEN;
6. success, error, cancellation, and scope-exit paths are covered where
   applicable;
7. the implementation is construct-based rather than fixture-specific;
8. relevant and full regression gates pass;
9. the acceptance matrix and parity ledger record its exact status and
   remaining divergence.

### Stable concurrency foundation

The foundation is stable when:

- each source task owns its evaluator state;
- the shared interpreter no longer parks/restores another task's dynamic
  frames;
- task values have real suspending completion semantics;
- structured and unstructured lifetime are distinct;
- cancellation and cleanup are explicit;
- actors own storage through logical executors;
- actor reentrancy is differential-tested;
- compiler-only isolation and Sendable rules use native preflight;
- host callbacks resume through task/executor identities;
- SwiftUI task lifetime is tied to view identity;
- every unsupported area is diagnosed rather than absorbed;
- the full repository gate is green.

Physical parallelism is not required to call the semantic foundation stable.
It is a separate optimization/capability milestone.

## 19. Autonomous GOAL prompt

Use this concise prompt when creating the long-running GOAL. The rest of this
document is the specification; the expanded execution contract below is for
the agent to read, not something that must be copied into the GOAL field.

```text
Реализуй стабильный фундамент Swift Concurrency для интерпретатора строго по
Docs/SwiftConcurrencyArchitecture.md.

Перед началом полностью прочитай документ и
Docs/ConcurrencyVerificationMethodology.md. Выбери следующий открытый
requirement из executionPlan.currentTail в
Tests/ConcurrencyParity/Manifests/milestone-acceptance.json — в порядке его
requirementRefs, при выполненных dependency; когда активный цикл закрыт,
переходи к entryRequirementRefs из nextMajorCycle. Порядок работ задаёт
demand-ordered scheduling из раздела 14, а не порядок перечисления
swiftinterface. Не бери demand-deferred остаток M4 (executor-preference,
repeated-wait, arbitrary-actor executors) без цитируемого отказа реального
приложения (corpus/FoodTruck/LiveCheck/TestCheck). Двигайся небольшими
проверяемыми изменениями.

Для каждого изменения семантики обязательно:
1. Сформулируй один точный семантический вопрос.
2. Напиши минимальный native Swift probe.
3. Скомпилируй и запусти его реальным swiftc в Swift 6 mode.
4. Зафиксируй только доказанную гарантию, не случайный порядок scheduler.
5. Объяви workflow: gap closure или characterization. Для gap closure сначала
   зафиксируй RED; для уже GREEN characterization не выдумывай ошибку.
6. Добавь same-source differential test.
7. Реализуй минимальный общий механизм без fixture-specific special cases, если
   gap closure требует production change.
8. Доведи проверки до GREEN, обнови acceptance matrix и
   Docs/ConcurrencyParity.md, запусти targeted tests и gate milestone.

Не добавляй silent no-op support, не ослабляй тесты и не затрагивай пользовательские
изменения в worktree. Не переходи к более поздним API, пока не выполнены архитектурные
предпосылки.

Продолжай автономно до Definition of done из этого документа или до настоящего
внешнего блокера.
```

The expanded execution contract follows.

```text
GOAL: implement the target Swift Concurrency architecture described in
Docs/SwiftConcurrencyArchitecture.md, approaching real Swift 6 semantics through
native differential verification at every step.

Workspace:
  /Users/mike/src/tries/2026-07-08-swiftui-dynamic

Authority and scope:
- Modify the interpreter, its host contracts, SwiftUI bridge integration,
  tests, parity harness, and concurrency documentation as required by the
  architecture document.
- Preserve all pre-existing user changes in the worktree.
- Never use destructive git commands.
- Never alter sample application sources to make the interpreter pass.
- Make only small, reviewable semantic steps.

Source of truth:
- Real Swift behavior must be established by compiling a minimal standalone
  probe with the active real swiftc in Swift 6 mode.
- Documentation, memory, existing interpreter behavior, and one observed
  scheduler order are not sufficient evidence.
- Every semantic change declares the gap-closure or characterization workflow.
  Gap closure begins with a failing differential observation; an already-green
  characterization never fabricates RED evidence.

Before the first change:
1. Run `git status --short` and record all existing modifications.
2. Read Docs/SwiftConcurrencyArchitecture.md completely.
3. Read the current async evaluator, program evaluator, task handle, host call
   contracts, and existing async tests referenced by that document.
4. Record swiftc version/path, SDK, target, and strict-concurrency flags.
5. Run the existing targeted async tests to establish the starting baseline.
6. Select the next open acceptance requirement from the executionPlan active
   cycle in milestone-acceptance.json (its requirementRefs order; fall back to
   the nextMajorCycle entry refs when the cycle closes), with satisfied
   dependency edges. Do not skip architectural prerequisites to add later API
   surface, and do not schedule demand-deferred surface remainders (the
   zero-demand M4 executor-preference/repeated-wait semantics) unless a real
   interpreted program failure cites them; section 14 demand ordering, not
   interface enumeration order, decides what is next.

Mandatory native parity loop for every behavior:
1. State one precise Swift semantic question.
2. Write the smallest standalone Swift probe that answers it.
3. Compile with real swiftc, normally using Swift 6,
   strict-concurrency=complete, and parse-as-library.
4. Run the native binary in a bounded process and capture status/stdout/stderr.
5. Repeat when scheduling could vary.
6. Classify the result as exact, allowed-set, partial-order, invariant,
   diagnostic, or unspecified.
7. Write down only the guarantee proved by the probe.
8. Run equivalent source through Interpreter.runAsync.
9. Declare the workflow: capture a failing differential observation for gap
   closure, or record an already-green characterization without inventing RED.
10. For gap closure, implement the smallest general mechanism that closes the
    gap. Characterization does not require a production change.
11. Re-run native and interpreted cases plus targeted regressions.
12. Update the acceptance matrix, Docs/ConcurrencyParity.md, and feature
    status.

Native probe rules:
- Prefer one shared source fixture for native and interpreter execution.
- If wrappers differ, document the exact difference and why it cannot affect
  the tested behavior.
- Do not use arbitrary sleep as synchronization.
- Use controlled actors, continuations, barriers, or host suspension gates.
- Do not assert total task order unless Swift guarantees it.
- Compare partial orders or invariants for nondeterministic scheduling.
- Diagnostic probes use swiftc -typecheck and compare diagnostic category and
  source position, not the complete version-sensitive wording.
- Every process has a timeout; deadlock is a test failure, never an indefinite
  wait.

Implementation doctrine:
- Ownership comes before API breadth.
- Move task-specific evaluator state into EvaluationTaskContext; do not enlarge
  the shared parked-frame workaround.
- Keep ParsedProgram immutable and RuntimeHeap explicitly shared.
- Route all task scheduling, suspension, wake-up, cancellation, executor hops,
  continuations, and structured scopes through ConcurrencyRuntime.
- Distinguish root, unstructured, detached, async-let, group-child, host-callback,
  and SwiftUI tasks.
- Separate language task lifetime from host session drain policy.
- Actor storage is executor-owned; actors are not ordinary classes.
- Implement actor reentrancy by releasing an actor executor at suspension and
  reacquiring it before resume.
- Keep execution cooperative until the ownership/isolation matrix permits
  parallel access safely.
- Use the real Swift compiler for isolation and Sendable diagnostics rather
  than building a second type checker without necessity.
- Async host callbacks carry task and executor identity; they never mutate a
  bare shared interpreter from an arbitrary native task.
- Keep synchronous SwiftUI rendering compatibility explicit and separate from
  canonical runAsync semantics.

Forbidden shortcuts:
- No source-name, app-name, fixture-name, or literal-specific special cases.
- No hardcoded native expected result without a committed native source.
- No silent no-op/absorption counted as support.
- No swallowing errors or cancellation merely to make a test green.
- No exact assertion of an unspecified scheduler order.
- No actual parallel execution of Box, Environment, or Instance before
  ownership and Sendability are enforced.
- No weakening existing tests, gates, or ratchets.

Iteration report:
At the start of each iteration report:
- current milestone;
- semantic question;
- native probe path/source;
- expected assertion kind.

After native execution report:
- toolchain fingerprint;
- compiler/run result;
- repetitions when applicable;
- guaranteed invariant and explicitly unasserted behavior.

After implementation report:
- root cause;
- general mechanism changed;
- native/interpreter parity result;
- targeted tests;
- milestone/full gate status;
- next smallest open parity gap.

Verification:
- Every iteration runs the new native differential case and relevant test
  filter.
- Prefer `Scripts/run-concurrency-iteration.sh CASE_ID TEST_FILTER` for that
  inner loop: it performs one build and then runs focused parity, the targeted
  suite, and methodology concurrently against the prebuilt bundle. Do not try
  to parallelize several `swift test --skip-build` commands; SwiftPM still
  serializes them on its shared build-directory planning lock.
- Every milestone runs AsyncExecutionTests, HostSignatureTests, all concurrency
  parity tests, full swift test, and Scripts/gate.sh when available.
- Run fresh-process cleanup checks for task/continuation/static-state leaks.
- Inspect git diff before staging; include only changes belonging to this GOAL.
- Commit only a green, minimal semantic step, and name the native parity case
  it closes.

Completion:
- Continue with the next dependency-ready open acceptance requirement in the
  executionPlan active-cycle order.
- A feature is not complete until it has a compiled native fixture, a written
  guarantee, a differential test, general implementation, cancellation/error
  coverage where applicable, green gates, and an updated parity status.
- The GOAL is complete only when the stable-foundation definition in
  Docs/SwiftConcurrencyArchitecture.md is satisfied and all remaining
  divergences are explicit and tested.
```

## 20. Initial implementation priorities

The first three code changes should be architectural, not surface additions:

1. Introduce native parity harness infrastructure and the parity ledger.
2. Introduce `EvaluationTaskContext` and migrate one complete async call path
   without changing observable behavior.
3. Introduce task IDs/records and make `task.value` a real suspension path.

Only after those foundations are green should implementation proceed to
`async let`, task groups, or actor isolation.

## 21. Review checklist

Before accepting any concurrency change, reviewers ask:

- Where is the compiled native probe?
- Which behavior is guaranteed, and which observed order is intentionally not
  asserted?
- Does the same source run through both sides?
- Which task/context owns every new mutable field?
- What happens on cancellation before, during, and after suspension?
- What happens on error and early scope exit?
- Which executor owns the resumed work?
- Can a host callback re-enter while another task is suspended?
- Is the implementation general or keyed to the fixture?
- Is interface-encoded API surface generated and attached to a reusable
  semantic intrinsic instead of recognized by another raw source-name branch?
- Does synchronous compatibility hide a canonical async failure?
- Is this feature exact, partial, compatibility-only, or unsupported?
- Is this gap closure with captured RED evidence, or an already-green
  characterization?
- Are native and interpreted executions bounded, and does the shard receipt
  prove exact manifest coverage?
- Is the fixture assigned to an acceptance requirement, and does the closing
  receipt identify the exact source/toolchain/manifest?
- Did the full gate preserve every existing ratchet?

If any answer is missing, the change is not ready to claim parity.
