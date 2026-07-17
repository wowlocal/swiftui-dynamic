# Concurrency verification methodology

This document is the operational contract for claiming Swift Concurrency
support. `SwiftConcurrencyArchitecture.md` is the normative target design,
`ConcurrencyParity.md` is the human-readable current ledger, and
`Tests/ConcurrencyParity/Manifests/milestone-acceptance.json` is the
machine-checked acceptance source of truth.

## Evidence workflows

Every concurrency change uses one of two workflows.

### Gap closure

Use this when native Swift supports behavior that the interpreter does not.

1. Add or select a minimal same-source native fixture.
2. Record the native guarantee, including every order deliberately left
   unspecified.
3. Capture a failing interpreter observation before changing production code.
4. Implement a construct-level mechanism, not fixture- or source-name-specific
   behavior.
5. Make the differential case and focused ownership/state regression green.
6. Update the acceptance matrix and current ledger.

### Characterization

Use this when the interpreter already appears to match native Swift and the
work adds permanent evidence. A fabricated RED result is neither required nor
useful. The change must still add the native fixture, written guarantee,
same-source interpreter execution, focused state/cleanup assertions where
applicable, acceptance-matrix assignment, and green gates.

Commits and ledger entries identify which workflow was used. “No production
change required” is a valid characterization result, not a gap closure.

## Acceptance matrix

`milestone-acceptance.json` records:

- milestone status and dependency edges;
- independently reviewable requirements;
- `covered`, `open`, or `deferred` requirement status;
- runtime/compiler/generator/integration ownership and semantic coverage
  dimensions such as failure, cancellation, cleanup, lifetime, and stress;
- one primary `ownedCaseIDs` assignment for every parity fixture, reusable
  `evidenceCaseIDs`, and focused tests that supply executable evidence;
- an explicit evidence reference for every claimed coverage dimension;
- requirement-level dependency edges in addition to milestone closure edges;
- machine-readable ledger evidence/remaining-work text; and
- the precise remaining gap or deferral reason.

The acceptance manifest also records the bounded current execution tail and
the next major cycle. This is scheduling metadata, not a waiver of dependency
edges: a queued cycle may admit characterization, but it cannot close until
its declared prerequisites are covered.

## External completeness accounting

`generated-concurrency-api.json` is the generated active-SDK declaration
denominator for its explicitly declared scope.
`concurrency-capability-status.json` is the authored implementation and
verification overlay. The overlay pins the generated inventory digest, so SDK
surface drift requires review. A generated adapter route is dispatch metadata,
not evidence of runtime support. An inventory whose scope is explicitly
incomplete must never be reported as full `_Concurrency` completeness.

Generated rows are the SDK-slice denominator; milestone requirements are the
semantic denominator. `project-concurrency-roadmap-v1` is a versioned,
machine-checked reporting projection and is explicitly incomplete. Report
counts by implementation and verification status, not one blended percentage.
Every generated declaration starts `unreviewed` and may be promoted only by an
explicit stable-ID override carrying an implementation/verification
disposition. Positive claims require executable evidence; negative, excluded,
or deferred claims require an owned gap or deferral rationale. This prevents
name-level adapters and broad semantic fixtures from silently claiming every
SDK overload.

`open-gaps.json` is the companion negative-evidence registry. Every open
requirement owns at least one precise expected-versus-current observation.
Native-backed gaps additionally carry a compilable same-source fixture and a
green regression that proves the native baseline and the known interpreter
mismatch remain reproducible. When implementation closes the mismatch, that
regression deliberately fails until the gap is removed or promoted into the
green parity manifest.

`ConcurrencyMethodologyTests` rejects duplicate milestones/requirements,
unknown dependency or fixture IDs, dependency cycles, covered requirements
without executable evidence, completed milestones with incomplete requirements,
unmapped coverage dimensions, duplicate or unassigned parity ownership, orphaned
open-gap observations, and status/evidence/remaining-work drift between the
matrix and the human ledger. Fixture ownership is unique, but evidence reuse is
intentional and explicit. The shard-validator regression also proves exact
manifest/repetition/digest coverage and rejects malformed, overlapping,
incomplete, or duplicate completion receipts.

Milestone status meanings:

- `complete`: every requirement is covered; no open requirement remains;
- `provisional`: the implemented foundation is usable, but a newly identified
  semantic or verification gap prevents an unconditional completion claim;
- `partial`: a documented subset is implemented and later dependent work may
  proceed only through an explicit dependency edge;
- `not-started`: no claim is made for the milestone deliverable, even if the
  harness already contains a native oracle useful to it; and
- `deferred`: deliberately outside the current execution phase.

The roadmap is dependency-gated, not a literal single lane. Cross-cutting work
may land early only when its acceptance row names the dependency and it does
not rely on an unimplemented guarantee. In particular, compiler-derived
signature/effect metadata and isolation preflight are prerequisites for
closing actor/executor and SwiftUI lifecycle work.

A requirement may be `covered` only when each of its requirement-level
dependencies is also `covered`. Partial implementation may be recorded as
evidence on an `open` row, but readiness is never inferred from that evidence.

## Progress and forecast reporting

“On track” has three separate meanings and reports must not collapse them:

- semantic progress: covered versus open acceptance requirements and reviewed
  versus unreviewed capability rows within the generated inventory's declared
  scope;
- verification health: the latest bounded gate receipt and any baseline drift;
  and
- delivery forecast: progress against an explicit date, iteration, or budget.

If no delivery target exists, report only the first two and say that schedule
status is undefined. Do not infer a calendar promise from fixture counts.

At the end of an iteration, record requirements opened/closed, newly discovered
gaps, gate duration, and dependency changes. Forecast only dependency-ready
work and give a range when discovery risk is material. The demand-scoped M5
actor cycle is covered and provisional: every scoped requirement has
executable evidence, while its broad M4 and M7 dependencies retain explicitly
owned partial-surface gaps. A provisional milestone may therefore close its
own scoped requirements without claiming those broader dependencies complete.
The demand-scoped M6 protocol/stream/continuation cycle is closed; its broader
unsafe-ownership, negative-capacity, and upstream-adapter divergences remain
explicitly demand-deferred. The M8 view-owned async lifecycle cycle is covered
with repeated teardown and weak session-release evidence; M8 remains
provisional only because broad M5/M7 are partial. Its requirement-level
prerequisites are covered, so M9 physical parallelism is now the active cycle.
Its first architectural prerequisite is green: one immutable `ParsedProgram`
can cross detached readers and back independent cooperative sessions without
sharing evaluator state. Its second prerequisite makes each interpreter's
actual mutable storage root explicit: one MainActor-confined `RuntimeHeap`
owns globals, synthesized environment models, and SwiftUI state cells, with
identity, cross-interpreter isolation, and facade-lifetime coverage. This is
still characterization only. Its third prerequisite routes every `runAsync`
program entry through a real single-use `InterpreterSession` binding the
program, heap, cooperative runtime, runtime ID, lazy-global mode, and
completion policy. Compile-time RED and focused GREEN evidence cover binding,
live-ID propagation, unique identity, foreign-facade rejection, reuse
rejection, draining, and facade-independent heap/runtime lifetime. Existing
same-source async-let parity is rerun as the no-semantic-change check. Its
fourth prerequisite adds a target-neutral, all-branch, immutable Sendable
declaration index to `ParsedProgram`; each session resolves one build-specific
plan consumed by both mutable symbol materialization and top-level execution.
The compile-time RED was the absent index/plan API. Focused GREEN evidence
covers eight detached readers, distinct iOS/macOS nominal + typealias +
extension plans from one parsed source, and 209 declaration/language/async/
compiler-preflight tests. The fifth prerequisite replaces bare production
runtime IDs with an explicit `RuntimeEntry` capability inherited by each source
task. Its compile-time RED was the missing type/context capability;
focused ownership GREEN proves callback parent/child identity, outliving-task
retention, final release, and distinct callback entries over one confined heap.
A causally gated Swift 6 same-source probe establishes the overlap policy in
twenty repetitions: a second MainActor callback may run while a task from the
first is parked and completes before that task resumes. Cooperative overlap is
therefore supported; physical concurrent heap access remains unclaimed.
Its sixth prerequisite removes the mutable function/initializer metadata
caches from the facade. One immutable Sendable all-branch callable index now
belongs to `ParsedProgram`; the program entry and escaped callbacks retain it,
and runtime symbol construction consumes it. The compile-time RED was the
absent index/summary/runtime-entry API. GREEN evidence covers eight detached
readers, session and callback propagation, 145 affected runtime/language/
compiler tests, and twenty unchanged `extract-isolation-nonisolated` native/
interpreter repetitions under Apple Swift 6.3.3. This was an already-GREEN
semantic characterization, not a fabricated runtime mismatch. Its seventh
prerequisite extends the index across readable accessor blocks and subscript
declarations. The compile-time RED was the absent accessor/subscript metadata
API. GREEN proves getter effects, setter names, subscript parameters/results,
observer exclusion, and detached-reader Sendability; 181 affected tests pass.
The causal `actor-subscript-async-exits` fixture remained exact in twenty
native/interpreter repetitions with no physical-thread claim. Its eighth
prerequisite introduces one immutable `ParsedProgramMetadata` propagation
capability so future indexes do not add parallel fields to every session,
entry, and closure. The compile-time RED was the absent program/entry metadata
API. GREEN covers detached readers, session binding, an escaped callback after
a different program becomes the facade fallback, callback-created tasks, and
real SwiftUI task entry. The SwiftUI cancellation check exposed a test race:
the source `started` event precedes registration of its sleep suspension. The
test now waits causally for both that event and runtime `.waiting`, with a
record dump on failure. The existing `extract-isolation-nonisolated` result is
unchanged in twenty native/interpreter repetitions. Extending immutable
nominal/property-storage, call-site, and compiler metadata, moving mutable
symbols and evaluation fully behind the session, worker-safe heap
classification, physical workers, cooperative-versus-parallel differential
evidence, and TSan remain open.

## Process and liveness isolation

Every native and interpreted runtime repetition has a hard wall-clock deadline.
A timeout terminates the process tree, records the case ID and repetition, and
fails the gate. No concurrency deadlock may turn into an indefinite test or CI
wait.

Interpreted parity runs use a fresh process whenever task-local/static state,
executor queues, cancellation, callbacks, or runtime registries could leak
between observations. A fresh `Interpreter` in a shared test process is useful
but is not process-isolation evidence.

Parallel shards emit their selected and completed case IDs. The coordinator
accepts the board only when their union is disjoint and exactly equals the
filtered manifest. Process exit alone is not coverage evidence.

Cleanup claims name their proof explicitly: empty runtime registries, weak
reference deallocation, successful child-process termination, and/or an RSS
plateau across repeated sessions. A fresh process prevents cross-case state
leakage but does not by itself prove that an escaped handle released its
session; that stronger claim needs weak-lifetime or plateau evidence.

## Assertion and stress rules

Exact traces are used only when program order, an await, actor serialization,
or a controlled barrier establishes every compared edge. Otherwise use an
allowed set, partial order, or invariant predicate.

An allowed-set member must be established by a native execution whose barriers
force that alternative, or by a separately committed compiler/interface
contract explicitly identified in the manifest. An interpreter-only outcome
must not become permitted merely to avoid asserting scheduler order.

Runtime traps use a distinct process-isolated assertion. Each native and
interpreted child must terminate with a nonzero status and contain its authored
diagnostic fragment. A successful exit, missing fragment, or deadline
termination fails the case; a hang is never normalized into a trap. This
assertion is reserved for native behavior that cannot be expressed as a
catchable source error.

Runtime warnings use a separate successful-process assertion. Each native and
interpreted child must exit zero and contain every authored warning fragment;
missing fragments, nonzero exit, or deadline termination fail the case. Only
after those checks may the harness normalize the diagnostic to a stable
`runtime-warning` marker. A host cleanup policy may drain work that native
process exit abandons, but it runs after the source observation and is recorded
explicitly in the case manifest.

`stress` means more than process completion. Every stress case names a checked
invariant or expected terminal sentinel. Race exploration uses recorded seeds
and prints the replay seed on failure. The required suite grows by milestone:

- task runtime: cancel-versus-complete and waiter graph cleanup;
- suspension: cancel-versus-clock-wake and handler register/unregister;
- structured concurrency: bounded fanout/depth, cancellation storms, nested
  composition, and registry/weak-reference cleanup;
- actors/executors: mailbox/reentrancy schedule exploration; and
- physical parallelism: Thread Sanitizer plus semantic parity between
  cooperative and parallel modes.

Nightly or scheduled stress may use more repetitions than the closing gate,
but the ordinary gate retains at least one non-vacuous seeded run.

## Verification receipt

Every closing gate writes a machine-readable receipt before temporary logs are
removed. It includes:

- repository commit and dirty/worktree fingerprints at both start and finish,
  with any mid-run source drift forcing RED, plus parity/acceptance/capability
  manifest digests and the inventory/status pin result;
- selected/completed parity case IDs and repetition counts;
- build/test Swift driver plus native-oracle compiler path/version, SDK
  path/version, targets, and flags;
- worker allocation and stage deadlines;
- stage status, duration, aggregate counters, and timeout/crash details; and
- per-case hashes of sorted native observations, so toolchain drift can be
  reviewed without treating incidental repetition order as semantic.

Receipts are build artifacts, not source baselines. CI retains them with the
job; local runs print their path. The receipt binds the acceptance-matrix
digest, avoiding a circular source-file pointer back to a receipt produced from
that source. Toolchain changes are reviewed from receipt diffs and never
silently update an expected semantic result.

RED receipts are first-class evidence: they retain failed worker/board exit
statuses, timeout text, interruption stage, validator diagnostics, and bounded
log tails before temporary logs are removed. Receipt creation failure keeps the
full temporary log directory.

Use two verification lanes when practical:

1. the pinned reference toolchain used for reproducible release evidence; and
2. an active-toolchain canary that reports native changes without automatically
   redefining compatibility.

## Interface-first concurrency surface

Signatures, overloads, generic constraints, effects, isolation, and ordinary
members encoded by `_Concurrency.swiftinterface` or SDK interfaces are
generated metadata. Runtime-owned task, cancellation, structured-scope,
executor, and continuation behavior is attached through reusable semantic
intrinsics.

Do not add a raw source-name branch for each newly encountered `Task`, group,
actor, stream, or SwiftUI API. For SwiftUI, `AGENTS.md` remains binding: ordinary
surface comes from BridgeGen, and only interface-inexpressible lifecycle/
identity behavior may use a small documented SwiftUI-magic primitive.

## Milestone closure review

Before changing a milestone to `complete`:

1. all acceptance requirements are covered and machine validation passes;
2. applicable success, failure, cancellation, early-exit, and teardown paths
   have native evidence;
3. race/stress and resource-limit requirements for that milestone pass;
4. focused, full-suite, repository, and fresh-process cleanup gates pass;
5. the verification receipt is retained and reviewed;
6. the target/current architecture snapshot and parity ledger agree; and
7. unsupported surface is diagnosed rather than absorbed.

Finding a native-backed gap after closure changes the milestone to
`provisional` until the gap is fixed or explicitly re-scoped. This is normal
evidence-driven maintenance, not a reason to weaken the new fixture.
