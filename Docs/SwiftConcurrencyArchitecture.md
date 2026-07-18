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
executor queue. M6 now includes a bounded checked-continuation registry. The
nonthrowing form owns explicit or caller-defaulted `nil` and
`MainActor.shared` isolation, `resume(returning:)` value slices plus
explicit-`nil` zero-argument Void
`resume()` and `Result<T, Never>` resume; the throwing form shares the same
record for explicit-`nil` value return, caller-defaulted isolation, and exact
source-error projection through `resume(throwing:)`, has exact MainActor
body/caller-restoration evidence for its error path, and delegates both
concrete-error and existential
`Result<T, any Error>` values passed to `resume(with:)` to those same terminal
transitions.
Contextual MainActor body execution is temporary, each
active record is owned by one task and names the caller's required resume
executor, and the canonical suspension lease removes every edge on success,
source failure, or infrastructure abort.
M6 began with protocol-driven
`for await` over interpreted witnesses, including suspending mutating iterator
copy-out, typed source-error propagation, and cooperative user-iterator
cancellation. Early `break` and its per-iteration `defer` cleanup are also
covered together with `continue` and `return` cleanup; protocol-extension
defaults for both requirements are covered as well. Host-backed sequences,
including typed opaque gateways with tracked host suspension, are covered as
well. Both stream flavors' evidenced cancellation, buffering, iterator-copy,
and lifetime tails are covered. Checked nonthrowing and throwing continuations
now cover explicit and caller-defaulted source actors. Checked continuations
also preserve Swift's fatal invariant when either checked form is resumed more
than once, including through source `do`/`catch`. Both checked forms now emit
Swift's successful-process misuse warning when the final unresumed source token
is released; the waiting task stays suspended and explicit host teardown
remains separate. A resumed checked token may remain escaped after owner
completion without retaining the task-local owner graph, runtime, session, or
interpreter, and its later release is inert. The active-interface generator
routes both unsafe continuation entry points to one shared named fail-closed
intrinsic before body invocation or ownership allocation. The demand-scoped M6
cycle is closed. The demand-scoped M8 SwiftUI lifecycle cycle is also covered:
BridgeGen emits the active
SDK `.task`, `.task(id:)`, and `.refreshable` surface, while one reusable
adapter lets real SwiftUI own appearance/identity and enters each invocation
through a fresh canonical `.swiftUITask` session. Same-source hosted probes
cover async entry, logical MainActor identity, disappearance cancellation, id
replacement, same-id preservation, refresh trigger/completion, and complete
per-task cleanup. A 32-cycle teardown characterization additionally proves
distinct session/task identities, complete registry draining, weak release of
each task-owned graph, and final interpreter/runtime release. M8 remains
provisional only because its broad M5/M7 dependencies remain partial; the
active cycle is now M9 optional physical parallelism.

The first M9 prerequisite slice is implemented: `ParsedProgram` now owns the
immutable parsed/operator-folded syntax tree and source-location index, is
strictly `Sendable`, and may be reused by independent interpreter sessions.
Eight detached readers and two concurrent cooperative sessions exercise the
same instance without sharing evaluator state. It now also owns a target-
neutral, all-conditional-branch `ParsedDeclarationIndex`; mutable runtime
symbols and the runtime heap do not belong in this value.

The second prerequisite makes that mutable boundary explicit. Each
`Interpreter` now owns exactly one `RuntimeHeap`, and its global environment,
synthesized environment models, and SwiftUI state cells are rooted there.
Independent interpreters have distinct heaps, the compatibility `globals` API
exposes the actual heap root, and releasing the facade releases the heap. The
heap, evaluator, declarations, and runtime registries remain MainActor-
confined; `Environment`, `Box`, and `Instance` have not been made `Sendable`.
This is an ownership characterization, not a physical-parallelism claim.

The third prerequisite makes `runAsync` construct and execute through a real
single-use `InterpreterSession`. That object binds one `ParsedProgram`, the
facade's `RuntimeHeap`, the cooperative runtime, one runtime entry, lazy-
global mode, and completion policy. The live root task carries exactly that
entry; foreign-facade execution and reuse are rejected; and the session keeps
its heap/runtime capabilities alive without retaining the facade. Declaration
and evaluator state still lives on the facade. This remains MainActor-confined
ownership work, not worker execution.

The fourth prerequisite moves top-level declaration discovery out of the
evaluator. Parsing now classifies every possible nominal, function, global,
typealias, and extension once, including every conditional-compilation branch.
Each session resolves that immutable index once against its own build identity,
and both declaration materialization and top-level execution consume the same
resolved plan. Eight detached readers share the index, while one parsed source
resolves different iOS/macOS nominal + typealias + extension plans correctly.
The resulting mutable `StructSymbol`/`EnumSymbol` graphs are still created per
facade/session on MainActor; member, call, isolation, and compiler-preflight
metadata have not all moved into `ParsedProgram` yet.

The fifth prerequisite replaces bare production `RuntimeSessionID` ownership
with an explicit `RuntimeEntry` capability. Program roots, synchronous host
callbacks, SwiftUI-owned async entries, and every source task they create now
retain one entry object that binds its unique ID, entry kind, interpreter, and
heap. A completed callback root may release while its unstructured tasks keep
the entry and heap alive. Distinct callback entries may overlap cooperatively
against the same MainActor-confined heap: a causally gated Swift 6 probe proves
a second callback can resume a task parked by the first and completes before
that task continues on MainActor. This defines the current overlap policy; it
does not authorize physical concurrent heap access.

The sixth prerequisite moves function and initializer call metadata out of
mutable facade caches. `ParsedProgram` now owns one immutable, Sendable,
all-branch `ParsedCallableMetadataIndex` containing parameter/call shapes,
return and builder facts, generic names, effects, declaration attributes, and
the currently modeled explicit isolation flags. A program `RuntimeEntry`
retains that index, and escaped source closures carry the capability into
fresh host-callback and SwiftUI entries. Eight detached readers observe one
snapshot, while focused ownership tests prove sessions and callback-created
tasks keep the originating program's metadata. Existing native parity for
plain explicitly nonisolated async declarations remains exact; this slice does
not claim complete member/accessor, call-site, or compiler metadata.

The seventh prerequisite extends that same index across readable accessor
blocks and subscript declarations. Getter bodies, `async`/`throws` effects,
setter bodies and custom parameter names, subscript parameters/call shapes,
result types, and explicit nonisolation are now parsed once. Computed-property,
local/global accessor, and subscript materialization consume the immutable
index; observer-only `willSet`/`didSet` blocks remain storage metadata rather
than readable accessors. Swift 6 parity for controlled async-throwing actor
subscript success and source-error exits remains exact. Nominal/property
storage metadata, call-site resolution, and compiler fingerprints remain open.

The eighth prerequisite consolidates propagation behind one
`ParsedProgramMetadata` capability. It initially owns the declaration and
callable indexes and is the sole syntax-derived metadata edge carried by program
sessions, runtime entries, source closures, synchronous host callbacks, and
SwiftUI tasks. Future nominal, call-site, isolation, or compiler indexes extend
this value without adding another parallel field to every ownership object.
Eight detached readers, session-entry assertions, a callback invoked after the
facade prepares a different program, and real SwiftUI lifecycle coverage prove
that the originating snapshot is retained. This is an ownership refactor; the
native `extractIsolation` observation remains unchanged.

The ninth prerequisite adds an immutable, all-branch
`ParsedNominalMetadataIndex` to that composite capability. Struct, class,
actor, enum, and protocol headers are indexed once, including nested/local
declarations and inactive conditional branches. Each entry owns its language
kind, name, inherited type spellings, declaration attributes, and generic
parameter constraints. Struct/class/actor/enum symbol construction and
protocol-inheritance registration consume the index, with a pure fallback for
synthetic syntax; mutable members and enum raw-value evaluation remain
session-owned. Eight detached readers, callback provenance after preparing a
different program, and the existing canonical custom-global-actor tests cover
the boundary. Swift 6 custom-global-actor parity remains unchanged in twenty
repetitions. Property-storage metadata is handled by the next prerequisite;
remaining member metadata, call-site resolution, and compiler fingerprints
remain open.

The tenth prerequisite adds an immutable, all-branch
`ParsedPropertyMetadataIndex` to the same composite capability. Every variable
declaration and pattern binding is indexed by syntax identity across top-level,
member, local, nested, and inactive conditional-compilation regions. The index
owns `let`/`var`, `static`/`class`, `lazy`, explicit `nonisolated`, `@TaskLocal`,
weak/unowned storage-edge policy, identifier and tuple storage shapes,
stored-versus-computed classification, and `willSet`/`didSet` bodies plus custom
parameter names. Global, struct/class/actor, enum-static, and local storage
materialization consume these immutable facts with a pure fallback for foreign
or synthetic syntax. Mutable boxes, static values, wrapper evaluation, and the
runtime symbol graph remain session/facade-owned. Eight detached readers,
session and callback provenance, storage/observer/ARC regressions, and the
existing actor-initialization oracle cover the boundary. Swift 6 actor
initialization parity remains unchanged in twenty repetitions; this is not a
physical-worker claim.

The eleventh prerequisite adds an immutable, all-branch
`ParsedEnumCaseMetadataIndex` to the composite capability. Every enum-case
element is indexed by syntax identity across top-level, nested, local, and
inactive conditional-compilation regions. The index owns normalized and
backticked names, associated-value labels and type spellings, and explicit raw
value expressions. Enum symbol construction consumes those immutable headers
with a pure fallback for foreign or synthetic syntax; selection of active
`#if` declarations, implicit String/Int raw values, and evaluation of explicit
raw expressions remain session-owned. The demand depth is bounded to spellings
cited by FoodTruck's `User`, `Panel`, and `BrandHeader.HeaderSize`; attributes
and `indirect` semantics are not claimed. Eight detached readers, session and
callback provenance, enum regressions, and a same-source actor-crossing oracle
cover the boundary. Swift 6 and the interpreter produce
`authenticated:foodtruck|default|1.0:0.5` in twenty repetitions without a
scheduler-order or physical-worker claim.

The twelfth prerequisite adds an immutable, all-branch
`ParsedExtensionMetadataIndex` to the same composite capability. Every
extension declaration is indexed by syntax identity across nested and inactive
conditional-compilation regions. The index owns the extended type spelling,
inherited conformances, generic `where` requirements, attributes, and
modifiers. Extension target resolution and retroactive conformance merging
consume those immutable headers with a pure fallback for foreign or synthetic
syntax; active-branch selection, member materialization, and supported generic-
constraint behavior remain session-owned. FoodTruck bounds the slice with
dotted `Donut.Topping` extensions, the retroactive
`AuthorizationHandlingError: LocalizedError` conformance, and
`ClosedRange where Bound: BinaryFloatingPoint`. Eight detached readers,
session and callback provenance, existing extension regressions, and a
same-source actor-crossing oracle cover the boundary. Swift 6 and the
interpreter produce `true:42:21` in twenty repetitions. Nonmatching generic
constraints, scheduler order, and physical workers are not claimed.

The thirteenth prerequisite adds an immutable, all-branch
`ParsedTypeAliasMetadataIndex` to the composite capability. Every typealias is
indexed by syntax identity across top-level, member, local, nested, and
inactive conditional-compilation regions. The index owns the alias name, full
target spelling, normalized lookup target, generic parameters and
requirements, attributes, modifiers, and nominal-versus-tuple/function target
classification. Top-level alias heads and values, member aliases, local
aliases, and lexical-name discovery consume those immutable headers with a
pure fallback for foreign or synthetic syntax; active-branch selection and
binding into mutable runtime symbols remain session-owned. FoodTruck bounds
the slice with the conditional private top-level and member aliases in
`DetailedMapView`, while cited corpus regressions cover generic alias
normalization. Eight detached readers, session and callback provenance, alias/
deinitializer regressions, and a same-source actor-crossing oracle cover the
boundary. Swift 6 and the interpreter produce `mac:42` in twenty repetitions
for the selected non-watchOS branch. Inaccessible inactive-branch behavior,
scheduler order, and physical workers are not claimed.

The fourteenth prerequisite adds an immutable, all-branch
`ParsedDeinitializerMetadataIndex` to the composite capability. Every
deinitializer is indexed by syntax identity across nested and inactive
conditional-compilation regions. The index owns its body, attribute type
spellings, and modifier names, including explicit `isolated` and
`nonisolated`. Deinitializer body attachment and executor-policy resolution
consume those facts with a pure fallback for foreign or synthetic syntax;
active-branch selection and attachment to mutable nominal symbols remain
session-owned. FoodTruck bounds the slice with the ordinary `deinit` on its
`@MainActor StoreMessagesManager`. Eight detached readers plus session and
callback provenance cover ownership. Swift 6 and the interpreter produce
`body|none:foodtruck|after` in twenty repetitions: the ordinary deinitializer
remains nonisolated and completes synchronously at final release. Isolated or
custom-global-actor teardown beyond existing fail-closed coverage, scheduler
order, and physical workers are not claimed.

The fifteenth prerequisite extends the existing immutable, all-branch
`ParsedCallableMetadataIndex` with function names, modifier names, and
static/class-versus-instance placement. Struct and enum method registration,
global function binding, closure debug names, and lexical capture discovery
consume those facts with a pure fallback for foreign or synthetic syntax;
active-branch selection, overload sets, closures, and mutable nominal symbols
remain session-owned. FoodTruck bounds the slice with `static func` callables
in `City`, `StoreMessagesManager`, and `TaskSeconds`. Session/callback
provenance and directly affected callable regressions cover ownership. After a
generic parity helper was corrected to recognize the runtime carrier for
`MainActor.shared`, the unchanged interpreter and Apple Swift 6.3.3 both
produce `type:same:foodtruck|instance:same` in twenty repetitions. The index
records `class` placement as a syntax fact, but class-method dispatch,
scheduler order, and physical workers are not claimed.

The sixteenth prerequisite extends the same callable index with immutable
initializer bodies, attribute and modifier names, failable/Codable
classification, and explicit nonisolated/MainActor facts. One shared
initializer-closure builder now serves struct/class/actor, enum, extension,
superclass, synchronous, and suspending execution; overload selection,
synthesized arguments, optional projection, and bridge Codable discovery also
consume the index. Ordinary initializers of MainActor-isolated non-actor
nominals inherit MainActor, explicit `nonisolated init` suppresses that
inheritance, and actor initializers retain Swift's lexically nonisolated
initialization rule. FoodTruck bounds the slice with the nonisolated
initializers of `StoreProductController` and `StoreSubscriptionController`,
the ordinary `StoreActor` initializer, and `Subscription.init?`. Apple Swift
6.3.3 and the interpreter produce
`isolated:same:foodtruck|nonisolated:none:store|accepted|rejected` in twenty
repetitions after the pre-fix interpreter reported `isolated:none`. Async and
custom-global-actor initializer expansion, scheduler order, and physical
workers are not claimed.

The seventeenth prerequisite completes the currently modeled function-
declaration facts in that callable index. Each function entry now owns its
optional body as well as its already indexed name, parameters, shape, return
and builder facts, generics, attributes, modifiers, effects, isolation, and
placement. A bodyless count keeps protocol requirements and imported/extern
absorbers observable without asking runtime materialization to inspect syntax.
All synchronous and suspending global, instance, static, enum, extension,
operator, pattern-matching, and public-evaluation dispatch paths now obtain
function bodies, required/defaulted parameters, labels, and `mutating` from
the immutable entry. Call-site identity/resolution and the separate host-
signature compiler parser remain distinct metadata boundaries.

FoodTruck supplies 133 function declarations, including the async account and
StoreKit bodies, layout methods and nested local helpers, mutating model
operations, static reducers/operators, and ViewModifier bodies. The compile-
time RED was the missing `ParsedFunctionMetadata.body` and
`bodylessFunctionCount`. This is an architectural migration, not an invented
runtime mismatch: the existing MainActor static/instance body fixture remained
exact against Apple Swift 6.3.3 in twenty bounded repetitions, producing
`type:same:foodtruck|instance:same` after an awaited actor hop. At four workers
each five-observation native shard reported SHA-256
`fbf74f9374e93a219a2c349cca34944ca2bac412063869be06806b33df31c0fd`.
No bodyless-requirement invocation, new isolation behavior, scheduler order,
physical thread, or physical parallelism is inferred.

The eighteenth prerequisite introduces an immutable, all-branch
`ParsedCallSiteMetadataIndex` for the argument structure runtime evaluation
actually consumes. Each function-call entry owns ordinary argument labels and
expressions, the first and additional trailing closures in source order, and
the spelling of a bare unqualified declaration reference when one is present.
Compiler-only conditional predicates such as `#if os(iOS)` are deliberately
excluded: they are build-selection inputs, not runtime call sites. Both
synchronous and suspending argument collection now consume one shared metadata
shape, and the bounded async-operation provenance check uses the captured
direct-reference spelling rather than reparsing the expression. Runtime value
evaluation, active-branch selection, overload choice, and call-target identity
remain session-owned; this slice does not pretend that syntax facts are a
compiler-resolved call graph.

FoodTruck supplies 41 additional-trailing-closure spellings, including
`ActivityConfiguration { } dynamicIsland: { }` and the four-region
`DynamicIsland` builder, plus direct action arguments such as
`Button(action: onPurchase)` and `Button(action: onDismiss)`. The architectural
RED was compile-time: `ParsedCallSiteMetadataIndex`, its composite capability
edge, and the new call-site summary did not exist. The runtime behavior was an
already-GREEN characterization. Apple Swift 6.3.3 and the interpreter preserve
the exact `withTaskExecutorPreference(nil, isolation: nil)` task-state/error
projection in twenty bounded repetitions; four five-observation native shards
each reported SHA-256
`8cd6f4abe47320a422f3c0da80530aa47491ddb0eace1d6087040e1f16dd5e86`.
The final prebuilt focused gate completed ten tests in four suites, all
forty-two methodology checks, and all twenty parity repetitions in two
seconds.
No qualified or converted function-value provenance, overload-resolution
guarantee, new executor behavior, scheduler order, physical thread, or physical
parallelism is inferred.

The nineteenth prerequisite introduces an immutable, all-branch
`ParsedMemberMetadataIndex`. It classifies direct variable, function,
initializer, deinitializer, subscript, type-alias, enum-case, nested-nominal,
and other declarations for every nominal and extension member block. Nested
conditional regions retain their ordered conditions and clauses; each runtime
session resolves one active declaration sequence with its build configuration
before creating mutable symbols. Struct, class, actor, enum, and extension
materialization now consume that plan instead of independently walking
`MemberBlockSyntax`, recasting every declaration, and recursively selecting
`#if` clauses. Protocol requirements remain inert, active-branch selection and
symbol values remain session-owned, and the separate HostSignature/compiler-
preflight parsers are not folded into this runtime index.

FoodTruck bounds the slice with five conditional member regions: stored
properties in `StoreSupportView`, `DonutGalleryGrid`, and `OrdersView`, plus
the conditional type alias and platform-specific methods in `DetailedMapView`.
The compile-time RED named the missing `ParsedMemberMetadataIndex`, composite
capability edge, and runtime member resolver. The same-source semantic probe
was already GREEN after its oracle was narrowed away from the unrelated
`String(describing:)` enum-formatting divergence. Apple Swift 6.3.3 and the
interpreter select the non-watchOS stored property, method, nested type,
extension method, and enum case and produce
`foodtruck:7:type:extension:regular:nested` in twenty bounded repetitions. Four
native shards each reported SHA-256
`8c1f91f180b8517d68ab0a40b3f0cc2ab73a32db163c2d296b1bc25d9561a937`.
The final prebuilt focused gate completed sixteen tests in ten suites, all
forty-two methodology checks, and all twenty parity repetitions in one second.
No positive-watchOS selection, new member semantics, scheduler order, physical
thread, or physical parallelism is inferred.

The twentieth prerequisite closes the split ownership of target selection.
`ParsedProgram.resolve(buildConfiguration:)` now produces one immutable,
Sendable `ResolvedProgramPlan` containing the originating composite metadata,
the exact build configuration, the resolved top-level declaration plan, and
the resolved member plan. An `InterpreterSession` creates this capability
before mutable symbols are materialized. Its `RuntimeEntry`, every source
`ClosureValue`, later host callbacks, SwiftUI tasks, and source tasks retain
the same plan identity. An escaped closure therefore cannot reselect a
conditional member using whichever target or parsed program the mutable
interpreter facade prepared most recently. Compatibility and foreign-syntax
fallbacks remain explicit; evaluator state and runtime values remain
MainActor-confined.

The architectural RED was compile-time: `ResolvedProgramPlan`,
`ParsedProgram.resolve(buildConfiguration:)`, and the plan edges on session,
entry, and closure did not exist, while the immutable build-configuration
evaluator was still MainActor-isolated. The semantic question reused the
already-owned `conditional-member-metadata` oracle instead of manufacturing a
new behavior claim: Swift selects target declarations at compilation and that
selection survives an actor hop. Before production changes, Apple Swift 6.3.3
and the interpreter matched in all twenty bounded repetitions, producing
`foodtruck:7:type:extension:regular:nested`; each four-worker native shard
reported SHA-256
`8c1f91f180b8517d68ab0a40b3f0cc2ab73a32db163c2d296b1bc25d9561a937`.
The post-change prebuilt focused gate preserved that exact result in all
twenty repetitions and completed thirteen ownership/dispatch tests in seven
suites plus all forty-two methodology checks within two seconds.
No new conditional-compilation semantics, scheduler order, physical thread, or
physical parallelism is inferred.

The twenty-first prerequisite introduces `RuntimeProgramState`, one
MainActor-confined mutable capability per prepared program. It owns the
materialized struct/enum/host-extension registries, protocol inheritance,
global overload and dependency caches, lexical declaration owners, and
deferred extension/type-alias/deinitializer work that previously lived as
independent fields on the `Interpreter` facade. `InterpreterSession` and its
root `RuntimeEntry` retain the capability; each source closure stamps it at
creation, so later host callbacks, SwiftUI entries, compatibility tasks, and
their source tasks select the originating mutable declaration state rather
than the facade's most recently prepared program. Synchronous compatibility
APIs retain an explicit last-program fallback, and the empty bootstrap state
is used only before any program is prepared.

The architectural RED was compile-time: there was no `RuntimeProgramState`
type or state edge on sessions, runtime entries, or closures. Focused ownership
tests require two sessions to materialize distinct nominal registries and an
escaped callback plus its parked task to retain the exact originating state
after a newer session is prepared. The semantic workflow reuses the causally
gated `host-callback-overlap` fixture: native Swift establishes that a later
inline callback completes before the parked MainActor task resumes, without
asserting unrelated ready-task order. This change groups and routes mutable
state but does not make `StructSymbol`, `EnumSymbol`, `RuntimeValue`,
`Environment`, `Box`, or `Instance` Sendable. The heap and evaluator remain
MainActor-confined, so no physical-worker or parallel-heap claim is made.

The twenty-second prerequisite closes the remaining source-location ownership
split. `ResolvedProgramPlan` now retains the originating file identity and
immutable `SourceLocationConverter` beside its target and metadata. Runtime
diagnostics and `#line` first resolve through the current `RuntimeEntry` plan;
only work with no runtime entry may use the explicitly named synchronous
compatibility converter. An escaped callback therefore cannot have syntax from
`Origin.swift` interpreted through the facade's later `Newer.swift` source map.

The architectural RED was behavioral and captured before production changes:
after an origin closure escaped and a second program ran, its unresolved
identifier was mislabeled `41:2` instead of authored `3:9`. The native semantic
probe used Apple Swift 6.3.3, the macOS 26.5 SDK, and target
`arm64-apple-macosx26.0`; an async closure returned its lexical `#line` after
`Task.yield()`. The standalone probe produced `4`, and the manifest-backed
same-source fixture produces `5` in both native Swift and the interpreter in
twenty bounded repetitions. Four five-observation native shards each report
SHA-256
`322f82b1ee560245f7819acb862b0cc122800997a5b88693393f20d65762314b`.
This proves source provenance across a suspension and later callback entry; it
does not assert scheduler order, physical-thread placement, or parallelism.
The canonical parallel iteration completed thirteen ownership/source-map tests
in seven suites, all forty-two methodology checks, and all twenty parity
repetitions on four workers in 1.8 seconds.

The twenty-third prerequisite moves strong ownership of session-owned
unstructured and detached task handles from the mutable `Interpreter` facade
into `CooperativeConcurrencyRuntime`. Launch, completion cleanup, session drain,
and session cancellation now share one canonical runtime registry;
`Interpreter.scheduledTasks` remains only a read-only compatibility inspection
view. The registry deliberately keeps a discarded source handle alive until
the task completes or its owning session applies its completion policy, then
atomically releases both the handle's active record and the registry edge.

The architectural RED was compile-time: the cooperative runtime had no task-
capacity guard, strong scheduled-handle registry, session lookup, or canonical
release API, while those ownership responsibilities remained on the facade.
The native semantic baseline reused the unchanged
`task-handle-deallocation` fixture before production changes. Apple Swift
6.3.3 and the interpreter produced exact output `completed,active` in all
twenty bounded repetitions, proving that discarding the last source handle
neither cancels nor ends the task operation. Four native shards each reported
SHA-256
`372f912e1aed613d03587d6bd5fc29d6c08f1299ce903484b08e01c8e89a12f9`.
The same fixture and digest remain exact after the ownership migration. A
focused runtime test additionally drops its local handle, observes the
runtime-owned handle and active record, then proves canonical release removes
both. This is MainActor-confined ownership work; it does not claim a thread-
safe registry, physical workers, or parallel execution.
The canonical parallel iteration completed eleven ownership/lifecycle tests in
four suites, all forty-two methodology checks, and all twenty parity
repetitions on four workers in 1.9 seconds.

The twenty-fourth prerequisite moves monotonic `EvaluationTaskContext`
identity allocation and construction from `Interpreter` into
`CooperativeConcurrencyRuntime`. Program roots, host callbacks, and source
tasks now receive their task-owned evaluator context through one runtime
factory. The facade retains only its synchronous compatibility context with
reserved ID `0`; it no longer owns the async identity counter or factory.

The architectural RED was compile-time: the runtime had no evaluator-context
factory, and a focused ownership test could create contexts only through the
facade. The semantic workflow reused the unchanged
`task-owned-evaluator-context` fixture before production changes. Apple Swift
6.3.3 and the interpreter each preserved the complete multiset of 100 distinct
`even:index`/`odd:index` events across a forced yield in twenty bounded runs.
Completion order is unspecified, so ordered native shard hashes vary and are
deliberately not compared. After migration, the same twenty-run predicate
remains GREEN. Focused tests additionally cover two unique nonzero runtime-
allocated context IDs, 100 cleaned source-task contexts, 100 async-initializer
contexts, stale-context rejection, suspension-budget renewal, callback/task
entry propagation, session identity, and real SwiftUI async entry. The factory
and contexts remain MainActor-confined and contexts still weakly reference the
facade; this does not claim session-independent evaluation or physical
parallelism.
The canonical parallel iteration completed nine ownership/context tests in
seven suites, all forty-two methodology checks, and all twenty predicate
parity repetitions on four workers in 2.1 seconds.

The twenty-fifth prerequisite removes the remaining weak facade identity from
`EvaluationTaskContext`. Each asynchronous or compatibility context now keeps
only a weak `CooperativeConcurrencyRuntime` capability. The runtime factory no
longer accepts an `Interpreter`, and `Interpreter.evaluationTaskContext`
selects an ambient context only when its runtime identity matches the facade's
runtime. A context from another interpreter therefore cannot become the
facade's dynamic evaluator state. `TaskBoundEvalContext` deliberately remains
the explicit host capability that owns an interpreter while a retained host
callback must be able to re-enter it.

The architectural RED was compile-time: creating a context still required an
`interpreter:` argument, and the context had no runtime-identity capability.
The focused test now creates a context from the runtime alone, proves the
facade deallocates while that context remains, and proves a foreign-runtime
ambient context falls back to compatibility ID `0`. The semantic workflow
reuses `detached-host-context-reentry`: native Swift and the interpreter both
produce exact output `lost,preserved` in twenty bounded repetitions before and
after migration. All four native shards report SHA-256
`dfe2ffa3bba5229691693999686926094a6ab74bf6414514dfd18ce8d2b6a1fb`.
This proves that `Task.detached` does not inherit the bound value while an
explicitly captured host capability can rebind it around an async callback.
It does not make the evaluator facade-independent during active evaluation or
claim physical parallelism.
The canonical parallel iteration completed nine ownership/re-entry tests in
six suites, all forty-two methodology checks, and all twenty exact parity
repetitions on four workers in 1.9 seconds.

The twenty-sixth prerequisite removes the facade-wide native-stack-bounds
cache. Stack geometry belongs to a pthread, while recursion counters and their
guard state belong to one source task. Each `EvaluationTaskContext` therefore
owns one optional `EvaluationStackBounds` tagged with the stable numeric ID of
the pthread that supplied it. The evaluator reuses that geometry only while
the current ID matches, recomputes it after a thread migration, and clears it
with the rest of the task's dynamic state at completion. The synchronous
compatibility context uses the same rule, so even that long-lived context
cannot assume thread affinity.

The architectural RED was compile-time: `EvaluationTaskContext` exposed no
stack-bound state, while `Interpreter` held one mutable cache justified only by
current MainActor confinement. A real Apple Swift 6.3.3 probe compiled 256
child tasks with 32 checked-continuation suspensions each. Three executions
observed 5,663, 5,636, and 5,720 transitions between pthreads. Those counts and
their scheduling order are not contractual; they are a direct witness that a
task-to-thread affinity assumption is invalid. The focused ownership test now
proves two contexts do not share the cache and completion clears it. Retained
source-task and async-initializer contexts additionally remain dynamically
empty after execution, including this cache.

The unchanged `task-context-cancellation` same-source oracle remains exact at
`cancelled,beta` in twenty native/interpreter repetitions. Every native shard
reports SHA-256
`ba7179bb0bf0eee67a3387d8970c61377f3858c23b6b8764d9c2b37403530735`.
This change removes mutable facade state and makes the guard migration-safe;
it does not make the evaluator Sendable or claim physical parallelism.
The canonical parallel iteration completed ten targeted tests in five suites,
all forty-two methodology checks, and all twenty exact parity repetitions on
four workers in 2.1 seconds.

The twenty-seventh prerequisite makes the host bridge a prepared-program
capability instead of mutable evaluator-global state. `RuntimeProgramState`
captures the `HostRegistry` selected when the program or session is prepared.
Sessions, runtime entries, and escaped closures already retain that same state,
so program roots, synchronous host callbacks, SwiftUI tasks, and descendant
source tasks now resolve host APIs from their originating capability. The
facade's public `registry` remains the compatibility/default selection for
future preparation; changing it cannot redirect an entry that is already
bound to a program.

The semantic RED prepared a callback using an `origin` registry, changed the
facade to `newer`, ran a newer program successfully through that registry, then
invoked the old callback. Before the change it incorrectly returned `newer`;
the common program-state mechanism now returns `origin`. A separately compiled
Apple Swift 6.3.3 dependency-capture probe returns exact `origin,newer` in
three runs: a closure retains the capability supplied at formation while a
later active selection changes independently. This is a capture/provenance
guarantee, not a claim that native Swift has a `HostRegistry` abstraction.

The unchanged `host-callback-overlap` same-source fixture remains exact in
twenty native/interpreter repetitions. Every native shard reports SHA-256
`4b1da57b3c315b718431c1f2b0fd875d7b3de0d2e66f35b46a79762815ea2652`.
Focused tests cover inline callback and descendant-task entry sharing, source
map plus registry provenance, distinct session state, session lifetime, and
real SwiftUI task entry/cancellation. Registries and their values remain
MainActor-confined; this establishes ownership, not worker safety.
The canonical parallel iteration completed eight targeted tests in three
suites, all forty-two methodology checks, and all twenty exact parity
repetitions on four workers in 2.2 seconds.

The twenty-eighth prerequisite removes the process-wide static provider used
when a host coercion resolved an implicit member supplied by an interpreted
extension. `Date.now` was the demand-cited FoodTruck spelling, but the
ownership defect was general: preparing any later program replaced or cleared
one global closure, so an escaped callback could resolve host input through
the wrong program. Host gateways now ask their bound `EvalContext` for a
source static member. `TaskBoundEvalContext` restores the originating runtime
entry before that lookup, and the interpreter resolves against that entry's
retained `RuntimeProgramState`. Non-interpreter embedders retain an explicit
nil default.

The semantic RED prepared a callback under a frozen `Date.now`, prepared a
newer program with no shadow, and then invoked the old callback. It returned
the current wall-clock day instead of the origin program's day. A standalone
Apple Swift 6.3.3 probe proves that a same-module `Date.now` remains selected
when implicit `.now` enters `Calendar.startOfDay(for:)` after `Task.yield()`;
with a fixed UTC calendar it returned exact `1784160000` in three runs. The
same-source `host-static-shadow-after-suspension` fixture narrows the stable
projection to the authored epoch `1784228400` and matches in twenty
native/interpreter repetitions. This establishes program-bound host coercion,
not scheduler order, Sendable host values, physical threads, or parallelism.
The canonical parallel iteration completed seven targeted tests in four
suites, all forty-two methodology checks, and all twenty exact parity
repetitions on four workers in 1.8 seconds.

The twenty-ninth prerequisite distinguishes session ownership from lexical
program provenance. A `RuntimeEntry` owns the lifetime, cancellation domain,
and task graph of the run that is currently executing. It is not necessarily
the source program that created every closure reachable from the shared heap:
compatibility runs deliberately leave global functions and values available
to later runs. Every synchronous and suspending closure invocation therefore
pushes the closure's retained `RuntimeProgramState` onto a task-owned LIFO
stack in `EvaluationTaskContext`. Declaration state, resolved plan, metadata,
source map, and host registry resolve through that lexical frame for the whole
dynamic call, including default arguments and nested closure formation. The
frame is removed on every normal, throwing, and cancellation exit; task
cleanup requires the stack to be empty.

The deterministic RED reused one `Interpreter`: the first program declared an
actor and a global async function, and the second program invoked that retained
function. Before the change, the second session's empty state won over the
closure's originating state, so the actor method lost its lexical owner and
read mutable storage without a mailbox lease. The minimal test failed with
`actor-isolated mutable property ... accessed without owning its executor`;
the existing actor-mailbox board reproduced it at seed
`0xac705eed00000001`. A synchronous companion selected the wrong global
overload (`int` instead of `string`), proving both evaluator entry paths had
the same provenance defect. A strict Swift 6 probe ran two actor calls through
`Task.yield()` and produced the invariant sorted result `1:2` in twenty
compiled executions. That probe establishes actor serialization across
suspension; it does not claim that Swift has the interpreter's cross-program
compatibility model. The focused two-worker board completed both provenance
regressions, all 64 actor-mailbox schedules, trap containment, SwiftUI task
lifecycle, async-initializer, task-group, and cancellation stress checks. The
heap and evaluator remain MainActor-confined; no physical-worker, Sendable
heap, or scheduler-order claim follows.

The first full-gate attempt then exposed the corresponding host-value case:
`ModelStateTests.hostTypeExtensions` returned `nil` when a second compatibility
run called a `View` extension declared by the first. A host payload has no
interpreted nominal symbol from which to recover provenance. Each new program
state now retains a one-way lineage only to older states that actually
contribute host extensions; expression-only states are skipped and released.
Lookup presents a newest-wins overlay, while collection copy-on-writes the
synthetic `StructSymbol`, so a later extension cannot mutate the symbol seen by
an older closure. Method/accessor formation recovers the state owning its
declaration ID, and direct retained closures also select their lexical host
registry. Focused tests prove inherited lookup, one-way overlay isolation,
release of empty intermediate states, and both direct-call and runtime-entry
registry provenance.

The thirtieth prerequisite removes `defaultIsolation(MainActor.self)` from the
`SwiftInterpreter` target. This is an isolation-boundary change, not a
scheduler change: `Interpreter`, `RuntimeHeap`, `RuntimeProgramState`,
`CooperativeConcurrencyRuntime`, evaluator contexts, runtime values, symbol
graphs, environments, boxes, instances, and their mutable helper carriers now
declare `@MainActor` directly. Executor-neutral identifiers, durations,
immutable descriptors, syntax-only helpers, and native task/continuation
carriers declare `Sendable` or `nonisolated` where their stored state permits
it. No blanket `@unchecked Sendable` conformance was introduced.

Removing the target default produced the architectural RED: the compiler
reported every evaluator/runtime dependency that had relied on implicit
isolation. A public-module Swift 6 typecheck now accepts off-actor construction
of `RuntimeSessionID`, `RuntimeTaskID`, `RuntimeInstant`, and
`RuntimeDuration`, while a negative fixture rejects off-actor construction of
`RuntimeHeap`, `Interpreter`, and `RuntimeValue`. A standalone strict Swift 6
probe read immutable program data from a detached task and mutated an explicit
MainActor heap, returning exact `14:7` in twenty runs. The unchanged
`task-owned-evaluator-context` same-source oracle preserves its 100-event
multiset in twenty native/interpreter repetitions. The focused board completed
48 ownership/isolation tests in five suites, all forty-two methodology checks,
and both compile-boundary tests in two seconds. Physical workers, worker-safe
heap access, cooperative-versus-parallel parity, and TSan remain open.

The stable target separates five concerns:

```text
Immutable ParsedProgram
          └── ParsedProgramMetadata
                    │ resolve(target)
                    ▼
          ResolvedProgramPlan [target + source map]
                    │
                    ▼
InterpreterSession ─────────────── HostGatewayRuntime
          │                               │
          ├── RuntimeProgramState         │
          │     ├── mutable symbols          │
          │     └── declaration registries   │
          │                               │
          ├── RuntimeHeap                 │
          │     ├── globals               │
          │     ├── class storage         │
          │     └── actor storage         │
          │                               │
          └── RuntimeEntry ◀──────────────┘
                    │
                    ▼
              ConcurrencyRuntime
                ├── TaskRecord graph
                ├── StructuredScope graph
                ├── Executor registry
                ├── Cancellation state
                ├── Clock
                └── Continuation registry
                         │
                         ▼
                EvaluationTaskContext
                ├── lexical program-state stack
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

### 4.1 Explicit interpreter isolation; MainActor-default UI boundary

The `SwiftInterpreter` target no longer applies
`defaultIsolation(MainActor.self)`. Immutable and value-semantic descriptors
therefore remain executor-neutral by default, while mutable evaluator, runtime,
symbol, value, and heap capabilities declare `@MainActor` at their actual
ownership boundary. `SwiftUIBridge`, UI executables, and their tests retain
MainActor default isolation because that is their host contract. Source tasks
still ultimately execute evaluator work through one native actor: interleaving
is possible at suspension points, but physical parallelism is not.

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

The longer-term target split remains:

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

The remaining ceiling is one level higher: sessions now own distinct mutable
`RuntimeProgramState` declaration registries, and the cooperative runtime owns
session-scheduled task handles plus async evaluator-context identities and
capability matching. Contexts no longer point back to the facade, but
`Interpreter` still combines the evaluator, compatibility surface, and shared
`RuntimeHeap`; explicit `TaskBoundEvalContext` host capabilities retain it when
re-entry is required. Overlapping entries therefore select the correct program
state while still sharing MainActor-confined global/view heap storage. Moving
evaluation behind the session and classifying every heap edge remain required
before executor-neutral or parallel operation.

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
    let nominalMetadata: NominalMetadataIndex
    let propertyMetadata: PropertyMetadataIndex
    let enumCaseMetadata: EnumCaseMetadataIndex
    let extensionMetadata: ExtensionMetadataIndex
    let typeAliasMetadata: TypeAliasMetadataIndex
    let callMetadata: CallMetadataIndex
    let isolationMetadata: IsolationIndex
    let sourceLocations: SourceLocationIndex
    let compilerFingerprint: CompilerFingerprint?
}
```

SwiftSyntax values may require an internal immutable wrapper rather than direct
`Sendable` conformance. The semantic requirement is immutability and absence of
task-specific state.

Current implementation stage (2026-07-17): `ParsedProgram` owns the folded
syntax, source-location index, and one public immutable
`ParsedProgramMetadata` capability. That value owns the public
`ParsedDeclarationIndex`, `ParsedCallableMetadataIndex`,
`ParsedCallSiteMetadataIndex`, `ParsedMemberMetadataIndex`,
`ParsedNominalMetadataIndex`,
`ParsedPropertyMetadataIndex`, `ParsedEnumCaseMetadataIndex`,
`ParsedExtensionMetadataIndex`, and `ParsedTypeAliasMetadataIndex`;
compatibility accessors on `ParsedProgram`
expose the same values. The declaration index
classifies all possible top-level primary declarations, aliases, and
extensions across nested conditional regions. A session resolves exactly one
ordered build-specific plan; the collector no longer rescans the source or
re-evaluates top-level `#if` regions in three separate passes. The callable
index records all-branch function/initializer parameter shapes, effects,
return/builder/generic facts, attributes, and the modeled declaration-level
isolation flags once. It also records readable accessor getter/setter bodies
and effects plus subscript parameters, call shapes, result types, and explicit
nonisolation. Mutable runtime symbol materialization remains
session/facade-owned. The call-site index records a normalized direct-reference,
explicit-member, implicit-member, typed-array, typed-dictionary, or other
callee shape plus the original immutable callee expression, ordinary argument
labels and expressions, first/additional trailing-closure structure, and bare
unqualified reference spelling across runtime source regions while excluding
compiler-only conditional predicates. Synchronous and suspending call dispatch
and argument collection consume it; value evaluation, overload resolution, and
call-target identity remain session-owned. The member index classifies every
direct nominal/extension
declaration and nested conditional clause once; sessions resolve the active
member sequence before mutable struct/enum/extension materialization. The
nominal index records struct/class/actor/enum/
protocol kind, name, inherited type spellings, attributes, and generic header
constraints across top-level, nested, local, and conditional declarations;
nominal symbol construction consumes it. The property index records every
variable declaration and binding's immutable storage header, including
mutability, static/lazy/nonisolated/TaskLocal and reference-ownership policy,
tuple layout, stored/computed classification, and observer bodies. Global,
member, enum-static, and local storage materialization consumes it.
The enum-case index records normalized/backticked names, associated-value
labels and type spellings, and explicit raw expressions in every lexical and
conditional region. Enum symbol materialization consumes those headers while
the session owns active-branch selection and raw-value evaluation.
The extension index records extended type spellings, inherited conformances,
generic requirements, attributes, and modifiers across every conditional
branch. Extension target resolution and conformance merging consume those
headers while the session owns branch selection and member materialization.
Nonmatching generic-constraint selection remains outside the implemented
claim. The type-alias index records alias names, full and normalized target
spellings, generic parameters and requirements, attributes, modifiers, and
nominal-target classification across every lexical and conditional region.
Top-level, member, and local alias binding consumes those headers while the
session owns active-branch selection and mutable symbol lookup. Remaining
member semantics and compiler-only signature parsing, call-target resolution
beyond the normalized callee shape, and the compiler-preflight fingerprint
remain target work.

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

Current implementation stage (2026-07-17): every `runAsync(source:)` and
`runAsync(program:)` entry constructs the public single-use session above and
executes through it. `makeSession(program:)` plus `runAsync(session:)` exposes
the same path for explicit ownership. Focused tests prove unique IDs, the live
root task's ID, policy/program/heap/runtime binding, foreign-facade rejection,
single-use state, complete runtime draining, and heap/runtime lifetime after
facade release. The session also binds the one build-resolved declaration plan
used by runtime-symbol materialization and top-level execution. Its root task
and evaluation context retain the same explicit `RuntimeEntry`, including the
program's immutable `ParsedProgramMetadata` capability. Host callbacks
and SwiftUI tasks create distinct entry capabilities through that same runtime
mechanism, and all source tasks inherit the object rather than only copying its
numeric ID. The session intentionally remains MainActor-confined and holds a
weak facade reference because mutable symbol collection and evaluation have
not yet moved out of `Interpreter`.

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

Current implementation stage (2026-07-18): `RuntimeHeap` is the explicit
MainActor-confined owner of the global environment, synthesized environment
models, and SwiftUI state cells. The legacy `Interpreter.globals` surface
forwards to that same root. The explicit `runAsync` session binds this heap,
but declaration/evaluator migration, callback-session unification, and runtime
registry isolation remain separate M9 work; no heap object is currently handed
to a physical worker.

Worker-admission stage (2026-07-18): a `RuntimeEntry` can now project a
structurally `Sendable` `RuntimeWorkerCapability`. The projection retains only
entry identity plus immutable `ResolvedProgramPlan`/`ParsedProgramMetadata`
and recursively copies the admitted `RuntimeValue` subset into an immutable
snapshot. It has no heap, program-state, interpreter, environment, box,
instance, closure, symbol, or opaque-host reference. Every current
`RuntimeHeap` stored root is inventoried as MainActor-confined and excluded;
the test inventory is compared with the heap's actual stored-property labels
so a future root requires an explicit policy update. Every `RuntimeValue` case
is handled by one exhaustive transfer switch: scalar and container graphs are
copied, actor instances are actor-confined, ordinary interpreted references
are MainActor-confined, and opaque host values are rejected as non-Sendable.
Nested rejection reports the exact value path and returns no partial
capability. This is a fail-closed data boundary for future pure worker kernels,
not permission to run the evaluator or touch the heap on a physical worker.

Physical-driver stage (2026-07-18): `RuntimePhysicalWorkerDriver` is an
explicit bounded executor for those capabilities. Each active slot owns one
real `Task.detached`; one shared FIFO permit pool enforces the configured limit
across concurrent batches, while each throwing task group preserves input order
on success, forwards structured cancellation into the detached native task,
cancels siblings on failure, and drains every slot before scope exit. Invalid
bounds fail as values. Tests use checked-Sendable atomics: two nonsuspending
spin jobs must enter before release, proving physical overlap, while a third
remains outside a two-worker bound. Cancellation, queued-waiter removal,
sibling failure, empty input, and operation-capture release are separately
pinned.

Source-kernel stage (2026-07-18): cooperative remains the default. Explicit
parallel mode admits only ordinary enqueued `Task.detached` source closures
with no authored signature, arguments, parameters, builder transform, extra
statements, or unmodeled expression. MainActor lowers literals to a constant
snapshot kernel and empty checked capability. The first corpus-demanded scalar
expression, CotEditor's `Task.detached { string.count }`, is admitted only when
`string` resolves to a locally captured source `let` whose runtime value is a
String. MainActor copies it into the checked capability and emits typed
binding-plus-String-count IR. Mutable/global captures and every other shape
retain cooperative evaluation; only copied Sendable values and typed IR cross
to the driver, and MainActor materializes the result.

The second corpus-demanded scalar expression is CotEditor's
`Task.detached { selectedStrings.map(\.count).reduce(0, +) }`, where the local
immutable value is `[Substring]`. Admission requires that exact zero-seed
key-path/reduction spelling and a directly owned immutable array whose runtime
elements all copy as String snapshots. MainActor recursively copies the array
and emits one typed String-count-sum node. Mutable bindings, globals, alternate
seeds, closure-map spellings, and non-String elements remain cooperative.

The first corpus-demanded suspending command is
swift-composable-architecture's
`Task.detached(priority: .background) { await Task.yield() }`. Admission
requires one signature-free zero-argument `await Task.yield()` expression.
That shape is necessary but not sufficient: lowering also resolves the `Task`
base through the originating closure's lexical environment and requires the
exact registered core-Task host-function identity. A source value or type that
shadows `Task` therefore stays on the cooperative evaluator.
MainActor emits typed `taskYield` IR and an empty checked capability; the real
detached worker invokes native `Task.yield()` and returns a `Void` snapshot.
Authored signatures, multiple statements, captures, and alternate calls remain
cooperative before worker submission.

The third corpus-demanded scalar expression is CotEditor's
`Task.detached { string.distance(from: string.startIndex, to: location) }`.
Admission requires directly owned immutable String and String.Index captures,
the same String reference for the receiver and `startIndex`, and the exact
label/expression shape. MainActor copies both typed values and emits typed
start-index/distance IR. Mutable or global bindings, alternate `from:`
expressions, authored signatures, and all other forms remain cooperative. A
finite source-kernel execution is isolated from logical source-task
cancellation so a non-checking cancelled body still publishes its value; the
ordinary physical-driver API retains infrastructure-cancellation forwarding.

The second corpus-demanded suspending command is Signal-iOS's
`Task.detached { try await Task.sleep(for: slowLinking ? .seconds(3) :
.milliseconds(500)) }`, where `slowLinking` is an immutable Bool parameter.
Admission requires one exact `try await Task.sleep(for:)` expression, a
directly owned immutable Bool capture, and nonnegative integer-literal
`.seconds`/`.milliseconds` branches. MainActor copies the Bool and emits typed
conditional-Duration plus sleep IR. A cancellation relay acquires worker
capacity independently, attaches the logical request to the actual detached
source worker, and remembers a request that wins the attachment race. Thus a
pre-cancelled task still enters and its throwing sleep observes cancellation,
while unsupported units, overloads, mutable/global conditions, and richer
bodies remain cooperative. The same core-Task identity proof used by the yield
kernel prevents a shadowed source `Task.sleep(for:)` method from entering this
physical path.

Scoped sanitizer stage (2026-07-18): `run-concurrency-tsan.sh` owns a separate
sanitized build cache. Its native checked-Atomic overlap executable performs
twenty bounded repetitions in one process, and its prebuilt test bundle runs
the driver plus source-kernel suites in parallel. The runner loads the TSan
runtime before SwiftPM's bundle helper and rejects both a nonzero exit and the
otherwise-zero-exit "interceptors not installed" diagnostic. A twenty-pair
same-source test requires cooperative and parallel modes to return the same
`atlas:42`, with zero versus two physical receipts and empty task registries.
A second twenty-pair test requires exact `5:9` and the same zero/two receipt
split for the immutable-String-count kernel. A third requires exact `6:10` and
the same receipt split for the immutable-Substring-array count reduction. A
fourth requires exact `yielded:2`, empty registries, and the same receipt split
for the typed yield command. A fifth requires exact `2:5|2:true`, empty
registries, and zero/three receipts for the typed String/String.Index distance
kernel including immediate cooperative cancellation. A sixth requires exact
`slow:fast|cancelled:true`: parallel mode records two successful executions
from three submissions, while cooperative mode records neither, and the
pre-cancelled throwing sleep must enter before producing `CancellationError`.
Two direct fallback regressions additionally require lexically shadowed
`Task.yield()` and `Task.sleep(for:)` calls to return their source values with
zero physical submissions or executions. All thirty-five
driver/source-kernel tests run under TSan. This receipt covers only the
checked driver, constant snapshot kernel, typed immutable-String-count kernel,
typed immutable-Substring-array reduction, exact no-capture `Task.yield`, and
typed immutable String/String.Index-distance and conditional-Duration sleep
kernels; future value shapes, richer suspending work, actor, host, or
heap-capable kernels require their own expanded differential and sanitizer
evidence.

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

The current slice implements a bounded runtime-owned record and opaque source
carrier for `withCheckedContinuation` with explicit or caller-defaulted `nil`,
`MainActor.shared`, or source-actor isolation plus `resume(returning:)`; its
explicit-`nil` Void slice also maps zero-argument `resume()` to the same resumed
terminal transition, and nonthrowing `Result<T, Never>` success delegates to
that same returning transition. Compiler preflight owns Swift's static
overload/member constraints, while the runtime implements the already-selected
valid calls.
`withCheckedThrowingContinuation` shares that record for explicit `nil`,
MainActor, and source-actor isolation plus caller-defaulted
nonisolated/MainActor/source-actor isolation, `resume(returning:)`, and
`resume(throwing:)`; its MainActor and source-actor error paths have exact
body-isolation and caller-restoration evidence, the caller-defaulted source
actor path proves mailbox release/reentry/reacquisition, and its
concrete-error plus existential `Result<T, any Error>` `resume(with:)`
overloads delegate success/failure to those same terminal transitions. A
distinct failed terminal outcome retains
the copied source error and projects it only after the runtime has closed the
continuation ownership edges. A contextual-executor override uses the ordinary
suspending invocation kernel: it acquires a selected source actor for the
synchronous body, or switches logical identity for MainActor, then restores a
different caller before waiting. A delayed resume therefore records
`.waitingForContinuation(id)` with the caller's required logical executor
rather than the temporary body executor. When the caller already owns the
selected source actor, the canonical suspension lease releases the complete
depth-counted segment, permits another actor message to enter, and reacquires
the actor before source evaluation continues. Resume closes both the registry
entry and task-owner edge before returning the copied value or throwing the
original source value through `InterpretedThrow`. Immediate resume uses the
same exactly-once transition without a synthetic suspension. Infrastructure
cancellation may abort the internal native waiter so session teardown cannot
hang; ordinary source cancellation does not resolve the continuation. Omitted
`#isolation` is materialized once from caller lexical isolation before executor
selection. The nonthrowing and throwing explicit plus caller-defaulted
source-actor shapes have exact native parity. Both checked forms also have
process-isolated native/interpreted parity for the fatal double-resume
diagnostic; fatal runtime invariants bypass source `do`/`catch`. Final release
of an unresumed checked token instead emits a successful-process runtime
warning through a diagnostic sink that does not retain the session, leaves the
waiting task parked, and never enters source `catch`; infrastructure abort
invalidates the token before host cleanup. After successful resume and owner
completion, an escaped token retains neither the task-local owner graph nor the
runtime/session/interpreter; its later release is inert. Both generated unsafe
entry points now fail closed through the shared
`unsupportedUnsafeContinuation` intrinsic before invoking their bodies or
creating ownership. The diagnostic preserves the selected source function
name; unsafe continuation ownership is not silently approximated by the checked
registry.

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
invoke termination again when it dies. Source checked continuations use the
separate runtime-owned continuation record described in Section 6.17; stream
producer handles are not evidence for their resume or lifetime rules.

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
closure synchronously, releases its root after the root's dynamic state is
clean, and reports an uncaught callback error through bridge diagnostics. The
entry itself remains owned by any source tasks that outlive the callback.
Buttons, generated actions, gestures, bindings, lifecycle event modifiers,
and Objective-C completions share this path. Queued GCD deliveries retain
their own deterministic/wall-clock bridge policy and require a separate
follow-up before they can adopt the same runtime entry without changing test
or delivery semantics.
Async `.task`, `.task(id:)`, and `.refreshable` closures instead require the
separate `swiftUITask` lifecycle contract above; they must not be implemented
by extending the synchronous adapter.

TaskObservatory verification (2026-07-18) exercises this boundary through the
real hosted control rather than a direct model call. A fixed-size
`NSHostingView` renders the unchanged project with `ViewRegistry`; an AppKit
mouse event presses its actual **Run experiment** SwiftUI `Button`. The source
callback creates canonical runtime tasks, both async-let children enter and
join before Atlas completes, the cancellation-handler and task-group branches
enter, two waiters consume the shared task result, all three workers finish,
and every task/group/scope owner drains. A separate same-source
retained-callback oracle
composes async let, two shared-result waiters, a four-child group, and
cancellation-handler observation. Strict Apple Swift 6.3.3 and interpreted
execution returned exact
`started,async:5|shared:10:10|cancelled` in twenty bounded repetitions; every
native shard reported SHA-256
`c4c9895155080edb1fd1dcf9b0e887a6c057553fd836addef8bc94ff20a885f8`.
This is an already-GREEN characterization. It asserts callback immediacy,
values, structured completion, cancellation observation, and cleanup, but no
unrelated scheduler order or physical thread. The displayed `Worker pool` is
the logical executor projection of `@concurrent nonisolated`; general physical
tree-walk evaluation remains outside this claim.

The current synchronous rendering compatibility path remains separate. A view
task must use the canonical concurrency runtime even when it was created by a
synchronous render pass.

Current overlap policy (2026-07-17): each external invocation receives a
distinct `RuntimeEntry`, while tasks created by that invocation retain and
inherit it. Multiple entries may be live cooperatively on one facade and share
its heap because every interpreter instruction and heap access is still
MainActor-confined. Existing completion-policy evidence proves one program
entry does not drain another entry's task, while the callback probe proves a
later callback can resume an earlier entry. Entries must not execute
heap-touching evaluator work on physical workers. The later worker-safe
classification must preserve this overlap rather than rejecting it wholesale.

## 7. Ownership and isolation matrix

| Component | Mutable? | Initial owner | Parallel target |
|---|---:|---|---|
| `ParsedProgram` | No | Session | Immutable/Sendable |
| Declaration metadata | No after build | Program | Immutable/Sendable |
| `InterpreterSession` | Yes | Cooperative runtime | Actor or explicit synchronization |
| `RuntimeEntry` | Weak owner edge only | External invocation/source-task graph | Immutable identity; heap capability follows heap policy |
| `RuntimeHeap` | Yes | Interpreter session/facade | Executor-confined or synchronized by edge class |
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
- `runtime-warning`: each isolated process exits zero and contains every
  authored warning fragment; nonzero exit, missing fragments, and timeout are
  failures;
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
- the M6 demand slice is closed while the broad milestone remains partial.
  Finite success, typed source
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
  also have exact parity. The checked-continuation value slices now own
  explicit or caller-defaulted `nil`, `MainActor.shared`, and source-actor
  isolation, detached-producer resume, contextual actor body execution,
  caller-executor restoration, mailbox release/reentry/reacquisition, and
  teardown cleanup. The checked throwing form
  additionally owns explicit-`nil` plus caller-defaulted isolation,
  value resume, exact source-error projection through `resume(throwing:)`,
  exact MainActor and source-actor body/caller restoration on delayed source
  error, mailbox release/reentry/reacquisition for a caller-defaulted source
  actor, and
  concrete-error plus existential-error Result success/failure through
  `resume(with:)`.
  The nonthrowing explicit-`nil` Void slice owns zero-argument `resume()`
  and `Result<T, Never>` success through the same terminal transition and
  cleanup path.
  Both checked forms diagnose double resume as a fatal runtime invariant even
  inside source `do`/`catch`. They also diagnose final-token abandonment as a
  successful-process warning while leaving the owner suspended; host teardown
  is explicit and occurs after observation. Resumed-token lifetime is covered:
  a retained escaped token does not own the completed task graph or runtime and
  is inert on release. Both unsafe entry points are generated into one shared
  named fail-closed intrinsic before source-body invocation and runtime
  ownership;
  complete custom-executor scheduling is not required for those slices;
- M8 view-owned async lifecycle has closed its demand-scoped cycle. Its covered prerequisites
  are M2 driver release, M5 logical executor identity, and M7 native preflight.
  Its first gap-closure slice generates the async modifier surface and covers
  `.task` runtime entry, disappearance cancellation, `.task(id:)` replacement,
  same-id task preservation, `.refreshable` completion lifetime, logical
  MainActor execution, and cleanup through actual `NSHostingView` lifecycle.
  Thirty-two causally sequenced teardown cycles prove distinct runtime
  sessions, cancellation before the next appearance, complete registry drain,
  weak task-graph release, and final interpreter/runtime release; and
- M9 is now the active cycle because its requirement-level M4 Sendable/escape,
  M5 executor, M7 native-preflight, and M8 lifecycle prerequisites are
  covered. Six narrow snapshot-kernel paths and five demand-cited physical
  source-call-wrapper paths now exist behind a validated explicit mode. The
  snapshot kernels are a signature-free, argument-free, single-literal `Task.detached`
  closure; the CotEditor-cited `string.count` spelling when `string` is a
  locally captured immutable String; and CotEditor's
  `selectedStrings.map(\.count).reduce(0, +)` spelling over a local immutable
  `[Substring]`; swift-composable-architecture's exact no-capture
  `Task.detached(priority: .background) { await Task.yield() }` command; and
  CotEditor's exact immutable String/String.Index `distance(from:to:)`
  spelling; plus Signal-iOS's conditional `Task.sleep(for:)` over an immutable
  Bool and literal seconds/milliseconds. All six lower to checked snapshot
  kernels and have paired cooperative/parallel plus TSan evidence. The five
  source-call families launch only a checked wrapper command before confined
  re-entry: MainActor, `@concurrent`, default source actor, actor-declared
  custom global actor, and inherited detached-caller isolation. Physical
  source-call bodies are signature-free except for Provenance's exact
  capture-only `{ [self] in await self.registerDefaults() }` spelling; that
  strong-capture proof cannot fall through to any snapshot kernel. Physical
  weak-reference transfer remains forbidden. Repeated `[weak self]` optional
  async member calls instead use one cooperative suspension-aware path that
  evaluates the receiver once, skips nil arguments, and flattens the result.
  Demand-cited optional async closures use the analogous cooperative callable
  path: nil returns before argument collection, while a present closure enters
  ordinary suspension-aware invocation and flattens its result.
  A causally gated weak-lifetime oracle additionally proves that task-record
  ownership of either cooperative path does not strengthen a weak capture
  while its detached task is suspended. This does not admit a weak reference
  to a physical worker.
  Physical Task-yield/sleep admission combines immutable callee shape with
  the stable registered core-Task identity; lexically shadowed source calls
  remain cooperative. The general
  evaluator, mutable/global captures, heap, source closures, environments,
  actors, and host gateways remain MainActor-confined.

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

Demand refresh (2026-07-18): the checked-out OSS expansion now contains 94
project trees. A direct source census finds 941 `Task.detached` occurrences in
502 Swift files across 52 of those trees. This supersedes the older
`Task.detached` row for within-M9 prioritization; the other rows retain their
2026-07-16 measurement until the complete construct census is refreshed.

Scheduling rule: work is selected from the `executionPlan` active cycle in
its listed `requirementRefs` order, not from interface enumeration order.
Surface work on constructs with zero measured demand is not schedulable; it
reopens only when a real interpreted program (corpus, FoodTruck, LiveCheck,
TestCheck) fails on a cited declaration. FoodTruck function parity — `.task`
view lifecycle, `@MainActor` model mutation, StoreActor-shaped global actors,
and `for await` over host-bridged async sequences — outranks completeness of
rarely used API families.

**Within-slice depth cap (steering 2026-07-17).** Demand admits a construct
into the active cycle; it also bounds how deep the cycle drills. Inside an
admitted construct, a spelling, buffering policy, or edge family receives the
full characterize+support treatment only with a demand citation: a named
corpus project, a FoodTruck source location, or a LiveCheck/TestCheck failure
class that exercises it. The uncited remainder fails closed with a named
diagnostic and a single fail-closed parity case — never silent absorption,
and never a speculative exhaustive sweep (buffering-policy matrices,
deprecated aliases, multi-consumer topologies) run ahead of a citation.
Existing coverage is never deleted (the ratchet holds); the cap governs new
work only. A slice's definition of done is "cited portion covered, remainder
fail-closed with a citation path back in" — not exhaustion of the construct's
interface surface.

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
on its own release. The source checked-continuation slices separately own a
bounded runtime record, delayed value resume for explicit or caller-defaulted
`nil`, `MainActor.shared`, and source-actor isolation, contextual actor body
execution, caller-executor restoration, mailbox release/reentry/reacquisition,
and infrastructure-abort cleanup. The throwing
form shares that record for explicit-`nil` value return, caller-defaulted
isolation, exact source-error projection, exact MainActor and source-actor
body/caller restoration on delayed source error, caller-defaulted source-actor
mailbox release/reentry/reacquisition,
and concrete-error plus existential-error Result success/failure through
`resume(with:)`;
the nonthrowing explicit-`nil` Void slice maps zero-argument
`resume()` and `Result<T, Never>` success to that same successful terminal
path. Both checked forms now have process-isolated parity for Swift's fatal
double-resume invariant, including its escape from source `do`/`catch`, and for
Swift's nonfatal final-token abandonment warning. The latter leaves the source
task suspended and uses explicit infrastructure cancellation only after the
warning observation. Escaped resumed-token lifetime now has direct causal
native/interpreter evidence: a retained token does not keep the completed
task-local owner graph, runtime, session, or interpreter alive and is inert on
release.

Closure directive (steering 2026-07-17): the demand-cited portion of this
slice is covered, including the escaped resumed-token lifetime tail.
Unsafe-continuation variants fall under the section 14
within-slice depth cap — with no demand citation on record they land as
fail-closed diagnostics with one parity case each, not as characterize+support
series. With those terminal items resolved the cycle closes, and the
executionPlan activates the M8 `swiftui-lifecycle-demand-cycle`: `.task` is
the highest-demand unserved construct on the board (30 corpus projects, 4
FoodTruck call sites) and directly serves the FoodTruck R4 mission. Update
`milestone-acceptance.json`'s executionPlan accordingly in the closing commit.

Closure receipt (2026-07-17): both native-positive unsafe entry points now
share the generated fail-closed intrinsic and have separate focused ownership
proof. The execution plan therefore activates M8; M6 remains partial only for
explicit demand-deferred divergences outside this bounded cycle.

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

Implemented demand-scoped cycle (2026-07-17): BridgeGen maps the SDK's three
`() async -> Void` modifier declarations to one generated async-action tag;
there is no handwritten `.task` name branch. The tag invokes a documented
SwiftUI-magic adapter that creates a fresh parentless `.swiftUITask` session
and maps native lifecycle cancellation into cooperative source cancellation.
Strict same-source `NSHostingView` fixtures cover task-group entry, removal,
id replacement, same-id preservation, refresh trigger/completion, and 32
sequential teardown cycles in twenty stable native runs and matching
interpreter runs. Weak references prove release of every task record, handle,
native driver, evaluation context, and task-local store after each cancellation
and release of the interpreter/runtime after the host graph is removed. The
requirement is covered; M8 remains provisional only because broad M5/M7 remain
partial, and the execution plan advances to active M9.

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

Implemented prerequisite slices (2026-07-17): parsing, operator folding, and
target-neutral top-level declaration discovery now produce a reusable immutable
`ParsedProgram`. Its SwiftSyntax tree, location converter, and all-branch
declaration index cross strict-concurrency detached-task boundaries as
`Sendable`; each session resolves one build-specific plan, and fresh
interpreters can execute one parsed program independently while keeping
globals, mutable symbols, and runtime records separate. Legacy `run(source:)`
still maps parse failures to the same located `RuntimeError`.
Each `Interpreter` also owns one explicit, MainActor-confined `RuntimeHeap`
that roots the actual global environment, synthesized environment models, and
SwiftUI state cells; focused tests prove identity, cross-interpreter isolation,
and facade-owned lifetime. Every `runAsync` program entry now executes through
a real single-use `InterpreterSession` binding that program, heap, cooperative
runtime, runtime entry, lazy-global mode, and completion policy; focused tests
prove live-ID propagation, ownership validation, single-use state, draining,
and facade-independent heap/runtime lifetime. Program roots, host callbacks,
SwiftUI tasks, and every source task they create now retain an explicit
`RuntimeEntry`; focused ownership tests prove callback parent/child identity,
distinct callback IDs over one heap, and final release. A causal same-source
probe establishes cooperative overlap against the confined heap in twenty
native/interpreter repetitions. `ParsedProgram` additionally owns one immutable
`ParsedProgramMetadata` capability containing its declaration and all-branch
callable, nominal, property, enum-case, extension, type-alias, and
deinitializer indexes; callable entries now also own names, modifiers, and
type-member placement. The
runtime no longer stores mutable function/initializer metadata caches on the facade.
Sessions and escaped callbacks retain the originating capability through
`RuntimeEntry`, and eight detached readers exercise one snapshot under Swift 6
strict concurrency.
Existing `extractIsolation` parity characterizes the no-semantic-change result
for plain explicitly nonisolated async declarations. The same index now owns
readable getter/setter metadata and subscript parameter/result/isolation facts;
computed/local/global accessors and subscript materialization consume it rather
than rescanning syntax. Controlled async-throwing actor-subscript native parity
remains exact. A real SwiftUI cancellation lifecycle test proves the same
capability reaches `.swiftUITask`; its wait now causally requires both the
source `started` event and the runtime `.waiting` state instead of racing those
two transitions. The composite capability now also owns an all-branch nominal
header index for structs, classes, actors, enums, and protocols; runtime symbol
construction consumes its names, inheritance, attributes, and generic facts.
The existing custom-global-actor fixture remains exact in twenty repetitions.
The composite also owns all-branch variable/property storage headers;
global, member, enum-static, and local materialization consume mutability,
static/lazy/nonisolated/TaskLocal, reference-ownership, tuple, accessor-kind,
and observer facts from that index with a pure foreign-syntax fallback. The
actor-initialization fixture remains exact in twenty repetitions.
The composite additionally owns enum-case headers; enum symbol materialization
uses normalized/backticked names, associated labels/type spellings, and raw
expressions from that index while evaluating raw values inside the session.
The `enum-case-metadata` fixture remains exact in twenty native/interpreter
repetitions.
The composite now also owns all-branch extension headers. Extension target
resolution and retroactive conformance merging consume the indexed extended
type and inherited-type spellings, while generic requirements, attributes,
and modifiers remain available as immutable program facts. The
`extension-metadata` fixture remains exact in twenty native/interpreter
repetitions for the demand-cited matching-constraint subset.
The composite additionally owns all-branch type-alias headers. Alias head
registration and top-level, member, local, and lexical-name binding consume
the indexed source and normalized target spellings. The `typealias-metadata`
fixture remains exact in twenty native/interpreter repetitions for the
selected non-watchOS branch, while target-aware project selection remains M7
evidence.
The composite now also owns all-branch deinitializer headers. Deinitializer
body attachment and isolation-policy resolution consume indexed bodies,
attribute type spellings, and modifier names. The `deinitializer-metadata`
fixture remains exact in twenty native/interpreter repetitions for FoodTruck's
ordinary `@MainActor`-class teardown path.
Callable registration, global binding, closure naming, and lexical capture
discovery now consume indexed function names, modifier names, and
static/class-versus-instance placement. The `callable-placement-metadata`
fixture remains exact in twenty native/interpreter repetitions for the
demand-cited static and instance MainActor routes.
Initializer selection and execution now consume indexed bodies, attributes,
modifiers, failable/Codable classification, and isolation facts through one
shared closure builder. The `initializer-declaration-metadata` fixture has
exact twenty-run parity for inherited MainActor isolation, explicit
nonisolation, failable outcomes, and preservation across an actor hop.
The core target now declares its mutable actor boundaries explicitly instead of
depending on target-wide default isolation. `RuntimeEntry` can project only a
checked-Sendable immutable worker capability and recursively copied value
snapshots; every mutable heap root and opaque runtime value remains excluded.
A bounded physical driver launches real detached workers, shares one FIFO
permit pool across concurrent batches, drains cancellation and failure, and
restores successful output order. Its strict checked-Atomic native probe proves
two nonsuspending jobs physically overlap without claiming a scheduler order.

The first source-kernel stage (2026-07-18) adds a public validated
`RuntimeExecutionMode`; cooperative remains the default and the legacy public
initializer entry points remain available. In explicit parallel mode, an
eligible literal-only detached closure is lowered entirely on MainActor to a
constant snapshot kernel plus an empty checked capability. The native worker
captures only those Sendable values. Its result is materialized on MainActor,
and an execution receipt increments only after the physical job succeeds.
Authored signatures, capture lists, parameters, builders, immediate launch
policies, multiple statements, and every nonliteral expression use the
unchanged cooperative evaluator. No
source closure, syntax node, `RuntimeValue`, environment, heap, host bridge, or
evaluator crosses the worker boundary.

The second source-kernel stage (2026-07-18) is demand-cited by CotEditor's
`EditorCounter.swift:130`. Evaluator boxes now retain source binding mutability
without changing their legacy public construction/definition signatures.
Explicit parallel mode may lower `Task.detached { string.count }` only when the
capture environment directly owns `string`, its source binding is `let`, and
its runtime value is a String. MainActor recursively copies that value into the
checked worker capability and emits a typed snapshot-expression kernel. The
worker performs only the binding read and Swift `String.count`; mutable
bindings, globals, authored signatures, and other expressions stay
cooperative. Same-source mode parity and the scoped TSan board cover this new
kernel alongside the literal kernel.

The third source-kernel stage (2026-07-18) is demand-cited by CotEditor's
`EditorCounter.swift:176`. Explicit parallel mode may lower
`Task.detached { selectedStrings.map(\.count).reduce(0, +) }` only when the
capture environment directly owns `selectedStrings`, its source binding is
immutable, and every `[Substring]` runtime element is representable as a copied
String snapshot. MainActor emits typed String-count-sum IR; the worker performs
only grapheme counts and checked integer addition. Mutable/global bindings,
alternate seeds, authored signatures, and alternate map/reduce spellings stay
cooperative. Same-source parity and the scoped TSan board cover this kernel.

The fourth source-kernel stage (2026-07-18) is demand-cited by
swift-composable-architecture's `TestStore.swift:1856`. Explicit parallel mode
may lower only a signature-free, argument-free, single-expression detached
closure containing the exact zero-argument `await Task.yield()` call. MainActor
emits typed `taskYield` IR with an empty checked capability; the physical
operation invokes native `Task.yield()` asynchronously and publishes a `Void`
snapshot. Authored async signatures, multiple statements, captures, and
alternate calls remain cooperative. Same-source parity and the expanded TSan
board cover this first suspending kernel without claiming scheduler order or
thread identity.

The fifth source-kernel stage (2026-07-18) is demand-cited by CotEditor's
`EditorCounter.swift:191`. Explicit parallel mode may lower only the exact
`string.distance(from: string.startIndex, to: location)` expression when both
the String and String.Index bindings are directly owned immutable captures.
MainActor copies those typed values and emits start-index/distance IR; the
worker performs only Swift's grapheme-aware distance. Finite source-kernel
execution does not inherit logical source cancellation, matching Swift's rule
that cancellation is cooperative, while direct driver callers retain
infrastructure cancellation. Mutable/global bindings, alternate `from:`
expressions, authored signatures, and other forms remain cooperative.
Same-source parity and the expanded TSan board cover the exact kernel and an
immediately cancelled non-checking task without claiming general cancellation
checks, scheduler order, or thread identity.

The sixth source-kernel stage (2026-07-18) is demand-cited by Signal-iOS's
`BackupRestoreProgressModal.swift:541`. Explicit parallel mode may lower only
an exact one-expression `try await Task.sleep(for:)` body whose ternary
condition is a directly owned immutable Bool and whose branches are
nonnegative integer-literal `.seconds` or `.milliseconds` durations. MainActor
copies only the Bool and emits typed conditional-Duration plus sleep IR.
Because throwing sleep observes cancellation, a Sendable actor relay separates
uncancelled permit acquisition from the real source worker and forwards or
remembers cancellation across their attachment race. This preserves Swift's
pre-cancelled-body entry and `CancellationError` behavior without changing the
non-checking finite-kernel rule. Mutable/global conditions, other units,
alternate overloads, authored signatures, and richer bodies remain
cooperative. Twenty exact native/parallel repetitions and the expanded TSan
board cover two successful sleeps plus one causally pre-cancelled sleep without
asserting elapsed time, worker identity, or scheduler order.

The fortieth prerequisite returns to the immutable call boundary before
admitting source-defined calls to physical lowering. The current 94 checked-out
OSS project trees contain 941 `Task.detached` occurrences; after the six
admitted kernels, the recurring shapes are predominantly source, actor, and
host calls rather than another safe scalar primitive. FoodTruck supplies the
exact `Task.detached { await self.updatesLoop() }` spelling in
`StoreMessagesManager.swift:33-35`. A same-named global function in the probe
makes target selection observable: Apple Swift 6.3.3 and the interpreter both
returned exact `target:member` in twenty bounded runs, and all four native
five-run shards reported SHA-256
`88ddf30fbc689070f9013a46d59717a74b18015dd09b8c8b2bd46316053566ff`.
This is an already-GREEN behavioral characterization, not an invented runtime
RED and not a physical-execution claim.

The architectural RED was compile-time: call-site metadata owned argument
shape but no immutable callee classification. Each call now retains its
original callee expression plus a normalized direct-reference,
explicit-member, implicit-member, typed-array, typed-dictionary, or other
shape and source name where one exists. Synchronous and suspending dispatch
consume that same fact, and detached readers prove the composite metadata
remains `Sendable`. Overload choice, receiver value lookup, source declaration
identity, actor hopping, and host routing remain session-owned. In particular,
this prerequisite does not treat a member name as an API identity, does not
move `updatesLoop()` to a worker, and does not expose `Box`, `Environment`,
`Instance`, or the evaluator across the physical boundary.
The canonical focused iteration completed 143 call/metadata/async/host tests
in six suites, all forty-three methodology checks plus the three separately
isolated gate-contract checks, and all twenty parity repetitions on four
workers in two seconds.

The forty-first prerequisite closes the first semantic call-target hole in
physical admission. Raw syntax previously treated any zero-argument
`await Task.yield()` spelling as the standard-library intrinsic. A same-source
probe forms a real detached-operation factory before introducing a local value
named `Task`; native Swift therefore launches a detached operation but invokes
the local async `yield()` method and returns exact `source`. Apple Swift 6.3.3
returned that value in twenty strict Swift 6 runs, and every five-run native
shard reported SHA-256
`5f56add95e0689069a663ad8f90d7ec54eb7305fc06e321ef8ca348d55017328`.

The deterministic interpreter RED was specific to explicit parallel mode:
cooperative evaluation returned `source`, while worker admission returned
`Void` and recorded one physical execution. Core builtins now carry stable
object-identity registrations. Yield and conditional-sleep lowering combine
the immutable explicit-member call-site shape with lookup through the
originating closure's lexical environment, and require that exact registered
core-Task value. The shadowed yield and sleep regressions now return their
source values with zero submissions/executions, while the positive builtin
yield/sleep cases still record physical receipts. No seventh worker kernel is
introduced and no name alone is treated as an API identity. The scoped TSan
board passed twenty native overlap iterations plus all thirty-five
driver/source-kernel tests on four workers in 53 seconds. The canonical
focused iteration completed 64 runtime/metadata/worker tests in three suites,
all forty-three methodology checks plus three isolated gate-contract checks,
and all twenty parity repetitions on four workers in one second.

The forty-second prerequisite closes the equivalent declaration-identity hole
for the existing `String.count` kernel. A same-module
`extension String { var count: Int { 41 } }` shadows the imported property,
including inside `Task.detached`. Apple Swift 6.3.3 returned exact `41` in
twenty complete-strict Swift 6 runs; every native five-run shard reported
SHA-256
`e195c78d2738596cc170bb3277a29bf2f181174109dcad6afec0ab1a95b0033a`.
Before the fix, both interpreter modes selected the native grapheme count and
returned `5`; parallel mode additionally recorded one physical execution.

Ordinary member evaluation now considers a source extension of the concrete
core `String` before its imported native members. Physical admission asks the
originating closure's `RuntimeProgramState` for a typed property-target
identity and admits only `.standardLibrary(.stringCount)`; a visible source
computed-property declaration is represented by its `SyntaxIdentifier`, and
missing state fails closed. A two-run regression proves a retained function
uses its origin program's target, while the positive imported-property probe
still takes the physical path. No source declaration or mutable state crosses
the worker boundary, and no seventh kernel is introduced. The scoped TSan
board passed twenty native overlap iterations plus all thirty-six
driver/source-kernel tests on four workers in 55 seconds. The canonical
focused iteration completed 65 runtime/metadata/worker tests in three suites,
all forty-three methodology checks plus three isolated gate-contract checks,
and all twenty parity repetitions on four workers in one second.

The forty-third prerequisite closes the method-target hole for the existing
CotEditor `String.distance(from:to:)` kernel. A same-module extension declares
that exact method and returns `77`; Apple Swift 6.3.3 selected it inside
`Task.detached` in twenty complete-strict Swift 6 runs. Every native five-run
shard reported SHA-256
`0e8f6fc06b0a6860d392095f867a5b94dc032ed589e0a43d0ce9b30924258f53`.
The deterministic RED left cooperative evaluation correct at `77`, while
parallel admission executed the stdlib kernel, returned `2`, and recorded one
physical submission/execution.

Physical admission now asks the originating `RuntimeProgramState` for a typed
standard-library method proof. Exact overload resolution remains session-owned
and incomplete, so any same-base source-extension overload makes the proof
unresolved and lowering fails closed; labels alone cannot prove identity in
the presence of defaults, generics, and parameter types. The retained two-run
regression returns `77` with zero receipts, while the positive stdlib distance
probe still takes the physical path. No source syntax, overload symbol, or
mutable state crosses the worker boundary, and no seventh kernel is introduced.
The scoped TSan board passed twenty native overlap iterations plus all
thirty-seven driver/source-kernel tests on four workers in 52 seconds. The
canonical focused iteration completed 66 runtime/metadata/worker tests in
three suites, all forty-three methodology checks plus three isolated
gate-contract checks, and all twenty parity repetitions on four workers in two
seconds.

The forty-fourth prerequisite applies the same boundary to the compound
CotEditor `selectedStrings.map(\.count).reduce(0, +)` kernel. A more-specific
same-module `Array.map` overload for `Element == Substring` returns `[41]`;
Apple Swift 6.3.3 selected it inside `Task.detached` and produced exact `41` in
twenty complete-strict Swift 6 runs. Every native five-run shard reported
SHA-256
`06012cab1f7bd007fb1ad3ff15d7822d89b450f3ea30814bf7d8f27b8d2687bb`.
Before the fix, both interpreter modes ignored the source overload and returned
the stdlib result `3`; parallel mode additionally recorded one physical
submission/execution.

Core `Array` values now dispatch source extensions before imported native
members. The count-reduction lowerer also requires the origin program's typed
`.arrayMap` proof; every same-base source overload keeps the expression
cooperative until exact overload resolution is available. The retained two-run
regression returns `41` with zero receipts, while the positive stdlib reduction
retains its physical path. This does not claim the `reduce` target or element
`count` key-path target; those remain separate fail-closed prerequisites. The
scoped TSan board passed twenty native overlap iterations plus all thirty-eight
driver/source-kernel tests on four workers in 25 seconds. The canonical focused
iteration completed 67 runtime/metadata/worker tests in three suites, all
forty-three methodology checks plus three isolated gate-contract checks, and
all twenty parity repetitions on four workers in one second.

The forty-fifth prerequisite closes the next target in that compound kernel.
A more-specific same-module `Array.reduce` overload for `Element == Int`
returns `73`; Apple Swift 6.3.3 selected it after `map(\.count)` inside
`Task.detached` in twenty complete-strict Swift 6 runs. Every native five-run
shard reported SHA-256
`510c4b8fd1343251f41b2cfbed0f4b84e7517a95b4603e64a96e98284898f67e`.
Before the fix, cooperative evaluation returned `73`, while parallel admission
executed the stdlib reduction, returned `3`, and recorded one physical
submission/execution.

The count-reduction lowerer now requires both typed `.arrayMap` and
`.arrayReduce` proofs from the originating `RuntimeProgramState`. Any same-base
source overload keeps the whole expression cooperative; the retained two-run
regression returns `73` with zero receipts, while the positive stdlib reduction
still executes physically. This adds no kernel and leaves only the element
`count` key-path target unresolved inside this compound expression. The scoped
TSan board passed twenty native overlap iterations plus all thirty-nine
driver/source-kernel tests on four workers in 35 seconds. The canonical focused
iteration completed 68 runtime/metadata/worker tests in three suites, all
forty-three methodology checks plus three isolated gate-contract checks, and
all twenty parity repetitions on four workers in one second.

The forty-sixth prerequisite closes the final target inside the compound
count-reduction kernel. A same-module `Substring.count` computed property
returns `89`; Apple Swift 6.3.3 selected it through the context-inferred
`\.count` key path over an explicitly typed `[Substring]`, while the same key
path over `[String]` still selected `String.count`. Twenty complete-strict
Swift 6 runs returned exact `178:3`; every native five-run shard reported
SHA-256
`6c177a2ff65fa47eaf04034c87bd3446d3047a1267fb98e302d5634fb93cb2a5`.
Before the fix, both interpreter modes returned `3` for the Substring branch;
parallel mode also recorded one physical submission/execution.

`RuntimeValue` intentionally stores both String and Substring values as String
snapshots, so payload shape cannot select this declaration. The ordinary
Array/key-path path now carries the source binding's retained static element
type into root-property dispatch. Physical admission independently requires
that same static type to be `Substring` and asks the closure's originating
`RuntimeProgramState` for a typed `.substringCount` target identity. A source
extension therefore executes on the confined evaluator; an untyped or
different element type fails closed. The retained two-run regression returns
exact `178` and `3` with zero receipts, while the positive stdlib Substring
reduction retains its physical path. This adds no kernel and completes the
map, element-property, and reduce target chain for this exact compound
expression. The scoped TSan board passed twenty native overlap iterations plus
all forty driver/source-kernel tests on four workers in 20 seconds. The
canonical focused iteration completed 69 runtime/metadata/worker tests in
three suites, all forty-three methodology checks plus three isolated
gate-contract checks, and all twenty parity repetitions on four workers in two
seconds.

The forty-seventh prerequisite establishes the first exact source-function
target that can be handed to later worker/actor-relay design. FoodTruck's
argument-free `await self.updatesLoop()` remains the demand citation. Apple
Swift 6.3.3 and the interpreter returned exact `target:member` in twenty
bounded same-source runs; all native five-run shards retained SHA-256
`88ddf30fbc689070f9013a46d59717a74b18015dd09b8c8b2bd46316053566ff`.
This is an already-GREEN behavior characterization with an architectural RED,
not a new physical kernel.

Resolution has two layers. Immutable parsed call-site metadata still owns only
callee/argument shape. On MainActor, runtime receiver lookup filters an own
reference-type method set and publishes a target only when exactly one
declaration matches the call shape and no property collision exists. The
selected closure carries an executor-neutral descriptor containing its origin
`ResolvedProgramPlan`, declaration `SyntaxIdentifier`, native function
spelling, lexical placement, isolation facts, effects, and return type name.
Same-shape overloads remain unresolved because labels do not prove Swift's
type-level overload choice.

The origin plan is part of target identity. A regression first demonstrated
that a retained instance resolved after a newer facade run was incorrectly
rebound to the newer plan and lost its lexical type. Every source instance now
retains its originating MainActor-confined `RuntimeProgramState`, value copies
preserve that capability, and method closure formation accepts the explicit
receiver origin. The descriptor alone is Sendable and readable by a detached
native task; the instance, state, closure, environment, symbols, heap, and
evaluator remain confined. The real argument-free suspending explicit-member
path consumes the resolver, but explicit parallel mode records zero physical
submissions/executions for this source call.

The canonical focused iteration completed 45 ownership/target/worker tests in
four suites, all forty-three methodology checks plus three isolated gate-
contract checks, and all twenty parity repetitions on four workers in one
second. The rebuilt scoped TSan board passed twenty native overlap iterations
and all forty driver/source-kernel tests on four workers in 70 seconds. A
future physical source-call design must use this descriptor in a typed command
that re-enters the owning source executor; it must not send the evaluator or
instance to a worker. Inherited/protocol witnesses, same-shape type overloads,
actor/host target routing, and that re-entry command remain open.

The forty-eighth prerequisite implements that re-entry command for the first
demand-cited subset. In explicit parallel mode, a signature-free detached body
whose only expression is `await self.method()` may be lowered only after the
MainActor resolver publishes one origin-plan-matched own source-class target.
The method must be async, nonthrowing, MainActor-isolated, argument-free, and
Void- or String-returning. Actor targets, inherited/nonisolated isolation,
alternate receivers, same-shape ambiguity, arguments, throwing effects,
foreign origins, and richer result types remain cooperative.

The boundary is split deliberately:

- `RuntimePhysicalSourceCallCommand` is Sendable and contains only the
  `RuntimeSessionID`, `RuntimeTaskID`, exact
  `RuntimeSourceFunctionTargetDescriptor`, and expected result kind;
- `RuntimeTaskRecord` owns the matching confined
  `RuntimeResolvedSourceFunctionCall`, so receiver identity, captured
  environment, source closure, mutable program state, and evaluator never
  enter the command or worker capability;
- a purpose-built MainActor relay validates command/capability/plan identity,
  recovers the task record, reinstalls its `EvaluationTaskContext`, invokes the
  selected closure, and structurally copies the result into
  `RuntimeWorkerValueSnapshot` before returning to the worker.

This preserves logical source cancellation independently from the native
wrapper task. The bounded native probe requests cancellation before yielding
MainActor; the re-entered Void method still starts and records
`Task.isCancelled == true`. A separate regression proves an interpreted trap
crosses the wrapper as a contained runtime-task failure rather than aborting
the host process.

Permit lifetime ends at executor handoff, not method completion. The detached
wrapper acquires a global physical permit for its worker prefix; a one-shot
handoff opens when the MainActor relay begins, releasing that permit while the
source method may remain suspended. With maximum parallelism one, a parked
MainActor call therefore cannot starve a subsequent finite kernel. This is a
semantic requirement for FoodTruck's long-lived `updatesLoop()`, not merely a
throughput optimization.

Apple Swift 6 complete-strict compilation and the interpreter returned exact
`1:true` in twenty bounded runs with four identical five-run digests
`5a14c888baeb47a0a83163bf1680a3fdcc9a508e7b5aa5bf4191aad7390e1d3a`.
The deterministic receipt RED moved from zero to two physical executions. The
canonical focused iteration completed 58 tests in five suites, all 46
methodology/gate checks, and twenty parity repetitions on four workers in two
seconds. The expanded scoped TSan board passed native overlap 20/20 plus all
48 driver/kernel/source-call tests in three suites on four workers in 66
seconds without a race or interceptor diagnostic.

The forty-ninth prerequisite extends the same physical-wrapper/confined-reentry
architecture to TaskObservatory's exact `@concurrent nonisolated` source calls
with labeled scalar arguments. The selected target remains an origin-bound own
source-class method and must be async, nonthrowing, MainActor- or
cooperative-default-executor bound, and Void- or String-returning. Admission is
intentionally limited to explicit nondefaulted, nonvariadic, non-builder,
nonisolated `Int`/`Int64` parameters supplied by integer literals or directly
owned immutable `Int`/`Int64` captures. This is the demand-ordered depth cap;
mutable, expression, noninteger, and opaque arguments remain cooperative.

`RuntimePhysicalSourceCallCommand` now pairs each argument label with a checked
worker-binding ID. `RuntimeWorkerCapability` carries the structurally copied
integer values, and the confined relay requires exact command/capability
cardinality and binding-name agreement before materializing them. It then
reconstructs labeled `CallArguments`, reinstalls the original
`EvaluationTaskContext`, and invokes the already selected source closure. The
command still carries no receiver, source box, `RuntimeValue`, environment,
program state, heap, or evaluator. The physical worker executes only the
detached wrapper and executor handoff; source evaluation remains confined to
the existing runtime executor.

The bounded same-source Swift 6 probe returned exact `7:11|18:none` in twenty
native/interpreted repetitions with four identical native five-run digests
`34d58dd88621c8d3b3208bf3323e40b36c7d84323ee01c44574ee52ebcef4315`;
the receipt RED moved from zero to one physical execution. An integration test
uses the unchanged TaskObservatory sources and maximum parallelism one: all
three detached `@concurrent` wrappers launch physically, the async-let,
cancellation-handler, task-group, and waiter tree reaches its exact terminal
state, and every runtime registry drains. The canonical focused iteration
completed 62 tests in six suites, all 46 methodology/gate checks, and twenty
parity repetitions on four workers in two seconds. The rebuilt scoped TSan
board passed native overlap 20/20 plus all 49 driver/kernel/source-call tests
in three suites on four workers in 87 seconds without a race or interceptor
diagnostic.

The fiftieth prerequisite extends the checked source-call argument schema for
iTorrent's exact MainActor calls with `true` and `false` literals. Every
`RuntimePhysicalSourceCallArgument` now carries a value kind in addition to its
label and binding ID. The lowerer admits integer literals as `.integer`,
Boolean literals as `.boolean`, and directly owned immutable Int/Int64 captures
as `.integer`. It then pairs each kind with the selected declaration's
nondefaulted, nonvariadic, non-builder, nonisolated `Int`, `Int64`, or `Bool`
parameter. Captured Bool remains outside the cited depth cap.

The confined relay validates the command kind against the actual copied
snapshot before materializing any argument. This keeps declaration selection,
worker copying, and re-entry binding mutually consistent even as the scalar
surface grows. The command remains Sendable and contains no receiver, source
box, `RuntimeValue`, environment, program state, heap, or evaluator; only the
detached wrapper and handoff execute physically.

The bounded strict Swift 6 probe sequentially awaited both wrappers and
returned exact `on:off|TF` in twenty native/interpreted repetitions; all four
native five-run shards retained canonical SHA-256
`ec0dfbfcbd3bbeab6dd3c5728b5da0face87e81f2b3be963f6d9d1acfa617bf6`.
The receipt RED moved from zero to two physical executions. The canonical
focused iteration completed 63 tests in six suites, all 46 methodology/gate
checks, and twenty parity repetitions on four workers in two seconds. The
rebuilt scoped TSan board passed native overlap 20/20 plus all 50 driver/kernel/
source-call tests in three suites on four workers in 68 seconds without a race
or interceptor diagnostic.

The fifty-first prerequisite adds the first checked source-actor route for
Session-iOS's exact detached wrapper around a synchronous actor-isolated
method. The origin-bound target descriptor already distinguishes lexical actor
placement and carries the exact runtime actor executor selected while forming
the receiver closure. Physical admission now treats that pair as a separate
route from MainActor and `@concurrent` source-class methods: it requires an
argument-free, synchronous, nonthrowing, Void-returning own method on the exact
receiver actor and its default executor. Zero-argument async methods,
synchronous argument-bearing methods, String-returning actor methods, custom
actor executors, nonisolated methods, and richer effects or results stay
cooperative at this prerequisite.

The checked worker boundary does not widen. The physical wrapper carries the
same Sendable entry/task/descriptor/result command and reaches the confined
relay without transferring an actor, `Instance`, closure, environment, heap,
or evaluator. After reinstating the original `EvaluationTaskContext`, the
relay calls the existing suspending evaluator. Its executor-hop protocol parks
an owned caller actor, queues for the selected mailbox, depth-counts actor
ownership during the synchronous body, releases it on return, and restores the
caller actor before publishing the copied result. Thus actor routing is owned
by the canonical logical runtime rather than inferred from the relay's native
MainActor host.

The same-source probe launches the unretained detached task directly from the
actor initializer, matching Session-iOS. A later actor method yields while
waiting and requires that task to re-enter the same actor to mutate state.
Native and interpreted execution returned exact `actor|R` in twenty bounded
runs; every native five-run shard retained canonical SHA-256
`ee46339758b9bf4f9030cfb7cc9db448e6b2c961004386a9c262fe21f5ce57cc`.
The receipt RED moved from zero to one physical execution, and the runtime
regression also requires empty task and actor registries. This establishes a
physical detached wrapper with actor-mailbox-confined source evaluation, not
general parallel actor-body execution.

The canonical focused board passed 65 tests in six suites, all 46
methodology/gate checks, and twenty parity repetitions on four workers in two
seconds. The rebuilt scoped TSan board passed native overlap 20/20 plus all 51
driver/kernel/source-call tests in three suites on four workers in 25 seconds
without a race or interceptor diagnostic.

The fifty-second prerequisite extends the exact default-actor route for
Planet's async termination callback. The existing source-call argument lowerer
already copies integer literals or directly owned immutable `Int`/`Int64`
captures and preserves labels in a Sendable command. Actor admission now
accepts that capability only when there is exactly one integer argument and
the origin-bound selected method is async, nonthrowing, Void-returning, and
isolated to the exact default receiver actor. This is a route-table extension,
not a new evaluator or actor representation.

After confined re-entry restores the task's `EvaluationTaskContext`, ordinary
suspending invocation acquires the actor mailbox. The async body owns that
lease while recording `start:17`; its `Task.yield` suspension releases the
complete depth-counted segment, and continuation must reacquire it before
recording `done:17`. Thus the physical wrapper composes with the existing actor
reentrancy state machine rather than retaining an executor across suspension.
The command still transfers no actor, receiver, `RuntimeValue`, environment,
heap, or evaluator.

Apple Swift 6.3.3 and interpreted execution returned exact
`start:17|done:17` in twenty bounded runs; all native five-run shards retained
canonical SHA-256
`b2ba89617abb88d104c2131843423923d4bbf7b369d08f05192dd8985b01325a`.
The receipt RED moved from zero to one physical execution. A nondefaulted
Boolean-argument async actor control remains cooperative, as do zero-argument async,
String/multiple/defaulted/mutable/expression arguments, throwing methods, and
custom executors. The focused board passed 66 tests in six suites, all 46
methodology/gate checks, and twenty parity repetitions on four workers in two
seconds. The rebuilt scoped TSan board passed native overlap 20/20 plus all 52
driver/kernel/source-call tests in three suites on four workers in 25 seconds
without a race or interceptor diagnostic.

The fifty-third prerequisite extends that route for Planet's explicitly
supplied defaulted Boolean call. Default expressions remain declaration
metadata on `ClosureValue.Parameter`; they are not evaluated during physical
admission. Admission first requires the call to supply exactly as many
arguments as the selected declaration has parameters, then checks one copied
Boolean literal against one `Bool` parameter that has a default expression.
This admits `method(flag: true)` without admitting `method()`. Required Bool,
defaulted integer, captured Bool, expression, and multiple-argument forms
remain distinct fail-closed capabilities.

The actor route still consumes the same origin-bound method descriptor and
Sendable source-call command. The physical wrapper carries the Boolean
snapshot; the confined relay restores the logical `EvaluationTaskContext` and
materializes ordinary `CallArguments` only after re-entry. Canonical actor
invocation owns the mailbox while recording `start:true`, releases the full
lease at `Task.yield`, and reacquires it before recording `done:true`. No
default expression, actor, receiver, closure, environment, program state,
heap, or evaluator is evaluated or transferred by the worker.

Apple Swift 6.3.3 and interpreted execution returned exact
`start:true|done:true` in twenty bounded runs; all native five-run shards
retained canonical SHA-256
`1b0355375aa6a812ce51840fb7f3c38c1c21320283d5e013d0cd27e5c30e1abe`.
The receipt RED moved from zero to one physical execution. Focused negative
evidence keeps omitted defaults, captured Bool, defaulted integers, and
nondefaulted Boolean parameters cooperative. The focused board passed 67
tests in six suites, all 46 methodology/gate checks, and twenty parity
repetitions on four workers in one second. The rebuilt scoped TSan board
passed native overlap 20/20 plus all 53 driver/kernel/source-call tests in
three suites on four workers in 23 seconds without a race or interceptor
diagnostic.

The fifty-fourth prerequisite adds a two-phase custom-global-actor route.
`RuntimeSourceFunctionTargetDescriptor` deliberately retains lazy global-actor
candidate names: eagerly reading `static shared` while deciding whether to
launch a physical wrapper could run a source initializer before native Swift
would enter the detached body. Admission therefore remains effect-free. It
uses the originating confined symbol table only to prove that exactly one
candidate names a source nominal that is itself an `@globalActor actor`, uses
the default executor, and selects an argument-free async nonthrowing Void
source-class method.

The worker command carries the unchanged declaration descriptor and no actor
identity. After MainActor-confined re-entry restores the logical
`EvaluationTaskContext`, ordinary invocation resolves canonical `static
shared` exactly where cooperative execution would, acquires its mailbox, and
runs the source method. The method observes the same actor before
`Task.yield`; canonical suspension releases that lease so the waiting result
method can progress, then reacquires it before continuation. This preserves
both initialization timing and executor identity without sending an actor or
evaluator capability across the worker boundary.

Apple Swift 6.3.3 and interpreted execution returned exact `same|same` in
twenty bounded runs; all native five-run shards retained canonical SHA-256
`fcb1cc9c933c78c04ad6becc131ea2f7d8ca50a23b090f5336dbcb64c0be6261`.
The receipt RED moved from zero to one physical execution. The canonical
global actor remains retained by source `static shared`; focused evidence
therefore requires one idle actor record rather than falsely requiring zero,
along with no owner, mailbox waiter, or runtime task record. Argument-bearing
or String-returning methods, struct/enum global-actor wrappers, custom
executors, throwing calls, and richer results remain cooperative. The focused
board passed 69 tests in six suites, all 46 methodology/gate checks, and
twenty parity repetitions on four workers in one second. The rebuilt scoped
TSan board passed native overlap 20/20 plus all 55
driver/kernel/source-call tests in three suites on four workers in 20 seconds
without a race or interceptor diagnostic.

The fifty-fifth prerequisite adds the first inherited-isolation source-class
route. iTorrent's `WebServerService` is `@unchecked Sendable` and launches two
one-expression detached wrappers around plain async, nonthrowing,
argument-free, Void-returning own methods. Their declarations name no actor
or `@concurrent` executor, so the target descriptor preserves `.inherited`
instead of collapsing the call into cooperative-default metadata during
selection.

Physical admission is still a pure route-table decision over the already
selected origin-bound descriptor. It accepts `.inherited` only for that exact
async/no-argument/Void family. The worker carries the existing Sendable
entry/task/target/result command and opens the confined-executor handoff; it
does not carry the source instance, closure, environment, runtime value,
program state, heap, actor, or evaluator. After relay re-entry reinstalls the
detached source task's `EvaluationTaskContext`, ordinary invocation inherits
that logical cooperative-default context. Consequently the method sees nil
actor isolation before `Task.yield` and again after continuation, without
fabricating either MainActor or a source actor.

Apple Swift 6.3.3 and interpreted execution returned exact `none|none` in
twenty bounded runs; all native five-run shards retained canonical SHA-256
`dc022b9fd32ef23613a6bf01ee0af601d88cf1f8fce887c8924f7047de1bd4b4`.
The receipt RED moved from zero to one physical execution. Argument-bearing
and String-returning inherited methods plus explicit `nonisolated` methods
remain cooperative with zero receipts. The focused board passed 70 tests in
six suites, all 46 methodology/gate checks, and twenty parity repetitions on
four workers in one second. The rebuilt scoped TSan board passed native
overlap 20/20 plus all 56 driver/kernel/source-call tests in three suites on
four workers in 24 seconds without a race or interceptor diagnostic.

The fifty-sixth prerequisite admits the first authored closure-signature
subset without generalizing worker capture transfer. Provenance's
`DiscSerialExtractorRegistry.registerDefaultsSync()` launches
`Task.detached(priority: .userInitiated) { [self] in await
self.registerDefaults() }`. The source class is `Sendable`; its selected own
method is inherited-isolation, async, nonthrowing, argument-free, and
Void-returning. An ordinary explicit strong self capture does not create an
actor executor, so the method observes nil actor isolation before and after
`Task.yield` just like the previously proven implicit capture.

Closure formation publishes one confined provenance bit only when syntax is
exactly one unmodified `self` capture with no initializer alias, attribute,
parameter clause, effect, return clause, second capture, or trailing comma.
The runtime task record retains that source closure and its strong receiver.
The physical entry guard accepts this bit for the direct-self source-call
attempt, but requires the original signature-free proof before considering
any snapshot kernel. Thus failure to resolve the exact method or executor
route returns to the cooperative evaluator without partially executing a
literal or expression on a worker. The successful worker still carries only
the existing Sendable entry/task/target/result command, and confined re-entry
restores the logical detached task before ordinary invocation.

Apple Swift 6.3.3 and interpreted execution returned exact
`strong:none|none` in twenty bounded runs; every native five-run shard
retained canonical SHA-256
`14c92e632cbf820172e940cbe85fb910e691b2b5a8e7ccd49b1a5f976660df9e`.
The receipt RED moved from zero to one physical execution. `unowned`, aliases,
multiple captures, explicit parameter/effect/return signatures, and non-call
bodies remain cooperative with zero receipts. Weak/optional-self async
dispatch remains outside that physical route. The
focused board passed 71 tests in six suites, all 46 methodology/gate checks,
and twenty parity repetitions on four workers in one second. The rebuilt
scoped TSan board passed native overlap 20/20 plus all 57
driver/kernel/source-call tests in three suites on four workers in 49 seconds
without a race or interceptor diagnostic.

The fifty-seventh prerequisite closes cooperative optional async-member
dispatch before any physical weak-reference design. Repeated corpus source
uses `Task.detached { [weak self] in await self?.method(...) }`. Native Swift
does not strengthen that capture: a present receiver invokes and suspends,
while an absent receiver skips both argument evaluation and the call and
produces nil.

The async explicit-member evaluator now owns that control-flow boundary. It
evaluates the optional-chain base once. `.none` returns before collecting
arguments; `.some` is rebound to a temporary and the rewritten call re-enters
the same suspension-aware declaration selection, executor routing, and
invocation used by a nonoptional receiver only when the payload is a source
class/actor reference. Optional value types keep their existing path until
mutating write-back has its own native oracle. Existing Optional lifting
flattens the result to one level. No weak box, receiver, closure, environment,
runtime value, heap, or evaluator crosses a worker boundary, and the parity case
requires zero physical receipts.

Apple Swift 6.3.3 and interpreted execution returned exact
`alive:none|none|nil` in twenty bounded runs; every native five-run shard
retained canonical SHA-256
`76d6367b231b0e0530517d36cac3c518d1d5eb029e181e53e7ac83722d93b2a7`.
The RED was a synchronous `Task.yield` failure inside the alive receiver; a
fatal nil-side argument trap additionally proves skipped evaluation. Optional
async closure invocation, optional value-type async chains with mutating
write-back, weak-receiver destruction races, and physical weak transfer remain
open. The focused board passed 72 tests in six suites, all 46
methodology/gate checks, and twenty parity repetitions on four workers in two
seconds. The rebuilt scoped TSan board passed native overlap 20/20 plus all 58
driver/kernel/source-call tests in three suites on four workers in 24 seconds
without a race or interceptor diagnostic.

The fifty-eighth prerequisite closes cooperative optional async-callable
dispatch. Aidoku, iTorrent, and Provenance all store optional async closures
and invoke them with `await callback?()`. Native Swift makes the optional
callable a control-flow boundary: a present closure invokes and suspends,
while an absent closure skips arguments and invocation and produces nil.

The suspension-aware call evaluator owns that boundary before argument
collection. It evaluates the callee once, returns nil for `.none`, or unwraps
`.some` and enters ordinary `invokeSuspending`; existing Optional lifting
flattens the result to one level. The source closure, captures, environment,
runtime values, heap, and evaluator stay confined, and the parity case requires
zero physical receipts.

Apple Swift 6.3.3 and interpreted execution returned exact
`live:7:none|none|nil` in twenty bounded runs; every native five-run shard
retained canonical SHA-256
`aeba7d1f8923f7f34fb729387f5cf709d80eefe1cf283d8faff2811c04e40706`.
The RED was a synchronous `Task.yield` failure inside the present closure; a
fatal nil-side argument trap additionally proves skipped evaluation. Optional
value-type async chains with mutating write-back, weak-receiver destruction
races, and physical weak transfer remain open.

The focused board passed 73 tests in six suites, all 46 methodology/gate
checks, and twenty parity repetitions on four workers in six seconds. The
rebuilt scoped TSan board passed native overlap 20/20 plus all 59
driver/kernel/source-call tests in three suites on four workers in 58 seconds
without a race or interceptor diagnostic.

The fifty-ninth prerequisite characterizes weak capture ownership across a
causally controlled suspension. Session's group-notification jobs suspend a
detached `[weak self]` task before their eventual `self?` call. A reentrant
actor gate models that interval without using elapsed time: the task reports
entry, the parent clears the final strong receiver, and only then can the task
resume.

Apple Swift 6.3.3 and the unchanged interpreter returned exact `released` in
twenty bounded runs; every native five-run shard retained canonical SHA-256
`c5e92e2453b9fcfd589dc5d3b917f8708b27239decb0a58ca175b11b85c27b6e`.
The interpreter recorded zero physical receipts and complete task/actor
cleanup, so this is characterization rather than a runtime gap closure.

The ownership boundary is explicit: `RuntimeTaskRecord` owns the source
closure, the closure owns a weak capture box, and that box does not own the
source instance. General physical weak-reference transfer remains forbidden;
optional value-type async chains with mutating write-back remain open.

The focused board passed 74 tests in six suites, all 46 methodology/gate
checks, and twenty parity repetitions on four workers in six seconds. The
rebuilt scoped TSan board passed native overlap 20/20 plus all 60
driver/kernel/source-call tests in three suites on four workers in 21 seconds
without a race or interceptor diagnostic.

The sixtieth prerequisite admits Provenance's exact one-expression
`Task.detached(priority: .background) { [weak self] in await
self?.processQueue() }` wrapper without transferring a weak reference. The
selected own source-class method is inherited-isolation, async, nonthrowing,
argument-free, and Void-returning. Its native wrapper returns `Void?`: a live
receiver produces `.some(())`, while a receiver released before body entry
produces `.none` without invoking the method.

Closure formation recognizes only the capture-only `[weak self] in` signature.
Admission may temporarily read a live receiver to prove one exact declaration
descriptor, but it does not register the resolved method closure because that
closure would strongly retain the instance while the physical job waits for a
permit. Instead, `RuntimeTaskRecord` retains the source operation closure and
its genuine weak box. The Sendable worker command still contains only
entry/task/descriptor/argument/result facts, now with an `optionalVoid` result
kind; no `Box`, receiver, closure, `Environment`, `RuntimeValue`, program state,
heap, or evaluator crosses the worker boundary.

After the detached wrapper acquires capacity and enters the MainActor relay,
the relay reads the confined weak box. Nil materializes a copied Optional.none
snapshot. A live instance is temporarily retained for the dynamic call,
re-resolved against the preflight descriptor, invoked through the ordinary
suspension-aware evaluator, and returned as Optional.some(Void). Thus the weak
read occurs at physical body re-entry rather than at registration. A causal
occupied-permit regression drops the only strong receiver while the wrapper is
queued and observes `released` through one physical receipt, proving the
registration itself does not strengthen the capture.

Apple Swift 6.3.3 and interpreted execution returned exact `weak:none|none` in
twenty bounded runs; every native five-run shard retained canonical SHA-256
`59b08bc91e9e8533552cc5edbaeedf8d0af325e761b6131da38169d353f0b121`.
The receipt RED moved from zero to one physical execution. String-returning and
argument-bearing weak calls, nil-at-admission, aliases, additional captures,
explicit signatures, unowned captures, and richer routes remain cooperative.
The focused board passed 75 tests in six suites, all 46 methodology/gate
checks, and twenty parity repetitions on four workers in four seconds. The
rebuilt scoped TSan board passed native overlap 20/20 plus all 62
driver/kernel/source-call tests in three suites on four workers in 68 seconds
without a race or interceptor diagnostic.

Earlier metadata slices separate immutable program input, mutable storage, and
execution identity without changing scheduling; the source kernels change
scheduling only for their admitted subsets. Remaining member families and
source class/actor/host/standard-library target identities beyond the unique
own reference-method descriptor, the exact default-actor synchronous and async
single-Int plus explicit-single-defaulted-Bool routes, the exact actor-declared
custom-global-actor argument-free async Void route, the exact inherited-caller
argument-free async Void route, normalized callee shape,
and the existing core-Task, `String.count`,
conservative `String.distance`, `Array.map`, `Array.reduce`, and
`Substring.count` proofs remain incomplete, as does compiler metadata
indexing. Mutable symbol materialization
plus evaluator state must move fully
behind the session, and
demand-cited value, richer scalar-expression, and captured or richer suspending
kernels still need safe lowering. The scoped
literal/String-count/Substring-reduction/yield/String-distance/conditional-sleep/
MainActor-Boolean/concurrent-integer/default-actor/custom-global-actor/
inherited-source-call
and strong-self-capture-source-call
and parallel-detached-weak-self-source-call
and weak-self-optional-async-source-call
and optional-async-closure-invocation
and weak-receiver-release-across-suspension
differential
and TSan board is green, but the board must expand with every future worker
kernel before M9 can close.

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
- update the acceptance matrix and parity ledger;
- the full repository gate is NOT part of this per-change loop (measured
  2026-07-17: ≈21 minutes wall — tests 460s, corpus+parity 189s, LiveCheck
  630s); per-change verification is the focused runner
  (`Scripts/run-concurrency-iteration.sh`), and the full gate belongs to the
  milestone and merge tiers below;
- focused runners terminate their entire child process tree on exit or
  interruption (orphaned probe processes were observed 2026-07-17; only the
  full gate killed its tree).

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

### Per merge into main

Main is the integration branch and is itself under the no-regression
covenant: every commit that lands on it leaves every board green — no
half-landed series (the 2026-07-17 checked-continuation alias window, red on
main for ~5 hours and auto-pushed to origin throughout, is the incident this
tier prevents). Work stages on the lane branch
(`.claude/worktrees/lane-concurrency`, branch `worktree-lane-concurrency`)
and reaches main only through a gate-green merge serialized by the steward:
run the full gate on the lane tip, append a `MERGE-READY <sha> <gate
summary>` line to `.claude/claims.md`, and keep working — LOOP.md's worktree
protocol v2 defines the steward handshake and the ~2-hour MERGE-LOCK
liveness fallback. Direct commits to main are not part of any lane's loop.
If main turns red anyway, restoring it — revert first when the fix is not
immediate — outranks every lane queue.

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

Рабочее место — worktree .claude/worktrees/lane-concurrency (ветка
worktree-lane-concurrency); main-checkout — интеграционное дерево steward'а,
в нём ничего не редактируй, не собирай и не тестируй. В начале цикла —
`git merge main` внутри worktree; каждый зелёный шаг коммить на ветку lane.
Прямые коммиты в main запрещены: когда серия готова, прогони полный gate на
верхушке lane и добавь строку `MERGE-READY <sha> <итог gate>` в
.claude/claims.md — мержит steward (worktree protocol v2 в LOOP.md, там же
~2-часовой MERGE-LOCK fallback). Main всегда зелёный.

Перед началом полностью прочитай документ и
Docs/ConcurrencyVerificationMethodology.md. Выбери следующий открытый
requirement из executionPlan.currentTail в
Tests/ConcurrencyParity/Manifests/milestone-acceptance.json — в порядке его
requirementRefs, при выполненных dependency; когда активный цикл закрыт,
переходи к entryRequirementRefs из nextMajorCycle. Порядок работ задаёт
demand-ordered scheduling из раздела 14, включая within-slice depth cap:
внутри допущенного construct'а полный цикл characterize+support получает
только spelling с demand-цитатой (corpus-проект, место в FoodTruck, класс
LiveCheck/TestCheck); остальное закрывается fail-closed с именованной
диагностикой. Не бери demand-deferred остаток M4 (executor-preference,
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
   Docs/ConcurrencyParity.md; на каждом шаге — только focused-проверки
   (Scripts/run-concurrency-iteration.sh CASE_ID TEST_FILTER). Полный gate —
   только на границе milestone/slice и перед MERGE-READY, не после каждого
   шага (раздел 15).

Не добавляй silent no-op support, не ослабляй тесты и не затрагивай чужие
worktree. Не переходи к более поздним API, пока не выполнены архитектурные
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
  .claude/worktrees/lane-concurrency inside
  /Users/mike/src/tries/2026-07-08-swiftui-dynamic (branch
  worktree-lane-concurrency). The main checkout is the steward's integration
  tree: never build, test, or edit there. Merge main into the lane at cycle
  start; commit every green step on the lane branch.

Authority and scope:
- Modify the interpreter, its host contracts, SwiftUI bridge integration,
  tests, parity harness, and concurrency documentation as required by the
  architecture document.
- Preserve all pre-existing user changes in the worktree.
- Never use destructive git commands.
- Never commit directly to main: series stage on the lane branch and reach
  main only through the steward-serialized, gate-green merge protocol in
  LOOP.md (MERGE-READY / MERGE-LOCK lines in .claude/claims.md). Main is
  itself under the no-regression covenant — green at every commit it
  receives.
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
  suite, and methodology concurrently against the prebuilt bundle. Repeated
  edits may pass `--methodology-filter` for the affected disposition and
  acceptance checks; the pre-commit run omits it and executes the complete
  methodology suite. Do not try to parallelize several
  `swift test --skip-build` commands; SwiftPM still serializes them on its
  shared build-directory planning lock.
- Every milestone/slice boundary and every MERGE-READY handoff runs
  AsyncExecutionTests, HostSignatureTests, all concurrency parity tests, full
  swift test, and Scripts/gate.sh when available. The full repository gate
  (≈21 minutes, measured 2026-07-17) is never the per-change inner loop.
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
