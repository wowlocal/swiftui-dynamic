# Swift Concurrency parity ledger

This ledger records facts established by compiling the committed native probes
with the active Apple Swift toolchain. It distinguishes language guarantees
from observed scheduler order and tracks interpreter support without silent
fallbacks.

Target architecture and verification doctrine:
[`SwiftConcurrencyArchitecture.md`](SwiftConcurrencyArchitecture.md).

## Toolchain baseline

Initial Milestone 0 run:

- Apple Swift 6.2.3 (`swift-6.2.3-RELEASE`);
- target `arm64-apple-macosx26.0`;
- macOS 26.5 SDK;
- language mode Swift 6;
- `-strict-concurrency=complete`.

`ConcurrencyParityTests.toolchainFingerprintIsComplete` captures the live
compiler path, complete version output, SDK path, and SDK version on every run.
These values are evidence metadata, not hard-coded pass criteria beyond Swift
major version 6.

## Milestone status

| Milestone | Status | Evidence | Remaining work |
|---|---|---|---|
| M0 native parity infrastructure | complete | Same-fixture runner, compiler fingerprint, bounded processes, repeated runtime probes, diagnostic fixture, negative control, cleanup probe; repository gate green at 678/680 corpus units | None |
| M1 task-owned evaluator context | complete | `EvaluationTaskContext` owns dynamic stacks/counters; 100 generic/type and 100 async-initializer siblings have distinct contexts; parked shared-frame restoration is removed; detached host callbacks explicitly rebind; cancellation inside an async initializer leaves sibling extension context intact; closing gate green | None; M2 may begin |
| M2 task runtime | in progress | Runtime-owned task IDs/records distinguish root, unstructured, and detached tasks; task reads suspend; session policies are task-kind neutral; cancellation request/observation is separate from terminal outcome; cancellation during another task's value wait, creation lineage, base/effective priority, direct/transitive escalation, task-local storage, and source `@TaskLocal` declaration/projection are natively covered | Standalone cancellation-before-start, task-handle deallocation, and remaining structured task creation/cancellation cases |
| M3 suspension and clocks | not started | Bridge `Task.sleep`/`yield` remain compatibility behavior | Runtime clock and first-class suspension |
| M4 structured concurrency | unsupported | No `async let` or task-group evaluator | Requires M1–M3 |
| M5 actors and executors | compatibility-only | Actors currently have class-like reference semantics | Actor storage, executors, hops, reentrancy |
| M6 async sequences/continuations | unsupported | No protocol-level async iteration or continuation runtime | Requires scheduler foundation |
| M7 compiler preflight | not started | Native diagnostic fixtures exist only in parity harness | Host stub module and surfaced native diagnostics |
| M8 SwiftUI lifecycle | partial | Existing `.task` compatibility is not view-lifetime parity | Canonical runtime and identity cancellation |
| M9 physical parallelism | intentionally deferred | Core remains main-actor isolated | Requires stable ownership/isolation foundation |

## Committed native facts

| Case | Assertion | Native fact | Interpreter status |
|---|---|---|---|
| `async-function-exact` | exact | Awaiting the fixture function returns `ready` | Expected native parity |
| `main-actor-task-partial-order` | partial order | A newly created MainActor task does not execute inline; `sync` precedes both task events | Expected native parity through async-session drain policy; relative child order is not asserted |
| `task-owned-evaluator-context` | predicate / event multiset | 100 sibling MainActor tasks preserve their own local index and lexical nested type across a forced yield; completion order is unspecified | Native parity in 20 native and 20 interpreter repetitions; each source task also has a distinct, explicitly cleaned evaluator context |
| `task-context-cancellation` | exact invariant | A task cancelled only after entering a cancellable suspension completes as cancelled; an interleaved sibling resolves its extension-scoped nested type and returns `beta` | Native/interpreter parity in 20 repetitions; no start-order assumption because the cancellation uses an explicit started barrier |
| `detached-host-context-reentry` | exact | `Task.detached` does not inherit a TaskLocal value; explicit capture/rebind preserves it inside an async callback | Native/interpreter parity in 20 repetitions; the interpreter host checks exact `EvaluationTaskContext` ID equality after detached re-entry |
| `async-initializer-context` | predicate / event multiset | 100 extension-declared async initializers preserve their argument and lexical nested type across suspension; completion order is unspecified | Native/interpreter parity in 20 repetitions; 100 distinct evaluator contexts are explicitly cleaned |
| `async-initializer-outcomes` | exact | Async initializers preserve successful, thrown-through-`try?`, failable-success, and failable-nil outcomes across suspension | Native/interpreter parity in 20 repetitions: `success,threw,accepted,rejected` |
| `task-value-success` | exact | `await task.value` suspends until completion and returns the successful value | Native/interpreter parity in 20 repetitions with a gate-forced trace: `child-start,before-value,child-end,value` |
| `task-value-failure` | exact | A throwing task preserves its source failure across suspension and `try await task.value` throws it to the caller | Native/interpreter parity in 20 repetitions; catchability is asserted without coupling to error text |
| `task-value-multiple-waiters` | predicate / event multiset | Multiple tasks may concurrently await the same task and every waiter receives its one completed success value | Native/interpreter parity in 20 repetitions; both interpreted waiters are simultaneously registered on one task record and relative resume order is not asserted |
| `task-value-waiter-cancellation` | exact | Cancelling a task while it awaits another unstructured task's value neither ends the value wait nor cancels the target; the waiter receives the value and remains marked cancelled | Native/interpreter parity in 20 repetitions: `target-active,waiter-cancelled,handle-cancelled`; request/observation order and cleanup of both wait-graph edges are verified directly |
| `task-result` | exact | `await task.result` waits and returns `.success`/`.failure` without throwing the failure from the property read; `get()` rethrows it | Native/interpreter parity in 20 repetitions: `success:value,failure,get-caught` |
| `task-result-cancellation` | exact | A throwing task cancelled during a cancellable suspension completes its result as `.failure` | Native/interpreter parity in 20 repetitions; the fixture asserts case shape rather than error text |
| `task-detached-value` | exact | A detached operation may suspend and its handle value awaits and returns the result | Native/interpreter parity in 20 repetitions; the interpreted record is detached, parentless, and physically crosses the native TaskLocal boundary |
| `task-priority-inheritance` | exact | An explicit `.utility` task sees raw priority 17, its unstructured child inherits 17, and a detached task without an explicit priority starts at `.medium`/21 | Native/interpreter parity in 20 repetitions: `17,17,21`; values are captured before any higher-priority handle await can cause escalation |
| `task-priority-escalation` | exact | A high-priority value waiter escalates an already-running background task, and a child created afterward inherits the effective priority | Native/interpreter parity in 20 repetitions: `9,25,25`; MainActor barriers put the reads and child creation after waiter registration without asserting scheduler order |
| `task-priority-transitive-escalation` | exact | Priority donation propagates through an awaited task that is itself awaiting another task | Native/interpreter parity in 20 repetitions: `9,25,25`; the utility middle and background bottom tasks both observe high priority |
| `task-local-declaration` | exact | Distinct source `@TaskLocal` declarations with the same member name retain separate identities; synchronous and suspending `withValue` scopes restore correctly, ordinary tasks inherit, and detached tasks do not | Native/interpreter parity in 20 repetitions; three task-owned storage objects are observed and explicitly empty after completion |
| `task-local-inheritance` | exact | A scoped task-local binding is inherited by an unstructured `Task`, absent from `Task.detached`, and restored after a nested binding exits | Native/interpreter parity in 20 repetitions: `parent,parent:child:parent,default`; every interpreted task owns distinct storage and completion clears it |
| `task-local-unwind` | exact | A scoped task-local binding is removed on both a thrown exit and cancellation, so an outer catch observes the inherited parent value | Native/interpreter parity in 20 repetitions: `parent,parent`; both inner values are checked before unwinding and cancellation starts only after an explicit suspension barrier |
| `unstructured-top-level-lifetime` | exact | An unstructured task may continue after its creating function returns; lexical scope does not join it | Native/interpreter parity in 20 repetitions: `returned,task`; interpreter execution uses the explicit drain policy rather than claiming structured ownership |
| `task-cancellation-caught` | exact | A task may catch `CancellationError` and complete successfully while its handle remains marked cancelled | Native/interpreter parity in 20 repetitions: `success:caught,cancelled`; request state and terminal outcome are asserted independently |
| `unstructured-cancellation-isolation` | exact | Cancelling an unstructured task does not cancel another unstructured `Task` that it created | Native/interpreter parity in 20 repetitions: `cancelled,child`; runtime records preserve a creation edge but no structured cancellation edge |
| `actor-isolation-diagnostic` | diagnostic | A nonisolated synchronous function cannot read actor-isolated mutable state | Native fact recorded; interpreter preflight belongs to M7 |

For `main-actor-task-partial-order`, the initial characterization ran both the
native executable and a fresh interpreter 20 times. Every native observation
was `sync,first,second`. The parity assertion does
**not** promote the observed `first < second` order into a language guarantee.
It checks only:

- exactly one `sync`, `first`, and `second` event;
- `sync < first`;
- `sync < second`.

## Existing async test classification

| Existing test | Current oracle | Classification / gap |
|---|---|---|
| `asyncMutatingStructMethodCopiesOutLikeNativeSwift` | Embedded native implementation | Useful differential test, but native source is not yet a standalone fixture |
| `runAsyncMatchesNativeTaskOrdering` | Embedded native task | Over-asserts one complete trace; should migrate to a partial-order fixture |
| `cancellationBeforeStartMatchesNativeTask` | Embedded native task | Differential, but needs standalone repeated fixture and explicit cancellation invariant |
| `runAsyncWaitsForDescendantTasks` | Interpreter-only expectation | Tests session drain compatibility, not native structured-task semantics |
| `synchronousRunRetainsInlineTaskCompatibility` | Interpreter-only | `compatibility-only`, intentionally not native concurrency |
| `synchronousRunBoundsRecursivelyCreatedTasks` | Interpreter-only | `compatibility-only`, bounded renderer behavior |
| `completedSessionsReleaseSchedulerTracking` | Interpreter internal state | Cleanup regression, not native semantic parity |
| `runtimeTaskHandleDispatchesCancellableExtensions` | Interpreter-only | Dynamic protocol-dispatch regression |
| `cancelledEvaluationThrowsCancellationError` | Native host cancellation wrapper | Infrastructure cancellation; must later separate from source cancellation |
| `asyncHostGatewaySuspendsThroughInterpretedFunction` | Event trace from test host | Host integration regression; no compiled same-source fixture yet |
| `interpretedTaskBodyCanAwaitAsyncHostGateway` | Test host result | Host integration regression; no compiled same-source fixture yet |
| `interleavedTasksKeepIndependentLexicalFrames` | `main-actor-task-partial-order` native fact plus value invariant | Both task-specific lexical values survive in task-owned contexts; sibling completion order is deliberately not asserted |
| `asyncGatewayCanReenterSuspendingInterpretedClosure` | Test host result | Host re-entry regression; no standalone native fixture yet |
| `asyncControlFlowIsLazyAndCatchesHostErrors` | Test host counters | Semantically useful; needs native fixture extraction |
| `cancellationInterruptsSuspendedHostGateway` | Native host task cancellation | Host-level cancellation regression; needs source/abort distinction |
| `synchronousEntryRejectsAsyncOnlyGateway` | Host contract expectation | Correct compatibility diagnostic, not compiler-preflight parity |

## Harness guarantees

The Milestone 0 harness currently provides:

- committed standalone Swift fixtures;
- real `swiftc` compilation in Swift 6 strict-concurrency mode;
- live toolchain and SDK fingerprinting;
- bounded compilation and execution with forced termination on timeout;
- equally repeated native and interpreter execution;
- exact, allowed-set, partial-order, predicate, diagnostic, and stress assertion
  machinery;
- same semantic fixture plus minimal native/interpreter runner wrappers;
- a negative-control test that compiles the real exact fixture, injects an
  intentionally wrong interpreter observation, and proves the differential
  assertion rejects it;
- a completion-only stress rule that rejects missing native or interpreter
  observations rather than passing vacuously.

The harness never treats a single observed scheduler order as a total-order
guarantee. Unsupported or compatibility-only behavior remains explicit in this
ledger.

## Milestone 0 verification record

Verification on Apple Swift 6.2.3 and the macOS 26.5 SDK:

- `swift test --filter ConcurrencyParityTests`: 5 tests passed;
- `swift test --filter 'ARCSemanticsTests|ClosureTests|ConcurrencyParityTests|AsyncExecutionTests|HostSignatureTests'`:
  92 tests in 6 suites passed;
- fresh runner process,
  `swift test --skip-build --filter AsyncExecutionTests.completedSessionsReleaseSchedulerTracking`:
  passed and exited, with scheduler tracking empty after consecutive sessions;
- full `swift test`: 706 tests in 141 suites passed, followed by five green
  `--skip-build` full-suite repetitions;
- `Scripts/gate.sh`: suite 706/706, corpus 678/680, live 5/5, and API parity
  345 match / 0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin all
  passed; the unchanged 678 corpus floor is satisfied.

The forced corpus sweep identified all non-passing units:

- `Widgets`: existing ledgered out-of-scope extension surface;
- `oss:Mythic`: existing ledgered app-authored DEBUG precondition crash;
- `CustomTabView` and `oss:Ollamac`: the same `$projection` lookup regression;
- `oss:iina`: an attempted read through a deallocated `unowned` reference.

The three non-ledgered regressions were closed with two construct-level
mechanisms, each characterized against a standalone Swift 6 probe before its
focused interpreter regression:

- projected identifiers such as `$local` now capture the underlying lexical
  wrapper box rather than falling through to an implicit instance lookup;
- a headless synthesized root models the otherwise-absent embedding caller's
  ownership of constructor arguments, including stable reference identity for
  opaque imported values placed in `weak` or `unowned` slots. Ordinary source
  construction and dead-`unowned` trapping remain unchanged.

`CustomTabView`, `oss:Ollamac`, and `oss:iina` consequently pass. `Widgets` and
`oss:Mythic` remain the same explicit ledgered exclusions. The corpus ratchet
and all existing ARC expectations were preserved, so M0 is closed and M1 is
the earliest incomplete milestone.

## Milestone 1 verification record

### Task-owned context foundation

Native question: can 100 sibling MainActor tasks suspend concurrently while
retaining the generic return binding, local value, and lexical nested type
belonging to each task?

The committed `task-owned-evaluator-context` fixture routes every value
through a generic async identity function and one real `Task.yield()`.
Twenty native Swift 6 strict-concurrency runs each produced exactly the same
100-value multiset. The sibling completion order was observed but deliberately
not asserted.

Before the ownership change, the equivalent interpreter run produced the
right observable multiset through the parked-frame workaround, but the
white-box ownership regression saw one shared evaluator context for all 100
tasks. After the change it sees 100 distinct context IDs and verifies that all
retained contexts have released their dynamic stacks after task completion.

Implementation facts:

- counters, annotation/type stacks, lexical owners, active declaration sets,
  recursion guards, and temporary async names are owned by
  `EvaluationTaskContext`, not stored on the shared interpreter;
- `runAsync` creates a fresh root context and every source `Task {}` creates a
  fresh child context;
- suspending host gateways receive `TaskBoundEvalContext`, which carries the
  explicit source context across asynchronous host re-entry;
- `withParkedEvaluatorFrames` and its save/clear/restore protocol no longer
  exist;
- task completion explicitly clears task-owned dynamic state.

Initial foundation verification was 20/20 native and interpreter repetitions,
100 unique expected values, 100 distinct context IDs, and explicit cleanup of
every retained context.

### Cancellation while another context runs

The committed `task-context-cancellation` fixture starts one task inside an
extension-declared `init async throws`, waits on an explicit host barrier
until that initializer has entered a 30-second cancellable suspension, and
only then cancels it. A sibling task suspends once and resolves `Token` from
an extension's lexical scope. The long sleep never reaches its deadline and is
not used for synchronization.

Twenty native Swift 6 runs and twenty equivalent interpreter runs all produced
the exact invariant `cancelled,beta`. This proves that cancellation unwinds
only the cancelled task context; there is no shared parked-frame restoration
that can overwrite the sibling's extension/lexical stacks.

### Detached host callback re-entry

The committed `detached-host-context-reentry` fixture first characterizes the
native boundary: a `Task.detached` body sees the default TaskLocal value rather
than its creator's binding. It then captures and explicitly rebinds that value
around a detached async callback. Twenty strict Swift 6 runs produced
`lost,preserved` exactly.

The interpreter twin performs the same real native detach. Its host support
captures the incoming `TaskBoundEvalContext`, invokes the interpreted closure
from the detached task, and has the nested gateway compare the rebound context
ID with the originating ID. Twenty interpreter runs also produced
`lost,preserved`. Ambient native TaskLocal inheritance is therefore an
integration aid, not the source of truth for host callback ownership.

### Async initializer interleaving and outcomes

`async-initializer-context` alternates two nominal types whose async
initializers are declared in extensions and resolve different nested enum
values. One hundred sibling tasks construct them concurrently. Twenty native
and twenty interpreter runs each produced the complete expected 100-value
multiset, while the white-box proof observed 100 distinct, cleaned evaluator
contexts.

`async-initializer-outcomes` crosses a real yield before every branch and
establishes exact parity for success, a thrown initializer observed through
`try?`, failable success, and failable nil. The synchronous interpreter entry
now rejects an async initializer explicitly instead of entering its body
through a non-suspending path.

The implementation shares one instance-storage seed path between synchronous
and asynchronous construction. Only a selected effect-bearing initializer
body uses `callWithArgumentsSuspending`; ordinary constructors retain the
established synchronous dispatcher.

### M1 closing gate

Final verification on Apple Swift 6.2.3 / macOS 26.5 SDK:

- all committed runtime fixtures passed their native/interpreter repetitions;
- targeted concurrency, host-signature, declaration, value, and ARC suites:
  124 tests in 6 suites passed;
- full `swift test`: 709 tests in 141 suites passed;
- `Scripts/gate.sh`: suite 709/709, corpus 678/680, live 5/5, and API parity
  345 match / 0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin;
- the corpus floor and every API parity ratchet remained unchanged.

M1 is complete: frame independence follows from ownership rather than
main-actor scheduling or save/clear/restore discipline. M2 task-runtime work
may begin.

## Milestone 2 verification record

### Suspending successful task value

`task-value-success` holds a child task behind an explicit MainActor gate.
After the child records `child-start`, the parent records `before-value`,
creates an opener task, and reads `await handle.value`. The opener cannot run
inline on MainActor, so the value read is the suspension point that permits the
gate to open. Twenty native Swift 6 runs produced the exact trace
`child-start,before-value,child-end,value`.

Before the implementation, all twenty interpreter runs returned
`child-start,before-value,()`: synchronous member lookup exposed the empty
result slot before completion. The async evaluator now recognizes a task value
read, waits for an explicit `RuntimeTaskOutcome`, returns success, rethrows a
stored source failure, or propagates cancellation. Twenty interpreter runs
match the native trace.

Verification for this first M2 step:

- `ConcurrencyParityTests|AsyncExecutionTests|HostSignatureTests`: 36 tests
  in 3 suites passed;
- full `swift test`: 709 tests in 141 suites passed;
- synchronous raw task-member access remains a documented compatibility path
  until the complete M2 runtime removes incomplete placeholder reads.

### Throwing task value

`task-value-failure` crosses a real yield, throws a source enum from the task
operation, and reads the handle with `try await value`. Twenty native and
twenty interpreter runs all returned `caught`. The handle stores the original
interpreted thrown value in its failure outcome rather than reducing it to the
diagnostic description used by the compatibility inspection API.

### Runtime records and multiple waiters

Every async interpreter session now creates a runtime-owned root record. Each
source `Task {}` creates a distinct unstructured record whose parent is the
current root or source task ID. The record owns lifecycle state, typed outcome,
native driver, evaluator context, and the IDs of tasks currently waiting for
its result. `RuntimeTaskHandle` is a source-facing reference to that record;
removing a completed record from the active session registry does not invalidate
an escaped handle.

`task-value-multiple-waiters` starts one value-producing task behind an explicit
gate, then starts two sibling waiter tasks. A controller opens the gate only
after both waiters have reached the read. Twenty native Swift 6 runs and twenty
interpreter runs each produced exactly one `first:value` and one `second:value`.
The assertion is an event multiset because Swift does not promise which waiter
resumes first. The interpreter runner additionally observes both distinct
waiter IDs in the source record before opening its gate.

Lifecycle regressions establish that sibling handles have distinct IDs and one
root parent, 100 context-parity tasks have 100 distinct runtime task IDs, and a
completed session leaves the runtime's active-record registry empty.

Verification for the task-record step: the 37 concurrency-parity,
async-execution, and host-signature tests passed; the full suite passed 710
tests in 141 suites. Repository-wide gates remain a milestone-closing check.

### Task result values

`task-result` forces a successful task to wait behind a gate and makes a
second task throw a source enum after a real yield. In twenty native and twenty
interpreter repetitions, `await result` produced `success:value` and `failure`
without throwing at either property read; calling `get()` on the failure then
entered the source `catch`. The pre-implementation interpreter failed before
the switch with `switch was not exhaustive for ()`, proving it had exposed the
old incomplete-result placeholder.

The async evaluator now waits through the same task-record waiter path as
`value` and returns a core `RuntimeResultValue`. Its case shape retains the
original interpreted payload for pattern matching, and `get()` rethrows that
payload. `task-result-cancellation` separately cancels a throwing task only
after it reaches a cancellable suspension. Twenty runs on each side returned
the `.failure` case. Exact cancellation payload typing remains part of the
cancellation-graph work rather than an assertion inferred from error text.

Verification for the result-value step: the 37 concurrency-parity,
async-execution, and host-signature tests passed, followed by all 710 tests in
141 suites.

### Detached source tasks

`task-detached-value` creates a source `Task.detached`, suspends through the
shared yield gateway, and reads its value. Twenty native and twenty interpreter
runs returned `detached`. Before implementation, the interpreter returned an
inert `ChainedImplicitCall` instead of a task value.

The `Task.detached` static member now routes through `EvalContext` into the same
runtime scheduler as other source tasks while selecting a distinct creation
policy. Its record has kind `detached` and no logical parent, owns a fresh
evaluator context, and is driven by a real native `Task.detached`. A white-box
regression runs the interpreter inside a non-default native TaskLocal value and
observes the default value inside the detached host gateway, the detached
record ID as its evaluator owner, a successful stored result, and an empty
active-record registry after session cleanup. This proves the native detached
boundary; source TaskLocal storage and priority inheritance are still open M2
foundations.

Verification for the detached-kind step: the 38 concurrency-parity,
async-execution, and host-signature tests passed, followed by all 711 tests in
141 suites.

### Language lifetime and host session policies

`unstructured-top-level-lifetime` holds a source `Task {}` behind a gate,
records `returned` in its creating function, and opens the gate from another
unstructured task. Twenty native and twenty interpreter runs produced
`returned,task`. The source task remains unstructured; the parity harness sees
its completion because `runAsync` defaults to the explicit
`drainOwnedTasks` host policy.

`runAsync` now accepts three task-kind-neutral completion policies:

- `topLevel` returns with owned unstructured/detached tasks still active;
- `drainOwnedTasks` waits for every task owned by that session, including
  tasks spawned by those tasks;
- `cancelRemainingTasks` cancels remaining owned tasks, waits for native
  completion, and releases their runtime records.

Each run receives a `RuntimeSessionID`, inherited by its owned task records and
contexts. Draining/cancellation filter by that identity rather than by indices
in a shared array. A detached cleanup watcher releases top-level-policy tasks
only after their native task actually completes. The old global
`asyncSessionDepth` has been removed; async scheduling capability now belongs
to the evaluator context, so a task that outlives top-level return can still
spawn another async task.

Focused policy regressions cover early top-level return, a drain session that
must not wait for another session's blocked task, cancellation of a task
already inside host suspension, stored handle state, and empty scheduler/runtime
tracking after cleanup. In a clean worktree, the 41 concurrency-parity,
async-execution, and host-signature tests passed, followed by all 714 tests in
141 suites.

### Cancellation request, observation, and outcome

`task-cancellation-caught` waits inside a throwing suspension, cancels the task
only after the suspension starts, catches `CancellationError` in source, and
then inspects both the result and cancellation flag. Twenty Swift 6.3.3 runs
produced `success:caught,cancelled`. Before implementation, all twenty
interpreter runs produced `failure,cancelled` because cancellation immediately
installed a terminal outcome and bypassed source `catch`.

Task records now retain a deterministic `RuntimeCancellationState`: request
sources plus first request/observation sequence numbers. Requesting cancellation
of a running task marks and wakes its native task but does not choose its
outcome. An uncaught observation completes as cancelled; a source catch may
continue and complete successfully while `isCancelled` remains true. The
white-box regression verifies a `taskHandle` request, later observation, and a
successful stored `caught` result.

Automatic evaluator polling no longer turns an ordinary source-task request
into repeated throws at arbitrary statements. Explicit `Task.checkCancellation`
and cancellable host operations remain catchable. Root native cancellation and
`cancelRemainingTasks` use `InterpreterSessionAbort`, which source catch blocks
cannot consume; boundary code converts it back to the public
`CancellationError` after owned-task cleanup. Existing host-abort and session
cleanup regressions remain green.

Verification for the cancellation request/outcome step: the 42
concurrency-parity, async-execution, and host-signature tests passed, followed
by all 718 tests in 141 suites.

### Creation lineage versus structured cancellation

`unstructured-cancellation-isolation` creates one unstructured task from
inside another. The parent stores the child handle before entering a
cancellable suspension; an explicit started barrier then permits the probe to
cancel the parent, and a separate gate releases the child only afterward.
Twenty Swift 6.3.3 strict-concurrency runs all returned the exact result
`cancelled,child`. No start or resume order beyond those barriers is asserted.

The interpreter already happened to produce that external result because it
had no cancellation graph at all. The pre-implementation white-box regression
therefore exposed the architectural gap directly: the child's `parent` ID was
present, but the parent recorded no creation edge. Task records now keep two
independent ID sets:

- `spawnedTasks` records creation/inheritance lineage for every non-detached
  task with a live creator record;
- `structuredChildren` is populated only for `asyncLet` and `groupChild`
  records and is the only edge traversed by parent cancellation.

Unstructured cancellation consequently cannot reach the child merely because
it was created inside the parent. Detached tasks remain parentless. The sets
store task IDs rather than retaining child records, and the focused regression
also proves that the active registry is empty after completion. Ambient native
driver cancellation is recorded as `inherited`, separately from a genuine
`structuredParent` propagation source.

Verification for this graph-foundation step on Apple Swift 6.3.3 / macOS 26.5
SDK: the 43 concurrency-parity, async-execution, and host-signature tests
passed, followed by all 719 tests in 141 suites.

### Task priority storage and initial inheritance

`task-priority-inheritance` starts an explicit `.utility` task, records
`Task.currentPriority.rawValue`, creates one ordinary unstructured task and one
detached task without an explicit priority, and records both child values. The
probe does not await any of these handles from higher-priority code before the
three observations, so it characterizes initial inheritance rather than
priority escalation. A shared `parityYield` wrapper only lets the MainActor
observer suspend while the recorder is incomplete; it does not participate in
the values under test.

Twenty Apple Swift 6.3.3 strict-concurrency runs produced `17,17,21` exactly:
the explicit utility priority is visible in the parent, the ordinary `Task`
inherits it, and `Task.detached` defaults to medium priority. Before the
implementation, `Task.currentPriority` had no runtime value and the equivalent
interpreter fixture could not complete, eventually hitting its bounded
evaluation budget.

`RuntimeTaskPriority` now keeps the source priority independently of native
scheduler state. Every task record owns `basePriority` and
`effectivePriority`; every `EvaluationTaskContext` carries the effective value
used by source `Task.currentPriority`. Ordinary tasks inherit the creator
context unless an explicit priority is supplied. Detached tasks use the
explicit value or the natively established medium default. The same logical
value is passed to the native task that currently drives cooperative
evaluation. Priority-aware overloads on `EvalContext` retain compatibility for
existing embedders through a fallback to their older task-creation method.

The white-box regression retains all three handles and verifies priority
storage, the ordinary parent edge, detached parentlessness, successful
outcomes, and an empty active-record registry after completion. Await-driven
priority escalation is not inferred from this probe; it is addressed by the
next independently verified step. Task-local storage was also still open at
this point and is addressed afterward.

Verification for this priority-foundation step on Apple Swift 6.3.3 / macOS
26.5 SDK: the 44 concurrency-parity, async-execution, and host-signature tests
passed, followed by all 720 tests in 141 suites.

### Await-driven priority escalation

`task-priority-escalation` starts a `.background` task and lets it record raw
priority 9 before any higher-priority waiter exists. After an explicit started
barrier, a `.high` task opens the low task's gate and immediately reads
`await low.value`. Both operations are MainActor-isolated and there is no
suspension between the gate write and value read, so the low task cannot resume
until the high waiter has been registered. It then reads raw priority 25 and
creates an ordinary child that also reads 25. Twenty Apple Swift 6.3.3 runs
produced `9,25,25` exactly.

`task-priority-transitive-escalation` constructs a second controlled chain.
The utility middle task marks its state and immediately awaits a blocked
background bottom task. Only after that dependency exists does a high task
open the bottom gate and await the middle task. Twenty native runs produced
`9,25,25`: the bottom begins at background, then both bottom and middle observe
high priority. Neither probe asserts which runnable task the scheduler chooses
outside the explicit MainActor barriers.

The first direct differential run captured the intended RED in all twenty
repetitions: native `9,25`, interpreter `9,9`. Runtime waiters previously
existed only as an observational ID set and never affected the awaited task's
logical priority.

Wait registration is now owned by `CooperativeConcurrencyRuntime`. It records
both sides of the dependency, monotonically donates the waiter's effective
priority when it is higher, updates the awaited record and its live
`EvaluationTaskContext`, and propagates an increase through any tasks that the
awaited task is itself waiting on. A visited set makes malformed cyclic wait
graphs safe. Ending an await removes both dependency edges with `defer`; it
does not rewrite immutable `basePriority` or infer a de-escalation that the
native cases did not establish. Donor histories contain task IDs and values,
not retained task records.

The direct white-box regression verifies background base/high effective
priority, the high donor ID, cleaned waiter edges, and high initial priority in
the child created after escalation. The transitive regression verifies high
effective priority in both lower records, the two donation links, cleaned
wait chains, successful values, and an empty active runtime registry.

Verification after both escalation cases: 47 concurrency-parity,
async-execution, and host-signature tests passed in three suites, followed by
all 723 tests in 141 suites.

### Task-local storage and initial inheritance

`task-local-inheritance` scopes the value `parent`, reads it in the creating
task, creates one ordinary unstructured task and one detached task, then
temporarily replaces the ordinary child's value with `child`. Twenty Apple
Swift 6.3.3 strict-concurrency runs produced the exact result
`parent,parent:child:parent,default`. This establishes only the deterministic
inheritance and dynamic-restoration rules; the nested binding crosses one real
`Task.yield`, and the case makes no scheduler-order claim.

The committed fixture is shared verbatim. Native support implements
`parityWithTaskLocalValue` and `parityReadTaskLocal` with a real Swift
`@TaskLocal`; interpreter support exposes the same two declarations through
the task-aware host capability. Before runtime storage existed, all twenty
interpreter repetitions returned
`default,default:default:default,default`, which records the differential RED
rather than relying on a white-box-only failure.

Each runtime task record now owns one `RuntimeTaskLocalStorage`, and its
`EvaluationTaskContext` refers to that same object. A root starts empty. An
ordinary task receives a value-semantic snapshot at creation; a detached task
starts empty. Scoped binding copies the supplied runtime value, restores the
previous binding with `defer`, remains active across the probed suspension,
and never mutates the creator's map. Public host gateways address bindings
through a namespaced `RuntimeTaskLocalKey`. Source-level lowering is covered by
the later declaration case and derives keys from declaration identity rather
than spelling alone.

The white-box regression observes the root, ordinary, and detached reads,
proves that their three storage objects are distinct, proves record/context
storage identity within each task, and retains the objects through completion
to verify explicit cleanup. A non-task-aware host context diagnoses scoped
binding as unsupported instead of silently executing it without a binding.
Direct parsing/lowering of source `@TaskLocal` declarations was not claimed by
this foundation step. Throwing and cancelled scoped exits are covered by the
next independently compiled case; declaration lowering follows afterward.

Focused verification passed 45 concurrency-parity, async-execution, and
host-signature tests in three suites, including 20/20 native/interpreter
repetitions of the new case. The full repository suite passed 721 tests in
141 suites.

### Task-local unwind on throw and cancellation

`task-local-unwind` begins under `parent`. Its first nested binding crosses a
real `Task.yield`, verifies that it sees `throwing`, and throws a source error;
the catch outside that scope then reads `parent`. A child task inherits the
same parent value, verifies a nested `cancelled` binding, enters the shared
30-second cancellable suspension, and is cancelled only after the explicit
wait-started barrier. Its source catch also reads `parent`; the deadline is not
used as synchronization and is never reached.

Twenty Apple Swift 6.3.3 strict-concurrency runs produced `parent,parent`
exactly, followed by the same result in all twenty interpreter repetitions.
The shared native task-local wrapper was generalized from a nonthrowing
operation to `async rethrows`; the source fixture and all control flow remain
identical on both sides.

This case was already GREEN when introduced. No runtime change was made: the
previous task-owned storage implementation deliberately scopes replacement
values with `defer`, so both error paths validated a general mechanism rather
than exposing another special case. The original missing-storage RED remains
the preceding inheritance case's
`default,default:default:default,default` result; manufacturing a new failure
after the mechanism existed would provide no useful evidence.

The differential runner now retains every storage observed by any
`task-local-*` fixture. On each interpreter repetition it additionally proves
that tasks do not share storage objects, each record and evaluator context
refer to the same per-task object, completion empties every retained map, and
the active record registry is empty. Source-level declaration and projection
lowering was still open at this point and is addressed by the next case.

Verification after adding the unwind case: 45 concurrency-parity,
async-execution, and host-signature tests passed in three suites, followed by
all 721 tests in 141 suites.

### Source task-local declarations and projection

`task-local-declaration` declares `PrimaryTaskLocal.value` and
`SecondaryTaskLocal.value` with the real source spelling
`@TaskLocal static var`. The identical member names make accidental
name-based aliasing observable. Under a primary binding, the fixture exercises
the synchronous `withValue` overload, creates an ordinary inherited task and a
detached task, then enters a suspending secondary binding and reads both
declarations after a controlled yield. Every created task is awaited, so the
case asserts no scheduler order.

Twenty Apple Swift 6.3.3 strict-concurrency runs produced one exact value:

```text
primary-default|secondary-default;primary-bound|secondary-default;primary-bound|secondary-sync;primary-bound|secondary-default;primary-default|secondary-default;primary-bound|secondary-bound;primary-bound|secondary-default;primary-default|secondary-default
```

The first differential run reached the intended RED before implementation:
the interpreter reported that `PrimaryTaskLocal` had no static member
`$value`. Its collector had treated `@TaskLocal` as an ordinary cached static,
so there was neither a source declaration identity nor a projected binding
capability.

Collection now recognizes module-qualified or bare `@TaskLocal`, requires a
static `var` with a stored default, and records a
`RuntimeTaskLocalDeclaration`. Its `RuntimeTaskLocalKey` hashes the binding's
SwiftSyntax `SyntaxIdentifier`; the debug spelling is not part of equality.
Consequently declarations named `value` in different types cannot collide,
and host string keys occupy a separate identity domain.

A direct static read first consults the current task-owned map and otherwise
returns the declaration's lazily cached static default using interpreter value
semantics. `$value` returns a dedicated projection rather than an inert wrapper
marker. The projection exposes synchronous and suspending `withValue` paths
through the task-aware host contract; both delegate to scoped storage cleanup,
so error and cancellation restoration reuse the previously proven mechanism.
Unknown projected members diagnose instead of being absorbed.

The white-box regression observes task-local storage at three source yields.
The root has two active bindings, its ordinary child has one inherited binding,
and its detached child has none. All three evaluator contexts point to their
own record-owned storage objects. It also verifies distinct declaration keys,
cached defaults, exact output, empty retained maps after completion, and an
empty active-record registry.

Verification for source declaration support: 48 concurrency-parity,
async-execution, and host-signature tests passed in three suites, followed by
all 724 tests in 141 suites.

### Cancellation while awaiting another task value

`task-value-waiter-cancellation` blocks a target task behind an explicit gate.
A waiter marks that it has started and then immediately reads
`await target.value`. Both the controller and these operations are
MainActor-isolated, with no suspension between the mark and the value read, so
the controller can resume only after the wait edge exists. It cancels the
waiter, observes the handle flag, and only then opens the independent target
gate. No scheduler order outside these barriers is asserted.

Twenty Apple Swift 6.3.3 strict-concurrency runs produced the exact result
`target-active,waiter-cancelled,handle-cancelled`. Thus cancellation does not
interrupt this value wait or propagate to the unstructured target. The waiter
receives the target value, completes successfully, and still observes its own
cancellation flag.

The same-source interpreter differential was already GREEN before a runtime
change. The focused white-box regression captured the architectural RED
instead: the waiter had a `.taskHandle` request and returned from an explicit
`Task.isCancelled == true` read, but its `observationSequence` was still
`nil`. Manufacturing a different source result would have contradicted the
existing general wait and cooperative-cancellation behavior.

Source evaluation of `Task.isCancelled` now snapshots the native flag and,
when it is true, records the first source observation in the owning runtime
task. Observation is bookkeeping only: it neither throws nor chooses a
terminal outcome. The regression verifies request-before-observation order,
the waiter's successful cancelled-marked outcome, the target's independent
successful outcome, removal of both wait-graph edges, and an empty active
registry.

Verification on Apple Swift 6.3.3 / macOS 26.5 SDK: 50 concurrency-parity,
task-cancellation, async-execution, and host-signature tests passed in four
suites, followed by all 727 tests in 142 suites.
