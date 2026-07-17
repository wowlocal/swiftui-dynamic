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
unchanged in twenty native/interpreter repetitions. Its ninth prerequisite
adds all-branch nominal headers to that same composite capability. The
compile-time RED was the absent nominal index/summary API. GREEN covers all five
nominal kinds, inactive conditional branches, nested declarations, attributes,
inheritance, generic constraints, eight detached readers, session and escaped-
callback provenance, and the existing struct/class/enum/actor/protocol
materialization suites. The causal `custom-global-actor-isolation` fixture is
unchanged in twenty native/interpreter repetitions. Its tenth prerequisite
adds all-branch variable/property storage headers to the composite capability.
The compile-time RED was the absent property index/summary and compatibility
accessor API. GREEN covers `let`/`var`, static, lazy, explicit nonisolation,
TaskLocal, weak/unowned, tuple, stored/computed, and observer metadata; eight
detached readers; pure foreign-syntax fallback; session and escaped-callback
provenance; 215 affected storage/declaration/actor/ARC/value tests; and twenty
unchanged `actor-initialization` repetitions. The fixture proves synchronous
actor initialization and first isolated-method ownership without asserting a
physical thread. Extending immutable remaining member, call-site, and compiler
metadata, moving mutable symbols and evaluation fully behind the session,
worker-safe heap
classification, physical workers, cooperative-versus-parallel differential
evidence, and TSan remain open.

Its eleventh prerequisite adds all-branch enum-case headers to the composite
capability. The architecture workflow is a gap closure: the captured
compile-time RED had no `ParsedEnumCaseMetadataIndex`, summary, compatibility
accessor, or runtime lookup. The semantic workflow is an already-GREEN
characterization: no runtime mismatch was invented. FoodTruck supplies the
within-slice demand citations for backticked `User.default`, labeled
`User.authenticated(username:)`, unlabeled `Panel.city(City.ID)`, conditional
cases, and `BrandHeader.HeaderSize` Double raw values. GREEN covers exact
all-scope/all-branch summaries, labels and type spellings, raw expressions,
eight detached readers, pure foreign-syntax fallback, session/callback
provenance, and enum materialization. The same source crosses an associated
enum value through an actor and observes backticked and raw-value cases;
Apple Swift 6.3.3 and the interpreter both produce
`authenticated:foodtruck|default|1.0:0.5` in twenty bounded repetitions. No
scheduler order or physical thread is inferred. Uncited case attributes and
`indirect` semantics remain outside this slice. Remaining member families,
call-site/compiler metadata, mutable-symbol/evaluator migration, worker-safe
heap classification, physical workers, mode-differential evidence, and TSan
remain open.

Its twelfth prerequisite adds all-branch extension headers to the composite
capability. The architecture workflow is a gap closure: the captured compile-
time RED had no `ParsedExtensionMetadataIndex`, summary, compatibility
accessor, composite component, or runtime lookup. The semantic workflow is an
already-GREEN characterization. FoodTruck supplies the within-slice demand
citations for dotted `Donut.Topping` extensions, the retroactive
`AuthorizationHandlingError: LocalizedError` conformance, and
`ClosedRange where Bound: BinaryFloatingPoint`. GREEN covers exact all-scope/
all-branch summaries, extended and inherited type spellings, generic
requirements, attributes, modifiers, eight detached readers, pure foreign-
syntax fallback, session/callback provenance, and existing extension
materialization. A same-source value crosses an actor boundary after using a
dotted conforming extension and a matching constrained extension; Apple Swift
6.3.3 and the interpreter both produce `true:42:21` in twenty bounded
repetitions. No behavior for a nonmatching generic constraint, scheduler
order, or physical thread is inferred. Remaining member families, call-site/
compiler metadata, mutable-symbol/evaluator migration, worker-safe heap
classification, physical workers, mode-differential evidence, and TSan remain
open.

Its thirteenth prerequisite adds all-branch type-alias headers to the
composite capability. The architecture workflow is a gap closure: the captured
compile-time RED had no `ParsedTypeAliasMetadataIndex`, summary, compatibility
accessor, composite component, or runtime lookup. The semantic workflow is an
already-GREEN characterization. FoodTruck supplies demand citations for the
conditional private top-level `ViewControllerRepresentable` and member
`ViewController` aliases in `DetailedMapView`; corpus regressions cite generic
aliases used as extension targets. GREEN covers exact all-scope/all-branch
summaries, full and normalized targets, generic parameters/requirements,
attributes, modifiers, nominal-versus-tuple targets, eight detached readers,
pure foreign-syntax fallback, session/callback provenance, and top-level,
member, local, generic-extension, and global-actor-alias consumers. A selected
top-level and member alias constructs a value that crosses an actor boundary;
Apple Swift 6.3.3 and the interpreter both produce `mac:42` in twenty bounded
repetitions for the non-watchOS branch. The harness's legacy iOS-shaped build
identity is not used to claim positive macOS predicate behavior; target-aware
platform selection remains separate M7 project evidence. No inaccessible
inactive-branch behavior, scheduler order, or physical thread is inferred.
Remaining member families, call-site/compiler metadata, mutable-symbol/
evaluator migration, worker-safe heap classification, physical workers, mode-
differential evidence, and TSan remain open.

Its fourteenth prerequisite adds all-branch deinitializer headers to the
composite capability. The architecture workflow is a gap closure: the captured
compile-time RED had no `ParsedDeinitializerMetadataIndex`, summary,
compatibility accessor, composite component, or runtime lookup. The semantic
workflow is an already-GREEN characterization rather than an invented runtime
mismatch. FoodTruck cites the ordinary `deinit` on its `@MainActor`
`StoreMessagesManager`. GREEN covers all-scope/all-branch body, attribute, and
modifier facts, explicit isolated/nonisolated classification, eight detached
readers, pure foreign-syntax fallback, session/callback provenance, and the
existing teardown consumers. Apple Swift 6.3.3 and the interpreter both
produce `body|none:foodtruck|after` in twenty bounded repetitions: the ordinary
deinitializer sees nil isolation and completes before execution continues
after final release. No isolated/custom-global-actor expansion, scheduler
order, physical thread, or physical parallelism is inferred. Remaining member
families, call-site/compiler metadata, mutable-symbol/evaluator migration,
worker-safe heap classification, physical workers, mode-differential evidence,
and TSan remain open.

Its fifteenth prerequisite extends the all-branch callable index with immutable
function names, modifier names, and static/class-versus-instance placement.
The architecture workflow is a gap closure: the captured compile-time RED had
no `typeMemberFunctionCount` or `modifiedFunctionCount` summary fields and no
`name`, `modifierNames`, or `isTypeMember` callable-entry facts. Struct/enum
method registration, global binding, closure naming, and lexical capture
discovery now consume the index with pure foreign-syntax fallback; session and
escaped-callback provenance retain the originating snapshot. FoodTruck cites
`static func` demand in `City`, `StoreMessagesManager`, and `TaskSeconds`.
The semantic workflow is an already-GREEN characterization. Its first apparent
`none` result came from a parity helper that recognized source-actor instances
but not the runtime carrier for `MainActor.shared`; correcting that generic
helper before the production change made the unchanged interpreter match
Swift. Apple Swift 6.3.3 and the interpreter both produce
`type:same:foodtruck|instance:same` in twenty bounded repetitions, including
the exact value after an awaited actor hop. `class` placement is indexed as a
syntax fact, but no class-method dispatch, scheduler order, physical thread, or
unrelated overload is inferred. Remaining member families, call-site/compiler
metadata, mutable-symbol/evaluator migration, worker-safe heap classification,
physical workers, mode-differential evidence, and TSan remain open.

Its sixteenth prerequisite extends initializer entries in the all-branch
callable index with immutable bodies, attribute and modifier names,
failable/Codable classification, and explicit nonisolated/MainActor facts.
The architecture workflow captured a compile-time RED for absent summary and
entry fields. The semantic workflow is a gap closure: the first preliminary
run incorrectly passed because the interpreter-side helper compared its
dynamic executor rather than native Swift's lexical `#isolation`; correcting
that generic oracle before production exposed the repeatable native
`isolated:same` versus interpreted `isolated:none` mismatch. One shared
initializer-closure builder now supplies metadata and declaration isolation to
struct/class/actor, enum, extension, superclass, synchronous, and suspending
paths; selection, synthesized arguments, optional projection, and bridge
Codable discovery use the same index. FoodTruck cites nonisolated initializers
on its MainActor StoreKit controller classes, the ordinary `StoreActor`
initializer, and `Subscription.init?`. Apple Swift 6.3.3 and the interpreter
both produce
`isolated:same:foodtruck|nonisolated:none:store|accepted|rejected` in twenty
bounded repetitions after the fix, including exact preservation across an
awaited actor hop. Existing actor and async-initializer parity remains green.
No new async/custom-global-actor initializer, scheduler-order, physical-thread,
or physical-parallelism claim is inferred. Remaining member families,
call-site/compiler metadata, mutable-symbol/evaluator migration, worker-safe
heap classification, physical workers, mode-differential evidence, and TSan
remain open.

Its seventeenth prerequisite completes the indexed function-declaration body
boundary. The architecture workflow captured a compile-time RED for missing
`ParsedFunctionMetadata.body` and `bodylessFunctionCount`; immutable entries
now distinguish executable bodies from bodyless requirements and extern
absorbers. Every synchronous/suspending global, member, static, enum,
extension, operator, pattern, and public-evaluation path consumes body,
parameter/default/label, and `mutating` facts from that index with pure
foreign-syntax fallback. Detached readers, session/runtime-entry provenance,
and representative dispatch regressions cover ownership. FoodTruck supplies
133 declaration bodies spanning async account/StoreKit work, layouts and local
helpers, mutating model operations, static reducers/operators, and modifiers.
The semantic workflow is an already-GREEN characterization: Apple Swift 6.3.3
and the interpreter still produce `type:same:foodtruck|instance:same` in all
twenty bounded `callable-placement-metadata` repetitions after an awaited actor
hop. Nineteen focused dispatch/ownership tests, forty-two methodology checks,
and those twenty parity repetitions completed in thirteen seconds. No
bodyless invocation, new isolation rule, scheduler order, physical
thread, or physical parallelism is claimed. Remaining member families,
call-site/compiler metadata, mutable-symbol/evaluator migration, worker-safe
heap classification, physical workers, mode-differential evidence, and TSan
remain open.

Its eighteenth prerequisite introduces the immutable call-site argument
boundary. The architecture workflow captured a compile-time RED for the absent
`ParsedCallSiteMetadataIndex`, `ParsedProgram.callSiteMetadataIndex`, and
composite capability edge. Entries preserve ordinary labels/expressions, first
and additional trailing closures in source order, and bare unqualified direct-
reference spelling; compiler-only `#if` predicate calls are excluded. The
synchronous and suspending collectors now consume the same indexed shape, and
the bounded async-operation provenance rule uses its direct-reference fact.
FoodTruck supplies 41 additional-trailing-closure spellings and three direct
`Button(action:)` uses of `onPurchase`/`onDismiss`. The semantic workflow is an
already-GREEN characterization: Apple Swift 6.3.3 and the interpreter preserve
the exact explicit-nil executor-preference task-state/error projection in all
twenty bounded `with-task-executor-preference-nil` repetitions. Four native
shards each reported SHA-256
`8cd6f4abe47320a422f3c0da80530aa47491ddb0eace1d6087040e1f16dd5e86`.
The final prebuilt focused gate completed ten tests in four suites, all
forty-two methodology checks, and all twenty parity repetitions in two
seconds.
Qualified/converted references, full overload identity, new executor behavior,
scheduler order, physical thread, and physical parallelism are not inferred.
Remaining member families, call-site semantic resolution, compiler metadata,
mutable-symbol/evaluator migration, worker-safe heap classification, physical
workers, mode-differential evidence, and TSan remain open.

Its nineteenth prerequisite introduces the immutable all-branch member plan.
The architecture workflow captured a compile-time RED for the absent
`ParsedMemberMetadataIndex`, composite parsed-program edge, and runtime member
resolver. The index classifies direct members and preserves nested ordered
conditional clauses; a session resolves one active sequence with its build
identity before struct/class/actor/enum/extension symbol materialization. The
first same-source probe exposed an unrelated enum `String(describing:)`
formatting difference, so the oracle was corrected before production to use a
String raw value. The unchanged interpreter was then GREEN, and Apple Swift
6.3.3 plus the post-migration interpreter both produced
`foodtruck:7:type:extension:regular:nested` in all twenty bounded
`conditional-member-metadata` repetitions. Four native shards each reported
SHA-256
`8c1f91f180b8517d68ab0a40b3f0cc2ab73a32db163c2d296b1bc25d9561a937`.
The final prebuilt focused gate completed sixteen tests in ten suites, all
forty-two methodology checks, and all twenty parity repetitions in one second.
FoodTruck supplies five conditional member regions across `StoreSupportView`,
`DonutGalleryGrid`, `OrdersView`, and `DetailedMapView`. Positive-watchOS
selection, new member semantics, compiler-only signature parsing, scheduler
order, physical thread, and physical parallelism are not inferred. Remaining
member semantics, call-site/compiler metadata, mutable-symbol/evaluator
migration, worker-safe heap classification, physical workers,
mode-differential evidence, and TSan remain open.

Its twentieth prerequisite verifies target-plan ownership rather than inventing
a new runtime semantic. The architecture workflow first captured a compile-time
RED for the absent `ResolvedProgramPlan`, parsed-program resolver, and
session/runtime-entry/closure plan edges. The immutable target evaluator and
both declaration indexes were then made callable outside MainActor, and one
session-owned plan was propagated unchanged through escaped callbacks,
SwiftUI entries, and their source tasks. Identity assertions deliberately
prepare a different program before invoking an older closure, so a fallback to
mutable facade state is observable.

The native semantic baseline was captured before production changes with the
existing `conditional-member-metadata` case. Apple Swift 6.3.3 selected the
non-watchOS declaration/member branches, carried the result through an actor
hop, and produced
`foodtruck:7:type:extension:regular:nested` in all twenty bounded
repetitions. Four native shards each reported SHA-256
`8c1f91f180b8517d68ab0a40b3f0cc2ab73a32db163c2d296b1bc25d9561a937`.
The same exact case remained GREEN after migration; no duplicate fixture or
post-hoc oracle was introduced. The final prebuilt focused gate completed
thirteen ownership/dispatch tests in seven suites, all forty-two methodology
checks, and all twenty parity repetitions within two seconds. FoodTruck's five
conditional member regions bound the demand. New branch semantics, positive-
watchOS behavior, scheduler order, physical threads, and physical parallelism
are not inferred.

Its twenty-first prerequisite verifies mutable program-state ownership. The
architecture workflow captured a compile-time RED for the absent
`RuntimeProgramState` and the missing session/runtime-entry/closure ownership
edges. The focused test prepares two sessions before running either, then
requires each session to materialize only its own nominal registry. A second
test prepares a newer session before invoking an older escaped callback and
requires the callback root plus its spawned task to observe the exact original
state identity. A weak-reference assertion covers the simple session-owned
lifetime without claiming that every future symbol/value graph is cycle-free.

The semantic workflow is an already-GREEN characterization using the existing
`host-callback-overlap` fixture. Its continuation gate establishes only the
causal `worker-started`, `second-return`, `worker-resumed` trace: a later
synchronous MainActor callback runs while the first callback's task is parked,
and that task resumes afterward. Native Swift 6.3.3 was compiled and captured
before production changes in twenty bounded runs. The same fixture is reused
unchanged after migration; no physical-thread or unrelated scheduler-order
claim is allowed. The closing gate must also run both session/state ownership
suites and the complete methodology suite from the prebuilt bundle.

Its twenty-second prerequisite verifies immutable source-map ownership. The
architecture workflow first captured a behavioral RED: an escaped closure from
`Origin.swift`, invoked after the facade ran `Newer.swift`, located its runtime
error at the newer converter's `41:2` rather than the authored `3:9`. The fix
adds file identity and the immutable converter to `ResolvedProgramPlan`; runtime
diagnostics select it through the exact `RuntimeEntry`, while parsing and
synchronous compatibility work retain a separately named fallback.

The native semantic baseline was captured before production changes with Apple
Swift 6.3.3, macOS SDK 26.5, and target `arm64-apple-macosx26.0`. An escaped
async closure yielded and then evaluated `#line`; its authored line remained
`4`. The manifest-backed `source-provenance-after-suspension` version places
that expression on line `5`, and native Swift plus the interpreter produce
exact output `5` in twenty bounded runs. Four native shards each report
SHA-256
`322f82b1ee560245f7819acb862b0cc122800997a5b88693393f20d65762314b`.
Only lexical source provenance is asserted. Scheduler order, worker identity,
physical threads, and physical parallelism remain unasserted. The closing gate
must include the cross-program callback regression, the complete runtime-entry
ownership suite, all methodology checks, and all twenty focused parity runs.
The canonical parallel iteration completed thirteen ownership/source-map tests
in seven suites, all forty-two methodology checks, and all twenty parity
repetitions on four workers in 1.8 seconds.

Its twenty-third prerequisite verifies canonical runtime ownership of session-
owned unstructured and detached handles. The architecture workflow first
captured a compile-time RED requiring a strong runtime handle registry, task-
capacity guard, session-scoped lookup, and idempotent canonical release; those
capabilities existed only as mutable facade bookkeeping. Production launch,
autonomous completion cleanup, drain, and cancellation must now use the runtime
API, while the facade may expose only a read-only compatibility view.

The semantic workflow is an already-GREEN characterization using the unchanged
`task-handle-deallocation` fixture. Before production changes, Apple Swift
6.3.3 and the interpreter both produced exact output `completed,active` in
twenty bounded runs. Four native shards each report SHA-256
`372f912e1aed613d03587d6bd5fc29d6c08f1299ce903484b08e01c8e89a12f9`.
The post-change differential must preserve that exact observation. The focused
ownership test drops its local `RuntimeTaskHandle`, requires the runtime to
retain it and its active record, and then requires canonical release to remove
both. The closing gate must include session drain/cancel, autonomous cleanup,
structured-child lifetime, real SwiftUI cancellation, all methodology checks,
and all twenty focused parity repetitions. No physical-thread or parallel-
execution assertion is allowed.
The canonical parallel iteration completed eleven targeted tests in four
suites, all forty-two methodology checks, and all twenty parity repetitions on
four workers in 1.9 seconds.

Its twenty-fourth prerequisite verifies runtime ownership of evaluator-context
identity allocation. The architecture workflow captured a compile-time RED:
`CooperativeConcurrencyRuntime` had no context factory, while `Interpreter`
owned the monotonic counter and constructed every program-root, callback, and
source-task context. Production async entry points must now use one runtime
factory; only the facade's synchronous compatibility context may retain the
reserved ID `0`.

The semantic workflow is an already-GREEN characterization using the unchanged
`task-owned-evaluator-context` fixture. Apple Swift 6.3.3 and the interpreter
each preserve the same 100-event multiset across a forced `Task.yield()` in
twenty bounded repetitions. The event order is unspecified, so native shard
hashes may differ and no total ordering is asserted. The post-change
differential must preserve the multiset. Focused coverage requires unique
nonzero runtime-allocated context IDs plus source-task and async-initializer
context cleanup, stale-context rejection, suspension-budget renewal,
callback/task entry propagation, program-session identity, and real SwiftUI
async entry. A clean rebuild is required after changing the runtime class
layout before the final prebuilt parallel gate.
The canonical parallel iteration completed nine targeted tests in seven
suites, all forty-two methodology checks, and all twenty predicate parity
repetitions on four workers in 2.1 seconds.

Its twenty-fifth prerequisite verifies that evaluator contexts identify their
owning runtime rather than a facade. The compile-time RED required
`makeEvaluationTaskContext()` without an interpreter argument and a weak
runtime capability on the resulting context. The focused ownership tests must
prove that retaining a context does not retain the facade, that the context's
runtime remains identifiable, and that a foreign-runtime ambient context is
not selected by another interpreter. Explicit `TaskBoundEvalContext` host
ownership remains unchanged because retained host callbacks need a real re-
entry capability.

The semantic workflow is an already-GREEN characterization using
`detached-host-context-reentry`. Apple Swift 6.3.3 establishes exact output
`lost,preserved`: `Task.detached` first observes the default TaskLocal value,
then an explicitly captured value is rebound around an async callback. Native
Swift and the interpreter match in twenty bounded repetitions before and after
the ownership change; every native shard reports SHA-256
`dfe2ffa3bba5229691693999686926094a6ab74bf6414514dfd18ce8d2b6a1fb`.
The closing focused filter includes context ID allocation/selection, facade
release, source-task cleanup, stale-context rejection, callback/task entry,
session lifetime, and real SwiftUI async entry. No implicit detached
inheritance, worker thread, or physical-parallelism claim is allowed.
The canonical parallel iteration completed nine targeted tests in six suites,
all forty-two methodology checks, and all twenty exact parity repetitions on
four workers in 1.9 seconds.

Its twenty-sixth prerequisite verifies that native-stack guard geometry is
task-owned and never treated as stable across pthread migration. The
compile-time RED requires `EvaluationTaskContext.evaluationStackBounds`, a
stable numeric pthread ID on `EvaluationStackBounds`, and cleanup as part of
`removeAllDynamicState()`. The production check must select the cache only
when the current pthread ID matches; otherwise it must query fresh stack
bounds. A long-lived compatibility context follows the same rule.

The native observation is a separately compiled Apple Swift 6.3.3 program:
256 child tasks each cross 32 checked-continuation suspensions. Three runs
observe 5,663, 5,636, and 5,720 pthread changes. The counts are evidence of
migration, not a required scheduler result. The semantic differential remains
the unchanged exact `task-context-cancellation` fixture, whose explicit
started barrier avoids an ordering assumption. Native Swift and the
interpreter must both produce `cancelled,beta` in all twenty bounded
repetitions; the canonical native digest is
`ba7179bb0bf0eee67a3387d8970c61377f3858c23b6b8764d9c2b37403530735` per
shard. Focused coverage also retains source-task and async-initializer contexts
through completion and requires them to be dynamically empty, including the
stack cache. No worker-count, physical-thread placement, or parallel-execution
claim follows from this prerequisite.
The canonical parallel iteration completed ten targeted tests in five suites,
all forty-two methodology checks, and all twenty exact parity repetitions on
four workers in 2.1 seconds.

Its twenty-seventh prerequisite verifies host-registry provenance across
program replacement. The required semantic RED creates an escaped callback
under registry A, changes the facade default to registry B, proves a newly
prepared program sees B, and then invokes the old callback. Returning B from
that callback is the bug; returning A proves the callback's retained
`RuntimeProgramState` owns the selection. The implementation must route all
active evaluator registry access through the current runtime entry's program
state, with the facade value used only as the default for future preparation.

A strict Apple Swift 6.3.3 probe separately pins ordinary dependency capture:
a callback formed with capability `origin`, followed by active capability
`newer`, returns exact `origin,newer` in three compiled executions. The
same-source concurrency oracle is the unchanged `host-callback-overlap` case.
Its explicit continuation gate makes the three snapshots causal; native Swift
and the interpreter remain exact in twenty bounded repetitions with canonical
native SHA-256
`4b1da57b3c315b718431c1f2b0fd875d7b3de0d2e66f35b46a79762815ea2652`
per shard. Focused coverage must include escaped source-map and registry
provenance, callback/descendant-task entry sharing, session ownership/lifetime,
and real SwiftUI task entry plus cancellation. No Sendable registry or
physical-worker claim is allowed.
The canonical parallel iteration completed eight targeted tests in three
suites, all forty-two methodology checks, and all twenty exact parity
repetitions on four workers in 2.2 seconds.

Its twenty-eighth prerequisite verifies that host coercions resolve source
static members through the originating program entry rather than process-wide
mutable state. The required semantic RED prepares an escaped callback under a
frozen `Date.now`, prepares a newer program without that extension, and then
invokes the old callback. Returning the wall-clock day is the bug; returning
the origin epoch proves the retained entry owns lookup provenance. The common
mechanism is a type/member-parameterized `EvalContext.sourceStaticMember`
capability. Interpreter-backed contexts bind it to their current runtime entry;
legacy embedders return nil explicitly. The Date bridge consumes this general
capability instead of an `Interpreter` static closure.

A strict Apple Swift 6.3.3 probe separately passes implicit `.now` into
`Calendar.startOfDay(for:)` after `Task.yield()` and returns exact
`1784160000` with a UTC calendar in three runs. The committed same-source
fixture projects the raw authored epoch and must return `1784228400` on both
sides in twenty bounded repetitions. Focused coverage also keeps the original
FoodTruck Calendar coercions, qualified/annotated static shadowing, cross-
program callback provenance, and real SwiftUI runtime entry green. No ready-
task order, worker thread, Sendable bridge, or physical parallelism is claimed.
The canonical parallel iteration completed seven targeted tests in four
suites, all forty-two methodology checks, and all twenty exact parity
repetitions on four workers in 1.8 seconds.

Its twenty-ninth prerequisite verifies closure-origin program provenance on
ordinary evaluator calls, not only on host-created runtime entries. The RED
must use one interpreter and two runs: program A declares the retained closure
and the actor/overload metadata it needs; program B contains only the call.
The suspending assertion requires actor-isolated storage to remain executor-
owned after `Task.yield()`. The synchronous assertion requires overload
selection from A. A result obtained from B's newly prepared state is the bug.

The common mechanism is a task-owned LIFO of lexical
`RuntimeProgramState` capabilities entered before invocation resolution and
left on every exit. `RuntimeEntry` remains the ownership/cancellation
capability and must not be replaced merely to change lexical lookup. Focused
cleanup requires the frame stack and every runtime registry to be empty. A
strict Swift 6 probe with two actor calls must return sorted `1:2` in twenty
bounded compiled runs; this is an invariant claim about actor serialization,
not a cross-program Swift feature or a task-order claim. Closing evidence must
include both minimal provenance tests, the exact actor replay seed, the full
64-seed actor board, and the parallel trap/SwiftUI/task-group/cancellation
regression board.

The full gate must also exercise compatibility host-extension reuse. A host
value created by program B has no interpreted nominal symbol, so program A's
extension is a separate provenance path from a retained closure. The minimal
RED declares an extension plus an overloaded helper in A and calls the member
from B. Closing evidence requires exact overload output, a one-way overlay
test proving B cannot mutate A's synthetic symbol, weak release of empty
intermediate program states, the pre-existing `hostTypeExtensions` regression,
and origin/newer HostRegistry selection through both direct closure calls and
runtime callback entries.

Its thirtieth prerequisite verifies that the interpreter core no longer
depends on target-wide MainActor default isolation. The architectural RED is a
normal `SwiftInterpreter` build immediately after removing that target setting:
every mutable evaluator/runtime edge that relied on implicit isolation must be
made explicit, not hidden behind blanket `@unchecked Sendable`. Immutable
descriptors and identifiers remain nonisolated and Sendable; mutable values,
heap roots, symbol graphs, evaluator contexts, and runtime registries remain
explicitly MainActor-confined until a later edge-by-edge worker policy exists.

Closing evidence typechecks two fixtures against the built public module under
Swift 6 complete strict concurrency. The positive fixture constructs runtime
IDs and clock values in a `nonisolated` function. The negative fixture attempts
to construct `RuntimeHeap`, `Interpreter`, and `RuntimeValue` there and must
fail with MainActor-isolation diagnostics. A standalone native probe must also
show detached immutable reads plus explicit MainActor mutation without
asserting scheduling order. Because the production change is an isolation
refactor, the semantic workflow is an already-GREEN characterization: the
unchanged `task-owned-evaluator-context` case must preserve its complete
100-event multiset in twenty native/interpreter repetitions. Focused ownership,
module-boundary, and methodology tests must remain green. This prerequisite
does not satisfy physical-worker, worker-safe heap, parallel-mode, or TSan
requirements.

Its thirty-first prerequisite establishes the fail-closed boundary that a
future physical scheduler must consume. The exact native question is whether
a detached task may read mutable MainActor state directly. Under Swift 6
complete strict concurrency the positive probe copies `[2, 3, 5]` before
detaching and must print exact `2,3,5,10|10`; the paired negative fixture reads
the actor property inside `Task.detached` and must fail compilation with a
MainActor isolation diagnostic. No worker start order is asserted.

The runtime RED must be a compile failure caused by the absence of a worker
capability and value-snapshot type. The closing implementation may retain only
checked-Sendable immutable entry metadata and recursively copied values. It
must exhaustively reject opaque host values, ordinary instances, actor
instances, closures, host functions, nominal/enum symbols, and enum values at
the exact nested path. It must add no `@unchecked Sendable` conformance.
`RuntimeHeap` stored roots are compared against a named classification
inventory; adding an unclassified root makes the test RED. A deliberately
retained confined edge and an incomplete manifest must both be rejected by the
executable admission predicate. The inverse snapshot-to-runtime conversion
runs only on MainActor. The unchanged `task-owned-evaluator-context` board is
the semantic characterization: this architectural slice does not claim that
source evaluation has moved to physical workers. Physical scheduling,
cooperative-versus-parallel parity, and TSan remain separate closing work.

Its thirty-second prerequisite turns that data boundary into an actual, still
internal physical-worker driver. The native probe must compile under complete
strict concurrency without blocking APIs or unchecked Sendable wrappers. Two
`Task.detached` jobs share only `Synchronization.Atomic` state; the first spins
without suspension until release, so observing both entries first proves
physical overlap rather than cooperative interleaving. The probe is bounded
and must print exact `overlap:2` in twenty runs. No particular pthread, start
order, or completion order is asserted.

The runtime workflow is gap closure: tests first fail to compile because the
job, driver, and configuration-error types do not exist. Closing code accepts
only `RuntimeWorkerCapability`, an async Sendable operation, and a
`RuntimeWorkerValueSnapshot` result. A configured bound limits real detached
tasks; successful output is restored to input order; parent cancellation must
cancel the detached task; one job failure must cancel a suspended sibling; and
scope exit must release operation captures. Invalid nonpositive bounds fail as
typed values. All waits are deadline-bounded and use checked-Sendable atomics.
The unchanged `task-owned-evaluator-context` case remains the source-semantic
oracle because no interpreted closure is routed through the driver yet. This
prerequisite does not satisfy parallel source execution, mode parity, or TSan.

Its thirty-third prerequisite routes the first demand-cited source operation
through that boundary. The exact semantic question is whether explicit
parallel mode can execute signature-free, argument-free `Task.detached`
closures returning Sendable literals and publish the exact values through
`await value`, without transferring the source closure, syntax, environment,
runtime value graph, heap, host bridge, or evaluator to a worker. The native
fixture must compile under Swift 6 complete strict concurrency with warnings as
errors and return exact `atlas:42` in twenty bounded runs. That result proves
the awaited values, not worker start/completion order or physical overlap; the
thirty-second checked-Atomic probe remains the physical-overlap oracle.

The workflow is gap closure. The recorded RED is a compile failure for the
missing validated execution-mode/configuration types, initializer overload, and
physical-source receipt. Closing code keeps cooperative mode as the default and
preserves the legacy public initializer signatures. Parallel admission is
fail-closed: only a source closure expression with no authored signature,
arguments, parameters, builder transform, or extra statements, the ordinary
enqueued launch policy, and exactly one representable literal expression/return
may lower. All other shapes use the unchanged cooperative evaluator before any
worker evaluation occurs.

Lowering and result materialization are MainActor-isolated. The detached native
operation captures only a checked capability and constant snapshot kernel, and
the shared driver-wide permit pool enforces the configured bound across
concurrent batches. A canceled queued waiter must be removed without consuming
a later permit. Same-source parity explicitly selects parallel mode and requires
exactly two successful physical-source receipts so cooperative fallback cannot
make the case accidentally green. Focused evidence also covers default-mode
behavior, mixed supported/unsupported bodies, authored-signature fallback,
immediate-detached launch preservation, public-module typechecking of old and
new initializers, invalid bounds, global capacity, cancellation, and cleanup.
This prerequisite does not claim general evaluator parallelism, captured or
suspending closures, heap access, scheduler order, speedup, full mode parity,
or TSan cleanliness.

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
  computed from built-in raw Git bytes with external diff drivers and text
  conversion disabled, with any mid-run source drift forcing RED, plus
  parity/acceptance/capability manifest digests and the inventory/status pin
  result;
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
