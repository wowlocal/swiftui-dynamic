# Dynamic SwiftUI

A tree-walking Swift interpreter that parses Swift source **at runtime** with
[SwiftSyntax] and renders user-defined SwiftUI views live — type a counter app
into the editor pane, click its buttons in the preview pane.

Inspired by [Bitrig's Swift interpreter series][bitrig-1] ([part on
expressions][bitrig-2]) and [Cocoanetics/SwiftScript][swiftscript].

```
swift run DynamicSwiftUIDemo
```

To exercise the generated native platform bridge in a small interpreted app,
render the shared smoke project with the host's platform identity:

```bash
swift run DynamicSwiftUIDemo \
  --platform macOS \
  --project Examples/PlatformBridgeSmoke
```

The same `PlatformBridgeSmoke` source is bundled by the iOS
`Examples/AtmosphereDevice` host and can be selected with the launch argument
`--project-resource PlatformBridgeSmoke`.

An editor opens on the left and a live interpreted **Atmosphere** app renders on
the right: a complete networked weather and air-quality dashboard. Its source
performs a three-stage request pipeline
(geocoding → forecast → air quality) with an actor-based generic API client,
`async`/`await`, `URLComponents`, nested `Codable` models, observable loading
state, debounced live city suggestions, and a custom `Shape` temperature
chart. The default launch uses live HTTP, so typing shows tappable matches;
pressing Return or the search button fetches the first result.
For deterministic/offline use, replay the committed Lisbon snapshot with:

```
swift run DynamicSwiftUIDemo --network replay:Fixtures/open-meteo-lisbon
```

The same app also lives as a conventional split-file interpreted project in
`Examples/Atmosphere/` (`Models.swift`, client, store, components, dashboard,
and root view). Run the directory directly:

```
swift run DynamicSwiftUIDemo \
  --project Examples/Atmosphere \
  --network live
```

Other built-in samples (toolbar picker): **Counter** (`@State` + Button
actions), **Calculator** (an iOS-style calculator — a real immediate-execution
state machine with chained operators, repeat-equals, percent and
divide-by-zero handling), **Tic-Tac-Toe** (play against a rule-based AI that
takes wins, blocks threats and prefers center/corners, with win-line
highlighting), **Todo** (MVVM `ObservableObject` store shared by views), **Form**
(`$state` bindings driving `Toggle`/`Slider`/`TextField`), **Weather** (enums
with methods, `switch` in bodies, gradients), **Layout** (stacks, modifiers,
`ForEach` chips), **List** (nested user-defined views), plus four lifted from
the sample-projects corpus: **Segments** (Kavsoft's AnimatedSegmentedControl —
generic view with a `@ViewBuilder` closure property, GeometryReader indicator
math), **Material** (Kavsoft's MaterialTF — floating-label text field),
**Popup** (Kavsoft's PopUpNavigation — an `.overlay`-based popup hosting
pushable NavigationLinks over a dimmed backdrop), and **Albums** (Kavsoft's
"Filled" — cards scale and fade under the header as they scroll, via nested
GeometryReaders).

```
swift test
```

For the full repository gate, including parallel test, corpus, API-parity, and
live-data evaluation, run `Scripts/gate.sh`. Its process-sharding model,
resource knobs, and tuning procedure are documented in
[`Docs/ParallelVerification.md`](Docs/ParallelVerification.md).
For a single manifest-backed concurrency parity case during development,
build tests once and use `Scripts/run-focused-parity.sh CASE_ID --jobs 4`;
the runner preserves the manifest's full repetition count while splitting it
across isolated processes.
For the complete concurrency inner loop, use
`Scripts/run-concurrency-iteration.sh CASE_ID TEST_FILTER`. It builds the test
bundle once, then runs the focused parity case, targeted tests, and methodology
suite concurrently through direct prebuilt-bundle processes. During the edit
loop, `--methodology-filter 'RELEVANT_TEST|ACCEPTANCE_TEST'` limits that lane to
the checks affected by the slice; omit the option for the complete 42-test
methodology gate before committing. The runner reports each lane's wall time
so the slowest verification surface remains visible. This avoids the shared
SwiftPM planning lock that serializes concurrent `swift test` commands; pass
`--skip-build` only when the bundle is already current.

## Concurrency roadmap

The machine-readable source of truth is
[`milestone-acceptance.json`](Tests/ConcurrencyParity/Manifests/milestone-acceptance.json),
with the detailed design in
[`Docs/SwiftConcurrencyArchitecture.md`](Docs/SwiftConcurrencyArchitecture.md).

- **Active cycle — M9 optional physical parallelism (2026-07-17):** first
  separate immutable parsed-program metadata, session-owned mutable state, and
  runtime-entry identity. Declaration, callable/accessor/subscript, nominal,
  property-storage, enum-case, extension, type-alias, and deinitializer
  headers plus function bodies/placement, initializer declaration/isolation,
  call-site argument structure/provenance, and all-branch conditional member
  plans are now immutable Sendable indexes. Each session owns one immutable
  target-resolved program plan, and runtime entries plus escaped closures retain
  that exact plan across callbacks and SwiftUI/source tasks. Each prepared
  program also owns a distinct MainActor-confined `RuntimeProgramState`; its
  session, entries, and escaped closures retain the originating mutable symbol
  and declaration registries even after the facade prepares another program.
  The resolved plan also owns file identity and its immutable source map, so
  escaped callbacks keep native-like diagnostic and `#line` provenance after
  suspension or a later facade run. The cooperative runtime now strongly owns
  session-scheduled unstructured and detached task handles through completion;
  the interpreter facade exposes only a compatibility inspection view. The
  runtime also allocates every asynchronous evaluator-context identity; only
  the synchronous facade context keeps reserved ID `0`. Evaluator contexts
  identify their owning runtime rather than retaining or identifying the
  interpreter facade; explicit host re-entry capabilities remain separate.
  The native-stack guard cache is task-owned too and is keyed by the stable
  numeric ID of its supplying pthread, so a Swift task that resumes on another
  worker cannot reuse the previous thread's stack geometry.
  Remaining member semantics, call-site semantic resolution, compiler
  metadata, evaluator/session migration, heap-edge classification, workers,
  mode-differential parity, and TSan are still open.
- **Covered demand cycles:** M5 actor identity/mailboxes and storage
  confinement, M6 protocol sequences/streams/checked continuations, and M8
  SwiftUI-owned `.task` lifecycle have scoped executable evidence. Their broad
  dependency milestones retain the explicit partial/provisional statuses in
  the acceptance manifest.
- **Demand-deferred:** the remaining M4 executor-preference/repeated-wait
  surface has zero measured corpus/FoodTruck demand and reopens only on a
  cited real-program failure.

Actor support is complete only when every M5 requirement and its M4/M7
dependencies are covered; parsing an `actor` declaration or running it through
the current class-like compatibility path is not a support claim.

## How it works

```
source ──SwiftParser──▶ AST ──SwiftOperators.foldAll──▶ precedence-folded AST
       ──DeclarationCollector──▶ StructSymbols in globals
       ──tree-walking eval──▶ RuntimeValue (type-erased enum)
       ──HostSignature contracts──▶ HostRegistry gateways
       ──real SwiftUI views (AnyView)
```

The core's responsibility boundaries and staged typed-value migration are
documented in [`Docs/InterpreterArchitecture.md`](Docs/InterpreterArchitecture.md).

- **No custom parser.** SwiftSyntax parses; `SwiftOperators` folds flat
  operator sequences into precedence trees, so the evaluator never implements
  precedence.
- **No reimplemented frameworks.** The interpreter core (`SwiftInterpreter`)
  never imports SwiftUI. "What does `VStack` mean" is answered by the
  `SwiftUIBridge` target through BridgeGen tables derived from the SDK's
  swiftinterfaces, plus a narrow set of semantic primitives for SwiftUI magic
  the interfaces cannot encode. Both call the real SwiftUI API (the Bitrig
  trick). A `TraceRegistry` implements the same protocol for headless tests.
- **Executable host contracts.** Embedders can register Swift-shaped
  declarations (`func`, `init`, instance/static methods, and mutable/read-only
  properties) through `HostFunction` and `HostProperty`. SwiftParser caches
  labels, defaults, variadics, generic constraints, effects, and return types;
  the boundary validates arguments and results, ranks typed overloads, and
  rejects ambiguity before gateway code runs. Legacy dynamic gateways remain
  available for incremental migration, and none of this imports SwiftUI into
  the language runtime.
- **User View structs become real views** via a stub: `InterpretedView` is a
  SwiftUI `View` whose `body` asks the interpreter to evaluate the interpreted
  `body` property.
- **`@State` re-render loop:** state lives in `Box`es on the instance; an
  interpreted Button action mutates the box → the box's `onChange` fires →
  a `StateStore` (`@StateObject`) publishes `objectWillChange` → SwiftUI
  re-runs `InterpretedView.body` → the interpreted body re-evaluates with the
  new value. `StateStore.adopt` carries boxes across instance recreations, so
  state survives parent re-renders just like real SwiftUI.
- **Implicit members** (`.title`, `.blue`, `.leading`) evaluate to a marker
  value and are resolved against the *expected* parameter type inside each
  gateway — type-inference dodged with lookup tables.

## Supported subset

**Language**: literals + interpolation (including localized printf-style
`specifier:` controls), arrays/dictionaries/tuples with
subscripts (including Dictionary `default:` reads and mutations with native
fallback evaluation), dedicated `Set` values (array-literal/sequence construction,
membership, algebra, mutation, and value semantics), operators with real
precedence, dedicated recursive Optional values (typed `.none`, nested
Optionals, IUOs, `if let`/`guard let`/shorthand, `??`, `?.` chaining,
`!`, patterns, `map`/`flatMap`, failable casts/inits and `try?`), `if`/`else`, `switch` with
expression/range/enum-payload/`where` patterns (also as expressions and in
builders), `for`-in, `while`, `break`/`continue`, functions (defaults,
implicit return, trailing closures, `@ViewBuilder`/`some View` builder
bodies), closures (`$0` shorthand, capture-by-reference, explicit capture-list
snapshots), structs (value semantics across bindings/arguments/returns/
containers, stored/computed properties, mutating methods, custom `init`s,
memberwise init, statics),
enums (raw + associated values, methods, computed properties, `CaseIterable`),
**classes** (reference semantics, custom inits, statics, `super`
inheritance-lite), **user subscripts** (get/set, tuple and multi-arg
indices), `defer` (LIFO, all exit paths), typealiases (target types,
generic args dropped), **protocols** (declarations inert — conformance is duck
typing; protocol-EXTENSION members serve as defaults, conformers' own
definitions win), extensions,
**view models** — `ObservableObject`/`@Observable` with `@Published`,
`@StateObject` (model persists across view recreation), `@ObservedObject`
(shared models re-render every observing view), `$store.field` bindings onto
model properties — plus `@State`, `@Binding`, `$` projections, ~40 stdlib members
(`map`/`filter`/`reduce`/`sorted`/`first(where:)`/`contains`/`joined`/
mutating `append`/`remove(at:)`/…, string methods), and global
`print`/`abs`/`min`/`max`/`String`/`Int`/`Double`/`Array`/`Set`.

**Type context, dynamically**: bare `.member` values resolve against known
enums via the type annotations on properties, parameters, and return types —
no inference engine, just annotations. Binding, Set, and Optional storage
retain generic/wrapped context even while a collection or Optional is empty.

**SwiftUI**: `Text`, `Image(systemName:)`, `Label`, stacks, `Group`,
`ScrollView`, `List`, `Form`, `Section`, `LazyVGrid`/`LazyHGrid`/`GridItem`,
`NavigationStack`/`NavigationLink`, `TabView`/`.tabItem`, `Button` (with
roles), `Toggle`, `Slider`, `TextField`/`SecureField`, `Picker` (String
selection), `ForEach` (ranges, arrays, and `ForEach($items) { $item in … }`
binding collections — element bindings write back into the array, and
`$item.field` projects field bindings à la `@dynamicMemberLookup`), `ProgressView`, `Spacer`/`Divider`, shapes (`Circle`,
`Capsule`, `Rectangle`, `RoundedRectangle`, `Ellipse`) with `.fill`/`.stroke`,
`LinearGradient`, `withAnimation`, **user `Shape` structs** (`func path(in:)
-> Path` runs interpreted and draws real geometry; `.fill`/`.stroke`/`.trim`
apply); presentation — `.sheet(isPresented:)`,
`.alert(_:isPresented:actions:message:)`, `.confirmationDialog`; environment —
`.environmentObject(_:)` + `@EnvironmentObject` (carried on SwiftUI's real
Environment, so scoping and propagation into sheets come for free); **AttributedString styling** (`range(of:)` + `text[range].foregroundColor =`
applied to the real Foundation type, rendered by `Text`); `$items[index]`
element bindings; `UUID()`
and `Date()` basics; ~50 modifiers including `padding`/`frame`/`font`/
`foregroundStyle` (colors, materials, hierarchicals, `.color.opacity`/
`.gradient` chains)/`background`/`overlay`/`shadow`/`clipShape`/`offset`/
`scaleEffect`/`rotationEffect`/`animation(value:)`/`onAppear`/`onTapGesture`/
`onSubmit`/`task`/`navigationTitle`/`listStyle`/`buttonStyle`/`pickerStyle`.
Color-typed parameters recursively accept transformed Color chains, and raw
`AnyShapeStyle` values retain their style identity across interpreted computed
properties before generated modifiers consume them.

## Generated gateways (BridgeGen)

Hand-writing gateways doesn't scale to SwiftUI's real surface, so
`swift run BridgeGen --emit` parses the SDK's **actual swiftinterface files**
(SwiftUICore + SwiftUI — the modern SDK splits them), extracts the public
AppKit/UIKit symbol graphs, and generates
`Generated/GeneratedModifiers.swift` (**428 overload variants across 151
modifier names**) and `Generated/GeneratedViews.swift` (**113 initializer
variants across 32 View structs** — containers, navigation, Button, Toggle,
TextField, Label, ContentUnavailableView, gradients…). Struct inits mostly live in *extensions*
with same-type constraints (`extension GroupBox where Label == Text`), so the
generator threads struct-level generics plus extension where-clauses (both
conformance sets and concrete substitutions) into parameter analysis. Every
entry is a statically-compiled call against the real SDK, so a wrong signature
fails at build time rather than in a session. Dispatch
goes through the ArgumentMatcher (`GeneratedSupport.swift`): per-overload
parameter specs (label + coercible type tag), label/coercibility filtering,
most-specific-first ranking. Hand-written gateways are consulted first and
always win for compatibility with existing semantic overrides; this dispatch
order is not permission to add new API-specific gateways. The report mode (no
`--emit`) prints the blocking-type histogram —
the priority list for new coercions. Defaulted parameters are expanded into
every valid labeled omission shape, including defaults before required
parameters (`VStack(spacing:) { ... }`); an omitted unlabeled default never
permits a later unlabeled positional argument.
`@ViewBuilder` attributes are read from both SwiftSyntax representations;
zero-input builders generate automatically, while builders that require a
framework-supplied value remain explicit semantic adapters. Generated builder
arguments stay lazy until overload selection, so a nested render failure keeps
its real source location instead of becoming a misleading outer-container
error. Concrete `Text` parameters preserve their SDK type while still accepting
string values. Public,
payload-free SDK enums are swept too: `GeneratedSDKEnums.swift` currently
coerces 14 types directly from their SDK-declared cases instead of maintaining
handwritten switches. CI can request a
stable inventory of emitted signatures and blocker counts with
`swift run BridgeGen --report-json .build/bridgegen-coverage.json`.

**Development invariant:** an ordinary missing initializer, modifier, or SDK
member is always a generator problem. Fix the interface analysis, type
mapping/coercion, or a reusable generated adapter; never add an API-, project-,
fixture-, or literal-specific gateway to make one case pass. Handwritten code
is reserved for narrowly documented SwiftUI magic absent from a
`swiftinterface`: builder execution and supplied inputs, state/binding identity,
child identity/composition, and opaque view/shape/style preservation or
erasure. Even that magic must be reusable where possible and covered by native
parity or integration tests. See `AGENTS.md` for the binding agent rule.

The same generator sweeps the SDK's **Foundation swiftinterface** for the
member surface of value types (`URL`, `Data`, `Date`, `Calendar`, `UUID`,
`Locale`, …): `Generated/GeneratedMembers.swift` holds **247 properties and
115 method variants**; **68 properties are generated as writable and 179 as
read-only**, matching the SDK interface. Entries are keyed by the receiver's
dynamic type (`"URL.lastPathComponent"`) and consulted from `bridgeHostMember`
after the hand boxes and before the ObjC trampoline. Every property emits its
exact read-only or mutable Swift declaration, parsed once into a shared
`HostProperty` that validates
the logical SDK receiver and every result (including Optional, collection, and
Objective-C-bridged names); mutable declarations additionally emit a typed
copy-out mutation. Value lvalues install the returned SDK copy, carrier boxes
write it back in place, while existing hand-normalized URLComponents item
reads remain language collections. Opt-in host value carriers copy at
interpreter storage boundaries, preserving native value semantics for
`DateComponents`, `URLComponents`, and `URLRequest`. Each method variant similarly emits a
`HostSignature`; `HostFunction` owns label/arity/type checks, deterministic
overload ranking, and return validation, while `ParamTag` only converts an
already-selected argument for the statically compiled host call. Invalid calls
or property boundary mismatches now diagnose at that contract boundary.
Soft-deprecation sentinels
(`deprecated: 100000.0` — `url.path` and friends) are tolerated for members
since real projects compile against them. The demand side is instrumented:
every member the absorb terminus swallows on a host native lands in
`Interpreter.absorbedHostMembers`, and LiveCheck prints the top of that
histogram per scenario (`absorbed: URLSessionBox.webSocketTask×3`) — the
priority list for growing the sweep's `memberTypes`/tags. Members hand-served
below the registry (the core's `nativeMember`) are pinned in BridgeGen's
`denyMembers` so generated entries never shadow them.

AppKit and UIKit need a second metadata source because most of their
Clang-imported Objective-C surface is absent from the textual Swift overlay.
BridgeGen therefore caches `swift-symbolgraph-extract` output for both SDKs
and emits `Generated/GeneratedPlatformBridge.swift`. Extracted declarations
are ordered by stable signature keys, so regenerating before and after a clean
package cache is byte-identical. Member selection is type-level: for each
configured platform primitive (`NSView`/`UIView`, controls, windows, colors,
fonts, images, text and collection views, plus their nested types), every
mechanically supported public member is generated; there is no member-name
allowlist. Module-global functions have no nominal parent, so every public
global accepted by the same availability and type/coercion rules is emitted
too. The current SDK produces **113 AppKit types, 164 constructors,
1,029 properties, 516 methods, 13 global functions, and 496 contextual
values**; **103 UIKit types, 123 constructors, 680 properties, 263 methods, 15
global functions, and 364 contextual values**; and **14 Metal types, 4
constructors, 69 properties, 48 methods, 4 global functions, and 12 contextual
values**. Calls compile statically against the real framework on its native
platform: ordinary SDK coverage is native forwarding, not a reimplementation.
The same typed contracts remain available on the other platform as
deterministic inert values, so shared source can still construct, read, write,
and chain the API without pretending that the unavailable framework exists.
Generated carriers preserve native struct value semantics and class identity.
Complete module-global `Begin…Context`/`End…Context`/
`Get…FromCurrent…Context` families additionally retain a per-registry nested
context lifecycle off-platform; this preserves control flow but does not claim
pixel or device parity. Inherited/importer-synthesized initializer shapes and
unsupported signatures (for example `inout` delegates) retain the existing
inert compiled-import fallback instead of weakening matched generated
contracts. The JSON coverage report's schema v2 records this surface under
`platformMembers`, including availability filtering and blocker counts.

**The parity harness closes the confidence loop**: `swift run BridgeGen
--emit --probes` also generates one expression probe per generated member
(deterministic seeds, textually identical on both sides) into a COMPILED
twin (`ParityTwin`) and an interpreter-side table; `swift run ParityCheck`
runs the twin twice (auto-filtering clock/locale-volatile members),
interprets every probe, normalizes representations, and diffs — the
native-baseline doctrine mechanized for APIs. The current board is **345
matches, 0 divergences, and 0 interpreter errors** across the 345 stable probes
(17 additional probes are filtered as native-run volatile).

## Corpus verification

`Tests/SwiftUIBridgeTests/Corpus/` holds ten realistic programs (todo list,
settings form, weather card, grid gallery, navigation profiles, stats
dashboard, animated counter, string toolkit, shape showcase, traffic light).
Each must: interpret; **deep-render** (every View body force-evaluated via the
trace registry, not just the lazy root); survive a click-through pass where
every Button action fires against a fresh render; and host through real
SwiftUI (`NSHostingView` in a never-shown window) with zero inline errors
(observed via `RenderDiagnostics`). This suite is the working definition of
"runs real-world code" — new corpus files are the cheapest way to grow
coverage.

## Deliberate divergences from Swift

- **Struct storage is internally class-backed, but language semantics are
  value-based.** New bindings, parameters, returns, properties, containers,
  captures, and assignments copy source-struct storage envelopes. Native
  containers retain their own copy-on-write storage, and composed lvalues
  detach only a nested source-struct path when it is mutated. Nested and
  sync/async `mutating` calls use lvalue copy-in/copy-out. Source classes and
  host objects retain identity, while `@State`/`@StateObject` and `@Binding`
  copies deliberately retain their external storage locations. Compile-time
  exclusivity and let-vs-var diagnostics remain the compiler's job.
- **Argument labels guide binding but are not compiler-strict.** Labeled
  arguments bind by name, defaults may be omitted in the middle, and trailing
  closures use function-parameter shape; unmatched positional arguments may
  still fill remaining parameters as a real-project compatibility fallback.
- **State resets on re-parse.** Each successful edit gets a fresh identity
  (`.id(generation)`); the old program's state may not fit the new program.
- **Per-identity @State persistence is probe-opt-in.** Compiled SwiftUI keeps
  @State/@StateObject storage alive across re-renders of the same position;
  the interpreter does too when `Interpreter.persistentViewState` is set
  (keyed by instantiation site + type + property — LiveCheck's multi-pass
  probe needs `.onAppear` writes visible to the fetch pass). It stays off for
  M0 render probes whose click-through replays actions against re-renders in
  an order no native run sequences. ForEach rows share one site (positional
  identity, above).
- **ForEach/container identity is positional** — bodies re-evaluate wholesale,
  so `@State` inside reordered children won't track.
- **No static type checking.** Type annotations drive dynamic coercion,
  overload selection, generic hints, and implicit-member resolution, but there
  is no compile-time inference/checking pass. Mismatches surface at evaluation
  time, located (`line:col`) in the error bar.
- **Bindings are Box handles.** `$name` projects the state's storage box; the
  bridge wraps it in a real `Binding` whose setter writes the box (rounding
  back to Int when the state was declared Int, e.g. for `Slider`).
- **Platform stubs.** `UIScreen.main.bounds` maps to the main screen's frame
  (390×844 headlessly); `DispatchQueue.main.async` dispatches interpreted
  closures through the real main queue; `UIViewRepresentable`/
  `NSViewRepresentable` structs are accepted in view position but render
  inert (their make/update methods never run); `X.appearance()` proxies accept
  all configuration inertly (writes ignored, config calls chain).
- **Conditional compilation identifies as iOS.** `#if os(iOS)`,
  `canImport(_)`, `DEBUG`, and `swift(…)`/`compiler(…)` hold;
  `os(macOS)`/`targetEnvironment(simulator)` and unknown conditions take
  the `#else` branch — consistent with the iOS-shaped platform stubs.
  Works in declaration, statement, builder, and postfix (modifier-chain)
  positions.
- **Custom `Layout` containers flow.** `TagLayout(spacing:) { … }` renders
  its children in a default vertical flow; the interpreted
  `sizeThatFits`/`placeSubviews` never run.
- **Hosted-object truths are fresh-state false.** Unknown host objects and
  unresolved markers in Bool positions read `false` (`context.
  canEvaluatePolicy(…)`, `session.isRunning` — no biometrics, nothing
  running headlessly); `!` negates from that. The same absorption reads
  unknowables as each context's fresh identity: 0 in arithmetic and numeric
  conversions, `""` in string concatenation
  (`NSTemporaryDirectory() + name` keeps the name), empty in ARRAY
  concatenation (`(target.plugins ?? []) + additions` keeps the
  additions), and empty in `for-in` iteration (`Activity<T>.activities`
  on a fresh device).
- **Canvas drawing is inert.** `Canvas { context, size in … }` runs the
  renderer once against a no-op context (390×844) — the closure's math
  executes, but fill/stroke/translate commands never reach a real
  `GraphicsContext`; the canvas area renders empty. `Path { … }` builders
  execute the same way.
- **Casts are optimistic.** `as`/`as!` pass the value through; `as?` only
  yields nil for nil inputs. The target type does resolve implicit-member
  markers and bridges Int/Double.
- **State-like wrappers flatten to @State.** `@AppStorage`, `@SceneStorage`,
  `@GestureState`, and `@FocusState` bind and project like `@State` but skip
  their special semantics (no UserDefaults persistence, no gesture reset, no
  focus plumbing). `@Bindable` (bare or module-qualified, e.g.
  `@Perception.Bindable`) rides `@ObservedObject` semantics: `$model.field`
  projects a binding into the model's box.
- **Store-query wrappers act on a fresh empty store.** `@Query` (SwiftData),
  `@ObservedResults` (Realm), and `@FetchRequest` (CoreData) flatten to
  `@State` defaulting to `[]`; `@Environment(\.modelContext)` and
  `\.managedObjectContext` yield an inert context (insert/delete/save
  accepted and ignored, fetch returns empty); `$results.append/remove`
  mutate the flattened state array. Nothing persists.
- **The file system is a per-run sandbox.** `FileManager.default` performs
  real file operations confined to a temp-directory sandbox (the analog of
  an app's fresh container): `urls(for:in:)` returns a sandbox Documents
  directory that starts empty, `fileExists` is honestly false until the
  program writes, copy/move/remove genuinely happen inside the sandbox and
  throw outside it. `URL(string:)` has real Foundation semantics (invalid
  strings are nil).
- **Missing environment objects synthesize fresh models.** When
  `@EnvironmentObject`/`@Environment(Type.self)` finds no ambient model (the
  `App` shell that would inject it never runs), a fresh instance of the type
  is constructed once and shared — the fresh-store doctrine applied to
  models. Ambient injections always win.
- **Typed environment rides the model environment.**
  `@Environment(Type.self)` + `.environment(model)` behave exactly like
  `@EnvironmentObject` + `.environmentObject(_:)`, keyed by type name.
- **Actors are currently a known divergence.** `actor` declarations still
  collect through the class-like compatibility path (reference semantics,
  methods, properties), but isolation is not enforced and calls run on the
  caller. Single-threaded execution does not make that Swift actor semantics.
  M5 replaces this path with actor-owned identity/storage, serial executor
  queues, isolated hops, and suspension-safe reentrancy; until then the runtime
  does not claim actor support.
- **`super` is inheritance-lite.** Interpreted superclasses dispatch
  methods/computed properties with `self` unchanged (plain member access
  walks the chain too), and stored properties MERGE down the interpreted
  chain at instantiation (child declarations win). Host superclasses
  (NSObject, UIViewController…) make `super.init()` and lifecycle calls
  inert.
  Member writes on unresolvable host markers (`manager.delegate = self`)
  are accepted and ignored; marker comparisons are name-based
  (`authorizationStatus(for: .video) == .authorized` is false — fresh
  system state).
- **Property observers run with compiled semantics.** `willSet` (newValue) and
  `didSet` (oldValue) fire on assignment through the write funnel, never on
  initialization, and assigning to the property inside its own observer does
  not re-trigger. Custom parameter names bind.
- **`$published` pipelines are silent.** The Combine projection inside a
  model (`$searchText.debounce(…).sink {…}`) chains inertly and never
  emits — debounce schedulers and timers don't run headlessly, so sinks
  stay quiet.
- **Model notification is box-level.** Writing a `@Published` property (or any
  stored property of an `@Observable` class) fires the model's change signal.
  Mutating an instance nested *inside* a published collection doesn't — 
  reassign through the collection (`todos[i] = item`) to notify. `@StateObject`
  initializer side effects re-run (and are discarded) on view recreation.
- An evaluation **step budget** (100k) guards the main thread against
  `while true {}`.
- **Async sessions schedule real task trees; synchronous renders are
  bounded.** `runAsync` propagates host suspension and runs `Task { … }`
  bodies as cancellable main-actor tasks, waiting for their descendants.
  The synchronous renderer cannot wait for child work, so its compatibility
  path executes one body inline with a 20k-step slice; an intentionally
  infinite polling loop then parks without charging the surrounding flow.
- **C interop is absorbing, hardware answers are real.** Unresolved
  snake_case/SCREAMING_SNAKE identifiers and bodyless functions read as C
  imports: calls absorb into writable bags, constants read as
  numeric-absorbing markers (0 in arithmetic and comparisons through
  concrete zero). A short registry of functions answers truthfully —
  `uname(&info)` fills the struct bag with the real host's utsname values
  and returns 0 — so hardware-detection chains (AlDente's
  `machineHardwareName`) resolve to the machine's actual identity. Inside
  host-type extension bodies these names resolve as C imports before any
  view-modifier rescue.
- **Bundle identity is real; bundle contents absorb.** `Bundle.main`
  carries the actual host process's `bundleURL`/`bundlePath` (so
  path-climbing idioms terminate), and `bundleIdentifier` answers the
  real one or a stable stand-in when the harness runs unbundled (a
  device app always has one). Resource and metadata lookups
  (`path(forResource:)`, `infoDictionary`, `object(forInfoDictionaryKey:)`)
  absorb — nothing is bundled headlessly.
- **App-delegate launch hooks run.** `applicationDidFinishLaunching` on
  NS/UIApplicationDelegate conformers executes before the root view
  renders (singleton seeding happens as on device); non-fatal errors
  inside the hook are tolerated.

[SwiftSyntax]: https://github.com/swiftlang/swift-syntax
[bitrig-1]: https://bitrig.com/blog/swift-interpreter
[bitrig-2]: https://bitrig.com/blog/interpreter-expressions
[swiftscript]: https://github.com/Cocoanetics/SwiftScript
