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
The TaskObservatory interactive follow-up is explicitly an already-GREEN M8
characterization: it presses the unchanged project's actual SwiftUI Button in
an `NSHostingView`, verifies async-let/cancellation-handler/task-group/shared-
waiter completion and registry cleanup, and pairs that bridge regression with
one same-source retained-callback composition fixture. Twenty strict native
and interpreter repetitions return exact
`started,async:5|shared:10:10|cancelled` with native shard SHA-256
`c4c9895155080edb1fd1dcf9b0e887a6c057553fd836addef8bc94ff20a885f8`.
Only values, callback immediacy, structured completion, cancellation
observation, and cleanup are committed; total scheduler order and physical
threads are not.
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

Its thirty-fourth prerequisite establishes a scoped runtime-mode differential
and Thread Sanitizer board before admitting richer worker kernels. This is an
already-GREEN characterization, not a semantic gap closure: the production
driver and literal source kernel passed the first manual sanitized run, so no
runtime RED or behavior change is invented. The exact questions are whether
the demand-cited literal fixture returns the same value in cooperative and
parallel modes with distinct zero/two physical receipts, and whether the
currently admitted physical boundary reports any data race under TSan.

The existing checked-Atomic native overlap fixture remains the physical oracle.
It compiles under Swift 6 complete strict concurrency with warnings as errors
and `-sanitize=thread`, performs twenty bounded overlap repetitions within one
instrumented process, and prints exact `overlap:2`. One process avoids paying
sanitizer startup twenty times without weakening the repetition count. The
same-source mode test reads the committed `parallel-literal-detached` fixture
and performs twenty paired interpreter runs. Each pair must return exact
`atlas:42`, drain both task registries, record zero physical kernels in default
cooperative mode, and exactly two in explicit parallel mode.

The sanitizer runner uses an independent `.build-tsan` cache and executes the
prebuilt driver/source-kernel suites with parallel workers. SwiftPM's testing
helper loads a Mach-O test bundle dynamically, so the TSan runtime must be
inserted before the helper starts. The first direct-prebuilt attempt exposed a
false-green hazard: TSan printed "interceptors not installed" but the helper
exited zero. The committed runner passes the runtime path through the protected
shell boundary, sets `DYLD_INSERT_LIBRARIES` immediately before the helper, and
fails on either interceptor diagnostic regardless of exit status. A
methodology test pins those source-level requirements. Build work has a
600-second wall deadline; native and prebuilt execution each have 60 seconds,
and timeout terminates the isolated process group rather than leaving compiler
or test descendants alive. This receipt is scoped:
captured/scalar-expression and suspending kernels, actors, host calls, heap
access, and the full parallel mode still require expanded mode-differential and
TSan coverage.

The `SwiftInterpreterTests` target is MainActor-isolated by default, but the
physical-worker driver probes are explicitly `nonisolated`. They hop to
`MainActor.run` only to project a checked Sendable capability, then perform
worker launch, cancellation, permit, and deadline orchestration off the shared
MainActor test queue. Otherwise one `Task.yield()` can place the controlling
probe behind hundreds of unrelated tests while its detached workers consume
their bounded deadlines, creating a deterministic load-induced false RED. The
closing gate also resolves both `swift` and `swiftc` through the same `xcrun`
selection and derives the prebuilt helper from that driver's runtime resource;
ambient Swiftly or Homebrew PATH entries cannot mix the build/runtime with a
different native oracle.

Its thirty-fifth prerequisite is a gap closure for the first demand-cited
captured scalar expression. CotEditor's `EditorCounter.swift:130` executes
`await Task.detached { string.count }.value`, where `string` is a local
immutable `String`. The exact semantic question is whether that operation can
publish the native grapheme count in explicit parallel mode while no mutable
binding, global storage, evaluator object, or syntax node crosses the worker
boundary. Apple Swift 6.3.3 compiled the same-source fixture in complete strict
Swift 6 mode with warnings as errors and returned exact `5:9` in twenty
bounded runs. Each native five-repetition shard reported SHA-256
`056cf461832cc0054882f24a52cbebddce0d96374179c21cc2f13e22eea43f3e`;
no worker order is asserted.

The captured RED was intentionally receipt-based: interpreted behavior already
returned `5:9` through cooperative fallback, but parallel mode recorded zero
physical source executions instead of two. Closing code preserves the legacy
public `Box` initializer and `Environment.define` signatures while retaining
source `let`/`var` mutability inside each evaluator box. MainActor lowering
admits only a locally owned immutable String binding, copies it recursively
into `RuntimeWorkerCapability`, and emits typed binding-plus-`String.count`
expression IR. Mutable bindings, globals, authored closure signatures, and all
other expressions remain on the confined cooperative evaluator.

Twenty paired cooperative/parallel runs preserve exact `5:9`, empty task
registries, and zero/two receipts. The same source-kernel suite is part of the
dedicated TSan runner, which rebuilt and passed the twenty-iteration native
overlap probe plus all seventeen driver/source-kernel tests on four workers.
This expands the scoped sanitizer claim only to the new immutable-String-count
kernel; future physical kernels must extend both boards again. The canonical
ordinary focused iteration rebuilt once, then completed 59 tests in ten
ownership/capture/worker suites, all forty-three methodology checks, and all
twenty parity repetitions in nineteen seconds; its post-build lanes each took
about two seconds.

Its thirty-sixth prerequisite is a gap closure for CotEditor's next
demand-cited captured scalar expression. `EditorCounter.swift:176` executes
`await Task.detached { selectedStrings.map(\.count).reduce(0, +) }.value`,
where `selectedStrings` is a local immutable `[Substring]`. The exact semantic
question is whether explicit parallel mode may publish the sum of Swift
grapheme counts while only a recursive value snapshot and typed IR cross the
worker boundary. Worker start and completion order are not asserted.

Apple Swift 6.3.3 compiled the same-source fixture in complete strict Swift 6
mode with warnings as errors and returned exact `6:10` in twenty bounded runs.
Each native five-repetition shard reported SHA-256
`ddbe36d8251c2e1a3d3d558a0e0796e114031f85a98cde26c8536d13562ab0ed`.
The captured RED was receipt-based: interpreted behavior already returned
`6:10` through cooperative fallback, but explicit parallel mode recorded zero
physical source executions instead of two.

MainActor lowering admits only the exact `map(\.count).reduce(0, +)` syntax, a
capture box owned directly by the closure environment, an immutable source
binding, and an array whose recursively copied elements are String snapshots.
It emits one executor-neutral String-count-sum node. The worker performs Swift
grapheme counts and checked integer addition only. Mutable bindings, globals,
alternate seeds, authored signatures, alternate map spellings, and every
non-String element remain cooperative before any worker evaluation occurs.

Twenty paired cooperative/parallel runs preserve exact `6:10`, empty task
registries, and zero/two receipts. The dedicated TSan runner rebuilt its cache
and passed the twenty-iteration native overlap probe plus all twenty
driver/source-kernel tests on four workers, with no interceptor or race
diagnostic. The complete sanitized board took 146 seconds, including a
137-second rebuild. This extends the claim only to the exact immutable
Substring-array count reduction; every future physical kernel must extend both
the mode differential and sanitizer board again. The canonical prebuilt
focused iteration completed 57 tests in nine ownership/worker suites, all
forty-three methodology checks, and all twenty parity repetitions on four
workers in five seconds.

Its thirty-seventh prerequisite is a gap closure for
swift-composable-architecture's demand-cited
`await Task.detached(priority: .background) { await Task.yield() }.value`.
The exact semantic question is whether explicit parallel mode may execute that
single suspending operation on a real detached worker and publish its awaited
`Void`, while only an empty checked capability and typed yield command cross
the worker boundary. Apple Swift 6.3.3 compiled the same-source fixture in
complete strict Swift 6 mode with warnings as errors and returned exact
`yielded:2` in twenty bounded runs. Each native five-repetition shard reported
SHA-256
`a8da6accf02cddfd0779ab299c9ccaf8f75d2092aa1704824745f6c197af7e8c`.
The sequential calls prove completion only, not a worker thread or scheduler
order.

Both recorded REDs were receipt-based: the interpreter already returned the
right value through cooperative fallback, while parity and a direct runtime
test observed zero physical executions instead of two. Admission requires an
ordinary signature-free, argument-free, single-expression detached closure and
the exact zero-argument `await Task.yield()` syntax. MainActor emits a typed
`taskYield` kernel and empty capability; the physical operation invokes native
`Task.yield()` asynchronously and returns a `Void` snapshot. Authored async
signatures, multiple statements, alternate calls, and captures fail closed to
the unchanged cooperative evaluator before worker submission.

Twenty paired mode runs require exact `yielded:2`, zero/two receipts, and empty
registries. The scoped TSan runner rebuilt with the same Xcode toolchain in 97
seconds, passed twenty native overlap iterations, and ran all twenty-three
driver/source-kernel tests on four workers; the complete board took 106 seconds
without a race or interceptor diagnostic. The canonical focused iteration
completed eighty-three tests in nine ownership/worker suites, all forty-three
methodology checks, and all twenty parity repetitions on four workers in four
seconds. This is evidence for only the exact
yield command. Captured suspending bodies, richer async expressions, general
evaluator work, actors, host calls, and heap access remain outside the worker
boundary.

Its thirty-eighth prerequisite is a gap closure for CotEditor's demand-cited
`Task.detached { string.distance(from: string.startIndex, to: location) }`.
The exact question is whether explicit parallel mode can copy an immutable
String and a String.Index derived from it, execute Swift's grapheme-aware
distance on a real worker, and publish the same value. The fixture also cancels
a third non-checking task before awaiting it, pinning Swift's cooperative
cancellation rule: the value still completes while the handle remains marked
cancelled. Apple Swift 6.3.3 compiled the fixture in complete strict Swift 6
mode with warnings as errors and returned exact `2:5|2:true` in twenty bounded
runs. Every native five-repetition shard reported SHA-256
`da866620191667df04f2901b8f5ca2478e97f730df4787c6d7c5b18260518f28`.

The first RED was receipt-based: cooperative fallback already returned the
correct distances, but explicit parallel mode recorded zero physical
executions instead of two. The first production pass exposed a second RED:
native-driver cancellation escaped into the finite worker operation and threw
`CancellationError` instead of publishing `2`. The source-kernel path now
isolates finite physical work from logical source cancellation, while the
ordinary driver API continues to forward infrastructure cancellation.

MainActor admission requires the exact `distance(from: string.startIndex,
to: location)` shape, the same String reference for the receiver and
`startIndex`, and directly owned immutable String and String.Index captures.
Only typed copies enter the checked capability; the worker receives typed
start-index/distance IR. Mutable bindings, globals, alternate `from:`
expressions, authored signatures, and all other shapes remain cooperative.
Twenty paired mode runs preserve exact `2:5|2:true`, empty registries, and
zero/three receipts. The incremental scoped TSan board passed twenty native
overlap iterations and all twenty-eight driver/source-kernel tests on four
workers in fifty seconds without a race or interceptor diagnostic. The
canonical focused iteration completed eighty-nine ownership/worker tests in
nine suites, all forty-three methodology checks (the forty-test board plus
three source-bound gate checks), and all twenty parity repetitions on four
workers in two seconds. No
String.Index provenance beyond Swift's own copied value semantics, native
thread identity, unrelated scheduling order, or general cancellation-checking
kernel is asserted.

Its thirty-ninth prerequisite is a gap closure for Signal-iOS's demand-cited
`Task.detached { try await Task.sleep(for: slowLinking ? .seconds(3) :
.milliseconds(500)) }`, where `slowLinking` is an immutable Bool parameter.
The exact question is whether explicit parallel mode can copy that Bool,
select a finite typed duration, suspend a real detached worker in throwing
`Task.sleep(for:)`, and publish `Void`; a second probe cancels before body entry
and requires the sleep itself to throw `CancellationError`. Elapsed time,
worker identity, and unrelated scheduler order are deliberately excluded.
Apple Swift 6.3.3 compiled the same-source fixture in complete strict Swift 6
mode with warnings as errors and returned exact
`slow:fast|cancelled:true` in twenty bounded runs. Every native five-run shard
reported the focused-harness SHA-256
`d78d19bf880bb60f640e843e2e59091db7555910efa54f0ed50b4b5e8d62ac95`.

The captured RED was receipt-based: both successful calls and the cancelled
call already returned the native value through cooperative fallback, but
parallel mode recorded zero successful physical executions instead of two.
Ordinary parameters and shorthand parameters are now represented as immutable
source bindings, matching Swift and allowing only a directly owned Bool copy.
Admission requires one exact `try await Task.sleep(for:)` expression whose
condition is that immutable Bool and whose branches are nonnegative integer
literals using only `.seconds` and `.milliseconds`. Other units, overloads,
mutable/global conditions, authored signatures, and richer bodies fail closed
to cooperative evaluation before submission.

Throwing sleep differs from the already admitted non-checking finite kernels.
The physical source job therefore carries typed cancellation behavior. A
Sendable actor relay acquires the shared permit from uncancelled infrastructure,
attaches the actual source `Task.detached`, and forwards or remembers a logical
cancellation request across that race. The new driver regression proves that a
pre-cancelled operation enters before it throws. Twenty paired mode runs
preserve exact `slow:fast|cancelled:true`, empty registries, zero/two successful
executions, and zero/three submissions. The scoped TSan board rebuilt in 11
seconds, passed twenty native overlap iterations, and ran all thirty-three
driver/source-kernel tests on four workers; the complete board took 23 seconds
without a race or interceptor diagnostic. The canonical focused iteration ran
the same thirty-three targeted tests, all forty-three methodology checks, and
all twenty parity repetitions on four workers in two seconds. No general
Duration expression, arbitrary suspension, evaluator work, actor, host call,
or heap access is admitted by this evidence.

Its fortieth prerequisite is an already-GREEN characterization for
FoodTruck's `Task.detached { await self.updatesLoop() }` source-member call.
The same-source probe defines a same-named global function, so exact
`target:member` proves the explicit `self` receiver selects the captured
MainActor-isolated instance method across its suspension. Apple Swift 6.3.3
and the interpreter returned that exact value in twenty bounded runs; every
native five-run shard reported SHA-256
`88ddf30fbc689070f9013a46d59717a74b18015dd09b8c8b2bd46316053566ff`.
No behavior RED was invented, and no worker identity or scheduler order is
asserted.

The architectural workflow captured a compile-time RED for the missing
immutable callee-shape fact. `ParsedCallSiteMetadata` now owns the original
callee expression plus a normalized direct-reference, explicit-member,
implicit-member, typed-array, typed-dictionary, or other classification and
source name where available. Synchronous and suspending dispatch consume that
one metadata shape; a foreign-syntax fallback and a detached `Sendable` reader
pin the boundary. Overload and declaration identity, receiver resolution,
actor hops, host routing, and physical execution of the source method remain
outside this prerequisite. It does not expose a runtime box, environment,
instance, heap, host value, or evaluator to a worker.
The canonical focused iteration completed 143 call/metadata/async/host tests
in six suites, all forty-three methodology checks plus three isolated
gate-contract checks, and all twenty parity repetitions on four workers in two
seconds.

Its forty-first prerequisite is a gap closure for physical call-target
identity. The exact question is whether a local value named `Task` shadows the
standard-library Task type inside an operation launched by a real
`Task.detached`, so `await Task.yield()` must invoke the source method and
return its String value. The detached-operation factory is formed outside the
shadowing scope; this isolates inner call selection from task creation. Apple
Swift 6.3.3 compiled the same-source fixture in complete strict Swift 6 mode
with warnings as errors and returned exact `source` in twenty bounded runs.
Every five-run native shard reported SHA-256
`5f56add95e0689069a663ad8f90d7ec54eb7305fc06e321ef8ca348d55017328`.
No physical-worker identity or unrelated scheduler order is asserted.

The deterministic RED compared both interpreter modes before production was
changed. Cooperative evaluation returned `source`; explicit parallel mode
matched the raw AST spelling, returned `Void`, and recorded one physical
source execution. The runtime now registers the builtin Task host function as
a stable core intrinsic. Yield and conditional-sleep admission require both
the immutable explicit-member callee shape and that exact runtime identity
resolved through the originating closure's lexical environment. Shadowed
yield and sleep calls return their source values with zero physical
submissions/executions; existing builtin yield and sleep probes continue to
record their positive receipts. The scoped TSan board passed twenty native
overlap iterations and all thirty-five driver/source-kernel tests on four
workers in 53 seconds. The canonical focused iteration completed 64
runtime/metadata/worker tests in three suites, all forty-three methodology
checks plus three isolated gate-contract checks, and all twenty parity
repetitions on four workers in one second. This proves fail-closed target
selection only; it adds no seventh kernel and does not resolve other source,
actor, host, or
standard-library calls.

Its forty-second prerequisite is a gap closure for standard-library property
target identity. The exact question is whether a same-module computed property
in `extension String` shadows the imported `String.count` inside a detached
operation. Apple Swift 6.3.3 compiled the same-source fixture in complete
strict Swift 6 mode with warnings as errors and returned exact `41` in twenty
bounded runs. Every five-run native shard reported SHA-256
`e195c78d2738596cc170bb3277a29bf2f181174109dcad6afec0ab1a95b0033a`.
No worker identity or unrelated scheduler order is asserted.

The deterministic RED compared both interpreter modes before production was
changed. Both selected the native grapheme-count property and returned `5`;
explicit parallel mode additionally recorded one physical source execution.
Member evaluation now checks a concrete core `String` source extension before
native members. Worker admission resolves a typed property identity through
the closure's originating `RuntimeProgramState`, admits only the exact
standard-library identity, and fails closed for a source declaration or
missing state. A two-run regression pins origin-state ownership; a positive
probe pins continued physical admission. The scoped TSan board passed twenty
native overlap iterations plus all thirty-six driver/source-kernel tests on
four workers in 55 seconds. The canonical focused iteration completed 65
runtime/metadata/worker tests in three suites, all forty-three methodology
checks plus three isolated gate-contract checks, and all twenty parity
repetitions on four workers in one second. This adds no kernel and does not
generalize target resolution to other properties or methods.

Its forty-third prerequisite is a gap closure for standard-library method
target proof. The exact question is whether a same-module
`String.distance(from:to:)` method shadows the imported method inside a
detached operation. Apple Swift 6.3.3 compiled the same-source fixture in
complete strict Swift 6 mode with warnings as errors and returned exact `77`
in twenty bounded runs. Every five-run native shard reported SHA-256
`0e8f6fc06b0a6860d392095f867a5b94dc032ed589e0a43d0ce9b30924258f53`.
No worker identity or unrelated scheduler order is asserted.

The deterministic RED compared both interpreter modes before production was
changed. Cooperative evaluation selected the source method and returned `77`;
explicit parallel mode executed the imported distance kernel, returned `2`,
and recorded one physical submission/execution. Worker admission now obtains a
typed method proof from the closure's originating `RuntimeProgramState`.
Because labels are not a complete overload identity, every same-base source
overload makes the proof unresolved until session-owned overload resolution
can publish an exact declaration. A retained two-run regression pins
origin-state ownership with zero receipts, while the positive stdlib probe
retains physical admission. The scoped TSan board passed twenty native overlap
iterations plus all thirty-seven driver/source-kernel tests on four workers in
52 seconds. The canonical focused iteration completed 66
runtime/metadata/worker tests in three suites, all forty-three methodology
checks plus three isolated gate-contract checks, and all twenty parity
repetitions on four workers in two seconds. This adds no kernel and makes no
general overload-resolution claim.

Its forty-fourth prerequisite is a gap closure for `Array.map` declaration
selection in the existing count-reduction kernel. The exact question is
whether a more-specific same-module `map` overload for
`Array where Element == Substring` is selected by `map(\.count)` inside a
detached operation. Apple Swift 6.3.3 compiled the same-source fixture in
complete strict Swift 6 mode with warnings as errors and returned exact `41`
in twenty bounded runs. Every native five-run shard reported SHA-256
`06012cab1f7bd007fb1ad3ff15d7822d89b450f3ea30814bf7d8f27b8d2687bb`.

The deterministic RED showed both interpreter modes returning the stdlib
result `3`; explicit parallel mode additionally recorded one physical
submission/execution. Core Array member lookup now checks source extensions
before imported native members. Worker admission separately requires a typed
stdlib `.arrayMap` proof from the closure's originating
`RuntimeProgramState`; any same-base source overload leaves it unresolved. A
retained two-run regression returns `41` with zero receipts, and the positive
stdlib reduction keeps its physical receipt. The scoped TSan board passed
twenty native overlap iterations plus all thirty-eight driver/source-kernel
tests on four workers in 25 seconds. The canonical focused iteration completed
67 runtime/metadata/worker tests in three suites, all forty-three methodology
checks plus three isolated gate-contract checks, and all twenty parity
repetitions on four workers in one second. `reduce` and element `count` target
proofs remain explicitly open.

Its forty-fifth prerequisite is the matching gap closure for `Array.reduce`.
The exact question is whether a more-specific same-module `reduce` overload for
`Array where Element == Int` is selected after `map(\.count)` inside a detached
operation. Apple Swift 6.3.3 compiled the same-source fixture in complete
strict Swift 6 mode with warnings as errors and returned exact `73` in twenty
bounded runs. Every native five-run shard reported SHA-256
`510c4b8fd1343251f41b2cfbed0f4b84e7517a95b4603e64a96e98284898f67e`.

The deterministic RED left cooperative evaluation correct at `73`, while
explicit parallel mode executed the stdlib reduction, returned `3`, and
recorded one physical submission/execution. Worker admission now requires a
typed `.arrayReduce` proof from the closure's originating
`RuntimeProgramState` in addition to `.arrayMap`; any same-base source overload
leaves the proof unresolved. A retained two-run regression returns `73` with
zero receipts, and the positive stdlib reduction keeps its physical path. The
scoped TSan board passed twenty native overlap iterations plus all thirty-nine
driver/source-kernel tests on four workers in 35 seconds. The canonical focused
iteration completed 68 runtime/metadata/worker tests in three suites, all
forty-three methodology checks plus three isolated gate-contract checks, and
all twenty parity repetitions on four workers in one second. Only the element
`count` key-path target remains open inside this compound kernel.

Its forty-sixth prerequisite closes that element-property target. The exact
question is whether a same-module `Substring.count` computed property is
selected through a context-inferred `\.count` key path over `[Substring]`,
without also being selected over `[String]`, inside a detached operation.
Apple Swift 6.3.3 compiled the same-source fixture in complete strict Swift 6
mode with warnings as errors and returned exact `178:3` in twenty bounded
runs. Every native five-run shard reported SHA-256
`6c177a2ff65fa47eaf04034c87bd3446d3047a1267fb98e302d5634fb93cb2a5`.

The deterministic RED showed both interpreter modes returning `3` for the
Substring branch; explicit parallel mode additionally recorded one physical
submission/execution. Runtime String storage cannot distinguish String from
Substring, so ordinary Array key-path application now consumes the binding's
retained static element type for root-property dispatch. Worker admission
separately requires the static `Substring` element type and a typed
`.substringCount` proof from the closure's originating `RuntimeProgramState`;
a source extension or missing static fact fails closed. The retained two-run
regression returns `178` and the String control `3` with zero receipts, while
the positive stdlib reduction keeps its physical path. The scoped TSan board
passed twenty native overlap iterations plus all forty driver/source-kernel
tests on four workers in 20 seconds. The canonical focused iteration completed
69 runtime/metadata/worker tests in three suites, all forty-three methodology
checks plus three isolated gate-contract checks, and all twenty parity
repetitions on four workers in two seconds. The exact compound kernel's map, element-property,
and reduce target chain is now closed; unrelated key-path inference and member
families remain open.

Its forty-seventh prerequisite returns to FoodTruck's argument-free source
member call. The exact question is whether, after runtime receiver lookup and
call-shape filtering select `await self.updatesLoop()`, the interpreter can
publish the exact origin-program declaration target without moving the source
instance, selected closure, environment, or evaluator to a worker. Apple Swift
6.3.3 again compiled the existing same-source fixture in complete strict Swift
6 mode with warnings as errors and returned exact `target:member` in twenty
bounded runs. Every native five-run shard retained SHA-256
`88ddf30fbc689070f9013a46d59717a74b18015dd09b8c8b2bd46316053566ff`.

Behavior was already GREEN, so the planned RED was architectural: the exact
selected source closure had no executor-neutral declaration descriptor or
fail-closed target resolver. The first implementation run exposed a second,
runtime RED: after a newer facade run, resolving a retained old instance's
method rebound the same syntax identifier to the new program plan and
classified its lexical placement as global. Source instances now retain their
originating MainActor-confined `RuntimeProgramState`, and source-value copies
preserve that edge. `makeFunctionClosure` can therefore form the method from
the receiver's origin rather than the facade's current program.

Every selected source function closure now projects a Sendable descriptor
containing the origin `ResolvedProgramPlan`, declaration `SyntaxIdentifier`,
native function spelling, lexical placement, resolved-or-lazy isolation facts,
effects, and return type name. The shared resolver publishes a target only for
an own reference-type method with no property collision and exactly one
call-shape match; same-shape type overloads remain unresolved. The real
suspending explicit-member path consumes this resolver for the demand-cited
argument-free form. A detached native reader proves the descriptor is
Sendable, a two-run regression proves origin-plan identity, and explicit
parallel mode returns `target:member` with zero physical submissions or
executions. The canonical focused iteration completed 45 ownership/target/
worker tests in four suites, all forty-three methodology checks plus three
isolated gate-contract checks, and all twenty parity repetitions on four
workers in one second. The rebuilt scoped TSan board passed twenty native
overlap iterations and all forty driver/source-kernel tests on four workers in
70 seconds. This does not claim full Swift overload resolution, inherited or
protocol-witness targets, host routing, actor re-entry from a physical worker,
or physical execution of the source method.

The forty-eighth M9 slice is a gap closure for FoodTruck's exact
`Task.detached { await self.updatesLoop() }` shape. The semantic question is
whether explicit parallel mode may launch the detached wrapper physically,
then re-enter the uniquely selected MainActor source method with the original
logical runtime-task context, without transferring its receiver or evaluator.
A bounded Swift 6 complete-strict probe uses two Void-returning methods: one
mutates MainActor state after `Task.yield()`, and one records cancellation that
the caller requests before yielding MainActor. Apple Swift returned exact
`1:true` in twenty runs; every five-run shard retained SHA-256
`5a14c888baeb47a0a83163bf1680a3fdcc9a508e7b5aa5bf4191aad7390e1d3a`.

Behavior was already GREEN, while the deterministic receipt RED observed zero
physical submissions/executions instead of two. Admission now requires the
signature-free one-expression direct-self spelling plus an origin-plan-matched,
uniquely shape-resolved own source-class method that is async, nonthrowing,
MainActor-isolated, and Void- or String-returning. The Sendable command contains
only entry/task IDs, the exact target descriptor, and the expected result kind.
Its confined half remains on `RuntimeTaskRecord`; a purpose-built MainActor
relay validates provenance, reinstalls the task's `EvaluationTaskContext`,
invokes the selected closure, and copies the result through the existing
worker-snapshot boundary.

The physical wrapper releases its bounded-worker permit when it reaches the
confined executor rather than when the source method returns. A maximum-one
regression parks a MainActor method, runs a finite literal kernel, and only
then releases the method; this prevents FoodTruck's long-lived updates loop
from starving later physical work. Logical cancellation remains visible after
re-entry, an interpreted fatal trap remains contained in the task outcome, and
actor, inherited/nonisolated, non-self, argument-bearing, throwing,
foreign-origin, ambiguous, and richer-result families remain cooperative.
The command, capability, and copied result cross the worker boundary; no
`Instance`, `ClosureValue`, `Environment`, `RuntimeProgramState`, heap, symbol,
or evaluator does.

The canonical focused iteration completed 58 ownership/target/driver/worker
tests in five suites, all forty-three methodology checks plus three isolated
gate-contract checks, and all twenty parity repetitions on four workers in two
seconds. The expanded scoped TSan board passed twenty native overlap
iterations and all 48 driver/kernel/source-call tests in three suites on four
workers in 66 seconds without a race or interceptor diagnostic. This slice
does not claim actor/host call routing, inherited/protocol-witness resolution,
typed arguments, throwing source calls, richer results, or general evaluator
parallelism.

The forty-ninth M9 slice is a gap closure for TaskObservatory's exact
`Task.detached { await self.method(label: integer, ...) }` family. The semantic
question is whether explicit parallel mode may launch a real detached wrapper
for a uniquely selected direct-self `@concurrent nonisolated` async source
method, copy its labeled integer arguments across the worker boundary, then
re-enter the confined evaluator under the logical default-executor task
context while preserving MainActor hops and the exact result. The bounded
same-source fixture calls `compute(id: 7, run: 11)`, yields, observes nil
lexical isolation, records isolated receiver state, and returns exact
`7:11|18:none`. Apple Swift 6 complete-strict compilation and the interpreter
returned that result in twenty runs; every five-run native shard retained
SHA-256
`34d58dd88621c8d3b3208bf3323e40b36c7d84323ee01c44574ee52ebcef4315`.

Behavior was already GREEN, while the deterministic receipt RED observed zero
physical submissions/executions instead of one. Admission is deliberately
depth-capped to integer literals or directly owned immutable `Int`/`Int64`
captures matched to explicit nondefaulted, nonvariadic, non-builder,
nonisolated `Int`/`Int64` parameters. Argument labels and checked binding IDs
travel in the Sendable command; copied values travel in the worker capability.
The confined relay validates their one-to-one provenance, reconstructs labeled
`CallArguments`, reinstalls the task's `EvaluationTaskContext`, and invokes the
origin-bound closure. Mutable captures, expression and noninteger arguments,
ordinary explicit `nonisolated` methods, actors, ambiguity, throwing calls,
and richer results stay cooperative.

The unchanged TaskObservatory project supplies the demand and integration
proof: with maximum parallelism one its three `@concurrent` wrappers record
three physical receipts, preserve exact final worker/waiter/group state, and
drain every task/group/scope registry. This proves physical wrapper launch,
not physical source-evaluator execution. No receiver, `Box`, `RuntimeValue`,
`CallArguments`, environment, program state, heap, or evaluator enters the
worker capability. The canonical focused iteration completed 62 tests in six
suites, all forty-three methodology checks plus three isolated gate-contract
checks, and all twenty parity repetitions on four workers in two seconds. The
rebuilt scoped TSan board passed native overlap 20/20 and all 49 driver/kernel/
source-call tests in three suites on four workers in 87 seconds without a race
or interceptor diagnostic.

The fiftieth M9 slice is a gap closure for iTorrent's exact
`Task.detached(priority: .utility) { await self.method(true/false) }` family.
The semantic question is whether two sequentially awaited detached wrappers
may pass Boolean literals to a uniquely selected MainActor async source method,
preserve that actor's exact mutation order, and return both values through the
checked worker/confined-reentry boundary. The bounded same-source fixture
yields inside the method and returns exact `on:off|TF`. Apple Swift 6.3.3
complete-strict compilation and the interpreter returned that value in twenty
runs; every five-run native shard retained canonical SHA-256
`ec0dfbfcbd3bbeab6dd3c5728b5da0face87e81f2b3be963f6d9d1acfa617bf6`.
Only sequential awaits and isolated state are asserted; worker identity and
unrelated scheduler order are not.

Behavior was already GREEN, while the deterministic receipt RED observed zero
physical submissions/executions instead of two. Each source-call command
argument now includes an integer-or-Boolean value kind. Admission checks that
kind against the selected declaration's `Int`, `Int64`, or `Bool` parameter,
and the confined relay independently checks it against the copied worker
snapshot before reconstructing `CallArguments`. Boolean depth is limited to
literal `true`/`false`, matching the cited iTorrent spelling; captured Bool,
Boolean expressions, String, mutable captures, ambiguity, actors, throwing
calls, and richer results stay cooperative.

The canonical focused iteration completed 63 tests in six suites, all
forty-three methodology checks plus three isolated gate-contract checks, and
all twenty parity repetitions on four workers in two seconds. The rebuilt
scoped TSan board passed native overlap 20/20 and all 50 driver/kernel/
source-call tests in three suites on four workers in 68 seconds without a race
or interceptor diagnostic. No receiver, source box, environment, program
state, heap, `RuntimeValue`, `CallArguments`, or evaluator entered the worker
capability.

The fifty-first M9 slice is a gap closure for Session-iOS's exact
`Task.detached { await self.synchronousActorMethod() }` family. The semantic
question is whether an unretained detached wrapper launched by an actor
initializer routes its synchronous cross-actor method through that same
actor's mutually exclusive executor while a later actor method yields waiting
for its mutation. The bounded same-source fixture preserves this launch shape,
mutates actor storage, and returns exact `actor|R`.
Apple Swift 6.3.3 complete-strict compilation with warnings as errors and the
interpreter returned that value in twenty runs; every five-run native shard
retained canonical SHA-256
`ee46339758b9bf4f9030cfb7cc9db448e6b2c961004386a9c262fe21f5ce57cc`.
No worker identity or unrelated scheduler order is asserted.

Behavior was already GREEN, while the deterministic receipt RED observed zero
physical submissions/executions instead of one. Admission is demand-capped to
a uniquely selected, argument-free, synchronous, nonthrowing, Void-returning
own method on the exact receiver actor with its default executor. The worker
carries only the existing Sendable command; confined re-entry restores
the source task context and uses normal suspending invocation to acquire the
actor mailbox. The exact completion proves that the actor's result method
released its mailbox at `Task.yield`, allowing the unretained initializer task
to enter instead of self-deadlocking. A retained negative control keeps
zero-argument async and synchronous argument-bearing actor methods cooperative.
Custom executors,
String-returning or nonisolated actor methods, ambiguity, throwing calls, and
richer results also remain outside the admitted subset.

This slice proves a physical detached wrapper plus logical actor routing, not
physical actor-method evaluation. No actor, receiver, source box,
`RuntimeValue`, `CallArguments`, environment, program state, heap, or evaluator
enters the worker capability. The focused parity board completed all twenty
native/interpreted repetitions on four workers in two seconds. The canonical
focused board passed 65 tests in six suites plus all forty-three methodology
checks and three isolated gate-contract checks. The rebuilt scoped TSan board
passed native overlap 20/20 and all 51 driver/kernel/source-call tests in three
suites on four workers in 25 seconds without a race or interceptor diagnostic.

The fifty-second M9 slice is a gap closure for Planet's exact
`Task.detached { await self.asyncActorMethod(label: capturedInt) }` family.
The semantic question is whether a copied immutable integer can enter an async
method on the exact receiver actor, remain actor-isolated before suspension,
release the mailbox at `Task.yield`, and reacquire it before the continuation.
The bounded same-source fixture asserts only the causally fixed trace
`start:17|done:17`. Apple Swift 6.3.3 complete-strict compilation with warnings
as errors and the interpreter returned that trace in twenty runs; every
five-run native shard retained canonical SHA-256
`b2ba89617abb88d104c2131843423923d4bbf7b369d08f05192dd8985b01325a`.
No thread identity or unrelated scheduler order is asserted.

Behavior was already GREEN, while the receipt RED observed zero physical
submissions/executions instead of one. Admission reuses the existing integer
snapshot and labeled source-call command, but permits the actor route only for
one `Int`/`Int64` argument, an async nonthrowing Void own method, and the exact
default receiver actor ID. Confined re-entry uses the ordinary suspending
evaluator; therefore actor ownership before and after the yield is proved by
the same mailbox state machine as cooperative execution. An async actor Void
method taking a Boolean literal through a nondefaulted parameter remains
cooperative as the nearest negative control; String, multiple/defaulted,
mutable, expression, throwing, and custom executor forms remain outside this
slice.

The canonical focused board passed 66 tests in six suites plus all forty-three
methodology checks and three isolated gate-contract checks; focused parity
completed all twenty repetitions on four workers in two seconds. The rebuilt
scoped TSan board passed native overlap 20/20 and all 52
driver/kernel/source-call tests in three suites on four workers in 25 seconds
without a race or interceptor diagnostic.

The fifty-third M9 slice is a gap closure for Planet's exact
`Task.detached { await self.asyncActorMethod(defaultedBool: true) }` family.
The semantic question is whether an explicitly supplied Boolean literal can
be copied into a defaulted Bool parameter, enter the exact receiver actor,
release that actor at `Task.yield`, and reacquire it before continuation. The
bounded same-source fixture asserts only the causal trace
`start:true|done:true`. Apple Swift 6.3.3 complete-strict compilation with
warnings as errors and interpreted execution returned that trace in twenty
runs; every five-run native shard retained canonical SHA-256
`1b0355375aa6a812ce51840fb7f3c38c1c21320283d5e013d0cd27e5c30e1abe`.
No thread identity or unrelated scheduler order is asserted.

Behavior was already GREEN, while the deterministic receipt RED observed
zero physical submissions/executions instead of one. The general route table
now distinguishes an explicitly supplied defaulted Bool parameter from both
an omitted default and a required Boolean parameter. It reuses the checked
Boolean snapshot, origin-bound source target, confined task-context relay,
and ordinary suspending actor invocation. Negative controls keep omitted
defaults, captured Bool, defaulted integer parameters, and nondefaulted
Boolean parameters cooperative with zero receipts; String, multiple,
mutable, expression, throwing, and custom-executor forms remain outside the
slice.

The canonical focused board passed 67 tests in six suites plus all
forty-three methodology checks and three isolated gate-contract checks;
focused parity completed all twenty repetitions on four workers in one
second. The rebuilt scoped TSan board passed native overlap 20/20 and all 53
driver/kernel/source-call tests in three suites on four workers in 23 seconds
without a race or interceptor diagnostic.

The fifty-fourth M9 slice is a gap closure for Provenance's exact
`Task.detached { await self.customGlobalActorMethod() }` family. The semantic
question is whether an unretained physical wrapper can preserve a canonical
user global actor across a real suspension without resolving `static shared`
during admission. The same-source probe waits on the same actor and asserts
only `same|same`: `#isolation` matches canonical `shared` before and after
`Task.yield`. Apple Swift 6.3.3 complete-strict compilation with warnings as
errors and interpreted execution returned that trace in twenty bounded runs;
every native five-run shard retained canonical SHA-256
`fcb1cc9c933c78c04ad6becc131ea2f7d8ca50a23b090f5336dbcb64c0be6261`.
No physical thread or unrelated scheduler order is asserted.

Behavior was already GREEN, while the deterministic receipt RED observed
zero physical submissions/executions instead of one. Admission now proves a
unique source global-actor declaration from immutable candidate names and
confined symbol metadata, restricted to an actor nominal with the default
executor. It intentionally does not materialize `static shared`; normal
confined invocation retains responsibility for canonical actor resolution,
mailbox acquisition, release at suspension, and reacquisition. The retained
negative board keeps argument-bearing and String-returning methods plus
struct/enum-backed global actors cooperative; custom executors, throwing
calls, and richer results remain outside the slice.

The canonical focused board passed 69 tests in six suites plus all
forty-three methodology checks and three isolated gate-contract checks;
focused parity completed all twenty repetitions on four workers in one
second. The rebuilt scoped TSan board passed native overlap 20/20 and all 55
driver/kernel/source-call tests in three suites on four workers in 20 seconds
without a race or interceptor diagnostic.

The fifty-fifth M9 slice is a gap closure for iTorrent's exact plain-async
source-class family:
`Task.detached(priority: .utility) { await self.refreshWebServerState() }`
and its WebDAV counterpart. The semantic question is whether a real detached
wrapper may invoke an argument-free async Void source method whose declaration
inherits its caller's isolation, while preserving the detached caller's nil
actor isolation across suspension.

The same-source probe declares an `@unchecked Sendable` class, launches the
wrapper without retaining its handle, samples defaulted `#isolation` before
and after `Task.yield`, and waits causally through a MainActor result method.
Apple Swift 6.3.3 compiled it in complete strict Swift 6 mode with warnings as
errors and returned exact `none|none` in twenty bounded runs. Every native
five-run shard retained SHA-256
`dc022b9fd32ef23613a6bf01ee0af601d88cf1f8fce887c8924f7047de1bd4b4`;
no physical thread, elapsed duration, or unrelated scheduler order is an
oracle.

The deterministic interpreter RED returned the same value and drained its
runtime state, but recorded zero physical submissions/executions instead of
one. The minimal route-table change admits `.inherited` only when the selected
own source-class method is async, nonthrowing, argument-free, and
Void-returning. The existing typed command and confined relay perform the
physical wrapper plus executor handoff; ordinary invocation runs only after
the logical detached `EvaluationTaskContext` is restored. Focused controls
keep inherited arguments and String results plus explicit `nonisolated`
methods cooperative with zero receipts.

The canonical focused board passed 70 tests in six suites plus all
forty-three methodology checks and three isolated gate-contract checks;
focused parity completed all twenty repetitions on four workers in one
second. The rebuilt scoped TSan board passed native overlap 20/20 and all 56
driver/kernel/source-call tests in three suites on four workers in 24 seconds
without a race or interceptor diagnostic.

The fifty-sixth M9 slice closes Provenance's capture-only strong-self wrapper:
`Task.detached(priority: .userInitiated) { [self] in await
self.registerDefaults() }`. The semantic question is whether that explicit
strong capture may use the already proven inherited-isolation physical
source-call route without treating general authored closure signatures as
worker-safe.

The same-source probe samples defaulted `#isolation` before and after
`Task.yield`. Apple Swift 6.3.3 complete-strict compilation with warnings as
errors and interpreted execution returned exact `strong:none|none` in twenty
bounded runs; all native five-run shards retained SHA-256
`14c92e632cbf820172e940cbe85fb910e691b2b5a8e7ccd49b1a5f976660df9e`.
No physical thread, scheduler order, elapsed duration, weak-capture lifetime,
or general capture-list transfer is an oracle. The interpreter RED returned
the same source value with complete cleanup but zero physical receipts.

The implementation classifies exactly one capture-only strong `self`
signature when the closure is formed. Physical lowering may use that fact
only for the direct-self source-call attempt and then fails closed before the
ordinary snapshot-kernel table. Controls keep `unowned`, alias, multi-capture,
explicit parameter/effect/return, and non-call forms cooperative with zero
receipts. Weak/optional-self async dispatch remains unclaimed outside this
physical-route slice. The worker receives no source receiver,
closure, environment, runtime value, heap, or evaluator.

The canonical focused board passed 71 tests in six suites plus all
forty-three methodology checks and three isolated gate-contract checks;
focused parity completed all twenty repetitions on four workers in one
second. The rebuilt scoped TSan board passed native overlap 20/20 and all 57
driver/kernel/source-call tests in three suites on four workers in 49 seconds
without a race or interceptor diagnostic.

The fifty-seventh M9 slice closes repeated weak-self optional async member
dispatch such as `Task.detached { [weak self] in await self?.method(...) }`.
The semantic question is cooperative: when the weak receiver is alive, does
the selected source method use the suspension-aware evaluator; when it is
nil, are argument evaluation and invocation both skipped? No physical weak
reference is admitted.

The same-source oracle retains one receiver through the awaited detached
handle, samples nil actor isolation around `Task.yield`, and then calls a nil
optional with a fatal argument expression. Apple Swift 6.3.3 complete-strict
compilation with warnings as errors returned exact `alive:none|none|nil` in
twenty bounded runs. Every native five-run shard retained SHA-256
`76d6367b231b0e0530517d36cac3c518d1d5eb029e181e53e7ac83722d93b2a7`;
no weak-destruction race, worker identity, or scheduler order is an oracle.
The deterministic interpreter RED failed inside the alive method because the
eager optional-member wrapper invoked `Task.yield` synchronously.

The fix evaluates an explicit optional-chain base once in
`evaluateCallSuspending`. Nil returns before argument collection. A present
source class/actor reference is rebound to a temporary, dispatched recursively
through ordinary suspension-aware member resolution, and lifted through the
existing Optional flattening rule. Optional value types keep their prior path
until mutating write-back is separately proven. The focused case requires zero
physical receipts. Optional
async closure calls, optional value-type async chains with mutating write-back,
weak-destruction races, and worker-side weak references remain outside the
slice.

The canonical focused board passed 72 tests in six suites plus all
forty-three methodology checks and three isolated gate-contract checks;
focused parity completed all twenty repetitions on four workers in two
seconds. The rebuilt scoped TSan board passed native overlap 20/20 and all 58
driver/kernel/source-call tests in three suites on four workers in 24 seconds
without a race or interceptor diagnostic.

The fifty-eighth M9 slice closes demand-cited optional async callable dispatch
such as Aidoku's `await loadMore?()`, iTorrent's `await refreshTask?()`, and
Provenance's `await iterationComplete?()`. The semantic question is
cooperative: does a present source closure use the suspension-aware evaluator,
and does nil skip both argument evaluation and invocation? No physical closure
transfer is admitted.

The same-source oracle invokes a present `@Sendable` closure with one integer,
samples nil actor isolation around `Task.yield`, and then calls a nil optional
with a fatal argument expression. Apple Swift 6.3.3 complete-strict
compilation with warnings as errors returned exact
`live:7:none|none|nil` in twenty bounded runs. Every native five-run shard
retained SHA-256
`aeba7d1f8923f7f34fb729387f5cf709d80eefe1cf283d8faff2811c04e40706`;
no worker identity or scheduler order is an oracle. The deterministic
interpreter RED failed because synchronous Optional invocation reached
`Task.yield` without the async runtime.

`evaluateCallSuspending` now checks optional chaining on the callee before
collecting arguments. Nil produces the chained nil result immediately. A
present callable is unwrapped, dispatched through `invokeSuspending`, and
lifted through the existing Optional flattening rule. The case requires zero
physical receipts. Optional value-type async chains with mutating write-back,
weak-receiver destruction races, and worker-side weak references remain
outside the slice.

The canonical focused board passed 73 tests in six suites plus all
forty-three methodology checks and three isolated gate-contract checks;
focused parity completed all twenty repetitions on four workers in two
seconds, and the complete focused gate took six seconds. The rebuilt scoped
TSan board passed native overlap 20/20 and all 59 driver/kernel/source-call
tests in three suites on four workers in 58 seconds without a race or
interceptor diagnostic.

The fifty-ninth M9 slice is an already-GREEN characterization of weak capture
lifetime across suspension. Session's group-notification jobs create detached
`[weak self]` tasks, suspend in `Task.sleep`, and only then read `self?`. The
oracle substitutes a causal actor gate so elapsed time and scheduler order are
not evidence.

The detached task first reports that it entered and suspended. Only afterward
does the parent clear the final strong receiver and reopen the gate. Apple
Swift 6.3.3 complete-strict compilation with warnings as errors and the
unchanged interpreter returned exact `released` in twenty bounded runs. Every
native five-run shard retained SHA-256
`c5e92e2453b9fcfd589dc5d3b917f8708b27239decb0a58ca175b11b85c27b6e`;
the interpreter recorded zero physical receipts and empty task/actor
registries.

No runtime mechanism changed. The evidence distinguishes ownership layers:
the task record owns its source closure until completion, but the closure's
weak capture box does not own the source instance. General physical weak-call
routing and optional value-type mutating async chains remain outside the slice.

The canonical focused board passed 74 tests in six suites plus all
forty-three methodology checks and three isolated gate-contract checks;
focused parity completed all twenty repetitions on four workers in two
seconds, and the complete focused gate took six seconds. The rebuilt scoped
TSan board passed native overlap 20/20 and all 60 driver/kernel/source-call
tests in three suites on four workers in 21 seconds without a race or
interceptor diagnostic.

The sixtieth M9 slice closes Provenance's exact capture-only weak-self wrapper:
`Task.detached(priority: .background) { [weak self] in await
self?.processQueue() }`. The semantic question is whether one physical wrapper
can preserve the weak read at body entry without moving the weak box or
receiver to a worker and without retaining the receiver while capacity is
queued.

The same-source probe retains one receiver through result observation and
samples defaulted `#isolation` before and after `Task.yield`. Apple Swift 6.3.3
complete-strict compilation with warnings as errors and interpreted execution
returned exact `weak:none|none` in twenty bounded runs. Every native five-run
shard retained SHA-256
`59b08bc91e9e8533552cc5edbaeedf8d0af325e761b6131da38169d353f0b121`;
no thread identity, scheduler order, elapsed duration, or general capture-list
transfer is an oracle. With admission disabled, the interpreter returned the
same value but recorded zero physical receipts instead of one.

The mechanism classifies only `[weak self] in`, preflights an argument-free
inherited-isolation Void method, and sends only the existing typed command with
an Optional-Void result contract. Confined registration owns the source
closure's weak box, not a resolved method closure. The MainActor relay reads the
box after worker entry, returns Optional.none when released, or temporarily
retains and invokes a live receiver after rechecking the exact descriptor. A
second deterministic test occupies the sole permit, clears the final strong
receiver while the wrapper is queued, then releases capacity and requires
`released` plus one receipt. Weak argument-bearing and String-returning calls
are retained zero-receipt controls.

The canonical focused board passed 75 tests in six suites plus all forty-three
methodology checks and three isolated gate-contract checks; focused parity
completed all twenty repetitions on four workers in one second, and the
complete focused gate took four seconds. The rebuilt scoped TSan board passed
native overlap 20/20 and all 62 driver/kernel/source-call tests in three suites
on four workers in 68 seconds without a race or interceptor diagnostic.

The sixty-first M9 slice uses an official compiler-runtime test as the primary
source rather than inventing an Optional write-back expectation. Pinned
`swiftlang/swift` `test/IRGen/run-coroutine_accessors.swift` at
`swift-6.3.3-RELEASE` commit
`064859e41d68596f486c5d724401cb370f260409`, SHA-256
`2fdae2aa9cd0153da1db13b5e227c6fe5a74112eda85b91795fad9554a80cc95`,
requires `await b.value?.mutate()` to preserve nil and copy a mutated value
back. The distilled fixture stays below forty lines while adding a real
`Task.yield`, a direct Optional lvalue, and an enclosing source-value property.

Apple Swift 6.3.3 complete-strict compilation with warnings as errors and the
interpreter returned exact
`direct-entered-resumed:direct-entered-resumed|nested-entered-resumed:nested-entered-resumed|nil:nil`
in twenty bounded runs. Every native five-run shard retained SHA-256
`7b98f96ff0ce968ecede27d9907e5ae498748983dd442b768d9b47f5d171a234`.
The retained RED is causal and behavioral: before the runtime change, the
first present call failed at `Task.yield` with `async host function 'yield'
requires runAsync and await` because optional value dispatch invoked the
method synchronously.

Focused evidence requires mutation both before and after suspension to reach
the original direct and nested storage, nil to remain nil, one Optional result
lift, complete runtime cleanup, and zero physical receipts. The production
path reuses the existing `LValue` and async mutating copy-in/copy-out kernels;
it does not add an Optional-name, fixture, or standard-library special case.
Throwing/cancellation exits and coroutine/computed/subscript accessors remain
explicit follow-ups rather than being normalized into this success oracle.

The canonical focused board passed 76 tests in seven suites plus all
forty-three methodology checks and three isolated gate-contract checks;
focused parity completed all twenty repetitions on four workers. The rebuilt
scoped TSan board passed native overlap 20/20 plus all 62 physical
driver/kernel/source-call tests in 17 seconds without a race or interceptor
diagnostic.

The sixty-second M9 slice asks one exceptional-exit question: after a present
Optional source value mutates across suspension, does Swift copy the receiver
back when the mutating method throws? The primary optional async oracle remains
the pinned `test/IRGen/run-coroutine_accessors.swift`. The independent upstream
unwind oracle is
`test/Interpreter/coroutine_accessors_old_abi_nounwind.swift` from the same
`swift-6.3.3-RELEASE` commit, SHA-256
`68f7dec3be698ae0010c9cf35b25bbc8c53e910e31d2cfd14a67145bb9fc2ce9`;
its modify cleanup runs after the yielded mutating call throws.

The 39-line differential uses direct Optional storage for a typed source error
and an enclosing stored property for a real `CancellationError`. It
self-cancels the second runtime task before
`Task.checkCancellation`, so no scheduler order or elapsed-time assumption is
part of the assertion. Strict Apple Swift 6.3.3 returned exact
`threw:throw-entered-resumed|cancelled:cancel-entered-resumed` in twenty
bounded runs, and every native five-run shard retained SHA-256
`a7e9b9c675182511ce7f0f538699d283c2b57d960f1a0c2b574c29e4e270f295`.
The retained RED returned `threw:throw|cancelled:cancel`: error identity and
catch routing were already correct, while receiver copy-out on unwind was not.

Focused evidence requires the same final receiver after source throw and
cancellation, the original failure to remain catchable, complete task/scope/
group cleanup, and zero physical receipts. The production change extends the
ordinary suspending mutating-method helper with one confined
write-back-on-exit callback used for normal and exceptional completion. It does
not branch on the fixture, error kind, Task API, or method name. Computed,
coroutine, and subscript owners remain outside the admitted stored-lvalue
syntax and must receive their own suspension-safe access transaction.

The canonical focused board passed 76 tests in seven suites plus all
forty-three methodology checks and three isolated gate-contract checks;
focused parity completed all twenty repetitions on four workers. The rebuilt
scoped TSan board passed native overlap 20/20 plus all 62 physical
driver/kernel/source-call tests in 24 seconds without a race or interceptor
diagnostic.

The sixty-third M9 slice asks the next ownership question: when the Optional
payload belongs to an ordinary writable computed property on a source struct,
does Swift call the getter once and the setter once with final `self` after
either normal async return or unwind? Pinned
`test/IRGen/run-coroutine_accessors.swift` lines 200-220 and 368-386 supply the
computed coroutine plus async-mutation basis; pinned
`test/Interpreter/coroutine_accessors_old_abi_nounwind.swift` lines 9-41
supplies the cleanup-on-unwind basis. The differential deliberately uses a
standard synchronous, nonthrowing get/set property; native `read`/`modify`
syntax is not claimed.

The probe mutates before and after `Task.yield` and records getter, method,
setter, and backing-storage effects without asserting scheduler or thread
order. Apple Swift 6.3.3 complete-strict compilation with warnings as errors
and interpreted execution returned exact
`get|enter|exit:seed-entered-resumed|set:seed-entered-resumed|seed-entered-resumed#get|enter|exit:seed-entered-resumed|set:seed-entered-resumed|seed-entered-resumed`
in twenty bounded runs. Every native five-run shard retained SHA-256
`a02611976cbcd7de5b34b6f5bb05bcfddd74953d47d67d9db2666eb907bc88ab`.
The retained RED was `get|enter|seed#get|enter|seed`, which isolates the lost
suspending continuation and absent setter rather than getter multiplicity or
error routing.

Focused evidence requires one getter and setter per present call, copy-out on
return and typed throw, the original Optional wrapper and final payload,
complete runtime cleanup, and zero physical receipts. Admission is metadata-
bounded to a direct source-value member with an Optional annotation,
synchronous nonthrowing getter, and setter. The shared LValue transaction reads
once and commits a reconstructed typed Optional through that same owner on
both exits. Native coroutine accessor spellings, async/throwing getters,
computed reference or nested owners, and source subscripts remain outside the
admitted support. One native-positive `interpreter-diagnostic` case represents
that uncited remainder. Native returns exact `seed-entered-resumed`; every
five-run shard retains SHA-256
`ce729f52a3592f1c93a7140c8bc10addb7e62d41ae42f06a3651ce98efcba89a`.
The interpreter fails before argument evaluation or payload mutation with a
named async-Optional-mutation storage diagnostic. Its RED instead entered the
method synchronously and failed late at `Task.yield`, which was not an
acceptable depth-cap boundary.

The exact upstream spelling has its own committed compiler probe at
`Tests/NativeProbes/Concurrency/optional-coroutine-accessor-async-writeback.swift`
(SHA-256
`970932d93de220890b56e5a8b520a6c4d25dd1e07d148c44fc9f1405aa0ff223`).
With the experimental CoroutineAccessors feature, complete strict concurrency,
and warnings as errors, it returned `seed-entered-resumed` in twenty runs.
The interpreter RED was the unrelated late diagnostic `unresolved identifier
'read'`. Declaration collection now identifies direct and parser-recovered
`read`/`modify`/`_read`/`_modify` shapes and fails immediately with the named
coroutine-ownership diagnostic.

The focused iterations passed both new regressions, all forty-three
methodology checks plus three isolated gate-contract checks, and twenty
repetitions of each parity case on four workers. The exact-tip
AsyncExecutionTests plus RuntimeSourceCallTargetTests board passed 114 tests
in two suites. The rebuilt
scoped TSan board passed native overlap 20/20 plus all 62 physical
driver/kernel/source-call tests in 31 seconds without a race or interceptor
diagnostic.

The sixty-fourth M9 slice asks one executor-inheritance question: does an
explicit `@MainActor` operation passed to `Task.detached` retain that actor
across suspension while a plain operation formed at the same MainActor site
remains nonisolated? Planet's `PlanetStore.swift:246` supplies the demand
spelling, and the pinned corpus contains 57 matching operation shapes.

The same fixture compares both closures before and after `Task.yield` and
returns exact `same|same#none|none`; it does not observe task order or thread
identity. Apple Swift 6.3.3's complete-strict region checker currently rejects
the exact corpus spelling with an internal checker diagnostic, so the native
fixture adds explicit `@Sendable`. That attribute is executor-neutral and the
detached operation is already Sendable. Twenty bounded strict runs and four
five-run focused shards agree; the focused native-observation digest is
`032c610c796c0f579b3af0c81e114c283f50d2ce0e576bb16089ef843ef1da7a`.

The retained RED `same|same#same|same` proves the interpreter conflated two
independent facts: an anonymous closure's explicit executor and lexical actor
inheritance selected by its consuming API. Evidence therefore requires the
runtime change to represent explicit closure isolation at formation and to
select lexical inheritance at task entry without mutating the shared closure.
Focused regressions also require ordinary immediate-detached inheritance to
remain MainActor and authored signatures to record zero physical receipts.
The canonical focused iteration passed those regressions, all forty-three
methodology checks plus three isolated gate-contract checks, and twenty parity
repetitions on four workers in two seconds. The rebuilt scoped TSan board
passed native overlap 20/20 plus all 62 physical tests on four workers in 40
seconds without a race or interceptor diagnostic. The exact-tip async,
generated Task-surface, and parallel-kernel board passed 137 tests in three
suites on four workers in two seconds.

The sixty-fifth M9 slice is an already-GREEN characterization of
closure-signature `@Sendable`. Two pinned corpus sites use the exact detached
operation form: swift-composable-architecture
`CurrentValueRelayTests.swift:38` and CotEditor `FileNode.swift:410`. The
oracle compares `Task { @Sendable in ... }` with
`Task.detached { @Sendable in ... }` from one MainActor function and samples
source isolation on both sides of `Task.yield`.

Apple Swift 6.3.3 compiled the same source in Swift 6 complete-strict mode
with warnings as errors. Twenty bounded runs returned exact
`same|same#none|none`; all four five-run shards retained digest
`c1c7528bed014c8a1065d919d0b0813aad3cb8170d5d495fd0968c2812edeaa4`.
The current interpreter returned the same observation before any production
change, with zero physical submissions/executions and empty task, structured-
scope, and task-group registries. Evidence therefore records characterization
rather than inventing a RED: `@Sendable` is executor-neutral, while Task API
selection still controls lexical actor inheritance. The focused iteration
passed two regressions, all forty-three methodology checks plus three isolated
gate-contract checks, and twenty parity repetitions in two seconds. The
exact-tip async, generated Task-surface, and parallel-kernel board passed 138
tests in three suites on four workers in two seconds.

The sixty-sixth M9 slice characterizes the composition of two previously
separate guarantees. Provenance contains 11 exact
`Task.detached { @MainActor [weak self] in ... }` operations. One probe branch
keeps the receiver live; a second uses an actor gate to establish task entry
and suspension before the parent clears the final strong receiver.

The exact corpus spelling triggers Apple Swift 6.3.3's region-checker internal
unsupported-pattern diagnostic. The strict oracle therefore adds the already
proven executor-neutral `@Sendable` attribute and otherwise preserves the
shape. Twenty bounded native/interpreter runs returned exact
`same|same:alive#same|same:released`; all four five-run shards retained digest
`768eb94127084dde469655732899dc1af00bd57c0f04a710c4edbc8e939c46d6`.
The interpreter was GREEN before any production edit, records zero physical
receipts, and drains task, actor, scope, and group registries. Evidence is
therefore an already-GREEN composition characterization. The focused
iteration passed three regressions, all forty-three methodology checks plus
three isolated gate-contract checks, and twenty parity repetitions on four
workers in two seconds. The exact-tip async, generated Task-surface, and
parallel-kernel board passed 139 tests in three suites on four workers in two
seconds.

The sixty-seventh M9 slice asks whether Planet's labeled immutable `String`
capture can use the existing physical-wrapper/confined-reentry architecture
without widening source evaluation onto a worker. The exact demand spelling
is `Task.detached { await self.sendNotificationForNewCID(cid: cid) }` in
`MyPlanetModel.swift:2948-2950`.

Strict Apple Swift 6.3.3 and interpreted execution returned exact
`bafy-planet:none|none` in twenty bounded runs; all four five-run native shards
retained digest
`2e15021f8c242902f4ed71d5b4dd1a16a4cc66ec7ca6135550bd1b58782e99a0`.
The captured RED was receipt-only: the source value and nil isolation were
already correct, but parallel mode reported zero submissions/executions
instead of one.

Evidence requires one typed String command argument, one structural worker
snapshot, exact String-parameter validation, confined materialization, one
physical receipt, and complete cleanup. A negative control requires String
literals, mutable String captures, and identical immutable captures routed to
MainActor or `@concurrent` methods to remain cooperative. Thus the new scalar
kind cannot silently broaden other route families.
The focused iteration passed both regressions, all forty-three methodology
checks plus three isolated gate-contract checks, and twenty parity repetitions
on four workers in two seconds. The exact-tip physical board passed 64 tests
in three suites in one second. Its rebuilt TSan twin passed native overlap
20/20 plus all 64 tests in 33 seconds without a race or interceptor
diagnostic.

The sixty-eighth M9 slice asks whether Amperfy's exact `[weak self]` optional
call can copy one immutable String into an `@concurrent` async Void source
method while retaining Swift's weak ownership and nil actor isolation. The
demand spelling is `Task.detached(priority: .high) { [weak self] in await
self?.loadImageAndCacheIt(imagePath: imagePathToDisplay) }` in
`LibraryEntityImage.swift:171-173`; the selected method begins at line 177.

Strict Apple Swift 6.3.3 compiled the same-source fixture with complete
concurrency checking and warnings as errors. Native and interpreted execution
returned exact `cover-cache:none|none#some` in twenty bounded repetitions;
every focused five-run shard retained canonical digest
`048303aaf53c0ed1e6f9788bb5cf8564a63ad7b333f05addf7971bc5c510e699`.
The receipt RED already returned the exact value but recorded zero physical
submissions/executions instead of one.

The weak route is reviewed separately from direct-self admission. It accepts
only a source class, an exact capture-only weak self signature, an
`@concurrent` async nonthrowing Void method, and one directly owned immutable
String argument. The capability copies that String only. MainActor re-entry
then reloads the weak box and re-resolves the same descriptor using the
materialized argument. A worker permit is deliberately occupied in the
lifetime regression; dropping the receiver before re-entry yields `released`,
proving neither the command nor the copied argument retained it. Literal and
mutable Strings, inherited/MainActor/actor routes, multiple arguments,
throwing effects, and richer results remain cooperative with zero receipts.
The focused iteration passed three regressions, all forty-three methodology
checks plus three isolated gate-contract checks, and twenty parity repetitions
on four workers in two seconds. The exact-tip physical board passed 67 tests
in three suites in one second;
the rebuilt TSan board passed native overlap 20/20 plus all 67 tests in 26
seconds without a race or interceptor diagnostic.

The sixty-ninth M9 slice asks whether Provenance's exact weak-self call may
pass a String literal to an inherited-isolation async Void source method
without widening either existing captured-String route. The cited spelling is
`Task.detached { [weak self] in await
self?.restartProcessingIfQueueHasPendingWork(context: "timeout") }` at
`GameImporter.swift:1297-1299`; the selected method begins at line 1092.

Strict Apple Swift 6.3.3 compiled the same-source fixture with complete
concurrency checking and warnings as errors. Native and interpreted execution
returned exact `timeout:none|none#some` in twenty bounded repetitions; every
five-run shard retained canonical digest
`fc29406e305e33efd900981045bd11728b7edc7f352ec5dd5f3dac67a99ee469`.
The deterministic receipt RED already returned the exact value but observed
zero physical submissions/executions instead of one.

The positive regression requires one physical wrapper and empty runtime
registries. The retained negative controls require the direct inherited route
to reject String literals, the weak `@concurrent` route to reject literals,
and the weak inherited route to reject captured or mutable Strings, MainActor
targets, and unrelated shapes. Admission therefore records typed literal
versus captured-immutable origin in the checked command instead of inferring
semantics from a generated binding name. The focused regressions passed 5/5;
the four-worker same-source board passed 20/20 in two seconds; the exact-tip
physical board passed all 68 tests in one second; and the rebuilt TSan board
passed native overlap 20/20 plus all 68 tests in 69 seconds without a race or
interceptor diagnostic.

The seventieth M9 slice asks whether Session-iOS's repeated weak-self call may
pass one immutable String capture to an inherited-isolation async Void method.
The exact spelling appears at `ConversationVC+Interaction.swift:1016-1018`
and `AttachmentApprovalViewController.swift:860-862`; both selected methods
are named `updateMentions(for:)`.

Strict Apple Swift 6.3.3 compiled the same-source fixture with complete
concurrency checking and warnings as errors. Native and interpreted execution
returned exact `session-message:none|none#some` in twenty bounded repetitions;
every five-run shard retained canonical digest
`d12895520e72e0f0c35194394fa4cc6fe01f5cf0bba7f133fc04e8fe06994403`.
The deterministic receipt RED already returned the exact value but observed
zero physical submissions/executions instead of one.

The positive regression requires one physical wrapper and empty runtime
registries. The adjacent controls retain the literal weak inherited route,
the captured weak `@concurrent` route, and the direct inherited capture route,
while a mutable weak inherited String remains cooperative with zero receipts.
This proves that admission consumes the existing typed
`.capturedImmutable` provenance rather than treating every identifier as a
safe snapshot. The focused board passed six tests; the four-worker same-source
board passed 20/20 in two seconds; the exact-tip physical board passed all 69
tests in one second; and the rebuilt TSan board passed native overlap 20/20
plus all 69 tests in 25 seconds without a race or interceptor diagnostic.

The seventy-first M9 slice asks whether KeyboardCowboy's exact weak-self call
may pass one immutable `[String]` capture to an inherited-isolation async Void
method. The demand spelling is `Task.detached { [weak self] in await
self?.reload(additionalPaths) }` at `ApplicationStore.swift:79-81`; the
selected method begins at line 90.

Strict Apple Swift 6.3.3 compiled the same-source fixture with complete
concurrency checking and warnings as errors. Native and interpreted execution
returned exact `Applications,WebApps:none|none#some` in twenty bounded
repetitions; every five-run shard retained canonical digest
`1782ec2cb9384815bd4effeae9daa6f2521dc4064c23871eea026619d5184104`.
The deterministic receipt RED already returned the exact value but observed
zero physical submissions/executions instead of one.

The positive regression requires both copied array elements, one physical
wrapper, and empty registries. A separate zero-receipt control passes typed
`[String]` parameters through direct inherited, weak `@concurrent`, and weak
MainActor calls; all remain cooperative. The command kind also rejects any
non-String snapshot element or non-`[String]` declared parameter. This proves
that recursive Sendable copying is necessary but not sufficient for route
admission. The focused route board passed eight tests; the same-source board
passed 20/20 in two seconds; the exact-tip physical board passed all 71 tests
in one second; and the rebuilt TSan board passed native overlap 20/20 plus all
71 tests in 29 seconds without a race or interceptor diagnostic.

The seventy-second M9 slice asks whether Meshtastic-Apple's exact
`Task.detached(priority: .utility) { try? await
self.refreshDevicesAPIData() }` wrapper may run physically without sending an
interpreted thrown value across a worker boundary. The cited own source-class
method at `MeshtasticAPI.swift:199` is inherited-isolation, async, throwing,
argument-free, and Void-returning.

Strict Apple Swift 6.3.3 compiled the same-source fixture with complete
concurrency checking and warnings as errors. Native and interpreted execution
returned exact `success:none|none#some|failure:none|none#nil` in twenty bounded
repetitions. Every five-run native shard retained canonical digest
`bea8145a5762b64cfca390d6d8247e3f3c6d695e8d6a1a7d22bc294251068b9e`;
the deterministic receipt RED returned the same value but observed zero
physical submissions/executions instead of two.

The positive regression requires physical receipts for both the successful
and source-throwing calls. The error must be caught during confined MainActor
re-entry, where `InterpretedThrow.value` remains owned, and only the resulting
typed `Optional<Void>` snapshot may return to the worker. A trap regression
requires fatal `RuntimeError` to escape authored `try?` while remaining
contained by the runtime task and host process. A zero-receipt control keeps
plain `try`, `try!`, argument-bearing, richer-result, MainActor,
`@concurrent`, and weak-self variants cooperative. The focused route board
passed three tests; the same-source board passed 20/20 in one second; the
exact-tip physical board passed all 74 tests in one second; and the rebuilt
TSan bundle plus a retained confirmation passed native overlap 20/20 plus all
74 tests, with the confirmation completing in 14 seconds without a race or
interceptor diagnostic.

The seventy-third M9 slice asks whether FreeChat's exact two-item detached
body may execute its contained throwing sleep physically and then resume the
remaining source expression without transporting confined evaluator state.
The cited spelling is `Task.detached(priority: .userInitiated) { try? await
Task.sleep(for: .seconds(1)); await submit(input) }` at
`ConversationView.swift:228-231`.

Strict Apple Swift 6.3.3 compiled the same-source fixture with complete
concurrency checking and warnings as errors. Native and interpreted execution
returned exact `completed:false,cancelled:true|false:true` in twenty bounded
repetitions. Every five-run native shard retained canonical digest
`0a5b2906a7b66290e031388b4917c98fc54cbd9670544a3d5a05930982e24523`;
the deterministic receipt RED returned the same value but observed zero
physical submissions/executions instead of two.

The positive regression requires both worker sleeps, including a pre-cancelled
30-second sleep whose `CancellationError` is suppressed before the suffix
observes `Task.isCancelled == true`. A confined outcome token proves that the
suffix closure, captured environment, `RuntimeValue`, and `Error` never cross
the worker boundary. A maximum-parallelism-one regression requires executor
handoff before a nested physical task can finish, a trap regression requires
fatal errors to remain host-contained, and zero-receipt controls retain plain
`try`, `try!`, nanoseconds/microseconds, three-item, reversed, and authored-
signature forms on the cooperative evaluator. Same-source parity passed 20/20
on four workers in one second; the exact-tip physical board passed all 78
tests in one second. The rebuilt scoped TSan board passed native overlap 20/20
plus all 78 tests in 60 seconds without a race or interceptor diagnostic.

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
