# Swift Concurrency parity ledger

This ledger records facts established by compiling the committed native probes
with the active Apple Swift toolchain. It distinguishes language guarantees
from observed scheduler order and tracks interpreter support without silent
fallbacks.

Normative architecture, operational methodology, and executable acceptance
status are separate sources:

- [`SwiftConcurrencyArchitecture.md`](SwiftConcurrencyArchitecture.md) defines
  the target design;
- [`ConcurrencyVerificationMethodology.md`](ConcurrencyVerificationMethodology.md)
  defines evidence and closure rules; and
- `Tests/ConcurrencyParity/Manifests/milestone-acceptance.json` assigns every
  parity fixture to a dependency-gated requirement.

External completeness accounting is split deliberately:

- `generated-concurrency-api.json` is the generated active-SDK declaration
  denominator for its explicitly incomplete top-level-function,
  Task/task-group-member, and selected nested task-group-iterator scope; and
- `concurrency-capability-status.json` is the authored implementation and
  verification overlay, pinned to the inventory digest.

An adapter route in the generated inventory is dispatch metadata, not support
evidence. The current inventory therefore must not be reported as full
`_Concurrency` completeness; its exclusions are part of the checked-in claim.

## Toolchain baseline

Initial Milestone 0 run:

- Apple Swift 6.2.3 (`swift-6.2.3-RELEASE`);
- target `arm64-apple-macosx26.0`;
- macOS 26.5 SDK;
- language mode Swift 6;
- `-strict-concurrency=complete`.

`ConcurrencyParityTests.toolchainFingerprintIsComplete` validates the live
compiler path, complete version output, SDK path, and SDK version. A closing
gate persists them in its machine-readable verification receipt; the focused
test alone is not historical evidence. These values are metadata, not
hard-coded pass criteria beyond Swift major version 6.

## Milestone status

This table is the current claim and supersedes historical “closed” wording in
the chronological verification record. Native-backed gaps discovered after a
closing gate move a milestone to `provisional` without invalidating the
evidence that remains covered.

| Milestone | Status | Evidence | Remaining work |
|---|---|---|---|
| M0 native parity infrastructure | complete | Same-source runtime and diagnostic oracles; compiler/SDK fingerprinting; bounded fresh-process repetitions and process-tree cleanup; exact shard/repetition/digest receipts; negative controls; durable source-bound gate receipts. | None |
| M1 task-owned evaluator context | complete | Task-owned evaluator contexts, cancellation isolation, async-initializer ownership, and detached host re-entry have native parity and focused ownership coverage. | None; M2 may proceed. |
| M2 task runtime | complete | Task outcomes, cancellation request versus observation, post-completion cancellation, completed-handle session/driver release, waiter and handle lifetimes, detached and top-level policy, priority donation and scoped escalation-handler delivery, task-local inheritance/unwind, and leased `UnsafeCurrentTask` identity/state have native parity and focused ownership proof. | None; M3 may proceed. |
| M3 suspension and clocks | complete | Runtime-owned task waits, host suspension, cancellable sleep, yield progress, cancellation-handler timing and cleanup through both the modern and deprecated public overloads, and seeded replayable cancellation-race exploration have native parity and focused runtime coverage. | None; M4 may proceed. |
| M4 structured concurrency | partial | Async-let ownership and lexical cleanup plus nonthrowing and throwing task-group joining, iteration, cancellation, all four public group-scope declarations for their evidenced default-isolation subsets, all eight generated `isEmpty`/`isCancelled` state properties, all four `cancelAll()` declarations, all four canonical `addTask(priority:operation:)`, all four canonical `addTaskUnlessCancelled(priority:operation:)`, all eight named add declarations without executor preference for their evidenced nonisolated subsets with task-owned names preserved, all eight `addTask` executor-preference declarations for their explicit-nil nonisolated subsets with non-nil preferences rejected by a shared guard and arbitrary-actor executor divergences recorded, all eight `addTaskUnlessCancelled` executor-preference declarations for active explicit-nil acceptance and post-cancellation rejection without child creation, with the shared non-nil guard and arbitrary-actor executor divergences recorded, and all eight `addImmediateTask`/`addImmediateTaskUnlessCancelled` declarations for their explicit-nil inherited-MainActor subsets with synchronous-prefix execution, Task.name, join, and cancellation-before-preference-validation evidence while non-nil preference and arbitrary-actor divergences remain recorded, all four ordinary/throwing group `next()` declarations, both deprecated `spawn()`, both deprecated `async()`, both deprecated conditional `add()` aliases, both deprecated `asyncUnlessCancelled()` aliases, and both deprecated `spawnUnlessCancelled()` aliases, explicit ordinary and throwing `makeAsyncIterator()` capabilities plus all six generated iterator `next`/`cancel` rows with value-semantic terminal state, default plus explicit-MainActor `waitForAll()` behavior, and `ThrowingTaskGroup.nextResult()` result projection with the arbitrary-actor executor gaps recorded, nested Task/async-let/group ownership, child-created unstructured lifetime, task-local and executor inheritance, error projection, draining, bounded stress, replayable cancellation storms, weak lifetime release, and process-isolated RSS/heap plateaus have native parity, focused runtime evidence, or an explicit negative disposition. | All currently generated task-group declarations have explicit dispositions and the target-aware escaped-capability boundary is covered. The remaining repeated-wait/new-work, non-nil TaskExecutor preference, and arbitrary-actor operation-executor semantics are demand-deferred (2026-07-16): they reopen only on a cited real-program failure; positive claims still require executable evidence and negative/deferred claims still require owned gap or deferral evidence. |
| M5 actor support and executor architecture | provisional | Logical cooperative-default and MainActor executor identity, source hops, caller restoration, detached-task lane identity, distinct source-actor runtime IDs, weak actor-record cleanup, canonical user-declared global-actor mapping through static shared, struct- and enum-backed arbitrary global-actor capability propagation through `#isolation` and defaulted isolated dispatch, depth-counted mailbox ownership for synchronous and async actor-function plus externally awaited synchronous computed-getter and subscript-getter segments, throwing computed-getter failure cleanup, async-throwing computed/subscript-getter success/source-error/cancellation reacquisition cleanup with caller restoration, actor computed-property and subscript-setter confinement to already-owned segments, controlled suspension release/reacquisition and actor reentrancy, task-local propagation through actor hops and suspension, retained queued actor messages after task cancellation, cross-actor throwing and cancellation-observing function hops with caller restoration, explicit plus defaulted/optional source-actor, MainActor, custom-global-actor, and nil isolated-parameter dispatch, explicit waitingForActor handoff/cleanup, replayable seeded mailbox stress with complete runtime draining, mutable stored-property confinement with Swift-compatible immutable-let and nonisolated exceptions, MainActor-owned deinitializer execution, fail-closed source-actor/user-global-actor deinitializer boundaries, and fail-closed custom actor-executor dispatch are covered. | The demand-scoped M5 actor cycle is covered. M5 remains provisional while its broad M4 and M7 prerequisite milestones retain explicitly owned partial-surface gaps; custom actor-executor scheduling and physical workers are not claimed. |
| M6 async sequences/continuations | partial | Protocol-level `for await` dispatches `makeAsyncIterator()` and suspending `next()` witnesses through the ordinary evaluator/executor path for interpreted values, protocol-extension defaults, and typed opaque host gateways. Exact same-source parity covers finite success, typed source failure, cooperative user-iterator cancellation, `break`/`continue`/`return` plus per-iteration and function-level `defer` cleanup, real source and host suspension, iterator state, terminal `nil`, host-operation ownership, and registry cleanup. `AsyncStream` and `AsyncThrowingStream` share runtime-owned suspension, cancellation, finish/failure, nonnegative buffering, copied-iterator, final-owner termination, escaped non-owning producer-handle, and complete cleanup evidence. Copied throwing-stream iterators share one pending-`next()` capability per stream; overlapping calls trap, with fatal semantics preserved across gateway source-location attachment. The current `withCheckedContinuation` slice owns delayed `resume(returning:)` values, zero-argument Void `resume()`, and nonthrowing Result success through `resume(with:)` in a bounded continuation registry for explicit `nil` and `MainActor.shared` isolation, records `waitingForContinuation`, runs the contextually isolated body on MainActor, restores the owner's required executor, distinguishes source cancellation from infrastructure abort, and drains every ownership edge. `withCheckedThrowingContinuation` shares that record for explicit-`nil` value resume and exact source-error projection through `resume(throwing:)`; its MainActor error path has exact body-isolation and caller-restoration evidence, and concrete-error plus existential-error Result success/failure through `resume(with:)` delegate to those same terminal transitions. Task-group iteration remains separate M4 evidence. | Extend checked continuations to omitted and arbitrary-source-actor isolation, double-resume and abandonment diagnostics, escaped-token lifetime, and then unsafe continuations. Negative stream capacities remain explicitly unsupported. |
| M7 compiler preflight | partial | The production interpreter now has explicit required and diagnostics-only compiler preflight, a bounded source/toolchain/SDK/target/gateway cache, registry-bound compiled host modules with separately fingerprinted compiler modes, a generated SDK re-export surface, multi-file project checking, pinned TaskGroup, Sendable, effectful-property, and imported-type-isolation diagnostics, compiler-backed fail-closed filtering of inactive `swiftinterface` conditional-compilation branches before declaration collection, generated active-SDK top-level/Task/selected-nominal/task-group plus nested group-iterator declaration metadata, typed synthetic top-level and receiver-qualified callable/property declarations, fail-closed synthetic nominal struct/class/enum declarations that preserve enclosing attributes, authored implementation/verification dispositions for all 36 currently generated Task instance/static rows including native-parity `Task.name` and all four `Task.immediate`/`Task.immediateDetached` declarations for their evidenced explicit-`nil`, inherited-MainActor subsets, both `withUnsafeCurrentTask` overloads and all nine `UnsafeCurrentTask` member rows, both deprecated public top-level `async(priority:operation:)` overloads for their evidenced inherited-MainActor subset, all four deprecated public top-level `asyncDetached`/`detach` overloads for their evidenced nonisolated subset, both public top-level withTaskCancellationHandler overloads, both macOS 26 task-priority-escalation handler declarations for their evidenced cooperative and explicit-`nil` subsets, the `withTaskExecutorPreference` declaration for its explicit-`nil`, no-ambient-custom-executor, bare-unqualified-direct-global-async-nil-operation-executor-preference-explicitly-nonisolated-operation subset, the `extractIsolation` declaration for synchronous non-invoking reflection of bare unqualified direct global async plain-explicit-nonisolated declarations including `@concurrent` while aliases, conversions, member references, and actor identity fail closed, all four public top-level task-group scope rows, plus seventy-seven task-group and iterator state, cancellation, wait, nextResult, spawn, async, add, canonical addTask, canonical addTaskUnlessCancelled, named add, executor-preference addTask, executor-preference addTaskUnlessCancelled, immediate add, asyncUnlessCancelled, spawnUnlessCancelled, makeAsyncIterator, next, and cancel rows, the public `withCheckedContinuation` declaration routed for its evidenced explicit-`nil` and MainActor value-resume plus explicit-`nil` Void-resume and nonthrowing Result-resume subsets, `withCheckedThrowingContinuation` routed for its explicit-`nil` value/error-resume plus MainActor error-resume and concrete-error plus existential-error Result-resume subsets, while the two public unsafe continuation entry points remain deferred, and exact exclusions for 26 compiler/runtime ABI top-level hooks with the distinct public job-testing hook deferred to M9. Current accounting is 171/171 reviewed: 51 runtime-supported, 20 diagnosed-unsupported, 71 known divergences, 26 excluded compiler ABI, three deferred, and zero unreviewed; generated adapter routing covers 125 declarations. | Target-aware project manifests are covered. Keep M7 partial while the generated inventory scope is explicitly incomplete and known-divergent or deferred declarations retain owned gap dispositions. |
| M8 SwiftUI lifecycle | partial | Retained synchronous host callbacks enter canonical runtime-owned tasks and preserve inline state mutation; nested detached/group execution has native parity. | Generate ordinary async modifier exposure and add reusable view-owned task identity, cancellation, and teardown semantics under the SwiftUI-magic rule. |
| M9 physical parallelism | deferred | The core remains cooperatively scheduled and main-actor hosted; no physical parallelism claim is made, and the source-callable _swift_createJobForTestingOnly hook is explicitly deferred with the executor-job runtime. | After M5, M7, and M8 stabilize ownership, add worker synchronization, Thread Sanitizer, and cooperative-versus-parallel semantic parity. |

## Committed native facts

| Case | Assertion | Native fact | Interpreter status |
|---|---|---|---|
| `async-function-exact` | exact | Awaiting the fixture function returns `ready` | Expected native parity |
| `async-try-await-conditional` | exact | A throwing async call remains awaited when its optional result is compared with `nil` as the condition of a ternary expression | Native/interpreter parity in 20 repetitions: `nil`; the fixture yields once inside the call but makes no scheduler-order claim |
| `host-gateway-suspension` | exact | Awaiting the controlled async wrapper suspends until its explicit gate opens, so a ready MainActor controller records progress before the wrapper returns | Native/interpreter parity in 20 repetitions: `before,host-enter,controller,host-exit,value`; the interpreted caller is `.waiting/.awaitingHost(operationID)` at the forced barrier and the operation registry is empty after completion |
| `host-callback-task-runtime` | exact | A synchronous MainActor callback exposes its inline mutation before returning, while an unstructured task it creates continues through Swift concurrency and may own structured group children | Native/interpreter parity in 20 repetitions: `started,done-3`; the interpreter fires the retained closure only after its initial evaluation has returned, enters `.hostCallback`, and finishes with empty task/group/scope registries |
| `main-actor-task-partial-order` | partial order | A newly created MainActor task does not execute inline; `sync` precedes both task events | Expected native parity through async-session drain policy; relative child order is not asserted |
| `concurrent-executor-hop` | exact | A `@concurrent nonisolated` async method leaves MainActor for entry and post-yield continuation, an awaited MainActor method runs on the main executor, and both direct and detached callers return to their prior executor afterward | Native/interpreter parity in 20 repetitions: `main\|worker:worker:main\|worker:worker:main\|main`; the interpreter models logical executor identity cooperatively and does not claim physical parallel execution |
| `actor-isolated-entry` | exact | An actor-isolated instance method sees its exact actor through `#isolation`, while an explicit `nonisolated` method sees no actor | Native/interpreter parity in 20 repetitions: `actor:none`; actor identity is logical and does not claim physical worker execution |
| `custom-global-actor-isolation` | exact | A function annotated with a user-defined global actor uses that declaration's canonical `static shared` actor identity, while an explicit `nonisolated` function sees none | Native/interpreter parity in 20 repetitions: `same:none`; declaration order and repeated resolution preserve the same runtime actor ID |
| `actor-arbitrary-global-actor-isolation` | exact | Struct- and enum-backed global actors whose `static shared` values have separate source-actor types expose those exact canonical actors through `#isolation`; a defaulted isolated existential selects and owns the same mailbox | Native/interpreter parity in 20 repetitions: `same:owned:same\|same:owned:same`; both nominal-symbol representations are covered without a physical-thread, independent-order, or arbitrary `@isolated(any)` task-operation claim |
| `actor-initialization` | exact | A synchronous actor initializer is lexically nonisolated, initializes actor-owned stored state without `await`, and the first externally awaited isolated method executes while owning that actor's executor | Native/interpreter parity in 20 repetitions: `none:owned:5`; the assertion covers initialization isolation, retained state, mailbox ownership, and cleanup without claiming a physical thread or unrelated message order |
| `actor-task-local-propagation` | exact | A task-local dynamic binding follows the calling task across an actor hop and remains visible after the actor-isolated method suspends and reacquires its executor | Native/interpreter parity in 20 repetitions: `default:owned\|bound:owned\|bound:owned>bound:owned\|default:owned`; the assertion covers task-local restoration, mailbox ownership, and cleanup without claiming FIFO, physical threads, or independent-message order |
| `actor-queued-message-cancellation` | exact | Cancelling a task whose cross-actor call already waits behind an occupied actor does not discard the call; after handoff the method owns the actor and observes the cancellation request | Native/interpreter parity in 20 repetitions: `requested\|released\|owned:cancelled`; controlled gate and MainActor run-to-suspension establish the queue/cancel edge without claiming FIFO among multiple waiters, physical threads, or automatic throwing behavior |
| `actor-serial-segment` | exact | Two concurrent calls to a synchronous actor-isolated method each own one mutually exclusive actor-executor segment and retain both mutations | Native/interpreter parity in 20 repetitions: `owned:owned:2`; the runtime records mailbox ownership explicitly and the assertion makes no FIFO, start-order, physical-thread, or cross-actor-parallelism claim |
| `actor-mailbox-stress` | stress invariant | Eight child tasks complete four actor-mailbox rounds with two post-barrier suspension/resume cycles per message; every message retains actor ownership and exactly one mutation, every child completes valid, and the terminal barrier is drained | Native/interpreter parity in 20 repetitions: `32:4:0:0:8`; a separate 64-seed interpreter board varies fanout, rounds, pre-entry yield, and resume-yield count while checking exact terminal counters and empty task/actor/group/scope/host-operation/scheduler registries; no FIFO, child order, physical-thread, or cross-actor-parallelism claim is made |
| `actor-computed-property` | exact | Each externally awaited synchronous actor computed-property getter owns the receiver actor for its complete accessor segment, explicit `nonisolated` does not enter it, and sequential isolated reads retain both mutations | Native/interpreter parity in 20 repetitions: `owned:1\|owned:2\|unowned\|2`; no FIFO between independent messages, physical-thread, or parallelism claim is made |
| `actor-computed-property-failure` | exact | A cross-actor awaited throwing computed getter owns the target actor until failure, releases it on throw, and restores the caller actor before catch handling and subsequent target work | Native/interpreter parity in 20 repetitions: `owned\|caught\|owned\|owned:owned:2\|owned`; no FIFO, physical-thread, or unrelated scheduling-order claim is made |
| `actor-computed-property-cancellation` | exact | A cancelled task reacquires an async-throwing computed getter's target actor before observing cancellation, then releases the target and restores the caller actor before catch handling and later target work | Native/interpreter parity in 20 repetitions: `owned\|cancelled\|owned\|owned:owned:owned:2\|owned`; explicit gates establish cancellation timing without a FIFO, physical-thread, or unrelated scheduling-order claim |
| `actor-computed-property-async-exits` | exact | After controlled suspension, an async-throwing computed getter reacquires its target actor before either returning a value or throwing a source error, then releases the target and restores the caller actor before subsequent source work | Native/interpreter parity in 20 repetitions: `owned\|value:1\|owned\|owned:owned:owned:2\|owned\|\|owned\|caught\|owned\|owned:owned:owned:2\|owned`; separate source-owned gates force both suspension edges, with no FIFO, physical-thread, or unrelated scheduling-order claim |
| `actor-computed-setter` | exact | A synchronous computed setter invoked from an actor-isolated method executes inside that method's actor-owned segment and may mutate actor-isolated storage | Native/interpreter parity in 20 repetitions: `owned:7\|owned:11`; external setter mutation is a separate compiler diagnostic, and no physical-thread or independent-message order is asserted |
| `actor-subscript-getter` | exact | Each externally awaited synchronous actor subscript getter owns the receiver actor for its complete accessor segment, while an explicit `nonisolated` subscript remains on the caller executor | Native/interpreter parity in 20 repetitions: `owned:1\|owned:3\|unowned\|3`; sequential awaits establish both mutations, with no setter, FIFO, physical-thread, or independent-message-order claim |
| `actor-subscript-cancellation` | exact | A cancelled task reacquires an async-throwing subscript getter's target actor before observing cancellation, then releases the target and restores the caller actor before catch handling and later target work | Native/interpreter parity in 20 repetitions: `owned\|cancelled\|owned\|owned:owned:owned:2\|owned`; explicit gates establish cancellation timing without a FIFO, physical-thread, or unrelated scheduling-order claim |
| `actor-subscript-async-exits` | exact | After controlled suspension, an async-throwing subscript getter reacquires its target actor before either returning a value or throwing a source error, then releases the target and restores the caller actor before subsequent source work | Native/interpreter parity in 20 repetitions: `owned\|value:1\|owned\|owned:owned:owned:2\|owned\|\|owned\|caught\|owned\|owned:owned:owned:2\|owned`; separate source-owned gates force both suspension edges, with no FIFO, physical-thread, or unrelated scheduling-order claim |
| `actor-subscript-setter` | exact | A synchronous actor subscript setter invoked from an actor-isolated method executes inside that method's actor-owned segment and may mutate actor-isolated storage | Native/interpreter parity in 20 repetitions: `owned:7\|owned:11`; external setter mutation is a separate compiler diagnostic, and no physical-thread or independent-message order is asserted |
| `actor-reentrancy` | exact | An async actor message owns its synchronous prefix, releases the actor at a controlled suspension so a second message can mutate isolated state, and reacquires the same actor before resuming | Native/interpreter parity in 20 repetitions: `owned:owned:interleaved:owned:3`; the gate establishes every asserted edge without a FIFO, task-start, physical-thread, or unrelated scheduling claim |
| `actor-cross-actor-failure` | exact | A cross-actor awaited throwing call runs inside the callee actor, releases that actor on failure, and restores the caller actor before catch handling and subsequent cross-actor work | Native/interpreter parity in 20 repetitions: `owned\|caught\|owned\|owned:owned:2\|owned`; no FIFO, physical-thread, or unrelated scheduling order is asserted |
| `actor-cross-actor-cancellation` | exact | A cancelled task reacquires the callee actor after controlled suspension before observing cancellation, then releases that actor and restores its caller actor before catch handling and subsequent cross-actor work | Native/interpreter parity in 20 repetitions: `owned\|cancelled\|owned\|owned:owned:owned:2\|owned`; explicit gates establish cancellation timing without a FIFO, physical-thread, or unrelated scheduling-order claim |
| `actor-isolated-parameter` | exact | A synchronous function with a required explicit source-actor `isolated` parameter selects that argument's executor before entry and may synchronously mutate its isolated storage | Native/interpreter parity in 20 repetitions: `owned:2\|owned:5\|5`; sequential awaited calls establish both mutations without a physical-thread or unrelated scheduling-order claim |
| `actor-isolated-parameter-defaults` | exact | A defaulted optional isolated parameter inherits a source actor from caller-lexical `#isolation`, an explicit source actor selects that actor, and explicit nil or a nil default from nonisolated code selects no actor | Native/interpreter parity in 20 repetitions: `owned:actor\|owned:actor\|unowned:none\|unowned:none`; the default value is materialized before executor selection and reused for binding, with no physical-thread or unrelated scheduling-order claim |
| `actor-isolated-parameter-mainactor-default` | exact | A default `#isolation` value in a MainActor caller is non-nil and selects MainActor, while explicit nil remains observably nil without forcing a synchronous caller-lane hop | Native/interpreter parity in 20 repetitions: `actor:main\|nil:main`; isolation-value presence and executor lane are asserted separately, without an arbitrary-global-actor, physical-worker, or unrelated scheduling-order claim |
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
| `task-group-named-add` | exact | All eight named `addTask`/`addTaskUnlessCancelled` overloads assign the supplied name to accepted children across ordinary, throwing, discarding, and throwing-discarding groups | Native/interpreter parity in 20 repetitions; every conditional add is accepted, scope exit joins the children, and sorted output avoids a scheduler-order assertion |
| `task-group-executor-preference-nil-add` | exact | All eight named and unnamed `addTask` executor-preference overloads across ordinary, throwing, discarding, and throwing-discarding groups accept an explicit `nil` preference, run their children, preserve optional task names, and join at scope exit | Native/interpreter parity in 20 repetitions: `discarding-named:discarding-name\|discarding-unnamed:nil\|ordinary-named:ordinary-name\|ordinary-unnamed:nil\|throwing-discarding-named:throwing-discarding-name\|throwing-discarding-unnamed:nil\|throwing-named:throwing-name\|throwing-unnamed:nil`; sorted output avoids a scheduling-order claim |
| `task-group-executor-preference-nil-add-unless-cancelled` | exact | All eight named and unnamed `addTaskUnlessCancelled` executor-preference overloads accept active explicit-`nil` calls, preserve optional child names, and reject post-`cancelAll` calls without child creation | Native/interpreter parity in 20 repetitions; decisions are `true,true,false,false` for every group kind, sorted child values avoid a scheduler-order claim, and no priority or physical-executor claim is made |
| `task-group-immediate-add` | partial order | Across ordinary, throwing, discarding, and throwing-discarding groups, every `addImmediateTask` and active `addImmediateTaskUnlessCancelled` operation starts synchronously on its inherited actor before the adding call returns; after its forced suspension the caller advances, active conditional calls return `true`, and post-cancellation conditional calls return `false` without child creation. An unconditional child added after `cancelAll()` observes `Task.isCancelled == true` and `Task.checkCancellation()` in its synchronous prefix and remains cancelled after resumption; `Task.name` is installed before entry, and scope exit joins every accepted child | Native/interpreter parity in 20 repetitions; the assertion checks the causal `start < after < finish` edges, active/post-cancel conditional decisions, and `cancelled-prefix:true < check:caught < after < resumed:true`, but deliberately leaves independent-child finish order unspecified |
| `task-immediate` | partial order | Both throwing and nonthrowing `Task.immediate` and `Task.immediateDetached` synchronously enter a same-actor operation before construction returns, suspend at a real await, and preserve names, explicit priorities, values, and exact source failures; ordinary immediate tasks inherit task-local context while immediate-detached tasks clear it | Native/interpreter parity in 20 repetitions; each operation satisfies `start < after < finish`, ordinary rows observe the parent task-local value, detached rows observe its default, and finish order between independent tasks is deliberately unspecified; focused runtime inspection separately pins creator versus parentless lineage |
| `task-name` | exact | `Task.name` is the immutable optional name supplied at ordinary, detached, or task-group child creation; omitted and explicit-`nil` names do not inherit and an empty string remains distinct from `nil` | Native/interpreter parity in 20 repetitions: `nil\|ordinary\|optional\|nil\|parent/nil\|detached\|empty\|group,nil`; awaited handles and sorted group values avoid any scheduler-order assertion |
| `top-level-async` | exact | Both deprecated global `async(priority:operation:)` overloads create ordinary unstructured task handles; the operation may outlive its creating function and projects success or source failure | Native/interpreter parity in 20 repetitions: `value:nil\|17\|boom`; an explicit MainActor gate records utility priority before handle-await donation, and no sibling start order is asserted |
| `top-level-detached-aliases` | exact | Both overloads of the deprecated global `asyncDetached` and `detach` spellings create detached task handles with cleared task-local storage, unnamed task metadata, explicit priorities, successful values, and source failures in the supported nonisolated subset | Native/interpreter parity in 20 repetitions: `asyncDetached:nil:17:default\|detach:nil:9:default\|asyncDetached-boom\|detach-boom`; both children record entry before release, so handle-await donation and scheduler order are outside the observation |
| `task-priority-inheritance` | exact | An explicit `.utility` task sees raw priority 17, its unstructured child inherits 17, and a detached task without an explicit priority starts at `.medium`/21 | Native/interpreter parity in 20 repetitions: `17,17,21`; values are captured before any higher-priority handle await can cause escalation |
| `task-priority-escalation` | exact | A high-priority value waiter escalates an already-running background task, and a child created afterward inherits the effective priority | Native/interpreter parity in 20 repetitions: `9,25,25`; MainActor barriers put the reads and child creation after waiter registration without asserting scheduler order |
| `task-priority-transitive-escalation` | exact | Priority donation propagates through an awaited task that is itself awaiting another task | Native/interpreter parity in 20 repetitions: `9,25,25`; the utility middle and background bottom tasks both observe high priority |
| `with-task-executor-preference-nil` | exact | With no ambient custom `TaskExecutor`, explicit nil executor and isolation arguments run a plain explicitly nonisolated operation function in the same task; identity, native high-priority value, name, task locals, cancellation, success, and exact source failure survive suspension and scope exit | Native/interpreter parity in 20 repetitions: `success:true:preference-success:25:bound:false:true:preference-success:25:bound:false\|error:true\|cancel:false:false:true:preference-cancel:true`; the current adapter additionally requires a bare unqualified operation reference with no declaration-level executor preference, so `@concurrent`, aliases/conversions, qualified/parenthesized references, and broader isolation shapes fail closed |
| `extract-isolation-nonisolated` | exact | `extractIsolation` returns nil for both supplied bare unqualified direct global async functions with plain explicit `nonisolated` declarations, including the `@concurrent` form, without invoking either function | Native/interpreter parity in 20 repetitions: `plain:true\|concurrent:true`; focused tests additionally pin no retained task/scope/group/scheduler ownership and fail-closed rejection of qualified/parenthesized references, aliases, conversions, member references, synchronous functions, closure expressions, and unsupported isolation kinds |
| `continuation-entry-points` | exact native characterization | All four public checked/unsafe continuation entry points accept explicit `MainActor.shared` isolation from a nonisolated caller; each inline body runs on MainActor and a one-shot resume returns its exact value | Native 20/20: `checked:11\|checkedThrowing:22\|unsafe:33\|unsafeThrowing:44`; checked nonthrowing and checked throwing subsets now have separate runtime parity below, while both unsafe entry points remain deferred |
| `checked-continuation-value-resume` | exact | With explicit `isolation: nil`, a checked continuation parked by one source task returns the exact value supplied through `resume(returning:)` by a detached producer after that producer yields | Native/interpreter parity in 20 repetitions: `41`; focused evidence observes one runtime-owned `waitingForContinuation` suspension, required-executor restoration, bounded continuation ownership, infrastructure-abort cleanup, and empty continuation/task/scope/group/stream/host-operation/scheduler registries; canonical native digest `cdc0e05905b13ba3a3ef5a18fbefc271aedd047a639102d2b4ef965cc4f8c1a7` |
| `checked-continuation-mainactor-resume` | exact | From a `@concurrent` nonisolated caller, explicit `MainActor.shared` isolation runs the synchronous continuation body on MainActor, then a causally delayed detached producer resume returns the caller to its cooperative executor | Native/interpreter parity in 20 repetitions: `worker\|main\|worker`; the task-value gate forces producer suspension without asserting ready-task order or its physical thread, focused evidence pins the continuation owner's cooperative required executor and the arbitrary-source-actor fail-closed boundary, and the canonical native digest is `610836ddc2aae4c485bd191467c390be96963743f86f353e6021d5790f655177` |
| `checked-throwing-continuation-value-error` | exact | Two sequential checked throwing continuations return the exact value supplied through `resume(returning:)`, then project the original source enum value supplied through `resume(throwing:)` into its matching catch | Native/interpreter parity in 20 repetitions: `value:23\|error:failed`; each detached producer yields before its own resume, sequential awaits establish value-before-error without asserting producer scheduling or physical threads, focused evidence observes two canonical suspensions and complete registry cleanup, and the canonical native digest is `8b442dc2a3797ac2fad8592e65f585685487b6df933119da1c8aaa66d74af594` |
| `checked-throwing-continuation-mainactor-error` | exact | From a `@concurrent` nonisolated caller, explicit `MainActor.shared` isolation runs the checked-throwing continuation body on MainActor and a delayed source-error resume restores the caller executor before matching catch | Native/interpreter parity in 20 repetitions: `worker\|main\|worker`; this was already-GREEN characterization, the task-value gate supplies causal delay without asserting producer scheduling or physical threads, focused evidence pins the cooperative required executor, exact catch lane, one canonical suspension, and complete cleanup, and the canonical native digest is `cf35e0f2fff2d29dd27a7b7b026bc52ecd705ce15e72919ac8fc24ae7d3b17fe` |
| `checked-throwing-continuation-result-resume` | exact | A checked throwing continuation maps a concrete `Result` success to its exact value and a concrete `Result` failure to its original source enum error through `resume(with:)` | Native/interpreter parity in 20 repetitions: `value:29\|error:failed`; sequential awaits establish value-before-error without asserting producer scheduling or physical threads, focused evidence observes two canonical suspensions and complete registry cleanup, compiler preflight rejects non-Result arguments, and the canonical native digest is `6400bcdc43bd6c03163fe44074b7e214559b9b36dbabb3a06017c268cb703c4e` |
| `checked-continuation-void-resume` | exact | A checked continuation with `Void` success resumes through the zero-argument `resume()` convenience and returns control to its awaiting owner | Native/interpreter parity in 20 repetitions: `void-resumed`; the detached producer yields before resume without making a ready-task, physical-thread, or parallelism claim, focused evidence observes one canonical suspension and complete registry cleanup, and the canonical native digest is `787b866a2ea70c81974998a32cc97636dd4069480fa4f301a357a20e16b1a14a` |
| `protocol-async-sequence-iteration` | exact | `for await` obtains a user-defined `AsyncSequence` iterator and repeatedly awaits its mutating `next()` until `nil`; a real suspension inside `next()` neither duplicates nor skips elements | Native/interpreter parity in 20 repetitions: `3:6`; the count and commutative sum avoid scheduler-order claims, and focused evidence proves iterator value-state copy-out plus empty task/scope/group registries |
| `protocol-async-sequence-throwing` | exact | A typed source error thrown by mutating `AsyncIterator.next()` after two suspending successes terminates `for try await` without delivering a third element and reaches its case-specific outer catch unchanged | Native/interpreter parity in 20 repetitions: `2:3:caught`; this was characterization of the general witness path, so no production change was required |
| `protocol-async-sequence-cancellation` | exact | Cancelling a task while a user `AsyncIterator.next()` is suspended does not itself terminate `for await`; the resumed iterator observes the request, may return an element, and the task may complete successfully while remaining marked cancelled | Native/interpreter parity in 20 repetitions: `1:7:true:true`; a MainActor gate fixes entry-before-cancel-before-resume without asserting unrelated task order, and this was characterization requiring no production change |
| `protocol-async-sequence-early-exit` | exact | `break` stops a protocol `for await` before another `next()` request, and the current iteration's `defer` runs before post-loop code just like the prior normally completed iteration | Native/interpreter parity in 20 repetitions: `12:2:next-1,defer-1,next-2,defer-2,after`; the iterator has no terminal `nil`, each `next()` really suspends, and this was characterization requiring no production change |
| `protocol-async-sequence-return-continue` | exact | `continue` runs the current iteration's `defer` before requesting the next element; `return` stops requests, unwinds the current body and enclosing function defers, then resumes the caller | Native/interpreter parity in 20 repetitions: `returned-3:3:next-1,continue-1,defer-1,next-2,body-2,defer-2,next-3,return-3,defer-3,consumer-defer,after`; the iterator has no terminal `nil`, every `next()` suspends, and this was characterization requiring no production change |
| `protocol-async-sequence-default-witnesses` | exact | Refining-protocol extensions provide both `makeAsyncIterator()` and mutating async `next()` defaults; concrete conformers declare only associated types and state, while `for await` dispatches the defaults through suspension to terminal `nil` | Native/interpreter parity in 20 repetitions: `3:6`; the successful default `next()` suspends on every element, preserves value-state copy-out, and this was characterization requiring no production change |
| `host-bridged-async-sequence` | exact | `for await` consumes an opaque SDK-owned host sequence through typed `makeAsyncIterator()` and suspending `next()` gateway contracts until the host returns terminal `nil` | Native/interpreter parity in 20 repetitions: `3:12`; all four interpreted `next()` calls own runtime-tracked host operations, and completion leaves host-operation/task/scope/group registries empty |
| `async-stream-suspended-consumer` | exact | An unbounded `AsyncStream` consumer that reaches an empty stream suspends until a producer yields two values, then terminates at `nil` after `finish()` | Native/interpreter parity in 20 repetitions: `2:6`; focused evidence observes a runtime-owned stream suspension and complete stream/task/scope/group/host-operation/scheduler cleanup; unsupported buffering policies fail closed |
| `async-stream-cancelled-consumer` | exact | Cancelling a task parked in empty-stream `next()` invokes `onTermination(.cancelled)` synchronously before resuming that `next()` with `nil`; the task can return normally while remaining marked cancelled | Native/interpreter parity in 20 repetitions: `true:true:cancelled:cancelled`; runtime stream wait, cancellation-handler, stream record, task, and scheduler ownership all drain |
| `async-stream-finish-termination` | exact | `finish()` synchronously invokes one `.finished` callback before returning, preserves buffered elements, makes repeated terminal reads return `nil`, ignores repeated finish, and makes later yield return `.terminated` | Native/interpreter parity in 20 repetitions: `3:true:true:finished,after-finish:terminated`; no production change was required |
| `async-stream-multiple-consumers` | exact | Two independent iterators may park concurrently on one empty stream, and one `finish()` resumes both with terminal `nil` | Native/interpreter parity in 20 repetitions: `true:true:2`; focused evidence observes at least two stream suspensions and complete ownership cleanup; no consumer resume order is claimed |
| `async-stream-copied-iterators` | exact | Value copies of one iterator own independent mutating-`next` access while sharing stream storage, so both may park and receive distinct yielded elements | Native/interpreter parity in 20 repetitions: `4:6:2`; a generic `HostValueSemantic` copy boundary replaces the erroneous shared mutable carrier; result assignment and resume order are not claimed |
| `async-stream-scope-termination` | exact | Releasing the last unfinished sequence/iterator owner at nested-function exit synchronously invokes `onTermination(.cancelled)` before the caller reads callback-owned state | Native/interpreter parity in 20 repetitions: `cancelled`; storage deinit now owns the implicit cancellation edge, closes the runtime record, and defers impossible nonthrowing-callback failures to the next evaluator safe point instead of swallowing them |
| `async-stream-escaped-continuation-lifetime` | exact | An escaped producer continuation does not retain unfinished stream storage: sequence scope exit invokes `.cancelled`, later yield returns `.terminated`, and releasing the handle is inert | Native/interpreter parity in 20 repetitions: `cancelled:terminated:cancelled`; the continuation carrier is now a non-owning handle while sequence and iterator carriers own storage |
| `async-stream-buffering-newest` | exact | `.bufferingNewest(2)` retains the two newest unconsumed elements; successful yields report decreasing remaining capacity, later yields report the oldest displaced element, and iteration drains only `3`, `4`, then `nil` | Native/interpreter parity in 20 repetitions: `enqueued(remaining: 1)|enqueued(remaining: 0)|dropped(1)|dropped(2)=>3,4,true`; focused evidence observes no consumer suspension and complete ownership cleanup |
| `async-stream-buffering-oldest` | exact | `.bufferingOldest(2)` retains the first two unconsumed elements; successful yields report decreasing remaining capacity, later yields report the newly rejected element, and iteration drains only `1`, `2`, then `nil` | Native/interpreter parity in 20 repetitions: `enqueued(remaining: 1)|enqueued(remaining: 0)|dropped(3)|dropped(4)=>1,2,true`; focused evidence observes no consumer suspension and complete ownership cleanup |
| `async-stream-zero-capacity` | exact | `.bufferingNewest(0)` and `.bufferingOldest(0)` retain no unconsumed value; each yield reports the supplied element as dropped, and the first post-finish iterator read is `nil` | Native/interpreter parity in 20 repetitions: `newest:dropped(1):true|oldest:dropped(2):true`; focused evidence observes two stream records, no consumer suspension, and complete ownership cleanup |
| `async-throwing-stream-suspended-failure` | exact | An empty unbounded `AsyncThrowingStream` consumer suspends, receives one yielded value, then observes the exact source error passed to `finish(throwing:)` after that value drains | Native/interpreter parity in 20 repetitions: `1:2:caught`; the shared stream record owns the suspension and source-error terminal outcome, then every runtime registry drains |
| `async-throwing-stream-finish-termination` | exact | Normal `finish()` synchronously invokes one `.finished(nil)` callback before returning, preserves a buffered value, makes repeated terminal reads `nil`, and makes a later yield `.terminated` | Native/interpreter parity in 20 repetitions: `3:true:true:finished(nil),after-finish:terminated`; focused evidence observes no consumer suspension and complete ownership cleanup |
| `async-throwing-stream-failure-termination` | exact | `finish(throwing:)` synchronously invokes one `.finished(error)` callback containing the supplied source error before returning, preserves a buffered value, rethrows that error next, and terminates later yields | Native/interpreter parity in 20 repetitions: `5:caught:finished-error,after-finish:terminated`; focused evidence observes no consumer suspension and complete ownership cleanup |
| `async-throwing-stream-cancelled-consumer` | exact | Cancelling a task parked in empty throwing-stream `next()` synchronously invokes `onTermination(.cancelled)` before that call returns `nil`; the task may return normally while remaining marked cancelled | Native/interpreter parity in 20 repetitions: `true:true:cancelled:cancelled`; focused evidence observes one stream suspension and complete ownership cleanup |
| `async-throwing-stream-buffering-newest` | exact | `.bufferingNewest(2)` retains the newest two unconsumed elements; successful yields report decreasing remaining capacity, later yields return the oldest displaced element, and iteration drains only `3`, `4`, then `nil` | Native/interpreter parity in 20 repetitions: `enqueued(remaining: 1)|enqueued(remaining: 0)|dropped(1)|dropped(2)=>3,4,true`; focused evidence observes no consumer suspension and complete ownership cleanup |
| `async-throwing-stream-buffering-oldest` | exact | `.bufferingOldest(2)` retains the first two unconsumed elements; successful yields report decreasing remaining capacity, later yields return the newly rejected element, and iteration drains only `1`, `2`, then `nil` | Native/interpreter parity in 20 repetitions: `enqueued(remaining: 1)|enqueued(remaining: 0)|dropped(3)|dropped(4)=>1,2,true`; focused evidence observes no consumer suspension and complete ownership cleanup |
| `async-throwing-stream-zero-capacity` | exact | `.bufferingNewest(0)` and `.bufferingOldest(0)` retain no unconsumed element; each yield returns the supplied element as dropped, and the first post-finish read is `nil` | Native/interpreter parity in 20 repetitions: `newest:dropped(1):true|oldest:dropped(2):true`; focused evidence observes two stream records, no consumer suspension, and complete ownership cleanup |
| `async-throwing-stream-copied-iterators` | runtime trap | Once one copied iterator has suspended in `next()`, invoking `next()` through another copy of the same throwing-stream iterator traps with `attempt to await next() on more than one task` | Native/interpreter process-isolated trap parity in 20 repetitions; `Task.immediate` establishes the first suspension causally, each side must exit nonzero with its owned diagnostic fragment, timeout is never accepted as a trap, and the canonical normalized native digest is `cab2a56c7fb9ca7135a95cc59a16b937f0a71d903ac195d2c7c79892126dea01` |
| `async-throwing-stream-scope-termination` | exact | Releasing the last unfinished throwing-stream sequence/iterator owner at nested-function exit synchronously invokes `onTermination(.cancelled)` before the caller reads callback-owned state | Native/interpreter parity in 20 repetitions: `cancelled`; the shared flavor-aware storage deinit now supplies the throwing termination value, preserves impossible callback failures for the next safe point, closes its record, and leaves every runtime registry empty; canonical native digest `165b1dc6bc0549403e963d0309882cc678f0ef9ff759b898171790b9d9641cc1` |
| `async-throwing-stream-escaped-continuation-lifetime` | exact | An escaped throwing producer continuation does not retain unfinished stream storage: sequence release invokes `.cancelled`, later yield returns `.terminated`, and releasing the handle is inert | Native/interpreter parity in 20 repetitions: `cancelled:terminated:cancelled`; already-GREEN characterization of the shared weak producer carrier, with one stream, no consumer suspension, complete cleanup, and canonical native digest `37ca395c9da690fb5efa6fba8dfec52ec9ee6ddce65ce54e759749b1a8932bb2` |
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

The active SDK `_Concurrency.swiftinterface` supplies the semantic
algorithm rather than leaving it to observed scheduling: throwing
`waitForAll` repeatedly consumes completion-ordered `next()` results, retains
only the first caught error, continues until the group is empty, and then
rethrows that retained error. The original twenty bounded strict-concurrency
native runs all produced `caught-second:drained`, but observation alone did not
prove that alternative. The fixture now withholds the first child's gate until
the second child records completion immediately before throwing. The exact
assertion therefore proves `caught-second:drained` without promoting an
uncontrolled scheduler order or permitting an unobserved interpreter result.

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

The original allowed-set differential case was GREEN in all 20 repetitions.
Its historical combined targeted run passed 73/73 tests across
`AsyncExecutionTests` (53),
`HostSignatureTests` (12), and `ConcurrencyParityTests` (8), with 63 runtime
fixtures. The full shared-worktree run passes 790 tests in 150 suites; one test
and its suite come from a preserved unrelated untracked corpus-sweep file, so
this tracked repository step accounts for 789 tests in 149 suites.

The 2026-07-15 methodology hardening makes the same case exact through the
added completion barrier. A fresh-process focused shard passed all 20 native
and 20 interpreted repetitions as `caught-second:drained` and emitted a
selected/completed receipt plus its native-observation digest for exactly this
case.
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

### Source actor identity and isolated entry

The first actor-runtime sub-slice asks one narrow semantic question before
adding mailbox scheduling: does dynamic `#isolation` identify a source actor
inside an actor-isolated instance method, and does an explicit `nonisolated`
method observe no actor isolation? The same-source fixture
`actor-isolated-entry.swift` returned `actor:none` in all 20 strict Swift 6.3.3
runs. Before the runtime change the interpreter was RED as `none:none` in all
20 repetitions because actor declarations had been erased to class-like
symbols and their methods inherited the caller executor.

Actor declarations now retain their nominal actor kind. Allocation assigns
each source actor instance a distinct `RuntimeActorID` and registers a
non-owning runtime record, so executor metadata cannot extend source lifetime.
Final source release removes that record. Instance-method closure formation
uses the captured actor identity to select the matching logical actor executor
unless the declaration is explicitly `nonisolated`; ordinary call dispatch
then reuses the existing dynamic-extent hop and caller-restoration mechanism.

The differential fixture is GREEN as `actor:none` in all 20 repetitions, and
the focused ownership test proves distinct IDs, no ID for an ordinary class,
record-to-instance identity, and zero active actor records after final release.
That sub-slice deliberately made no claim of actor storage isolation, a serial
mailbox, reentrancy, user-defined global actors, or physical parallelism. The
next record adds only the global-actor identity mapping; storage, mailboxes,
reentrancy, and physical execution remain open.

### Canonical user-declared global-actor isolation

`custom-global-actor-isolation.swift` asks whether a function annotated with a
source `@globalActor` declaration executes under that declaration's exact
`static shared` actor identity, while an explicit `nonisolated` function sees
no actor isolation. Twenty bounded strict Swift 6.3.3 runs returned
`same:none`. Before the runtime change, the same interpreted source was RED as
`none:none` in all 20 repetitions because the declaration collector retained
the global-actor type but discarded its use as function isolation metadata.

Function closures now retain attribute type candidates independently of
declaration order. At invocation, the interpreter accepts only a collected
type actually marked `@globalActor`, lazily evaluates its canonical `shared`
member, requires that value to be a source actor instance, and installs that
instance's `RuntimeActorID` through the ordinary executor-hop and caller-
restoration path. Static storage supplies stable shared identity; arbitrary
attributes and unknown external actors are not reclassified.

The exact differential is GREEN as `same:none` in all 20 repetitions. A
focused runtime test proves repeated resolution returns the same shared actor
ID and record. This closes custom global-actor identity mapping only; it does
not claim actor-owned storage checks, mailbox serialization, reentrancy, or
physical worker execution.

### Actor mailbox, controlled reentrancy, and stored-property confinement

The next native question is deliberately smaller than full actor reentrancy:
does each concurrent call to a synchronous actor-isolated method own one
mutually exclusive actor executor segment, so both calls observe actor
ownership and both mutations survive? `actor-serial-segment.swift` creates two
`async let` calls to one counter. A native helper receives an
`isolated (any Actor)? = #isolation` default and compares identity without
observing scheduler order. Twenty strict Apple Swift 6.3.3 runs returned
`owned:owned:2` exactly.

The pre-fix interpreter was RED in all 20 repetitions as `unowned:unowned:2`
with native-observation digest
`b4ba0db5d46be94eaf313c140dbfc871202ca09803fc8336628020dab1a08073`.
The final value happened to be two only because the entire evaluator is
physically MainActor-hosted. That accidental serialization did not establish
source-actor ownership and therefore was not accepted as parity.

Each `RuntimeActorRecord` now owns a depth-counted source-task lease and a
bounded waiter mailbox. A synchronous actor-function call acquires the lease
before changing logical executor. A competing task transitions to
`.waiting/.waitingForActor(actorID)` and suspends on a checked continuation;
release either clears the lease or transfers it directly to one waiter before
resuming that task. Actor and task teardown assert that no owner or queued edge
survives. FIFO is only the deterministic internal handoff policy and is not a
source semantic claim.

Stored-property metadata now preserves `var` versus `let` and explicit
`nonisolated` provenance. Common instance-property read, write, and projection
funnels require a matching logical actor plus the canonical runtime task's
lease for mutable isolated storage. Separate real Swift 6 compiler probes
established that an ordinary immutable actor `let` and an explicit
`nonisolated` property are directly readable, while a mutable isolated `var`
is rejected outside the actor; the runtime guard follows that distinction.
Cross-actor synchronous calls in canonical async sessions also fail closed
unless the source task owns the actor.

The same-source differential is GREEN as `owned:owned:2` in all 20 repetitions
with the unchanged native digest. White-box coverage proves queue suspension,
ownership handoff, state restoration, complete task/actor edge cleanup, the
mutable-storage rejection, and the immutable/nonisolated exceptions.

The next semantic question is actor reentrancy across a causally controlled
suspension. `actor-reentrancy.swift` starts one async actor message, waits until
that message has written `1` and entered a host gate, completes a second actor
message that writes `2`, then opens the gate. The first message must observe
the interleaved mutation, regain ownership before touching actor state, and
write `3`. Twenty bounded strict Apple Swift 6.3.3 runs returned exactly
`owned:owned:interleaved:owned:3`. The gate establishes every compared edge;
FIFO, child start order, physical thread, and unrelated ready-task order remain
unasserted.

Before the production change, the same interpreted source was captured as
`unowned:unowned:interleaved:owned:3`: the compatibility frame happened to
permit interleaving but supplied no mailbox ownership before or after the
wait. A `RuntimeTaskSuspensionLease` now pairs every canonical task-state wait
with the complete depth-counted actor segment owned by that task. Host, task-
value/async-let, clock/yield, and task-group waits release that segment only
after recording the task as waiting; wake-up restores the task to runnable,
queues it on the actor when necessary, and returns to the evaluator only after
the same nested depth is owned again. Explicit cross-executor calls similarly
park their caller actor before acquiring a different callee executor. Async
actor functions therefore use the same mailbox ownership as synchronous ones;
the unowned compatibility frame has been removed.

The promoted fresh-process differential is GREEN as
`owned:owned:interleaved:owned:3` in 20 repetitions, with native-observation
digest `3124ca05275c1a09307543bdc5d023a28b82566675ad9ac279e9f4ea49e8436f`.
A focused runtime test additionally proves
that a nested depth-two segment becomes completely unowned during suspension,
is restored before continuation, unwinds one lease at a time, and leaves no
task or actor edge. The post-fix board passed `ActorRuntimeTests` 5/5,
`AsyncExecutionTests` 86/86, host suspension 1/1, SwiftUI actor execution 2/2,
TaskObservatory 1/1, and methodology/accounting 38/38. The three neighboring
actor parity cases stayed GREEN in parallel, and FoodTruck `socialFeed` plus
`salesHistory` each passed 1/1. The full milestone gate remains deferred while
M5 is open.

This closes the successful controlled-reentrancy gap, not M5:
cross-actor hop parity, computed-property setter/subscript confinement, isolated
parameters, arbitrary global actors, failure/cancellation paths, and replayable
mailbox stress remain open. No physical parallelism is claimed.

### Actor computed-property getter confinement

The next entry-slice question is whether an externally awaited synchronous
computed-property getter executes as an actor-owned segment rather than as an
ordinary eager member read. `actor-computed-property.swift` performs two
sequential `await counter.next` reads. Each getter compares `#isolation` with
its receiver before mutating isolated storage, and the final actor method reads
the retained value. Twenty bounded strict Apple Swift 6.3.3 executions returned
`owned:1|owned:2|unowned|2` exactly. The third field comes from a direct
explicitly `nonisolated` computed getter and therefore characterizes the
absence of actor entry. Sequential awaits establish both isolated mutations;
the fixture makes no FIFO claim between independent messages and no
physical-thread or parallelism claim.

This was a gap closure. The temporary native-RED registration reproduced the
isolated-getter result against interpreter `unowned|unowned|0` before the
nonisolated characterization field was added: the async member path
forced the syntax through `accessMember`, but the computed-property body then
ran directly through the synchronous evaluator without acquiring or installing
the receiver's actor executor.

Computed-property declarations now retain explicit `nonisolated` metadata.
For a source actor receiver, the async member path resolves the exact runtime
actor ID, parks a different caller actor when necessary, acquires the ordinary
depth-counted mailbox lease, and executes the accessor through one computed-
getter context. That context installs the logical executor and lexical
executor extent, requires the canonical task to own the actor, and restores all
state on success or failure. An unawaited dynamic getter therefore fails closed,
while an explicitly nonisolated computed property remains directly readable.
The existing setter funnel is deliberately unchanged; setter parity is not
claimed by this getter fixture.

After the production change the native-RED regression deliberately reported
that the gap was no longer RED, and the case was promoted to the positive board.
Fresh-process native/interpreter execution is GREEN in all 20 repetitions with
native-observation digest
`0301f4f1e20316840431c3e55db31c4cabb8c7d37dbaea92fa99d94b8bdfc84f`.
Focused runtime coverage additionally proves two owned reads, isolated storage
mutation, explicit-nonisolated metadata, fail-closed unawaited entry, and empty
task/actor registries after local lifetime exit.

The final targeted gate passes `ActorRuntimeTests` 6/6,
`AsyncExecutionTests` 86/86, computed/value/language semantics 125/125,
`HostSignatureTests` 16/16, SwiftUI actor execution 2/2, TaskObservatory 1/1,
and methodology/accounting 38/38. Neighboring actor serial/reentrancy shards
remain GREEN in 20 repetitions, and FoodTruck `socialFeed` plus `salesHistory`
each pass 1/1. The full milestone gate remains deferred while M5 is open.

This closes synchronous actor computed-getter entry only. Computed setter and
subscript parity, actor failure/cancellation exits, replayable mailbox stress,
and the later isolated-dispatch slice remain open.

### Actor computed-property setter confinement

The next entry-slice question separates legal setter execution from an illegal
cross-actor mutation. `actor-computed-setter.swift` invokes a synchronous
computed setter from an actor-isolated method twice. Each setter records the
current isolation before mutating actor storage. Twenty bounded Apple Swift
6.3.3 executions under Swift 6 complete strict concurrency returned
`owned:7|owned:11` exactly. The sequential awaited method calls establish both
assignments; the fixture does not claim an external setter hop, physical-thread
behavior, or ordering between independent actor messages.

The separate `actor-computed-setter-diagnostic.swift` fixture establishes why
no external setter hop may be implemented: real Swift rejects
`await counter.value = 1` with an actor-isolated-property mutation diagnostic
at line 9 and additionally reports that the `await` contains no async
operation. The production compiler preflight rejects the same source before
declaration collection or runtime mutation. The focused runtime negative
control omits only that semantically inert `await` so it can exercise the
dynamic bypass directly.

This was a gap closure at the runtime safety boundary. Before the production
change, the legal same-source case was already GREEN as a characterization,
because its enclosing actor method owned the mailbox, but an external dynamic
assignment executed an empty setter without any actor ownership. The RED
focused test reported `actor computed setter executed without executor
ownership`.

All instance computed setters now execute through the same computed-accessor
context as getters. The shared path restores lexical ownership and logical
executor state on every exit and, for an actor receiver, requires the current
source task to already own the matching mailbox lease. It deliberately does
not acquire a lease or synthesize an external setter hop. Initializer and
explicit synchronous compatibility remain governed by the existing accessor
entry rules; required compiler preflight remains the source-language boundary.

Post-fix native/interpreter parity is GREEN in all 20 repetitions with
native-observation digest
`75e8b66f905ebc5b86b85b9adabca1c63e3cb14b94b23cbc474efe75469faca1`.
Focused runtime evidence proves `owned:7`, fail-closed external dynamic entry,
and empty task/actor registries. The final incremental test build took 6.44
seconds. A read-only prebuilt-bundle board then ran in parallel and completed
in 23.21 seconds: 199 actor/async/host/value tests, four compiler/preflight/
diagnostic/matrix tests, four SwiftUI actor/TaskObservatory/binding tests, the
twenty exact setter repetitions, and all nine FoodTruck rungs passed. The full
milestone gate remains deferred while M5 is open.

This closes computed-setter confinement only. Actor subscript confinement,
failure/cancellation exits, replayable mailbox stress, and the later
isolated-dispatch slice remain open.

### Actor subscript-getter confinement

The next entry slice asks whether subscript access follows the same isolation
boundary as a computed-property getter. `actor-subscript-getter.swift` performs
two sequential external `await counter[index]` reads. The synchronous getter
checks that its complete accessor body owns the receiver actor before mutating
isolated storage. An explicitly `nonisolated` two-index subscript checks the
opposite boundary. Twenty bounded Apple Swift 6.3.3 executions under Swift 6
complete strict concurrency returned `owned:1|owned:3|unowned|3` exactly. The
fixture establishes neither actor-subscript setter behavior nor scheduler or
physical-thread ordering.

Before the production change, the same-source parity test was RED in all 20
repetitions: the interpreter returned `unowned|unowned|unowned|0` while native
Swift returned the exact value above. `await` had no suspending subscript path,
and collected subscript metadata did not retain isolation or lexical-owner
identity, so the eager member dispatcher ran both isolated getters on the
caller executor.

Subscript members now retain explicit-`nonisolated` and lexical-declaration
metadata. A forced awaited subscript evaluates its base exactly once and its
indices before the hop, resolves actor isolation from the receiver, acquires
the canonical mailbox lease, and executes the getter through the common
accessor context. The context restores lexical and logical executor state on
all exits and requires matching actor ownership. The nonisolated route keeps
the existing eager semantics on the caller executor. No fixture or subscript
name is recognized by the implementation.

Post-fix native/interpreter parity is GREEN in all 20 repetitions with
native-observation digest
`c4296765959e48d30f02b7b542f25d36e51eabd8f1697b068f867ee543e893c4`.
Focused runtime evidence additionally proves collected isolation metadata,
owned getter mutation, caller-executor nonisolated execution, fail-closed
unawaited entry, and empty task/actor registries after completion.

The final incremental `--build-tests` build took 1.11 seconds. A read-only
prebuilt-bundle board then completed in 22.72 seconds: 225 actor/async/host/
value/language tests, four SwiftUI actor/TaskObservatory/subscript tests, the
twenty exact subscript-getter repetitions, and all nine FoodTruck rungs passed.
After synchronizing one literal ledger phrase, the full 38-test methodology
suite and the neighboring computed-getter, computed-setter, and actor-
reentrancy cases all passed concurrently in 12.56 seconds, with 20 exact
native/interpreter repetitions per neighboring case. The full milestone gate
remains deferred while M5 is open.

This closes actor subscript-getter entry. The setter boundary is established
separately below; failure/cancellation exits, replayable mailbox stress, and
the later isolated-dispatch slice remain open.

### Actor subscript-setter confinement

The setter slice separates legal execution inside an actor message from an
illegal external mutation. `actor-subscript-setter.swift` assigns through a
synchronous subscript twice from an actor-isolated method. Each setter records
the current actor isolation before mutating storage. Twenty bounded Apple Swift
6.3.3 executions under Swift 6 complete strict concurrency returned
`owned:7|owned:11` exactly. Sequential awaited method calls establish both
assignments without claiming an external setter hop, physical threads, or an
order between independent messages.

`actor-subscript-setter-diagnostic.swift` supplies the separate language
boundary. Real Swift rejects `await counter[0] = 1` at line 9 because the
actor-isolated subscript cannot be mutated from a nonisolated context, and it
also warns that the `await` contains no async operation. Required compiler
preflight rejects the same source before declaration collection or runtime
mutation.

The legal same-source case was already GREEN as a characterization because its
enclosing actor method owned the mailbox. The focused dynamic bypass was RED:
a direct setter outside the actor completed without any executor ownership and
reported `actor subscript setter executed without executor ownership`.

User-subscript setters now execute through the same common accessor context as
subscript getters and computed accessors. For an actor receiver, that context
requires the current source task to own the matching mailbox lease, installs
the declaration's lexical owner, balances call depth, and restores logical and
lexical executor state on every exit. It deliberately never acquires a lease
or synthesizes an external setter hop. Ordinary and explicit `nonisolated`
subscripts retain their caller-executor behavior.

Post-fix native/interpreter parity is GREEN in all 20 repetitions with
native-observation digest
`d80eb25e8b35d0bc881005b4be52c9f488611cc63dc18ed4984f54831d2ecdcc`.
Focused runtime evidence proves legal owned mutation, fail-closed direct
dynamic entry, and empty task/actor registries. Compiler-oracle and production
preflight tests prove rejection before interpreter mutation.

The final incremental `--build-tests` build took 5.80 seconds. Seven parallel
prebuilt processes completed within 22.62 seconds: 226 actor/async/host/value/
language tests, four SwiftUI actor/TaskObservatory/subscript tests, four actor
parity cases with 20 exact repetitions each, and all nine FoodTruck rungs
passed. A deliberately broader combined methodology/compiler-preflight/
diagnostic process also passed 67/67 but formed an 82.44-second tail. Future
incremental boards run only the changed preflight test; the complete preflight
suite remains part of the milestone gate.

This closes actor subscript getter/setter confinement. Cross-actor failure,
remaining accessor cancellation/failure exits, replayable mailbox stress,
isolated-parameter dispatch, and the remaining per-feature safety-boundary
flips keep M5 open.

### Cross-actor throwing-function exit

`actor-cross-actor-failure.swift` isolates the ownership edges around a
throwing hop. A caller actor records its ownership, awaits a different actor's
synchronous throwing method, catches the error, checks that its own lease was
restored, sends a recovery message to the callee, and checks restoration again.
The callee records ownership in both messages and retains the mutation made
before throwing. Twenty bounded Apple Swift 6.3.3 executions under Swift 6
complete strict concurrency returned
`owned|caught|owned|owned:owned:2|owned` exactly.

The same source was already GREEN in all 20 interpreter repetitions. This is a
coverage closure rather than a production semantic patch: the common
cross-executor invocation path parks the caller actor, acquires the callee,
uses balanced `defer` cleanup for the throwing body, releases the callee, and
reacquires the caller before propagating the error into source `catch` logic.
The fixture claims those causal ownership edges and retained mutations only;
it does not claim FIFO, physical worker behavior, or unrelated task ordering.

Native/interpreter observations have digest
`c083a020a5dd4cf6191ca31cea58c31b9ad37657d3945cb6b0452141258c530f`.
Focused runtime evidence independently checks the same source-executor and
mailbox-owner identities, then proves empty task and actor registries after
both actor instances leave scope.

The incremental focused build/test took 5.65 seconds. The final four-process
prebuilt board completed in 12.75 seconds: all ten actor-runtime tests, the
acceptance-matrix consistency test, and 20 exact repetitions each of the new
failure case and neighboring reentrancy case passed. No production runtime
file changed in this coverage-only slice, so the already-GREEN FoodTruck and
broader runtime boards were not redundantly repeated.

This closes cross-actor throwing-function failure/restoration evidence.
Effectful-accessor failure/cancellation, isolated parameters, arbitrary global
actors, and replayable mailbox stress remain open M5 work.

### Cross-actor cancellation exit

`actor-cross-actor-cancellation.swift` uses an explicit suspension gate to
remove scheduler timing from cancellation. A source task enters a caller actor,
hops to a target actor, records target ownership, and suspends. Only after the
controller observes that suspension does it cancel the task and open the gate.
The target must reacquire its actor before `Task.checkCancellation()` throws;
the caller must then reacquire its own actor before the typed cancellation
catch and before/after a subsequent recovery message.

Twenty bounded Apple Swift 6.3.3 executions under Swift 6 complete strict
concurrency returned
`owned|cancelled|owned|owned:owned:owned:2|owned` exactly. The three target
ownership fields establish entry, post-suspension reacquisition, and recovery;
the final `2` proves the pre-cancellation mutation was retained. No FIFO,
physical worker, or unrelated scheduling order is asserted.

The equivalent interpreter source was already GREEN in all 20 repetitions, so
this is another coverage closure over the common runtime rather than a
production patch. Its native-observation digest is
`1c5598f4348229ef4f6e7c8ab7599fe766a13f7c239640f413df50c94acf25db`.
Focused evidence checks logical-executor and runtime mailbox-owner identities
separately and proves empty task/actor registries after the cancelled task and
both actor instances leave scope.

The incremental focused build/test took 6.31 seconds. The final five-process
prebuilt board completed in 12.80 seconds: all eleven actor-runtime tests, the
acceptance-matrix consistency test, and 20 exact repetitions each of actor
reentrancy, cross-actor failure, and cross-actor cancellation passed. No
production runtime file changed in this coverage-only slice.

This closes controlled cross-actor function cancellation/restoration evidence.
Effectful-accessor failure/cancellation, the remaining isolated-parameter
forms, arbitrary global actors, and replayable mailbox stress remain open M5
work.

### Isolated-parameter executor dispatch

`actor-isolated-parameter.swift` passes one source actor to a synchronous
global function through a required explicit `isolated` parameter. The function
checks that its logical executor and mailbox owner are that exact argument,
then performs two sequential mutations. Twenty bounded Apple Swift 6.3.3
executions under Swift 6 complete strict concurrency returned
`owned:2|owned:5|5` exactly. The observation proves argument-selected executor
entry and retained mutation only; it makes no physical-thread or independent
message-order claim.

Before the production change, the same-source differential was RED in all 20
repetitions: native returned `owned:2|owned:5|5`, while the interpreter returned
`unowned|unowned|0`. Function-parameter metadata discarded the `isolated` type
specifier, and invocation resolved only declaration- or receiver-selected
executors, so the body ran on its caller executor and the ownership guard
prevented both mutations.

Function parameters now preserve the SwiftSyntax `isolated` specifier as
semantic metadata. A common pre-entry argument matcher supplies the same
label, positional, variadic, tuple-compatibility, and trailing-closure mapping
to both ordinary binding and dynamic executor resolution. The suspending call
path resolves the required explicit actor argument before parking a caller
actor or acquiring the callee mailbox; the eager path permits the call only
when that mailbox is already owned. A missing argument, a non-source-actor
value, multiple isolated parameters, or conflicting declaration executor
fails closed. No function, fixture, actor, or parameter name is recognized by
the implementation.

Post-fix native/interpreter parity is GREEN in all 20 repetitions with
native-observation digest
`454021a048cafab87c1493a0bc288fc49d3ddd9e8a92ddc5338079bdf0be95a7`.
Focused runtime evidence additionally proves preserved parameter metadata,
externally awaited executor acquisition, same-actor synchronous entry,
fail-closed unawaited cross-actor entry, and empty task/actor registries after
completion.

The final incremental `--build-tests` build took 11.61 seconds. Eight
independent read-only processes then completed in 22.34 seconds: all twelve
actor-runtime tests, the acceptance-matrix consistency test, 114 related
core/SwiftUI tests, 20 exact repetitions each of reentrancy, cross-actor
failure, cross-actor cancellation, and isolated-parameter parity, plus all
nine FoodTruck rungs passed. The test/native-oracle portion completed within
12.35 seconds; FoodTruck was the board tail at 22.34 seconds.

Defaulted `#isolation`, optional isolated parameters, non-source actor
existentials, arbitrary global actors, effectful-accessor exits, and replayable
mailbox stress remain outside this slice.

### Throwing actor computed-getter exit

`actor-computed-property-failure.swift` sends a message from one source actor
to another actor's synchronous throwing computed getter. The getter records
target ownership, mutates target storage, and throws. The caller catches that
specific source error, checks its own restored ownership, then sends a recovery
message that observes the first mutation and performs a second one. Twenty
bounded Apple Swift 6.3.3 executions under Swift 6 complete strict concurrency
returned `owned|caught|owned|owned:owned:2|owned` exactly. These actor-ownership
and retained-state edges are causal; FIFO, physical threads, and unrelated
scheduling order are not asserted.

The same source was already GREEN in all 20 interpreter repetitions, so this
is characterization rather than a production gap closure. The common awaited
computed-accessor path acquires the target mailbox, balances that lease with
`defer` when source evaluation throws, and restores the parked caller actor
before rethrowing into source `catch`. The later recovery message proves the
target mailbox was not stranded. No production runtime file changed.

Native/interpreter observations have digest
`a4415583eb00029a12fe4f797275828d02bf6fdc11ef93f390697037ed25dfd5`.
Focused runtime evidence independently verifies the caller/target logical
executor and mailbox-owner identities and requires empty task/actor registries
after both actor instances leave scope.

The incremental `--build-tests` build took 5.05 seconds. Five independent
prebuilt processes completed in 12.21 seconds: all thirteen actor-runtime
tests, the acceptance-matrix consistency test, and 20 exact repetitions each
of the successful computed getter, throwing function, and throwing computed
getter cases passed. At that characterization checkpoint, async computed-getter
cancellation, other unproven accessor exits, and replayable mailbox stress
remained open.

### Async-throwing actor computed-getter cancellation exit

`actor-computed-property-cancellation.swift` sends a message from one source
actor to another actor's `get async throws` computed property. An explicit gate
holds the getter after it has recorded target ownership and mutated target
storage. The controller cancels the source task before opening that gate. The
getter then records ownership again, explicitly observes cancellation, and
throws into the caller actor. The caller checks its restored ownership and
sends a recovery message that observes both getter ownership samples and the
retained mutation. Twenty bounded Apple Swift 6.3.3 executions under Swift 6
complete strict concurrency returned
`owned|cancelled|owned|owned:owned:owned:2|owned` exactly. The gate establishes
the asserted cancellation and resume edges; FIFO, physical threads, and
unrelated scheduling order are not asserted.

Before the runtime change, the native side completed but the first interpreted
repetition exceeded its five-second child timeout: declaration collection had
dropped the getter's `async` effect and the eager member evaluator could not
open the suspension gate. `ComputedProperty` now retains `async` and `throws`,
awaited member access selects a suspension-aware accessor body, and the shared
actor invocation path keeps mailbox acquisition, release-at-suspension,
reacquisition, error unwinding, and caller restoration balanced. A canonical
async session also rejects an eager entry into an async getter instead of
silently executing it synchronously.

Native/interpreter observations are GREEN in all 20 repetitions with digest
`4659a853409d6011a4cf6137d832eaea8900444959de7f1c5ba602de5964f86a`.
Focused runtime evidence independently verifies preserved getter-effect
metadata, target/caller executor ownership, fail-closed eager entry, and empty
task/actor registries after completion. The incremental `--build-tests` build
took 14.85 seconds. Eight independent prebuilt processes then completed in
23.93 seconds: all fourteen actor-runtime tests, the acceptance-matrix
consistency test, 20 exact repetitions each of the successful computed getter,
throwing function, cancelled function, throwing computed getter, and cancelled
async computed getter cases, plus all nine FoodTruck rungs passed. The
test/native-oracle portion completed within 13.33 seconds; FoodTruck was the
board tail at 23.70 seconds. At that checkpoint, effectful subscript-getter and
other unproven accessor exits plus replayable mailbox stress remained open M5
work.

### Async-throwing actor subscript-getter cancellation exit

`actor-subscript-cancellation.swift` sends a message from one source actor to
another actor's `get async throws` subscript. A controlled host gate holds the
getter after target ownership is recorded and the supplied increment mutates
target storage. The controller cancels the source task before opening the gate.
The getter records ownership again, explicitly observes cancellation, and
throws into the caller actor. The caller verifies restored ownership and sends
a recovery message that observes both getter ownership samples and the retained
mutation. Twenty bounded Apple Swift 6.3.3 executions with SDK 26.5 under Swift
6 complete strict concurrency returned
`owned|cancelled|owned|owned:owned:owned:2|owned` exactly. The gate establishes
the cancellation and resume edges; FIFO, physical threads, and unrelated
scheduling order are not asserted.

Before the runtime change, native completed but the first interpreted
repetition exceeded its five-second child timeout. Declaration collection had
dropped subscript getter effects, and the awaited actor path acquired the
mailbox only to call the synchronous getter driver, so the gate could never
open. `SubscriptMember` now preserves `async`/`throws`; awaited dispatch selects
a shared suspension-aware accessor context for interpreted instances and host
extension receivers, adding mailbox ownership only for actors. Canonical async
sessions reject eager async-subscript entry rather than silently executing it
synchronously.

Native/interpreter observations are GREEN in all 20 repetitions with digest
`b538ccb532ea8c2db2b0343bfbe01bc60926d7798900029188fd435e8de846ba`.
Focused runtime evidence independently verifies getter-effect metadata,
target/caller executor ownership, fail-closed eager entry, and empty task/actor
registries after completion. The incremental `--build-tests` build took 12.62
seconds. Eight independent processes reused that prebuilt bundle and completed
together in 24 seconds: all fifteen actor-runtime tests, all 86 async-execution
tests, the acceptance-matrix consistency test, and 20 exact repetitions each
of the synchronous subscript getter, controlled actor reentrancy, cancelled
async computed getter, and cancelled async subscript getter cases passed;
`FoodTruckCheck` also exited successfully. Independent successful-completion
and source-error async-subscript cases plus replayable mailbox stress remained
open at that checkpoint.

### Async-throwing actor subscript success and source-error exits

`actor-subscript-async-exits.swift` executes two sequential calls from one
source actor to an `async throws` subscript on another actor. Each call uses a
fresh source-owned actor gate, so the getter records target ownership, suspends,
and cannot continue until the controller opens that exact gate. The successful
call records the returned value; the second throws a typed source error. Both
callers record their restored actor ownership before sending a recovery message
to the target. Twenty bounded Apple Swift 6.3.3 executions with SDK 26.5 under
Swift 6 complete strict concurrency returned
`owned|value:1|owned|owned:owned:owned:2|owned||owned|caught|owned|owned:owned:owned:2|owned`
exactly. The sequential awaits and separate gates establish every asserted
edge; FIFO, physical threads, and unrelated scheduling order are not asserted.

This change used the characterization workflow. Before any production edit,
the equivalent interpreter case was already GREEN in all 20 fresh-process
repetitions with native-observation digest
`b8b77a744d7628eab78be63cd160a01176cbbb99f3c292be54b1c1685eb30fb1`.
The general suspension-aware subscript accessor path from the preceding gap
closure already reacquired the target for both normal and source-error exits,
released it, and restored the caller. No production runtime change was
required. Focused evidence independently checks retained `async`/`throws`
metadata, target/caller ownership after a real yield, both outcomes, and empty
task/actor registries. The incremental `--build-tests` build took 5.14 seconds.
Eight independent processes then reused that bundle and completed together in
23 seconds: all sixteen actor-runtime tests, all 86 async-execution tests, the
acceptance-matrix consistency test, 20 exact repetitions each of actor
reentrancy, cancelled async computed/subscript getters, and the new async
subscript exit case, plus `FoodTruckCheck`, passed. Remaining unproven accessor
exits, arbitrary global actors, defaulted/optional isolated parameters, and
replayable mailbox stress remained open at that checkpoint.

### Async-throwing actor computed-getter success and source-error exits

`actor-computed-property-async-exits.swift` executes two sequential calls from
one source actor to an `async throws` computed getter on another actor. Each
target owns a fresh source actor gate and records its actor ownership before
and after the controller-forced suspension. The first getter returns its
retained mutation; the second throws a typed source error. Both callers verify
their restored actor ownership before sending a recovery message to the target.
Twenty bounded Apple Swift 6.3.3 executions with SDK 26.5 under Swift 6 complete
strict concurrency returned
`owned|value:1|owned|owned:owned:owned:2|owned||owned|caught|owned|owned:owned:owned:2|owned`
exactly. Sequential awaits and separate gates establish every asserted edge;
FIFO, physical threads, and unrelated scheduling order are not asserted.

This was also characterization. Before any production edit, the same-source
interpreter case passed all 20 fresh-process repetitions with
native-observation digest
`6744ccb7f1c8981e38aa259318f60abba189865f1656454467c4a41662c9ae33`.
The existing suspension-aware computed-accessor path already performed target
reacquisition, balanced release, and caller restoration on both exits, so no
production runtime change was justified. Focused evidence independently checks
retained getter effects, target/caller ownership after a real yield, exact
success/error projection, and empty task/actor registries. The incremental
`--build-tests` build took 4.76 seconds. Eight independent processes reused the
bundle and completed together in 22 seconds: all seventeen actor-runtime tests,
all 86 async-execution tests, the acceptance-matrix consistency test, 20 exact
repetitions each of actor reentrancy, cancelled and successful/source-throwing
async computed getters, and successful/source-throwing async subscript getters,
plus `FoodTruckCheck`, passed. Together with the cancelled computed getter and
the three async-subscript exit paths, this closes the currently modeled
effectful-getter exit matrix. Arbitrary global actors, defaulted/optional
isolated parameters, and replayable mailbox stress remain open M5 work.

### Replayable actor mailbox and reentrancy stress

`actor-mailbox-stress.swift` asks only commutative terminal questions that
Swift guarantees across scheduler choices. Eight child tasks send four rounds
of messages to one actor. A round barrier forces actor reentrancy through
`Task.yield()`, and every message performs two additional suspension/resume
cycles before its one mutation. The terminal observation records mutation
count, completed rounds, pending barrier arrivals, ownership violations, and
valid children. Twenty bounded Apple Swift 6.3.3 executions with SDK 26.5
under Swift 6 complete strict concurrency returned `32:4:0:0:8` exactly. The
fixture deliberately asserts no FIFO, child-start or completion order,
physical thread, or cross-actor parallelism.

This was characterization, not a production runtime fix. Before any runtime
edit, the same-source interpreter fixture was already GREEN in all 20
fresh-process repetitions with native-observation digest
`cedc3aa25350b5eb44f12c8856ba2f7597a61ae1d87b5013fc08d91177530eb3`.
The existing mailbox and suspension-lease paths already released and
reacquired actor ownership correctly across every barrier and yield.

A separate ordinary-test board makes the characterization replayable and
broader than the fixed parity case. Its 64 deterministic seeds vary fanout
from 2 through 9, rounds from 2 through 5, zero through three in-segment resume
yields, and whether each child yields before actor entry. Every seed checks
exactly `fanout * rounds` mutations, all rounds complete, no pending arrival or
ownership violation, every child reports valid, and task, actor, structured
scope, task-group, host-operation, and scheduler registries are empty. A
failure reports the exact single-seed command through
`DYNAMIC_SWIFT_ACTOR_MAILBOX_STRESS_SEED`; a negative-control test pins that
diagnostic. The full board passed in 1.97 seconds.

The final incremental `--build-tests` rebuild took 12.27 seconds. Eight
independent processes then reused that bundle and completed together in 17
seconds: all 17 actor-runtime tests, both mailbox-stress tests, all 86
async-execution tests, the acceptance-matrix consistency test, 20 exact
repetitions each of actor reentrancy, mailbox stress, and async computed-getter
exits, plus the FoodTruck social-feed and sales-history ratchets, passed. This
closes the actor identity/storage/serial-executor entry requirement. M5 remains
partial for arbitrary global actors, defaulted/optional isolated parameters,
and the per-feature fail-closed safety boundary.

### Defaulted and optional isolated-parameter dispatch

`actor-isolated-parameter-defaults.swift` asks whether a synchronous function's
`isolated (any Actor)? = #isolation` parameter uses the caller's lexical
isolation before entry. Four calls cover a default inherited inside a source
actor, an explicit source actor, explicit nil, and an omitted default from
explicitly nonisolated code. Twenty bounded Apple Swift 6.3.3 executions with
SDK 26.5 under Swift 6 complete strict concurrency returned
`owned:actor|owned:actor|unowned:none|unowned:none` exactly. A second fixture
separates value presence from lane selection on MainActor: omitted
`#isolation` is non-nil and selects the main lane, while explicit nil remains
nil without moving a synchronous caller off that lane. Its native result was
`actor:main|nil:main` in all 20 executions. Neither fixture claims arbitrary
global actors, physical worker execution, or unrelated scheduling order.

Before the production change, the first interpreted case was RED on its first
fresh-process repetition with `isolated parameter 'isolation' requires an
explicit runtime argument`. Executor resolution matched only call-site
arguments and rejected the omitted slot before ordinary default binding.

Invocation now materializes a missing isolated default exactly once in the
caller's lexical executor frame before any hop. The exact resulting value is
added to the effective call arguments, used to select the callee executor, and
then reused by ordinary parameter binding, so `#isolation` is never reevaluated
after entry. The magic literal projects a real source-actor instance, a logical
MainActor isolation value, or nil; it does not inspect the physical native
MainActor that hosts the cooperative evaluator. Explicit source actors and nil
flow through the same value-to-executor resolver. Multiple isolated
parameters, declaration-isolation conflicts, missing nondefaulted values, and
nonactor values continue to fail closed without recognizing names from the
fixtures.

Post-fix, the source-actor/nil case passed all 20 repetitions with
native-observation digest
`64050bd2ab20346f1563560e3ad86e002de8429f0acf97828963001ce14bebc6`;
the MainActor/nil case passed all 20 with digest
`b71e627179c415d88f2865bd0e8e9c9b7fee4cb1ed1a615a7c406cf26c725b7b`.
Focused evidence checks preserved `isolated` and `#isolation` syntax metadata,
the four source-actor/nil outcomes, and empty task, actor, and scheduler
registries.

The single `--build-tests` build took 25.73 seconds. Eight independent
processes then reused the bundle and completed together in 14 seconds: all 18
actor-runtime tests, all 86 async-execution tests, the acceptance-matrix
consistency test, 20 exact repetitions each of actor isolated entry, required
explicit isolated dispatch, source-actor/nil defaults, and MainActor/nil
defaults, plus the FoodTruck social-feed and sales-history ratchets, passed.
Defaulted/optional isolated-parameter dispatch was covered in that slice for
source actors, MainActor, and nil. The following slice closes arbitrary global
actors; the per-feature fail-closed safety boundary remains open M5 work.

### Arbitrary global-actor capability dispatch

`actor-arbitrary-global-actor-isolation.swift` asks whether a global actor's
canonical executor capability depends on the nominal type that carries
`@globalActor`. Its struct- and enum-backed declarations each expose a
`static shared` value whose source-actor type differs from the annotated
nominal. Inside each isolated function the fixture compares direct
`#isolation` with that exact shared instance, then forwards the caller-lexical
default through `isolated (any Actor)? = #isolation` and checks ownership of
the same mailbox segment. Twenty bounded Apple Swift 6.3.3 executions with SDK
26.5 under Swift 6 complete strict concurrency returned
`same:owned:same|same:owned:same` exactly. No physical thread, independent
message order, or demand-deferred `@isolated(any)` task-operation executor is
asserted.

This was a gap closure with two independently captured RED observations. The
initial struct-backed interpreter output was `none:unowned:none`; its collected
`StructSymbol` had discarded the source `@globalActor` attribute, so the
ordinary global-actor resolver could not recognize the declaration. After
nominal attribute retention was made uniform, the extended enum-backed probe
produced `same:owned:same|none:unowned:none`: `EnumSymbol` already retained the
attribute, but executor resolution accepted only the separate `.type` runtime
representation.

The general fix preserves attributes on every source struct just as the
existing class/actor/enum collectors do, including nested structs, and makes
global-actor executor resolution consume both nominal runtime
representations. Both paths still require the annotated type to carry
`globalActor`, evaluate its canonical `static shared`, require that value to be
a source actor with a runtime ID, and return that exact actor capability. No
fixture name or actor type is recognized. Focused evidence additionally pins
both nominal metadata representations, the two distinct shared actor IDs,
defaulted-isolated syntax metadata, mailbox ownership, and empty task and
scheduler registries after completion.

Post-fix, all twenty native/interpreter repetitions passed with native-
observation digest
`387b364a7e2c458e4671f25ded8ece0fd74e209c3ff0f55cc388a9f76506b066`.
The final incremental `--build-tests` rebuild took 11.88 seconds. Four
independent prebuilt processes then ran concurrently: all 19 actor-runtime
tests, all 38 methodology/accounting tests, the new 20-repetition differential
case, and all nine FoodTruck rungs passed. The parity lane completed in 14.47
seconds; FoodTruck was the board tail at approximately 33 seconds. An earlier
parallel lane also passed all 86 async-execution tests, all 28 compiler-
preflight tests, and the three neighboring custom-global/source-default/
MainActor-default differential cases. The complete preflight suite took 72.15
seconds and is therefore retained for milestone gates rather than repeated in
unchanged micro-iterations.

The acceptance dependency now names the covered
`M7/native-diagnostic-oracles` requirement, which owns exactly the source-
actor isolation and setter diagnostics used by this runtime slice. The broader
`M7/generated-signatures-and-preflight` row remains open for its explicitly
incomplete SDK inventory denominator and still gates M5 at milestone scope; it
is not a semantic prerequisite for source nominal actor dispatch.

This covers `M5/actor-reentrancy-and-isolated-dispatch`. M5 remains partial
only for the active per-feature fail-closed actor safety boundary; physical
workers remain M9.

### Actor initialization isolation boundary

`actor-initialization.swift` asks whether construction itself owns an actor
executor. Its synchronous initializer records caller-independent lexical
isolation while seeding and mutating stored state; the first externally
awaited method then checks ownership of the new actor's mailbox and returns the
retained value. Twenty bounded Apple Swift 6.3.3 executions with SDK 26.5
under Swift 6 complete strict concurrency returned `none:owned:5` exactly.
The initializer is therefore lexically nonisolated, while the post-init method
is isolated to the new actor. No physical thread or unrelated message order is
asserted. The native-observation digest is
`23e29416eefa3be111ed2ba69d4e6f9a71ba03d22c0bcbee81ef6f7ea013ee46`.

This is a characterization: after correcting the differential support helper,
the production runtime was already GREEN in all twenty fresh-process
repetitions. The first helper version projected only source-actor IDs and
mistook logical MainActor for nil; broadening it to the dynamic executor then
exposed the opposite error by reporting the caller's MainActor inside a
lexically nonisolated initializer. The final adapter consumes the
interpreter's actual lexical `#isolation` projection, matching the native
helper's defaulted isolated parameter. That intermediate adapter failure is
test-oracle evidence, not a claimed production RED.

Focused evidence pins the initializer's synchronous metadata, its single nil
lexical-isolation observation, mailbox ownership during the first isolated
method, the retained value, and empty task, actor, and scheduled-task
registries after completion. The final incremental build took 6.22 seconds.
Three processes then reused the prebuilt bundle directly, avoiding SwiftPM's
otherwise-serialized package-planning lock: all 20 actor-runtime tests passed
in 0.52 seconds, all 38 methodology tests in 12.05 seconds, and the fresh-
process 20-repetition differential in 15.17 seconds, which was the complete
parallel-board tail. This adds actor initialization to the active safety-
boundary inventory; the requirement remains open for the remaining unsupported
actor forms and their explicit fail-closed dispositions.

### Actor task-local propagation

`actor-task-local-propagation.swift` asks whether entering an actor changes
the caller's dynamic task-local context. One source task reads the default,
enters a scoped binding, calls both synchronous and suspending methods on one
actor, and reads the default again after scope exit. Every actor read also
checks mailbox ownership. The fixture has SHA-256
`54e7b2836b00f9f8e62c4950e454e43e4838a360e7031dabc32efaa0becb8c7a`.

Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) compiled it against SDK 26.5 for
`arm64-apple-macosx26.0` with Swift 6, complete strict concurrency, and
warnings as errors. Twenty bounded executions returned exactly:

```text
default:owned|bound:owned|bound:owned>bound:owned|default:owned
```

The binding therefore belongs to the logical task rather than its current
executor: it crosses actor entry, remains present after `Task.yield()` releases
and reacquires the actor, and is restored at dynamic-scope exit. No FIFO,
physical-thread identity, or ordering between independent messages is
asserted. The differential harness's order-independent native-observation
digest is
`586ac0ef0f2e1c097f5cb1471b3983067b5f15b351a704f36b7c1a11eb02e66e`.

This is characterization, not gap closure. The production runtime was already
GREEN in all twenty fresh-process repetitions, so no semantic implementation
changed and no RED was fabricated. A focused runtime test independently pins
one task ID, one actor ID, root-task kind, the task-local storage counts
`0,1,1,1,0`, mailbox ownership at all five observations, identity between the
task record and evaluator storage, restored empty storage, and empty task,
actor, group, scope, and scheduler registries after completion. Its first
version incorrectly required a synchronous host callback to receive
`TaskBoundEvalContext`; the corrected observer uses the interpreter's canonical
current evaluation-task context, matching the established parity adapter.

After one incremental test build, the focused runtime check passed in 0.03
seconds and the differential passed in 14.28 seconds; when run concurrently,
the differential remained the board tail. The full M5 gate remains reserved
for closure of the actor safety boundary. Actor task-local propagation now
covers that required matrix row; the next required row was queued-message
cancellation.

### Queued actor-message cancellation

`actor-queued-message-cancellation.swift` asks whether cancellation removes a
cross-actor call that has already suspended behind an occupied actor. Its
native support gate blocks one synchronous actor segment on an `NSCondition`.
A waiter running on MainActor sets a marker immediately before the cross-actor
call; because MainActor jobs run until suspension, the controller cannot
observe that marker until the waiter has attempted the busy actor hop. It then
cancels the waiter before releasing the holder. The fixture has SHA-256
`7ecd99abe7f26d42ac1bc70bd38a6d4c440a71a8ee2470fba9578cf1d4bdf26b`.

Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) compiled the source against SDK 26.5
for `arm64-apple-macosx26.0` with Swift 6, complete strict concurrency, and
warnings as errors. Twenty bounded executions returned exactly:

```text
requested|released|owned:cancelled
```

Cancellation therefore does not discard the queued call or synthesize a
throw. Ordinary mailbox handoff still enters the method with actor ownership,
and the source body then observes its task's request. No FIFO among multiple
waiters, physical-thread identity, or automatic cancellation throwing is
asserted. The differential harness's native-observation digest is
`00f86da29041ea4b50046cc64990089bfc9d670f141c54b19f4945c6374331c3`.

This closed a parity-harness gap while characterizing an already-correct
production mechanism. Before the controlled interpreter gate existed, native
compilation and all native repetitions were green, but the first interpreted
repetition failed at the unresolved gate helper. A cooperative interpreter
cannot block a physical MainActor inside a synchronous actor segment and still
run its controller. Its general differential adapter therefore creates an
ordinary synthetic runtime task in the same session, acquires the source
actor through `CooperativeConcurrencyRuntime`, and retains that lease until
the source releases the gate. The actual source waiter then exercises the
normal mailbox and cancellation paths; no fixture, actor, or method name is
recognized.

Production cancellation already left `waitingForActor` independent from the
cancellation request. A focused runtime regression now pins the occupied
owner, the queued waiter and suspension reason before cancellation, the same
mailbox edge afterward, direct ownership handoff, request-before-observation,
successful completion after observation, and empty task/actor registries.
The focused test passed in 0.02 seconds; the twenty-repetition differential
passed in 14.03 seconds. This covers the final behavioral row in the required
actor matrix. M5 remains open only for the explicit unsupported-form safety
audit and its closing gates.

## Official Swift upstream intake

### Pinned Swift 6.3.3 concurrency runtime corpus

The upstream harness now pins `swiftlang/swift` at
`swift-6.3.3-RELEASE` / `064859e41d68596f486c5d724401cb370f260409`.
Its reproducible sparse-checkout script inventories all 134 Swift sources in
`test/Concurrency/Runtime`, assigns every file an explicit `direct`,
`diagnostic`, `needs-adapter`, or `unsupported` reason, and copies only
manifest-selected fixtures byte-for-byte. The current inventory is 14 direct,
4 diagnostic, 109 needs-adapter, and 7 unsupported. A direct fixture means it
is selected for differential execution; the `interpreter-diagnostic` assertion
is a native-positive fail-closed boundary and is not counted as behavioral
parity.

Native Swift compiles every selected concurrency fixture in Swift 6 strict
concurrency mode. The interpreter receives the same source plus only a generic
detected-`@main` entry. A local literal FileCheck subset validates both native
and interpreted output; unsupported regex and variable syntax is rejected
rather than weakened. The first direct tranche covers throwing `async let`,
pre-start cancellation with a late async-let child, task-handle cancellation,
task-group pending `next()`, and task-group `isEmpty` while a child is pending
and after its completion has been consumed. The next direct fixtures cover
`addTaskUnlessCancelled` for both ordinary and discarding groups whose owner is
already cancelled, nested async-let task-local inheritance and restoration, and
Task-to-async-let-to-group task-local snapshotting.

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

### M4 pinned swiftlang nested async-let task locals

The unchanged pinned swiftlang fixture
`test/Concurrency/Runtime/async_task_locals_async_let.swift` is now a direct
case. It nests async-let children inside a task-local binding, nests another
async let inside one of those children, and then repeats the inheritance check
through a five-level async-let chain. Native Swift 6.3.3 observes the default
`0` before and after the scope and the bound value `2` in all four child reads.

Sibling async-let print order is not a Swift guarantee. Native runs observed
both the source CHECK order and a run in which the two reads from the nested
function preceded its sibling read. The manifest therefore uses a dedicated
unordered literal-multiset oracle for this case. It requires two distinct
default-value matches and four distinct bound-value matches in both native and
interpreted output; a negative control proves that a missing duplicate fails.
The upstream source and its CHECK lines remain byte-for-byte unchanged.

The first interpreted run was RED at `TaskLocal projection has no member
'get'`. A source task-local projection now carries its declaration's immutable
default and value type, exposes the real zero-argument `get()` operation, and
returns the current task-owned binding or a value-semantic copy of the default.
Its description matches Swift's `TaskLocal<Value>(defaultValue: ...)` form
instead of exposing the interpreter's internal declaration key.

Focused runtime coverage records a root, async-let child, and nested async-let
grandchild with three distinct task-local storage objects, both structured
scope ownership edges, and inherited value `2` in both children. After join,
all three storage objects and the task, group, scope, and scheduler registries
are empty. The upstream inventory is now 7 direct / 4 diagnostic / 116
needs-adapter / 7 unsupported across the same 134 pinned sources. The broader
M4 composition requirement remains open for group/async-let cross-composition,
executor inheritance, and child-created unstructured work.

### M4 pinned swiftlang Task/async-let/task-group composition

The unchanged pinned swiftlang fixture
`test/Concurrency/Runtime/async_task_locals_in_task_group_may_need_to_copy.swift`
is now a direct case. It composes an unstructured `Task`, an `async let`, task
groups nested both in one task and across group children, and task-local scopes
that end immediately after `addTask`. The source hash matches the pinned Swift
checkout byte-for-byte.

Apple Swift 6.3.3 compiled the fixture in Swift 6 strict-concurrency mode. All
20 bounded native runs produced the same trace hash. The committed FileCheck
oracle asserts the source's ordered task-local values; each checked handoff is
bounded by `group.next()`, an awaited task value, or structured scope exit. It
does not claim a relative execution order for independent ready tasks.

This iteration is a characterization: the unchanged source was already GREEN
through the interpreter, so no production behavior changed. A focused runtime
test observes the live ownership chain `root -> Task -> async let -> group
child`, the separate async-let and group structured scopes, and four distinct
task-local storage objects. The active `one = 11` binding reaches every task,
while `two = 22` is snapshotted only by the child added inside that binding.
After completion all retained task-local stores, task records, structured
scopes, groups, native drivers, and scheduled-task registries are empty.

The upstream inventory is now 8 direct / 4 diagnostic / 115 needs-adapter / 7
unsupported across the same 134 pinned sources. The broader requirement remains
open for executor inheritance and child-created unstructured work.

The targeted run passes 81/81 tests across `AsyncExecutionTests`, the official
Swift upstream suite, and the concurrency methodology suite. The source-bound
repository receipt is GREEN in 665 seconds with 849 tests, exact 84/84 runtime
case and 1,642-repetition coverage, the unchanged 678/680 corpus ratchet, 5/5
live scenarios, and API parity at 345 match / 0 diverge / 0 interpreter errors /
17 unstable / 0 no-twin. Its start/end commit and worktree fingerprints match
and `driftDetected` is false.

### M4 group-child-created unstructured Task lifetime

`task-group-child-unstructured-task.swift` is a same-source native/interpreted
fixture for the ownership boundary between structured group children and the
unstructured work they create. A main-actor gate holds the unstructured `Task`
after it starts. The group child returns its handle, the group joins that child,
and the group scope exits while the returned task remains active. Only then does
the owner open the gate and await the task handle.

Apple Swift 6.3.3 produced
`group-child-start,task-start,group-child-return,group-finished,after-scope,task-active:active:value`
in all 20 bounded runs. Every asserted edge is forced by the gate, a join, or
program order. The fixture therefore establishes that group cleanup neither
waits for nor cancels an unstructured `Task` created by a group child; creation
lineage is not structured ownership.

This iteration is a characterization: the fresh interpreted differential case
was already GREEN, so no production behavior changed. A focused runtime test
observes `root -> group child -> unstructured Task` creation lineage while the
group scope owns only the group child. The child records the nested task in its
spawned-task lineage but not in its structured children, and the session keeps
the nested task scheduled after the group child has completed. After the owner
explicitly awaits the handle, all three task-local stores, task records,
structured scopes, groups, native drivers, and scheduled-task registries are
empty.

The nested-composition requirement now has direct evidence for nested groups,
async lets, task-local snapshots, and child-created unstructured lifetime. Its
remaining semantic gap is executor identity inheritance across those composed
children.

The targeted run passes 92/92 tests across `AsyncExecutionTests`, the complete
native differential board, and the concurrency methodology suite. The
source-bound repository receipt is GREEN in 661 seconds with 850 tests, exact
85/85 runtime-case and 1,662-repetition coverage, the unchanged 678/680 pinned
corpus ratchet, 5/5 live scenarios, and API parity at 345 match / 0 diverge / 0
interpreter errors / 17 unstable / 0 no-twin. Its start/end commit and worktree
fingerprints match and `driftDetected` is false.

### M4 composed child executor inheritance

`task-executor-composition.swift` is a same-source executor-selection probe.
A MainActor root creates an ordinary `Task`; that task creates an `async let`
and a nonisolated task-group child; the group child creates another ordinary
`Task`. The owner awaits the outer task, async-let value, sole group result,
and nested task value, so the assertion compares executor identity without
claiming any independent ready-task order.

Apple Swift 6.3.3 compiled the fixture in Swift 6 strict-concurrency mode. All
20 bounded native runs produced
`main|main:worker:worker:worker`: ordinary `Task` creation inherited MainActor,
the async-let and nonisolated group-child operations began on the cooperative
executor, and the task created by the group child inherited that executor.

This iteration is a gap closure. Before the runtime change, all 20 interpreted
runs produced `main|main:main:main:main`. `makePendingRuntimeTask` applied the
ordinary unstructured-task inheritance rule to every non-detached task kind,
so structured children copied the owner's MainActor identity. Initial executor
selection is now task-kind-specific: detached tasks select detached identity,
async-let and group children select the cooperative default, and ordinary
unstructured tasks inherit the creator's current executor. Declaration-level
actor hops remain scoped to the invoked declaration and restore the child's
initial executor afterward.

Focused runtime assertions cover both ownership chains:
`root(main) -> Task(main) -> async let(default) -> group child(default)` and
`root(main) -> group child(default) -> Task(default)`. They retain the existing
task-local snapshot, structured-scope, unstructured-lifetime, and registry
cleanup proof. Explicit actor-isolated closure metadata, arbitrary actors, and
executor queues remain M5/M7 work; this M4 claim is the initial-executor rule
for the currently supported nonisolated structured-child surface.

With this case, `M4/nested-composition-and-child-created-work` is covered.
Nested groups, nested async lets, Task-to-async-let-to-group task-local
snapshots, child-created unstructured lifetime, and composed executor selection
all have native plus focused runtime evidence.

The targeted run passes 92/92 tests across `AsyncExecutionTests`, the complete
native differential board, and the concurrency methodology suite. The
source-bound repository receipt is GREEN in 833 seconds with 850 tests, exact
86/86 runtime-case and 1,682-repetition coverage, an uncached 678/680 pinned
corpus sweep, 5/5 live scenarios, and API parity at 345 match / 0 diverge / 0
interpreter errors / 17 unstable / 0 no-twin. Its start/end commit and worktree
fingerprints match and `driftDetected` is false.

### M4 bounded structured tree and repeated sessions

`task-group-bounded-tree.swift` recursively creates work only through
`withTaskGroup`. It exercises shapes `(depth: 0, fanout: 4)`, `(1, 4)`, and
`(3, 3)`. The deepest shape creates 39 structured children across 13 nested
groups; consuming every result with a commutative sum gives the
scheduler-independent node counts `1,5,40`.

Apple Swift 6.3.3 compiled the fixture in Swift 6 strict-concurrency mode and
produced `1,5,40` in all 20 bounded runs. The interpreter produced the same
terminal value in all 20 fresh-process runs. The stress oracle intentionally
asserts only complete structured joining and the aggregate result, not sibling
completion order.

A focused runtime test then reuses one interpreter for 16 consecutive async
sessions. Every session rebuilds the same bounded tree and returns `1,5,40`;
after each return, the active task, structured-scope, task-group,
host-operation, and scheduled-task registries are empty. This is a
characterization slice, so no production runtime behavior changed.

The `M4/structured-stress-and-leak-plateau` requirement remains open. Bounded
fanout/depth and repeated-session registry cleanup now have retained evidence;
seeded cancellation storms, weak deallocation of a complete structured graph,
and an RSS plateau are still required before the acceptance row can close.

The source-bound repository receipt for this slice is GREEN and covers 851
tests, exact
87/87 runtime cases and 1,702 repetitions, the 678/680 pinned corpus ratchet,
5/5 live scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M4 structured task-group graph weak lifetime

The native semantic anchor remains `task-group-bounded-tree.swift`: every
recursive group scope joins all of its children and produces the
scheduler-independent terminal value `1,5,40` in 20/20 Apple Swift 6.3.3 and
interpreter processes. Object release below is an interpreter ownership
invariant layered on that compiled Swift behavior, not a claim that Swift
exposes its internal task objects.

During a live leaf in a depth-three binary group tree, the focused lifetime
test retains only weak references to the root and leaf task records, the leaf's
source handle, task group and structured scope, task-local storage,
task-owned and host-bound evaluator contexts, and native task driver. The
tree returns the exact node count `15` after all eight leaves execute. At that
point all runtime registries are empty and every captured graph object has
deallocated. Leaving the interpreter's ownership scope then deallocates both
the cooperative runtime and the interpreter itself.

This is a characterization slice: the ownership implementation was already
correct and no production runtime behavior changed. It strengthens the prior
registry-count evidence into an ARC lifetime proof. The
`M4/structured-stress-and-leak-plateau` requirement remains open only for a
seeded structured cancellation-storm board and a retained RSS plateau.

The source-bound repository receipt for this slice is GREEN and covers 852
tests, exact 87/87 runtime cases and 1,702 repetitions, the 678/680 pinned
corpus ratchet, 5/5 live scenarios, and API parity at 345 match / 0 diverge /
0 interpreter errors / 17 unstable / 0 no-twin.

### M4 seeded structured cancellation storm

`task-group-cancellation-storm.swift` is a same-source stress fixture for
high-fanout group cancellation. Thirty-two children all enter a 30-second
cancellable sleep before the owner calls `cancelAll()` four times. Every child
catches `CancellationError` and reports its own cancellation state; group
iteration consumes all results with a commutative count and sum.

Apple Swift 6.3.3 produced `32:32:cancelled:owner-active` in all 20 bounded
strict-concurrency runs. The interpreter produced the identical terminal value
in 20 fresh processes (native observation digest `b83e814b…`). The assertion
therefore proves cancellation observation, idempotent repeated requests, full
group draining, and owner isolation without claiming sibling completion order.

`StructuredCancellationStressTests` extends that endpoint through 64
deterministic seeds. Non-overlapping seed bits select fanout 8 through 15,
cancellation before any child is added or after every child starts, and one
through four duplicate `cancelAll()` requests. The complete board drains
exactly 736 cancelled children while reusing one interpreter across sessions;
after every seed, task, group, scope, host-operation, and scheduler registries
are empty. Failures carry an exact replay command. A focused replay of
`0x57acce110000002d` ran exactly one configuration and emitted `replay:true`.

This is another characterization slice: native and interpreted semantics plus
runtime cleanup were already correct, so no production behavior changed. The
`M4/structured-stress-and-leak-plateau` acceptance row now remains open only
for a retained RSS plateau under repeated structured workloads.

The source-bound repository receipt for this slice is GREEN and covers 854
tests, exact 88/88 runtime cases and 1,722 repetitions, the 678/680 pinned
corpus ratchet, 5/5 live scenarios, and API parity at 345 match / 0 diverge /
0 interpreter errors / 17 unstable / 0 no-twin.

### M4 retained-memory plateau

`StructuredMemoryPlateauTests` turns the bounded-tree semantic anchor into a
retention probe. A dedicated child process reuses one interpreter for 128
warm-up sessions and twelve measured batches of 64 sessions. Each session
executes the previously native-anchored `1,5,40` task-group tree, representing
46 structured nodes, and immediately requires empty task, group, scope,
host-operation, and scheduler registries. One probe therefore executes 896
sessions and 41,216 structured nodes without process-resetting the interpreter.

After allocator pressure relief, the child records Darwin resident size,
physical footprint, and malloc bytes in use before and after every measured
batch. Plateau checks use first/last window medians, late-window spread, and
least-squares positive slope with explicit noise ceilings. Three independent
focused child processes all reported zero median RSS/footprint drift, 448 bytes
of heap drift, and slopes below 3 KiB per batch. The ordinary limits remain
16 MiB total and 1 MiB/batch for RSS/footprint, and 8 MiB total plus 512
KiB/batch for live heap so the test tolerates allocator and CI variation while
still amplifying session-retention defects across 768 measured sessions.

The analyzer's negative control feeds it a linearly growing synthetic process:
2 MiB of RSS/footprint and 1 MiB of heap per batch. It must reject both the
total drift and positive slope, while bounded 192 KiB jitter must pass. The
parent also proves that the measurement ran in a different PID, that a receipt
was written, and that the child stayed within its hard 60-second deadline.

This is a characterization slice with no production behavior change. Together
with native bounded-tree and cancellation-storm parity, per-session registry
checks, and the complete weak graph-release proof, it closes
`M4/structured-stress-and-leak-plateau`. M4 remains partial only for the
generated task-group surface and the M7-backed escaped-capability diagnostic.

The source-bound repository receipt for this slice is GREEN and covers 857
tests, exact 88/88 runtime cases and 1,722 repetitions, the 678/680 pinned
corpus ratchet, 5/5 live scenarios, and API parity at 345 match / 0 diverge /
0 interpreter errors / 17 unstable / 0 no-twin.

### M7 active-SDK signature and effect inventory

`ConcurrencySurfaceGenCore` makes the `_Concurrency.swiftinterface` parser a
testable package component instead of executable-only code. The checked-in
surface now retains all 75 declarations found for the four task-group types
and their four scope functions in the active macOS SDK: overload identity,
complete declaration text, parameter labels and defaults, `async`,
`throws`/`rethrows`, typed errors, `isolated` parameters, `@isolated(any)` and
`@Sendable` function types, `@_inheritActorContext`, declaration modifiers,
and known global-actor attributes. Existing generated intrinsic dispatch is
unchanged.

One focused test parses a synthetic interface containing the effect and
isolation edge cases plus a legacy alias. A second regenerates the surface
from the active SDK in memory and requires byte-for-byte equality with the
checked-in file while asserting the real `withTaskGroup`,
`withThrowingTaskGroup`, `next`, `nextResult`, and `addTask` effects. An SDK or
toolchain update therefore fails `swift test` until the generated surface and
its semantic disposition are reviewed.

That slice changed metadata generation, not interpreted runtime behavior. At
that checkpoint, complete `_Concurrency`/SDK host stubs, compiler invocation,
cache identity, and surfaced preflight diagnostics all remained open; the next
slice closes the production invocation/cache/diagnostic portion while leaving
generated compiled host stubs open.

The source-bound repository receipt for this slice is GREEN in 852 seconds and
covers 859 tests, exact 88/88 runtime cases and 1,722 repetitions, the 678/680
pinned swiftlang corpus ratchet, 5/5 live scenarios, and API parity at 345
match / 0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin. The
start/end commit and worktree fingerprints match and `driftDetected` is false.

### M7 production compiler preflight and pinned swiftlang diagnostic

`SwiftCompilerPreflight` is the first production compiler-backed semantic
boundary. It discovers the active Xcode `swiftc`, complete compiler version,
macOS SDK path/version, target triple, and deployment target, then invokes
strict Swift 6 type checking with an isolated module cache. Its bounded
per-engine cache key includes the source and logical filename plus compiler,
SDK, target/deployment, additional arguments, and gateway-manifest identity.
Compiler diagnostics are normalized to the logical source filename while raw
stdout/stderr and the native exit status remain available for investigation.

The interpreter exposes three explicit policies. Existing callers remain
`disabled`; `diagnosticsOnly` retains native errors while permitting editor
recovery; `required` rejects invalid source before parsing, global mutation,
session creation, or task creation. Both synchronous and asynchronous program
entries cross the same preflight boundary. A hard monotonic deadline snapshots
the compiler driver and all `swift-frontend` descendants by PID plus process
start time, sends TERM, and escalates surviving identities to KILL so a timed
out compiler cannot remain attached or be confused with a reused PID.

The pinned swiftlang corpus now contains the unchanged
`test/Concurrency/taskgroup_cancelAll_from_child.swift` diagnostic from
`swift-6.3.3-RELEASE` commit `064859e4…`. Its SHA-256 is `a358a89a…`; production
preflight must reproduce the Swift 6 non-Sendable and mutable `inout TaskGroup`
capture diagnostics on lines 18 and 25. All 19 allowlisted upstream fixtures
now carry and verify their own SHA-256 before either native or interpreted
execution, preventing a local edit from silently weakening the oracle.

Focused clean-build evidence covers required rejection before mutation,
diagnostics-only recovery, successful execution, cache reuse and invalidation,
compiler process-tree cleanup, all 18 executable upstream comparisons, and the
new compiler diagnostic. M7 remains partial: generated `_Concurrency` and SDK
host declarations still need to become a compiled stub module, and real
project/bridge gateway manifests must be wired into preflight before required
mode can become the default for SwiftUI projects.

### M7 compiled host declaration module boundary

This gap-closure slice asks whether a host gateway's serialized isolation is
visible to the same Swift 6 compiler that checks user source. Before the fix,
the gateway-manifest SHA affected only the preflight cache key: a source call to
the declared gateway failed as an unresolved identifier, so no actor-isolation
rule could be checked. That RED observation distinguished declaration presence
from a merely well-keyed cache.

`CompilerPreflightHostModule` now binds a generated module name and source to a
content-derived manifest identity. Production preflight validates the name,
compiles the module once per engine with the selected compiler/SDK/target and
the same strict Swift 6 policy, imports the artifact into each user check, and
uses `#sourceLocation` so the invisible import does not shift client file or
line diagnostics. A malformed module fails before user type checking; the
shared bounded process runner supplies the same deadline and descendant-tree
cleanup as ordinary preflight. `HostRegistry` exposes the module with a nil
default, and `Interpreter.withActiveCompilerPreflight` binds compiler and
runtime gateway environments from the same registry rather than accepting an
unrelated caller-supplied hash.

The module oracle is the unchanged swiftlang input
`test/Concurrency/Inputs/GlobalActorIsolatedFunction.swift` from pinned commit
`064859e4…`, SHA-256 `5f40cc13…`. Native Apple Swift 6.3.3 serializes its
`@MainActor public func mainActorFunction()` declaration; a minimal client call
from a synchronous nonisolated function is rejected on the original client
line as a main-actor-isolated call. Production preflight reproduces that
cross-module diagnostic, accepts a MainActor-isolated client, compiles the
module only once across distinct client sources, and executes the legal source
through the registry-backed runtime gateway with result `42`.

M7 remains open rather than claiming a generated bridge surface prematurely.
The next slice must make BridgeGen/project manifests emit their actual module
source, extend host call contracts with generated isolation/effect metadata,
and enable this registry-bound path in the real SwiftUI project entry rather
than only an explicit compiler-checked construction.

The clean closing gate was GREEN with no source drift in
926 seconds: build 61 seconds, 869 tests 256 seconds, project/API evaluation
180 seconds, and live verification 425 seconds. Its four parity shards ran all
88 runtime cases for 1,722 selected and completed repetitions; the remaining
boards report 678/680 project fixtures, 345 API matches with zero divergences
or interpreter errors, and 5/5 live scenarios. The machine receipt records
`source.driftDetected = false`, worktree fingerprint `7adc4883…`, and evidence
log digest `0c7e88d9…` under Apple Swift 6.3.3 / macOS SDK 26.5. After the
repository-owned client fixture was moved to its final test-only directory,
the affected compiler-preflight and official-Swift suites repeated GREEN at
8/8 and 5/5 tests respectively.

### M7 generated active-SDK bridge preflight surface

The previous compiled-module boundary still required callers to invent a host
module: `ViewRegistry` exposed no compiler surface, so the compiler and runtime
could silently describe different environments. The RED integration test
observed exactly that nil manifest before any source was type checked.

BridgeGen now emits `GeneratedCompilerPreflightSurface.swift` beside its
runtime gateway tables. The generated module re-exports `_Concurrency`,
Foundation, and SwiftUI, plus the conditionally available Combine,
CoreGraphics, Darwin, ObjectiveC, AppKit, UIKit, and Metal modules already
backing generated gateways. This deliberately does not print lossy declaration
copies from a swiftinterface: compiling the re-export module makes Swift
deserialize the SDK's canonical signatures, effects, generic constraints,
availability, Sendable annotations, and actor isolation. New SDK declarations
therefore enter compiler checking with the SDK update; only APIs synthesized by
the interpreter will require generated declaration stubs of their own.

`ViewRegistry.compilerPreflightHostModule` supplies that generated surface, and
its content-derived manifest identity is now the same identity used by
`Interpreter.withActiveCompilerPreflight(registry:)`. A positive end-to-end
test checks and interprets a real `Button` whose MainActor-isolated action calls
an `@MainActor` function. The corresponding direct call from a synchronous
nonisolated function is rejected on its original source line. This matches a
standalone Apple Swift 6.3.3 module/client oracle and demonstrates that the
result comes from real SwiftUI isolation metadata rather than a handwritten
Button rule.

Two complete BridgeGen emissions produced byte-identical output: the new
surface SHA-256 is `435c2893...`, while all five existing generated gateway
artifacts retained their prior hashes and no SDK drift. The focused closure
board ran 62 tests across compiler preflight, official pinned swiftlang inputs,
the `_Concurrency` surface generator, and generated SwiftUI, Foundation, and
platform gateways.

M7 remains partial. The next dependency-ready work is generated declarations
for interpreter-synthetic host APIs and a recovery-aware project entry policy;
required compiler checking is not silently enabled for the editor or merged
projects in this slice.

The source-bound closing repository gate is GREEN over 870 tests, exact 88/88
runtime parity cases and 1,722 repetitions, the 678/680 pinned corpus ratchet,
5/5 live scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M7 explicit compiler policy at the project facade

The generated registry surface was usable through the low-level interpreter
factory, but the public `InterpreterHost` project/render facade exposed only an
unconfigured initializer. The captured RED was a compile-time API gap: a real
project caller could not select required native checking without bypassing the
same facade used for rendering.

`InterpreterHost` now accepts an explicit `CompilerPreflightMode`. Its default
remains `disabled`, preserving editor recovery, platform-substituted corpus
source, and existing call sites. Selecting `required` or `diagnosticsOnly`
constructs the interpreter through
`Interpreter.withActiveCompilerPreflight(registry:mode:)`; compiler declarations
and runtime gateways therefore come from the same fresh `ViewRegistry`. No
sample or demo source was changed, and the default does not add compiler work
to interactive renders.

The native project oracle is the three unchanged files in
`Examples/TaskObservatory`. Apple Swift 6.3.3 accepted them together under
Swift 6 complete strict concurrency. The public required-mode facade then
typechecked the equivalent merged project against the generated bridge module
and rendered it successfully. A negative control sent a MainActor-isolated
global call from a synchronous nonisolated function through that same facade;
it was rejected with the native isolation diagnostic, proving that the mode is
not ignored.

The focused bridge/compiler/upstream/generated board is GREEN at 64 tests. M7
remains partial for target-aware multi-file project input and any declarations
that are genuinely synthesized by the interpreter rather than supplied by an
SDK module; the explicit policy avoids pretending that a macOS compiler can
authoritatively check every merged iOS corpus project.

The source-bound closing repository gate is GREEN over 872 tests, exact 88/88
runtime parity cases and 1,722 repetitions, the 678/680 pinned corpus ratchet,
5/5 live scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M7 native multi-file project preflight

The project facade previously passed its merged interpreter source to
`swiftc` as one physical file. That is not equivalent to a Swift module:
file-scoped `private` declarations from different files collide after the
merge, and native diagnostics lose the file that produced them.

`SwiftCompilerPreflight` now accepts an ordered set of logical source files,
includes every filename and body in its bounded cache identity, writes them as
distinct temporary inputs to one strict Swift 6 typecheck, and maps diagnostics
back to their logical files. The existing single-source API and `run` ABI are
preserved as forwarding overloads. Host-module imports are injected into every
input, so all files deserialize the same generated SDK isolation and effect
metadata.

`ProjectMaterial` recovers these inputs from its existing `// FILE:` markers;
duplicate basenames receive deterministic logical names. `InterpreterHost`
uses the recovered files only for explicit `required` or `diagnosticsOnly`
compiler policy, while runtime evaluation continues to use the merged syntax
tree. Snippets and the default disabled policy retain their old behavior.

The native Apple Swift 6.3.3 oracle compiles three separate files whose first
two both declare `private func fileScopedValue()` and prints exactly `42`.
Concatenating the same bodies is rejected as an invalid redeclaration. The
production multi-file preflight accepts the native layout, preserves a failing
file's name and line, caches an identical module, and lets the required public
project facade check both TaskObservatory and a duplicate-private project.
The focused compiler/project board is GREEN at 14 tests.

M7 remains partial for target-aware build manifests and declarations that are
truly synthesized by the interpreter rather than re-exported from an SDK. The
source-bound closing gate is GREEN over 875 tests, exact 88/88 runtime parity
cases and 1,722 repetitions, the 678/680 pinned swiftlang corpus ratchet, 5/5
live scenarios, and API parity at 345 match / 0 diverge / 0 interpreter errors
/ 17 unstable / 0 no-twin.

### M7 pinned swiftlang Sendable-capture diagnostics

The compiler corpus now includes the unchanged upstream
`test/Concurrency/sendable_checking_captures_swift6.swift` from
`swiftlang/swift` release `swift-6.3.3-RELEASE`, commit `064859e4…`. Its
SHA-256 is `da9906cb…`; the checked-in fixture is byte-identical to the pinned
checkout, and the networked sync command reproduced the complete selected
corpus without additional drift.

Apple Swift 6.3.3 with complete strict concurrency rejects the source for a
non-Sendable value captured by an `@Sendable` local function, the same value
captured by `@Sendable` closures, and a non-Sendable mutable `inout` capture.
Production `SwiftCompilerPreflight` checks the unchanged file through the same
path used by `Interpreter`, requiring error severity plus the upstream logical
filename, lines 11, 14, 22, and 41, and the upstream message fragments. An
unrelated compiler failure or warning therefore cannot satisfy this oracle.

The captured RED was the upstream manifest containing only one diagnostic
case. After admission it contains 20 SHA-pinned cases: 18 executable native
versus interpreter comparisons and two production-preflight diagnostics. The
focused upstream/compiler board is GREEN at 15 tests. M7 remains partial for
target-aware build manifests and truly interpreter-synthetic declarations.

The source-bound closing gate is GREEN over 875 tests, exact 88/88 runtime
parity cases and 1,722 repetitions, the 678/680 pinned corpus ratchet, 5/5 live
scenarios, and API parity at 345 match / 0 diverge / 0 interpreter errors / 17
unstable / 0 no-twin.

### M7 generated static Task surface

This characterization slice asks whether the static `Task` operations already
implemented by the runtime come from the active `_Concurrency.swiftinterface`
or from another handwritten name table. Before the generator change, the
runtime behavior was already GREEN, but `MemberEvaluator` selected
`detached`, `currentPriority`, `isCancelled`, `checkCancellation`, `sleep`, and
`yield` through raw string cases. The captured generator RED was the absence of
`taskStaticDispatch`, the known-member inventory, and declaration effect
metadata.

The bounded same-source probe
`Tests/NativeProbes/Concurrency/task-static-generated-surface.swift` checks an
uncancelled task, `checkCancellation`, `yield`, zero-duration `sleep`, detached
task creation, and its awaited value. Apple Swift 6.3.3 and `runAsync` both
produce exactly `active:detached`; sequential awaits establish the complete
order, so no scheduler choice is asserted.

`ConcurrencySurfaceGen` now inventories all 14 public static `Task` member
names in the active macOS SDK interface and preserves every overload's async,
throwing, parameter, actor-isolation, Sendable, modifier, availability, and
return metadata. Six implemented names map to generated semantic intrinsics;
`MemberEvaluator` consumes that map instead of owning another source-name
table. Known but unsupported members such as `basePriority` are diagnosed as
active-interface surface, and `detached(executorPreference:)` is rejected
explicitly instead of silently discarding its executor contract. Two complete
generator runs produced the same checked-in output SHA-256 `a40fbcc6…`.

The focused generator/runtime board is GREEN at 89 tests. M7 remains partial:
instance `Task` surface, interpreter-synthetic host declarations, and
target-aware project build manifests are still open. The source-bound closing
gate is GREEN over 879 tests, exact 88/88 runtime parity cases and 1,722
repetitions, the 678/680 pinned corpus ratchet, 5/5 live scenarios, and API
parity at 345 match / 0 diverge / 0 interpreter errors / 17 unstable / 0
no-twin.

### M7 generated Task instance surface

This characterization slice moves source-visible `Task` handle dispatch onto
the active `_Concurrency.swiftinterface`. Before the generator change,
`cancel`, `isCancelled`, `value`, and `result` were selected independently by
raw string switches in the synchronous member and suspension evaluators. The
captured generator RED was the absence of `taskInstanceDispatch`, the complete
known-member inventory, and instance declaration effect metadata; no semantic
RED was invented for behavior that already matched native Swift.

The native anchor is the unchanged swiftlang fixture
`test/Concurrency/Runtime/async_task_handle_cancellation.swift` from release
`swift-6.3.3-RELEASE`, SHA-256 `5829b825…`. Its FileCheck oracle requires the
detached task to observe cancellation, its handle to remain cancelled after
`await task.value`, and the parent task to remain uncancelled. The pinned
upstream runner executes the same file natively and through the interpreter.
Existing exact same-source fixtures separately cover successful, failing, and
cancelled `Task.result` reads.

`ConcurrencySurfaceGen` now inventories all nine public instance `Task` member
names in the active macOS SDK interface and retains both throwing and
nonthrowing `value` overloads plus the async/nonthrowing `result` contract.
Four supported names map to generated semantic intrinsics consumed by both
member lookup and suspension dispatch. Known but unsupported active-interface
members, including deprecated `get`/`getResult`, hashing, and priority
escalation, now fail with an explicit generated-surface diagnostic instead of
falling through as unknown API. Two complete generator runs produced identical
checked-in output SHA-256 `e1c8e433…`.

The focused generator/runtime/upstream board is GREEN at 86 tests. M7 remains
partial for the remaining generated concurrency surface,
interpreter-synthetic host declarations, and target-aware project build
manifests. The source-bound closing gate is GREEN over 880 tests, exact 88/88
runtime parity cases and 1,722 repetitions, the 678/680 pinned corpus ratchet,
5/5 live scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M7 pinned swiftlang nonthrowing sleep cancellation

The executable upstream corpus now includes the unchanged swiftlang fixture
`test/Concurrency/Runtime/taskgroup_cancelAll_cancellationHandler.swift` from
release `swift-6.3.3-RELEASE`, commit `064859e4…`, with SHA-256
`1bb8aa78…`. Apple Swift 6.3.3 in Swift 6 complete strict-concurrency mode
prints exactly `group task isCancelled: true` followed by `done`: cancelling
the group interrupts the deprecated nonthrowing `Task.sleep(_:)`, but the child
continues, observes its cancellation request, and returns a value. The parent
cancellation handler does not run.

The newly admitted differential test first captured the interpreter RED as
`nonthrowing task-group child was cancelled without a value`. The runtime had
collapsed all `Task.sleep` overloads into the throwing cancellation path. Sleep
dispatch now selects the active `_Concurrency.swiftinterface` declaration by
argument shape and uses its generated throwing effect. Cancellation from the
positional nonthrowing overload remains recorded and observable without being
re-thrown; `sleep(nanoseconds:)` and `sleep(for:)` retain their throwing
contract. No upstream, demo, project, or API-name-specific source behavior was
added.

The pinned manifest now contains 21 cases, including 19 executable native
versus interpreter comparisons. Runtime inventory is 9 direct / 4 diagnostic /
114 needs-adapter / 7 unsupported. The focused generated-surface and complete
upstream differential board is GREEN at 6 tests. The source-bound closing gate
is GREEN over 880 tests, exact 88/88 runtime parity cases and 1,722 repetitions,
the 678/680 pinned corpus ratchet, 5/5 live scenarios, and API parity at 345
match / 0 diverge / 0 interpreter errors / 17 unstable / 0 no-twin.

### M7 generated top-level concurrency functions

This characterization slice removes the remaining handwritten registration
table for the supported top-level `_Concurrency` functions. The captured
generator RED was the absence of a top-level function inventory, declaration
metadata, and semantic dispatch; runtime behavior itself was already covered
and was not given an artificial failing assertion.

`ConcurrencySurfaceGen` now inventories all 41 public top-level function names
in the active macOS SDK interface and preserves every overload's parameters,
async/throwing effect, isolation, Sendable annotations, availability,
modifiers, and return type. Five implemented names map to generated semantic
intrinsics: `withTaskCancellationHandler` and the four ordinary, throwing, and
discarding task-group scope functions. `GlobalBuiltins` consumes that generated
map, and task-group kinds derive their source spelling from the intrinsic
instead of retaining a second string table. The other 36 interface names stay
explicitly inventoried without claiming runtime support.

Native evidence remains the unchanged SHA-pinned swiftlang executable corpus,
including cancellation-handler plus group composition and ordinary/discarding
group operations; all 19 executable cases run the same source through Apple
Swift 6.3.3 and the interpreter. The complete AsyncExecution board additionally
exercises throwing and throwing-discarding adapters. Two generator runs and
`--check` produced identical checked-in output SHA-256 `911e55a2…`.

The focused generator/runtime/upstream board is GREEN at 89 tests. M7 remains
partial for interpreter-synthetic host declarations and target-aware build
manifests. The source-bound closing gate is GREEN over 880 tests, exact 88/88
runtime parity cases and 1,722 repetitions, the 678/680 pinned corpus ratchet,
5/5 live scenarios, and API parity at 345 match / 0 diverge / 0 interpreter
errors / 17 unstable / 0 no-twin.

### M7 typed synthetic top-level host declarations

This gap-closure slice asks whether the compiler sees the same `async` effect
as an interpreter-synthetic typed host gateway. The bounded native diagnostic
probe consists of `SyntheticAsyncHostModule.swift` (SHA-256 `8713f015…`) and
`SyntheticAsyncHostMissingAwait.swift`. Apple Swift 6.3.3 compiles the module
in Swift 6 complete strict-concurrency mode, then rejects the unchanged client
on line 4 with `async call in a function that does not support concurrency`.
There is no scheduler observation in this diagnostic assertion.

Before the fix, production preflight reported `no such module
'DynamicSwiftHostSurface'` even though the runtime registry contained a parsed
`func syntheticAsyncValue() async -> Int` gateway. The registry manifest and
runtime behavior could therefore disagree, and the compiler could not enforce
the gateway's effect. The same focused test captured that RED before the
production change.

`HostRegistry.compilerPreflightSyntheticSignatures` now exposes exact parsed
contracts for APIs implemented by the interpreter rather than an SDK.
Production preflight deterministically deduplicates and sorts those contracts,
emits public declaration-only trap bodies, appends them to any generated SDK
re-export module or creates `DynamicSwiftHostSurface`, and derives the manifest
identity from the composed source. A legal client using `await` passes native
preflight and invokes the same runtime gateway once, returning `42`. SDK APIs
remain sourced from canonical serialized SDK modules rather than declaration
copies.

This first synthetic slice deliberately supports typed top-level functions.
Member, initializer, and property signatures fail configuration explicitly;
generated extension/type stubs and source-level global-actor attributes remain
open together with target-aware project build manifests. The focused
compiler/host-contract/upstream/SwiftUI board is GREEN at 33 tests. The
source-bound closing gate is GREEN over 882 tests, exact 88/88 runtime parity
cases and 1,722 repetitions, the 678/680 pinned corpus ratchet, 5/5 live
scenarios, and API parity at 345 match / 0 diverge / 0 interpreter errors / 17
unstable / 0 no-twin.

### M7 synthetic global-actor host declarations

This gap-closure slice asks whether an interpreter-synthetic host contract
retains source isolation when production preflight serializes it into a Swift
module. The native oracle is the unchanged swiftlang support fixture
`Concurrency/Inputs/GlobalActorIsolatedFunction.swift` from release
`swift-6.3.3-RELEASE`, commit `064859e4…`, with SHA-256 `5f40cc13…`, plus the
unchanged `host-module-mainactor-diagnostic.swift` client. Apple Swift 6.3.3
rejects the cross-module call on line 4 as a main-actor-isolated global call
from a nonisolated context. This is a compiler diagnostic guarantee; it does
not assert a runtime schedule or physical thread.

Before the fix, registering the equivalent runtime gateway as
`@MainActor func mainActorFunction()` failed while parsing its typed
`HostSignature` with `unsupported host declaration`. The generated compiler
surface therefore could not express isolation even though the native module
contract could. That exact production failure was captured before changing
the parser.

Native-shaped top-level host functions now retain SwiftSyntax declaration
attributes and modifiers together with their existing parameters, generic
constraints, effects, and return type. Stub generation inserts `public` at the
parsed `func` token without reordering attributes or rewriting the contract;
an explicitly non-public synthetic declaration fails configuration instead of
silently changing visibility. Production preflight compiles the resulting
`@MainActor public func` in the same registry-bound module, the pinned invalid
client receives the native line/category diagnostic, and a legal
`@MainActor` client invokes the original runtime gateway once and returns
`42`.

This is compiler-preflight serialization, not a claim that actor storage or
executor enforcement is complete. M7 remains partial for synthetic member,
initializer, property, type, and extension stubs and target-aware project build
manifests; runtime actor isolation remains gated on M5. The focused
compiler/host-contract/upstream/generated board is GREEN at 35 tests. The
source-bound closing gate is GREEN over 888 tests, exact 88/88 runtime parity
cases and 1,722 repetitions, the 678/680 pinned corpus ratchet, 5/5 live
scenarios, and API parity at 345 match / 0 diverge / 0 interpreter errors / 17
unstable / 0 no-twin.

### M7 synthetic receiver-qualified host declarations

This gap-closure slice asks whether an interpreter-synthetic member carries the
same source isolation into compiled preflight as a native serialized member.
The oracle adds the unchanged swiftlang support input
`test/Concurrency/Inputs/GlobalVariables.swift` from release
`swift-6.3.3-RELEASE`, commit `064859e4…`, SHA-256 `cb2556b3…`. Its upstream
RUN line builds the support module in Swift 5; an unchanged Swift 6 client then
receives the line-4 error that main-actor-isolated static property
`actorInteger` cannot be referenced from a nonisolated context. The repository
client is bounded plumbing, while the declaration under test remains
byte-identical to swiftlang.

`CompilerPreflightHostModule` now owns module-only compiler arguments and
includes them in its manifest digest. The upstream support module therefore
uses its real Swift 5/minimal-concurrency serialization mode while the client
stays in Swift 6 complete strict-concurrency mode. A negative-control test uses
opposing `#if swift(...)` assertions in module and client, proving that the
module language mode does not leak into user-source preflight.

Before the production change, `HostSignature` rejected
`@MainActor func String.syntheticMember() -> Int` with `expected parameter
clause in function signature` and rejected `@MainActor static var
Globals.actorInteger: Int { get set }` with `expected '=' in variable`. The
focused tests captured both failures before implementation.

Receiver-qualified host contracts now pass through SwiftSyntax as valid member
declarations, preserving attributes, modifiers, parameters, defaults, generic
constraints, async/throwing function effects, property mutability, and return
types while removing only the runtime DSL's `Receiver.` qualifier. Production
preflight deterministically emits public extension stubs for instance/static
methods, initializers, and synchronous get/get-set properties. Explicitly
non-public members and async property accessors fail configuration; the next
slice below closes read-only throwing getters.

The pinned invalid client receives the native static-property isolation
diagnostic; a legal `@MainActor` program compiles and invokes the same typed
method/property registry contracts, returning `9` with one call to each
gateway.

This does not synthesize a nominal type or claim runtime actor enforcement.
M7 remains partial for per-overload Task API dispositions, synthetic enclosing
type declarations and attributes, async property accessors, and
target-aware build manifests. The focused compiler/host-contract/upstream and
generated board is GREEN at 40 tests, and `ConcurrencySurfaceGen --check` is
GREEN. A source-bound closing gate follows this ledger update.

### M7 throwing synthetic property getters

This gap-closure slice asks whether a receiver-qualified synthetic `get throws`
contract preserves the same access-site requirement as native Swift and then
executes through the typed runtime property. The minimal diagnostic fixture is
derived from swiftlang's
`test/Concurrency/actor_call_implicitly_async.swift` at release
`swift-6.3.3-RELEASE`, commit `064859e4…`. Apple Swift 6.3.3 rejects its line-8
read with the stable category that property access can throw but is not marked
with `try`; production preflight reports the same file, line, and category. No
scheduler order is involved.

Before the production change, composing
`var String.syntheticThrowingCount: Int { get throws }` failed with the explicit
configuration error that throwing accessors were not serializable. After stub
serialization was enabled, the same end-to-end test exposed a second RED: a
plain Swift `Error` from a legal throwing host getter escaped synchronous
`do/catch`. The shared synchronous statement boundary now catches arbitrary
host errors just like the suspending boundary while still rethrowing fatal
runtime errors and `InterpreterSessionAbort`.

Compiler stubs emit `get` with the exact SwiftSyntax effect spelling, preserving
both ordinary and typed throws. A legal client reads the property, the typed
`HostProperty` executes one success and one caught failure path, and invalid
effectful get/set registration fails closed because native Swift rejects a
setter paired with an async or throwing getter. Async synthetic getters remain
open because their runtime member boundary still needs a genuinely suspending
typed property contract; M7 also remains open for per-overload dispositions,
synthetic enclosing types/attributes, and target-aware project manifests.

The focused compiler/host-contract/upstream/diagnostic board is GREEN at 44
tests, `ConcurrencyMethodologyTests` is GREEN at 7 tests, and
`ConcurrencySurfaceGen --check` is GREEN. A source-bound closing gate follows.

### M7 async synthetic property getters

This slice closes the remaining synthetic accessor-effect gap without adding a
`Task.value` or application-specific branch. The compiler oracle is the
unchanged swiftlang
`test/Concurrency/effectful_properties_async_if_optional_unwrap.swift` from
release `swift-6.3.3-RELEASE`, commit `064859e4…`, SHA-256 `49d637f0…`.
Production preflight preserves its errors for ordinary reads, optional binding,
shorthand optional binding, and invalid `if let await` syntax. A separate
repository-owned client proves that a receiver-qualified serialized
`get async throws` still requires `await` and carries the native
`property access is 'async'` note across the generated-module boundary.

The RED had two independent parts: `CompilerPreflightHostModule` rejected every
async property as non-serializable, and `HostProperty` had no asynchronous
registration contract. Compiler stubs now reproduce the exact SwiftSyntax
getter effects (`async`, `async throws`, and typed throws where present).
`HostProperty(asyncGet:)` validates the receiver and result just like its
synchronous face, rejects synchronous declarations and effectful setters, and
tracks the getter as a runtime host operation.

Member lookup remains eager so existing source-extension, typed-registry, and
fallback precedence is unchanged. When lookup reaches an async typed property
beneath `await`, it returns an interpreter-private carrier that the async
overlay immediately resolves through a task-bound evaluation context. The
caller is observably `.waiting/.awaitingHost` while a controlled gate is
closed. Completion, arbitrary host errors, cancellation, nested member chains,
optional chaining, and instance/static properties all use the same path;
synchronous entry fails closed with `requires runAsync and await`.

This is a typed host-boundary and compiler-serialization claim. It does not
claim source-defined async computed-property execution, actor isolation, or
physical worker parallelism. M7 remains open only for per-overload generated
API dispositions, synthetic enclosing type declarations/attributes, and
target-aware project build manifests.

### M7 synthetic nominal type declarations and inherited attributes

The compiler boundary can now describe receiver types that exist only behind a
`HostRegistry`, without adding their runtime implementation to user source or
an SDK shim. The native oracle is the unchanged swiftlang support input
`test/Concurrency/Inputs/implicit_nonisolated_things.swift` from release
`swift-6.3.3-RELEASE`, commit `064859e4…`, SHA-256 `f4bd6452…`. A minimal
repository-owned client adds a method in an extension of its imported
`@MainActor` struct and calls that method from a synchronous `nonisolated`
function. Swift 6 emits `ActorIsolatedCall` at the call. The exact same client
and diagnostic are required when the imported nominal declaration is generated
from the interpreter registry.

The RED failed before client checking because preflight could emit only
extensions of types already present in the SDK or base host module.
`CompilerPreflightHostType` now parses one empty top-level struct, class, or
enum with SwiftSyntax, exports access-neutral declarations, and retains the
original attributes and modifiers. Generic, inherited, non-empty, non-public,
actor, protocol, and other unsupported forms fail during contract creation;
in particular this compiler-only surface does not pretend to provide the actor
storage or executor semantics owned by M5.

Composition deduplicates identical nominal contracts, rejects conflicting
declarations for the same name, orders output deterministically, and emits
nominals before unrelated extension stubs. Receiver-qualified typed members
for a synthetic type are placed inside that nominal body. Besides inheriting
type-level isolation correctly, this is required for a synthetic class's
designated `init()` because an extension initializer would collide with the
class's synthesized initializer. Existing SDK-backed receivers remain emitted
as extensions.

A production registry test then uses the same generated `@MainActor final class`
for native preflight while its constructor and typed get/set property
execute through the ordinary runtime registry, proving that compiler and
runtime contracts remain bound without forwarding execution to native Swift.
The focused compiler/host-contract/upstream/methodology board is GREEN at 52
tests, and the pinned-corpus sync reproduces the new support input byte for
byte. M7 remains partial only for per-overload generated API dispositions and
target-aware project build manifests.

### M7 authored Task-instance overload dispositions

The generated active-SDK denominator now has an authored claim for every one
of its 11 `Task` instance overload rows. The RED guard observed zero explicit
overrides and now requires the exact 11-row domain to stay fully reviewed; an
SDK inventory change also invalidates the existing SHA-256 pin before a new
row can inherit an accidental support claim.

Five rows are `runtime-supported` with `native-parity`: `cancel()`,
`isCancelled`, `result`, and both the nonthrowing and throwing `value`
overloads. Their evidence is the existing same-source Swift 6 differential
suite for cancellation, successful and failing values, `Result` outcomes,
waiter isolation, and repeated completed-handle reads. The unchanged swiftlang
`test/Concurrency/Runtime/async_task_handle_cancellation.swift` fixture remains
the independent upstream cancellation anchor, pinned at SHA-256 `5829b825…`.

The other six rows are not mislabeled as implemented merely because the
generator retained their declarations. `escalatePriority(to:)`, two deprecated
`get()` overloads, deprecated `getResult()`, `hash(into:)`, and `hashValue` are
`diagnosed-unsupported`. A focused executable test reads every unsupported
name through a real runtime task handle and requires the generated active-SDK
diagnostic. Metadata assertions separately retain both `get()` effect variants,
so name-level rejection cannot erase the per-overload denominator.

The resulting inventory is 5 native-parity runtime rows, 6 focused diagnosed
rows, and 139 still unreviewed rows. M7 therefore remains open for those 139
top-level, Task-static, and task-group dispositions plus target-aware project
build manifests. The focused upstream/runtime/methodology board is GREEN at 29
tests, five representative same-source parity cases pass 20 native and
interpreted repetitions each, and `ConcurrencySurfaceGen --check` is GREEN.

### M7 authored Task-static overload dispositions

The 21-row active-SDK `Task` static denominator is now reviewed independently
of its generated name routing. The RED guard found no authored static claims;
it now requires the exact domain to remain 21/21 reviewed and continues to
inherit the inventory SHA-256 stale check.

Six rows are fully `runtime-supported` with native parity: `checkCancellation`,
`currentPriority`, static `isCancelled`, positional nonthrowing `sleep(_:)`,
throwing `sleep(nanoseconds:)`, and `yield`. Existing same-source cases cover
cancelled checks, priority inheritance and donation, cancellation isolation,
sleep cancellation, and yield progress. The unchanged swiftlang
`taskgroup_cancelAll_cancellationHandler.swift` fixture is the independent
oracle for the subtle positional sleep effect: cancellation wakes it and stays
observable without being rethrown.

Twelve rows are `diagnosed-unsupported`: task equality, the deprecated
`CancellationError`, `runDetached`, `suspend`, `withCancellationHandler`, and
`withGroup` spellings, `basePriority`, `name`, both custom-executor detached
overloads, and deadline-based `sleep(until:)`. Focused tests retain overload
counts and effect metadata, then require real interpreter diagnostics for each
name or call shape.

The two ordinary detached overloads and `sleep(for:)` are deliberately
`known-divergence`, not positive claims. Their core operation forms work, but
the runtime currently ignores a supplied task name and explicit sleep
tolerance/custom clock respectively. Recording these three partial overloads
prevents generated routing or default-argument happy paths from overstating
support.

Across both Task domains, 32/32 rows are now authored: 11 runtime-supported,
18 diagnosed-unsupported, and 3 known divergences. The total generated
inventory leaves 118 unreviewed top-level and task-group rows, plus the
target-aware project-manifest gap. The focused generated/upstream/methodology
board is GREEN at 22 tests, eight representative same-source parity cases pass
20 native and interpreted repetitions each, and the generator check is GREEN.

### M4 generated task-group state-property dispositions

The first task-group accounting slice reviews the exact eight active-SDK
`isEmpty` and `isCancelled` rows across `TaskGroup`, `ThrowingTaskGroup`,
`DiscardingTaskGroup`, and `ThrowingDiscardingTaskGroup`. Its RED guard found
zero authored rows and now requires the four expected containers and all eight
stable declaration IDs to retain explicit dispositions.

One same-source Swift 6 probe covers every container. Each group starts empty
and active, receives a child held in a cancellable 30-second sleep, becomes
nonempty, transitions to cancelled through `cancelAll()`, and becomes empty
again after explicit result consumption or discarding-group automatic
consumption. The sleep forces the post-add observation without asserting which
executor starts first. Twenty native and twenty interpreter processes produced
the same exact four summaries.

The ordinary `TaskGroup.isEmpty` row also retains the unchanged swiftlang
`test/Concurrency/Runtime/async_taskgroup_is_empty.swift` as an independent
pinned oracle. That upstream test establishes the new, outstanding, and drained
states through the original FileCheck expectations; the broader repository
probe does not pretend that one ordinary-group test proves the other three
containers.

All eight rows are therefore `runtime-supported` with `native-parity`. Across
the generated inventory, 40/150 rows now have authored dispositions: 19
runtime-supported, 18 diagnosed-unsupported, and 3 known divergences. The
remaining 110 top-level and task-group rows stay unreviewed; repeated-wait/new-
work behavior and the other generated group overloads remain explicit M4/M7
work.

### M4 generated task-group `cancelAll()` dispositions

The adjacent four-row slice reviews `cancelAll()` on the same ordinary,
throwing, discarding, and throwing-discarding group containers. The RED guard
observed zero authored claims, then locked the active SDK denominator to the
four expected declarations.

No new runtime mechanism was necessary. The existing four-kind same-source
probe calls `cancelAll()` with one outstanding sleeping child in every group,
observes the group's cancelled state, drains or automatically consumes the
child, and exits empty. Its 20 native and 20 interpreter processes establish
the common operation without relying on scheduler order. The ordinary row also
cites unchanged swiftlang
`test/Concurrency/Runtime/taskgroup_cancelAll_cancellationHandler.swift`,
pinned at SHA-256 `1bb8aa78…`; that test independently proves that group
cancellation reaches the child without firing the owner's cancellation
handler.

All four declarations are `runtime-supported` with `native-parity`. Generated
accounting is now 44/150 reviewed: 23 runtime-supported, 18
diagnosed-unsupported, 3 known divergences, and 106 unreviewed rows.

### M4 generated task-group `waitForAll(isolation:)` dispositions

The two-row wait slice preserves the active interface's semantic split instead
of treating generated name routing as proof: `TaskGroup.waitForAll` is async
and nonthrowing, while `ThrowingTaskGroup.waitForAll` is async throwing. The RED
guard found zero authored rows and now fixes both containers and declaration
IDs; focused generated-surface assertions retain both effects and their
`isolation` parameter.

Nine same-source Swift 6 fixtures supply the runtime oracle. The
nonthrowing cases prove joining and consumption of all remaining outcomes. The
throwing cases separately cover empty and multi-success groups, one and
multiple source failures, first-completion-ordered error retention, full drain,
and child cancellation projected as `CancellationError` without cancelling the
owner. Each fixture asserts program-order or gate-forced facts rather than
ready-task scheduler order. The added explicit-isolation fixture passes
`MainActor.shared` to both overloads, forces each wait to suspend behind a
source gate, and verifies MainActor entry and resumption in 20 native and 20
interpreter processes.

The compiler-side anchor is the unchanged swiftlang
`test/Concurrency/async_task_groups_and_actors.swift` from the pinned
`swift-6.3.3-RELEASE` commit, SHA-256 `85a2cc34…`. Production preflight accepts
its ordinary, throwing, and discarding groups inside MainActor-isolated code.
This establishes the supported default and explicit-MainActor boundary, but
not arbitrary source-defined actor executors. Both complete any-Actor rows are
therefore retained as `known-divergence` until M5 supplies actor identity and
executor dispatch. Generated accounting is now 46/150 reviewed: 23
runtime-supported, 18 diagnosed-unsupported, 5 known divergences, and 104
unreviewed rows.

The explicit-MainActor case is GREEN for 20 native and 20 interpreted
processes with native observation SHA-256 `ed4685de…`. The combined generated
surface, methodology, and complete pinned-swiftlang board is GREEN at 25 tests;
the generator check and fail-closed capability-accounting validator are also
GREEN.

### M4 generated `ThrowingTaskGroup.nextResult(isolation:)` disposition

The one-row `nextResult` slice began with an executable RED from both a local
same-source probe and unchanged swiftlang
`test/Concurrency/Runtime/async_taskgroup_throw_recover.swift`: the generated
surface retained the declaration, but runtime lookup reported that it was not
supported. The upstream file is copied byte-for-byte from the pinned
`swift-6.3.3-RELEASE` commit at SHA-256 `dd9e32b8…`; twenty strict Swift 6
native executions stably recover from a child failure through a nonthrowing
`Result.failure` before consuming a later successful child.

The reusable group intrinsic now consumes one outcome from the existing
completion queue and wraps that exact source success, failure, or cancellation
in the same `Result` carrier used by `Task.result`. It does not project failure
as interpreter control flow. The local fixture independently covers an empty
group, successful value, source error, `CancellationError`, owner cancellation
state, single consumption, and explicit `MainActor.shared` resumption. It is
GREEN in all 20 native/interpreted repetitions with parity observation SHA-256
`dfab7c8f…`; the unchanged swiftlang executable is also admitted to the pinned
corpus.

The implementation deliberately makes no arbitrary-actor claim. The complete
SDK declaration accepts `isolated any Actor`, so the authored row remains
`known-divergence` until M5 provides actor identity and executor dispatch even
though its default and explicit-MainActor behavior now has native parity.
Generated accounting is 47/150 reviewed: 23 runtime-supported, 18
diagnosed-unsupported, 6 known divergences, and 103 unreviewed rows.

### M4 deprecated task-group `spawn(priority:operation:)` dispositions

The two generated `spawn` rows are historical aliases for unconditional child
creation on `TaskGroup` and `ThrowingTaskGroup`. A same-source probe passes an
explicit `.high` argument through both aliases, consumes each successful value,
and then proves source-error projection from a throwing child. It deliberately
does not assert the child's exact effective priority: the current native runtime
reports the inherited parent priority here, not `.high`. It is GREEN in all 20
native and interpreted processes with exact output
`ordinary-value|throwing-value:failure-child` and native observation SHA-256
`d76e2a8105f10f58b13941ecca44418834d128d22775283563c5dd6a04508186`.

An independent unchanged oracle comes from swiftlang
`test/Concurrency/Runtime/async_taskgroup_is_asyncsequence.swift`, copied
byte-for-byte from the pinned `swift-6.3.3-RELEASE` commit at SHA-256
`46a6aec7…`. It creates ten children through each ordinary and throwing
`spawn` alias, drains them through async iteration, and asserts only stable
result sums rather than scheduler order. Twenty strict Swift 6 native runs
completed successfully, and the complete 22-case executable upstream board is
GREEN in the interpreter.

No new alias-specific runtime path was required: both declarations already
route through the generated `addTask` intrinsic, so this slice records and
locks the shared mechanism instead of duplicating behavior. Both rows are
`runtime-supported` with `native-parity`. Generated accounting is 49/150
reviewed: 25 runtime-supported, 18 diagnosed-unsupported, 6 known divergences,
and 101 unreviewed rows.

### M4 deprecated task-group `async(priority:operation:)` dispositions

The next two-row historical alias family uses the same unconditional group-child
creation contract as `spawn`. The same-source probe invokes ordinary and
throwing `async` with an explicit `.high` argument, consumes both successful
values, and projects a source error from a later throwing child. As with
`spawn`, exact effective child priority is not part of the claim. Twenty strict
Swift 6 native and interpreted repetitions are exact at
`ordinary-value|throwing-value:failure-child`, with native observation SHA-256
`dd2d3b28f286d597b519c4904cb888ee5f2af2b0accf84bee441ba55e5d1616c`.

The ordinary row also cites the unchanged pinned swiftlang
`test/Concurrency/Runtime/async_taskgroup_is_empty.swift`, SHA-256
`46c4c047…`. That independent oracle uses the default-priority `group.async`
spelling and proves the child makes the group nonempty before its result is
consumed. The throwing spelling is covered by the local probe because the
upstream test uses only `TaskGroup`.

Both generated declarations already route through `addTask`; no duplicate
alias implementation was introduced. They are `runtime-supported` with
`native-parity`. Generated accounting is 51/150 reviewed: 27
runtime-supported, 18 diagnosed-unsupported, 6 known divergences, and 99
unreviewed rows.

### M4 explicit task-group iterator dispositions

This slice begins with the two ordinary/throwing `makeAsyncIterator()` rows and
expands the generated denominator to the six public members on their nested
`Iterator` types: two `cancel()` declarations and default plus isolated `next`
overloads for both group kinds. A strict Swift 6 probe exposed an important
compiler boundary: calling default `iterator.next()` from a MainActor-isolated
probe is rejected because sending the mutable iterator may race. The fixture
therefore tests default `next()` in a nonisolated function and tests the modern
overloads explicitly with `next(isolation: MainActor.shared)`.

The initial interpreter RED was the generated-surface diagnostic that
`TaskGroup.makeAsyncIterator` was declared by the active
`_Concurrency.swiftinterface` but unsupported. A first implementation then
revealed a deeper native contract: an iterator is permanently terminal after
`nil`, `cancel()`, or a thrown `next`, even when later work is added to the
group. Iterator copies have independent terminal flags while sharing the
group's exactly-once completion queue. The generated active interface also
shows `finished` storage and public `cancel()` on both iterator types.

The reusable implementation therefore uses generated nested-iterator dispatch
rather than raw member-name checks. Its source iterator carrier adopts the
interpreter's host value-semantics protocol and copies `{group, finished}` at
Swift storage boundaries. `next` preserves owner/lifetime checks, consumes the
existing group queue, and marks only that iterator value terminal on nil or
error. `cancel` marks that iterator terminal, requests group cancellation, and
cancels children; a copied iterator retains its own terminal state while still
observing the shared group's cancellation.

Twenty strict Swift 6 native and interpreted repetitions are exact at
`default:5:6|shared:3|terminal:nil:nil:42|copy:nil:7:nil|throwing:failure-child:nil:9|cancel:cancelled:nil:rejected:cancelled:nil:rejected`,
with native observation SHA-256
`947e1cea23ffcad0de409eaa81cd2134a2acec6a742830a7e7b3051954647630`.
The shared result is a sum, so scheduler order is deliberately unobserved. The
probe covers both default overloads, explicit MainActor next, iterator/group
interleaving, terminal-after-new-work, copy independence, source-error
terminality, both cancel declarations, and rejection of new conditional work.

The unchanged pinned swiftlang oracle
`test/Concurrency/Runtime/async_taskgroup_is_asyncsequence.swift`, SHA-256
`46a6aec7…`, independently drains ordinary and throwing groups while asserting
stable sums. In interpreted execution that fixture uses the existing direct
task-group iteration path, so it is independent semantic evidence rather than
adapter coverage; the explicit differential fixture carries all maker/iterator
claims. The two isolated `next` rows remain known divergences for arbitrary
actors despite explicit MainActor parity. Generated accounting is 59/156
reviewed: 33 runtime-supported, 18 diagnosed-unsupported, 8 known divergences,
and 97 unreviewed rows.

### M4 deprecated task-group `add(priority:operation:)` dispositions

The two remaining deprecated `add` rows are the async conditional-child aliases
on `TaskGroup` and `ThrowingTaskGroup`. The active SDK
`_Concurrency.swiftinterface` bodies forward them directly to
`addTaskUnlessCancelled(priority:operation:)`, including the supplied priority.
The initial capability-accounting test was RED because neither generated row
had an authored disposition; runtime dispatch itself already reached the shared
generated conditional-child intrinsic, so no alias-specific implementation was
added.

Strict Swift 6 compilation also defines the probe boundary. Invoking this async
mutating API from the earlier `@MainActor` fixture shape is rejected because
sending the task-group value risks a data race, so the valid same-source probe
is nonisolated. It passes `.high` to exercise the complete declaration spelling
but makes no exact effective-priority claim: native execution of this context
does not make `Task.currentPriority == .high` a stable fact.

The ordinary group returns `true`, delivers its value, then returns `false` and
leaves no result after `cancelAll()`. The throwing group additionally accepts a
failing child and projects the exact source error before proving the same
post-cancellation rejection and empty tail. Twenty strict Swift 6 native and
interpreted repetitions are exact at
`ordinary-accepted:ordinary-value:ordinary-rejected:ordinary-empty|throwing-accepted:throwing-value:failure-accepted:failure-child:throwing-rejected:throwing-empty`,
with native observation SHA-256
`4eff45aa765e927d5dc18a417bb62441436a6e81f7c0b8c9a918d307201d5a5c`.

The unchanged pinned swiftlang oracle
`test/Concurrency/Runtime/async_taskgroup_addUnlessCancelled.swift`, SHA-256
`2c5673f63a67f2f0d02f8770c42519ca6dfee101a78fafc4dd6fa14d79e0ed00`,
independently proves rejection after owner cancellation for the shared modern
primitive. It is supporting semantic evidence rather than direct deprecated
alias coverage; the local same-source fixture carries both `add` declarations
and the throwing-error claim. Generated accounting is 61/156 reviewed: 35
runtime-supported, 18 diagnosed-unsupported, 8 known divergences, and 95
unreviewed rows.

### M4 deprecated task-group `asyncUnlessCancelled` dispositions

The next two generated rows are the synchronous legacy conditional-child
aliases on `TaskGroup` and `ThrowingTaskGroup`. Their active SDK
`_Concurrency.swiftinterface` bodies directly return
`addTaskUnlessCancelled(priority:operation:)`. The initial denominator test was
RED with both exact capability IDs absent from authored status. Generated
dispatch already routes the ordinary and throwing spellings to the shared
conditional-child intrinsic, so the repair is an evidence/accounting closure,
not a duplicate runtime path or an API-name special case.

The strict Swift 6 boundary is narrower than the modern overloads: the legacy
operation is plain `@Sendable`, without actor-context inheritance. A
MainActor-isolated caller may invoke the synchronous alias with an independent
closure, but directly capturing isolated mutable state is rejected. The probe
therefore observes values and errors only. It passes `.high` to exercise
priority forwarding while making no claim that effective child priority equals
the request.

For both group kinds the alias returns `true` while active and delivers the
accepted child outcome. The throwing spelling accepts a failing child and
projects the exact source error from `next()`. After `cancelAll()`, both return
`false` and leave the completion stream empty. Twenty strict Swift 6 native
and interpreted repetitions are exact at
`ordinary-accepted:ordinary-value:ordinary-rejected:ordinary-empty|throwing-accepted:throwing-value:failure-accepted:failure-child:throwing-rejected:throwing-empty`,
with native observation SHA-256
`ac4b3a3949d55150dd975fb344c5dac0ca078834e135b02eebf5b6cd13d157da`.

The unchanged pinned swiftlang oracle
`test/Concurrency/Runtime/async_taskgroup_addUnlessCancelled.swift`, SHA-256
`2c5673f63a67f2f0d02f8770c42519ca6dfee101a78fafc4dd6fa14d79e0ed00`,
independently proves post-owner-cancellation rejection by the shared modern
primitive. It does not directly cover this deprecated spelling or the throwing
group; the local same-source fixture carries those claims. Generated accounting
is 63/156 reviewed: 37 runtime-supported, 18 diagnosed-unsupported, 8 known
divergences, and 93 unreviewed rows.

### M4 deprecated task-group `spawnUnlessCancelled` dispositions

The final two legacy conditional aliases are `spawnUnlessCancelled` on
`TaskGroup` and `ThrowingTaskGroup`. Both active SDK interface bodies
directly return `addTaskUnlessCancelled(priority:operation:)`, and generated
dispatch maps both receivers to the shared intrinsic. The initial denominator
test was RED because neither exact capability ID had an authored disposition;
no new runtime primitive or spelling-specific branch was needed.

The ordinary row is anchored directly by unchanged swiftlang source
`test/Concurrency/Runtime/async_taskgroup_cancel_then_spawn.swift`, copied at
SHA-256
`29866ac0f6d2db635787262db5186c5bb493e137c850451396d368adcdc961ed`.
Its unused `import Dispatch` is deliberately retained. Twenty strict Swift 6
native/interpreted trials were stable with observation SHA-256
`915499842d28675e50fc961dd124daccb615812f955f1ba16d7fca360db77151`:
conditional spawn returns `true` and delivers `1` before cancellation, returns
`false` with `nil` afterward, while unconditional `spawn` still creates a
child that observes cancellation and returns `3`. The upstream inventory now
classifies this unchanged file as direct, raising its fail-closed allowlist from
11 to 12 runtime fixtures.

The upstream file has no throwing-group spelling, so a minimal local
same-source probe carries that row. It accepts and delivers a successful child,
accepts a failing child and projects the exact source error, then returns
`false` with an empty tail after `cancelAll()`. It passes `.high` without
claiming exact effective priority. Twenty strict Swift 6 native and interpreted
repetitions are exact at
`throwing-accepted:throwing-value:failure-accepted:failure-child:throwing-rejected:throwing-empty`,
with native observation SHA-256
`3ae35734ca3c59114fb554b76c5d5a1ad78c1da58d038cfe8556ac4419ceacc2`.

Together the unchanged upstream oracle and focused throwing fixture cover both
generated aliases without duplicating the ordinary scenario locally. Generated
accounting is 65/156 reviewed: 39 runtime-supported, 18 diagnosed-unsupported,
8 known divergences, and 91 unreviewed rows.

### M4 task-group `next` overload dispositions

The active SDK exposes four group-level `next` declarations: ordinary and
throwing modern overloads with
`isolation: isolated (any Actor)? = #isolation`, plus two declaration-only
`@_disfavoredOverload` zero-argument compatibility entries. Generated routing
maps all four to the existing shared completion-queue intrinsic, but routing
alone is not support evidence.

Strict Swift 6 SIL establishes the overload split. A direct `group.next()` call
selects the modern `next(isolation:)` declaration and supplies `#isolation`.
The same-source probe forces each legacy entry through a local protocol whose
requirement has the exact zero-argument async signature; the resulting witness
calls name the distinct legacy ABI symbols. This avoids falsely crediting the
compatibility rows from an ordinary no-argument source call.

The probe covers empty groups, successful values, exactly-once drain, source
failure and recovery, cancellation projection, an unconditional child added
after `cancelAll()`, modern default isolation, explicit `nil` from nonisolated
code, and explicit `MainActor.shared`. Its MainActor path also suspends in
`next`, cancels the owner, and observes group/child cancellation before the
owner resumes. Twenty strict native and twenty process-isolated interpreted
runs are exact, with native observation SHA-256
`1b975a0c0bbc615fc5a5b7a1e2c2e576bd2b73a5a17eff11f6f20bc1c16ddaf0`.

Pinned unchanged swiftlang tests provide independent modern-overload evidence:
`async_taskgroup_next_on_pending.swift` (SHA-256 `d112c3e1…`) waits for and
drains pending ordinary children, while `async_taskgroup_throw_recover.swift`
(SHA-256 `dd9e32b8…`) catches a child failure and consumes later work. Compiler
AST inspection confirms their plain `next()` calls also select the modern
defaulted-isolation overload. The broader upstream
`async_taskgroup_asynciterator_semantics.swift` (SHA-256 `3d5f1c81…`) remains
`needs-adapter`: its `next` sections match after diagnostic substitution, but
the unchanged file also requires currently unsupported `Int.isMultiple(of:)`
and `TaskGroup.contains`, so it is not admitted under a narrower claim.

The two legacy rows are `runtime-supported` with `native-parity`. The modern
rows retain `known-divergence`: default, explicit-nil, and explicit-MainActor
behavior are covered, but arbitrary source-defined actor executors are not yet
modeled. Generated accounting is 69/156 reviewed: 41 runtime-supported, 18
diagnosed-unsupported, 10 known divergences, and 87 unreviewed rows.

### M4 canonical task-group `addTask` dispositions

The next generated slice is the four canonical
`addTask(priority:operation:)` declarations on `TaskGroup`,
`ThrowingTaskGroup`, `DiscardingTaskGroup`, and
`ThrowingDiscardingTaskGroup`. It deliberately excludes the named and
executor-preference overloads: the current member adapter does not implement
either of those extra contracts. The initial exact-denominator test was RED
with all four capability IDs absent from authored status.

The existing four-kind same-source fixture is direct evidence for this slice.
Compiling it with the active toolchain under Swift 6 complete concurrency and
inspecting SIL produces one `function_ref` to each exact canonical declaration;
none of the named or executor-preference symbols is selected. A native run
returns
`ordinary=true:false:false:false:true:true|throwing=true:false:false:false:true:true|discarding=true:false:false:false:true:true|throwing-discarding=true:false:false:false:true:true`.
The latest twenty-repetition native observation digest is
`c16880612a4fceb5925349d75ac1e17da3fd167a9b48ba6d2ef931e259d99384`.
The probe covers unconditional child creation, cancellation observation,
explicit result consumption for result-producing groups, automatic consumption
for discarding groups, and terminal drain. Existing same-source throwing-group
and focused throwing-discarding tests additionally cover child-error
projection.

All four rows remain `known-divergence`, not `runtime-supported`. Their source
signatures accept `sending @isolated(any)` operations, while the interpreter
currently begins group children on its cooperative executor and has no general
source-defined actor executor to carry arbitrary closure isolation. The tested
nonisolated subset is equivalent; the complete contract belongs to the M5
executor architecture. Generated accounting is now 73/156 reviewed: 41
runtime-supported, 18 diagnosed-unsupported, 14 known divergences, and 83
unreviewed rows.

### M4 canonical task-group `addTaskUnlessCancelled` dispositions

The adjacent four-row slice covers the canonical
`addTaskUnlessCancelled(priority:operation:)` declaration on every task-group
kind. The exact-denominator test began RED with all four active-SDK capability
IDs absent. Named and executor-preference overloads remain outside this slice
because they add contracts that the current member adapter does not implement.

The existing ordinary-group differential fixture now exercises all four
receivers without adding another process-heavy parity case. Each active group
accepts `.high` work, while the assertion deliberately makes no effective-
priority claim. Result-producing groups consume their values, the throwing
group also projects an exact source error, and discarding groups wait until
automatic consumption makes them empty. After `cancelAll()`, every receiver
returns `false` and has an empty tail. All calls in strict Swift 6 SIL resolve
to the four canonical declarations; no named or executor-preference overload
is selected.

Twenty strict native and twenty process-isolated interpreted runs are exact at
`ordinary-accepted:ordinary-value:ordinary-rejected:ordinary-empty|throwing-accepted:throwing-value:failure-accepted:failure-child:throwing-rejected:throwing-empty|discarding-accepted:discarding-drained:discarding-rejected:discarding-empty|throwing-discarding-accepted:throwing-discarding-drained:throwing-discarding-rejected:throwing-discarding-empty`,
with native observation SHA-256
`737e4ac09ce7d91323a033ec1ea5222bd583b527c0c0006dc1d5d042db0a5b58`.
The broader throwing-discarding child-error path remains covered by the shared
runtime primitive's focused test.

These four rows are also `known-divergence`. Their active-SDK bodies preserve
the `sending @isolated(any)` operation's serial executor, whereas the current
interpreter supports the observed nonisolated subset but cannot enqueue on an
arbitrary source-defined actor executor. Generated accounting is now 77/156
reviewed: 41 runtime-supported, 18 diagnosed-unsupported, 18 known
divergences, and 79 unreviewed rows.

### M7 compiler ABI exclusions and the public job-testing hook

The active SDK contributes exactly 27 unreviewed underscore-prefixed top-level
rows, but the prefix is not itself a disposition rule. The initial
characterization test pins all 27 capability IDs, requires the absence of a
runtime adapter, and was RED because none had authored status.

Twenty-six rows are compiler/runtime ABI rather than source-level interpreter
APIs. Fifteen are lowering and lifecycle entry points: async-let storage,
future wait, cancellation, task-group wait, actor initialization/destruction,
executor checking, and related `Builtin` or `@_silgen_name` hooks. The active
interface body of `_abiEnableAwaitContinuation` deliberately traps with
`never use this function`. The other eleven are
`@_unsafeInheritExecutor` legacy/back-deployment symbol twins of public
nonunderscored continuation, cancellation-handler, task-executor-preference,
and task-group APIs. These 26 exact IDs are now
`excluded-compiler-abi`; no prefix-based generator rule can silently classify
a future SDK declaration.

The twenty-seventh row is intentionally different. Real Swift 6 complete-
concurrency preflight accepts a direct
`_swift_createJobForTestingOnly {}` call and gives it the public
`ExecutorJob` result. It is therefore `deferred` under M9's executor-job and
physical-parallelism work, not hidden as compiler ABI. The checked-in preflight
test preserves that distinction against future SDK drift.

Generated accounting is now 104/156 reviewed: 41 runtime-supported, 18
diagnosed-unsupported, 18 known divergences, 26 excluded compiler ABI, one
deferred, and 52 unreviewed source-facing rows.

### M3/M7 public cancellation-handler overload dispositions

The next two-row characterization asks whether the public deprecated
`withTaskCancellationHandler(handler:operation:)` spelling shares the active-
cancellation guarantees already established for the modern
`operation:onCancel:isolation:` spelling. Generated routing already attached
both rows to one cancellation-handler intrinsic, and its runtime adapter
accepted both label forms, so no production RED or production change was
invented.

The existing same-source active-handler fixture now selects both declarations.
The deprecated operation enters a controlled suspension before the controller
cancels it; the modern operation retains its MainActor serialization barrier.
In each path the handler runs before `cancel()` returns, runs once across two
cancellation requests, and observes the uncancelled controller's dynamic
context. Strict Swift 6 complete-concurrency SIL contains distinct
`function_ref` entries for the exact `handler:operation:` and
`operation:onCancel:isolation:` symbols.

Twenty Apple Swift 6.3.3 native and twenty fresh-process interpreted runs are
exact at
`deprecated[0,1,1,false,done]|modern[0,1,1,false,true,done]`, with native
observation SHA-256
`ffe6f2b5614ca757a345bea0e62e3a5b6b70fdc4bf4d0de0228fa4cb20ae6741`.
The controlled barriers establish the compared edges; no order between
independently ready tasks is asserted.

The deprecated row is `runtime-supported` with `native-parity`. The modern
row remains `known-divergence`: its default-isolation subset also has the
existing pre-cancelled, nested, throwing, and scope-exit evidence, but the
runtime deliberately diagnoses an explicitly supplied `isolation:` until M5
provides arbitrary actor executors and resume ownership. Generated accounting
is now 106/156 reviewed: 42 runtime-supported, 18 diagnosed-unsupported, 19
known divergences, 26 excluded compiler ABI, one deferred, and 50 unreviewed
source-facing rows.

### M4/M7 public task-group scope dispositions

The four public top-level scope functions are a distinct active-SDK
denominator from their group member operations:
`withTaskGroup`, `withThrowingTaskGroup`, `withDiscardingTaskGroup`, and
`withThrowingDiscardingTaskGroup`. This characterization asks which exact
declarations ordinary source selects and whether their default-isolation
subset matches the already shared task-group runtime. Generated routing and
runtime behavior were already GREEN, so no production failure or production
change was fabricated.

The existing four-kind `task-group-state-properties.swift` source invokes all
four scopes. Apple Swift 6.3.3 in complete strict-concurrency mode emits one
SIL `function_ref` for each exact `returning:isolation:body:` declaration
(including `of:` for the result-producing groups). Twenty native and twenty
fresh-process interpreted runs remain exact at
`ordinary=true:false:false:false:true:true|throwing=true:false:false:false:true:true|discarding=true:false:false:false:true:true|throwing-discarding=true:false:false:false:true:true`,
with native observation SHA-256
`c16880612a4fceb5925349d75ac1e17da3fd167a9b48ba6d2ef931e259d99384`.
Existing throwing and throwing-discarding evidence additionally covers child
failure, body failure, cancellation, drain, join, and cleanup. No relative
order between independently ready children is asserted.

All four rows are `known-divergence`, not `runtime-supported`. Omitting the
defaulted isolation exercises the supported subset, while the complete
signatures accept an arbitrary isolated actor and require resume ownership on
that actor executor. The interpreter deliberately rejects an explicit
`isolation:` until M5 supplies that architecture. Generated accounting is now
110/156 reviewed: 42 runtime-supported, 18 diagnosed-unsupported, 23 known
divergences, 26 excluded compiler ABI, one deferred, and 46 unreviewed
source-facing rows.

### M4/M7 named task-group add overload dispositions

The active SDK exposes eight group-member rows that add a `name:` parameter
without adding `executorPreference:`: `addTask` and
`addTaskUnlessCancelled` on each of `TaskGroup`, `ThrowingTaskGroup`,
`DiscardingTaskGroup`, and `ThrowingDiscardingTaskGroup`. They are a separate
denominator from both the canonical unnamed rows and the executor-preference
rows.

Apple Swift 6.3.3 in complete strict-concurrency mode compiles the same-source
`task-group-named-add.swift` probe against exactly those eight
`name:priority:operation:` overloads. Each accepted child reads `Task.name`,
and twenty native observations are exact at
`discarding-add|discarding-unless|ordinary-add|ordinary-unless|throwing-add|throwing-discarding-add|throwing-discarding-unless|throwing-unless`,
with 20-line SHA-256
`64b1d3c13531aa02c723b77b5984c6f357aa716ef50d7c4b4772e065f1babc54`.
The output is sorted before comparison, so scheduler order is outside the
claim. The matching isolated differential shard completed all twenty
fresh-process interpreter repetitions with receipt digest
`376caa37b31e12dabecdc1b310467df8b524a38d5f8b1361600c8225dfa0cb09`.

All eight rows remain `known-divergence` because their complete signatures
retain the arbitrary `@isolated(any)` executor gap. Their supported
nonisolated subset no longer has a name gap: the shared group adapter decodes
`name:`, stores it on the child runtime task record, and the generated
`Task.name` property reads that task-owned value. The same path preserves
conditional acceptance, draining, and result delivery for every group kind;
it does not add a group-API special case. Rejection after cancellation remains
covered by the existing conditional-add fixtures, while this exact
same-source probe is the name-preservation evidence for all eight rows.

Generated accounting after the `Task.name` disposition is still 118/156
reviewed: 43 runtime-supported, 17 diagnosed-unsupported, 31 known
divergences, 26 excluded compiler ABI, one deferred, and 38 unreviewed
source-facing rows.

### M2/M4/M7 task-owned `Task.name`

The next gap asks whether `Task.name` is immutable metadata of the currently
executing task rather than a property of the source handle or the physical
native driver. The minimal same-source `task-name.swift` probe observes the
root task, ordinary and detached tasks, nonnil and explicit-`nil` computed
optional arguments, a named parent with an unnamed child, an empty-string
name, and named plus unnamed ordinary task-group children.

Compiled with Apple Swift 6.3.3 in Swift 6 complete strict-concurrency mode,
twenty native runs produced the exact result
`nil|ordinary|optional|nil|parent/nil|detached|empty|group,nil`. The 20-line
native observation SHA-256 is
`1d95a0094e23238160ce73c3aec1702045d7a2aec4a2f456ada8ba06b882e659`.
This establishes that both an omitted name and an explicitly supplied
optional `nil` remain `nil` rather than inheriting, a nonnil optional payload
is accepted, and an empty string is distinct from `nil`. Every created handle
is awaited and the two group results are sorted, so the assertion makes no
claim about ready-task order, physical thread identity, or parallel
execution.

Before the production change, the focused interpreted differential captured
the intended RED at generated static-member dispatch:
`Task.name is declared by the active _Concurrency.swiftinterface but is not
supported yet`. The repair is one construct-level mechanism. Each
`RuntimeTaskRecord` now owns an immutable `String?` name; every runtime task
creator supplies it explicitly, with root, host-callback, async-let, and other
unnamed paths supplying `nil`. Ordinary, detached, and task-group creation
decode the source `String?` once, preserve an empty payload, and store it on
the new record without inheriting the creator's name. Generated `Task.name`
dispatch reads the logical current record, never the native driver task. A
named task created through the legacy synchronous compatibility entry is
rejected instead of silently running under the creator's record.

Focused GREEN evidence, without a full-gate claim:

- the isolated `task-name` parity shard completed all twenty fresh-process
  interpreter repetitions at the exact native value, with receipt digest
  `e9474ae01b83c41d6f2743bfc919cb6f0d7214198a0020aae94b596f8f26ec60`;
- `GeneratedTaskSurfaceTests` passed all seven tests, proving that generated
  metadata routes `Task.name`, no longer classifies it as unsupported, and
  rejects named creation through synchronous compatibility; and
- all three `ConcurrencySurfaceGeneratorTests` plus
  `ConcurrencySurfaceGen --check` passed with the checked-in active-SDK
  surface and capability inventory; and
- the combined task-completion, task-cancellation, and cancellation-race
  focused run passed all eleven tests, including immutable record ownership
  and completed-task record/driver release.

The broader async evaluator, host-signature, and task-group regression board
also passed all 98 tests. The full source-bound repository gate is deliberately
reserved for the coherent closeout batch and is not claimed by this slice.

The `Task.name` declaration is therefore promoted from
`diagnosed-unsupported`/`focused-only` to
`runtime-supported`/`native-parity`. The eight named group declarations stay
`known-divergence` only for their arbitrary-actor executor semantics; their
supported nonisolated subset preserves the supplied task name.

### M2/M7 deprecated top-level `async` overloads

The next generated-surface question is whether both deprecated global
`async(priority:operation:)` overloads are merely source spellings for ordinary
unstructured task creation: do they return task handles before their operations
finish, preserve explicit priority, leave the task unnamed, return a successful
value, and project a thrown source error through the throwing handle?

The minimal same-source `top-level-async.swift` fixture creates the successful
task inside a synchronous MainActor function and holds its operation behind an
explicit MainActor gate. Apple Swift 6.3.3 compiled both overloads in Swift 6
complete strict-concurrency mode with only their expected deprecation warnings.
Twenty native runs produced the exact result `value:nil|17|boom`; the raw
20-line SHA-256 is
`dfd727fabc13cc01f9cb45cf42373b480d109c7c1b74c008dc719395207f8dfc`.
The gate proves that the task survives its creating function and captures the
utility priority before awaiting its handle can donate priority. The claim does
not choose a ready-task start order, physical worker, or arbitrary actor
executor.

Before the production change, the isolated interpreted run captured the RED
`unresolved identifier 'async'`. Both declarations were present in the active
SDK inventory but had no generated runtime route, so identifier resolution
could not reach the existing unstructured-task primitive.

The generator now maps source spellings to semantic intrinsics: both `async`
rows route to the reusable `unstructuredTask` intrinsic rather than adding an
API-specific runtime. Its global adapter decodes the existing priority and
operation arguments and calls canonical ordinary task creation with `name:
nil`. That path preserves runtime ownership, parent lineage, priority and
context inheritance, completion, failure, cancellation, and handle waiting.
Synchronous compatibility entry fails closed with `Task creation requires
runAsync` instead of executing the operation inline.

The final isolated differential completed all twenty fresh-process interpreted
repetitions at the native value, with receipt digest
`bcb582d7b32a424532328837604c5ed31c490ac763e5cbc0bd8d72c23f4c7a0c`.
Focused generator, runtime-surface, methodology, and accounting checks cover
the shared route and both exact active-SDK signatures; the full repository gate
remains reserved for the coherent closeout batch.

Both generated rows are recorded as `known-divergence` rather than
`runtime-supported`: their complete signatures carry `_inheritActorContext`
and `@isolated(any)`, while arbitrary source-defined actor executors remain an
M5 gap. The evidenced inherited-MainActor/default subset is supported without
claiming that missing executor architecture.

### M2/M7 deprecated top-level detached-task aliases

The next generated-surface question is whether the four deprecated global
`asyncDetached(priority:operation:)` and `detach(priority:operation:)`
overloads can share canonical detached-task creation while retaining their
full native contract. The active Apple Swift 6.3.3 interface answers this in
two parts. All four create non-child tasks without copying task locals or the
creator context. However, their `_inheritActorContext @isolated(any)`
operations also supply `Builtin.extractFunctionIsolation(operation)` as the
initial serial executor. The existing interpreter detached primitive models
the first part but not arbitrary lexical actor executors.

The same-source `top-level-detached-aliases.swift` fixture therefore isolates
the supported claim in synchronous `nonisolated` creator functions. It covers
both spellings and both success/failure shapes, verifies cleared task-local
storage and unnamed task metadata, holds the successful operations until both
have started, then observes their explicit priorities before handle-await
donation. Apple Swift 6.3.3 compiled the fixture in Swift 6 complete
strict-concurrency mode with only four expected deprecation warnings. Twenty
native runs produced the exact result
`asyncDetached:nil:17:default|detach:nil:9:default|asyncDetached-boom|detach-boom`;
the raw 20-line SHA-256 is
`b5bf9202d44d99164488367f7b71194ec4aa690029318b24b08b213e1ea6829f`.
The result makes no claim about relative start order or physical threads.

Before the production change, the isolated interpreter run captured the RED
`unresolved identifier 'asyncDetached'`. The generator now maps both source
spellings to one reusable `detachedTask` intrinsic. Its global adapter decodes
the existing priority and operation arguments and enters canonical detached
creation with `name: nil`; it does not add alias-specific scheduling or
lifecycle behavior. Synchronous compatibility entry fails closed with `Task
creation requires runAsync` instead of executing an async operation inline.

The focused generator, generated-surface, methodology, async-runtime, and
task-completion run passed all 128 tests in 15.35 seconds. The isolated
differential then completed all twenty fresh-process interpreter repetitions
at the native value, with observation digest
`132b48c96cc82c9c0c9bd4000f2b4cf7824b9d9ee96dd13d8429b1e25c5df82a`.
`ConcurrencySurfaceGen --check` and capability accounting also passed with all
four rows explicitly owned.

All four rows remain `known-divergence`/`none`: the nonisolated subset now has
native parity, while inherited and arbitrary `@isolated(any)` operation
executors require the M5 actor/executor architecture. This avoids promoting a
partial adapter to a false full-support claim.

### M4/M7 task-group `addTask` executor preferences

The next eight-row slice asks two separate questions about the named and
unnamed `addTask` overloads on all four task-group kinds. First, does an
explicit `executorPreference: nil` preserve ordinary group-child behavior?
Second, may a non-`nil` source `TaskExecutor` be ignored by the cooperative
runtime?

The committed same-source
`task-group-executor-preference-nil-add.swift` fixture invokes each exact
overload once. Apple Swift 6.3.3 compiled it in Swift 6 complete
strict-concurrency mode, and SIL contains one reference to every named and
unnamed executor-preference symbol. Twenty native runs were exact at
`discarding-named:discarding-name|discarding-unnamed:nil|ordinary-named:ordinary-name|ordinary-unnamed:nil|throwing-discarding-named:throwing-discarding-name|throwing-discarding-unnamed:nil|throwing-named:throwing-name|throwing-unnamed:nil`;
the raw 20-line SHA-256 is
`367c623bb8c986250b1a8fff70cca6e93e3bdabb12f61dceba330ca94436a9aa`.
Every group waits until its two children have recorded before returning, scope
exit joins them, and the final values are sorted, so the assertion chooses no
ready-child order. The pre-change isolated interpreter characterization was
already GREEN for this supported subset and completed all twenty
fresh-process repetitions with observation digest
`bc32d1fc5b8a07ba0db01ebb242e8fdc3d416cf2d0e7ecff2fbcb8391589a869`;
no artificial production RED was introduced for it.

A separate strict native `CountingTaskExecutor` probe establishes why the
complete declarations cannot inherit that positive status. Its source
SHA-256 is
`2badd1a4c69d8557446f131d687c3aaae0f8ad3f6f6def570826d88d34c98149`.
Twenty runs were exact at
`accepted:true:true|conditional-nil|conditional-non-nil|nil|non-nil|enqueues:2`,
with raw-output SHA-256
`fe56c52bb63fb774cee1573e6e96367b729f540ee6d1951ee049bc7f1d7f5896`.
Only the two non-`nil` children enqueue through the supplied executor; the
explicit-`nil` children do not. A separately cancelled conditional group
returns `false` without enqueueing. The preference is therefore observable
native behavior, not optional metadata.

The source-valid focused interpreter regression supplied the production RED:
a `ProbeTaskExecutor: TaskExecutor` passed to
`group.addTask(executorPreference:)` was silently discarded and the child ran
on `.cooperativeDefault`. The repair is a reusable runtime
executor-preference policy, not a group-kind special case. It accepts an
omitted or source `nil` preference and rejects every non-`nil` value with an
API-shaped unsupported diagnostic before child creation. For
`addTaskUnlessCancelled`, the shared check deliberately remains after the
existing cancelled-group early return, matching Swift's `false` result without
touching the executor. Focused regressions preserve both the non-`nil`
fail-closed path and that cancellation ordering.

The final isolated differential again completed all twenty fresh-process
interpreter repetitions at the exact native value and reproduced digest
`bc32d1fc5b8a07ba0db01ebb242e8fdc3d416cf2d0e7ecff2fbcb8391589a869`.
The combined task-group, methodology, generator, async-runtime, and
task-completion board passed all 124 tests in 6.794 seconds.
`ConcurrencySurfaceGen --check` and capability accounting also passed. The
full repository gate remains reserved for the coherent closeout batch.

All eight reviewed rows remain `known-divergence`/`none`. Their explicit-`nil`
nonisolated subset has same-source parity, but native non-`nil`
`TaskExecutor` scheduling and arbitrary `@isolated(any)` operation executors
remain M5-backed gaps. Accounting is now 132/156 reviewed: 43
runtime-supported, 17 diagnosed-unsupported, 45 known divergences, 26
excluded compiler ABI, one deferred, and 24 unreviewed rows. The remaining
generated tail is eight conditional executor-preference rows, eight immediate
task-group rows, and eight top-level rows.

### M4/M7 conditional task-group executor preferences

This eight-row slice is a CHARACTERIZATION of the named and unnamed
`addTaskUnlessCancelled` executor-preference overloads on all four task-group
kinds. It asks only whether an active explicit-`nil` call is accepted and
whether the same call after `cancelAll()` is rejected without child creation.
It makes no claim about ready-child order, priority scheduling, physical
threads, or non-`nil` executor-preference support.

The same-source
`task-group-executor-preference-nil-add-unless-cancelled.swift` fixture has
source SHA-256
`84e5c2e5674e8e34b25941fc39aebc08a890b2716fcdda15e5c1de3a3caf75cb`.
Apple Swift 6.3.3 compiled it with Swift 6 complete strict concurrency and
warnings as errors. SILGen contains exactly two references to each of the
eight declarations: one active call and one post-cancellation call. Every
accepted child records `Task.name` before its group is cancelled, every
rejected closure contains an observable sentinel, every structured scope
joins, and final child values are sorted.

All twenty native runs produced the same decisions: each group kind reports
`true,true,false,false`; accepted unnamed children observe `nil`, and accepted
named children observe their supplied name. The raw twenty-line output has
SHA-256
`0c0b8553995b3711e5b3619ba20e0509796999333cdaeaa5c423debac1728461`.
The isolated interpreter characterization was already GREEN and matched all
twenty fresh-process runs with native-observation digest
`72cbe2cb6e285431894a702ed14ea7f83bd7cb2130301b403234ad2f7ba36d32`;
there was therefore no justified production runtime change in this slice.

Focused negative coverage proves that an active non-`nil` preference fails
closed before child creation. Existing cancellation coverage proves the
important inverse ordering: once the group is cancelled, the operation
returns `false` before validating or using the preference. The combined
task-group, methodology, generator, async-runtime, and task-completion board
passed all 126 tests in 6.923 seconds. `ConcurrencySurfaceGen --check` and
capability accounting also passed. The full repository gate remains reserved
for the next coherent closeout batch.

All eight rows remain `known-divergence`/`none`: active explicit `nil` and
post-cancellation rejection have same-source parity, while native non-`nil`
`TaskExecutor` scheduling and arbitrary `@isolated(any)` operation executors
remain open. Accounting is now 140/156 reviewed: 43 runtime-supported, 17
diagnosed-unsupported, 53 known divergences, 26 excluded compiler ABI, one
deferred, and 16 unreviewed rows. The remaining generated tail is eight
immediate task-group rows and eight top-level rows.

### M4/M7 immediate task-group children

This eight-row iteration is a GAP CLOSURE for `addImmediateTask` and
`addImmediateTaskUnlessCancelled` on ordinary, throwing, discarding, and
throwing-discarding task groups. The positive claim is deliberately narrower
than each complete declaration: an explicit-`nil` executor preference and an
operation inherited from the fixture's `MainActor` start the operation's
synchronous prefix before the adding call returns. A forced suspension then
lets the caller record its `after` event and open the child gate. Active
conditional calls return `true`; calls after `cancelAll()` return `false`
without running their operation; `Task.name` is visible in the prefix; and
scope exit joins every accepted child. The oracle makes no claim about
independent-child finish order, priority scheduling, physical threads,
arbitrary actors, or non-`nil` executor-preference execution.

An unconditional `addImmediateTask` remains accepted after `cancelAll()`. Its
synchronous prefix observes `Task.isCancelled == true`,
`Task.checkCancellation()` throws `CancellationError`, and cancellation is
still visible after a forced suspension. This distinguishes unconditional add
semantics from the conditional member's post-cancellation `false` result.

That supported actor subset is checked at the runtime boundary rather than
assumed from the call site. The operation must inherit `MainActor` and the add
must be invoked from `MainActor`; explicitly nonisolated operations and
MainActor-looking closure literals created inside a lexically nonisolated
factory fail closed instead of being launched on the wrong executor.

The same-source `task-group-immediate-add.swift` fixture has source SHA-256
`e9bed7b55c8459d7eba0548889d902bf82e8a68e2ba00356f776c08a66afd457`.
Apple Swift 6.3.3 compiled it for macOS 26 with Swift 6 complete strict
concurrency and warnings as errors. SILGen selects all eight declarations,
including the active and post-cancellation conditional paths, plus the second
ordinary unconditional call that probes pre-attached cancellation. All twenty
native executions satisfied the same partial order. For each ordinary active
unconditional child the checked edges are
`start < after < finish`; for each active conditional child they are
`start < after:true < finish`; and the post-cancellation decision is
`rejected:false` with no rejected-child event. The pre-cancelled unconditional
child satisfies `prefix:true < check:caught < after < resumed:true`. Required
event multiplicity makes an accidentally executed rejected closure observable
while leaving unrelated finish order unconstrained.

Two tests pinned to swiftlang commit
`064859e41d68596f486c5d724401cb370f260409` provide independent semantic and
compile provenance:
[`startImmediately_order.swift`](https://github.com/swiftlang/swift/blob/064859e41d68596f486c5d724401cb370f260409/test/Concurrency/Runtime/startImmediately_order.swift)
checks the synchronous-prefix ordering of `Task.immediate`, and
[`startImmediately.swift`](https://github.com/swiftlang/swift/blob/064859e41d68596f486c5d724401cb370f260409/test/Concurrency/Runtime/startImmediately.swift)
contains the immediate task-group spellings and preferred-executor contract.
They are not substituted for this fixture's executable oracle: the upstream
task-group executor invocation block is disabled/commented, so it does not
runtime-test all eight declarations used here.

Before the runtime change, the isolated interpreter run supplied the expected
RED:
`TaskGroup.addImmediateTask is declared by the active _Concurrency.swiftinterface but is not supported yet`.
The repair is one generated intrinsic route and one general runtime launch
mode shared by all four group kinds and both operation forms. A group child is
registered in the group and structured-scope ownership graphs before its
native `Task.immediate` launch, so even an inline completion observes valid
ownership; launch failure rolls that transaction back. Immediate launch skips
the ordinary task's mandatory initial yield, while the existing task-owned
context, outcome publication, cleanup, name, priority, and group-join paths
remain shared. Conditional cancellation is checked before executor-preference
validation. Existing group cancellation sources are attached to a new child
record before immediate native launch, so its inline prefix cannot race ahead
of cancellation propagation. The common preference guard still fails closed
for an active non-`nil` `TaskExecutor` instead of silently discarding native
behavior.

`TaskGroupSurfaceTests/immediateTaskGroupChildCompletesBeforeAddReturns`
proves that a no-suspension immediate child mutates state and completes before
the add call returns while already present in both ownership graphs.
`TaskGroupSurfaceTests/immediateTaskGroupChildPreservesExecutorAcrossSuspension`
inspects both the task record and callback context before and after a forced
suspension and pins the supported MainActor operation executor across resume.
`TaskGroupSurfaceTests/synchronouslyThrowingImmediateGroupChildPublishesFailure`
pins the other inline-completion edge: a throwing child publishes its exact
source failure into the already registered group outcome, and `group.next()`
observes it rather than hanging or losing the result.
`TaskGroupSurfaceTests/preCancelledUnconditionalImmediateChildObservesCancellation`
proves that an unconditional immediate child created after `cancelAll()` sees
cancellation through `Task.isCancelled` and `Task.checkCancellation()` before
construction returns and still sees it after resumption.
`TaskGroupSurfaceTests/immediateTaskGroupChildRejectsUnsupportedOperationExecutors`
proves that all four group kinds and both immediate member forms enforce the
MainActor-operation/MainActor-invocation subset and reject unsupported
operation-executor combinations.
`TaskGroupSurfaceTests/nonNilImmediateTaskGroupExecutorPreferenceFailsClosed`
proves that an active non-`nil` preference is rejected, and
`TaskGroupSurfaceTests/cancelledImmediateConditionalAddSkipsExecutorPreference`
proves that a cancelled conditional call returns `false` before touching such
a preference. The updated isolated differential completed all twenty
fresh-process interpreter repetitions and satisfied the expanded native
partial order, including the pre-cancelled unconditional child.

All eight declarations remain `known-divergence`/`none`, not full-support
claims: native non-`nil` `TaskExecutor` resumption and arbitrary
`@isolated(any)` operation executors still require the M5 executor
architecture. The compiler-backed conditional filter added by the following
iteration expands the active denominator to 162 rows and exposes six active
declarations: four static Task-immediate rows and two additional top-level
priority-escalation rows. After reviewing the Task-immediate rows, accounting
is 152/162 reviewed: 43 runtime-supported, 17 diagnosed-unsupported, 65 known
divergences, 26 excluded compiler ABI, one deferred, and ten unreviewed
top-level rows. Reviewing those ten rows and adding target-aware build
manifests remains M7 work; repeated wait/new-work behavior and the escaped
task-group capability boundary remain M4 work.

### M7 conditional `Task.immediate` creation

This four-row iteration is a GAP CLOSURE for the throwing and nonthrowing
`Task.immediate` and `Task.immediateDetached` declarations selected by the
active Apple SDK. The generator now asks the active compiler to evaluate
`swiftinterface` conditional-compilation predicates, removes inactive branches
before the existing declaration walkers run, and fails closed when compiler
configuration diagnostics prevent a reliable selection. This general change
also exposes two active top-level priority-escalation declarations; they remain
unreviewed rather than being hidden by the previous walker limitation. The
generated Task instance/static denominator is therefore 36 rows and the whole
generated concurrency denominator is 162.

The same-source `task-immediate.swift` fixture has source SHA-256
`9c384ab8de788a992ebde85f6cec5e9af0b461d622bb6afae96d67f83d09fe6d`.
Apple Swift 6.3.3 compiled it in Swift 6 mode with complete strict concurrency
and warnings as errors. Each of the four declarations has one call site. All
twenty native and twenty fresh-process interpreter executions satisfied the
same partial order: every synchronous prefix records `start` before the
constructor-side `after`, the forced gate suspension places `finish` after
`after`, successful handles return `11` and `33`, and throwing handles project
their exact source errors. Names and explicit raw priorities are visible in
the prefix. `Task.immediate` observes the parent task-local value, whereas
`Task.immediateDetached` observes its declaration default. Independent finish
order is not asserted. No native-observation digest is pinned: repeated
accepted batches produced different digests when that independent finish order
changed, while all required events and causal edges continued to pass.

The isolated pre-fix run supplied the expected RED: construction recorded only
the caller-side `ordinary-after|detached-after` events and produced no task
values because the generated declarations had no runtime route. The repair
does not encode either API as a separate scheduling system. Task context
inheritance, operation executor, and task start policy are orthogonal runtime
inputs. `Task.immediate` combines inherited unstructured context, the
operation's inherited MainActor, and immediate start; `Task.immediateDetached`
changes only the context dimension to detached while retaining that operation
actor and start policy. Both records are created before launch, both use the
common outcome, waiter, cleanup, name, and priority paths, and the detached form is launched
through native `Task.immediateDetached` so native context is not accidentally
inherited through `Task.immediate`.

`GeneratedTaskSurfaceTests/immediateTaskKindsRunTheirPrefixBeforeConstructionReturns`
pins the synchronous prefix and handle values;
`GeneratedTaskSurfaceTests/immediateTaskKindsUseDistinctRuntimeInheritanceAndCleanUp`
pins unstructured-versus-detached lineage, task-local inheritance, and registry
cleanup, including the inherited MainActor executor on both task kinds.
`GeneratedTaskSurfaceTests/immediateTaskKindsPreserveOperationExecutorAcrossSuspension`
inspects the runtime record and callback executor before and after `Task.yield()`
for both forms and pins MainActor ownership across resumption.
`GeneratedTaskSurfaceTests/immediateTaskKindsRejectUnsupportedOperationExecutors`
proves that a non-MainActor caller, an explicitly nonisolated operation, or an
operation closure returned by a lexically nonisolated factory fails closed. A
separate Apple Swift 6.3.3 typecheck with complete strict concurrency and
warnings as errors confirms that these nonisolated shapes are native-legal, so
their rejection is an explicit recorded divergence rather than a compiler
diagnostic.
The non-`nil`
preference and synchronous-compatibility tests ensure that unsupported
execution cannot silently fall back. Generator tests inject
active and inactive compiler configurations and verify that an unanswerable
condition fails closed.

All four declarations remain `known-divergence`/`none`, not full-declaration
support claims. The evidenced runtime subset uses an explicit `nil`
`TaskExecutor` preference and an operation inherited from `MainActor`. Native
non-`nil` executor-preference resumption and arbitrary `@isolated(any)`
operation actors require the M5 executor architecture and currently fail
closed. Current accounting is 152/162 reviewed: 43 runtime-supported, 17
diagnosed-unsupported, 65 known divergences, 26 excluded compiler ABI, one
deferred, and ten unreviewed top-level rows.

### M7 generated `UnsafeCurrentTask` capability

This iteration expands the interface-first denominator with a reusable
selected-nominal walker. It discovers all nine active `UnsafeCurrentTask`
member declarations without a type-name special case and fails closed if the
family or any required route disappears from the active SDK. Together with the
two `withUnsafeCurrentTask` overloads, the generated denominator is now 171
rows and 119 rows have runtime adapter routes.

The same-source `with-unsafe-current-task.swift` fixture covers synchronous and
asynchronous detached-task bodies, exact rethrow, logical identity across
nested calls and suspension, base/effective priority, equal-identity hash
consistency, cancellation, and cleanup. Focused runtime tests separately cover
the `nil` outside-task case, root and host-callback identity,
cancellation-observation accounting, post-body lease invalidation, and
ownership release. The runtime exposes a weak `RuntimeTaskID` capability with
a shared dynamic-extent lease: copies remain valid across suspension inside
the body and do not retain the task record. Root, child, detached, and
host-callback entry paths therefore consult the same logical task record
instead of native thread identity.

Six generated member routes (`==`, `basePriority`, `cancel`, `hashValue`,
`isCancelled`, and `priority`) and both top-level overloads are
`runtime-supported`/`native-parity`. `hash(into:)`,
`escalatePriority(to:)`, and `unownedTaskExecutor` remain generated but
unrouted and have explicit focused diagnostics; the interpreter does not
approximate executor preference or capability-driven priority mutation.
Current accounting is
163/171 reviewed: 51 runtime-supported, 20 diagnosed-unsupported, 65 known
divergences, 26 excluded compiler ABI, one deferred, and eight unreviewed
top-level rows.

### M7 task-priority escalation-handler routes

This iteration reviews the two macOS 26 source-callable declarations
`withTaskPriorityEscalationHandler` and
`_isolatedParameter_withTaskPriorityEscalationHandler`. The semantic question
was scoped narrowly: does a strict priority donation invoke every handler
active on the target task with the exact old/new values, without replaying an
increase that predates registration; does the operation resume at the donated
priority; and do value, typed-error, and cancellation exits remove the handler
before any later donation?

The committed `task-priority-escalation-handler.swift` fixture has SHA-256
`dc6ff8dab03edfb9800e1de829568393d3057b89301265c12d08ac29e6a01e64`.
Apple Swift 6.3.3 compiled it in Swift 6 mode with complete strict concurrency
and warnings as errors. Twenty native executions produced exactly:

```text
active:17:25|error:true:25|cancel:true:25|replay:true:25|events:inner:9>17,outer:9>17,replay:17>25
```

The handshakes force a background operation to receive a low donation while
two nested handlers are active, then a high donation only after their success
scope exits. Separate lanes donate only after typed-error and cancellation
scope exit. The replay lane first donates low before registration and then
donates high inside the scope. Handler events are sorted because Swift does not
guarantee relative nested-handler order or callback-versus-operation
scheduling; no physical-thread or unrelated ready-task order is claimed.

Before the runtime change, the isolated interpreter run reached its evaluation
budget because both generated declarations were known metadata but had no
runtime route, so no callback could release the controlled operation. The
final no-replay lane was added to strengthen the native oracle before the
production mechanism was implemented. The repair maps both source spellings
to one generated `withTaskPriorityEscalationHandler` intrinsic. Runtime task
records own a dynamic registration stack. Each strict donation captures the
old value, updates the record and live evaluator context, invokes a snapshot of
all active registrations, and only then propagates transitively. Registration
does not inspect prior donation history, and `defer` removes it on every exit.
The isolated wrapper accepts only explicit `isolation: nil`; omitted
`#isolation` and non-`nil` actors fail closed until M5 owns actor isolation and
resume executors.

The focused runtime test inspects all retained task handles after release. It
pins two active nested invocations, zero post-success/error/cancellation
invocations, one non-replayed-then-active invocation, exact donation histories,
observed cancellation, and empty task/scope/group/scheduler ownership. A
separate negative test pins the isolation guard. An interpreter-only defensive
test makes both active callbacks fail: delivery continues to every handler,
the first failure belongs to the target rather than the donating waiter, and
all registrations and runtime ownership still drain. A source-shape test pins
Swift's ordinary unlabeled trailing-handler syntax. Generator and surface tests
pin both active signatures and their shared route. The final differential
shard passed all twenty fresh-process interpreter repetitions in 12.19 seconds;
the nine focused generator/surface/runtime checks passed in 4.62 seconds while
that shard was running.

Both complete declarations remain `known-divergence`/`none`, because arbitrary
actor/executor behavior is outside the evidenced cooperative and explicit-nil
subsets. Accounting is now 165/171 reviewed: 51 runtime-supported, 20
diagnosed-unsupported, 67 known divergences, 26 excluded compiler ABI, one
deferred, and six unreviewed. A full repository gate is deliberately reserved
for the coherent M7 closeout batch; this iteration claims only the focused
checks above.

### M7 `withTaskExecutorPreference` explicit-nil scope

This iteration reviews the active SDK declaration with ID
`swift-concurrency-api-v1:e68748f7bb9c746670485d2f0151129a63ad918994e692bede2ca9d7e622cd05`.
The semantic question was scoped to one exact subset: with no ambient custom
`TaskExecutor`, do explicit nil executor and isolation arguments invoke a plain
explicitly nonisolated operation function in the same task, preserving task
identity, native high priority, name, task locals, cancellation, values, typed
source errors, suspension, and cleanup?

The committed `with-task-executor-preference-nil.swift` fixture has SHA-256
`af638f3688b1e029566ed84fce1dac81610931af8d1296a07bdb47c372454947`.
Apple Swift 6.3.3 compiled the same source in Swift 6 mode with complete strict
concurrency and warnings as errors. Twenty bounded native executions produced
exactly:

```text
success:true:preference-success:25:bound:false:true:preference-success:25:bound:false|error:true|cancel:false:false:true:preference-cancel:true
```

The success lane checks suspension-time and post-scope identity, name, native
high-priority raw value, task-local state, and cancellation. The cancellation
lane begins uncancelled, cancels the current task inside the operation, and
requires the caller to observe cancellation after return. That causal effect
would fail if the adapter secretly created a child task. The failure lane
requires the exact source enum case rather than an error string. No custom
executor scheduling, ambient preference inheritance, actor isolation,
physical thread, or unrelated ready-task order is asserted.

Before production routing, the isolated interpreter differential failed at
the first repetition with `unresolved identifier
'withTaskExecutorPreference'`; native compilation and all twenty native runs
were already green. During test hardening, two fixture-only mistakes were
found and corrected without changing runtime semantics: an
`UnsafeCurrentTask` capability had escaped its allowed dynamic extent, and a
contextual `.high` comparison exercised an unrelated implicit-member gap. The
final probe keeps every capability lease active and compares the exact raw
priority observed by native Swift.

The generator now maps the active declaration to one
`withTaskExecutorPreference` intrinsic. Its runtime adapter validates an
explicit nil unlabeled executor argument, explicit `isolation: nil`, and a
named operation carrying a plain `nonisolated` modifier. It then invokes the
operation through the ordinary suspending closure path in the current
`RuntimeTaskID`; it creates no child, task record, context copy, or executor
mutation. Closure metadata now records plain explicit nonisolation separately
from a nil executor preference, because nil also represents custom actor kinds
that M5 cannot identify. Non-nil executors, omitted or non-nil isolation,
MainActor/custom-actor operations, `nonisolated(nonsending)`, and closure
expressions fail closed.

The final focused selection passed nine generator, surface, runtime, and
methodology tests in 4.86 seconds. The final differential shard compiled the
real source and passed all twenty fresh-process interpreter repetitions in
5.74 seconds; its native-observation digest is
`5e5390c403bc06ba8dc02f232a50223b7e9c89270dc5b2838e1b6f6cca45bee3`.
The generated-source stale check passed, and the capability validator reported
171 declarations, 122 generated routes, 166 reviewed rows, a matching
inventory pin, and no accounting errors.
Accounting is now 166/171 reviewed: 51 runtime-supported, 20
diagnosed-unsupported, 68 known divergences, 26 excluded compiler ABI, one
deferred, and five unreviewed. The complete declaration remains
`known-divergence`/`none`, and the full repository gate remains reserved for
the coherent M7 closeout batch.

### M7 `extractIsolation` direct-declaration reflection

This iteration reviews the active SDK declaration with ID
`swift-concurrency-api-v1:c8849676233060c2f6364bb847db1bac6c2b6ddcae80a6da3269d3adda052bb8`.
The semantic question is deliberately construct-level: when the argument is a
bare, unqualified identifier reference to a global async function carrying
plain explicit `nonisolated`, does `extractIsolation` return `nil`
synchronously without invoking that function or touching task/executor state?

The committed `extract-isolation-nonisolated.swift` fixture has SHA-256
`8743962c044b92531e9f156ae55f9ad73b2df4e3c750776daaf5c5fa2515568d`.
Apple Swift 6.3.3 compiled it in Swift 6 strict-concurrency mode. Twenty
bounded native executions and twenty fresh-process interpreter executions
produced exactly:

```text
plain:true|concurrent:true
```

One operation is typed-throwing and the other is `@concurrent`; both would
terminate or throw if called, so the output also proves non-invocation. Before
the generated route existed, native compilation and all native repetitions
were green while the interpreter failed the first repetition with unresolved
identifier `extractIsolation`.

Independent review then found a second RED in the first repair: a local
function-value conversion retained the source declaration's
`functionDeclID`/`isExplicitlyNonisolated` flags, so both `extractIsolation`
and the previously routed `withTaskExecutorPreference` could silently accept a
value whose isolation had been reclassified. This iteration therefore narrows
both current adapters to an enforceable bare-unqualified-global-async boundary
and adds conversion regressions. `withTaskExecutorPreference` additionally
requires no declaration-level operation executor preference, so `@concurrent`
fails closed there even though it belongs to the positive `extractIsolation`
fixture. This does not retroactively broaden the earlier
task-executor-preference receipt.

The generator maps the active declaration to one `extractIsolation` intrinsic.
The runtime adapter inspects metadata synchronously and returns nil only when
call-site provenance proves a bare, unqualified global async declaration and
closure metadata proves plain explicit nonisolation. Argument collection
records that provenance in both synchronous and suspension-aware call paths and
preserves it through inout unwrapping. This is shared with
`withTaskExecutorPreference`; qualified or parenthesized references, local
aliases, annotated conversions, member references, synchronous functions,
closure expressions, implicit nonisolation, actor-isolated functions, and
`nonisolated(nonsending)` fail closed instead of inheriting declaration flags
that may no longer describe the function value.

Focused tests pin the positive result and no retained
task/scope/group/scheduler ownership; the conversion, member-reference, and
parenthesized-reference guards; and the task-executor-preference `@concurrent`
boundary. The post-fix prebuilt parallel board completed generator, route,
runtime, ledger, stale, accounting, and exact parity checks in 12.26 seconds.
The exact parity shard passed all twenty repetitions in 11.61 seconds with
native-observation digest
`8be9a0cfbf94e0f9b44c98e8a8e8fb90de56922dcdfe93eeacc01a7054806afd`.
At that checkpoint, generated-surface and capability-accounting checks retained
171 declarations, 123 routes, and 167 reviewed rows: 51 runtime-supported, 20
diagnosed-unsupported, 69 known divergences, 26 excluded compiler ABI, one
deferred, and four unreviewed continuation APIs.

The full declaration remains `known-divergence`/`none`. Canonical value-level
isolation metadata for formation, conversion, actor identity, and the
replacement closure `.isolation` property belongs to M5. The full repository
gate remains reserved for the coherent M7 closeout batch.

### M7 public continuation entry-point dispositions

This characterization iteration reviews the final four unreviewed declarations
in the active-SDK denominator: `withCheckedContinuation`,
`withCheckedThrowingContinuation`, `withUnsafeContinuation`, and
`withUnsafeThrowingContinuation`. The semantic question is limited to the
native surface: do all four public entry points accept an explicit
`MainActor.shared` isolation argument from a nonisolated caller, execute their
inline body on MainActor, and return the exact value supplied by one immediate
resume?

The committed `continuation-entry-points.swift` fixture has SHA-256
`12d5e7bacfea449085147ca08000245f07661600b0b4e58c7e2d3cd14c736b0f`.
Apple Swift 6.3.3 compiled it with `-swift-version 6`, complete strict
concurrency, and parse-as-library against SDK 26.5. Twenty bounded native
executions produced exactly:

```text
checked:11|checkedThrowing:22|unsafe:33|unsafeThrowing:44
```

Each body calls `MainActor.assertIsolated()` before resuming. This establishes
the explicit-isolation body hop and inline one-shot value projection. It does
not establish delayed or cross-executor resume ownership, throwing projection,
cancellation, double-resume diagnostics, abandoned checked-continuation policy,
or cleanup; none of those are asserted by this iteration.

This is characterization, not gap closure: the generated inventory already
contained the four exact declarations, so no production runtime changed and no
RED was fabricated. A production-preflight test permanently recompiles the
fixture, while a methodology test pins the four stable IDs, checked versus
unsafe value/error types, async/throwing/sending/isolation metadata, and their
then-current absence of adapter routes. At this characterization checkpoint,
every row was explicitly `deferred`/`none` under
`M6/protocol-iteration-streams-and-continuations`, with the existing
`async-sequence-continuation-runtime` gap. A continuation registry must own a
suspended task and its required resume executor, so implementing these APIs
before M5 reentrancy/resume ownership would violate the architecture.

Accounting at that checkpoint was 171/171 reviewed: 51 runtime-supported, 20
diagnosed-unsupported, 69 known divergences, 26 excluded compiler ABI, five
deferred, and zero unreviewed; the generated route count remains 123. The final
incremental test build took 9.88 seconds. The parallel focused board then ran
five compiler/generator/methodology tests, the generated stale check,
capability accounting, and the twenty native executions in 7.65 seconds. All
passed. The full repository gate remains reserved for the coherent M7
closeout; target-aware build manifests are the remaining M7 work.

### M7 target-aware project preflight boundary

This iteration replaces target-blind project checking with one immutable
`ProjectBuildManifest` shared by compiler preflight and interpreted execution.
It binds the canonical project root, exact ordered source membership and bytes,
module, SDK, target triple and deployment floor, compiler and effective Swift
conditional versions, language/concurrency/default-isolation modes, defines,
search paths, enabled features, and authoritative import and compiler-owned
conditional answers. Preflight consumes the original files as one native
module; the interpreter alone receives a derived import-stripped merge. A
sibling invalid Swift file is therefore excluded by target membership rather
than a filename or parse heuristic.

The native iOS-simulator fixture compiled under Apple Swift 6.3.3 with Swift 6,
complete strict concurrency, `arm64-apple-ios18.0-simulator`, `DEBUG`, and
MainActor default isolation. It causally selects `os`, `arch`, simulator,
unversioned and versioned `canImport`, exact `swift`/`compiler` ranges,
`hasFeature(StrictConcurrency)`, `hasAttribute(preconcurrency)`,
`objectFormat(MachO)`, `_endian(little)`, `_runtime(_ObjC)`, and the iOS 18
deployment floor. Removing default isolation fails at the explicit
MainActor call; adding the excluded sibling fails at its line 1 type mismatch.
The Catalyst oracle resolves the exact `arm64-apple-ios18.0-macabi` triple
against the macOS SDK.

Compiler-owned conditional answers are verified by a hidden file in the same
client module, which matters because version-qualified `canImport` can depend
on imports in sibling files. Before runtime mutation, the interpreter walks all
`#if` syntax and rejects an unrecorded answer instead of silently selecting
`false`. The same per-interpreter target identity now supplies SwiftUI
environment platform defaults, so the legacy process-global canvas cannot
override a target-aware render.

The production project entry rejects the unchanged SHA-pinned upstream
TaskGroup escape fixture at its native `18:10` and `25:10` diagnostics before
the mutation sentinel executes. This covers M4 `group-escape-legality`; M4
remains partial for repeated wait/new-work, non-nil executor preferences, and
arbitrary actor executors. The target-manifest portion of M7 is covered, while
M7 itself remains partial because the generated inventory denominator is still
explicitly incomplete and its divergent/deferred rows retain owned gaps.

The focused post-fix board passed 26 compiler-preflight tests, four
target-manifest integration tests, and 38 methodology/accounting tests. The
single incremental build precedes parallel read-only bundle and native-oracle
runs; multiple SwiftPM processes never contend for the same `.build` lock.

### M5 pinned swiftlang ordinary actor deinitializer

This characterization admits the unchanged upstream
`test/Concurrency/Runtime/executor_deinit1.swift` fixture from
`swiftlang/swift` release `swift-6.3.3-RELEASE`, commit `064859e4…`. Its
checked-in bytes have SHA-256
`92336e92a42088e9d6834c52776690f7a3d95b9129f054efa13b6744165c6635`.
The semantic question is deliberately narrow: after an actor has completed an
externally awaited isolated method, does releasing its final source reference
still run its ordinary `deinit`?

Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) compiled the unchanged file against
SDK 26.5 for `arm64-apple-macosx26.0` with Swift 6, complete strict concurrency,
warnings as errors, and parse-as-library. Twenty bounded native executions
printed exactly `called deinit`. The same unchanged file, plus only the
harness's generic detected-`@main` invocation, passed native/interpreter
FileCheck. This proves final-release execution of an ordinary actor
deinitializer after isolated entry. It does not establish which physical
thread runs teardown, globally isolated or `isolated deinit` scheduling,
custom-executor teardown, or ordering against unrelated tasks.

This is an already-GREEN characterization: source-class lifetime already
routes final `Instance` release through the common idempotent deinitializer
path and then releases the actor record, so no production runtime changed and
no RED was fabricated. At that point the pinned concurrency intake was 13
direct / 4 diagnostic / 110 needs-adapter / 7 unsupported across all 134 inventoried
runtime files. The actor declaration safety boundary remains open for the
separate custom-executor and isolated-deinitializer forms.

The iteration also removes a verification bottleneck without changing an
oracle. The 23 executable upstream fixtures are now independent parameterized
test cases. Native compilation/process execution is nonisolated and can use
the prebuilt Swift Testing worker pool; only interpreter execution returns to
MainActor. On the same build, the complete board fell from 23.03 seconds in one
serialized test to 5.24 seconds with four workers (4.4×), while all 23 fixtures
and their original assertions remained GREEN.

### M5 pinned swiftlang MainActor deinitializer parity

The next characterization admits the unchanged upstream
`test/Concurrency/Runtime/isolated_deinit_main_sync.swift` fixture from the
same Swift release and commit. Its checked-in bytes have SHA-256
`f5bdf3c356f9ed9093e9673b58c218fdca49bd08298848b70083e4ed21d6af2c`.
The semantic question is narrow: when final release already occurs on
MainActor, does Swift accept an explicit `@MainActor deinit` and run it before
the following statement?

Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) compiled the unchanged source against
SDK 26.5 for `arm64-apple-macosx26.0` with Swift 6, complete strict concurrency,
warnings as errors, and MainActor default isolation. Twenty bounded native
executions printed exactly `isDead = false`, `DEINIT`, `isDead = true`; the
concatenated output SHA-256 was
`a4a1c51d0716fe4132004fa0e907d048e373620c2554be91d6a2ec082beaa47e`.
This establishes the MainActor-owned path only; it does not grant a source
actor or user-global-actor executor capability.

The first implementation treated this native-positive form as unsupported.
It initially rejected the declaration and then, after the full corpus proved
that too broad, rejected first construction. The first M5 closing gate exposed
the remaining architectural mistake: Kiwix and Mythic construct valid types
with MainActor-owned deinitializers, while the interpreter's host `Instance`
already has an `@MainActor isolated deinit`. The host Swift runtime therefore
owns exactly the capability required by this fixture.

Collection now records `.mainActor` deinitializer metadata instead of a fatal
requirement. Final host release invokes the source body with MainActor dynamic
and lexical executor identity, restores the caller, and continues superclass
teardown. The unchanged upstream source passes FileCheck under both native
Swift and the interpreter. Focused ARC regressions cover final-release timing
and preserve ordinary nonisolated actor deinitializers. The manifest assertion
is now `file-check`, making this the 24th independently schedulable executable
upstream case; only the custom-executor fixture remains an
`interpreter-diagnostic` executable.

### M5 isolated MainActor deinitializer parity

The repository-owned same-source fixture
`Tests/ConcurrencyParity/Fixtures/actor-isolated-deinitializer.swift` has
SHA-256
`2c86c8c84447539808242e519b1860b2e8716acb47c8394c86d7dbc52f6d2fa4`.
It asks one question: when a MainActor-isolated class declares
`isolated deinit` and final release already owns MainActor, does teardown run
before the following MainActor statement?

Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) compiled the source against SDK 26.5
for `arm64-apple-macosx26.0` with Swift 6, complete strict concurrency, and
parse-as-library. Twenty bounded executions returned exactly `deinit`; the
concatenated output SHA-256 was
`31a22641c2d9978ed6e65d1f374a2bca272f06ab1a95b0c245524d9c3e56f697`.
This proves only the already-owned synchronous fast path. It does not establish
off-executor scheduling or physical-thread behavior.

This is a two-stage gap closure. The first production change stopped silently
discarding `isolated`, but rejected every such lifetime. The full corpus and
the host representation then showed the construct-level distinction that
syntax-only rejection missed: `isolated deinit` on a MainActor nominal can use
the same real host MainActor capability as explicit `@MainActor deinit`.
Collection now records that executor on the nominal and the common runner
enters it for the body. All twenty same-source repetitions match `deinit`.

The rejection remains where the capability is genuinely absent:
`isolated deinit` on a source actor fails at first construction because the
host MainActor lifetime does not own that source actor's mailbox. Ordinary and
explicit `nonisolated` actor deinitializers remain supported. The parity
harness continues to represent diagnostics as typed `RuntimeError`
observations for the user-global-actor and custom-executor boundaries, so a
returned source string cannot masquerade as a diagnostic.

### M5 user global-actor deinitializer boundary

The repository-owned same-source fixture
`Tests/ConcurrencyParity/Fixtures/actor-global-actor-deinitializer.swift` has
SHA-256
`7736ed5ae758e32e47a6733f7ce1d24d7b6eff712723d4f3051e6aa6a169bd1e`.
It asks one question: when a class explicitly annotates its deinitializer with
a source-declared global actor and final release already owns that actor, does
teardown finish before the following actor-isolated statement?

Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) compiled the fixture against SDK
26.5 for `arm64-apple-macosx26.0` with Swift 6, complete strict concurrency,
and parse-as-library. Twenty bounded native executions returned exactly
`deinit`; the concatenated output SHA-256 was
`31a22641c2d9978ed6e65d1f374a2bca272f06ab1a95b0c245524d9c3e56f697`.
This proves only the already-owned synchronous fast path. It does not establish
off-executor scheduling, physical-thread behavior, or an order between
independent tasks.

This is a gap closure. Before the production change, all twenty interpreted
fresh-process repetitions silently returned `deinit`; the declaration
collector treated `@ParityTeardownActor` as an unrelated attribute and stored
the body for ordinary synchronous ARC. The common collector now retains
explicitly attributed deinitializers as pending isolation checks. After every
nominal declaration, deferred extension, nested type, and typealias has been
resolved, it verifies the attribute's declaration metadata. An attribute that
actually names `@globalActor` records the located fatal diagnostic
`global-actor deinitializer '@…' requires executor-owned teardown, which is
not supported yet` on the owning nominal; first construction raises it. The
mechanism does not recognize the fixture, class, or actor name.

Focused regressions prove declaration-order-independent resolution, a
global-actor typealias, and Swift's separate rule that an ordinary
deinitializer remains nonisolated when only its enclosing class carries the
actor annotation. The ARC suite is GREEN at 57/57, and the exact differential
is GREEN in 20/20 native and fresh interpreted repetitions with native
observation digest
`712624bccfecdd59be5c0dd5d11e430671dca20fe3f8d82510ebc022f48aa578`.
At this step the M5 safety boundary remained open only for the custom-executor
actor-form audit; no physical parallelism was claimed.

### M5 pinned swiftlang custom actor-executor boundary

The unchanged upstream `test/Concurrency/Runtime/custom_executors.swift`
fixture comes from `swiftlang/swift` release `swift-6.3.3-RELEASE`, commit
`064859e4…`. Its checked-in bytes have SHA-256
`140dd12df48b4bcf7f660414fe6586781c57820b77dc6423cbe6f60b6ed03adf`.
The semantic question is narrow: does a source-defined `unownedExecutor`
change the executor used for each isolated actor entry?

Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) compiled the unchanged source against
SDK 26.5 for `arm64-apple-macosx26.0` with Swift 6, complete strict
concurrency, and parse-as-library. Twenty bounded native runs produced the
same trace: every `Custom.report()` entry first printed
`custom unownedExecutor`, then `custom.count == N`, and
`simple.count == N`; `simple.preconditionIsolated()` succeeded. The
concatenated output SHA-256 was
`953a5b8c068987794f3d4266b3944de52d9342b4eb0c59700e54d1862be397fa`.
This proves executor selection and shared executor identity. It does not prove
an unrelated task order or require physical parallelism.

This is a gap closure. Before the production change the interpreter ignored
`unownedExecutor`, entered `Custom.report()` through its default logical
mailbox, and failed later with the unrelated diagnostic that `Simple` had no
`preconditionIsolated` member. Actor symbols now classify a direct computed or
stored `unownedExecutor` after extensions are reconciled. Transitive actor
protocol conformances also inspect protocol-extension defaults; the unchanged
upstream `custom_executors_protocol.swift` compiled and ran under the same
Swift 6 strict mode, and twenty native runs produced one exact executor trace
(concatenated SHA-256
`b1e05850cc67d8eb62ddcb29af6ade568f9af82b164aa4e8d2607c6b3a2597e4`).

The common actor method, accessor, isolated-parameter, global-actor, and
stored-property entry funnels now raise the fatal diagnostic
`custom actor executor … uses unownedExecutor dispatch, which is not supported
yet` before isolated source code executes. The actor declaration and
initializer are not rejected; nonisolated members remain callable, and a
same-named property on a non-actor remains ordinary. A legacy synchronous
storage path has the same guard. This is construct-level fail-closed behavior,
not emulation of a custom serial executor.

The unchanged swiftlang differential, 26 focused actor-runtime tests, and the
complete upstream parity suite are GREEN. `ProjectCheck --all --project
Aidoku` is also GREEN at 1/1, proving that the real stored-`unownedExecutor`
declaration can still be collected without an up-front project rejection. The
upstream runtime inventory is now 15 direct / 4 diagnostic / 108 needs-adapter
/ 7 unsupported across all 134 files. The demand-scoped M5 safety requirement
is covered and the active execution-plan cycle advances to M6. M5 is recorded
as provisional because its broad M4/M7 prerequisite milestones retain owned
partial-surface gaps; custom-executor scheduling and physical threads are not
claimed.

### M6 protocol `for await` success slice

The first M6 gap closure asks one bounded question: does `for await` over a
user-defined `AsyncSequence` obtain its iterator, repeatedly await a mutating
value-type `next()` witness through a real suspension, deliver every non-`nil`
element once, and terminate at `nil`? The same-source
`protocol-async-sequence-iteration.swift` fixture uses `Task.yield()` inside
each successful `next()` and reduces values 1, 2, and 3 to the deterministic
observation `3:6`. Apple Swift 6.3.3 compiled it in Swift 6 complete-strict
mode against SDK 26.5; twenty bounded native runs produced that exact result.
Count plus a commutative sum make no claim about unrelated scheduler order or
physical threads.

This is a two-stage RED-to-GREEN gap closure. Initially the async statement
evaluator recognized only the concrete `RuntimeTaskGroup` carrier and failed
at the loop with `for-in requires a range or an array`. The first general
witness-dispatch implementation then repeatedly copied the value-type iterator
without committing its mutating state and hit the evaluation budget. The
final mechanism calls `makeAsyncIterator()` and `next()` through ordinary
member and suspending invocation. Its mutating witness path is the same
copy-in/copy-out kernel used by explicit `await iterator.next()`, so iterator
state, source method calls, protocol-extension candidates, actor hops, and
generated host methods do not acquire a second evaluator implementation.

The exact parity case passed all twenty native/interpreted repetitions with
native-observation SHA-256
`c2fe5dfc6c62bc73a4153780ef502fa634eca8ca23a57a9a4bc3659ac6c8560b`.
A focused runtime test independently checks the value-state transition and
empty scheduled-task, task-record, structured-scope, and task-group
registries. At that point M6 remained `partial`: typed-error and cancellation
characterization, `break`/`return` cleanup, protocol-extension defaults,
host-bridged sequences, streams, continuation ownership, and executor-correct
resume still required evidence.

The immediate follow-up is characterization, not another gap closure. A
second same-source sequence returns 1 and 2 across real yields, then its
mutating `next()` throws `ProbeAsyncSequenceError.stopped`. Swift 6.3.3
produced `2:3:caught` in twenty bounded runs: only two values reach the loop
body, and the case-specific outer catch receives the source error. The
interpreter was already GREEN through the general witness path in all twenty
runs, with native-observation SHA-256
`41c3e17dc0fc6f34eebeaa45d4cdac265ea524e1be16169cf15d7c8239f945db`;
no production change or fabricated RED was needed. Associated-value catch
binding is deliberately outside this sequence question. At that point,
cancellation, early-exit cleanup, protocol-extension defaults, host-backed
sequences, streams, and continuations remained open.

A second characterization pins cancellation as an orthogonal user-iterator
dimension. A MainActor gate holds the first `next()` after entry; the parent
then cancels the consuming task and releases the gate. Swift does not
automatically terminate a general `for await`: the iterator resumes, observes
`Task.isCancelled`, returns value 7, and returns `nil` only on its next call.
The loop consumes that value, and the task succeeds while both its own view and
its handle remain cancelled. Native and interpreted executions produced
`1:7:true:true` in all twenty runs, with native-observation SHA-256
`d836304e58bda609e9187c112300dcd94d917e3bec13210316a9a7c5529edcd8`.
No production change was needed, and no physical-thread or unrelated ready-task
order is claimed. Automatic consumer termination for `AsyncStream` is a
separate M6 question; early-exit cleanup, default witnesses, host bridging,
streams, and continuations remain open.

The next characterization covers the first early-exit path. Its iterator has
no terminal `nil`: each `next()` records its ordinal, really suspends with
`Task.yield()`, and returns another integer forever. The loop records values 1
and 2, installs one body-local `defer` per iteration, and breaks on 2. Apple
Swift 6.3.3 and the interpreter both produced
`12:2:next-1,defer-1,next-2,defer-2,after` in all twenty bounded runs. This
proves that `break` prevents a third `next()` request and that the breaking
iteration's defer completes before post-loop code, without claiming unrelated
scheduler order or physical threads. The canonical twenty-observation native
SHA-256 is
`4c2b2bfbeefbaaa83bf8568535bed2e681ed7b0a24c4aced214ab627f6c20eef`.
The general streaming loop was already correct, so no production change or
fabricated RED was needed. `return`/`continue`, protocol-extension defaults,
host bridging, streams, and continuations remain open.

The companion control-flow characterization uses another nonterminating
iterator. Value 1 records `continue`, value 2 completes normally, and value 3
returns from an inner consumer to an outer caller. Every `next()` suspends.
Swift 6.3.3 and the interpreter produced the exact twenty-run observation
`returned-3:3:next-1,continue-1,defer-1,next-2,body-2,defer-2,next-3,return-3,defer-3,consumer-defer,after`.
Thus `continue` runs its iteration defer before requesting value 2; `return`
prevents a fourth request, then unwinds the value-3 defer and consumer defer
before the caller records `after`. The canonical native-observation SHA-256 is
`7cccd6b0587a78d2fe388df081ca38c6051f4564f89ae67144104ec3f8794113`.
This was also already correct through the shared streaming/body funnels, so no
production change was needed. Protocol-extension defaults, host bridging,
streams, and continuations remain open.

The protocol-default characterization removes callable implementations from
both concrete types. A refining `AsyncSequence` protocol extension supplies
`makeAsyncIterator()`, and a refining `AsyncIteratorProtocol` extension
supplies mutating async `next()`; the concrete sequence and iterator declare
only associated-type witnesses and stored state. Apple Swift 6.3.3 and the
interpreter produced `3:6` in all twenty runs while each successful default
`next()` suspended with `Task.yield()`. The canonical native-observation
SHA-256 is
`7ecad08059eb64d34d9a6f0ed689f83f410c385f80b40a1590867991086cae68`.
This confirms that ordinary transitive protocol-extension lookup feeds the
same make/next and mutating copy-out funnels; no concrete-name route or
production change was added. Host bridging, streams, and continuations remain
open.

The host-bridge slice replaces both source values with opaque SDK-owned
carriers. Native support exposes a finite `AsyncSequence` of 2, 4, and 6; the
interpreter sees only parsed host declarations for the factory,
`makeAsyncIterator()`, and `mutating next() async -> Int?`, plus nominal and
protocol metadata from the test registry. The shared protocol loop therefore
cannot inspect the carrier or fixture name. It invokes the same ordinary
member and suspending-call funnels that generated StoreKit gateways use.

Apple Swift 6.3.3 and the interpreter produced `3:12` in all twenty bounded
runs. The canonical native-observation SHA-256 is
`bc358f17e71f8d3e32b52119816eed247bd9c796dc3a8a0411f0ffcb659d4a98`.
Focused white-box assertions prove one tracked host operation for each of the
three values and the terminal `nil` request, followed by empty
host-operation, task, structured-scope, task-group, and scheduler registries.
No production change or fixture-specific route was required. `AsyncStream`,
`AsyncThrowingStream`, and continuation ownership remain open.

### M6 unbounded `AsyncStream` suspended-consumer foundation

The first stream gap closure adapts one deterministic semantic subset from the
unchanged pinned swiftlang
`test/Concurrency/Runtime/async_stream.swift` oracle: a continuation yields two
values, calls `finish()`, and the iterator observes terminal `nil`. The upstream
file is pinned at Swift commit `064859e4…` with SHA-256
`940c49ec9cfe4a0292f13757e0a56be5a601618fd5ecaae6d489ce9952569447`.
It remains `needs-adapter` rather than being falsely admitted as a direct test:
it imports Swift's internal `StdlibUnittest` module and also exercises throwing
streams, buffering, termination callbacks, deinitialization, and multiple
consumer behavior outside this slice.

The same-source `async-stream-suspended-consumer.swift` probe begins its
MainActor producer with `Task.yield()`. This establishes that the consumer
reaches an empty stream before either value is available, without asserting an
unrelated scheduler order. Apple Swift 6.3.3 compiled the probe in Swift 6
complete-strict mode with warnings as errors. Native and interpreted execution
both produced `2:6` in all twenty bounded repetitions; the canonical native
observation SHA-256 is
`5c90df842175db3c82f1151ac4cdbb285bc67a7e6f4136a0f0db96ea56d63b49`.

The captured RED was the interpreter diagnostic that `AsyncStream` had no
constructor. The general repair adds interpreter-owned unbounded stream
storage, producer continuation and iterator capabilities, and a runtime stream
record that owns task wait edges without retaining source storage. Empty
`next()` acquires a `.waitingForStream(streamID)` suspension lease; `yield`
resumes one consumer; `finish()` releases pending consumers with terminal
`nil`; and the record closes only after buffered values and runtime waits
drain. Type/protocol metadata and member dispatch are capability-based, with no
fixture or carrier-name route. Unsupported buffering policies produce an
explicit diagnostic rather than silently behaving as unbounded.

Focused white-box evidence observes one created stream, at least one real
stream suspension, and empty stream, task, structured-scope, task-group,
host-operation, and scheduler registries after completion. This is not a full
`AsyncStream` claim: consumer cancellation, termination callbacks,
producer/consumer lifetime, iterator copies, bounded buffering,
`AsyncThrowingStream`, and source continuation ownership remain open.

### M6 cancelled `AsyncStream` consumer and termination ordering

The next bounded probe parks a MainActor child in an empty
`AsyncStream.Iterator.next()`. The child sets `enteredNext` immediately before
the await; MainActor run-to-suspension prevents the parent from observing that
flag until `next()` has actually yielded the executor. The parent then cancels
the child. Swift 6.3.3 invokes the installed `onTermination` closure with
`.cancelled` before resuming `next()` with `nil`; the child returns normally
while `Task.isCancelled` remains true. Twenty native runs and twenty
interpreted runs all produced `true:true:cancelled:cancelled`, with canonical
native-observation SHA-256
`56a7e6749ac968b86afc193b51e0a60609748b599aff47a818c4c729d5c17616`.

The captured RED was precise: the existing stream reached the builder and
failed only because assignment to `Continuation.onTermination` was missing.
The repair adds a capability-based writable continuation property and stores
one source closure in stream storage. The runtime's existing cancellation
registration invokes it synchronously in the cancelling context, clears it
before invocation, and only then transitions the stream to terminal state and
releases the parked consumer. This also preserves Swift's edge case in which a
cancellation callback itself yields or finishes before the outer cancellation
finishes the stream. Legal callbacks are nonthrowing; an interpreter failure is
retained by the task cancellation machinery rather than swallowed.

Focused evidence observes a real stream suspension and complete cleanup of
the stream record, waiter edge, cancellation registration, source tasks,
structured scopes, groups, host operations, and scheduler. Explicit-finish
callback ordering, deinit/lifetime termination, iterator copies,
post-terminal yield results, multiple consumers, bounded buffering,
`AsyncThrowingStream`, and source continuations remain open.

### M6 value-copied `AsyncStream.Iterator`

The copied-iterator probe creates one seed iterator, then two MainActor tasks
each place a source-level value copy into a local mutable variable. Both call
`next(isolation: #isolation)`; the explicit isolation argument is required by
strict Swift 6 sendability checking and makes the executor contract explicit.
After both tasks are parked, the producer yields 4 and 6 and finishes. The
results are sorted so neither waiter assignment nor resume order is claimed.

Native Swift returned `4:6:2` in twenty runs. The interpreter RED instead
reported `attempt to await AsyncStream.Iterator.next() concurrently`: both
source copies still referenced one carrier and therefore one mutable guard.
The repair does not remove that safety guard. `RuntimeAsyncStreamIterator`
opts into the existing general `HostValueSemantic` protocol, so every source
storage copy creates a distinct mutable iterator token while retaining the
same stream storage. Native/interpreter parity is now 20/20 with canonical
native-observation SHA-256
`594fcb32181db21eab266d2a8ba6ccdbb8183487d482a5db80bee4e6990e9062`.

Focused evidence requires two real stream suspensions, distinct delivery of 4
and 6, and complete stream/task/scope/group/host-operation/scheduler cleanup.
This is a general value-ownership correction, not a fixture or AsyncStream
source-name branch. Deinit/lifetime termination, bounded buffering,
`AsyncThrowingStream`, and source continuations remain open.

### M6 explicit `AsyncStream.finish()` termination characterization

The explicit-finish probe installs `onTermination`, buffers value 3, calls
`finish()`, records an event immediately after that call returns, attempts to
yield 99, and calls `finish()` again. It then consumes the buffered value and
requests terminal state twice. Swift 6.3.3 and the interpreter both produced
`3:true:true:finished,after-finish:terminated` in all twenty repetitions. The
canonical native-observation SHA-256 is
`e5c5b4559a7c0e21a670c4febbf08d3bff2709e4d9580c49d0b93b5b69404f2b`.

The trace proves `.finished` is delivered synchronously before `finish()`
returns and only once, values buffered before termination remain consumable,
terminal `nil` is stable across repeated `next()` calls, and a post-terminal
yield returns `.terminated` without adding value 99. The cancellation slice's
general storage mechanism was already correct, so this was characterization
without a production change or fabricated RED. Focused evidence also requires
zero stream suspensions for the fully buffered path and complete cleanup of
stream, task, scope, group, host-operation, and scheduler registries.

Deinit/lifetime termination, iterator-copy and multiple-consumer behavior,
bounded buffering, `AsyncThrowingStream`, and source continuations remain open.

### M6 multiple parked `AsyncStream` consumers

The pinned swiftlang stream suite explicitly checks that `finish()` releases
multiple consumers. The local same-source adapter creates two independent
iterators over one empty stream. Each MainActor child increments a shared count
immediately before `next()`; the parent cannot observe count 2 until both calls
have yielded the actor. One continuation then calls `finish()`.

Swift 6.3.3 and the interpreter produced `true:true:2` in all twenty bounded
runs. The canonical native-observation SHA-256 is
`4b4ba4ee7f6ceb999b5122aea7f8ca85d6e4269f859552649e79676f384f2090`.
Both tasks receive terminal `nil`; their relative resume order is deliberately
absent from the observation. Focused evidence requires at least two
runtime-owned `.waitingForStream` suspensions and complete cleanup of both wait
edges, the stream record, source tasks, scopes, groups, host operations, and
scheduler. The existing waiter queue was already general, so this was another
characterization with no production change.

Deinit/lifetime termination, copied-iterator behavior, bounded buffering,
`AsyncThrowingStream`, and source continuations remain open.

### M6 unfinished `AsyncStream` scope-exit termination

The lifetime probe creates an unfinished stream in a nested function, installs
`onTermination`, discards the only sequence value, and lets the builder
continuation die with the call frame. The outer function reads callback-owned
state immediately after the nested call. This makes final-release ordering
observable without a sleep, task race, or scheduler-order assertion.

Apple Swift 6.3.3 compiled the same source in Swift 6 complete-strict mode with
warnings as errors and returned `cancelled` in twenty bounded runs. The
interpreter RED returned `none`: host ARC destroyed storage and removed its
runtime record, but destruction omitted the implicit cancellation callback.
The runtime now invokes the one-shot `.cancelled` callback synchronously from
unfinished storage deinit before closing the record. A source callback is
nonthrowing, but any defensive interpreter failure is retained and surfaced at
the next throwing evaluator safe point instead of being discarded by deinit.

Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`a78cb0e23e5bae8b901c6a25188a7d0233033b9177f49a4996a46316f8083d52`.
Focused evidence requires one created stream, zero consumer suspensions, and
empty stream, task, structured-scope, task-group, host-operation, and scheduler
registries after completion. Bounded buffering, `AsyncThrowingStream`, and
source checked continuations remain open after the lifetime follow-up below.

### M6 non-owning escaped `AsyncStream` producer continuation

The follow-up lifetime probe retains the builder continuation outside a nested
function while discarding the only sequence value. It reads termination as
soon as that function returns, calls `yield(9)` through the retained producer
handle, releases the handle, and reads termination again. This separates the
sequence/storage owner edge from producer-handle lifetime without a task or
scheduler assumption.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned `cancelled:terminated:cancelled` in twenty
bounded runs. The interpreter RED was `none:enqueued:cancelled`: its producer
continuation strongly retained storage, postponed implicit cancellation, and
accepted an element for a stream with no sequence or iterator owner.

The general ownership repair makes producer continuations non-owning handles;
sequence and iterator carriers retain storage. Owner release now invokes the
one-shot `.cancelled` callback immediately, an escaped handle reports
`.terminated` from later `yield`, and releasing it cannot fire termination
again. Native/interpreter parity is 20/20 with canonical native-observation
SHA-256
`7ca384f8a0176ff57fa4e3c0055a1ff7783123568a4e7552a39be27fae5a3e20`.
Focused evidence records one stream, zero consumer suspensions, and empty
stream/task/scope/group/host-operation/scheduler registries. Remaining bounded
buffering policies, `AsyncThrowingStream`, and source checked continuations
remain open.

### M6 `AsyncStream.bufferingNewest` capacity and eviction

The bounded-buffer probe performs four synchronous yields into
`.bufferingNewest(2)` before creating an iterator. It renders every
`YieldResult` and then drains the stream, so capacity, displaced-element, and
retained-value semantics are observable without task-order assumptions.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned
`enqueued(remaining: 1)|enqueued(remaining: 0)|dropped(1)|dropped(2)=>3,4,true`
in twenty bounded runs. The interpreter RED was its prior fail-closed
diagnostic that only `.unbounded` buffering was supported.

The general stream storage now owns an explicit buffering policy. Successful
bounded yields report the capacity remaining after insertion;
`.bufferingNewest` evicts and returns the oldest buffered element once full.
Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`cc694ba7c7410fafe79768c883e7b3072fc461257e94b6b5b1da4bfa050533f8`.
Focused evidence records one stream, zero consumer suspensions, and empty
stream/task/scope/group/host-operation/scheduler registries. The
`.bufferingOldest` follow-up is recorded below; zero-capacity boundaries,
`AsyncThrowingStream`, and source checked continuations remain open.

### M6 `AsyncStream.bufferingOldest` retention and rejection

The companion bounded-buffer probe performs four synchronous yields into
`.bufferingOldest(2)` before creating an iterator. It renders every
`YieldResult` and drains the stream, isolating retained-versus-rejected values
without task-order assumptions.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned
`enqueued(remaining: 1)|enqueued(remaining: 0)|dropped(3)|dropped(4)=>1,2,true`
in twenty bounded runs. The interpreter RED was its explicit fail-closed
diagnostic that `.bufferingOldest` was unsupported.

The existing policy-owned storage now accepts the oldest-retaining policy.
Successful inserts report remaining capacity; once full, later yields reject
and return the new element while preserving the existing buffer.
Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`ce750f2131b0fb4526ee96775de38a23ab5c0b853f4a751b1f11993b223052f0`.
Focused evidence records one stream, zero consumer suspensions, and empty
stream/task/scope/group/host-operation/scheduler registries. The zero-capacity
follow-up is recorded below; `AsyncThrowingStream` and source checked
continuations remain open.

### M6 zero-capacity `AsyncStream` buffering

The boundary probe creates `.bufferingNewest(0)` and `.bufferingOldest(0)`
streams sequentially. Each builder yields one distinct value and finishes
before iteration. Rendering the yield result plus the first iterator read
fully exposes zero-capacity retention without scheduler assumptions.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned
`newest:dropped(1):true|oldest:dropped(2):true` in twenty bounded runs. The
interpreter RED was its explicit fail-closed diagnostic for
`.bufferingNewest(0)`.

Both bounded policies now treat capacity zero as a permanent empty buffer and
return the newly supplied value from `.dropped`. Native/interpreter parity is
20/20 with canonical native-observation SHA-256
`835466db10fcdaa4c20da208c0dbea51584198f6d47292fdf4096c8310702079`.
Focused evidence records two streams, zero consumer suspensions, and empty
stream/task/scope/group/host-operation/scheduler registries. All nonnegative
`AsyncStream` buffering-policy shapes are now covered; negative capacities
remain explicitly unsupported. `AsyncThrowingStream` and source checked
continuations remain open.

### M6 unbounded `AsyncThrowingStream` source failure

The first throwing-stream probe creates an empty unbounded stream whose
MainActor producer yields once only after a suspension and then calls
`finish(throwing:)` with a source enum case. The consumer records the delivered
value and uses a case-specific catch, so value-before-error ordering and error
identity are observable without unrelated scheduler claims.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned `1:2:caught` in twenty bounded runs. The
interpreter RED was its missing `AsyncThrowingStream` constructor diagnostic.

The stream runtime now has a shared flavor-aware storage kernel. Both stream
families use the same buffer, waiter, suspension lease, producer handle,
iterator carrier, and cleanup ownership; a throwing terminal retains the original
`RuntimeValue`, and the next request rethrows it as `InterpretedThrow` after
the already-delivered waiter value completes. Native/interpreter parity is
20/20 with canonical native-observation
SHA-256
`b35c84ff9dee12339f6f150c9f5074154bc4ee6c478e988f675c468f1f291d56`.
Focused evidence records one stream, at least one consumer suspension, and
empty stream/task/scope/group/host-operation/scheduler registries. Normal
finish, throwing termination/cancellation callbacks, bounded buffering,
iterator-copy, and lifetime edges remain fail-closed or open; checked
continuations remain open.

### M6 normal `AsyncThrowingStream.finish()` termination

The normal-finish probe installs `onTermination`, synchronously yields one
value, calls `finish()`, records an event immediately after the call, and
attempts one later yield. Three sequential iterator reads expose retained
buffer state and stable terminal nil without scheduler assumptions.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned
`3:true:true:finished(nil),after-finish:terminated` in twenty bounded runs. The
interpreter RED rejected assignment to the throwing continuation's
`onTermination` property.

The flavor-aware storage now constructs the throwing stream's `.finished(nil)`
termination value, invokes its callback synchronously before returning from
normal finish, clears the callback one-shot, preserves buffered values, and
rejects post-terminal yield. Native/interpreter parity is 20/20 with canonical
native-observation SHA-256
`c208018808dc13933512c4d0274986274461222cfafc3806ebfcfd65d880f944`.
Focused evidence records one stream, zero consumer suspensions, and empty
stream/task/scope/group/host-operation/scheduler registries. Failure and
cancellation callback payloads, bounded buffering, iterator-copy, and lifetime
edges remain fail-closed or open; checked continuations remain open.

### M6 failing `AsyncThrowingStream.finish(throwing:)` termination

The companion finish probe installs `onTermination`, synchronously buffers one
value, calls `finish(throwing:)` with a source enum case, records an event after
return, and attempts a later yield. The callback reduces its associated error
to whether it contains the `stopped` case, avoiding module-qualified rendering
differences while retaining error identity.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned
`5:caught:finished-error,after-finish:terminated` in twenty bounded runs. The
interpreter RED was its explicit fail-closed diagnostic for a failure
termination callback.

The throwing termination carrier now preserves the original `RuntimeValue` in
`.finished(error)`. Storage invokes the callback synchronously and one-shot,
then iteration drains the prior value and rethrows the same source error;
post-terminal yield remains rejected. Native/interpreter parity is 20/20 with
canonical native-observation SHA-256
`f1ab4a6a9520f687349a779caf3d418c77cd925a5b9011cf4d98167001453935`.
Focused evidence records one stream, zero consumer suspensions, and empty
stream/task/scope/group/host-operation/scheduler registries. Cancellation is
covered by the next slice; bounded buffering, iterator-copy, and lifetime
edges remain fail-closed or open; checked continuations remain open.

### M6 cancelled `AsyncThrowingStream` consumer

The cancellation probe creates an empty unbounded throwing stream, installs an
`onTermination` callback, and starts a MainActor child that marks entry
immediately before awaiting `next()`. MainActor run-to-suspension makes the
parent's observation of that marker a causal proof that the consumer has
parked; cancellation then records callback ordering, terminal `nil`, and the
task's still-set cancellation bit without asserting physical executor order.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned `true:true:cancelled:cancelled` in twenty
bounded runs. The interpreter RED timed out: its explicit fail-closed guard
discarded the throwing callback and exited cancellation without resolving the
parked waiter.

Throwing and nonthrowing streams now share the same cancellation kernel. It
selects the flavor-specific `.cancelled` carrier, invokes the callback
synchronously and one-shot, and only then finishes the waiter with terminal
`nil`. Native/interpreter parity is 20/20 with canonical native-observation
SHA-256
`8248bec5de22875ebe62a306cd31b2da279ff76a8ae4e49dbe34dbb67c77ea93`.
Focused evidence records one stream, at least one consumer suspension, and
empty stream/task/scope/group/host-operation/scheduler registries. Bounded
buffering, iterator-copy, and lifetime edges remain fail-closed or open;
checked continuations remain open.

### M6 `AsyncThrowingStream.bufferingNewest` capacity and eviction

The first bounded throwing-stream probe performs four synchronous yields into
`.bufferingNewest(2)`, records every `YieldResult`, finishes normally, and then
reads sequentially to terminal `nil`. Program order proves every compared edge;
no task scheduling or physical executor observation participates.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned
`enqueued(remaining: 1)|enqueued(remaining: 0)|dropped(1)|dropped(2)=>3,4,true`
in twenty bounded runs. The interpreter RED was its blanket fail-closed
diagnostic for every bounded throwing-stream policy.

The flavor-aware constructor now admits the proven positive-capacity
`.bufferingNewest` subset into the existing shared policy-owned storage. Its
successful yields report capacity after insertion, full-buffer yields evict
and return the oldest element, and iteration retains only the two newest
values. Native/interpreter parity is 20/20 with canonical native-observation
SHA-256
`94d8669f69f6d2b253081259b081438fe1602acc67a8d2158bf00165c7923f7b`.
Focused evidence records one stream, zero consumer suspensions, and empty
stream/task/scope/group/host-operation/scheduler registries. Throwing-stream
`.bufferingOldest`, zero-capacity buffering, iterator-copy, and lifetime edges
remain fail-closed or open; checked continuations remain open.

### M6 `AsyncThrowingStream.bufferingOldest` retention and rejection

The companion bounded probe performs four synchronous yields into
`.bufferingOldest(2)`, records every `YieldResult`, finishes normally, and then
reads sequentially to terminal `nil`. Program order makes the retention and
rejection edges exact without asserting scheduler behavior.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned
`enqueued(remaining: 1)|enqueued(remaining: 0)|dropped(3)|dropped(4)=>1,2,true`
in twenty bounded runs. The interpreter RED was the policy capability
diagnostic that still rejected `.bufferingOldest`.

The same flavor-aware storage kernel now admits both proven positive-capacity
policies. `.bufferingOldest` reports capacity after successful insertion,
preserves the first elements once full, and returns each newly rejected value.
Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`6272b53c8b144fdc2dcd1a634e3d61f188df3a54ed9f5297cb29e1690bd0db68`.
Focused evidence records one stream, zero consumer suspensions, and empty
stream/task/scope/group/host-operation/scheduler registries. Zero-capacity
throwing buffering, iterator-copy, and lifetime edges remain fail-closed or
open; checked continuations remain open.

### M6 zero-capacity `AsyncThrowingStream` buffering

The boundary probe creates separate `.bufferingNewest(0)` and
`.bufferingOldest(0)` throwing streams. Each performs one synchronous yield
and normal finish before a sequential iterator read, making the yield result
and empty terminal state exact without scheduler assumptions.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned
`newest:dropped(1):true|oldest:dropped(2):true` in twenty bounded runs. The
interpreter RED was the remaining zero-capacity capability guard.

The temporary throwing-policy guard is now gone: both stream flavors share the
same unbounded and nonnegative bounded-policy kernel, while the common parser
continues to reject negative and unknown policies. At capacity zero neither
policy retains a value and each returns the supplied element as `.dropped`.
Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`72fec1663febaddef370e266d91916d3a79842c423b27d3dea3ed16093cadd0b`.
Focused evidence records two streams, zero consumer suspensions, and empty
stream/task/scope/group/host-operation/scheduler registries. Throwing-stream
iterator-copy and lifetime edges remain open; checked continuations remain
open.

### M6 copied `AsyncThrowingStream.Iterator` overlap trap

The probe copies one iterator, then uses `Task.immediate` to run the first
copy through the synchronous prefix of `next()` to its real empty-stream
suspension before construction returns. Calling `next()` through the second
copy is therefore causally overlapping; no sleep, waiter-count guess, or
physical-executor ordering is asserted.

Apple Swift 6.3.3 compiled the probe in Swift 6 complete-strict mode with
warnings as errors. All twenty bounded native processes terminated with the
runtime diagnostic `attempt to await next() on more than one task`. The first
interpreter observation instead timed out with its first consumer parked,
capturing the missing per-stream pending-next capability as RED.

The stream storage now owns one pending throwing-`next()` token, while the
nonthrowing `AsyncStream` iterator-copy behavior remains unchanged. A second
overlapping throwing-stream call raises a fatal runtime error. The general
gateway location helper also preserves `fatal` and `budgetTrip` metadata when
pinning an unlocated runtime failure to source, so source `try?`/`catch` cannot
turn a runtime trap into an ordinary error. The parity harness gained a
reusable `runtime-trap` assertion: native and interpreted observations run in
isolated processes, must exit nonzero, must contain their authored diagnostic
fragments, and a timeout is a failure rather than a successful trap.

Native/interpreter trap parity is 20/20 with canonical normalized native
SHA-256
`cab2a56c7fb9ca7135a95cc59a16b937f0a71d903ac195d2c7c79892126dea01`.
Focused cleanup evidence observes the first real stream suspension followed by
empty stream/task/scope/group/host-operation/scheduler registries after the
fatal failure escapes. Throwing-stream lifetime remains open; checked
continuations remain open.

### M6 unfinished `AsyncThrowingStream` scope-exit termination

The lifetime probe constructs an unfinished throwing stream in a nested
function, installs `onTermination`, and lets both the sequence and its builder
continuation die at return. The caller immediately reads callback-owned state.
That gives an exact ARC edge without a task, sleep, scheduler-order assumption,
executor claim, or physical-thread claim.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned `cancelled` in twenty bounded runs. The
interpreter RED was its explicit `AsyncThrowingStream implicit termination is
not yet supported` diagnostic.

The storage destructor no longer has a throwing-flavor exclusion. Both stream
flavors now use the same final-owner cancellation path, with the flavor-aware
`.cancelled` value passed synchronously before the runtime record closes.
Because destruction cannot throw, an interpreter failure from the source-level
nonthrowing callback is still retained for the owning task's next throwing safe
point rather than swallowed.

Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`165b1dc6bc0549403e963d0309882cc678f0ef9ff759b898171790b9d9641cc1`.
Focused evidence records one stream, zero consumer suspensions, and empty
stream/task/scope/group/host-operation/scheduler registries. Escaped throwing
producer-continuation lifetime remains the last stream-lifetime slice; checked
continuations remain open.

### M6 non-owning escaped `AsyncThrowingStream` producer continuation

The follow-up retains the builder continuation after its only unfinished
sequence owner leaves a nested function. In one MainActor task it records the
callback value immediately, yields through the escaped handle, releases that
handle, and reads callback state again. These three observations are
program-ordered; no scheduling, executor, or physical-thread behavior is
asserted.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned `cancelled:terminated:cancelled` in twenty
bounded runs. The interpreter produced the same output immediately. This is an
already-GREEN characterization, not a fabricated gap closure: the common
producer carrier was already weak for both flavors, so sequence/iterator
owners alone control storage lifetime.

Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`37ca395c9da690fb5efa6fba8dfec52ec9ee6ddce65ce54e759749b1a8932bb2`.
Focused evidence records one stream, zero consumer suspensions, and empty
stream/task/scope/group/host-operation/scheduler registries. At that
checkpoint, the evidenced stream-lifetime tail was closed and checked
continuation ownership plus executor-correct resumption became the next M6
gap.

### M6 checked-continuation value resume foundation

The first source-continuation probe calls `withCheckedContinuation` with
explicit `isolation: nil`. Its body creates a detached producer, that producer
yields, and then calls `resume(returning: 41)`. The compared result is causal;
the case makes no physical-thread, producer-start-order, or parallelism claim.

Apple Swift 6.3.3 compiled the unchanged source in Swift 6 complete-strict mode
with warnings as errors and returned `41` in twenty bounded runs. The initial
interpreter observation failed at the exact missing surface with `unresolved
identifier 'withCheckedContinuation'`.

Generated top-level dispatch now routes this declaration to a general checked-
continuation carrier and a runtime-owned record. The owner task holds the only
active ownership edge. A delayed call records
`waitingForContinuation(RuntimeContinuationID)`, uses the canonical suspension
lease to release and restore actor ownership, and returns only after the record
has one copied value and the required logical executor is restored. Immediate
resume is handled by the same state transition without fabricating a wait.
The registry is capped, successful resume is one-shot, and completion removes
both the registry entry and task-owner edge.

Native driver cancellation is deliberately split from Swift source
cancellation. An ordinary source `Task.cancel()` leaves a checked continuation
parked, as Swift requires; session or host teardown marks the internal record
aborted, wakes the driver, and unwinds with the non-source-catchable
infrastructure abort. A focused cancellation test proves that a never-resumed
root continuation cannot hang teardown and that every continuation, task,
scope, group, stream, host-operation, and scheduler registry is empty afterward.

Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`cdc0e05905b13ba3a3ef5a18fbefc271aedd047a639102d2b4ef965cc4f8c1a7`.
The generated declaration remains a known divergence: omitted and non-nil
isolation, `resume()` for `Void`, `resume(with:)`, checked throwing value/error
projection, double-resume and abandonment policy, escaped-token lifetime, and
unsafe continuations remained open at this checkpoint.

### M6 checked-continuation MainActor body and caller restoration

The next gap-closure probe calls the same public declaration from an
`@concurrent nonisolated` function and passes `MainActor.shared` explicitly.
The continuation body captures its logical lane, a detached producer parks on
the shared task-value gate, and a separate controller opens that gate. This
forces delayed resume without relying on ready-task order or on the producer's
physical worker thread.

Apple Swift 6.3.3 compiled the source with Swift 6 complete strict concurrency
and warnings as errors. Twenty native runs produced exactly
`worker|main|worker`: the caller entered on the cooperative executor, the
contextually isolated synchronous body ran on MainActor, and the caller was
restored after resume. The same-source interpreter RED rejected the call with
`withCheckedContinuation currently requires explicit isolation: nil`.

`MainActor.shared` now materializes the same logical executor capability used
by `#isolation`. The common synchronous closure invocation accepts a contextual
executor override, installs it for both runtime and lexical isolation while
the continuation body runs, and restores the caller before the runtime records
`waitingForContinuation`. The continuation record therefore retains the
caller's cooperative executor as its required resume executor rather than the
temporary MainActor body lane. Arbitrary source actors still fail closed before
a continuation record is allocated.

Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`610836ddc2aae4c485bd191467c390be96963743f86f353e6021d5790f655177`.
Focused evidence pins `worker|main|worker`, the cooperative owner executor,
canonical suspension ownership, complete cleanup, and the negative arbitrary-
actor boundary. The declaration remains a known divergence: omitted and
arbitrary-source-actor isolation, `resume()` for `Void`, `resume(with:)`,
checked throwing value/error projection, double-resume and abandonment policy,
escaped-token lifetime, and unsafe continuations remained open at this
checkpoint.

### M6 checked-throwing continuation value and error resume

The next gap-closure fixture executes two checked throwing continuations in
program order with explicit `isolation: nil`. The first detached producer
yields and calls `resume(returning: 23)`; only after that await completes does
the second producer yield and call `resume(throwing:)` with a source enum case.
The assertion therefore compares the exact value and matching source catch,
not detached-task order, physical threads, or parallel execution.

Apple Swift 6.3.3 compiled the fixture in Swift 6 complete-strict mode with
warnings as errors and produced `value:23|error:failed` in twenty bounded
runs. Before production routing, every interpreted repetition returned
`unexpected-value-error`: the first missing runtime entry failed inside the
probe's deliberately broad value-path catch.

Generated interface dispatch now attaches `withCheckedThrowingContinuation`
to the existing checked-continuation semantic core. The source carrier records
whether error resume is legal; the common runtime record gains a distinct
failed terminal outcome. `resume(throwing:)` copies the original source value,
wakes the one owner, restores its required executor, closes the registry and
task-owner edges, and only then projects that value through `InterpretedThrow`.
The nonthrowing carrier rejects error resume instead of silently accepting a
shape its `Never` failure type forbids.

Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`8b442dc2a3797ac2fad8592e65f585685487b6df933119da1c8aaa66d74af594`.
Focused evidence records two created records, two canonical suspensions, exact
value/error projection, and empty continuation/task/scope/group/stream/host-
operation/scheduler registries. At that checkpoint the declaration remained a
known divergence: throwing MainActor evidence, omitted and arbitrary-source-
actor isolation, `resume(with:)`, double-resume and abandonment policy,
escaped-token lifetime, and unsafe continuations were still open.

### M6 checked-throwing MainActor error restoration

The characterization fixture calls `withCheckedThrowingContinuation` from an
`@concurrent nonisolated` function with explicit `MainActor.shared` isolation.
Its synchronous body selects one source error based on its logical lane. A
detached producer enters a task-value gate before a controller opens it, then
resumes with that error. The exact assertion is `worker|main|worker`: caller
entry, MainActor body, and restored caller lane before matching catch. It does
not claim producer scheduling order, physical thread, or parallel execution.

Apple Swift 6.3.3 compiled the fixture in Swift 6 complete-strict mode with
warnings as errors and produced the exact output in twenty bounded runs. The
equivalent interpreted source was already GREEN in all twenty repetitions.
The shared contextual-executor invocation and failed continuation transition
already composed correctly, so this characterization required no production
change and does not invent RED evidence.

Focused runtime evidence holds the producer externally, observes one owner in
`waitingForContinuation` with cooperative required executor, then proves exact
source-error catch on that restored lane and empty continuation/task/scope/
group/stream/host-operation/scheduler registries. Native/interpreter parity is
20/20 with canonical native-observation SHA-256
`cf35e0f2fff2d29dd27a7b7b026bc52ecd705ce15e72919ac8fc24ae7d3b17fe`.
At that checkpoint, omitted and arbitrary-source-actor isolation, remaining
Result spellings, checked diagnostics/lifetime, and unsafe continuations were
still open.

### M6 checked-throwing continuation Result resume

The next gap-closure fixture passes two concrete
`Result<Int, CheckedThrowingContinuationResultProbeError>` values through the
generic `resume(with:)` overload. The success continuation completes before
the failure continuation is created; each detached producer yields before its
resume. The exact assertion therefore covers `value:29|error:failed` without
claiming producer scheduling order, physical threads, or parallel execution.

Apple Swift 6.3.3 compiled the fixture in Swift 6 complete-strict mode with
warnings as errors and produced the exact output in twenty bounded runs. The
interpreter RED timed out on repetition one: the detached producer rejected
the previously unrouted `with:` label, and its unobserved error left the
continuation owner parked.

The common checked-continuation carrier now accepts a case-shaped Result and
delegates `.success` to `resume(returning:)` and `.failure` to
`resume(throwing:)`. No second continuation state machine or cleanup path was
added: both branches retain the existing exactly-once transition, required-
executor restoration, source-error projection, and registry teardown.
Compiler preflight owns the nominal argument constraint and rejects a plain
`Int` where Swift requires `Result<Int, any Error>`.

Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`6400bcdc43bd6c03163fe44074b7e214559b9b36dbabb3a06017c268cb703c4e`.
Focused evidence records two created records, two canonical suspensions, exact
value/error projection, and empty continuation/task/scope/group/stream/host-
operation/scheduler registries. At that checkpoint, nonthrowing
`Result<T, Never>` and existential-error `Result<T, any Error>` spellings,
omitted and arbitrary-source-actor isolation, diagnostics/lifetime, and unsafe
continuations were still open.

### M6 checked-continuation Result spelling characterization

The follow-up fixture exercises two additional public overload shapes. A
nonthrowing `CheckedContinuation<Int, Never>` receives
`Result<Int, Never>.success`; a throwing
`CheckedContinuation<Int, any Error>` receives existential
`Result<Int, any Error>` success and failure values. The three continuation
calls are sequential, and each detached producer yields before resuming. The
exact assertion `never:31|any-success:37|any-error:failed` is therefore causal
without claiming producer scheduling order, physical threads, or parallel
execution.

Apple Swift 6.3.3 compiled the unchanged fixture in Swift 6 complete-strict
mode with warnings as errors and produced that output in twenty bounded runs.
Interpreted execution was already GREEN in all twenty repetitions. The common
case-shaped Result carrier already delegated the nonthrowing success and both
existential branches to the established returning/throwing transitions, so no
production change or artificial RED was introduced.

Focused runtime evidence records three created records, three canonical
suspensions, exact value/error projection, and empty continuation/task/scope/
group/stream/host-operation/scheduler registries. Production compiler
preflight accepts both overload spellings. Native/interpreter parity is 20/20
with canonical native-observation SHA-256
`5983e5accbf237aacb90f6930d587fc78001990db22efdb2f89d538c7b4a22d2`.
Omitted and arbitrary-source-actor isolation, double-resume and abandonment
diagnostics, escaped-token lifetime, and unsafe continuations remain open.

### M6 checked-continuation Void resume convenience

The next fixture binds the awaited success value as `Void`, passes explicit
`isolation: nil`, and starts one detached producer. That producer yields before
calling the zero-argument `resume()`. The exact assertion is only that the
owner returns `void-resumed`; it makes no ready-task-order, physical-thread, or
parallel-execution claim.

Apple Swift 6.3.3 compiled the source in Swift 6 complete-strict mode with
warnings as errors and returned `void-resumed` in twenty bounded runs. Before
the runtime change, interpreted repetition one timed out: the detached producer
rejected the zero-argument call, while the unobserved producer error left the
continuation owner parked indefinitely.

The common continuation member adapter now maps a zero-argument `resume()` to
the existing `resumed(Void)` terminal transition. The continuation registry,
canonical suspension lease, required-executor restoration, one-shot rule, and
cleanup path are unchanged. Swift exposes this convenience only when the
success type is `Void`; compiler preflight owns that static member constraint,
while the runtime adapter implements the selected valid call.

Native/interpreter parity is 20/20 with canonical native-observation SHA-256
`787b866a2ea70c81974998a32cc97636dd4069480fa4f301a357a20e16b1a14a`.
Focused evidence records one created record, one canonical suspension, exact
owner return, and empty continuation/task/scope/group/stream/host-operation/
scheduler registries. At that checkpoint, nonthrowing and existential-error
Result resume spellings, omitted and arbitrary-source-actor isolation,
double-resume and abandonment policy, escaped-token lifetime, and unsafe
continuations were still open.
