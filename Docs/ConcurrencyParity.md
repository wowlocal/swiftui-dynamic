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
| M0 native parity infrastructure | implementation complete; exit blocked | Same-fixture runner, compiler fingerprint, bounded processes, repeated runtime probes, diagnostic fixture, negative control, cleanup probe | Restore the repository corpus floor and rerun the closing gate |
| M1 task-owned evaluator context | not started | Current implementation still uses `withParkedEvaluatorFrames` | Introduce `EvaluationTaskContext` after M0 closes |
| M2 task runtime | not started | `RuntimeTaskHandle` is observational and `value` does not suspend | Task IDs, outcomes, waiters, kinds, session policies |
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
| `interleavedTasksKeepIndependentLexicalFrames` | Fixed interpreter trace | Important regression, but current shared-frame architecture is still order-sensitive |
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
- `swift test --filter 'AsyncExecutionTests|HostSignatureTests'`: 28 tests in
  2 suites passed;
- fresh runner process,
  `swift test --skip-build --filter AsyncExecutionTests.completedSessionsReleaseSchedulerTracking`:
  passed and exited, with scheduler tracking empty after consecutive sessions;
- full `swift test`: 703 tests in 141 suites passed;
- `Scripts/gate.sh`: suite 703/703, live 5/5, and API parity
  345 match / 0 diverge / 0 interpreter errors all passed; corpus remained
  675/680 against the ratcheted 678 floor, so the closing gate correctly
  remained red.

The forced corpus sweep identified all non-passing units:

- `Widgets`: existing ledgered out-of-scope extension surface;
- `oss:Mythic`: existing ledgered app-authored DEBUG precondition crash;
- `CustomTabView` and `oss:Ollamac`: the same `$projection` lookup regression;
- `oss:iina`: an attempted read through a deallocated `unowned` reference.

The three non-ledgered regressions are in the concurrently changing production
tree and predate the final M0 harness revision. M0 itself adds only documentation,
fixtures, and tests; `ProjectCheck` fingerprints `Package.swift` and `Sources`,
so none of the M0 paths can change its verdict. M0 is therefore implemented and
locally verified, but its milestone exit stays blocked until the repository
corpus floor is restored. The floor and tests have not been weakened.
