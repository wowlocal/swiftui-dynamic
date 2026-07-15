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
| M2 task runtime | complete | Runtime-owned task IDs/records distinguish root, unstructured, and detached tasks; task reads suspend, reject missing `await`, and preserve completed typed outcomes; session policies are task-kind neutral; cancellation request/observation is separate from terminal outcome; cancellation before entry and during another task's value wait, dropped-handle lifetime, creation lineage, base/effective priority, direct/transitive escalation, task-local storage, source `@TaskLocal` projection, and implicit optional defaults are natively covered; closing repository gate is green | None; M3 may begin |
| M3 suspension and clocks | complete | Incomplete task-value/result reads, external async host gateways, async source `Task.sleep`, and `Task.yield` use runtime-owned `.awaitingTask`/`.awaitingHost`/`.sleeping`/`.yielding` states; host callbacks temporarily restore the source task and nested gateways receive distinct operation IDs; sleep has injected continuous/manual clocks and cancellable wake-up; cancellation handlers and the source/host-abort boundary have same-source Swift 6 parity and deterministic runtime-state coverage; closing repository gate is green at the 678/680 corpus ratchet | None; actor/group/stream/continuation reasons remain with their owning milestones, and M4 may begin |
| M4 structured concurrency | partial | Identifier, tuple-pattern, and multi-binding `async let` declarations create runtime-owned structured children; tuple elements project one stored child outcome, while declaration bindings own distinct children; successful, throwing, and parent-cancelled value reads suspend and preserve their outcomes; parent cancellation propagates both to existing unread children and children created after the request, and unconsumed children join on normal, early-return, throwing, and cancellation exits; `defer` and async-let teardown share Swift's lexical LIFO registration order on normal, early-return, throwing, and owner-cancellation exits; nonthrowing `withTaskGroup`, successful `withThrowingTaskGroup` child consumption, source-error and cancellation projection through throwing `next`, and throwing `waitForAll` success plus completion-ordered source-error/cancellation projection with full remaining-outcome draining, `addTask`, `addTaskUnlessCancelled`, explicit nonthrowing `waitForAll` with remaining-result draining, `cancelAll`, combined owner/`cancelAll` `isCancelled` state, completion-ordered `next` consumption, drained-group `nil`, cancellation inheritance for late ordinary children, cancelled-state initialization when a group is created by an already-cancelled owner, non-cancelling implicit wait on normal group scope exit, normal throwing-group exit that joins children while discarding unconsumed child errors, exceptional body-error exit that cancels and joins children before rethrowing the body error, streaming nonthrowing `for await`, and successful, source-failing, cancelled, plus early-exit throwing `for try await` group iteration have runtime-owned group/scope support; body `defer` order is covered for normal cancelAll-driven, throwing exceptional, and owner-cancelled cleanup; missing `await` is diagnosed | A group child creating its own nested task group lacks differential coverage; escaped-capability runtime coverage and compiler-backed escape diagnostics remain explicit follow-up (the compiler preflight belongs to M7) |
| M5 actors and executors | partial | Runtime tasks and task-owned evaluator contexts carry logical source-executor identity; `@concurrent nonisolated` methods hop to the cooperative default executor, `@MainActor` methods hop back, dynamic calls restore their caller executor, detached tasks start outside MainActor, and the SwiftUI `Thread.isMainThread` bridge projects this source identity instead of leaking the evaluator's physical hosting actor | Actor storage/IDs, executor queues and serialization, arbitrary actor/global-actor isolation, reentrancy, isolated parameters, closure isolation metadata, and physical worker execution |
| M6 async sequences/continuations | unsupported | No protocol-level async iteration or continuation runtime | Requires scheduler foundation |
| M7 compiler preflight | not started | Native diagnostic fixtures exist only in parity harness | Host stub module and surfaced native diagnostics |
| M8 SwiftUI lifecycle | partial | Retained synchronous host actions now enter a fresh runtime-owned `.hostCallback` task/session while preserving inline state mutation; `Button`, generated actions, gestures, bindings, synchronous event modifiers, Objective-C completions, and headless/live action drivers share the runtime entry; uncaught action errors are observable; a same-source Swift 6 differential fixture proves nested `Task.detached` plus `withTaskGroup` execution in 20 repetitions | Give async `.task`/`.task(id:)`/`.refreshable` work `.swiftUITask` identity, view-lifetime cancellation, and teardown cleanup; reconcile queued GCD delivery policy with runtime entry semantics |
| M9 physical parallelism | intentionally deferred | Core remains main-actor isolated | Requires stable ownership/isolation foundation |

## Committed native facts

| Case | Assertion | Native fact | Interpreter status |
|---|---|---|---|
| `async-function-exact` | exact | Awaiting the fixture function returns `ready` | Expected native parity |
| `async-try-await-conditional` | exact | A throwing async call remains awaited when its optional result is compared with `nil` as the condition of a ternary expression | Native/interpreter parity in 20 repetitions: `nil`; the fixture yields once inside the call but makes no scheduler-order claim |
| `host-gateway-suspension` | exact | Awaiting the controlled async wrapper suspends until its explicit gate opens, so a ready MainActor controller records progress before the wrapper returns | Native/interpreter parity in 20 repetitions: `before,host-enter,controller,host-exit,value`; the interpreted caller is `.waiting/.awaitingHost(operationID)` at the forced barrier and the operation registry is empty after completion |
| `host-callback-task-runtime` | exact | A synchronous MainActor callback exposes its inline mutation before returning, while an unstructured task it creates continues through Swift concurrency and may own structured group children | Native/interpreter parity in 20 repetitions: `started,done-3`; the interpreter fires the retained closure only after its initial evaluation has returned, enters `.hostCallback`, and finishes with empty task/group/scope registries |
| `main-actor-task-partial-order` | partial order | A newly created MainActor task does not execute inline; `sync` precedes both task events | Expected native parity through async-session drain policy; relative child order is not asserted |
| `concurrent-executor-hop` | exact | A `@concurrent nonisolated` async method leaves MainActor for entry and post-yield continuation, an awaited MainActor method runs on the main executor, and both direct and detached callers return to their prior executor afterward | Native/interpreter parity in 20 repetitions: `main\|worker:worker:main\|worker:worker:main\|main`; the interpreter models logical executor identity cooperatively and does not claim physical parallel execution |
| `task-owned-evaluator-context` | predicate / event multiset | 100 sibling MainActor tasks preserve their own local index and lexical nested type across a forced yield; completion order is unspecified | Native parity in 20 native and 20 interpreter repetitions; each source task also has a distinct, explicitly cleaned evaluator context |
| `task-context-cancellation` | exact invariant | A task cancelled only after entering a cancellable suspension completes as cancelled; an interleaved sibling resolves its extension-scoped nested type and returns `beta` | Native/interpreter parity in 20 repetitions; no start-order assumption because the cancellation uses an explicit started barrier |
| `detached-host-context-reentry` | exact | `Task.detached` does not inherit a TaskLocal value; explicit capture/rebind preserves it inside an async callback | Native/interpreter parity in 20 repetitions; the interpreter host checks exact `EvaluationTaskContext` ID equality after detached re-entry |
| `async-initializer-context` | predicate / event multiset | 100 extension-declared async initializers preserve their argument and lexical nested type across suspension; completion order is unspecified | Native/interpreter parity in 20 repetitions; 100 distinct evaluator contexts are explicitly cleaned |
| `async-initializer-outcomes` | exact | Async initializers preserve successful, thrown-through-`try?`, failable-success, and failable-nil outcomes across suspension | Native/interpreter parity in 20 repetitions: `success,threw,accepted,rejected` |
| `task-value-success` | exact | `await task.value` suspends until completion and returns the successful value | Native/interpreter parity in 20 repetitions with a gate-forced trace: `child-start,before-value,child-end,value`; an incomplete interpreted target records `.awaitingTask(targetID)` on the waiter until completion |
| `task-value-failure` | exact | A throwing task preserves its source failure across suspension and `try await task.value` throws it to the caller | Native/interpreter parity in 20 repetitions; catchability is asserted without coupling to error text |
| `task-value-multiple-waiters` | predicate / event multiset | Multiple tasks may concurrently await the same task and every waiter receives its one completed success value | Native/interpreter parity in 20 repetitions; both interpreted waiters are simultaneously registered on one task record and relative resume order is not asserted |
| `task-value-waiter-cancellation` | exact | Cancelling a task while it awaits another unstructured task's value neither ends the value wait nor cancels the target; the waiter receives the value and remains marked cancelled | Native/interpreter parity in 20 repetitions: `target-active,waiter-cancelled,handle-cancelled`; request/observation order and cleanup of both wait-graph edges are verified directly |
| `task-cancellation-before-start` | exact | An unstructured task cancelled before it can start still enters its operation, observes cancellation, may return a normal value, and remains marked cancelled | Native/interpreter parity in 20 repetitions: `body-ran,body-cancelled,handle-cancelled`; the interpreted record succeeds with its returned value while retaining ordered request/observation metadata |
| `task-result` | exact | `await task.result` waits and returns `.success`/`.failure` without throwing the failure from the property read; `get()` rethrows it | Native/interpreter parity in 20 repetitions: `success:value,failure,get-caught` |
| `task-completed-handle-reads` | exact | Once a task has completed, repeated `value` and `result` reads reproduce its stored success or failure, and `Result.get()` continues to rethrow the stored failure | Native/interpreter parity in 20 repetitions: `value,value,success:value,failure,failure,get-caught`; escaped interpreted handles retain typed logical outcomes after active-registry release |
| `task-result-cancellation` | exact | A throwing task cancelled during a cancellable suspension completes its result as `.failure` | Native/interpreter parity in 20 repetitions; the fixture asserts case shape rather than error text |
| `task-detached-value` | exact | A detached operation may suspend and its handle value awaits and returns the result | Native/interpreter parity in 20 repetitions; the interpreted record is detached, parentless, and physically crosses the native TaskLocal boundary |
| `task-priority-inheritance` | exact | An explicit `.utility` task sees raw priority 17, its unstructured child inherits 17, and a detached task without an explicit priority starts at `.medium`/21 | Native/interpreter parity in 20 repetitions: `17,17,21`; values are captured before any higher-priority handle await can cause escalation |
| `task-priority-escalation` | exact | A high-priority value waiter escalates an already-running background task, and a child created afterward inherits the effective priority | Native/interpreter parity in 20 repetitions: `9,25,25`; MainActor barriers put the reads and child creation after waiter registration without asserting scheduler order |
| `task-priority-transitive-escalation` | exact | Priority donation propagates through an awaited task that is itself awaiting another task | Native/interpreter parity in 20 repetitions: `9,25,25`; the utility middle and background bottom tasks both observe high priority |
| `task-local-declaration` | exact | Distinct source `@TaskLocal` declarations with the same member name retain separate identities; synchronous and suspending `withValue` scopes restore correctly, ordinary tasks inherit, and detached tasks do not | Native/interpreter parity in 20 repetitions; three task-owned storage objects are observed and explicitly empty after completion |
| `task-local-implicit-optional-default` | exact | An optional `@TaskLocal` may omit its initializer; its implicit default is `nil`, and a scoped binding restores that `nil` after exit | Native/interpreter parity in 20 repetitions: `nil,bound,nil`; non-optional declarations without a default remain diagnosed |
| `task-local-inheritance` | exact | A scoped task-local binding is inherited by an unstructured `Task`, absent from `Task.detached`, and restored after a nested binding exits | Native/interpreter parity in 20 repetitions: `parent,parent:child:parent,default`; every interpreted task owns distinct storage and completion clears it |
| `task-local-unwind` | exact | A scoped task-local binding is removed on both a thrown exit and cancellation, so an outer catch observes the inherited parent value | Native/interpreter parity in 20 repetitions: `parent,parent`; both inner values are checked before unwinding and cancellation starts only after an explicit suspension barrier |
| `unstructured-top-level-lifetime` | exact | An unstructured task may continue after its creating function returns; lexical scope does not join it | Native/interpreter parity in 20 repetitions: `returned,task`; interpreter execution uses the explicit drain policy rather than claiming structured ownership |
| `task-handle-deallocation` | exact | Discarding the last source-level handle neither cancels an unstructured task nor ends its operation; active task lifetime is independent of handle lifetime | Native/interpreter parity in 20 repetitions: `completed,active`; every interpreted parity repetition also ends with empty scheduler and runtime registries |
| `task-cancellation-caught` | exact | A task may catch `CancellationError` and complete successfully while its handle remains marked cancelled | Native/interpreter parity in 20 repetitions: `success:caught,cancelled`; request state and terminal outcome are asserted independently |
| `unstructured-cancellation-isolation` | exact | Cancelling an unstructured task does not cancel another unstructured `Task` that it created | Native/interpreter parity in 20 repetitions: `cancelled,child`; runtime records preserve a creation edge but no structured cancellation edge |
| `task-sleep-cancellation` | exact | `Task.sleep` suspends without blocking the executor, and cancelling the sleeping task resumes it by throwing `CancellationError` | Native/interpreter parity in 20 repetitions: `started,cancelled`; an explicit started barrier makes the 30-second deadline unreachable within the five-second process bound |
| `task-yield-progress` | stress / completion | Repeated `Task.yield` calls let a ready MainActor sibling make progress | Native/interpreter completion in 20 repetitions; no yield count or relative scheduler order is asserted |
| `task-cancellation-handler-active` | exact | An active handler runs synchronously before `cancel()` returns, is invoked once across repeated requests, and uses the cancelling task's dynamic context | Native/interpreter parity in 20 repetitions: `0,1,1,false,true,done`; MainActor serialization fixes the observation points without choosing a ready-task order |
| `task-cancellation-handler-pre-cancelled` | exact | Registering a handler in an already-cancelled task invokes it immediately, in that task's cancelled dynamic context, before the operation begins | Native/interpreter parity in 20 repetitions: `1,true,true,operation-cancelled`; MainActor prevents operation entry before the two pre-start cancellation requests |
| `task-cancellation-handler-nested` | exact | Simultaneously active nested handlers run once from inner to outer before the cancelled operation resumes | Native/interpreter parity in 20 repetitions: `inner,outer,operation`; a MainActor started barrier fixes the cancel-time happens-before edges without asserting independent task scheduling |
| `task-cancellation-handler-scope-exit` | exact | A handler is inactive after its operation returns or throws, so later cancellation does not invoke it | Native/interpreter parity in 20 repetitions; MainActor exit barriers place cancellation strictly after each unwind, and the runtime regression observes zero registrations at both exit points |
| `async-let-throwing-defer-order` | exact | A throwing scope unwinds `defer` and unread async-let cleanup in reverse lexical registration order, joining the cancelled child before propagating the owner error | Native/interpreter parity in 20 repetitions for both registration orders: `child-start,scope-throw,child-cancelled,defer,caught\|child-start,scope-throw,defer,child-cancelled,caught` |
| `async-let-early-return-defer-order` | exact | An early return unwinds `defer` and unread async-let cleanup in reverse lexical registration order, joining the cancelled child before the caller receives the returned value | Native/interpreter parity in 20 repetitions for both registration orders: `child-start,early-return,child-cancelled,defer,returned\|child-start,early-return,defer,child-cancelled,returned` |
| `async-let-cancellation-defer-order` | exact | Cancelling an owner preserves reverse lexical registration order between `defer` and unread async-let cleanup, joins the child before returning the owner value, and leaves cancellation observable on both tasks | Native/interpreter parity in 20 repetitions for both registration orders: `scope-exit,child-complete,defer,returned:cancelled\|scope-exit,defer,child-complete,returned:cancelled` |
| `async-let-created-after-owner-cancellation` | exact | An async-let child created after its owner is already cancelled starts with the owner's structured cancellation request | Native/interpreter parity in 20 repetitions: `owner-cancelled:child-cancelled`; an ordinary unstructured child created at the same runtime boundary remains uncancelled |
| `task-group-defer-cancel-cleanup-order` | exact | A body `defer` runs before `withTaskGroup` performs its implicit join, so `cancelAll` from that defer reaches an already-started child | Native/interpreter parity in 20 repetitions: `child-start,body-return,defer-cancel,child-cancelled,after-scope`; the outer scope resumes only after the child completes |
| `task-group-throwing-defer-cleanup-order` | exact | A throwing task-group body runs its `defer` before exceptional cleanup cancels and joins an outstanding child, and preserves the body error | Native/interpreter parity in 20 repetitions: `child-start,body-throw,defer,child-cancelled,caught-body`; the outer catch runs after both cleanup phases |
| `task-group-owner-cancellation-defer-cleanup-order` | exact | An owner-cancelled task still runs the task-group body `defer`, joins its cancelled child, and only then publishes its successful value while retaining handle cancellation | Native/interpreter parity in 20 repetitions: `child-start,scope-exit,defer,child-cancelled,returned:cancelled`; the child is released only by the defer |
| `task-group-throwing-implicit-failure` | exact | A normal `withThrowingTaskGroup` body return joins an unconsumed failing child, discards that child error, and preserves the body value | Native/interpreter parity in 20 repetitions: `child-start,body-return,child-failed,scope-return-body-value`; the gate proves the join, while `rethrows` makes the child error unobservable without `next`/`waitForAll` |
| `task-group-throwing-body-throw` | exact | If a `withThrowingTaskGroup` body throws, exceptional scope exit cancels and joins each outstanding child before rethrowing the body's source error | Native/interpreter parity in 20 repetitions: `child-start,body-throw,child-cancelled,caught-body`; a started barrier and structured join establish every edge without selecting ready-task order |
| `task-group-iteration` | exact | `for await` over a nonthrowing `TaskGroup` yields every child result exactly once and consumes the group | Native/interpreter parity in 20 repetitions: `3:6:empty`; count and commutative sum avoid asserting completion order, and the trailing `next()` proves the completion queue is drained |
| `task-group-throwing-iteration` | exact | `for try await` over a `ThrowingTaskGroup` yields every successful child result exactly once and consumes the group | Native/interpreter parity in 20 repetitions: `3:6:empty`; the throwing group uses the same completion queue as `next()`; failure, cancellation, and early exit have dedicated committed cases |
| `task-group-throwing-iteration-failure` | exact | A failed child consumed by `for try await` rethrows its source error, then exceptional group exit cancels and joins an outstanding sibling before the outer catch runs | Native/interpreter parity in 20 repetitions: `sibling-start,child-failed,sibling-cancelled,caught-child`; the started barrier, failure propagation, and structured join establish every edge |
| `task-group-throwing-iteration-cancellation` | exact | A cancelled child consumed by `for try await` throws `CancellationError` without cancelling the owner; exceptional group exit joins every sibling before the outer catch runs | Native/interpreter parity in 20 repetitions: `cancellation:owner-active:joined`; an explicit started barrier fixes the relevant edges, while child completion order is deliberately not asserted |
| `task-group-throwing-iteration-early-exit` | exact | Breaking out of `for try await` does not cancel a remaining throwing-group child; normal group scope exit joins it and leaves the owner active | Native/interpreter parity in 20 repetitions: `first:active:owner-active:joined`; a started barrier and explicit release make every asserted edge deterministic |
| `task-read-missing-await-diagnostic` | diagnostic | `Task.value` and `Task.result` are async property accesses, so omitting `await` is rejected even inside an async function | Real Swift 6 diagnostics require `await`; runtime member dispatch now diagnoses instead of returning `()` for either property |
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
| `cancellationBeforeStartMatchesNativeTask` | Embedded native task plus committed `task-cancellation-before-start` fixture | Kept as a focused regression; the standalone fixture now supplies the repeated same-source baseline and explicit operation-entry invariant |
| `runAsyncWaitsForDescendantTasks` | Interpreter-only expectation | Tests session drain compatibility, not native structured-task semantics |
| `synchronousRunRetainsInlineTaskCompatibility` | Interpreter-only | `compatibility-only`, intentionally not native concurrency |
| `synchronousRunBoundsRecursivelyCreatedTasks` | Interpreter-only | `compatibility-only`, bounded renderer behavior |
| `completedSessionsReleaseSchedulerTracking` | Interpreter internal state | Cleanup regression, not native semantic parity |
| `runtimeTaskHandleDispatchesCancellableExtensions` | Interpreter-only | Dynamic protocol-dispatch regression |
| `cancelledEvaluationThrowsCancellationError` | Native host cancellation wrapper plus runtime-state regression | Public host cancellation remains `CancellationError`, while the internal non-catchable abort records only `.hostTask` and bypasses source `catch` |
| `asyncHostGatewaySuspendsThroughInterpretedFunction` | `host-gateway-suspension` native fact plus event trace from test host | Host integration regression backed by the compiled same-source suspension fixture |
| `interpretedTaskBodyCanAwaitAsyncHostGateway` | `host-gateway-suspension` native fact plus test host result | Host integration regression backed by the compiled same-source suspension fixture |
| `interleavedTasksKeepIndependentLexicalFrames` | `main-actor-task-partial-order` native fact plus value invariant | Both task-specific lexical values survive in task-owned contexts; sibling completion order is deliberately not asserted |
| `asyncGatewayCanReenterSuspendingInterpretedClosure` | Test host result | Host re-entry regression; no standalone native fixture yet |
| `asyncControlFlowIsLazyAndCatchesHostErrors` | Test host counters | Semantically useful; needs native fixture extraction |
| `cancellationInterruptsSuspendedHostGateway` | Native host task cancellation | Host-level cancellation regression; the source/abort boundary is covered separately because forced session teardown has no native language equivalent |
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

### Source handle lifetime versus active task lifetime

`task-handle-deallocation` assigns the result of `Task { ... }` directly to
`_`, so no source-level handle survives the creation statement. The operation
marks entry, waits behind an explicit MainActor gate, then records its own
cancellation flag and completion. The controller does not release the gate
until entry is visible, so completion cannot be confused with inline execution
or an unobserved task that never started.

Twenty Apple Swift 6.3.3 strict-concurrency runs produced `completed,active`
exactly. Dropping the handle neither requests cancellation nor ends the
operation. The runtime task remains independently alive until its body
finishes.

The same-source interpreter case was already GREEN in all twenty repetitions;
no runtime behavior was changed and no artificial RED was introduced.
`scheduledTasks` already owns active operations independently of values kept by
source code, then releases their records at session drain or detached cleanup.
The parity harness now checks this ownership boundary for every runtime
fixture: after `runAsync`, both the scheduler list and active runtime registry
must be empty. This turns leak cleanup into closing evidence rather than an
assumption specific to the new fixture.

Verification on Apple Swift 6.3.3 / macOS 26.5 SDK: 51 concurrency-parity,
task-cancellation, async-execution, and host-signature tests passed in four
suites, followed by all 728 tests in 142 suites.

### Completed handles retain logical outcomes

`task-completed-handle-reads` creates one successful and one throwing task.
For each handle, its first `value` or `result` read establishes completion;
subsequent reads therefore target an already-completed task. The fixture reads
the successful value twice, then reads its result, reads the failure result
twice, and calls `get()` on the stored failure.

Twenty Apple Swift 6.3.3 strict-concurrency runs produced
`value,value,success:value,failure,failure,get-caught` exactly. Completed task
reads are stable observations of one stored outcome rather than new operation
executions or consumed one-shot values.

The same-source interpreter case and focused white-box regression were already
GREEN; no runtime change was needed. The retained success record contains the
original `value` with logical type `String`. The retained failure record keeps
the interpreted `TaskCompletedHandleReadError.failed` value and its nominal
type after both records have left the runtime's active registry. Both handles
remain readable while scheduler tracking and active records are empty.

Verification on Apple Swift 6.3.3 / macOS 26.5 SDK: 52 concurrency-parity,
task-completion, task-cancellation, async-execution, and host-signature tests
passed in five suites, followed by all 729 tests in 143 suites.

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

### Cancellation before task entry

`task-cancellation-before-start` creates an ordinary unstructured task on
MainActor and cancels its handle before the creator reaches any suspension.
Actor serialization therefore proves that the request precedes operation
entry rather than merely winning a scheduler race. The body records entry,
reads `Task.isCancelled`, and returns a normal string; its caller then awaits
the value and reads the handle flag.

Twenty Apple Swift 6.3.3 strict-concurrency runs produced
`body-ran,body-cancelled,handle-cancelled` exactly. Cancellation requested
before entry does not suppress the operation. The body starts in a cancelled
context, may cooperate by reading the flag, and may still return successfully;
the completed handle remains marked cancelled.

The first same-source interpreter run reached the intended RED by throwing
`CancellationError` instead of producing a string. A pending record had been
immediately changed to terminal `.cancelled`, and the native driver discarded
the source closure at entry. The focused regression made all consequences
visible: the body had not run, no value existed, and the record was cancelled
rather than succeeded.

Cancellation request now remains separate from lifecycle state and outcome.
It records the source and cancels the native driver; attachment also forwards
an already-recorded request. The driver transitions the record from pending to
running and enters source even when its cancellation flag is set. A pre-entry
safe-point still suppresses the body for non-catchable session/host abort, but
ordinary source cancellation remains cooperative. The existing running,
caught-cancellation, cancellation-policy, and cleanup regressions stay green.

The white-box case verifies body entry, a true cancellation observation,
request-before-observation order, a successful `body-cancelled` outcome, a
retained cancellation flag with only the `.taskHandle` source, and an empty
active registry. Verification: 51 concurrency-parity, task-cancellation,
async-execution, and host-signature tests passed in four suites, followed by
all 728 tests in 142 suites.

### Task reads that omit await

`task-read-missing-await-diagnostic` contains one `Task.value` read and one
`Task.result` read without `await`, both inside async functions. Apple Swift
6.3.3 rejects both as async property access; the stable diagnostics are
`expression is 'async' but is not marked with 'await'` and
`property access is 'async'`.

Before the audit fix, the interpreter's synchronous task-handle member path
returned `()` for both reads. The focused regression recorded both placeholder
values as RED. Synchronous dispatch now diagnoses `Task.<member> requires
await` for incomplete and completed handles alike. Explicit awaited access
continues through the existing `waitForOutcome` path, so this closes the final
placeholder escape without adding a second completion mechanism. Compiler-
backed source preflight remains M7; the runtime boundary is no longer silently
wrong in the meantime.

### Optional task-local declarations without an initializer

`task-local-implicit-optional-default` declares
`@TaskLocal static var value: String?` without an initializer, reads it before
and after a suspending `withValue` scope, and crosses a real yield inside the
scope. Twenty Apple Swift 6.3.3 runs produced `nil,bound,nil` exactly. A
separate compiler probe rejects the corresponding non-optional declaration
with the rule that a task-local must have a default value or be optional.

The same-source interpreter case initially failed during collection with
`requires a stored default value`. `RuntimeTaskLocalDeclaration` now represents
the initializer explicitly as optional. Collection accepts the absent form
only for an Optional annotation, and static default resolution materializes a
typed `nil`; all binding identity, inheritance, and cleanup reuse the existing
task-owned storage mechanism. The four corpus projects that exposed the gap —
Sidekick, CopilotForXcode, session-ios, and apple-browsers — each pass their
focused ProjectCheck run after the change.

Combined verification on Apple Swift 6.3.3 / macOS 26.5 SDK:

- 53 concurrency-parity, async-execution, host-signature, task-cancellation,
  task-completion, and task-diagnostic tests passed in six suites;
- all 736 tests passed in 145 suites;
- the full corpus improved from 674/680 to 677/680; the four task-local
  failures are gone, while `oss:Mythic` remains ledgered and the newly merged
  generated platform bridge exposes an unrelated IceCubes
  `UIApplication.openSettingsURLString` fallback regression.

At this audit point all M2 architecture deliverables and semantic proofs were
present, but M2 stayed `in progress` until the repository gate again satisfied
its 678/680 corpus ratchet. No structured-concurrency support was claimed;
that starts in M4 only after the M3 suspension foundation.

### M2 closing repository gate

The closing audit found two platform-bridge regressions outside the task
runtime. Both were fixed at their metadata category rather than for IceCubes:

- opposite-platform non-optional static `String` properties now preserve an
  opaque symbol instead of inventing an empty string, so valid SDK URL tokens
  do not become `nil` at `URL(string:)`;
- `UIFontMetrics` is a UIKit type-level BridgeGen root, which generates its
  complete mechanically supported surface, including `default` and
  `scaledValue(for:)`, instead of absorbing that call as an untyped marker.

The committed same-source Catalyst probes compile and run with Apple Swift
6.3.3 in Swift 6 strict-concurrency mode. Both return `true` natively. Before
their respective fixes, the interpreter returned `false` for the settings URL
and diagnosed no matching `systemFont(ofSize:)` overload for the scaled-font
chain; after the general fixes, both match native behavior.

Closing verification on Apple Swift 6.3.3 / macOS 26.5 SDK:

- 8 generated-platform bridge tests passed;
- all 53 M2 concurrency-parity, async-execution, host-signature,
  task-cancellation, task-completion, and task-diagnostic tests passed;
- all 740 tests passed in 146 suites;
- `Scripts/gate.sh` passed with suite 740/740, corpus 678/680, live 5/5, and
  API parity 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
  0 no-twin.

M2 is complete. Structured concurrency is still not claimed; M3 must first
provide scheduler-owned suspension and clocks.

## Milestone 3 verification record

### Cancellable task sleep and injected clocks

Native question: after a task has announced that it is about to enter a
30-second `Task.sleep`, can another task run, cancel it, and make the sleep
throw `CancellationError` without the deadline expiring?

The committed `task-sleep-cancellation` fixture uses an explicit MainActor
started marker and performs cancellation only after that marker. The native
runner compiles the fixture with the active Apple compiler in Swift 6 strict-
concurrency mode. Twenty native runs produced `started,cancelled` exactly. The
deadline cannot expire within the harness's five-second process bound, so the
result proves suspension, executor availability, cancellation, and wake-up
without relying on scheduler order or an arbitrary synchronization delay.

Before the implementation, the same interpreter source produced
`started,completed` in all twenty repetitions because the SwiftUI bridge
served `Task.sleep` as a synchronous compatibility no-op. The async evaluator
now resolves `Task.sleep` in the interpreter core before that bridge boundary.
It records `.sleeping(until:)`, moves the task from `running` to `waiting`, and
awaits an injected `RuntimeClock`. `ContinuousRuntimeClock` supplies production
monotonic time; `ManualRuntimeClock` lets tests advance time without wall-clock
sleep. Task cancellation removes the registered waiter, resumes it with
`CancellationError`, records cancellation observation, and clears the active
suspension on unwind. Synchronous rendering deliberately keeps its documented
compatibility policy.

Two deterministic unit tests use only manual time. One proves that a sleeping
task remains pending until the clock advances to its deadline. The other
cancels the task at time zero and verifies waiter removal, caught cancellation,
the independent successful task outcome, and cleanup of suspension state.
The focused concurrency/runtime gate passed 55 tests in six suites, including
all native differential repetitions. A clean full build of the exact isolated
change set passed all 742 tests in 146 suites. `Scripts/gate.sh` passed with
suite 742/742, corpus 678/680, live 5/5, and API parity 345 match / 0 diverge /
0 interpreter errors / 17 unstable / 0 no-twin.

### Cooperative task yield

Native question: can a MainActor task repeatedly call `Task.yield` until a
ready sibling makes observable progress, without assuming how many yields are
needed or which ready task the scheduler chooses first?

`task-yield-progress` creates the sibling without suspending, so the worker
cannot run inline with its constructor. The creator then yields until the
worker flips an explicit flag. Twenty bounded native Swift 6 runs completed
with `completed`. This is deliberately a stress/completion fact rather than a
total-order guarantee: the fixture asserts neither a yield count nor scheduler
fairness beyond the observed bounded liveness run.

Before the implementation, the interpreter never released MainActor in that
loop and ended with `evaluation budget exceeded`. Async source `Task.yield` now
resolves in the interpreter core, records `.yielding`, moves the runtime task
to `waiting`, performs a real native `Task.yield`, and restores `running` after
resumption. Synchronous rendering retains its explicit compatibility path and
main-queue drain behavior. A deterministic unit test holds the root after the
sibling progresses, then verifies its retained `.yielding` suspension history
and terminal cleanup without using wall-clock delay. The focused concurrency/
runtime gate passed 56 tests in six suites, including all twenty differential
repetitions. A clean full build of the exact isolated change set passed all
743 tests in 146 suites. `Scripts/gate.sh` passed with suite 743/743, corpus
678/680, live 5/5, and API parity 345 match / 0 diverge / 0 interpreter errors /
17 unstable / 0 no-twin.

### Active task cancellation handler

Native question: after an operation has entered
`withTaskCancellationHandler`, is `onCancel` observable before the synchronous
`cancel()` call returns, is the same registration invoked again by a repeated
request, and which task supplies its dynamic cancellation context?

`task-cancellation-handler-active` holds both the controller and worker on
MainActor. The worker explicitly marks operation entry, then yields until its
native cancellation flag changes. The controller samples the handler count
before cancellation, after the first request, and after a repeated request;
the worker can only resume after those samples. Twenty strict Swift 6.3.3 runs
all returned `0,1,1,false,true,done`. The `false` is the uncancelled controller's
`Task.isCancelled` value inside `onCancel`; the final `true` records that the
worker observed the handler before it resumed. Actor serialization establishes
these happens-before edges without asserting a scheduler choice.

Before implementation, the same interpreted source exhausted its evaluation
budget because the unknown global API was absorbed and the operation never
acquired real handler semantics. The cooperative runtime now owns scoped,
one-shot handler registrations. A first cancellation request marks and cancels
the native task, then invokes active interpreted handlers synchronously on the
caller stack; repeated requests do not re-invoke them. Registration is removed
with `defer` on operation exit, while an invalid interpreted handler failure is
retained for the cancelled task's next safe point rather than swallowed.
Explicit `isolation:` remains diagnosed instead of being silently ignored.

The focused runtime/host/parity gate passed all 55 tests in four suites. A
deterministic unit test additionally proves cancelling-context rebinding,
single invocation, successful cancelled-operation completion, and registration
cleanup after scope exit. A clean build of the isolated change set passed all
748 tests in 146 suites. A forced sweep of the complete local corpus passed
678/680 projects, then `Scripts/gate.sh` passed with suite 748/748, corpus
678/680, live 5/5, and API parity 345 match / 0 diverge / 0 interpreter errors /
17 unstable / 0 no-twin.

### Pre-cancelled task cancellation handler

Native question: if an unstructured task receives repeated cancellation
requests before it enters `withTaskCancellationHandler`, does registration run
`onCancel` immediately, which dynamic cancellation context does it observe, and
can the operation begin first?

`task-cancellation-handler-pre-cancelled` creates the worker and controller on
MainActor. The controller calls `cancel()` twice without suspending, so the
worker cannot enter its operation before both requests. When the worker later
registers its handler, twenty strict Swift 6.3.3 runs all returned
`1,true,true,operation-cancelled`. The first `true` is `Task.isCancelled` inside
`onCancel`; the second proves the operation observed the handler's one prior
invocation. Actor serialization establishes that ordering without asserting
which unrelated ready task a scheduler would otherwise choose.

On the pre-handler runtime, the same-source differential case was RED with
`13:15: unresolved identifier 'withTaskCancellationHandler'`. The general
runtime mechanism from the active-handler step already closes this path:
registration checks the owning task's cancellation record and immediately
invokes a newly registered one-shot handler when cancellation was previously
requested. Because registration occurs while evaluating the worker, both the
handler and operation retain the worker's task context; structured `defer`
still removes the registration on scope exit. No production branch or fixture-
specific behavior was added for this case.

A deterministic unit test additionally verifies the worker context ID in both
closures, cancelled native context, handler-before-operation ordering, one
invocation across repeated requests, successful operation completion, and zero
active handlers after scope exit. The focused concurrency/runtime/host gate
passed all 58 tests in six suites. A clean build of the exact isolated change
set passed all 749 tests in 146 suites. `Scripts/gate.sh` passed with suite
749/749, corpus 678/680, live 5/5, and API parity 345 match / 0 diverge /
0 interpreter errors / 17 unstable / 0 no-twin.

### Nested task cancellation handlers

Native question: when two dynamically nested cancellation handlers are active,
in which order do they run relative to one another and to resumption of the
cancelled operation, and does a repeated request invoke either one again?

`task-cancellation-handler-nested` enters both scopes before exposing a
MainActor `started` barrier. The controller then calls `cancel()` twice without
suspending, and the operation records its final event only after observing its
cancellation flag. Twenty strict Swift 6.3.3 runs all returned
`inner,outer,operation`: both handlers finish synchronously in inner-to-outer
order before the worker can resume, and the repeated request adds no event. No
relative order between independent ready tasks is asserted.

The first current-runtime differential run was RED in all twenty repetitions:
native returned `inner,outer,operation`, while the interpreter returned
`inner,operation,outer,inner,operation`. The root cause was general async
lowering, not handler storage. A labeled closure argument reached
`suspensionRoots` as the root expression, but traversal began at its children;
that bypassed the closure guard and eagerly executed an `await` from the
deferred body while collecting arguments. The inner scope therefore ran once
before the outer handler was registered and then ran again during the real
operation.

Async lowering now rejects a root `ClosureExpr` as a suspension source, just as
it already rejected nested closure nodes. Deferred closure bodies consequently
run only when invoked. The runtime's task-owned registration stack then applies
the natively established reverse traversal, while one-shot state prevents a
second cancellation request from re-invoking either registration. This is a
construct-level fix for every labeled async closure argument; no handler or
fixture symbol is inspected.

A deterministic unit test additionally verifies exact event order, both
handlers' cancelling-task context, the operation's worker context, two total
invocations, successful cancelled-operation completion, and zero active
registrations after both scopes unwind. A separate lowering regression routes a
labeled closure containing a real `await` through an async gateway and proves
the gateway observes control before the deferred body runs exactly once. The
focused concurrency/runtime/host gate passed all 60 tests in six suites. A
full build of `c6ec54b` plus this exact change set passed all 759 tests in 146
suites. `Scripts/gate.sh` reported suite 759/759, corpus 676/680, live 5/5, and
API parity 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
0 no-twin; it correctly returned RED because the repository corpus floor is
678. The two units below the previous floor are parent-level regressions:
`oss:PlayCover` fails while deriving the native ABI layout of `sockaddr_in`, and
`oss:home-assistant-ios` reaches an app-authored missing-image assertion. Both
failures reproduce verbatim when each project is run against a clean detached
`c6ec54b` worktree without this concurrency change. The concurrency step does
not claim a green repository gate or hide the parent failure.

### Cancellation handler scope exit

Native question: after a cancellation-handler operation has returned normally
or unwound by throwing, can cancelling the still-running task invoke that old
handler?

`task-cancellation-handler-scope-exit` runs the normal and throwing forms in
separate unstructured tasks. Each task publishes a MainActor exit barrier only
after leaving `withTaskCancellationHandler`, then remains alive by yielding
until the controller cancels it. Twenty strict Swift 6.3.3 runs all returned
`normal-operation,normal-exit,normal-cancelled,throwing-operation,throwing-exit,throwing-cancelled`.
Neither handler event appears. The barriers establish that each cancellation
happens after its dynamic scope has unwound; no independent scheduler order is
asserted.

The first equivalent interpreter differential was already GREEN in all twenty
repetitions. The runtime's general registration path surrounds the operation
with `defer`-based removal, so both a returned value and a propagated source
error remove the same task-owned registration. No production branch was added.
A deterministic regression observes each task record at the post-scope barrier:
both have zero active registrations. It then verifies zero handler invocations,
successful task outcomes after cancellation, and final registration cleanup.

The focused concurrency/runtime/host gate passed all 61 tests in six suites,
and the full suite passed all 760 tests in 146 suites. `Scripts/gate.sh`
reported suite 760/760, cached corpus 676/680 with unchanged runtime sources,
live 5/5, and API parity 345 match / 0 diverge / 0 interpreter errors /
17 unstable / 0 no-twin. It returned RED solely on the already isolated
parent-level corpus floor described above.

### Source cancellation versus host session abortion

Native question: if an ordinary Swift task catches the `CancellationError`
raised by its cancelled suspension, may it still complete successfully while
its handle remains marked cancelled?

The committed same-source `task-cancellation-caught` fixture supplies the
language oracle. Twenty Apple Swift 6.3.3 strict-concurrency runs all produced
`success:caught,cancelled`. Source cancellation is therefore cooperative and
catchable: consuming the thrown error does not clear the cancellation request,
but it may determine a successful task outcome. Forced interpreter-session
teardown has no native Swift language equivalent; its non-catchable behavior
is an explicit host-infrastructure contract rather than a parity claim.

Before the fix, the new host-abort regression correctly bypassed the source
`catch`, but the retained root task recorded both `.inherited` and `.hostTask`.
The `do/catch` evaluator first treated every caught native
`CancellationError` as an ordinary source observation, synthesizing the
inherited source, and only afterward classified root cancellation as a fatal
session abort.

Cancellation classification now happens before source observation. A root
native cancellation records `.hostTask` and throws `InterpreterSessionAbort`;
the `cancelRemainingTasks` policy observes its existing `.sessionPolicy`
request and throws the same non-catchable internal abort. Only an ordinary
task cancellation that survives this classification reaches source `catch`.
This is one construct-level ordering rule in the suspending `do/catch` path;
it does not inspect fixture symbols or special-case a gateway.

Deterministic runtime regressions cover all three boundaries:

- `.taskHandle` reaches source `catch`, retains only that request source, and
  stores a successful outcome;
- `.sessionPolicy` bypasses source `catch`, retains only the policy source,
  stores a cancelled outcome, and cleans the active registry;
- `.hostTask` bypasses source `catch`, retains only the host source, stores a
  cancelled root outcome, and is converted back to public
  `CancellationError` only at the host API boundary.

The focused concurrency/runtime/host/parity gate passed all 62 tests in six
suites, including all native repetitions. The full suite passed all 761 tests
in 146 suites. `Scripts/gate.sh` reported suite 761/761, corpus 676/680, live
5/5, and API parity 345 match / 0 diverge / 0 interpreter errors /
17 unstable / 0 no-twin. It returned RED solely on the already isolated
parent-level corpus floor described above; the forced sweep introduced no new
failure.

M3 remains in progress only for the remaining first-class suspension
categories.

### Task-value suspension reason

Native question: while an unstructured target is held incomplete behind an
explicit MainActor gate, does `await target.value` suspend its caller so that a
separately created controller can run, release the target, and let the caller
resume with the value?

The existing committed same-source `task-value-success` fixture answers this
without relying on scheduler choice. The target records `child-start` and
waits at the gate. The caller records `before-value`, creates the controller,
and immediately reads the value; the controller cannot execute inline on
MainActor, so that read must suspend before it can open the gate. Twenty
bounded Apple Swift 6.3.3 strict-concurrency runs again produced
`child-start,before-value,child-end,value` exactly.

Before the runtime change, the new deterministic regression observed a
partially represented dependency: the target's waiter set and the caller's
`waitingOnTasks` edge were correct, but the caller remained `.running`, its
active suspension was `nil`, and its suspension history was empty. The logical
scheduler therefore could not explain why that task was unable to execute.

`RuntimeSuspension` now includes `.awaitingTask(RuntimeTaskID)`.
`RuntimeTaskHandle.waitForOutcome` installs that reason and moves the caller to
`.waiting` whenever `value` or `result` targets an incomplete task. Actual
target completion resumes the same caller and removes both dependency edges;
completed targets do not acquire a fictitious wait reason. The mechanism is
shared by successful, failed, and cancelled outcomes, multiple waiters, and
priority-donation chains.

At the forced observation point, the regression sees exactly one target
waiter, the reciprocal caller dependency, and
`.waiting/.awaitingTask(targetID)`. After completion it sees a successful
caller, no active suspension, one retained history entry, no wait edges, and
an empty active registry. The focused concurrency/runtime/host/parity gate
passed all 63 tests in six suites, including every native repetition; the full
suite passed all 762 tests in 146 suites. `Scripts/gate.sh` reported suite
762/762, corpus 676/680, live 5/5, and API parity 345 match / 0 diverge /
0 interpreter errors / 17 unstable / 0 no-twin. It returned RED solely on the
already isolated parent-level corpus floor; the forced sweep introduced no new
failure.

The next smallest open M3 suspension category is an async host gateway, which
needs a runtime-owned host-operation identity rather than a name-based marker.

### Async host-gateway suspension reason

Native question: if a MainActor caller awaits an async wrapper that has entered
but is held behind an explicit gate, can a separately created ready controller
run and open that gate before the wrapper returns?

The committed `host-gateway-suspension` fixture records `before`, creates the
controller without suspending, and then awaits the wrapper. The controller
cannot run inline with `Task` construction. It waits for the wrapper's explicit
started marker, records `controller`, and opens the gate. The wrapper records
entry and yields behind that gate, so no scheduler order beyond the forced
happens-before edges is asserted. Twenty bounded Apple Swift 6.3.3 strict-
concurrency runs produced
`before,host-enter,controller,host-exit,value` exactly.

Before the runtime change, the equivalent interpreter trace was already
externally correct because the native host closure genuinely suspended. The
white-box RED showed the missing logical semantics: at the forced barrier the
source root was still `.running`, its suspension and history were empty, and no
runtime operation identified what it was awaiting.

The cooperative runtime now assigns every external async gateway invocation a
`HostOperationID`, registers its owning source task, and records
`.waiting/.awaitingHost(operationID)` until the implementation returns or
throws. Argument validation runs before this lifecycle and result validation
runs after it. Overload and generic forwarding wrappers delegate ownership to
the selected leaf, while interpreter-owned implementations of `Task.sleep`,
`Task.yield`, task-local scopes, and cancellation handlers opt out because they
already install their own more precise runtime semantics.

`TaskBoundEvalContext` also makes host re-entry explicit. Calling an interpreted
closure temporarily resumes the source task while retaining the outer operation
identity. A nested async gateway then receives a different ID; after that nested
operation finishes, leaving the callback restores the outer wait. The focused
regression observes the exact history
`awaitingHost(outer), awaitingHost(nested), awaitingHost(outer)`, with one active
operation during interpreted callback execution, two during the nested gateway,
and an empty registry after completion. The same mechanism applies to every
async host function and does not inspect gateway names or fixture source.

The focused concurrency/runtime/host/parity gate passed all 64 tests in seven
suites, including every native repetition. The full suite passed all 763 tests
in 147 suites. `Scripts/gate.sh` reported suite 763/763, corpus 676/680, live
5/5, and API parity 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
0 no-twin. It returned RED solely on the already isolated parent-level corpus
floor: `oss:PlayCover` still fails native ABI derivation for `sockaddr_in`, and
`oss:home-assistant-ios` still reaches its app-authored missing-image assertion
on the clean parent commits. No new corpus, live, or API-parity failure was
introduced.

All M3 semantic deliverables were implemented at this point. The milestone
remained unclosed until the parent-level repository corpus ratchet was restored
by the closing work recorded next.

### M3 repository closing gate

The closing gate was two projects below its unchanged 678/680 ratchet because
of parent-level platform-bridge gaps, not a concurrency regression. Both were
fixed through host capabilities and generated SDK contracts before beginning
M4.

`darwin-socket-memory-layout.swift` compiled and ran with the real Apple Swift
6 compiler against Darwin and established the exact
size/stride/alignment sequence
`16,16,1,16,16,4,28,28,4,128,128,8,106,106,1` for `sockaddr`,
`sockaddr_in`, `sockaddr_in6`, `sockaddr_storage`, and `sockaddr_un`.
The first interpreter run was RED while trying to guess a stable layout for
`sockaddr_in`. `HostRegistry.hostABILayout` now lets the selected host bridge
supply compile-time native layouts for the coherent Darwin socket family;
source-defined types still take precedence. The isolated `PlayCover` check is
GREEN at 199 nodes and 32 actions.

`uigraphics-context-image.swift` asks a stateful API question that a declaration
alone cannot answer: is the current image nil before, during nested image
contexts, after restoring the outer context, and after ending it? The exact
fixture compiled with Apple Swift 6.3.3 in Swift 6 strict-concurrency mode for
an iOS 26.5 simulator and returned
`nil,image,image,image,nil`. The same source was RED in both generated fallback
registries as `nil,nil,nil,nil,nil`.

BridgeGen now emits every mechanically bridgeable public module-global
function from the platform symbol graph, rather than requiring its signature
to mention a selected nominal type. On the framework's native platform those
generated gateways directly call the real Swift-imported SDK functions. On an
opposite-platform verifier, a per-registry generated fallback runtime infers
only complete `Begin…Context`/`End…Context`/
`Get…FromCurrent…Context` declaration families and maintains their nested
context depth; unrelated optional SDK results remain nil. There is no project,
fixture, literal, or UIKit function-name branch. The exact differential source
is GREEN through both `ViewRegistry` and `TraceRegistry`, and the isolated
`home-assistant-ios` check is GREEN at 756 nodes and 8 actions.

The generated platform bridge also has identical warm-cache and clean-cache
SHA-1 `b1b236488bc217bbf70f4787c9b88e7469eec4b6`; symbol-graph declaration
order is therefore not part of the checked-in output contract.

The final repository gate passed 767/767 tests in 147 suites. `Scripts/gate.sh`
also passed corpus 678/680, live 5/5, and API parity 345 match /
0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin. M3 is complete;
M4 is now the earliest open milestone.

### M4 async-let structured child foundation

The first M4 question is whether an `async let` initializer is an independent
structured child before its binding is read, and whether reading that binding
suspends until the child produces its value. The same-source
`async-let-value.swift` fixture holds the child behind an explicit gate. The
parent cannot open that gate until the child has marked entry, and it reads the
binding only after opening it. Twenty bounded Apple Swift 6.3.3 strict-
concurrency runs produced
`child-start,parent-open,child-end,value` exactly. Only those barrier-forced
edges are asserted; initial ready-task scheduling is deliberately unspecified.

The first interpreter run was RED at the child gate with `async host function
'parityWaitTaskValueGate' requires runAsync and await`: the `async` declaration
modifier was ignored and the initializer followed the ordinary eager `let`
path in its parent task.

Scope exit is a separate semantic fact rather than an assumption.
`async-let-scope-exit.swift` puts an unconsumed child in a 30-second
cancellable suspension, records the end of the lexical body, and observes code
after the scope. Twenty native runs produced
`child-start,scope-exit,child-cancelled,after-scope` exactly. Natural completion
is impossible inside the five-second process bound, so this proves both
implicit cancellation and the required join before execution continues after
the scope. `async-let-missing-await-diagnostic.swift` also establishes the
Swift 6 diagnostic category and source line for a direct binding read.

The interpreter now creates a lazy `RuntimeStructuredScopeRecord` for a block
that declares a structured child. The child has kind `.asyncLet`, its own
`EvaluationTaskContext`, inherited logical priority and task-local storage, and
a parent/scope edge in `CooperativeConcurrencyRuntime`. It is deliberately not
inserted into the host session's `scheduledTasks`: lexical scope, not session
drain policy, owns its lifetime. `RuntimeAsyncLetBinding` hides the internal
task handle; an explicit awaited identifier uses the existing
`.awaitingTask(childID)` suspension and a direct non-awaited read fails instead
of exposing a carrier value.

Every lexical exit first cancels all unconsumed async-let children, then waits
for all child outcomes, closes the runtime scope, and releases their task
records. This path runs for normal completion, return, thrown interpreter
errors, and cancellation unwinding; completed task contexts assert that no
scope frame remains. The differential harness additionally requires zero
active scope records after every fixture. White-box coverage observes the
parent waiting on the child, the child absent from session ownership, and all
task/scope registries empty after completion.

M4 remains partial. This step claims native parity only for successful explicit
value access, unconsumed normal scope exit, and the missing-await diagnostic.
Remaining cancellation/defer cleanup combinations and task groups require
their own native fixtures before their behavior is classified.

Closing verification for this step is green: the focused async-let tests pass
2/2, `AsyncExecutionTests` pass 41/41, `HostSignatureTests` pass 12/12,
`TaskCompletionRuntimeTests` and `TaskCancellationRuntimeTests` pass 2/2 each,
and `ConcurrencyParityTests` pass 7/7. The full suite passes 769 tests in 147
suites. `Scripts/gate.sh` is green with 769/769 suite tests, the unchanged
678/680 project-corpus ratchet, 5/5 live-data scenarios, and API parity at 345
match / 0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin.

### M4 throwing async-let value

`async-let-value-failure.swift` asks whether `try await` of a throwing
async-let binding waits for and propagates the child's failure. The child
crosses the shared `parityYield` suspension before throwing the fixture's only
error, so the stable observable is whether the parent's `do`/`catch` receives
that failure. Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`caught` exactly; no ready-task ordering is asserted.

The same-source interpreter case was already GREEN before any additional
production change and also produced `caught` in all 20 repetitions. The
previous construct-level implementation had already made
`RuntimeAsyncLetBinding.value` reuse the task outcome wait and translate the
stored failure back into `InterpretedThrow`; this probe therefore expands the
proved surface without adding a failure-specific dispatch path. The parity
harness also confirmed that the child task and structured scope registries are
empty after every repetition.

### M4 parent-cancelled async-let value

`async-let-value-cancellation.swift` holds a throwing child inside the shared
30-second cancellable suspension and sets a MainActor flag immediately before
the parent reaches `try await value`. The outer task cannot issue cancellation
until that flag is visible; because the value is still incomplete, the parent
must then suspend before any other MainActor work can observe the flag.
Cancellation-handler and result events therefore form forced edges rather than
an assumed scheduler order.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`child-start,parent-await,child-cancelled,parent-caught,parent-finished`
exactly. This proves that parent cancellation reaches the structured child,
the child finishes cancellation before the value wait throws, and the parent
may catch that `CancellationError` and complete successfully.

The same-source interpreter case was again GREEN before an additional
production change and matched all 20 repetitions. The existing structured
child edge propagates the request, the child's native cancellable operation
stores a cancelled outcome, and `RuntimeAsyncLetBinding.value` translates that
outcome into `CancellationError` for source `do`/`catch`. Per-repetition cleanup
also left both the task registry and structured-scope registry empty.

### M4 early-return async-let scope exit

`async-let-early-return.swift` starts an unconsumed child and holds it in the
shared 30-second cancellable suspension. Only after the child marks entry does
the owner record `early-return` and execute an explicit `return`. The caller
records the returned value and then a final event, so either caller-side event
before child cancellation would expose an incorrect scope escape.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`child-start,early-return,child-cancelled,returned,after-return` exactly. The
same-source interpreter case matched all 20 repetitions before an additional
production change. The general non-normal result path in
`executeBlockSuspending` already ran defers, cancelled the unconsumed binding,
joined its child, and closed the scope before propagating `.returnValue`.
Per-repetition cleanup again left no active task or structured-scope records.

### M4 throwing async-let scope exit

`async-let-throwing-scope-exit.swift` starts an unconsumed nonthrowing child,
waits until it is inside the shared 30-second cancellable suspension, records
`scope-throw`, and throws an owner error. The child catches its cancellation
and returns successfully, so it cannot replace the error being unwound. The
outer `catch` event therefore also marks delivery of the original owner path.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`child-start,scope-throw,child-cancelled,caught,after-catch` exactly. The
same-source interpreter case matched all 20 repetitions before an additional
production change. `executeBlockSuspending`'s general error path already ran
deferred bodies and structured cleanup before rethrowing, and the parity
cleanup guard observed zero active task and scope records after every run.

### M4 tuple-pattern async-let projection

`async-let-tuple-pattern.swift` declares
`async let (left, right) = asyncLetTupleChild(...)`. The one initializer marks
entry and waits behind the explicit task-value gate; after the parent opens the
gate it returns `(left, right)`, and the parent awaits each name separately.
Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`child-start,parent-open,child-end,left,right` exactly. Only gate- and
value-dependency edges are asserted.

The initial same-source interpreter run was RED at the declaration with
`unsupported async-let binding pattern`. The implementation previously made a
binding carrier own both source lookup and child lifetime, which cannot model
several names backed by one initializer task.

`RuntimeAsyncLetChild` now owns the handle, explicit-await state, cancellation,
scope join, and record release exactly once. Each `RuntimeAsyncLetBinding`
references that child and carries an immutable tuple-index projection path;
the declaration walker recursively validates identifier, wildcard, and tuple
patterns before spawning the child. Element annotations are projected from a
matching tuple type annotation. The committed parity claim is limited to the
flat two-element fixture; recursive paths are the general mechanism rather
than a new unprobed semantic claim.

The differential case is GREEN in all 20 repetitions. White-box coverage also
observes exactly one parent structured-child edge and one scope child for the
two names, returns `left:right`, and finishes with empty session task, runtime
task, and structured-scope registries. `AsyncExecutionTests` pass 42/42,
`HostSignatureTests` pass 12/12, and `ConcurrencyParityTests` pass 8/8.
The full suite passes 778 tests in 149 suites. A clean `Scripts/gate.sh` run is
green with 778 tests, the unchanged 678/680 project-corpus ratchet, 5/5
live-data scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M4 multiple async-let declaration bindings

`async-let-multiple-bindings.swift` declares two bindings in one `async let`
statement. Each child records a distinct start event, increments a shared
MainActor count, and then waits behind the same explicit gate. The parent
cannot record `parent-open` until both starts have happened, which proves the
second initializer can begin while the first remains suspended. It then awaits
the two named values in source order.

Apple Swift 6.3.3 produced one total trace in 20 bounded runs, but FIFO start
or completion is not claimed. The permanent partial-order assertion requires
both starts before `parent-open`, the open before both ends, each end before its
own projected value, and `first-value:one` before `second-value:two` from parent
program order. Other event pairs remain deliberately unconstrained.

The same-source interpreter case was already GREEN before an additional
production change and satisfied those invariants in all 20 repetitions. The
declaration loop already creates and scope-registers one `RuntimeAsyncLetChild`
per `PatternBindingSyntax`; the repeated fixture also left task and structured
scope registries empty. This proof closes the multi-binding surface without
introducing a scheduler-order special case.

### M4 lexical cleanup registration order

The same-source fixtures
`async-let-defer-before-declaration.swift` and
`async-let-defer-after-declaration.swift` ask whether `defer` and async-let
teardown participate in one lexical cleanup order or whether either construct
always wins. Both children mark entry and then remain inside the shared
30-second cancellable suspension until scope exit, so their cancellation event
cannot be confused with natural completion.

With `defer` registered first, 20 bounded Apple Swift 6.3.3 strict-concurrency
runs produced
`child-start,scope-exit,child-cancelled,defer,after-scope` exactly. With
`async let` registered first, all 20 runs produced
`child-start,scope-exit,defer,child-cancelled,after-scope` exactly. The reversed
pair proves LIFO registration order in both directions; no unrelated ready-task
ordering is asserted.

`async-let-separate-declaration-cleanup-order.swift` checks the same rule
between two async-let declarations. Both children have entered cancellable
suspensions before scope exit. All 20 native runs completed the later
declaration's cancellation before the earlier declaration's cancellation.
The permanent partial-order assertion deliberately leaves their start order
unconstrained.

The first same-source interpreter run was RED. It produced
`child-start,scope-exit,defer,child-cancelled,after-scope` even for the
defer-before-declaration fixture because the async evaluator stored all defer
bodies and all structured children in separate arrays, then always ran the
complete defer array first.

`RuntimeStructuredScopeFrame` now owns one ordered lexical cleanup stack.
Encountering a `defer` registers its deferred-body slot; encountering one
`async let` declaration registers a cleanup group containing all initializer
children from that declaration. Unwinding traverses registrations in reverse.
For one async-let group it cancels every unconsumed sibling first, joins every
sibling, and only then advances to the next outer cleanup. Runtime scope closure
and task-record release happen after the complete stack unwinds. This is a
construct-level ordering mechanism rather than a fixture or event-name branch.

All three same-source cases are GREEN for all 20 repetitions. The parity cleanup
guard observes zero active task and structured-scope records after every run.
`AsyncExecutionTests` pass 42/42, `HostSignatureTests` pass 12/12, and
`ConcurrencyParityTests` pass 8/8. The full suite passes 778 tests in 149
suites. `Scripts/gate.sh` is green with 778 tests, the unchanged 678/680
project-corpus ratchet, 5/5 live-data scenarios, and API parity at 345 match /
0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin.

### M4 parent cancellation with an unread async-let child

`async-let-parent-cancellation-scope-exit.swift` asks whether cancelling an
owner propagates to an async-let child even when source never reads the
binding, and whether the owner's eventual scope exit still joins that child.
The child and parent both enter separate 30-second cancellable suspensions
before the outer task records `cancel-issued` and requests cancellation.

One hundred bounded Apple Swift 6.3.3 strict-concurrency runs produced two
total traces. In 98 runs the parent observed cancellation and reached
`owner-exit` before the child observed cancellation; in two runs the child
finished first. The permanent partial-order assertion therefore does not order
those observations. It asserts only the forced facts: the child is running
before the parent waits, cancellation is issued before the child's handler and
both observations, the child follows its own handler/observation/completion
order, and both the child completion and owner exit precede `parent-finished`.

The same-source interpreter case was already GREEN before any production
change and satisfied those invariants in all 20 manifest repetitions. The
existing structured-child edge propagates the request independently of a
binding read; after source catches cancellation, the general lexical cleanup
path waits for the child's terminal outcome before the parent task completes.
The parity cleanup guard again observed zero active task and structured-scope
records. This step expands the proved cancellation surface without adding a
fixture-specific runtime path.

### M4 nonthrowing task-group foundation

`task-group-wait-for-all.swift` asks whether `withTaskGroup` creates an
independent structured child and whether an explicit `waitForAll` keeps the
owner suspended until that child completes. The child records entry and waits
behind the shared task-value gate. Only after observing entry does the owner
record `parent-open`, open the gate, and call `waitForAll`.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`child-start,parent-open,child-end,group-finished,after-scope` exactly. Every
edge follows from the explicit gate, the `waitForAll` dependency, or parent
program order; no unconstrained scheduling choice is asserted.

The initial same-source interpreter case was RED at the outer call with
`unresolved identifier 'withTaskGroup'`. Treating this as an ordinary native
gateway would not be sufficient: the trailing closure contains interpreted
AST, and its `group` parameter must mutate the source task's structured
ownership graph.

The interpreter now creates a runtime-owned `RuntimeTaskGroupID`, a
task-group-kind `RuntimeStructuredScopeRecord`, and a source-facing
`RuntimeTaskGroup` capability for the dynamic extent of the body closure.
`addTask` creates a `.groupChild` with its own `EvaluationTaskContext`, inherited
priority and task locals, and parent/group/scope edges. It is not session-owned.
`waitForAll` records one logical `.waitingForGroup(groupID)` suspension, donates
the owner's effective priority to incomplete children through runtime wait
edges, waits for every registered child, and then removes those edges. Closing
the group verifies terminal children, closes the structured scope, and releases
the child records and group capability.

Only explicit `waitForAll` is classified by this step. If a body exits while
an added child is still active without the verified wait, the runtime cancels
and joins it for leak-free teardown and emits a clear unsupported diagnostic;
it does not silently claim Swift's implicit group scope-exit rule. `next`,
`cancelAll`, result ordering, throwing groups, and iteration likewise remained
explicitly unsupported by this foundation step until their own native probes.

The exact differential case is GREEN in all 20 repetitions. White-box coverage
observes `.groupChild`, the matching task-group and structured-scope records,
the owner's `.waitingForGroup` state, absence from session-owned tasks, and zero
task/group/scope records after completion. `AsyncExecutionTests` pass 43/43,
`HostSignatureTests` pass 12/12, and `ConcurrencyParityTests` pass 8/8. The
full suite passes 779 tests in 149 suites. `Scripts/gate.sh` is green with 779
tests, the unchanged 678/680 project-corpus ratchet, 5/5 live-data scenarios,
and API parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
0 no-twin.

### M4 implicit normal task-group scope exit

`task-group-implicit-scope-exit.swift` removes the explicit `waitForAll` from
the previous shape. The child first marks entry behind the task-value gate;
the group body then records `body-return`, opens the gate, and returns
immediately. This makes natural child completion possible while still exposing
an outer-scope escape that occurs before the child finishes.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`child-start,body-return,child-end,after-scope` exactly. The gate forces the
first three program points, while `after-scope` following `child-end` proves
that normal `withTaskGroup` return implicitly joins outstanding work. The child
finishes its normal path, so this case also proves that normal group scope exit
does not cancel it.

The initial same-source interpreter case was RED with the foundation's explicit
`withTaskGroup scope-exit waiting is not supported yet` diagnostic. The normal
body-return path now reuses the same runtime-owned group wait as `waitForAll`
without requesting child cancellation, then validates terminal outcomes,
closes the task-group structured scope, and releases its child records. Error
cleanup remains a distinct cancel-and-join path and is not classified by this
normal-exit fixture.

The exact differential case is GREEN in all 20 repetitions, including the
task/group/scope cleanup guard. The temporary explicit-wait generation marker
and diagnostic were removed; no new group API or unprobed result-order rule was
introduced. `AsyncExecutionTests` pass 43/43, `HostSignatureTests` pass 12/12,
and `ConcurrencyParityTests` pass 8/8. The full suite passes 779 tests in 149
suites. `Scripts/gate.sh` is green with 779 tests, the unchanged 678/680
project-corpus ratchet, 5/5 live-data scenarios, and API parity at 345 match /
0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin.

### M4 task-group `cancelAll`

`task-group-cancel-all.swift` asks whether `cancelAll` only requests
cancellation or also allows the group owner to escape before a cancelled child
finishes. The child first records entry, suspends in the shared cancellable
wait helper, catches `CancellationError`, records a final post-catch event, and
returns normally. Only after the wait helper reports that suspension has begun
does the owner record `cancel-all`, call `cancelAll`, and await `waitForAll`.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`child-start,cancel-all,child-cancelled,child-finished,group-finished,after-scope`
exactly. The explicit wait-start gate establishes the first two events; child
program order establishes its cancellation and finish events; `waitForAll` and
outer program order prove that requesting cancellation remains separate from
the child's terminal outcome and the structured join.

The initial same-source interpreter case was RED with
`TaskGroup.cancelAll is not supported yet`. The group capability now validates
that it is active and used by its owning evaluation task, then sends a distinct
`.taskGroupCancelAll` request to every incomplete runtime-owned child. The same
general child-cancellation helper is also used by exceptional group cleanup;
waiting, priority-donation edges, outcome storage, joining, and scope teardown
continue through the existing task-group mechanisms. At this step, the
capability recorded that `cancelAll` occurred and explicitly rejected a later
`addTask` until that separate Swift behavior was natively classified, rather
than silently launching an incorrectly uncancelled child.

The exact differential case is GREEN in all 20 repetitions, including the
task/group/scope cleanup guard. This step did not classify adding children
after `cancelAll`, group cancellation state or `isCancelled`, cancellation
ordering among multiple children, `next`, throwing groups, or iteration; each
requires a separate native probe before support is claimed.
`AsyncExecutionTests` pass 44/44, `HostSignatureTests` pass 12/12, and
`ConcurrencyParityTests` pass 8/8. The full suite passes 780 tests in 149
suites. `Scripts/gate.sh` is green with 780 tests, the unchanged 678/680
project-corpus ratchet, 5/5 live-data scenarios, and API parity at 345 match /
0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin.

### M4 task-group completion-ordered `next`

`task-group-next-completion-order.swift` first adds a child that enters a
confirmed cancellable suspension, then adds an immediately returning child.
The owner consumes one result with `next`, calls the already-proved
`cancelAll` to release the slow child, consumes a second result, and calls
`next` once more after both results have been removed.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`fast:slow:empty` exactly. The wait-start handshake proves that the slow child
was active before the fast child was added. Therefore the first result proves
completion order rather than insertion order; cancellation occurs only after
that result, so the second result must be slow; the final fallback proves that
each result is consumed once and a drained group returns `nil`. No unconstrained
relative scheduler event is asserted.

The initial same-source interpreter case was RED with
`TaskGroup.next is not supported yet`. Each group child now records its runtime
group identity, and every success, failure, or cancellation terminal transition
publishes the child ID into a runtime-owned completion log. A monotonic cursor
consumes that log without quadratic front-removal, while identity sets reject
duplicate publication or consumption. If no result is ready but a child is
active, the sole owning task installs one group-result continuation, records
`.waitingForGroup(groupID)`, donates priority across the incomplete child
edges, and removes those edges after the next terminal transition. Source
`next` projects successful outcomes as `Optional.some` and a drained group as
`Optional.none`; it does not poll handles or mirror source work into another
native task group.

The exact differential case is GREEN in all 20 repetitions. White-box coverage
observes the logical group suspension, one consumed completion with no pending
result, and zero task/group/scope records after completion. At this step, the
then-unprobed interaction `waitForAll` followed by `next` was explicitly
diagnosed instead of silently choosing whether `waitForAll` consumed queued
results; the next step classifies it. Throwing groups, group iteration,
concurrent/multiple consumers, and post-cancellation addition remain outside
this step. `AsyncExecutionTests` pass 46/46,
`HostSignatureTests` pass 12/12, and `ConcurrencyParityTests` pass 8/8. The
full suite passes 782 tests in 149 suites. `Scripts/gate.sh` is green with 782
tests, the unchanged 678/680 project-corpus ratchet, 5/5 live-data scenarios,
and API parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
0 no-twin.

### M4 `waitForAll` result draining

`task-group-wait-for-all-consumes-results.swift` starts with the same
completion-order shape: the first-added child enters a confirmed cancellable
suspension, then a fast child is added and consumed by `next`. The owner calls
`cancelAll` to release the slow child, awaits `waitForAll`, and finally calls
`next` again. This asks whether `waitForAll` merely joins remaining work or also
consumes its queued result after an earlier result was already removed.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced `fast:empty`
exactly. The handshake proves slow was active before fast was added; the first
`next` therefore consumes fast. Slow catches cancellation and returns a normal
value before `waitForAll` completes, so the final `empty` proves that the wait
consumed that remaining result. Every asserted edge follows from the handshake,
program order, or the structured waits.

The initial same-source interpreter case was RED with the temporary safety
diagnostic `TaskGroup.next after waitForAll is not supported yet`. After the
general group join succeeds, `waitForAll` now advances the same completion-log
cursor through every unpublished-to-source outcome, including a tail left
after earlier `next` calls. The runtime requires every child to be terminal and
asserts that the consumed identity set equals the complete child set. A later
`next` therefore reaches the existing drained-group path and returns
`Optional.none`; the temporary capability flag and diagnostic were removed.

The exact differential case is GREEN in all 20 repetitions, and direct runtime
coverage verifies the basic one-child `waitForAll` then `next` shape plus zero
task/group/scope records after completion. This step does not classify adding
new children after a completed wait, repeated waits with new work, throwing
group error draining, or async iteration. `AsyncExecutionTests` pass 46/46,
`HostSignatureTests` pass 12/12, and `ConcurrencyParityTests` pass 8/8. The
full suite passes 782 tests in 149 suites. `Scripts/gate.sh` is green with 782
tests, the unchanged 678/680 project-corpus ratchet, 5/5 live-data scenarios,
and API parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
0 no-twin.

### M4 child addition after `cancelAll`

`task-group-add-after-cancel-all.swift` calls `cancelAll` before adding any
child. The newly added child reads `Task.isCancelled` as its first source
operation, returns `cancelled` or `active`, and the owner consumes that value
with `next`.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced `cancelled`
exactly. There is no scheduler-order assertion: group cancellation is complete
in owner program order before `addTask`, and the child performs no earlier
source operation. The result proves both that `addTask` remains legal and that
the new child starts with cancellation already requested.

The initial same-source interpreter case was RED with the temporary safety
diagnostic `TaskGroup.addTask after cancelAll is not supported yet`. The
runtime-owned group record now retains a specifically named
`hasCancelAllRequest` state. When `addTask` creates a pending child after that
request, it records `.taskGroupCancelAll` on the child before attaching the
native driver. Existing task-start semantics still enter source work for a
cooperatively cancelled task, so `Task.isCancelled` observes the request and
the closure can decide how to finish normally. The temporary rejection was
removed.

The exact differential case is GREEN in all 20 repetitions, and direct runtime
coverage verifies the same cancelled-at-entry result plus zero task/group/scope
records after completion. This step deliberately did not generalize the
recorded flag to parent cancellation; at this point `TaskGroup.isCancelled`,
`addTaskUnlessCancelled`, and adding work after parent cancellation still
needed their own probes. `AsyncExecutionTests` pass 46/46,
`HostSignatureTests` pass 12/12,
and `ConcurrencyParityTests` pass 8/8. The full suite passes 782 tests in 149
suites. `Scripts/gate.sh` is green with 782 tests, the unchanged 678/680
project-corpus ratchet, 5/5 live-data scenarios, and API parity at 345 match /
0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin.

### M4 task-group `isCancelled` after `cancelAll`

`task-group-is-cancelled.swift` reads `group.isCancelled`, calls `cancelAll`
with no child work in the group, and reads the same property again. A small
pure source helper labels each Boolean state.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`active:cancelled` exactly. Both reads and the cancellation call occur in one
owner's program order, so the result contains no scheduler-dependent edge. It
proves that `isCancelled` is initially false and becomes true synchronously by
the time `cancelAll` returns.

The initial same-source interpreter case was RED with
`TaskGroup.isCancelled is not supported yet`. Property projection now enforces
the capability's active lexical extent and owning evaluation task, then reads
the already runtime-owned `hasCancelAllRequest` state. It adds no second
cancellation flag and no polling of native task state.

The exact differential case is GREEN in all 20 repetitions. Direct runtime
coverage observes `active:cancelled` on the group, then confirms that a child
added afterward sees `Task.isCancelled`, followed by zero task/group/scope
records. This step did not claim how `isCancelled` changes when only the owner
task was cancelled; parent-cancellation state and late addition in that state
remained separate until the later active-owner-cancellation probe. At this
point `addTaskUnlessCancelled` was also unprobed.
`AsyncExecutionTests` pass 46/46, `HostSignatureTests` pass 12/12, and
`ConcurrencyParityTests` pass 8/8.
The full suite passes 782 tests in 149 suites. `Scripts/gate.sh` is green with
782 tests, the unchanged 678/680 project-corpus ratchet, 5/5 live-data
scenarios, and API parity at 345 match / 0 diverge / 0 interpreter errors / 17
unstable / 0 no-twin.

### M4 task-group `addTaskUnlessCancelled`

`task-group-add-unless-cancelled.swift` first calls
`addTaskUnlessCancelled` on an active group, consumes that child's `first`
result, then calls `cancelAll` and invokes the conditional addition again. A
final `next` distinguishes a skipped closure from hidden work.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`added:first:skipped:empty` exactly. The first Boolean is returned before its
child result is awaited. The second call occurs after `cancelAll` in owner
program order, and the following drained `next` proves that returning `false`
did not register or execute another child. No relative scheduler order is part
of the assertion.

The initial same-source interpreter case was RED with
`TaskGroup.addTaskUnlessCancelled is not supported yet`. `addTask` and
`addTaskUnlessCancelled` now share one operation/priority parsing and child
creation path. The conditional form first validates the active capability and
owner; if the runtime group has a `cancelAll` request it returns `false`
without allocating a task record, otherwise it creates the same structured
`.groupChild` and returns `true`.

The exact differential case is GREEN in all 20 repetitions. Direct runtime
coverage observes the skipped post-cancellation closure alongside ordinary
`addTask` cancellation inheritance and zero task/group/scope records. At this
step the method under owner-only cancellation remained unclassified; the later
active-owner-cancellation probe closes that case.
`AsyncExecutionTests` pass 46/46, `HostSignatureTests` pass 12/12, and
`ConcurrencyParityTests` pass 8/8. The full suite passes 782 tests in 149
suites. `Scripts/gate.sh` is green with 782 tests, the unchanged 678/680
project-corpus ratchet, 5/5 live-data scenarios, and API parity at 345 match /
0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin.

### M4 owner cancellation of an active task group

`task-group-owner-cancellation.swift` creates an unstructured owner task and
publishes readiness only after that task has entered `withTaskGroup`. The outer
controller cancels the owner's handle. Inside the group, the owner waits until
its own `Task.isCancelled` read becomes true, then reads `group.isCancelled`,
calls `addTaskUnlessCancelled`, adds one ordinary late child, and consumes that
child with `next`.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`cancelled:cancelled:skipped:child-cancelled` exactly. Readiness proves the
group already exists before cancellation. The owner's observation loop ensures
all following operations occur after cancellation rather than asserting when
the scheduler delivers it. The result therefore proves that cancelling the
owner makes the active group cancelled, conditional addition skips without
running its closure, and an ordinary child added afterward starts cancelled.

The initial same-source interpreter case was RED in all 20 repetitions with
`cancelled:active:added:wrong-conditional`. Owner cancellation already reached
existing structured children, but the task record had no identity edge to its
active group, so the group capability retained only its independent
`hasCancelAllRequest` state.

Each runtime task now owns the IDs of its active task groups. Cancellation marks
those group records with a distinct `hasOwnerCancellationRequest` before
cancellation handlers run, while `cancelAll` remains a separate fact.
`isCancelled` and `addTaskUnlessCancelled` read the combined runtime-owned
state. A late ordinary child receives `.structuredParent` before its native
driver is attached; if both owner cancellation and `cancelAll` apply, it
retains both sources. Group close removes the owner edge, and task release now
rejects a leaked active group. No native mirror `TaskGroup`, polling loop, or
fixture-specific dispatch was introduced.

The exact differential case is GREEN in all 20 repetitions, including the
fresh interpreter cleanup guard for task/group/scope records. The combined
targeted run passes 66/66 tests across `AsyncExecutionTests` (46),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8). The full suite
passes 782 tests in 149 suites. `Scripts/gate.sh` is green with 782 tests, the
unchanged 678/680 project-corpus ratchet, 5/5 live-data scenarios, and API
parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable / 0
no-twin. At this step, group creation after an already-cancelled owner remained
unclassified; the next fixture closes that creation-time state. Throwing
groups, group iteration, and the remaining exceptional cleanup combinations
remain open.

### M4 task-group creation after owner cancellation

`task-group-created-after-owner-cancellation.swift` publishes readiness from an
unstructured owner task before any group exists. The outer controller cancels
the owner. Only after the owner observes `Task.isCancelled` does it enter
`withTaskGroup`, read `group.isCancelled`, try `addTaskUnlessCancelled`, add an
ordinary child, and consume that child with `next`.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`cancelled:skipped:child-cancelled` exactly. The observation loop proves the
cancellation request precedes group creation. All group operations then follow
in owner program order, and the late child reads its own cancellation as its
first source action. The assertion therefore contains no unconstrained
scheduler ordering.

The initial same-source interpreter case was RED in all 20 repetitions with
`active:added:wrong-conditional`. The previous active-group mechanism could
record a cancellation event only for groups already connected to the owner;
new group records always initialized their owner-cancellation flag to false.

`createTaskGroup` now reads the owning runtime task's existing cancellation
state and supplies it to `RuntimeTaskGroupRecord` during initialization, before
the record or source capability becomes observable. The existing combined
group state then drives `isCancelled`, the conditional-add branch, and the
already-general late-child cancellation-source path. This adds no second
source-facing rule and no native mirror group.

The exact differential case is GREEN in all 20 repetitions, including the
fresh interpreter cleanup guard. The combined targeted run passes 66/66 tests
across `AsyncExecutionTests` (46), `HostSignatureTests` (12), and
`ConcurrencyParityTests` (8). The full suite passes 782 tests in 149 suites.
`Scripts/gate.sh` is green with 782 tests, the unchanged 678/680 project-corpus
ratchet, 5/5 live-data scenarios, and API parity at 345 match / 0 diverge / 0
interpreter errors / 17 unstable / 0 no-twin. At this point throwing groups,
group iteration, and the remaining exceptional cleanup combinations remained
open; the next fixture establishes only the throwing group's successful path.

### M4 throwing task-group successful `next`

`task-group-throwing-success.swift` enters `withThrowingTaskGroup`, adds one
immediately successful child returning `value`, and consumes it through
`try await group.next()`.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced `value`
exactly. The result depends only on the awaited child outcome; no relative
scheduler order is asserted. This fixture classifies successful creation,
addition, completion publication, and `next` projection only. It does not
classify child failure, first-error selection, cancellation-as-error, or an
exceptional body exit.

The initial same-source interpreter case was RED with
`unresolved identifier 'withThrowingTaskGroup'`. The interpreter now registers
that source function alongside `withTaskGroup` and creates the same
runtime-owned structured scope and completion machinery. An immutable
`RuntimeTaskGroupKind` on the group record distinguishes `.nonthrowing` from
`.throwing`, so the successful path can be shared without losing the future
failure contract.

At this step unprobed throwing child failure and cancellation outcomes still
produced a specific unsupported diagnostic; they were not projected through
the nonthrowing rule or counted as support. A white-box regression observes
the `.throwing` record kind from the live child and verifies zero
task/group/scope ownership after completion. The next fixture classifies one
failed-child `next` path only.

The exact differential case is GREEN in all 20 repetitions. The combined
targeted run passes 67/67 tests across `AsyncExecutionTests` (47),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8). The full suite
passes 783 tests in 149 suites. `Scripts/gate.sh` is green with 783 tests, the
unchanged 678/680 project-corpus ratchet, 5/5 live-data scenarios, and API
parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable / 0
no-twin. Throwing child failure/first-error semantics, throwing-group
exceptional exit, group iteration, and the remaining exceptional cleanup
combinations remain open.

### M4 throwing `next` source-error propagation

`task-group-throwing-next-failure.swift` adds one child that throws the nominal
enum case `ThrowingTaskGroupNextFailure.failed`, then immediately calls
`try await group.next()`. A generic outer `catch` switches over the delivered
error and returns `caught-child` only for that exact source value.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`caught-child` exactly. One child and one awaited completion remove any
first-error or scheduler-order choice. This proves preservation of the source
error identity through throwing `next`; it does not classify multiple failed
children, `waitForAll`, cancellation projection, or exceptional body exit.

The fixture deliberately avoids a typed catch clause. Its first draft exposed
an unrelated interpreter limitation: async catch dispatch currently selects
the first clause without testing its pattern, which could falsely report the
expected branch for the wrong host error. Switching inside a generic catch
makes this parity assertion sensitive to the actual delivered `RuntimeValue`.

With that strengthened assertion, the same-source interpreter case was RED
with `cannot compare throwing task-group child failure propagation is not
supported yet and ThrowingTaskGroupNextFailure.failed`. The runtime outcome
already retained the original failure payload; only projection was wrong.
`nextSourceTaskGroupValue` now throws `InterpretedThrow(value:)` for a
`.throwing` group's failed completion. Completion ordering, outcome storage,
group cleanup, and nonthrowing behavior are unchanged.

The exact differential case is GREEN in all 20 repetitions. Focused coverage
also verifies the nominal switch result and zero task/group/scope records. The
combined targeted run passes 68/68 tests across `AsyncExecutionTests` (48),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8). The full suite
passes 784 tests in 149 suites. `Scripts/gate.sh` is green with 784 tests, the
unchanged 678/680 project-corpus ratchet, 5/5 live-data scenarios, and API
parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable / 0
no-twin. Multiple-failure/first-error selection, throwing `waitForAll`,
cancellation projection, throwing-group exceptional exit, group iteration, and
the remaining exceptional cleanup combinations remained open at this step. The
next fixture closes only single-child explicit `waitForAll`.

### M4 throwing `waitForAll` with one child

`task-group-throwing-wait-for-all-failure.swift` runs two throwing groups in
program order. The first adds one successful child, explicitly awaits
`waitForAll`, and returns `success`. The second adds one child that throws the
nominal `ThrowingTaskGroupWaitFailure.failed` value; a generic catch switches
over the error delivered by its explicit `waitForAll`.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`success:caught-child` exactly. Each group has one child and an explicit join,
so neither scheduler order nor multiple-error selection is asserted. The result
proves successful completion and exact source-error propagation for this
single-outcome shape. It does not classify zero/multiple child outcomes or
implicit failed scope exit.

The failure-only first draft was RED through the existing unsupported
diagnostic. Adding the successful group ensured that the no-error half of the
same API was also natively proved. The strengthened same-source case remained
RED as `wrong-success:cannot compare throwing task-group child failure
propagation is not supported yet and ThrowingTaskGroupWaitFailure.failed`;
the inner switch exposed the incorrect host error instead of the stored source
value.

Outcome validation now receives an explicit consumer: lexical scope exit or
`waitForAll`; `next` already has its completion-ordered projection path. A
throwing explicit wait accepts exactly one outcome, returns for success, and
throws `InterpretedThrow(value:)` for failure. Zero or multiple outcomes retain
an unsupported diagnostic at this step. A failed
implicit scope exit remains a different unsupported diagnostic rather than
silently inheriting the explicit-wait rule.

The exact differential case is GREEN in all 20 repetitions. Focused coverage
verifies both explicit outcomes, the separate scope-exit diagnostic, and zero
task/group/scope records after each run. The combined targeted run passes 69/69
tests across `AsyncExecutionTests` (49), `HostSignatureTests` (12), and
`ConcurrencyParityTests` (8). The full suite passes 785 tests in 149 suites.
`Scripts/gate.sh` is green with 785 tests, the unchanged 678/680 project-corpus
ratchet, 5/5 live-data scenarios, and API parity at 345 match / 0 diverge / 0
interpreter errors / 17 unstable / 0 no-twin. Multiple-outcome/first-error
throwing waits, cancellation projection, throwing-group exceptional exit,
group iteration, and the remaining exceptional cleanup combinations remain
open at this step. The next fixture closes only the zero-outcome explicit-wait
case.

### M4 throwing `waitForAll` with no children

`task-group-throwing-wait-for-all-empty.swift` creates a throwing group, adds
no children, explicitly awaits `waitForAll`, and returns `empty`. Twenty bounded
Apple Swift 6.3.3 strict-concurrency runs produced `empty` exactly. With no
child, completion order, error selection, and scheduler order cannot affect the
result; the probe establishes only successful zero-outcome completion.

The same source was RED in all 20 interpreter repetitions as
`error:throwing task-group waitForAll with multiple child outcomes is not
supported yet`. Outcome validation now permits zero or one outcome for an
explicit throwing wait: zero returns normally, while the previously proved
single-outcome success/error projection is unchanged. More than one outcome
still takes the explicit unsupported path until a dedicated native probe
defines its selection behavior.

The exact differential case is GREEN in all 20 repetitions. Focused coverage
also verifies zero scheduled tasks and zero task/group/scope records after the
empty group closes. The combined targeted run passes 70/70 tests across
`AsyncExecutionTests` (50), `HostSignatureTests` (12), and
`ConcurrencyParityTests` (8), with 60 runtime fixtures. The full suite passes
786 tests in 149 suites. `Scripts/gate.sh` is green in 744 seconds with 786
tests, the unchanged 678/680 project-corpus ratchet, 5/5 live-data scenarios,
and API parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
0 no-twin. Multiple-outcome/first-error throwing waits, cancellation
projection, throwing-group exceptional exit, group iteration, and the
remaining exceptional cleanup combinations remained open at this step. The
next fixture closes only success-only multiple-outcome waits.

### M4 throwing `waitForAll` with multiple successful children

`task-group-throwing-wait-for-all-multiple-success.swift` adds two children to
a throwing group, ignores their individual values, explicitly awaits
`waitForAll`, and returns `all-success`. Twenty bounded Apple Swift 6.3.3
strict-concurrency runs produced `all-success` exactly. Since neither child
fails and their values are not observed, completion order and error selection
cannot affect the assertion.

The same-source interpreter case was RED in all 20 repetitions as
`error:throwing task-group waitForAll with multiple child outcomes is not
supported yet`. Explicit wait validation now first checks whether any failure
exists. Any number of all-success outcomes returns normally; a sole failed
outcome still rethrows its stored source value, while a failure among multiple
outcomes keeps a distinct unsupported diagnostic pending an error-selection
probe. A white-box test uses three children, rather than the fixture's two, and
verifies that this is an outcome-classification rule rather than a count
special case.

The exact differential case is GREEN in all 20 repetitions. Focused coverage
also verifies zero scheduled tasks and zero task/group/scope records after the
three-child group closes. The combined targeted run passes 71/71 tests across
`AsyncExecutionTests` (51), `HostSignatureTests` (12), and
`ConcurrencyParityTests` (8), with 61 runtime fixtures. The full suite passes
787 tests in 149 suites. `Scripts/gate.sh` is green in 695 seconds with 787
tests, the unchanged 678/680 project-corpus ratchet, 5/5 live-data scenarios,
and API parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
0 no-twin. Multi-outcome failure/first-error throwing waits, cancellation
projection, throwing-group exceptional exit, group iteration, and the
remaining exceptional cleanup combinations remained open at this step. The
next fixture closes only the one-failure/multiple-outcome shape.

### M4 throwing `waitForAll` with one failure and successful siblings

`task-group-throwing-wait-for-all-single-failure-among-multiple.swift` adds one
successful child and one child that throws the nominal
`ThrowingTaskGroupSingleFailure.failed` value. A generic catch switches over
the error delivered by explicit `waitForAll`. Twenty bounded Apple Swift 6.3.3
strict-concurrency runs produced `caught-child` exactly. Because only one child
fails, completion order cannot change the selected error identity and
multiple-error selection is not asserted.

The same-source interpreter case was RED through the existing multi-outcome
failure-selection diagnostic; switching over that host diagnostic raised
`cannot compare ... and ThrowingTaskGroupSingleFailure.failed`. Explicit wait
validation now classifies failures independently from successful outcomes. If
exactly one source failure exists, it throws `InterpretedThrow(value:)`
regardless of successful sibling count. Two or more failures retain a distinct
unsupported diagnostic.

The validator also detects `.cancelled` outcomes before success/failure
projection and reports the unprobed cancellation boundary explicitly,
instead of allowing a cancelled child to look like all-success. White-box
coverage uses two successful siblings plus one failed child, checks the source
error identity, exercises the cancellation diagnostic separately, and verifies
zero task/group/scope records after both runs.

The exact differential case is GREEN in all 20 repetitions. The combined
targeted run passes 72/72 tests across `AsyncExecutionTests` (52),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 62 runtime
fixtures. The full suite passes 788 tests in 149 suites. `Scripts/gate.sh` is
green in 683 seconds with 788 tests, the unchanged 678/680 project-corpus
ratchet, 5/5 live-data scenarios, and API parity at 345 match / 0 diverge / 0
interpreter errors / 17 unstable / 0 no-twin. Multiple-failure/first-error
throwing waits, cancellation projection, throwing-group exceptional exit,
group iteration, and the remaining exceptional cleanup combinations remain
open.

### M4 throwing `waitForAll` completion-ordered first error

`task-group-throwing-wait-for-all-multiple-failures.swift` adds two failing
children. An explicit gate prevents the first-declared child from completing
until the other child can fail; both increment a MainActor-isolated completion
counter immediately before throwing. The outer catch identifies the nominal
source error and reports whether both children completed.

The Apple Swift 6.3.3 SDK `_Concurrency.swiftinterface` supplies the semantic
algorithm rather than leaving it to observed scheduling: throwing
`waitForAll` repeatedly consumes completion-ordered `next()` results, retains
only the first caught error, continues until the group is empty, and then
rethrows that retained error. Twenty bounded strict-concurrency native runs all
produced `caught-second:drained`. The parity assertion nevertheless permits
either nominal source error while requiring `drained`, so it checks Swift's
first-observed-error and full-drain guarantees without promoting one scheduler
order into a contract.

The same-source interpreter case was RED through the explicit unsupported
multiple-failure diagnostic; its attempted source-error switch reported
`cannot compare ... and ThrowingTaskGroupMultipleFailure.first`. Explicit
throwing waits now join the group and then consume its remaining outcomes
through the runtime's existing completion queue, the same queue used by
`next`. Validation therefore sees completion order rather than declaration
order, excludes values already consumed by an earlier `next`, records the first
failure, and performs projection only after every pending outcome has been
drained. Cancellation remains an explicit unsupported boundary.

White-box coverage holds the first-declared child at a host gate until the
second child is the group's sole completed outcome. After release the source
returns `caught-second`; both child IDs are completed and consumed, the pending
completion count is zero, and the scheduler plus task/group/scope registries
are empty.

The allowed-set differential case is GREEN in all 20 repetitions. The combined
targeted run passes 73/73 tests across `AsyncExecutionTests` (53),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 63 runtime
fixtures. The full shared-worktree run passes 790 tests in 150 suites; one test
and its suite come from a preserved unrelated untracked corpus-sweep file, so
this tracked repository step accounts for 789 tests in 149 suites.
`Scripts/gate.sh` is green in 667 seconds with the same shared-worktree 790-test
suite, the unchanged 678/680 project-corpus ratchet, 5/5 live-data scenarios,
and API parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
0 no-twin. Throwing-wait cancellation projection, throwing-group exceptional
exit, group iteration, and the remaining exceptional cleanup combinations
remain open.

### M4 throwing `waitForAll` cancellation projection

`task-group-throwing-wait-for-all-cancellation.swift` cancels a throwing group
before adding two children. The first child records completion and calls
`Task.checkCancellation()`; the second records completion and returns normally
while ignoring its inherited cancellation flag. A generic catch compares the
dynamic error metatype with `CancellationError.self`, checks the owner task's
cancellation state, and verifies that both children completed.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`cancellation:owner-active:drained` exactly. Together with the SDK
`waitForAll` implementation, this establishes three guarantees without a
scheduler-order claim: an observing cancelled child contributes
`CancellationError`, that error does not mark the owner cancelled, and the
explicit wait drains the successful sibling before returning the error.

The same-source interpreter case was RED in all 20 repetitions as
`wrong-error:owner-active:drained`: cancellation and draining already occurred,
but the validator projected its unsupported host diagnostic rather than the
source-visible error. Throwing explicit waits now select their first error-like
outcome in completion order. A `.failure` rethrows its retained source value;
a `.cancelled` outcome throws `CancellationError`. This is the same selection
path used for any number of outcomes, not a child-count special case, and it
does not request or observe cancellation on the owner.

White-box coverage retains the group and owner records across cleanup. It
observes two completed and consumed child IDs, zero pending completions, an
owner with neither requested nor observed cancellation, and empty scheduler,
task, group, and structured-scope registries after return.

The exact differential case is GREEN in all 20 repetitions. The combined
targeted run passes 74/74 tests across `AsyncExecutionTests` (54),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 64 runtime
fixtures. The full shared-worktree run passes 791 tests in 150 suites; one test
and its suite come from the preserved unrelated untracked corpus-sweep file, so
this tracked repository step accounts for 790 tests in 149 suites.
`Scripts/gate.sh` is green in 775 seconds with the same shared-worktree 791-test
suite, the unchanged 678/680 project-corpus ratchet, 5/5 live-data scenarios,
and API parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
0 no-twin. Throwing-`next` cancellation projection, throwing-group exceptional
exit, group iteration, and the remaining exceptional cleanup combinations
remain open.

### M4 throwing `next` cancellation projection

`task-group-throwing-next-cancellation.swift` cancels a throwing group before
adding its sole child. That child immediately calls `Task.checkCancellation()`,
and the owner awaits `group.next()`. A generic catch compares the dynamic error
metatype with `CancellationError.self` and separately checks the owner task's
cancellation flag.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`cancellation:owner-active` exactly. The pre-cancelled group and sole child
remove scheduler and error-selection choices: observing inherited group
cancellation makes throwing `next` deliver `CancellationError`, while delivery
does not itself cancel the owner.

The same-source interpreter case was RED in all 20 repetitions as
`wrong-error:owner-active`; the completion was consumed correctly, but
`nextSourceTaskGroupValue` substituted its unsupported host diagnostic.
Throwing-group `.cancelled` outcomes now throw `CancellationError`, parallel to
their already-proved projection through `waitForAll`. Nonthrowing-group behavior
and source-error payload projection are unchanged.

White-box coverage retains the group and owner records across lexical cleanup.
It observes one completed and consumed child ID, zero pending completions, an
owner with neither requested nor observed cancellation, and empty scheduler,
task, group, and structured-scope registries after return.

The exact differential case is GREEN in all 20 repetitions. The combined
targeted run passes 75/75 tests across `AsyncExecutionTests` (55),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 65 runtime
fixtures. The full shared-worktree run passes 793 tests in 151 suites. Two tests
and two suites come from preserved unrelated untracked files
(`SwiftUpstreamCorpusSweepTests` and `TaskObservatoryTests`), so this tracked
repository step accounts for 791 tests in 149 suites. `Scripts/gate.sh` is green
in 746 seconds with the same shared-worktree 793-test suite, the unchanged
678/680 project-corpus ratchet, 5/5 live-data scenarios, and API parity at 345
match / 0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin.
Throwing-group exceptional exit, group iteration, and the remaining exceptional
cleanup combinations remain open.

### M4 throwing task-group normal exit discards an unconsumed failure

`task-group-throwing-implicit-failure.swift` adds one throwing child behind an
explicit MainActor gate. The child records entry, the group body records its
normal return and opens the gate, and the child records failure immediately
before throwing. The caller then records the value returned by the group.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`child-start,body-return,child-failed,scope-return-body-value` exactly. The gate
and lexical program order establish every asserted edge. The compiler also
accepts the `withThrowingTaskGroup` call without `try`: because the body itself
does not throw, `rethrows` proves that an unconsumed child error cannot escape
the call. Child completion order relative to any independent work is not
asserted.

The initial same-source interpreter case was RED in all 20 repetitions with
`throwing task-group scope-exit failure propagation is not supported yet`.
Normal cleanup incorrectly treated the joined child outcome as though it had
been consumed through a throwing group API.

The throwing-group `.scopeExit` outcome policy now only joins and destroys the
group. It does not project child failures; `next` and `waitForAll` retain their
separate completion-ordered source-error and cancellation projection. Cleanup
when the body itself throws is unchanged and remains a separate parity
question.
White-box coverage uses three children (success, failure, success), observes
all three completions before the body value leaves the scope, and verifies
empty scheduler, task, group, and structured-scope registries afterward.

The exact differential case is GREEN in all 20 repetitions. The combined
targeted run passes 76/76 tests across `AsyncExecutionTests` (56),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 67 runtime
fixtures. The full shared-worktree run passes 795 tests in 151 suites; one test
and suite come from the preserved user-owned untracked
`TaskObservatoryTests.swift`, so the tracked repository accounts for 794 tests
in 150 suites. `Scripts/gate.sh` is green in 708 seconds with the same 795-test
shared-worktree suite, the unchanged 678/680 project-corpus ratchet, 5/5
live-data scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin. Body-throwing group exit, group iteration,
and the remaining exceptional defer/cleanup combinations remain open.

### M4 nonthrowing task-group async iteration

`task-group-iteration.swift` adds three nonthrowing children returning 1, 2,
and 3, consumes the group with `for await`, and then calls `next()` once more.
Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`3:6:empty` exactly. The count proves that all three child outcomes were
visited, the commutative sum avoids promoting completion order into a
guarantee, and the trailing empty read proves that iteration consumes rather
than copies each outcome.

The initial same-source interpreter case was RED with
`for-in requires a range or an array, got SwiftInterpreter.RuntimeTaskGroup`.
The suspending statement evaluator only knew how to materialize synchronous
collections before entering a loop, so it could not represent an async
sequence whose next element may require suspension.

The evaluator now recognizes an active nonthrowing `RuntimeTaskGroup` as a
streaming `for await` source. Every iteration requests exactly one element
through the same completion-queue and ownership path as `group.next()`, runs
the loop body before requesting another, and stops when that path returns
`.none`. Synchronous finite loops and their prepared fast path are unchanged;
both loop kinds share one pattern-binding and body-control implementation.
Throwing-group iteration remains an explicit unsupported diagnostic until its
error and early-exit behavior have their own native probes.

White-box coverage observes exactly one consumed child when the first loop
body begins, then verifies the three-element count and sum, a drained trailing
`next()`, and empty scheduler, task, group, and structured-scope registries.

The exact differential case is GREEN in all 20 repetitions. The combined
targeted run passes 77/77 tests across `AsyncExecutionTests` (57),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 68 runtime
fixtures. The full shared-worktree run passes 796 tests in 151 suites; one
test and suite come from the preserved user-owned untracked
`TaskObservatoryTests.swift`, so the tracked repository accounts for 795 tests
in 150 suites. `Scripts/gate.sh` is green in 710 seconds with the same
796-test shared-worktree suite, the unchanged 678/680 project-corpus ratchet,
5/5 live-data scenarios, and API parity at 345 match / 0 diverge / 0
interpreter errors / 17 unstable / 0 no-twin. Body-throwing group exit,
throwing and early-exit group iteration, and the remaining exceptional
defer/cleanup combinations remain open.

### M4 successful throwing task-group async iteration

`task-group-throwing-iteration.swift` adds three successful throwing-group
children returning 1, 2, and 3, consumes them with `for try await`, and then
calls throwing `next()` once more. Twenty bounded Apple Swift 6.3.3
strict-concurrency runs produced `3:6:empty` exactly. Count and commutative sum
prove exactly-once delivery without choosing completion order; the final empty
read proves the shared completion queue is drained.

The initial same-source interpreter case was RED in all 20 repetitions as
`error`. The suspending statement evaluator recognized the runtime group but
explicitly rejected every throwing group before entering its streaming loop.

Both group kinds now enter the same streaming statement path. Each iteration
requests one outcome through `nextSourceTaskGroupIterationValue`, which already
uses the group's completion-ordered, exactly-once `next()` implementation and
projects throwing-group outcomes through the established source-error and
cancellation rules. Finite synchronous loops and nonthrowing group iteration
are unchanged.

White-box coverage observes consumed-result counts `[1, 2, 3]` after the three
loop bodies, then verifies three published and consumed child IDs, zero pending
completions, and empty scheduler, task, group, and structured-scope registries
after lexical exit.

The exact differential case is GREEN in all 20 repetitions. The combined
targeted run passes 78/78 tests across `AsyncExecutionTests` (58),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 70 runtime
fixtures. The full shared-worktree run passes 798 tests in 151 suites; one test
and suite come from the preserved user-owned untracked
`TaskObservatoryTests.swift`, so the tracked repository accounts for 797 tests
in 150 suites. `Scripts/gate.sh` is green in 692 seconds with the same 798-test
suite, the unchanged 678/680 project-corpus ratchet, 5/5 live-data scenarios,
and API parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
0 no-twin. Early loop exit and remaining exceptional cleanup combinations stay
open for their own native probes; body-throwing exit, failure iteration, and
cancellation iteration are characterized below.

### M4 throwing task-group body-error scope exit

`task-group-throwing-body-throw.swift` starts one throwing-group child, holds
the body behind a started barrier until that child is inside a 30-second
cancellable sleep, and then throws a distinct body error. Twenty bounded Apple
Swift 6.3.3 strict-concurrency runs produced
`child-start,body-throw,child-cancelled,caught-body` exactly. The barrier fixes
the first edge, the body throw requests structured cleanup, and the outer catch
cannot run before the group has joined its child. No unrelated ready-task order
is asserted.

The initial same-source interpreter case was already GREEN in all 20
repetitions, so this step did not manufacture a RED or change production code.
The general exceptional-exit path already cancels every unfinished group child
with `.structuredScopeExit`, waits for completion, closes the group and scope,
releases their active task records, and then rethrows the original body error.
The child's caught cancellation outcome therefore cannot replace that error.

Focused runtime coverage retains the closed records long enough to verify one
throwing group child, exactly one `.structuredScopeExit` cancellation source,
observed cancellation followed by a successful child catch, an unconsumed
completion, an uncancelled owner, and empty scheduler, task-group, structured-
scope, and active-task registries after exit.

The combined targeted run passes 80/80 tests across `AsyncExecutionTests`
(60), `HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 72
runtime fixtures. The full shared-worktree run passes 800 tests in 151 suites;
one test and suite come from the preserved user-owned untracked
`TaskObservatoryTests.swift`, so the tracked repository accounts for 799 tests
in 150 suites. `Scripts/gate.sh` is green in 495 seconds with the same 800-test
shared-worktree suite, the unchanged cached 678/680 project-corpus ratchet, 5/5
live-data scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M4 throwing task-group iteration failure

`task-group-throwing-iteration-failure.swift` starts one child inside a
30-second cancellable sleep and holds a second child behind that started
barrier. The second child then records and throws a nominal source error while
the group body consumes results with `for try await`. Twenty bounded Apple
Swift 6.3.3 strict-concurrency runs produced
`sibling-start,child-failed,sibling-cancelled,caught-child` exactly. Each edge
comes from the barrier, error propagation, or structured-scope join rather than
an assumed ready-task order.

The same-source interpreter case was already GREEN in all 20 repetitions, so
this characterization also required no production change. Iteration delegates
to the completion-ordered `next()` path: it consumes the failed outcome once
and rethrows its stored interpreted source value. The existing exceptional
group exit then requests `.structuredScopeExit` cancellation on the unfinished
sibling, joins it, closes ownership, and preserves the iteration error for the
outer catch.

Focused runtime coverage verifies two completed group children, exactly one
consumed failed child, one unconsumed sibling completion, successful recovery
inside the cancelled sibling, an uncancelled owner, and empty scheduler,
task-group, structured-scope, and active-task registries after exit.

The combined targeted run passes 81/81 tests across `AsyncExecutionTests`
(61), `HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 73
runtime fixtures. The full shared-worktree run passes 801 tests in 151 suites;
one test and suite come from the preserved user-owned untracked
`TaskObservatoryTests.swift`, so the tracked repository accounts for 800 tests
in 150 suites. `Scripts/gate.sh` is green in 497 seconds with the same 801-test
shared-worktree suite, the unchanged cached 678/680 project-corpus ratchet, 5/5
live-data scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M4 throwing task-group iteration cancellation

`task-group-throwing-iteration-cancellation.swift` first places one child
inside a 30-second cancellable sleep, then calls `cancelAll()`, adds a second
child, and consumes the group with `for try await`. The late child inherits the
group cancellation request and calls `Task.checkCancellation()`. Twenty
bounded Apple Swift 6.3.3 strict-concurrency runs produced
`cancellation:owner-active:joined` exactly. The output deliberately omits child
completion order: it proves only the cancellation error's type, the owner
task's independent cancellation state, and the structured join of both
children before the outer catch runs.

The same-source interpreter case was already GREEN in all 20 repetitions, so
this characterization required no production change. Throwing iteration uses
the shared completion-ordered `next()` path, which consumes a cancelled child
outcome once and projects it as `CancellationError`. Explicit group
cancellation reaches the sleeping sibling and is inherited by the late child;
exceptional scope exit joins both without propagating cancellation to the
owner task.

Focused runtime coverage permits one or two consumed outcomes because the
successfully recovering sibling may complete before the cancelled child. It
still proves that the cancelled child is consumed, both children complete,
both retain `.taskGroupCancelAll` as a cancellation source, the owner remains
active, and the scheduler, task-group, structured-scope, and active-task
registries are empty after exit.

The combined targeted run passes 82/82 tests across `AsyncExecutionTests`
(62), `HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 74
runtime fixtures. The full shared-worktree run passes 802 tests in 151 suites;
one test and suite come from the preserved user-owned untracked
`TaskObservatoryTests.swift`, so the tracked repository accounts for 801 tests
in 150 suites. `Scripts/gate.sh` is green in 504 seconds with the same 802-test
shared-worktree suite, the unchanged cached 678/680 project-corpus ratchet, 5/5
live-data scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M4 throwing task-group iteration early exit

`task-group-throwing-iteration-early-exit.swift` starts a sibling which waits
behind an explicit release flag, then starts a child which cannot return until
that sibling has entered its wait. The first `for try await` value is therefore
deterministically `first`; the loop releases the sibling and immediately
breaks. Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`first:active:owner-active:joined` exactly. This proves that `break` does not
cancel the remaining child, normal group scope exit joins it, and the owner
task remains active.

The same-source interpreter case was already GREEN in all 20 repetitions, so
this characterization required no production change. `break` leaves the
streaming loop through ordinary statement control flow. The enclosing
throwing-group body then returns normally and uses the established implicit
join path, without requesting either `cancelAll` or structured-scope
cancellation.

Focused runtime coverage retains both child records, the group, and its owner
through scope closure. It verifies two successful completed children, exactly
one consumed first result, one pending unconsumed sibling result, no
cancellation request on either child or the owner, and empty scheduler,
task-group, structured-scope, and active-task registries after exit.

The combined targeted run passes 83/83 tests across `AsyncExecutionTests`
(63), `HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 75
runtime fixtures. The full shared-worktree run passes 803 tests in 151 suites;
one test and suite come from the preserved user-owned untracked
`TaskObservatoryTests.swift`, so the tracked repository accounts for 802 tests
in 150 suites. `Scripts/gate.sh` is green in 502 seconds with the same 803-test
shared-worktree suite, the unchanged cached 678/680 project-corpus ratchet, 5/5
live-data scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M4 throwing async-let/defer lexical cleanup order

`async-let-throwing-defer-order.swift` composes two rules previously proved
only in isolation: throwing scope exit cancels and joins an unread async-let
child, and `defer` plus async-let teardown share one lexical LIFO stack. Both
registration orders wait until the child has entered a 30-second cancellable
suspension before throwing the same nominal owner error.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced one exact
combined trace:
`child-start,scope-throw,child-cancelled,defer,caught|child-start,scope-throw,defer,child-cancelled,caught`.
When `defer` is registered first, the later async-let cleanup runs first; when
`defer` is registered second, it runs before child cleanup. In both variants
the outer catch executes only after the entire unwind and receives the owner
error rather than a child outcome.

The same-source interpreter case was already GREEN in all 20 repetitions, so
this characterization required no production change. The general error path
in `executeBlockSuspending` closes the same `RuntimeStructuredScopeFrame` used
for normal exit, and that frame traverses its mixed defer/async-let
registrations in reverse order before rethrowing the original error.

Focused runtime coverage retains both child, scope, and owner records through
closure. It verifies successful child recovery from
`.structuredScopeExit` cancellation, one async-let child in each scope,
uncancelled owners, delivery of the nominal error to both catches, and empty
scheduler, structured-scope, and active-task registries afterward.

The combined targeted run passes 84/84 tests across `AsyncExecutionTests`
(64), `HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 76
runtime fixtures. The full shared-worktree run passes 804 tests in 151 suites;
one test and suite come from the preserved user-owned untracked
`TaskObservatoryTests.swift`, so the tracked repository accounts for 803 tests
in 150 suites. `Scripts/gate.sh` is green in 505 seconds with the same 804-test
shared-worktree suite, the unchanged cached 678/680 project-corpus ratchet, 5/5
live-data scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M4 early-return async-let/defer lexical cleanup order

`async-let-early-return-defer-order.swift` repeats both lexical registration
orders while leaving a function through an explicit early `return`. Each child
has entered a 30-second cancellable suspension before the function records
`early-return`; the caller appends the returned value only after the function
has fully completed.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced one exact
combined trace:
`child-start,early-return,child-cancelled,defer,returned|child-start,early-return,defer,child-cancelled,returned`.
The mixed cleanup stack therefore unwinds in reverse registration order, and
the caller cannot observe the return value until child cancellation, join, and
the corresponding `defer` have all finished.

The same-source interpreter case was already GREEN in all 20 repetitions, so
this characterization required no production change. The `.returnValue`
branch of `executeBlockSuspending` closes the same
`RuntimeStructuredScopeFrame` used by normal and error exits before propagating
the statement result to its caller.

Focused runtime coverage retains both child, scope, and owner records. It
verifies successful child recovery from `.structuredScopeExit` cancellation,
one async-let child in each scope, uncancelled owners, post-cleanup return-value
delivery, and empty scheduler, structured-scope, and active-task registries.

The combined targeted run passes 85/85 tests across `AsyncExecutionTests`
(65), `HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 77
runtime fixtures. The full shared-worktree run passes 805 tests in 151 suites;
one test and suite come from the preserved user-owned untracked
`TaskObservatoryTests.swift`, so the tracked repository accounts for 804 tests
in 150 suites. `Scripts/gate.sh` is green in 520 seconds with the same 805-test
shared-worktree suite, the unchanged cached 678/680 project-corpus ratchet, 5/5
live-data scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M4 owner-cancelled async-let/defer lexical cleanup order

`async-let-cancellation-defer-order.swift` repeats both lexical registration
orders after cancelling an owner task. The structured child and owner are each
already inside a 30-second cancellable suspension before cancellation. After
the owner catches `CancellationError` and starts scope unwind, a MainActor
controller releases the child from a yield loop. This barrier separates
cleanup order from the otherwise unspecified order in which cancellation
wakes ready tasks.

Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced one exact
combined trace:
`scope-exit,child-complete,defer,returned:cancelled|scope-exit,defer,child-complete,returned:cancelled`.
When `defer` is registered first, the later async-let cleanup joins the child
before that defer. When `defer` is registered second, it executes before the
child join. In both variants the owner value becomes observable only after all
lexical cleanup, while child, owner, and owner handle retain cancellation
state.

The same-source interpreter case was already GREEN in all 20 repetitions, so
this characterization required no production change. The existing parent
cancellation propagation and mixed lexical cleanup stack already compose on
the caught-cancellation return path.

Focused runtime coverage retains the child, async-let scope, and owner records
through closure. It verifies `.structuredParent` plus
`.structuredScopeExit` cancellation on each successfully recovered child,
task-handle cancellation and successful completion on each owner, one child
per structured scope, and empty scheduler, scope, and active-task registries
afterward.

The combined targeted run passes 86/86 tests across `AsyncExecutionTests`
(66), `HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 78
runtime fixtures. A broader targeted run including ARC, closure, and the
official Swift upstream differential corpus passes 146/146 tests. The full
shared-worktree run passes 806 tests in 151 suites; one test and suite come
from the preserved user-owned untracked `TaskObservatoryTests.swift`, so the
tracked repository accounts for 805 tests in 150 suites. `Scripts/gate.sh` is
green in 553 seconds with the same 806-test shared-worktree suite, the
unchanged cached 678/680 project-corpus ratchet, 5/5 live-data scenarios, and
API parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable /
0 no-twin.

### M3 suspension-expression correction: leading `try await` and ternary

`async-try-await-conditional.swift` calls a throwing async function that
yields once and returns `nil`, compares the result with `nil`, and uses that
comparison as a ternary condition. Twenty bounded Apple Swift 6.3.3
strict-concurrency runs produced `nil` exactly. This establishes that the call
remains under the leading `try await`; it does not establish any scheduler
ordering.

The initial same-source interpreter case was RED in all 20 repetitions as
`error`. A diagnostic run showed that the inner `Task.yield` had reached the
synchronous gateway path. SwiftSyntax represents the leading `try await` over
an operator sequence which folding turns into a ternary expression. The
suspending evaluator propagated forced async invocation through `try` and
infix operands, but the ternary evaluator discarded it while evaluating its
condition. The nested async function was therefore invoked synchronously.

The ternary evaluator now carries the invocation mode into its condition as
well as the one selected result branch. It still evaluates exactly one branch,
so this repairs suspension propagation without weakening ternary laziness.
Focused coverage exercises both a successful optional result and a thrown host
error, observes one invocation of each, proves that the untaken async branch is
never invoked, and finishes with empty scheduler and runtime registries.

The exact differential case is GREEN in all 20 repetitions. The combined
targeted run passes 79/79 tests across `AsyncExecutionTests` (59),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 71 runtime
fixtures. The full shared-worktree run passes 799 tests in 151 suites; one test
and suite come from the preserved user-owned untracked
`TaskObservatoryTests.swift`, so the tracked repository accounts for 798 tests
in 150 suites. `Scripts/gate.sh` is green in 675 seconds with the same 799-test
shared-worktree suite, the unchanged 678/680 project-corpus ratchet, 5/5
live-data scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

## M8 incremental verification record

### Synchronous host callbacks enter the concurrency runtime

The TaskObservatory mismatch came from the real interactive boundary rather
than from `async let`, cancellation handlers, or task groups themselves.
`Button` retained an interpreted closure during rendering and later invoked it
through the legacy synchronous evaluator. With no async session, nested source
tasks took the inline compatibility path: the async-let slices ran
sequentially, and the cancellation-handler and task-group workers failed before
they could finish. `try?` then hid those failures from both the view and tests.

`host-callback-task-runtime.swift` isolates the boundary. Its callback changes
state to `started`, creates a detached task whose operation reduces two
structured group children, and eventually publishes `done-3`. The native
runner invokes the callback synchronously. The interpreter runner first ends
the initial evaluation, then invokes the retained closure through the external
host-callback entry. Twenty bounded Apple Swift 6 strict-concurrency runs and
twenty interpreter runs all returned `started,done-3` exactly, with empty task,
group, and structured-scope ownership afterward.

The runtime now creates a fresh `.hostCallback` record/session for each
synchronous external event, binds an async-capable evaluation context, executes
the callback itself inline, and lets any source tasks it creates continue on
the canonical scheduler. The SwiftUI bridge funnels buttons, generated
actions, gestures, bindings, synchronous event modifiers, and Objective-C
completions through one adapter. Callback errors are
recorded in `RenderDiagnostics` instead of disappearing through `try?`.
HeadlessVerifier and LiveCheck use the same entry, so interactive regressions no
longer pass by exercising a different direct-closure path.

Focused coverage proves the `.hostCallback` record kind, immediate mutation,
nested detached/group completion, ownership cleanup, and diagnostic delivery.
A diagnostic run against the unchanged `Examples/TaskObservatory` source also
entered its `Run` and `Cancel` closures externally and reached
`Completed,Cancelled,Completed`, two `Received orbit-10` observers, and
`TaskGroup reduced 4 values into orbit-10`.

The full shared-worktree run passes 795 tests in 151 suites. One test and its
suite come from the preserved user-owned untracked `TaskObservatoryTests.swift`,
so the tracked repository step accounts for 794 tests in 150 suites.
`Scripts/gate.sh` is green in 697 seconds: the same 795-test shared-worktree
suite passes across four process shards, the corpus remains 678/680, live data
is 5/5, and API parity is 345 match / 0 diverge / 0 interpreter errors / 17
unstable / 0 no-twin across 362 probes.

This does not complete M8; async `.task` lifetime, identity changes, view
removal cancellation, and `.refreshable` remain separate work. Source executor
identity and the TaskObservatory lane projection are covered by the M5 step
below; physical worker-pool execution remains intentionally deferred to M9.

## M5 incremental verification record

### Logical executor identity and `@concurrent` hops

The remaining TaskObservatory mismatch was executor identity, not the already
repaired callback entry or structured-task lifecycle. The interpreter executes
its mutable evaluator physically on native MainActor, so forwarding
`Thread.isMainThread` to the host thread made every interpreted worker report
`Main thread` even when Swift runs the corresponding `@concurrent nonisolated`
method on its cooperative global executor.

`concurrent-executor-hop.swift` isolates that rule. A MainActor-isolated caller
records its lane, directly awaits a `@concurrent nonisolated` method, repeats
the call through `Task.detached`, and records its lane again. The concurrent
method records entry and post-`Task.yield` lanes and awaits a MainActor method
between them. Twenty bounded Apple Swift 6.3.3 strict-concurrency runs produced
`main|worker:worker:main|worker:worker:main|main` exactly. The same-source
interpreter case was RED in all 20 repetitions as
`main|main:main:main|main:main:main|main`.

Runtime task records now own an initial logical executor preference, and each
task-owned `EvaluationTaskContext` owns its mutable current executor. Task
creation either inherits that identity or selects detached identity. Function
declarations retain the executor metadata already present in their syntax:
`@concurrent` selects the cooperative default executor, direct or lexical
`@MainActor` isolation selects MainActor, and synchronous `nonisolated` helpers
inherit their caller. Both synchronous and suspending invocation install the
callee preference for its dynamic extent and restore the caller preference on
every exit.

The SwiftUI `Thread.isMainThread` bridge projects the current source executor
instead of the physical thread hosting the evaluator. This is a deliberate
abstraction boundary: exposing the native hosting MainActor would make source
semantics depend on an implementation detail and would prevent the later
cooperative executor from being testable. A focused real-host-callback
regression observes `worker:worker:main` across
`Task.detached -> @concurrent -> @MainActor`.

A read-only diagnostic against the unchanged `Examples/TaskObservatory` source
reached `Completed,Cancelled,Completed`; all Atlas, Beacon, and Comet work was
reported as `Worker pool`, while Root, cancellation-handler dispatch, and
shared-result waiters were reported as `Main thread`. Independent ready-task
order is deliberately not compared to one native trace; causal dependencies,
terminal results, and executor lanes are compared.

The exact differential case is GREEN in all 20 repetitions. This step does not
yet implement actor mailboxes, executor serialization, arbitrary global
actors, isolated parameters, closure isolation annotations, or physical
parallel execution. Those remain explicit M5/M9 work rather than being
inferred from logical lane parity.

The combined targeted run passes 81/81 tests across `AsyncExecutionTests`
(57), `HostSignatureTests` (12), `ConcurrencyParityTests` (8),
`HostCallbackAdapterTests` (3), and the preserved user-owned
`TaskObservatoryTests` (1), with 69 runtime fixtures. The full shared-worktree
gate passes 797 tests in 151 suites; one test and suite come from that untracked
TaskObservatory integration test, so the tracked repository accounts for 796
tests in 150 suites. `Scripts/gate.sh` is green in 727 seconds with the same
797-test suite, the unchanged 678/680 project-corpus ratchet, 5/5 live-data
scenarios, and API parity at 345 match / 0 diverge / 0 interpreter errors / 17
unstable / 0 no-twin across 362 probes.

## Official Swift upstream intake

### Pinned Swift 6.3.3 concurrency runtime corpus

The upstream harness now pins `swiftlang/swift` at
`swift-6.3.3-RELEASE` / `064859e41d68596f486c5d724401cb370f260409`.
Its reproducible sparse-checkout script inventories all 134 Swift sources in
`test/Concurrency/Runtime`, assigns every file an explicit `direct`,
`diagnostic`, `needs-adapter`, or `unsupported` reason, and copies only
manifest-selected fixtures byte-for-byte. The current inventory is 6 direct,
4 diagnostic, 117 needs-adapter, and 7 unsupported.

Native Swift compiles every selected concurrency fixture in Swift 6 strict
concurrency mode. The interpreter receives the same source plus only a generic
detected-`@main` entry. A local literal FileCheck subset validates both native
and interpreted output; unsupported regex and variable syntax is rejected
rather than weakened. The first direct tranche covers throwing `async let`,
pre-start cancellation with a late async-let child, task-handle cancellation,
task-group pending `next()`, and task-group `isEmpty` while a child is pending
and after its completion has been consumed. The next direct fixture covers
`addTaskUnlessCancelled` for both ordinary and discarding groups whose owner is
already cancelled.

The previously selected interpreter tests remain exact-output cases. Normal
test runs are fully offline; `Scripts/sync-swift-upstream-tests.sh` is the only
networked refresh path and verifies the resolved upstream commit before
regenerating the corpus and inventory.

### Upstream-discovered pre-cancelled async-let semantics

`async_task_cancellation_early.swift` initially found two general gaps. First,
`#function` was an inert host marker. Function declarations now retain native
magic-identifier spelling with external labels, invocation frames expose it,
and escaping closures capture the lexical value. Sync, suspending, method, and
closure paths have focused coverage.

Second, the runtime propagated structured cancellation only when the request
edge fired. A child added after that event therefore started active. Task
creation now treats cancellation as parent state: every newly created
`asyncLet` or task-group child immediately receives `.structuredParent` when
its owner is already cancelled; unstructured creation remains isolated.

The upstream test also exposed that the async evaluator rethrew
`CancellationError` from `try?`. Native Swift catches that source error and
continues. The evaluator now does the same while still rethrowing the private
`InterpreterSessionAbort` control signal, so host/session teardown cannot be
swallowed by source `try?`.

The minimal same-source fixture
`async-let-created-after-owner-cancellation.swift` uses a MainActor barrier to
place cancellation before the declaration. Apple Swift 6.3.3 and the
interpreter both produce `owner-cancelled:child-cancelled` in all 20 bounded
runs. All 79 runtime fixtures and all 14 selected official upstream fixtures
are green.

The closing `Scripts/gate.sh` run is GREEN in 741 seconds: 817 shared-worktree
tests pass across four parity shards, the project corpus remains at its
documented 678/680 floor, all 5 live-data scenarios pass, and API parity is
345 match / 0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin across
362 probes. One test belongs to the preserved user-owned untracked
`TaskObservatoryTests.swift`, so the tracked repository accounts for 816 tests.

### M4 task-group body-defer cancellation before implicit cleanup

`task-group-defer-cancel-cleanup-order.swift` places one nonthrowing group child
inside a 30-second cancellable suspension, records `body-return`, and registers
a body `defer` that records `defer-cancel` before calling `group.cancelAll()`.
The MainActor start flag proves that the child is already suspended before the
body can return. Twenty bounded Apple Swift 6.3.3 strict-concurrency runs
produced exactly
`child-start,body-return,defer-cancel,child-cancelled,after-scope`.

This establishes three ordered guarantees without selecting a scheduler order:
the body defer runs before implicit task-group cleanup, its cancellation request
reaches the active child, and execution after `withTaskGroup` begins only after
the child has completed and the group has joined it.

The same-source interpreter case was already GREEN in all 20 repetitions, so
this characterization required no production change. The general closure
unwind executes the source defer while the group capability is still active;
`cancelAll` uses the runtime cancellation graph, and `closeSourceTaskGroup`
then performs the ordinary implicit join. Focused runtime coverage verifies a
successful child recovery carrying exactly `.taskGroupCancelAll`, one pending
unconsumed completion, an uncancelled owner, and empty scheduler, task-group,
structured-scope, and active-task registries after exit.

The combined targeted run passes 88/88 tests across `AsyncExecutionTests`
(68), `HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 80
runtime fixtures. `Scripts/gate.sh` is GREEN in 547 seconds: 818 shared-worktree
tests pass across four process shards, the unchanged cached project corpus is
678/680, all 5 live-data scenarios pass, and API parity is 345 match / 0
diverge / 0 interpreter errors / 17 unstable / 0 no-twin across 362 probes.
All 818 tests belong to the tracked repository after the independent
TaskObservatory commit `a3d628c` landed during this iteration.

### M4 throwing task-group defer before exceptional cleanup

`task-group-throwing-defer-cleanup-order.swift` starts one throwing-group child
inside a 30-second cancellable suspension, registers a body `defer`, records
`body-throw`, and throws a distinct nominal source error. The MainActor start
flag fixes child entry before the throw. Twenty bounded Apple Swift 6.3.3
strict-concurrency runs produced exactly
`child-start,body-throw,defer,child-cancelled,caught-body`.

The body defer therefore finishes before exceptional task-group cleanup
requests child cancellation. The outer catch cannot run until the child has
completed and the group has joined it, and it receives the original body error
rather than a child outcome. No independent ready-task order is asserted.

The same-source interpreter case was already GREEN in all 20 repetitions, so
no production change was needed. The closure's general structured-block unwind
runs its deferred bodies before rethrowing; the task-group boundary then uses
the existing exceptional cancel-and-join path. Focused runtime coverage
verifies exactly `.structuredScopeExit` on the successfully recovering child,
an unconsumed completion, an uncancelled owner, and empty scheduler,
task-group, structured-scope, and active-task registries after exit.

The combined targeted run passes 89/89 tests across `AsyncExecutionTests`
(69), `HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 81
runtime fixtures. `Scripts/gate.sh` is GREEN in 550 seconds: all 819 tracked
tests pass across four process shards, the unchanged cached project corpus is
678/680, all 5 live-data scenarios pass, and API parity is 345 match / 0
diverge / 0 interpreter errors / 17 unstable / 0 no-twin across 362 probes.

### M4 owner-cancelled task-group defer before implicit join

`task-group-owner-cancellation-defer-cleanup-order.swift` starts a group child
inside a 30-second cancellable suspension and holds its post-cancellation
completion behind a MainActor release flag. The owner does not leave the group
body until its handle has been cancelled. Its body defer records `defer` and
opens the child release; the caller reads the owner value only after the group
scope has closed. Twenty bounded Apple Swift 6.3.3 strict-concurrency runs
produced exactly
`child-start,scope-exit,defer,child-cancelled,returned:cancelled`.

This proves that owner cancellation does not skip the task-group body's defer,
that an already-cancelled structured child remains joined at normal group-body
return, and that the owner's successful value is not published until cleanup
finishes even though its source handle remains cancelled. The release barrier
fixes every compared edge; no unrelated scheduler order is asserted.

The same-source interpreter case was already GREEN in all 20 repetitions, so
no production change was required. Focused runtime coverage verifies only
`.structuredParent` on the successfully recovering child, only `.taskHandle`
on the successfully completing owner, owner-cancellation state on the active
group, one unconsumed completion, and empty scheduler, task-group,
structured-scope, and active-task registries after exit.

The combined targeted run passes 90/90 tests across `AsyncExecutionTests`
(70), `HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 82
runtime fixtures. `Scripts/gate.sh` is GREEN in 554 seconds: all 820 tracked
tests pass across four process shards, the unchanged cached project corpus is
678/680, all 5 live-data scenarios pass, and API parity is 345 match / 0
diverge / 0 interpreter errors / 17 unstable / 0 no-twin across 362 probes.

The M4 completion audit maps every async-let lifecycle item and the task-group
completion-order, `next`, `waitForAll`, `cancelAll`, iteration, throwing,
cancellation, and scope-exit paths to committed native fixtures above. It also
confirmed zero active runtime registries in a fresh focused test process and
in the four gate shards. The audit did not promote M4 to complete: nested
composition, remaining generated task-group surface, structured stress/leak
plateaus, and escaped-capability legality remain explicit acceptance rows.
Native compiler enforcement of group escape remains an M7 preflight deliverable
rather than being claimed as M4 runtime support.

### M4 child-owned nested task group

`task-group-child-nested-group.swift` places a task group inside one child of
an outer task group. The inner child records entry, waits on a MainActor gate,
then publishes `value`; explicit `next()` calls at both levels force the inner
grandchild join before the outer child result and the outer child join before
the function result. Twenty bounded Apple Swift 6.3.3 strict-concurrency runs
produced exactly
`grandchild-start,inner-open,grandchild-end,inner-finished,outer-finished:value`.

The same-source interpreter case was already GREEN in all 20 repetitions, so
this characterization required no production change. Focused runtime evidence
records distinct outer-owner, group-child, and grandchild task records; proves
the parent, group, and structured-scope ownership edges at both levels; proves
one completed and consumed child in each group; and finishes with empty task,
group, and structured-scope registries.

### M4 upstream task-group `isEmpty` and generated dispatch

The unchanged swiftlang fixture
`test/Concurrency/Runtime/async_taskgroup_is_empty.swift` is now a direct case
from the pinned `swift-6.3.3-RELEASE` commit. Native Swift and the interpreter
compile and run the same file. Its FileCheck oracle proves that a newly created
group is empty, a pending child makes it nonempty, consuming that child through
`next()` makes it empty again, and the enclosing operation returns `42`.

The first interpreter run was deliberately RED with
`TaskGroup.isEmpty is not supported yet`. The runtime now defines emptiness in
terms of unconsumed child outcomes, so a completed result remains part of the
group until `next()` or iteration consumes it. Focused state coverage verifies
the child is completed and consumed and that task, group, structured-scope,
and scheduler registries are empty after scope exit.

`ConcurrencySurfaceGen` parses the active SDK's
`_Concurrency.swiftinterface` with SwiftSyntax and emits the task-group member
inventory plus source-name-to-runtime-intrinsic dispatch. This replaces the
handwritten alias switch and picks up the SDK's deprecated `add`, `spawn`, and
`async` spellings, including their `UnlessCancelled` variants. Unsupported
members discovered in the active interface remain explicit diagnostics rather
than silent fallbacks. `swift run ConcurrencySurfaceGen --check` verifies that
the checked-in artifact is current without rewriting it. Discarding task
groups and their distinct semantics remain open M4 work.

### M4 discarding task-group runtime kinds

The unchanged swiftlang fixture
`test/Concurrency/Runtime/async_taskgroup_addUnlessCancelled.swift` is the
sixth direct concurrency case from the pinned release. Its two halves run the
same already-cancelled owner scenario through `withTaskGroup` and
`withDiscardingTaskGroup`; native Swift and the interpreter both report
`Task added = false` twice, so the discarding group shares the combined owner
cancellation state without allocating a child.

Discarding groups are distinct runtime kinds rather than aliases for ordinary
groups. They omit the child-result-type requirement, automatically consume a
completion, clear its child-record outcome, and make `isEmpty` true once no
unconsumed child remains. Throwing discarding groups retain only their first
failed or cancelled outcome, mark the group cancelled, propagate a distinct
`.taskGroupChildFailure` reason to siblings and later children, join all work,
and then project that first error. A body error still owns exceptional exit:
the group cancels and joins children before the original body error is rethrown.

The generated interface artifact now inventories `TaskGroup`,
`ThrowingTaskGroup`, `DiscardingTaskGroup`, and
`ThrowingDiscardingTaskGroup` independently. This prevents result-consuming
members such as `next` and `waitForAll` from leaking onto discarding groups
while preserving their generated `addTask`, `addTaskUnlessCancelled`,
`cancelAll`, `isCancelled`, and `isEmpty` dispatch. Focused state tests cover
successful auto-consumption and throwing child-error projection with empty
task, group, structured-scope, and scheduler registries after exit. Separate
bounded fan-out and memory-plateau acceptance remains open.

### M2 post-completion task-handle cancellation

`task-cancellation-after-completion.swift` asks one terminal-state question.
Its first `await task.value` establishes that the unstructured task has
completed before the handle receives `cancel()`. Apple Swift 6.3.3 in Swift 6
strict-concurrency mode produces exactly
`active,cancelled,value,value`: late cancellation changes the handle flag, but
neither the successful outcome nor later value reads.

This was a recorded gap closure. Before the runtime change, the same source
produced `active,active,value,value` through the interpreter because
`requestCancellation` returned before recording a request on every completed
task. The runtime now records cancellation before its terminal-state guard and
then skips all active-work side effects. A focused record test additionally
releases the completed task from the active registry before cancelling its
retained handle; the state remains `succeeded`, the typed `String` outcome
remains `value`, cancellation is requested but unobserved, and the registry
remains empty.

The promoted exact differential and both focused cancellation tests were
GREEN. At that iteration, M2 remained provisional only for the stronger
lifetime requirement: an escaped completed handle still needed proof that it
did not retain its interpreter session or native driver.

### M2 completed-handle session and driver release

The focused ownership regression first failed with both the runtime and task
record still alive after their completed source handle escaped. The handle
strongly owned the complete mutable record, which in turn retained the native
Swift task driver; removing the record from the active registry did not break
that graph.

`release` now atomically replaces the active runtime/record edge with a compact
value-only snapshot. It preserves task identity, the typed immutable outcome,
diagnostic metadata, and the cancellation state needed for repeated
`value`/`result` reads and late `cancel()`. It also removes both sides of any
remaining waiter dependency, drops the native driver, and severs the handle's
runtime reference. A weak-reference regression proves that the driver, record,
and complete runtime/session graph deallocate while the escaped handle still
returns `value` and remains cancellable.

The same-source native board remains GREEN for 20 repeated completed-handle
reads, 20 dropped-live-handle runs, and the post-completion cancellation case.
The focused task, cancellation, structured-runtime, and methodology run passes
89/89 tests. The machine-readable repository gate receipt is the final
source-bound evidence for this M2 completion claim.

### M3 seeded cancellation-race exploration

`CancellationRaceExplorationTests` runs 64 deterministic seeds in the ordinary
test gate. Seed bits select both cancel-versus-complete orders, four
cancel-versus-manual-clock-wake boundaries, both cancellation-handler
unregister orders, and one through four duplicate cancellation requests. Each
iteration verifies terminal outcome/cancellation independence, wake and
observation consistency, one-shot handler invocation, and empty sleeper,
suspension, handler, and active-task registries.

The board deliberately varies only explicit happens-before boundaries; it does
not promote a native scheduler's ready-task order into a guarantee. Failures
include the exact `DYNAMIC_SWIFT_CANCELLATION_RACE_SEED=0x... swift test
--filter CancellationRaceExplorationTests` replay command. The negative
control verifies that diagnostic, and a focused replay of seed
`0xcacec0de0000002d` executes exactly one iteration.

Fresh Apple Swift 6.3.3 differential runs remain GREEN for 20/20 repetitions
of cancellation-before-start, cancellable sleep, active cancellation handlers,
and handler scope exit, plus the post-completion cancellation fixture. The
unchanged pinned swiftlang executable corpus also remains GREEN, including
`test/Concurrency/Runtime/async_task_cancellation_early.swift`. These native
fixtures anchor the semantic endpoints while the seeded runtime board explores
their cancellation boundaries. M3 is complete; the next dependency-ready work
belongs to M4.
