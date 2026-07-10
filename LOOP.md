# The Loop

## High-level goal

A Swift interpreter that **matches native SwiftUI's abilities and runs real
open-source SwiftUI projects without errors**. Architecture (settled, don't
relitigate): tree-walk SwiftSyntax ASTs directly (never SIL), delegate all
framework behavior to gateways (hand-written overrides + BridgeGen-generated
tables from the SDK's swiftinterfaces), stub types (`InterpretedView`) for
protocol conformance. See README.md for what already works.

**North-star metric: `swift run ProjectCheck` pass rate.** 587 real zipped
SwiftUI sample projects sit in `/Users/mike/Documents/sample-projects`. The
runner extracts them (into gitignored `External/`), merges each project's
`.swift` files, interprets, deep-renders every View body, and clicks every
action. Its failure-class histogram is the priority queue.

**Second queue: `swift run TestCheck [root] --limit N` — semantic fidelity.**
Runs each OSS project's OWN unit tests over the interpreted code (TestHarness
merges app + test sources; XCTAssert* are recording host functions; fresh
instance per test, setUp/tearDown honored). ProjectCheck proves code RENDERS;
TestCheck proves it COMPUTES — author-written assertions catch divergences no
render can (inout write-back and the $0/$1 tuple splat shipped exactly this
way: tiles slid, never merged, zero render diagnostics). Consult this queue
when ProjectCheck's histogram is all-singletons or its top class is a known
wall; a genuine TestCheck class then outranks singleton render classes.

**The native-baseline rule (never skip it):** an interpreted test failure is
an interpreter bug ONLY if the same expectation holds under the real
compiler. Before queueing any TestCheck class:

1. Reproduce natively. SPM-based projects (Package.swift in the repo): run
   the exact test inside `External/oss/<name>` with
   `swift test --filter TestClass/testName`. Xcode-only projects: distill
   the failing assertion into a minimal native snippet and run it (scratch
   package — the Examples/ExpenseTrackerNative pattern).
2. Classify by the native verdict:
   - passes natively, fails interpreted → GENUINE class: queue it, fix it,
     pin it with a unit test whose expectation is the NATIVE output (copy
     the value the compiler produced, never what the interpreter says).
   - fails natively too → upstream-broken: record it in the TestCheck
     Ledger below and never count it against the metric.
   - can't run natively headlessly (device, keychain, network, UI) →
     environmental; deprioritize below any genuine class.
3. `UIKitStub`-vs-`UIKitStub` comparisons inside failure messages are the
   absorbed environment talking (Date/Calendar/NSImage stubs), not
   semantics — environmental by default.

Scoreboard: per-suite `passed/failed/errored`; passed counts on touched
suites are strictly-improving, and tests are never skipped to go green.
First pilot baseline (8 smallest OSS suites, 2026-07-09): 6 ran — 75
passed / 51 failed / 18 errored. Seed classes awaiting native baselines:
ControlRoom's subcommand argument arrays lose their static prefix and
`.arguments` on payload-carrying enum cases resolves as a marker; Maccy's
String-index / remove(at:) range traps and sort-comparator order;
OnlineStoreTCA's missing synthesized `init(from: Decoder)`.

**Third queue: `swift run LiveCheck` — live-data fidelity.** The road to "a
real networked app shows real data" (MovieSwiftUI posters, IceCubes' public
timeline). Scenarios run with the network in REPLAY mode: URLSession serves
RECORDED real API responses from `Fixtures/` matched by URL path
(host-independent), so the metric stays deterministic. `NetworkPolicy` has
three modes and one hard rule:
- `.absorbed` (default) — ProjectCheck/TestCheck always run here; nothing
  about their doctrine changed.
- `.replay(fixturesDirectory:)` — the ONLY mode LiveCheck's metric may use.
- `.live` — real HTTP for interactive demo runs (a human at the window),
  never in a metric, never in the loop.

Fixture rules: fixtures are real responses captured once by a human (curl /
a future `--record`), never edited by hand — they are the network's native
baseline. Assertions derive expected content FROM the fixture (movie titles,
status authors) and check it reaches decoded models and rendered trees.
Structural JSON decode (JSONDecodeBridge) maps stored properties via
CodingKeys → exact → snake_case and instantiates memberwise; custom
`init(from:)` bodies do NOT run — a documented divergence to burn down with
real Codable synthesis when the histogram demands it.

**Rung scoring (the metric).** Each scenario is an ORDERED ladder of rungs —
decode → strings-in-tree → nonblank pixels → interaction (tap a row, its
detail shows fixture content). The LiveCheck metric is TOTAL RUNGS passed
across scenarios, strictly improving; a fix that moves a scenario from
"117 strings of chrome" to "titles in the tree" counts even though the
scenario isn't fully green. Sub-rung progress goes in the histogram, not
the score.

**Cost & flakiness budget (hard rules).** A full LiveCheck run must stay
under ~3 minutes wall-clock and be deterministic run-to-run:
- per-scenario hard timeout (120s) — a scenario that can't fit is split or
  simplified, never retried-until-green;
- assertions use only fixture-derived substrings, counts, and a BLANKNESS
  threshold on renders (mean brightness) — never pixel-exact images, never
  wall-clock-dependent strings (relative timestamps), never ordering that
  the fixture doesn't pin;
- replay serves recorded bytes and DETERMINISTIC placeholder images (a
  generated solid PNG) for image requests — no network, no randomness;
- flaky-by-design surfaces (streaming, push, animations mid-flight) are out
  of the metric; they belong to the human live gate.

**The live gate (acceptance, human-run, not a metric):** with `--network
live`, the demo window shows a REAL feed — MovieSwiftUI: popular-movie grid
with titles and poster images, tap pushes a detail with overview; IceCubes:
a public Mastodon timeline with authors and readable text, scroll works,
tap pushes a status detail. OAuth/login flows are OUT OF SCOPE (quarantine
class: auth) — public/unauthenticated data only.

**Doctrine fork (recorded, to implement when the histogram demands):**
absorbed mode keeps iter-71 semantics (Combine pipelines never emit). In
replay/live modes, pipelines rooted at `$published` deliver SYNCHRONOUSLY on
write (debounce collapses to immediate) — otherwise completion-based apps
whose data flows through publishers can never become functional.

Baseline (2026-07-09): **2/4 scenarios pass** (mastodon-fixture-decode,
tmdb-fixture-decode — the full decoder pipeline works). Open classes:
- movieswiftui-popular-ui: 0 strings rendered — the fetch path
  (`.task`/onAppear closures) never fires during deep-render, so no data
  reaches the tree.
- icecubes-timeline-ui: renders 117 strings of chrome but no fixture
  authors — the same async-fetch wall plus whatever hides behind it.
- replay wildcards: parameterized paths (`/api/v1/statuses/:id`,
  `/3/movie/:id`) must match fixtures with `_` wildcard segments — needed
  for every detail-view rung. [DONE]
- movieswiftui-popular-ui: the probe now evaluates the app's DECLARED
  composition root (StoreProvider(store:) { Tabbar… }); the blocker is the
  EXTERNAL state container — SwiftUIFlux's Store/StoreProvider/dispatch
  absorb, so no state flows. Class: vendored-library gateway for the
  Redux-store shape (Store.state + dispatch → reducer → objectWillChange).
- icecubes-timeline-ui: root AppView correct, 9 lifecycle closures fire;
  the timeline fetch dies in the Client-actor path — actor methods must
  execute (inline-async semantics) for the fetch to land.

## TestCheck Ledger

(upstream-broken or natively-unrunnable tests, with the native verdict —
keep short; these never count against the metric)

## The iteration algorithm (never invent the next step)

Each iteration does exactly this:

1. **Health check**: `swift test` (~100 tests). If red, fix that first — the
   suite is never weakened, tests are never deleted to go green.
2. **Measure**: `swift run ProjectCheck --limit N` (N grows over time; start
   25, raise when the current window passes ~80%). Read the failure-class
   histogram. ALSO run the cheap queues every iteration: `swift run
   LiveCheck` (~minutes, deterministic) and, when its classes or
   ProjectCheck's top class point at semantics, `swift run TestCheck
   --limit N` with the native-baseline rule.
3. **Pick the single biggest failure class** (most projects blocked). If two
   tie, pick the one that's an interpreter-language gap over a gateway gap.
   When ProjectCheck's histogram is all-singletons or a known wall, a
   LiveCheck rung class or a native-verified TestCheck class outranks
   render singletons — functional-app progress beats breadth.
   SATURATION OVERRIDE: when ProjectCheck counts ZERO failures in its
   window, "most projects blocked" stops being the metric — the biggest
   class is the TOP OPEN LiveCheck/TestCheck class (step-9 queue, oldest
   first), and new-material arrival-passes do NOT count as a fixed class.
   M0 breadth is done; the mission ladder (M2/M3) is the metric now.
4. **Classify and fix properly** (no per-project hacks):
   - *Language gap* (unsupported syntax/semantics) → implement in
     `Sources/SwiftInterpreter/` following existing evaluator patterns.
   - *Missing view/modifier/type* → prefer teaching BridgeGen a coercion or
     mapping and regenerate (`swift run BridgeGen --emit`); hand-write in
     `ViewGateways`/`ModifierGateways` only when generation can't express it.
   - *Missing MEMBER on a host native* (a Foundation/SDK value's property or
     method absorbs or errors) → this is a GENERATED-MEMBERS gap, not a
     hand-box job. Read the demand signal first: LiveCheck failure messages
     print the absorb histogram (`absorbed: Type.member×N`), and
     `Interpreter.absorbedHostMembers` carries it programmatically. Then fix
     in BridgeGen's member sweep (`Sources/BridgeGen/main.swift`): add the
     type to `memberTypes`, add a `memberMapping` entry + `ParamTag` coercion
     for a blocked parameter type (report mode prints the member-blocking
     histogram), or lift a sweep filter — and regenerate with `swift run
     BridgeGen --emit`. Write a NEW hand box only for semantics generation
     can't express (write-back mutation, stateful boxes like URLSessionBox);
     if the core's `nativeMember` already hand-serves a member the sweep would
     emit, pin it in `denyMembers` instead of shadowing it.
   - *iOS-only / platform-impossible API* (UIKit interop, UIScreen…) → add a
     minimal inert stub if cheap and honest (renders something reasonable),
     otherwise record the project name + reason in the Quarantine section
     below. Quarantine is a last resort and never used to inflate pass rate.
5. **Add regression coverage**: a corpus program under
   `Tests/SwiftUIBridgeTests/Corpus/` or a unit test that captures the fixed
   class. New capability without a test doesn't count.
6. **Verify**: full `swift test` green AND ProjectCheck pass count strictly
   improved (or same count with the histogram's top class eliminated).
7. **Commit** with the failure class named in the message.
8. **Update the Progress log below** (date, pass rate, what was fixed). Keep
   entries to one line.
9. If ProjectCheck passes everything in the current window: raise `--limit`
   (25 → 50 → 100 → … → --all). When the local ladder is exhausted, check
   the OTHER queues BEFORE reaching for new material: an open LiveCheck rung
   class (M2/M3) or a native-verified TestCheck class outranks material
   expansion — new-material hunts (GitHub apps, 10–40 files, stars > 100,
   cloned into `External/oss/<name>`) are the fallback when LiveCheck and
   TestCheck have no actionable class either, and at most every THIRD
   iteration otherwise. Never fabricate passing material. The async-fetch
   class is CLOSED (lifecycle closures fire in the probe; pinned by
   AsyncFetchProbeTests). Current standing queue, oldest first — these ARE
   actionable classes, so material hunts don't resume until they close.
   CLAIMS: two agents work this repo (the ralph loop and the steering
   worktree (штурман)). Before STARTING a queue item, prepend `[CLAIMED <agent>
   <HH:MM>]` to its first line (loop: edit in your iteration commit;
   steward: via the worktree merge). Skip items with a fresh claim;
   claims older than ~2 hours are stale and free. Three duplicate
   implementations happened on 2026-07-10 (decoder stubs, generics,
   flux) — claims are cheaper:
   1. [DONE iter 199] `.modifier(m)` member spelling runs interpreted
      ViewModifier bodies (strict shape + environment injection).
      (State identity note: per-identity @State persistence is OPT-IN
      via `Interpreter.persistentViewState` — LiveCheck sets it; M0
      probes keep fresh-per-instantiation state, see README divergence.
      `URLSessionBox.webSocketTask` still absorbs — stateful hand-box
      gap, the histogram will resurface it.)
      (Also landed alongside: assignment targets thread their declared
      type as the call-site annotation — `statuses = try await
      client.get()` binds Entity; bare type names inside a type prefer
      NESTED types over globals — Instance.statuses: Statuses is the
      config struct, not the endpoint enum; api_v2_instance fixture
      recorded, /api/v2/instance hits.)
   2b. [DONE iter 198/200] `as?` strict-nil on definite interpreted
      mismatches (transitive protocol inheritance; class up/downcasts;
      pinned by CastFalsePositiveTests).
   3. [DONE iter 200] @Query/@FetchRequest read the live model store
      each render (Wrapper.query + per-render refreshQueries;
      QueryLiveStoreTests — insert taps become visible rows).
   3b. [DONE штурман 18:3x] STDLIB CONTAINER MEMBERS absorb at scale (histogram audit
      2026-07-10 ~18:00; scenarios PASS but the semantics read
      fresh-falsy): movieswiftui absorbs DictValue.contains ×184,
      DictValue.filter ×18, Array<RuntimeValue>.append ×18
      (member-position), DictValue.compactMap ×6 — OUR containers, so
      the fix is nativeMember stdlib-table entries, NOT the generated
      swiftinterface tier (its sweep serves SDK types only). Minor tier
      items from the same audit: URLSessionBox.webSocketTask (stateful
      hand box), URL.resourceValues (throws — sweep-filtered; consider
      a do/catch-wrapping emit policy for throwing members).
      RESOLUTION: Dictionary Collection members land in nativeMember —
      contains(where:)/filter/compactMap/map/sorted(by:) over native
      (key:, value:) tuple elements (DictEnumeratedTests). Post-fix
      histogram: only Array.append (member-position) + webSocketTask +
      URL.resourceValues remain.
   4. TestCheck classes (native-baseline rule first; scoreboard
      2026-07-10 @ --limit 8: 79 passed / 52 failed / 12 errored).
      Top exemplar: clean-architecture-swiftui LoadableTests.map —
      generic enum method (`Loadable<Int>.map → Loadable<String>`),
      optional-map with rethrows, conditional-conformance `==`, and
      array-of-enums equality. Behind it: FreeChat PromptTemplateTests
      (a template STRING computes to a raw UIKitStub — find which host
      member returns the stub), Milestones Comparable/reducer classes,
      ControlRoom subcommand arrays, Maccy String-index/sort,
      OnlineStoreTCA Codable synthesis.

## Rules

- **Model & attribution**: the loop is intended to run on **Claude Fable 5 at
  xhigh reasoning effort** (session-level settings — `/model` and `/effort`;
  the loop cannot change them itself). Every commit made by the loop MUST
  record who made the change with a trailer line before Co-Authored-By:
  `Model: <model name> (<model id>), effort=<effort>`.
- Small commits, one failure class each. No drive-by refactors.
- Hand-written gateways stay authoritative over generated ones.
- Semantic divergences (reference-backed structs, positional identity, etc.)
  are documented in README.md, not silently extended. If a fix requires a NEW
  divergence, document it in the same commit.
- The step budget, located errors (`line:col`), and headless verifiability
  are invariants — don't trade them away for pass rate.
- **Stale-build gotcha**: after changing the layout of a public core type
  (e.g. adding a field to RuntimeError), `touch` dependent sources
  (SwiftUIBridge, ProjectCheck, tests) before trusting results — SwiftPM's
  incremental build has linked stale objects twice (once a link error, once
  a SIGBUS with garbage error output).
- Known deep walls, in preferred order when the ladder forces them:
  `@Environment` values (dismiss, colorScheme…) → value semantics for structs
  → protocols/generics in interpreted code → async/await → `@main App`/scene
  shell → Foundation breadth (Date formatting, Timer, URLSession stubs).
  Don't start one preemptively; wait until it's the top failure class.

## Mission ladder (functional parity with Xcode builds)

The end state: any GitHub SwiftUI project launches and FULLY functions as
if compiled in Xcode. Milestones, each with its measuring queue:

- **M0 Renders** — ProjectCheck (deep-render + clicks). [~97%: keep gated
  window raises as before]
- **M1 Computes** — TestCheck: the project's own tests pass interpreted,
  native-baseline verified.
- **M2 Live data** — GREEN 2026-07-10: LiveCheck 4/4 (icecubes + movieswiftui
  full launch chains). Breadth grows by adding scenarios; the rung ladder:
  fetch → decode → strings in tree →
  nonblank pixels.
- **M3 Interactive persistence** — in-session data is REAL: insert →
  query returns it, tap a row → its detail renders that row's data, state
  survives navigation. (LiveCheck interaction rungs + doctrine below.)
- **M4 App-shell parity** — the real `@main App`/Scene body runs: its env
  objects seed the tree (no synthesized stand-ins), the App's own root
  replaces root-selection, onOpenURL/WindowGroup semantics.
- **M5 Semantic parity** — the documented divergences burn down (value
  semantics for structs first); TestCheck failure classes against native
  baselines trend to zero.

**Milestone weighting (amends step 3 "pick the single biggest class"):**
within a queue, size wins as before. ACROSS queues, a class that unblocks
the LOWEST-numbered unfinished milestone outranks a bigger class that only
polishes an already-saturated one — e.g. the async-fetch class (M2)
outranks five M0 render singletons. M0 saturation sweeps remain the health
backstop, not the main line, once its histogram is all-singletons.

**Doctrine v2 status:** ModelContext insert/delete/save/fetch/fetchCount
back a LIVE per-Interpreter store (LiveModelStore; runs start empty —
deterministic; pinned by LiveModelStoreTests). REMAINING named class:
@Query/@FetchRequest boxes still flatten to a static `[]` — they must read
the live store and refresh on store writes (flatten-site + state-adoption
semantics, core-shaped work).

**Doctrine upgrade — live fresh stores (M3, replaces fresh-EMPTY):**
@Query/@FetchRequest/@ObservedResults-shaped wrappers and ModelContext
insert/delete/save now back onto a LIVE per-run in-memory store: what the
interpreted UI writes, its queries read back. Determinism holds (every run
starts empty); ProjectCheck click-through becomes MORE honest (an added
row appears and can be clicked). Implement bridge-side; document in README
as fresh-store doctrine v2. Todo/notes-genre apps are not "functional"
without this.

## Quarantine

(projects excluded from the metric, with reasons — keep short)

(empty — all three historical quarantines fell in iteration 184:
isowords via `>=>` Kleisli composition after macros/TCA/C-interop
machinery matured, and the Realm pair via capability that accumulated
between iterations 35 and 183.)

## Progress log

- 2026-07-09: Loop bootstrapped. Corpus (12 programs) + 97 unit tests green.
  ProjectCheck baseline over smallest 25 real projects: **1/25**. Top classes:
  top-level `#Preview` as expression (12), `Bool.toggle()` (3), get/set
  computed properties (3), `UIScreen.main` (2), `Color.black` static (2).
- 2026-07-09 iter 1: statement-position `#Preview` (MacroExpansionExpr) made
  inert — 12-project class eliminated; **1/25 → 3/25**. Next top classes:
  `Bool.toggle()` (3), get/set computed properties (3), statics on host types
  like `Color.black` (2+2 related).
- 2026-07-09 iter 2: `Bool.toggle()` via the lvalue path (state notification
  fires); **3/25 → 7/25**. Next: get/set computed properties (3), member
  access on host-type functions (`Color.black`, `String.…`, ~4 related).
- 2026-07-09 iter 3: settable computed properties (get/set accessors, custom
  setter param names, compound assignment through getter+setter; observer-only
  bindings are stored+inert, documented). Class eliminated; **7/25 → 7/25**
  (freed projects hit next blockers). Noted for later: Int literals don't
  promote to Double-annotated storage. Next: host-type static members
  (`Color.black` family, ~5 across variants).
- 2026-07-09 iter 4: host-type static members — unknown uppercase identifiers
  become HostTypeMarker; member access on markers/host constructors yields
  implicit members (`Color.red` ≡ `.red`), calling a marker is a clear located
  error. Trace registry's generic recorder is uppercase-only (lowercase
  unresolveds error truthfully) with an explicit withAnimation case.
  **7/25 → 9/25**.
- 2026-07-09 iter 5: GeometryReader/TimelineView proxy closures — the 4-project
  class behind `$0`/`proxy`/`timeLine` failures. Real gateways evaluate content
  at layout time with the real proxy (errors → RenderDiagnostics + EmptyView);
  trace uses honest stubs (390×844). New `hostMember` registry hook serves
  GeometryProxy/CGSize/CGRect/CGPoint members as Doubles, frame(in:) coerces
  coordinate spaces. GeometryCard corpus program added. **9/25 → 10/25**.
- 2026-07-09 iter 6: host static chains — the bridge intercepts type markers
  AND host constructor functions via hostMember: `UIScreen.main.bounds` maps
  to the real screen frame, `DispatchQueue.main.async` defers interpreted
  closures via a main-actor Task (GCD's queue never drains under swift test).
  **10/25 → 12/25**. Noted next: `.init()` in annotated positions (2 projects),
  colorScheme `@Environment` comparison (1).
- 2026-07-09 iter 7: annotated implicit members for structs/classes —
  `: T = .init(...)` instantiates, `.factory()` dispatches static methods,
  bare `.staticValue` resolves, and `[T]` annotations resolve array elements
  (covers `(1...8).map { .init(...) }`). **12/25 → 14/25** (56% of window;
  --limit stays 25 until ~80%).
- 2026-07-09 iter 8: memberwise trailing closures — unlabeled trailing closure
  binds to the last closure-shaped stored property; `@ViewBuilder var content`
  stores the BUILT view (Swift's synthesized builder-memberwise semantics).
  The 3-project `argument '_'` class eliminated; **14/25 holds** (all three
  advanced to deeper blockers). CustomContainer corpus added. Next: bare
  Color implicit members in view position (`.clear`/`.black`, 2).
- 2026-07-09 iter 9: nested type declarations — enums/structs inside types
  collect into `nestedTypes`, register under `Outer.Name` (annotations) and
  the bare name when unclaimed (in-scope refs); `.type` member access serves
  them. `DockProgress.ProgressType.linear` patterns work. **14/25 → 15/25**
  (60%). Remaining classes are all singletons: parameterized closure props,
  Color-as-view, doStmt, String.startIndex, colorScheme compare.
- 2026-07-09 iter 10: parameterized @ViewBuilder closure properties —
  function-typed annotations (`(CGSize) -> Content`) store the closure at
  memberwise init instead of pre-building; the body's `content(size)` call
  builds. SizedBox added to CustomContainer corpus. **15/25 holds**; class
  eliminated (ScrollParallax → `proxy.bounds(of:)` next; Canvas's identical
  message is really the GraphicsContext wall).
- 2026-07-09 iter 11: Colors as Views — `Coerce.colorLike` (bare `.black`,
  `Color.clear`, `.opacity` chains) accepted by both registries' isViewValue/
  anyView/node paths; view modifiers route on implicit-member bases
  (`Color.black.ignoresSafeArea()`), while `opacity`/`gradient` stay style
  chains. **15/25 holds**; class eliminated — both projects advanced (`round`
  builtin, dynamic range bounds are next-up singletons).
- 2026-07-09 iter 12: `@Environment(\.key)` values — the first known wall.
  Wrapper carries the key path; InterpretedView injects real reads
  (colorScheme, dismiss) before body; headless harnesses inject honest
  defaults (light, no-op dismiss) via InterpretedEnvironment.defaults().
  Table is extensible per-key. **15/25 → 16/25** (64%).
- 2026-07-09 iter 13: do/catch/throw/try/try?/try!/await — interpreted throws
  deliver their value to the catch binding; non-fatal host errors arrive as
  message strings (`.localizedDescription` works); budget errors are fatal and
  uncatchable; `await` evaluates inline (documented divergence). Also learned:
  stale incremental objects after core-type layout changes cause garbage
  crashes — rule added. **16/25 → 17/25** (68%).
- 2026-07-09 iter 14: math builtins (round/floor/ceil/sqrt/pow, joining
  abs/min/max). **17/25 holds**; class eliminated — Custom_Indicators advanced
  to `getWidth`, exposing interpreted `extension View { func … }` helpers as
  the real next class (host-protocol extensions currently skipped).
- 2026-07-09 iter 15: interpreted extensions of host types — `extension View`/
  `String`/`Int`/`Double` members collect into synthetic symbols, resolved on
  view values, view-conforming instances (implicit self), and native selves.
  Removing the silent skip made BlurredSheet_Updated execute deeper code,
  which forced two more condition kinds in the same iteration: `if case`
  pattern conditions (rides the switch matcher) and `#available` (passes on
  latest-SDK host). **17/25 holds — more honestly than before.**
- 2026-07-09 iter 16: writable host members — new hostSetMember/
  hostObjectConstructor registry hooks + LValue.hostProperty, with
  DateFormatterBox (real Foundation formatter: dateFormat get/set,
  string(from:), date(from:)) as the first user, shared by both registries.
  **17/25 holds**; the "cannot assign to host member" class is eliminated
  (DateTextField advanced into its closure-argument plumbing).
- 2026-07-09 iter 17: UIKit/AppKit representables — `*Representable` structs
  are accepted in view position (incl. modifiers on their instances) and
  render inert in both registries (make/update never run — documented).
  **17/25 → 18/25** (72%).
- 2026-07-09 iter 18: Timer publishers — `Timer.publish(every:on:in:)
  .autoconnect()` yields a box wrapping the REAL Combine publisher;
  `.onReceive` drives interpreted closures from actual ticks (trace records
  the modifier inert). AnimatedCounter corpus ticks a session counter.
  **18/25 → 19/25** (76% — one from the 80% window raise).
- 2026-07-09 iter 19: UIApplication window chain — `shared` → app stub,
  `windows` → one-window array, `safeAreaInsets` → zero EdgeInsets (honest
  macOS analog), EdgeInsets components as Doubles. Custom_Indicators passes
  after its 4-iteration march. **19/25 → 20/25 = 80% → window raised to
  --limit 50. New baseline: 25/50**; top classes: GeometryProxyStub members
  (4: minX/bounds family), $-projection on non-state (2), ImplicitMemberCall
  members (2), host statics (2).
- 2026-07-09 iter 20: GeometryProxy.safeAreaInsets + bounds(of:) on both the
  real proxy (NamedCoordinateSpace coercion, optional CGRect) and the stub
  (zero insets, canvas rect). 4-project class eliminated; **25/50 → 27/50**.
- 2026-07-09 iter 21: type context for statics, host inits, and mutating-array
  payloads — static properties keep their annotations (`static let samples:
  [Item] = [.init(...)]`); host-type annotations construct via host object
  constructors/global builtins (`: Date = .init()`, CGSize/CGPoint added,
  `Date.now`); `items.append(.init(...))` resolves against the target
  property's `[Type]` annotation. **27/50 → 28/50**; ShaderExample passed,
  the others advanced deeper.
- 2026-07-09 iter 22: state-like wrappers (@AppStorage/@SceneStorage/
  @GestureState/@FocusState) flatten to @State — bind, project, persist via
  StateStore; special semantics skipped (documented). All three class
  projects pass incl. DateTextField's five-iteration arc.
  **28/50 → 31/50** (62%). Next: `Type.self` statics (2).
- 2026-07-09 iter 23: universal `.self` (the value itself — Swift semantics),
  unblocking the PreferenceKey idiom (`.preference(key: SizeKey.self, …)`,
  trace-recorded). **31/50 → 33/50** (66%).
- 2026-07-09 iter 24: CG numeric type context — `CGFloat(x)` global builtin
  (our CGFloat model IS Double) and `.zero` statics for CGSize/CGPoint/CGRect
  via the marker path (covers `: CGSize = .zero` annotations). DropDown and
  MarqueeText pass. **33/50 → 35/50** (70%).
- 2026-07-09 iter 25: implicit members adopt the OTHER operand's host type in
  ==/!= (`dragOffset == .zero` resolves .zero as CGSize via the marker path);
  CG equality cases added. TouchAnimation passes. **35/50 → 36/50** (72%).
- 2026-07-09 iter 26: as/as?/as! casts — target type resolves markers via
  resolveAnnotated, Int/Double bridge, optimistic as? (nil only for nil;
  documented). AppStub gains connectedScenes/WindowSceneStub (screen,
  keyWindow). **36/50 holds**; CustomHUDs advanced to rootViewController —
  the UIKit hosting wall, possible quarantine candidate.
- 2026-07-09 iter 27: wrapper backing storage — `self._offset = offset` in
  custom inits canonicalizes `_x` → `x` (binding-stub swap included), and
  `State(initialValue:)` constructs as its value. Write-through verified:
  child button mutates parent state via assigned storage. Custom_ScrollView
  passes (156-node render). **36/50 → 37/50** (74%).
- 2026-07-09 iter 28: collection/Bool extensions — sugar-typed `extension
  [Item]` keys match array candidates alongside `extension Array`; implicit
  self on native values consults native members first (bare `count`/
  `firstIndex` inside extension bodies). StackedCards passes.
  **37/50 → 38/50** (76%).
- 2026-07-09 iter 29: BindingStub.wrappedValue — reads return the box value,
  writes go straight through the box (projectedValue returns the stub).
  PopUpNavigation passes. **38/50 → 39/50** (78% — one from the 100-window).
- 2026-07-09 iter 30: the Foundation date pipeline + crash guard. Format
  styles (`formatted(date:time:)`), plain assignments adopt property
  annotations (`self.amount = .random(in:)`), Double/CGFloat/Int `.random`
  statics, real-Calendar box (`Calendar.current.date(byAdding:value:to:)`,
  startOfDay, component) accepting `.now`/`.random` gateway args.
  CustomFileExtension passes → **40/50 = 80% → window raised to 100**.
  First 100-run SEGFAULTED (interpreted recursion overflows the native stack
  before the step budget) → call-depth guard (200, fatal, uncatchable) in
  calls and computed properties. **New baseline: 60/100.** Top classes:
  parameterized closures w/o data (7), member-on-void (6), appearance-proxy
  assigns (4).
- 2026-07-09 iter 31: label-aware parameter binding (the declared load-bearing
  lie, finally forced): labeled args match parameter labels, omitted MIDDLE
  defaults fall back correctly, positionals fill unlabeled params, the
  unlabeled trailing closure binds to the LAST unbound parameter. Plus
  ScrollViewReader (real proxy.scrollTo / no-op stub), joining the reader
  family. "missing argument" 7 → 4 (Canvas wall remains).
  **60/100 → 64/100** (64%).
- 2026-07-09 iter 32: uninitialized optionals are nil (real Swift semantics) —
  `var view: UICollectionView?` without initializer defaults to nil in stored
  properties AND locals, so optional chains propagate instead of dying on
  void. **64/100 → 66/100**. Remaining void-member subroots: unknown
  @Environment keys (modelContext → SwiftData), third-party wrappers
  (@ObservedResults/Realm — quarantine candidate).
- 2026-07-09 iter 33: UIKit appearance proxies — `X.appearance()` on any host
  marker yields an inert stub: writes accepted-and-ignored, config calls
  chain (`.standardAppearance.configureWithOpaqueBackground()`). Platform-stub
  doctrine, documented. **66/100 → 68/100**.
- 2026-07-09 iter 34: recursive marker chains — ChainedImplicitCall.base is
  now the full previous marker (not a bare name), member access on
  ImplicitMemberCall/ChainedImplicitCall extends the chain instead of
  throwing, and Coerce.animation folds combinator chains
  (`.easeInOut(duration:).delay(0.2).repeatForever(...)`, `.speed`,
  `.repeatCount`); colorLike/shapeStyle resolve chain bases recursively
  (`.blue.opacity(0.3).gradient`). Kills the 4-project "unsupported member
  on ImplicitMemberCall" class: CustomTabBar + ScrollParallax pass,
  3DGestureCard shifts to arithmetic-on-marker, MoreTabBar (.init-as-view)
  remains. **68/100 → 71/100**.
- 2026-07-09 iter 35: the member-on-void class (4) — store-shaped roots.
  `@Environment(Type.self)` ≡ @EnvironmentObject keyed by a synthesized type
  annotation + `.environment(model)` gateway in both registries (Observation
  idiom); `@Query`/`@ObservedResults` flatten to @State over a fresh-store
  `[]`; `@Environment(\.modelContext)` yields an inert ModelContextStub
  (insert/delete/save no-op, fetch empty); `$results.append/remove` write
  through the binding box. ObservationEnv + NotesStore corpus programs.
  PaginatingSwiftData + SwiftTransformer pass; NetflixUI pair advanced past
  env into a view-position marker class; SwiftUIRealm advanced to Realm
  ObjectId internals (quarantine candidate if it tops). **71/100 → 73/100**.
- 2026-07-09 iter 36: MapReader joins the reader family — content deep-renders
  with a MapProxyStub whose `convert(_:from:)` is honestly nil (no map exists
  headlessly; MapKit never imports). DraggableMapPin passes; the "missing
  argument" class shrinks 3 → 2 (Canvas = the GraphicsContext wall, Chips_UI =
  String text-measurement overload vs user extension — both single-project
  roots). **73/100 → 74/100**.
- 2026-07-09 iter 37: the String-member class — real text measurement +
  String.Index basics. `str.size(withAttributes:)` dispatches through a
  call-label-aware hook in specialMemberCall (user `size(_ font:)` extensions
  keep winning plain member access — the Chips pattern), measured bridge-side
  with real NSFonts mapped from UIFont markers (systemFont/weight/
  preferredFont(forTextStyle:)); startIndex/endIndex/index(_:offsetBy:)/
  distance(from:to:) join the String natives. Class eliminated: MarqueeText
  passes, Chips_UI advanced to a custom-Layout blocker, TextSelectionAPI
  advanced to a Bool-operand singleton. **74/100 → 75/100**.
- 2026-07-09 iter 38: the "() is not callable" class — two roots. Memberwise
  multiple-trailing-closure binding is now two-pass: labeled arguments claim
  their properties first, then unlabeled trailing closures fill remaining
  closure-shaped properties in DECLARATION order (SE-0286 forward scan) —
  `CustomButton(tint:) { content } action: {…}` binds correctly. Env action
  keys openWindow/dismissWindow/openURL are honest no-ops (no scene shell);
  AppStub gains inert terminate + mainWindow/keyWindow, WindowStub gains
  close (click-through fires Quit buttons — terminating the host is not an
  option). MultiWindowApp passes; AnimatedButton advanced to closure
  return-type annotation threading. **75/100 → 76/100**.
- 2026-07-09 iter 39: host-object property bags in trace — opaque constructed
  objects (UIPanGestureRecognizer() → generic TraceNode) now behave like the
  mutable objects they stand for: member writes land in node.config and read
  back (`gesture.name = id … gesture.name ?? ""` round-trips). Kills the
  "cannot assign on TraceNode" class; both FullScreenPop variants pass.
  **76/100 → 78/100**.
- 2026-07-09 iter 40: non-builder trailing closures on unknown constructors
  degrade to recorded configuration — the Lottie idiom (`LottieView { await
  LottieAnimation.loadedFrom(url:) }` loads data, not views) no longer fails
  the builder; genuine nested errors still propagate (fatal + non-view-shape
  guarded). Both NetflixUI units pass after their 3-iteration march, and
  MoreTabBar's `.init(value:)-as-view` rode the same shape. Only known walls
  (Canvas GraphicsContext, Chips_UI Layout) + singletons remain.
  **78/100 → 81/100**.
- 2026-07-09 iter 41: the Canvas wall, taken inert — `Canvas { context, size
  in }` runs the renderer with a no-op GraphicsContextStub + 390×844 size in
  BOTH registries (drawing never reaches a surface — documented divergence);
  `Path { path in }` builders execute against an inert PathDrawStub; Date
  gains timeIntervalSinceReferenceDate, Double gains remainder/
  truncatingRemainder(dividingBy:). WaveCanvas corpus program (Canvas + Path
  + Slider, real-hosted). Canvas passes; the class's other member (Chips_UI)
  is the Layout-protocol wall. **81/100 → 82/100**.
- 2026-07-09 iter 42: window raised 100 → 200 (82% ≥ 80%). New baseline
  142/200 (71%). Top class "has no member" (8) = user Shape structs hitting
  .fill/.stroke/.trim. StructSymbol.conformsToShape; instance member access
  falls back to modifiers for shapes; makeRenderable wraps them shape-typed —
  real side ShapeBox(InterpretedShape) whose nonisolated path(in:) calls the
  interpreted method via MainActor.assumeIsolated, PathDrawStub now
  accumulates a REAL Path (move/addLine/addCurve/addQuadCurve/addArc/addRect/
  addEllipse/closeSubpath), so user shapes draw actual geometry; trace side
  executes path(in:) against the standard rect and records inert. New public
  Interpreter.callMethod(named:on:arguments:). `.trim(from:to:)` hand
  modifier. CustomShapes corpus (fill/stroke/trim + state-driven redraw,
  real-hosted). 7 shape projects pass (WaterWave, SplashsAnimation, Glass,
  SegmentedControlAnimation, ScratchCard, Custom_Tab_Bar, Device_MockUp);
  the 8th (Tags) is a Layout — the protocols wall. **142/200 → 149/200**.
- 2026-07-09 iter 43: binding-collection ForEach — `ForEach($items) { $item
  in … }` iterates element bindings whose writes land back in the parent
  array (BindingStub.elementBindings, both registries); `$`-prefixed closure
  parameters also bind their bare name SHARING the binding's box (`item`
  reads live); `$item.field` projects field bindings via the instance's own
  box (Binding's @dynamicMemberLookup semantics). ChoreBoard corpus
  (Toggle(isOn: $chore.done) + reset click-through). All 5 in-window class
  projects pass. **149/200 → 155/200**.
- 2026-07-09 iter 44: DispatchQueue.main.asyncAfter — the deadline anchor
  `.now()` absorbs into its numeric offset in +/- arithmetic (the seconds the
  gateway needs), and MainQueueStub.asyncAfter schedules the interpreted
  closure via a delayed main-actor Task (real firing, like async). All three
  class projects pass (ParticleEmission, RepeatButton, LiquidTransition).
  **155/200 → 158/200**.
- 2026-07-09 iter 45: ScreenStub gains visibleFrame/frame (real NSScreen when
  present, laptop-shaped rect headlessly) — the NSScreen.main?.visibleFrame
  class. CustomTabBarMac + Login_Mac pass; FloatingWindow advanced to
  arithmetic-on-unresolved `.init(x:y:)` marker (the chain-combine class).
  **158/200 → 160/200**.
- 2026-07-09 iter 46: the "missing argument" class — three roots, two fixed.
  (1) Label-mismatch retry: when a member call binds a user extension whose
  labels don't fit (binding fails BEFORE the body runs), the call retries
  through the modifier table — `extension View { func offset(coordinateSpace:
  …) }` no longer shadows the built-in `.offset(x:)` (HeaderAnimation).
  (2) KeyframeAnimator/PhaseAnimator content receives its initialValue/first
  phase as seed; GlitchEffect then exposed tuple-element lvalues —
  `@State var trigger: (Bool, Bool, Bool)` + `trigger.0.toggle()` — added
  LValue.tupleElement with write-through-base (state notifies). Chips_UI
  (Layout protocol) remains the wall. **160/200 → 162/200**.
- 2026-07-09 iter 47: nested enums resolve as bare identifiers — nested
  STRUCTS defined globals but nested ENUMS only landed in the annotation map,
  so `enum ChartType` inside ContentView fell to HostTypeMarker and
  `ForEach(ChartType.allCases)` got a marker. Registration now mirrors the
  struct path (Outer.Name + unclaimed bare name). Class eliminated; both
  AnimatedCharts advanced to `Date.createDate` extension statics in annotated
  positions (new class). **162/200 holds — top class eliminated.**
- 2026-07-09 iter 48: genericSpecializationExpr + computed bindings —
  `Binding<Int?>(get:set:)` evaluates its base (type args are unchecked
  annotations) and a Binding(get:set:) host constructor backs a BindingStub
  whose box snapshots get() per render pass and calls set(newValue) on
  writes. JSONWithPagination + HorizontalWheelPicker_Updated pass (the
  latter a 359-node render). **162/200 → 164/200**.
- 2026-07-09 iter 49: window raised 200 → 400 (82% ≥ 80%), new baseline
  283/400 (71%). Top class: subscripting (9) — two roots. (1) `$items[index]`
  → BindingStub.elementBinding(at:) write-through element bindings in the
  subscript evaluator; Array(repeating:count:) builtin joined (DarkMode's
  empty-toggles root). (2) AttributedString styling — real Foundation-backed
  AttributedStringBox: range(of:), s[range] proxies via a new host-subscript
  hook (registry hostMember "subscript"), foregroundColor/font attribute
  writes on ranges AND whole strings, Text(attributed) renders styled.
  WindowStub.isKeyWindow = true. StyledConsent corpus. LottieRatingBar,
  GlassMorphism, Split, LikedAnimation + ripple pass; GSignin/
  DarkModeAnimation advanced into UIKit window introspection, DownloadTask
  opaque, Cart/AnimationChallenge4 into marker-arithmetic.
  **283/400 → 290/400**.
- 2026-07-09 iter 50: the member-on-void class (7) — environment holes.
  Missing env objects synthesize one fresh instance per type (the App shell
  that would inject them never runs; ambient wins — fresh-store doctrine,
  documented); verify() now injects env objects at the ROOT too.
  `@Environment(\.self)` serves the whole values table via
  EnvironmentValuesStub (member reads hit the same defaults, real-side
  overrides included). `@FetchRequest`/`@SectionedFetchRequest` join the
  query-flatten family and `\.managedObjectContext` maps to the inert
  context. PopupImagePicker + InteractiveToasts ×2 pass (+ripple); TaskApp →
  CalendarBox class, IconGenerator → marker-compare, SwiftUIRealm stays
  (ObjectId). **290/400 → 297/400**.
- 2026-07-09 iter 51: the CalendarBox class (5) — real-Calendar breadth:
  dateComponents(_:from:[to:]) → mutable DateComponentsBox (member reads AND
  writes, plus a DateComponents() constructor), range(of:in:for:),
  month/weekday symbols, isDateInToday/Tomorrow/Yesterday/Weekend,
  isDate(_:inSameDayAs:), date(from: components). Fallout fixes with general
  value: STATIC COMPUTED properties (`static var x: T { … }`) collect into
  staticComputedProperties and evaluate with self = the TYPE (bare sibling
  statics resolve; staticMember rewritten symbol-based — the old inout cache
  caused an exclusivity crash on re-entry); user host-extension statics
  (`extension Date { static var currentMonth }`) resolve in annotated
  positions; Int gains promoting truncatingRemainder; Date joins
  hostCandidates (user Date-extension instance methods). SleepTime ×2,
  ElegantTaskApp, CustomScrollAnimation pass; TaskApp/AnimatedCharts
  advanced. **297/400 → 301/400**.
- 2026-07-09 iter 52: the "expected a Bool" class — @FocusState defaults.
  Uninitialized non-optional `@FocusState var x: Bool` synthesizes `false`
  (real SwiftUI semantics; optionals stay nil), and BindingStub joins
  hostCandidates so user `extension Binding { … }` members dispatch on
  projections ($otpText.limit(6)). AutoOtpTF, ExpandableSearchBar,
  Custom_Header pass (+ripple); ImageColorPicker ×2 remain (marker-typed
  extension dispatch on Color values — deferred), FaceID_Login is
  LocalAuthentication. **301/400 → 306/400**.
- 2026-07-09 iter 53: parameterized closures on unknown constructors are
  callbacks, not builders — recorded as configuration and never invoked
  (`SignInWithAppleButton { request in }`, `UIAction(…) { _ in }`); the
  generic recorder previously called them argument-less. Apple_Signin,
  AppleSignIn, CustomContentMenu pass (+ripple). The "missing argument"
  class is now purely the Layout-protocol wall (Chips_UI, LoopingCards).
  **306/400 → 311/400**.
- 2026-07-09 iter 54: lazy-forceable globals + static context in property
  initializers — the "unresolved identifier" class. Top-level identifier
  bindings hoist as LazyGlobal thunks (forward/cross-file references force
  on first read) while STILL executing eagerly in statement order unless
  already forced (main.swift sequential semantics preserved — first attempt
  broke 6 tests by going fully lazy). Property initializers evaluate with
  self = the type, so bare statics resolve (`Timer.publish(every:
  autoScrollDuration…)`). FacebookGradientMask, HeroNavigationStack,
  AutoScrollCarousel, WidgetsDemo pass. **311/400 → 315/400**.
- 2026-07-09 iter 55: conditional compilation — the harness identifies as an
  iOS-shaped canvas: os(iOS)/canImport/DEBUG/swift() hold, os(macOS)/
  targetEnvironment and unknowns take #else (documented; consistent with the
  UIKit-flavored stubs). Wired through all four positions: top-level
  (expandedTopLevelItems feeds collector + run), struct members, statements
  (control flow propagates), builders (active clause contributes views), and
  postfix modifier chains (PostfixIfConfigExpr grafts the base onto the
  active clause's chain). TabBars advanced (UIDevice chain), NotesMacOS +
  SharedLogin-Updated pass. **315/400 → 318/400**.
- 2026-07-09 iter 56: @Bindable locals — `$name` resolution consults scope
  LOCALS before the self property path: a local holding a model instance
  projects member bindings (ModelProjection), a local binding projects
  itself. `@Bindable var x = model; $x.activeTab` — the Observation binding
  idiom. TabBarSheet, CustomNavigationPopItems, ZoomTransitions pass.
  **318/400 → 321/400 (80.25% — next iteration raises the window to --all).**
- 2026-07-09 iter 57: window raised 400 → --all (80.25% ≥ 80%). Full-corpus
  baseline **431/587 (73.4%)**. Top class: doStmt in view builders (13) —
  imperative statements inside builder-evaluated closures (`.task { do { try
  await fetch() } catch {} }`) now execute for effect via executeStatement
  (explicit returns contribute views); do/guard/for/while all covered.
  Ride-alongs the class projects needed: `#selector(...)`/macro expressions
  evaluate as inert markers, AppStub.sendAction inert (keyboard dismissal).
  CompositionalLayout, EmailLogin, SocialMedia ×2 pass (+ripple).
  **431/587 → 444/587**.
- 2026-07-09 iter 58: the TraceNode-arithmetic class (7) — two big roots plus
  a chain of Foundation gaps behind them. (1) `Text + Text` concatenation:
  new HostRegistry.combineValues hook — trace records a TextConcat node,
  real approximates with a zero-spacing HStack (documented). (2) Formatter
  values leaking as nodes: real NumberFormatterBox (numberStyle/
  fraction-digit writes, string(from:)/number(from:)), NSNumber passthrough,
  Float builtin, String(format:) real formatting, `.init` on host
  constructor functions calls them, marker-tolerant date/number formatters,
  chained markers resolve in annotated positions (`.now.startOfMonth` runs
  the user Date extension), Calendar date() gains DateComponents-marker
  byAdding + bySettingHour forms. Image_Viewer, MovieAppUI, Food_App_UI,
  Cart, Fitness_DashBoard pass; the Expense series advanced deep.
  **444/587 → 450/587**.
- 2026-07-09 iter 59: query-wrapper CONSTRUCTORS are fresh-store empties —
  `_list = Query(descriptor, animation:)` in custom inits assigned a
  TraceNode over the flattened `[]` (Query/FetchRequest/SectionedFetch/
  ObservedResults ctors now return empty results); unknown store-query
  TraceNodes act empty for map/compactMap/filter/sorted/count/isEmpty (the
  realm.objects(...) reading). MinimalTodo, NotesApp, Task_Management ×2 +
  ripple pass; RealmDataBase/Expense EP5 advanced. **450/587 → 455/587**.
- 2026-07-09 iter 60: the superExpr wall, taken as inheritance-lite —
  StructSymbol.superclassName (first non-protocol inherited type); `super`
  evaluates to a SuperReference: interpreted parents dispatch methods/
  computed with self unchanged, host parents (NSObject…) make super.* inert.
  Ride-along general gaps the same chains hit: IUO annotations (`Track!`)
  seed nil; marker comparisons are name-based (authorization checks read as
  fresh-system-state false); member WRITES on markers are inert
  (`manager.delegate = self`); break/continue execute in builder position.
  ShazamKitApp, CameraControlAPI, PomodoroTimer pass; LocationSearch pair →
  Combine $published pipelines, HeaderAnimation → window wall.
  **455/587 → 470/587 (+15 — the marker fixes rippled corpus-wide).**
- 2026-07-09 iter 61: the UIKit window/app surface (WindowStub 6 + AppStub 6,
  sibling classes). New HostRegistry.hostTypeName hook: stubs name the host
  type they stand for (AppStub → UIApplication, trace nodes → their
  constructor kind), so user `extension UIApplication { … }` members dispatch
  on stubs; bare host members resolve as implicit self inside those extension
  bodies. window.rootViewController opens a UIKitStub island — memoized
  chainable reads, round-tripping writes, InertCallable calls (present/
  dismiss inert). AppStub gains canOpenURL (true — schemes resolve on real
  devices) + open (inert). GSignin, DarkModeAnimation, MultiLogin ×2,
  InAppNotifications, LinkPreview ×2, Signal_ImagePicker, DLogin,
  DynamicProgressView pass. **470/587 → 481/587 (81.9%)**.
- 2026-07-09 iter 62: optional-binding pattern breadth — `if let _ = x`
  (wildcard AND expression-pattern-wrapped discard: presence check, no
  binding) and `if let (a, b) = pair` (tuple destructuring via TuplePattern
  or expression-pattern tuples of unresolved names/pattern exprs).
  ImageRenderer-PDF, MapRoutes, 3DCardAnimation, HabitTracker pass;
  ImageDrawing advanced. **481/587 → 485/587**.
- 2026-07-09 iter 63: Double division follows IEEE 754 — x/0 is ±inf, 0/0 is
  NaN, exactly like real Swift (the old always-throw was WRONG for doubles;
  Int division still traps). The stub canvas width 390 was cancelling
  hardcoded 390s in scroll-geometry ratios (`width / (width - 390)`).
  Filled, ScrollDetection, AppleWalletScroll, PinterestGridAnimation pass;
  TwitterProfileScrolling remains (honest Int-division trap fed a stub
  zero). **485/587 → 489/587**.
- 2026-07-09 iter 64: the String-member class (4) — the card-formatting
  genre. Mutating append (positional + contentsOf:) and insert(_:at:
  String.Index) through lvalues; enumerated() with (offset, element)-labeled
  tuples; count(where:) via the call-aware hook (the property keeps winning
  plain .count); components(separatedBy:); forEach over characters. Two
  language companions: one tuple argument SPLATS across multi-parameter
  closures ({ index, char in } over enumerated()), and for-in destructures
  tuple patterns (`for (index, digit) in text.enumerated()`). PaymentCard,
  WalletAnimation, QuizGame, SequencedAnimation pass. **489/587 → 493/587**.
- 2026-07-09 iter 65: marker arithmetic — the chain-combine class (4).
  Members read off `.init(labeled:)` markers return the matching labeled
  argument (memberwise read-back: `.init(width: 100, height: 120).height` →
  120); CG-shaped init markers do arithmetic on their labeled numeric
  arguments and REWRAP (`Angle(degrees:) * 0.1`, `sizeA - sizeB` elementwise,
  scalar broadcasts), staying typed markers for later coercion; chained
  markers compare by final member name (`.current.orientation ==
  .landscapeRight` → false). 3DGestureCard, FloatingWindow,
  Pomodoro_Timer_Part_1, CustomVideoPlayer_-_Part_2 pass (+ripple).
  **493/587 → 499/587**.
- 2026-07-09 iter 66: CalendarBox round two — `dateInterval(of:for:)` with a
  DateIntervalBox (start/end/duration), weekOfMonth/weekOfYear/quarter
  components, and Foundation boxes gain host type names (CalendarBox →
  "Calendar", DateFormatter/NumberFormatter/DateComponents likewise) so user
  `extension Calendar { var hours … }` members dispatch on the real-backed
  boxes. TaskManagement, TaskPlanner (162 nodes — its Calendar extension
  evaluates for real), TaskManagementCoreData ×2 pass.
  **499/587 → 503/587 (85.7%).**
- 2026-07-09 iter 67: the protocols wall, first slice — protocol declarations
  collect inertly (requirements carry no bodies; conformance is duck typing),
  and protocol-EXTENSION members dispatch as DEFAULTS through the conformer's
  inheritance clause (own definitions win). Operator/precedence/typealias
  declarations skip inertly (vendored-Pods projects declare custom
  operators). Quiz + Global_Chat (despite merged Firebase Pods!) pass;
  SplashScreen advanced deep into vendored lib internals.
  **503/587 → 505/587 (86.0%).**
- 2026-07-09 iter 68: custom @resultBuilders — the member-on-closure class
  (3). Builder detection widened from @ViewBuilder to any *Builder-suffixed
  attribute; builder properties with `[X]` annotations collect their block's
  items into an ARRAY (buildBlock semantics), view-typed ones keep grouping.
  CustomSwipeActions_Updated + Expense_Tracker EP2/EP3 pass (146/138-node
  renders — the Expense march ends). **505/587 → 508/587 (86.5%).**
- 2026-07-09 iter 69: `.constant(x)` bindings — the marker-compare class (3).
  Constant bindings resolve to fixed-value boxes at @Binding memberwise
  positions (annotation-resolved) and in the bridge's binding coercions
  (Toggle(isOn: .constant(true))), so side-menu rows comparing
  `selectedMenu == title` read the constant. Custom_Side_Menu, Drawer,
  Instagram_Desktop (266 nodes / 29 actions — the largest render yet) pass.
  **508/587 → 511/587 (87.1%).**
- 2026-07-09 iter 70: the date(byAdding:) remainder — bare `.init()` markers
  construct Dates in date positions (timeIntervalSince1970/Now labeled forms
  included); Dates compare with </<=/>/>=; sorted accepts by:-labeled
  closures; calendar.compare(_:to:toGranularity:) returns marker-comparable
  ComparisonResults. Task_Management ×2 (92 nodes) + CardAnimation pass.
  **511/587 → 514/587 (87.6%).**
- 2026-07-09 iter 71: Combine `$published` projections — the $searchText
  class (3). Inside a model, `$published` yields a PublishedProjection whose
  pipeline stages (debounce/removeDuplicates/sink/store) chain inertly and
  never emit (documented: schedulers don't run headlessly). `&inout`
  expressions evaluate pass-through (reference semantics) and Set() joins
  the builtins (array-backed set-lite). LocationSearch ×2 + Marvel_API pass.
  **514/587 → 517/587 (88.1%).**
- 2026-07-09 iter 72: the member-on-void class resolved three ways. Path is a
  Shape/View: draw commands chain (`Path{}.strokedPath(StrokeStyle(...))
  .fill(...)`), strokedPath/addLines apply for REAL, StrokeStyle constructs,
  fill/stroke accept PathDrawStub, Path renders in view position in both
  registries — CustomScrollViewBottomShee passes. The two Realm projects are
  QUARANTINED (ProjectCheck gains the mechanism, reasons printed as 🚧 and
  recorded above) — third-party ORM internals, the sanctioned last resort.
  Metric basis is now 585. **517 → 518 passing / 66 failing / 2 quarantined
  (88.5% of the metric).**
- 2026-07-09 iter 73: the tied 3-classes — WindowStub.frame/bounds read as
  the canvas rect (ResponsiveUI ×3, one advancing through `.zero + .init`
  zero-marker arithmetic), and the Expense string(from:) chase ended at
  numeric `.zero` statics: Double/CGFloat/Int/TimeInterval `.zero` (+
  infinity/pi) resolve via the marker table, formatter belt-and-suspenders
  included. The WHOLE Expense_Tracker series passes (EP2→Complete). +11
  ripple. **518 → 529/585 (90.4% — past 90%).**
- 2026-07-09 iter 74: enum static computed properties (the iter-51 struct fix
  applied to the enum collector — `static var count: CGFloat` on a
  CaseIterable Tab), trig/math builtins (sin/cos/tan/asin/acos/atan/atan2/
  log/log2/exp/hypot), and bare numeric markers absorb in arithmetic
  (`x / .pi`, `.infinity`). PS_TabBar + Interactive_Header pass.
  **529 → 531/585 (90.8%).**
- 2026-07-09 iter 75: the Layout wall, taken as containers — Layout
  conformers accept trailing content (children stash at init) and modifiers,
  rendering as a default flow in both registries (sizeThatFits/placeSubviews
  never run — documented). Clears the TagLayout pair AND the long-standing
  wall pair: TagView, TagTextField, Chips_UI (blocked since iter 36),
  LoopingCards. **531 → 534/585 (91.3%).**
- 2026-07-09 iter 76: hosted-object nodes act like objects — TraceNodes with
  UIKit-ish constructor prefixes (UI/NS/CA/AV/CL/MK/WK/SK/PH) serve members
  as memoized chained bags (`engine.mainMixerNode.outputVolume = 0.5`
  round-trips) instead of falling into the view-modifier catch-all, and
  TraceNode is InertCallable (calls absorb, clearing the "not callable"
  class too). Canvas_Editor, ImageDrawing, InteractiveToasts,
  Responsive_UI_New (218 nodes) pass — two classes, one stroke.
  **534 → 538/585 (92.0%).**
- 2026-07-09 iter 77: fresh-state Bool doctrine — hosted-object values
  (InertCallable) AND unresolved markers in Bool positions read false
  (`canEvaluatePolicy` → no biometrics, `session.isRunning` → nothing runs
  headlessly); `!` negates from that. Clears the Bool/TraceNode 3-class and
  half the Bool-operand pair: Music, FaceID_Login ×2, QRCodeScanner pass;
  TextSelectionAPI advanced (patternExpr singleton).
  **538 → 543/585 (92.8%).**
- 2026-07-09 iter 78: real Color statics — `Color.white` etc. resolve to real
  Colors (user `extension Color/UIColor` members dispatch via the
  hostTypeName precedence rule: user extensions of a stub's host type WIN
  over bridge members); tuple locals destructure (`var (r, g, b, a) =
  (0,0,0,0)`); native-Color members (opacity/gradient), AnyGradient.opacity,
  AnyShapeStyle pass-through, and AnyHashable equality (realized Colors
  compare) — the last three recovered a 4-project regression the
  realization caused. ImageColorPicker ×2 pass. **543 → 545/585 (93.2%).**
- 2026-07-09 iter 79: size-class env keys — horizontalSizeClass reads
  .compact / verticalSizeClass .regular (the iPhone-portrait canvas), plus
  dynamicTypeSize/.scenePhase defaults; Query-shaped `.init(filter:sort:)`
  markers act as fresh empty stores in ForEach. AdaptiveLayoutDesign +
  Notes_App_Complete pass. **545 → 547/585 (93.5%).**
- 2026-07-09 iter 80: array `append(contentsOf:)` splices through the
  mutating-lvalue path (both AnimatedCharts units pass — their multi-
  iteration march ends). **547 → 549/585 (93.8%).**
- 2026-07-09 iter 81: fractional ranges — `0.01...0.1` constructs
  ClosedRange<Double> (Int semantics unchanged), doubleRangeValue bridges
  Int ranges, and the consumers speak both: Slider(in:), Double.random(in:),
  Int-context random over double bounds. HackerTextEffect passes;
  MatrixRainEffect advanced to stub-fed index math.
  **549 → 550/585 (94.0%).**
- 2026-07-09 iter 82: property-shadowed modifiers — the modifier-retry
  (iter 46) extends to "is not callable" failures: `var offset: CGFloat` on
  a view struct no longer shadows `.offset(y:)` at call sites (invocation
  fails before any body runs → the retry is safe). BottomSheet,
  CustomCarouselSlider, CompositionalGridLayout pass (+ripple); the LAST
  2-class is gone — the histogram is all singletons.
  **550 → 554/585 (94.7%).**
- 2026-07-09 iter 83: the OSS rung (step 9) — the zip histogram went
  all-singletons, so the ladder gains real GitHub material: SwiftUI-Kit
  (jordansinger, 18 files), SwiftUI-2048 (unixzii, 11), Milestones (jpsim,
  21) cloned into External/oss/ (gitignored); ProjectCheck scans oss/
  directories as `oss:<name>` units. First contact: **SwiftUI-Kit passes
  immediately** (37-node catalog render); 2048 fails on `[.Index]`-typed
  call shapes and Milestones on the `/` case-path prefix operator — new
  class material the zip corpus never produced. Metric basis 588.
  **554 → 555/588 (94.4%).**
- 2026-07-09 iter 84: the 2048 quartet (first OSS-driven fixes) — USER
  SUBSCRIPTS (get/set, tuple indices, arity-matched, lvalue writes through
  setters), typed empty containers (`[Index]()`, `[String: Int]()`),
  typealiases resolve to their target types (top-level AND member-level,
  generic args dropped), and `defer` runs LIFO on every exit path.
  oss:SwiftUI-2048 advanced four walls deep (now at custom postfix
  operators); the zip corpus holds. **555/588 steady, four language
  features banked.**
- 2026-07-09 iter 85: the second 2048 batch — custom PREFIX/POSTFIX operator
  functions dispatch by name (`postfix func >*` — the AnyView-erasure
  operator; builtins keep priority for -/!), AnyView(x) is identity in both
  registries, backtick-escaped parameter labels normalize (`` `for` ``),
  and deferred-init locals (`let x: T` assigned in branches) hold void
  until first assignment. +1 zip ripple; 2048 now at capture-list self.
  **555 → 556/588 (94.6%).**
- 2026-07-09 iter 85: the second 2048 batch — custom PREFIX/POSTFIX operator
  functions dispatch by name (postfix func >* — the AnyView-erasure
  operator; builtins keep priority for -/!), AnyView(x) is identity in both
  registries, backtick-escaped parameter labels normalize, and
  deferred-init locals (let x: T assigned in branches) hold void until
  first assignment. +1 zip ripple; 2048 now at capture-list self.
  **555 → 556/588 (94.6%).**
- 2026-07-09 iter 86: **oss:SwiftUI-2048 PASSES — 7,445 nodes, the largest
  render ever** (the full game-board matrix deep-rendered). The final batch:
  static METHODS bind self = the type (statics/`self`/`Self` resolve in
  static bodies), `Self` resolves to the enclosing type, `Type.init(...)` ≡
  `Type(...)`, and Array.flatMap. A real GitHub game app runs end to end
  after 3 iterations / 11 language features. **556 → 557/588 (94.7%).**
- 2026-07-09 iter 87: min/max with predicates — the charts genre's
  `analytics.max { $0.value < $1.value }` compared whole instances via the
  no-closure path; by:-labeled and trailing predicates now drive both (min
  probes closure(element, best), max closure(best, element) — Swift's exact
  areInIncreasingOrder semantics). A 6-project class had been hiding as
  stringified-singleton histogram entries. InteractiveCharts ×2, DashBoards,
  BankingMacApp, SwiftCharts + ripple pass. **557 → 564/588 (95.9%).**
- 2026-07-09 iter 88: fresh-state numerics — the compare/combine family (10
  projects hiding across stringified messages). Unresolved markers/hosted
  objects read ZERO in arithmetic and FALSE in ordered comparisons;
  marker-vs-concrete equality is false; hosted objects compare by identity;
  numeric markers (.zero/.pi/.infinity) absorb in compare like arithmetic.
  Companions the chain exposed: FocusState false-synthesis is Bool-only,
  nil-optional switches match `.none`/`nil` cases, and `break` exits a
  SWITCH (not the enclosing function). StretchySlider, Game, IconGenerator,
  CustomTabView, CustomHUDs, CustomHeader, CardCreation_Updated + ripple.
  **564 → 571/588 (97.1%).**
- 2026-07-09 iter 89: value-type member writes — `size.width = 300` and
  nested `rect.origin`/`rect.size` swaps write through mutated copies (new
  registry hostMutatedCopy hook + LValue.hostValueMember; structs with
  readable members route there, class-backed boxes keep reference writes);
  `$tuple.0`/`$point.x` binding projections write through the parent box;
  `let _ = …` wildcard locals evaluate for effect. CustomScrollView (184
  nodes/34 actions) + Sticky_Header (152/18) pass.
  **571 → 572/588 (97.3%).**
- 2026-07-09 iter 90: custom @resultBuilder parameters — closures bound to
  `@…Builder` params undergo the builder transform (collect items, not
  last-expression); `[X]`-returning builder closures/functions collect into
  ARRAYS (view-typed still group). Attribute lives on
  FunctionParameterSyntax.attributes, not the type node.
  InteractiveFloatingButton passes (31 nodes, 4 actions).
  **572 → 573/588 (97.4%).**
- 2026-07-09 iter 91: name-resolution order — identifier lookup now walks
  locals (chain BEFORE globals) → implicit-self members → globals, matching
  real Swift scoping: a method named like a top-level type wins in its own
  body (`func OTPField()` vs `enum OTPField`), member properties shadow
  global constants. New Environment.box(for:before:) boundary walk.
  AutoOTP passes (44 nodes, 3 actions). **573 → 574/588 (97.4%).**
- 2026-07-09 iter 92: case patterns vs unknowable subjects — `.selection(let
  range)` against a host marker can't match, so the switch falls to
  `default` (fresh-state) instead of choking on the `let` binding; plus
  String.Index ranges (String.range(of:), Range<String.Index>
  lowerBound/upperBound/isEmpty, `text[range]`/`text[i]` subscripts).
  TextSelectionAPI passes (11 nodes, 4 actions). **574 → 575/588 (97.6%).**
- 2026-07-09 iter 93: inherited host-superclass initializers — classes whose
  superclass is a host type (class RainFall: SKScene) accept inherited-init
  labeled arguments as instance properties (readable later: `size` in
  sceneDidLoad); interpreted-superclass/protocol shapes keep the strict
  memberwise error (new isInterpretedType gate).
  WeatherAppScrolling_Rain_Effect_Updated passes (199 nodes).
  **575 → 576/588 (97.8%).**
- 2026-07-09 iter 94: numeric conversions absorb unknowables — Int()/
  Double()/Float() of host markers/chains read the fresh state (0; .pi/
  .infinity markers keep their constants) via new Builtins.absorbedNumeric,
  instead of yielding nil that poisons downstream comparisons
  (`Int(player.currentTime.truncatingRemainder(…)) < 9`).
  Audio_Player passes (40 nodes, 9 actions). **576 → 577/588 (98.0%).**
- 2026-07-09 iter 95: Locale host bridge — Locale.current/autoupdatingCurrent
  return the REAL host locale (CalendarBox precedent); members regionCode/
  identifier/languageCode/currencyCode/currencySymbol/localizedString(for…)
  via modern non-deprecated APIs; Locale(identifier:) constructor;
  hostTypeName "Locale" for extension dispatch.
  PhoneAuth_Updated_Latest passes (35 nodes, 13 actions).
  **577 → 578/588 (98.3%).**
- 2026-07-09 iter 96: FileManager sandbox + real URLs — FileManager.default
  performs real file ops confined to a per-run temp sandbox (fresh
  container: documents start empty; ops outside the sandbox throw);
  urls/fileExists/remove/copy/move/createDirectory/contentsOfDirectory;
  URL(string:) has real semantics (invalid → nil) with unknowable marker
  strings flowing through (openSettingsURLString — caught a mid-iteration
  Signal_ImagePicker regression); URL members (path/lastPathComponent/
  appending…/deleting…). README fresh-state doctrine updated.
  DownloadTask passes (7 nodes). **578 → 579/588 (98.5%).**
- 2026-07-09 iter 97: fresh-identity absorption — unknowables read each
  context's identity value: "" in string concat (suffix survives:
  NSTemporaryDirectory() + "….mov"), empty in for-in iteration
  (Activity<T>.activities; bare `.member` sequences too). README doctrine
  extended. ReelsCamera (22 nodes) + Lockscreen_Dock (13) pass.
  **579 → 581/588 (98.8%).**
- 2026-07-09 iter 98: appearance proxy = UIKitStub — `.appearance()` returns
  the read/write bag (writes stick, reads memoize, config calls chain);
  UIKitStub geometry members (bounds/frame → CGRect.zero, center/
  contentOffset → CGPoint.zero, contentSize → CGSize.zero) read REAL
  fresh-layout values so CGRect math works; AppearanceStub deleted.
  CustomHeader passes (18 nodes). **581 → 582/588 (99.0%).**
- 2026-07-09 iter 99: Double-family annotation coercion — CGFloat/Double/
  TimeInterval/Float-annotated storage coerces Int values to Double at
  resolveAnnotated, so `20 / titleOffset` with a zero offset is IEEE
  infinity (compiled-Swift behavior) instead of an Int-division trap.
  TwitterProfileScrolling passes (242 nodes, 5 actions).
  **582 → 583/588 (99.1%).**
- 2026-07-09 iter 100: Array(String) splits into characters — the Array()
  builtin maps a string to single-char strings (our character model), so
  `Array(constant)[getRandomIndex(…)]` indexes real characters instead of
  a one-element wrap. MatrixRainEffect passes (711 nodes — full grid).
  **583 → 584/588 (99.3%). Only the three SDK/Pods walls remain.**
- 2026-07-09 iter 101: static stored property WRITES — `ChatClient.shared =
  ChatClient(config:…)` (extension statics on host types, declared without
  initializers → nil until written) and `Palette.accent = "red"` (interpreted
  types) write through new LValue.staticProperty into the symbol's static
  cache; reads serve extension statics off host constructor functions;
  locals shadow via the before-globals walk. Stream_Tutorials passes
  (12 nodes). **584 → 585/588 (99.5%). Remaining: Milestones (TCA),
  SplashScreen (Pods).**
- 2026-07-09 iter 102: oss:Milestones — three layers peeled: (1) CasePaths
  prefix `/` yields an inert CasePathMarker (operand kept textual — case
  references aren't standalone values); (2) DateFormatterBox config setters
  (locale/calendar/timeZone/dateStyle/timeStyle/am-pmSymbol); (3) ROOT view
  parameter synthesis — parameterized roots (no ContentView) instantiate
  with fresh values per annotation: identity primitives, empty collections,
  nil optionals, recursive fresh instances for interpreted types (custom
  inits included), Binding stubs, unknowable chains for host generics
  (Store<A,B>). oss:Milestones passes. **585 → 586/588 (99.7%).
  Remaining: SplashScreen (vendored Pods).**
- 2026-07-09 iter 103: vendored type-name collisions — Lottie's `struct
  Color` (12.8k lines of vendored Pods) shadowed SwiftUI.Color under our
  merged-module model. Two fallthroughs, both binding-safe: constructor
  binding failures on interpreted types retry the same-named registry
  constructor (Color("bg") → asset color); static-member misses on
  registry-known type names fall through to bridge statics/implicit
  members (Color.black). SplashScreen passes (33 nodes, 3 actions).
  **586 → 587/587 counted units — ZERO failures. The local ladder + OSS
  rung are saturated; step 9 (new OSS material) applies next.**
- 2026-07-09 iter 104: ladder step 9 — cloned four new OSS repos (Weather 25
  files, reddit-swiftui 37, MovieSwiftUI 105, Jinxiansen/SwiftUI examples
  41; units 588 → 591 counted). Fixed the biggest new class, MovieSwiftUI's
  archived-state restore: FileManager.url(for:in:appropriateFor:create:) +
  url(forUbiquityContainerIdentifier:) → nil (no iCloud, fresh device);
  trap builtins (fatalError/precondition/assert family — concrete false
  traps, unknowable conditions assume a healthy device); fresh-store
  persistence reads fail honestly (Data(contentsOf:) real file semantics,
  decode-on-stub throws) so restores take their else branch; Data members
  (count/isEmpty/base64) — the real-Data switch briefly regressed
  Music+Filter, caught by the measure. MovieSwiftUI passes (3 nodes).
  **588/591 counted (99.5%); queue: oss:Weather, oss:SwiftUI,
  oss:reddit-swiftui.**
- 2026-07-09 iter 105: duplicate type names last-wins — multi-target repos
  (reddit-swiftui's iOS + macOS ContentView/PostList pairs) redeclare views
  per platform; the symbols LIST (root-view pick) resolved first-wins while
  globals resolved last-wins, pairing an iOS body with a macOS symbol
  (`isLoading` void). registerTypeSymbol replaces in-place so both agree.
  oss:reddit-swiftui passes (14 nodes, 1 action). **589/591 (99.7%);
  queue: oss:Weather, oss:SwiftUI.**
- 2026-07-09 iter 106: Date ranges — `soon..<later` / `soon...later` with
  Date bounds construct Range<Date>/ClosedRange<Date> in the ..< and ...
  builtins (DatePicker `in:` windows — Jinxiansen DatePickerPage idiom).
  oss:SwiftUI passes (175 nodes — the whole examples collection).
  **590/591 (99.8%); queue: oss:Weather.**
- 2026-07-09 iter 107: percent-encoding — String.addingPercentEncoding
  (withAllowedCharacters:) with CharacterSet markers (.urlQueryAllowed +
  url*/alphanumerics/letters/digits/whitespaces) and removingPercentEncoding,
  real Foundation semantics. oss:Weather passes (6 nodes).
  **591/591 counted — ZERO failures again. Ladder saturated; step 9
  (more OSS material) governs the next iteration.**
- 2026-07-09 iter 108: step 9 again — cloned clean-architecture-swiftui (63
  files), MortyUI (26), OnlineStoreTCA (27); units 591 → 594. Fixed the
  biggest new class: `actor` declarations — collected as reference-typed
  classes via a shared class-like collector (isolation not enforced,
  documented in README; the interpreter is single-threaded). run() skip
  list includes actors. oss:clean-architecture-swiftui passes (5 nodes).
  **592/594 (99.7%); queue: oss:OnlineStoreTCA ($0), oss:MortyUI
  (ForEach over chain).**
- 2026-07-09 iter 109: AsyncImage phases — the trace gateway invokes the
  content closure with a stub image (TraceNode "Image" — trace-land's image
  currency, so `$0.resizable()` shorthand chains natively; GeometryReader-
  proxy precedent) AND renders the placeholder (the phase a fresh launch
  shows); phase-form closures record without invoking. The generic recorder
  had called `{ $0… }` shorthand closures with zero args ($0 unbound).
  oss:OnlineStoreTCA passes (19 nodes, 1 action). **593/594 (99.8%);
  queue: oss:MortyUI.**
- 2026-07-09 iter 110: ForEach over unknowables — both registries' ForEach
  elements extraction reads unknowable host collections (GraphQL fragment
  chains, InertCallable/chain/bare-marker kinds) as EMPTY, matching the
  for-in doctrine (iter 97); regression test drives the chain directly
  (first draft hid it behind a nil optional — caught in review).
  oss:MortyUI passes (37 nodes). **594/594 counted — ZERO failures.
  Ladder saturated again; step 9 governs next.**
- 2026-07-09 iter 111: step 9 — cloned MakeItSo (17 files), ControlRoom (82),
  IceCubesApp (424; units 594 → 597). Fixed the biggest new class: import
  declarations (@_exported/@preconcurrency/#if-nested forms survive
  ProjectCheck's line strip) are no-ops at the interpreter level (statement
  + run skip); plus doctrine completion — .hostFunction values in sequence
  position iterate empty (for-in + both ForEach helpers), peeling IceCubes
  18k lines deeper. **594/597 (99.5%); queue: MakeItSo ($viewModel
  synthesis), ControlRoom (Collection-extension members on natives),
  IceCubesApp (.timeline vs void).**
- 2026-07-09 iter 112: protocol-extension members on natives — hostCandidates
  gains protocol umbrellas (Collection/Sequence for arrays+strings+dicts+
  ranges; RandomAccess/Mutable/Bidirectional for arrays; StringProtocol;
  BinaryInteger/Numeric; FloatingPoint), so `extension Collection { var
  isNotEmpty }` dispatches on every conforming native.
  oss:ControlRoom passes (5 nodes). **595/597 (99.7%);
  queue: MakeItSo, IceCubesApp.**
- 2026-07-09 iter 113: wrapper-storage inits — StateObject/ObservedObject/
  Published/Bindable constructors join the State precedent: the storage IS
  the wrapped value, so `self._viewModel = StateObject(wrappedValue:
  ViewModel(…))` in custom inits stores the model instance and
  `$viewModel.field` projects off it (`self._name = binding` already worked
  via canonicalPropertyName). oss:MakeItSo passes (6 nodes, 1 action).
  **596/597 (99.8%); queue: IceCubesApp only.**
- 2026-07-09 iter 114: IceCubes layers — (1) standalone roots synthesize
  @Binding parameters (fresh inner value: first payload-free case for
  enums) and @ObservedObject models; (2) missing env-object synthesis
  instantiates via instantiateRoot, so models with required init params
  (Client(server:)) get fresh arguments; (3) unqualified modifier calls in
  View-extension bodies (`sheet(item:)`, `navigationDestination`) bind
  implicit view self as a LAST-resort resolution — first draft sat before
  the constructor check and trace-land's catch-all modifier table hijacked
  30 tests (caught by the suite, moved to pre-throw).
  IceCubesApp: 215 → 39961 (ToolbarContent instances — next class).
  **596/597 (99.8%); top class eliminated.**
- 2026-07-09 iter 115: IceCubes climb, five layers — (1) rendersLikeView
  duck-typing: instances with a `body` render (ToolbarContent/Commands),
  wraps at builder + modifier seams; (2) a type's OWN nested types shadow
  same-named globals (per-package `enum Constants`); (3) wrapper-storage
  `.init(initialValue:/wrappedValue:)` markers dispatch members onto the
  wrapped value (first patch landed in the wrong accessMember case — SIMD
  `any()` compile error exposed it); (4) real Date arithmetic (Date ±
  TimeInterval → Date, Date − Date → TimeInterval); (5) suite caught
  nothing else. IceCubes: 39961 → 19181 (bag member in Bool position —
  next class). **596/597; ToolbarContent class eliminated. Suite 228.**
- 2026-07-09 iter 116: nested classes + function absorption — nested CLASS/
  ACTOR declarations register like nested structs (UserPreferences.Storage
  was falling to the catch-all TraceNode, poisoning every preference read);
  makeClassLikeSymbol split from registration, shared registerNestedType;
  bound host-member FUNCTIONS complete the fresh-identity table (0 in
  arithmetic + compare, "" in concat, false in Bool). IceCubes:
  19181 → 35507 (String.unicodeScalars — next class). **596/597;
  picked class eliminated. Suite 229.**
- 2026-07-09 iter 117: env-key defaults + static adoption — String.
  unicodeScalars (scalar array, char model); CUSTOM @Environment keys read
  their @Entry-declared defaults from the EnvironmentValues extension
  (undeclared keys read fresh identities); range bounds absorb unknowables
  (0..<chain = empty); bare `.member` statics adopt the OTHER operand's
  host type in binary ops (40 + .statusColumnsSpacing resolves the CGFloat
  extension constant; Double tries CGFloat/TimeInterval names) — call-
  shaped markers keep equality-only adoption (init-marker elementwise
  arithmetic broke once mid-iteration, suite caught it); bare markers
  absorb to 0 as last resort. IceCubes: 35507 → 35527 (String.flatMap).
  **596/597; picked class eliminated. Suite 230.**
- 2026-07-09 iter 118: map-family argument shapes — flatMap/map/compactMap
  accept closures (incl. trailing — first string draft missed those, own
  test caught it), KEY PATHS (KeyPathStub now carries components;
  applyKeyPath walks instance/native/host members, unknown hops chain),
  and unapplied function references (URL.init(string:) invokes); string
  flatMap is Optional-flavored (closure gets the whole string); Locale
  .language/.languageCode/.characterDirection bridged; UIApplication
  alternateIconName reads nil (fresh install). IceCubes: 35527 → 3407
  ("Icon is not callable" — next class). **596/597. Suite 231.**
- 2026-07-09 iter 119: IceCubesApp FALLS — enum custom inits (writable
  `self`, `self = .init(rawValue:)!` resolves in own type context;
  Icon(rawValue:) raw-value initializer; EnumSymbol.initializers collected);
  unknowable subscripts read nil (Bundle.main.infoDictionary?[…] → ??
  fallback); unknown SDK member views render opaque (WishKit.
  FeedbackListView() — Lottie-degrade precedent); String.replacing(_:with:)
  (test-driven find: fresh state never ran the else branch in the corpus).
  oss:IceCubesApp passes (197 nodes, 10 actions — the 424-file marathon
  rung, six iterations of layers). **597/597 counted — ZERO failures.
  Ladder saturated; step 9 governs next.**
- 2026-07-09 iter 120: step 9 — cloned RedditOS (103 files, PASSED on
  arrival), damus (641), isowords (388); units 597 → 600. Fixed the biggest
  new class: custom-operator FOLDING — user operator/precedencegroup decls
  join the fold table (OperatorTable.addSourceFile); operators from
  EXTERNAL modules recover with default precedence and get ecosystem
  semantics at eval (|> / <| pipes, >>> / <<< composition; user operator
  FUNCTIONS retry first). Same climb: stub-member lvalue reads chain,
  bitwise & | ^ << >>, String HOFs via char array (min/max excluded —
  shadowed the global two-arg forms, PaymentCard regressed and was caught
  by the measure), reduce(into:), Data(contentsOf:) marker flow,
  unsafeBitCast passthrough. isowords: line 1 → 28146 (sqlite3 C interop —
  next class/scope decision). **598/600 (99.7%); queue: isowords, damus.**
- 2026-07-09 iter 121: C-interop absorbers — unresolved snake_case /
  _dyld-style / C-stdlib identifiers (sqlite3_*, ndb_*, malloc) read as
  inert absorbing functions (the merge holds all the app's OWN Swift, so
  undeclared snake_case = unmerged C import); delegating initializers
  (`self.init(…)` convenience chains, shared runInitializer); String
  utf8/utf16 views + Data byte views; Data(bytes) real construction;
  hostCandidates gains Data/URL/UUID; String ranges ("A"..<"H" dict keys,
  equality). isowords QUARANTINED after its C wall fell: the remaining
  wall is the SERVER half (NIO/Prelude/EitherIO — client+server monorepo
  the merged-module model can't split; recorded in ProjectCheck).
  damus: 8262 → 11978. **598/599 counted; queue: oss:damus.**
- 2026-07-09 iter 122: failable-init semantics — `init?` bodies that
  `return nil` yield NIL (not a half-built instance with void lets — the
  damus Pubkey/IdType chase, found via temporary instrumentation); struct
  init self-reassignment (`self = decoded`) propagates through
  runInitializer; root synthesis prefers NON-failable inits and knows
  Data/UInt8-64 fresh values; Data(repeating:count:) real; pointer-interop
  members (withCString/withUnsafeBytes…) absorb without invoking closures;
  Data iterates as its byte collection (ForEach/for-in — a mid-iteration
  RedditOS regression from the new Data fresh value, caught + fixed).
  damus: 11978 → 69257 (force-unwrap — next class). **598/599; queue:
  oss:damus.**
- 2026-07-09 iter 123: bech32 runs REAL — the probe-driven chase made damus's
  pure-Swift decoder interpret bit-perfectly (hrp=npub, 32 bytes): String
  data(using:)/range(of:options:) (.backwards), Data subscript reads AND
  byte writes (LValue.dataElement), Data.append write-through, Data copy
  ctor (Data(values[..<n]) was returning empty!), partial ranges
  (PartialRangeValue: prefix ..</... + postfix ..., slicing String/Data/
  arrays), scalar .value/.asciiValue/isNumber on single-char strings,
  compound bitwise assigns (&= |= ^= <<= >>=), array start/endIndex,
  Int-family ctors (UInt8…Int64), annotation-labeled tuples ((hrp:,data:)
  labels positional returns), and SHAPE-AWARE chooseInitializer (positional
  args need `_` slots — Pubkey(data) no longer picks init?(hex:)).
  damus: 69257 → 76646 (.ptr on void — nostrdb C pointers, next class).
  **598/599. Suite 236.**
- 2026-07-09 iter 124: init-delegation failure + lazy library globals —
  a delegated `self.init(…)` that returns nil now fails the WHOLE init
  (sentinel unwinds through runInitializer; no more half-built instances
  reading void `note.ptr`); merged multi-file units treat top-level
  globals as LAZY library globals (SwiftUI apps have no main.swift — real
  Swift initializes them on first use), so damus's embedded test fixtures
  (`NostrEvent(…)!` needing real secp256k1) never run unless referenced.
  Single-source programs keep eager main-semantics (tests unchanged).
  damus: 76646 → 35225 (void `environment` property — next class).
  **598/599. Suite 237.**
- 2026-07-09 iter 125: damus FALLS — custom property wrappers read their
  attribute defaults (@Setting(key:, default_value: .production) — a fresh
  store has nothing persisted, the declared default IS the value); Task
  bodies swallow unhandled interpreted throws (device semantics: errors
  end the task silently); throwing property DEFAULTS read unknowable
  (real resources exist on device); synthesis falls to unknowable on
  throwing inits; UUID uuidString/description; phase-labeled verifier
  diagnostics (top-level/root-init/root-body/action #n) kept permanently.
  oss:damus passes (9 nodes, 5 actions — 641 files, four iterations).
  **599/599 counted — ZERO failures. Ladder saturated (fourth time);
  step 9 governs next.**
- 2026-07-09 iter 126: step 9 — cloned EhPanda (192 files), VirtualBuddy
  (250, PASSED on arrival), Planet (263); units 599 → 602. Biggest new
  class: GENERIC-PARAMETER synthesis — properties typed by a struct's own
  generic params (`content: Content` in AlertHost<Content: View>) never
  synthesize as same-named concrete types (EhPanda's GalleryState.Content
  model had claimed the bare name); View-constrained params become fresh
  EmptyViews via the registry. Same climb: external-model $projections
  absorb (AlertKit manager), WindowSceneStub.activationState
  (foregroundActive), exit/abort/sleep C absorbers, String.description,
  CGFloat + static absorbedNumeric learn unknowables (.hostFunction).
  All three repos pass. **602/602 counted — ZERO failures (fifth
  saturation).**
- 2026-07-09 iter 126b (user request): LIVE project rendering — the demo
  gains `--project <dir>` (ProjectCheck-style merge → real-registry render
  in a window; --render-png composes for headless snapshots). Real-registry
  parity fixes driven by IceCubesApp live: unknown SDK constructors build
  absorbing UIKitStubs (trace-recorder analog) and unknown SDK views render
  EmptyView; Color.resolve(in:)/Color.Resolved components; sheet(item:)
  presents on non-nil bindings with presentation-time content;
  tabViewStyle (sidebarAdaptable/grouped/automatic); keypath
  .environment writes pass through (@Entry defaults apply);
  InterpreterHost uses lazy globals + root synthesis. Verified: PNG
  snapshot renders error-free; windowed app alive 12s with the project
  loaded. `swift run DynamicSwiftUIDemo --project External/oss/IceCubesApp`.
- 2026-07-09 iter 127: step 9 — cloned Whisky (64 files), Cork (370), Rayon
  (230, PASSED on arrival); units 602 → 605. Biggest new class (Cork):
  default-less switches over UNKNOWABLE subjects take the first case
  (payload bindings read fresh chains — the switch analog of first-enum-
  case synthesis); nil reads false in Bool positions (optional-chain
  artifacts); DI-container wrappers (@InjectedObservable/@Injected —
  FactoryKit) are environment-object shaped, typed by annotation or the
  capitalized keypath (`\.navigationManager` → NavigationManager), so the
  existing missing-env-object synthesis provides fresh instances.
  Cork passes (35 nodes, 7 actions). **604/605 (99.8%); queue: Whisky
  (FileManagerBox.homeDirectoryForCurrentUser).**
- 2026-07-09 iter 128: Whisky falls — FileManager.homeDirectoryForCurrentUser
  reads the SANDBOX root (the app's home is its container) +
  temporaryDirectory (sandbox tmp); URL.appending(path:/component:) is the
  modern appendingPathComponent. Whisky passes (59 nodes, 5 actions).
  **605/605 counted — ZERO failures (sixth saturation). 585 zips + 20 OSS
  repos green; quarantines: Realm pair + isowords.**
- 2026-07-09 iter 129: step 9 — cloned CodeEdit (672 files, PASSED ON
  ARRIVAL — the biggest single-pass yet), OnlySwitch (343), eul (128);
  units 605 → 608. Classes fixed: objectWillChange on interpreted
  ObservableObjects (.send() fires the change signal; pipeline members
  chain); generic-typed @EnvironmentObject strips generics
  (ComponentsStore<EulComponent>); String.localized* (key fallback —
  Localize_Swift); marker $projections complete (.implicitMember/
  .hostFunction box values); backticked enum case names normalize
  (`default`); LAZY instance members defer to first access with self
  bound (LazyMemberSeed — sibling-property references are legal).
  eul (74 nodes) + OnlySwitch (8 nodes) pass. **608/608 counted — ZERO
  failures (seventh saturation). 585 zips + 23 OSS repos green.**
- 2026-07-09 iter 130: step 9 — cloned PlayCover (73 files), Mythic (108);
  Swiftcord vendored no Swift (dropped); units 608 → 610. Classes fixed
  (Mythic's climb): GLOBAL computed vars (`var uptime: String { … }` at
  file scope — ComputedGlobal, accessor per read); static property
  initializers + host-extension static METHODS evaluate in static-type
  context (bare sibling statics: `custom(category:)` sees `subsystem`);
  Thread.isMainThread true (single-threaded interpreter) + bare markers
  read false in Bool; array allSatisfy + filter accept key paths (own
  test caught allSatisfy's requiredClosure draft). **608/610; queue:
  Mythic (call-depth in action #0), PlayCover ($viewModel projection).**
- 2026-07-09 iter 131: Mythic falls — delegation to INHERITED designated
  inits: chooseInitializerStrict (shape-only, nil on no match) stops the
  blind fallback that made `self.init(window:)` self-delegate forever
  inside NSWindowController conveniences; unmatched delegation binds
  labeled args as properties (iter-93 host-superclass rule); bare statics
  ASSIGN inside static methods (`shared = …` via .type self →
  LValue.staticProperty); @StateObject joins root synthesis; unknowable
  binding projections ($vm.app.settings → detached member binding);
  chain-vs-concrete equality false (areEqual unknowable gate); compare-
  side chains absorb; formatter decimalSeparator/minimumIntegerDigits;
  unknowable path components chain; nested Task bodies SCHEDULE (never
  run synchronously — taskDepth). Mythic passes (48 nodes, 2 actions).
  **609/610; queue: PlayCover (direct recursion in action #18).**
- 2026-07-09 iter 132: METHOD OVERLOADS — methods/staticMethods store
  overload ARRAYS; chooseFunction picks by call shape at both call paths
  (member calls + unqualified calls in the type's own body); value-position
  reads keep the first overload. PlayCover's "infinite recursion" was
  `error(localized:)` forwarding to `error(_ msg:)` through a last-wins
  single-slot method table that dispatched back to itself. Depth-guard
  errors now carry call-site locations (diagnostic keeper).
  PlayCover passes (333 nodes, 21 actions). **610/610 counted — ZERO
  failures (eighth saturation). 585 zips + 25 OSS repos green.**
- 2026-07-09 iter 133: step 9 — cloned Loop (150 files), Aidoku (408, passed
  on arrival), Clop (64, passed on arrival); units 610 → 613. Loop's climb
  + fallout fixes: bodyless extern declarations absorb (@_silgen_name
  Carbon privates); marker member writes accepted; sysctl/getenv family;
  typed-array ctors ([CChar](repeating:count:)); @Default is state-like
  with fresh-identity values; observer-only GLOBALS are stored (iter-130
  fallout — Clop); shadowed-enum registry fallthrough (Aidoku State);
  prefix ! completes the truthiness table; COMPILED-IMPORTS mode
  (merged units compile on device — unresolved identifiers absorb);
  in-run persistence ROUND-TRIP (encode→write→read→decode returns the
  original value, chain-keyed URLs — PlayCover's config-reset loop
  terminates with real semantics); INTERPRETED-superclass storage MERGES
  + member dispatch walks the chain (README divergence retired).
  Loop passes (59 nodes, 8 actions). **613/613 counted — ZERO failures
  (ninth saturation). 585 zips + 28 OSS repos green. Suite 248.**
- 2026-07-09 iter 134: step 9 — cloned yattee (348 files), SwiftBar (66),
  MonitorControl (29); units 613 → 615 counted (MonitorControl is pure
  AppKit → new ⚪ "not SwiftUI material" marker, auto-excluded like
  quarantine but self-describing). Classes: app-shell top-level programs
  (NSApp.delegate writes accepted; run/terminate/activate no-op — the
  render pipeline IS the run loop); `_ = expr` discard assignments;
  ecosystem Optional truths (isNil true on nil — yattee regression from
  the speculative `!nil`, which is REVERTED; concrete-side chains already
  read false); Optional-extension dispatch on nil values.
  yattee (7 nodes) + SwiftBar (3 nodes) pass. **615/615 counted — ZERO
  failures (tenth saturation). 585 zips + 30 OSS repos green. Suite 249.**
- 2026-07-09 iter 135: step 9 — cloned Ice (116 files), linearmouse (233),
  KeyboardCowboy (673, PASSED ON ARRIVAL — ties CodeEdit for biggest
  single-pass). Classes: HOST-superclass instance properties (NSPanel
  .title — writes create boxes, reads chain, qualified AND unqualified
  paths); owner-scoped annotation synthesis (each view's own nested enum
  Location wins over same-named globals); compiled-mode unknown MEMBERS
  absorb after every dispatch (own → inherited → protocol extensions);
  backtick-normalized property names. **616/618 counted; queue: Ice
  (void OptionSet default — deep init-overload chase), linearmouse
  (String.container).**
- 2026-07-09 iter 136: linearmouse falls — Codable inits are DECODER-ONLY:
  never picked by synthesis or shape-fallback for ordinary construction
  (isCodableInit gates struct/class/enum paths; enum single positional
  tries raw-value matching first); gateway numeric coercions absorb
  markers (Coerce.cgFloat/double via public absorbedNumeric — whose early
  `default: return nil` had made the bare-marker zero rule DEAD CODE;
  window.frame.minY on inherited host frames now reads 0).
  linearmouse passes (11 nodes, 2 actions). **617/618; queue: Ice (void
  OptionSet in generic init overloads — probe-resistant, needs a fresh
  angle).**
- 2026-07-09 iter 137: Ice falls — the probe-resistant void was an OVERLOAD-
  SELECTION over-promise: missing required labels may be covered by
  UNLABELED trailing closures only (the binder hands them to the LAST
  unbound slot; total-trailing counting let the 5-param designated init
  beat the 4-param delegation target, leaving header unbound → the
  binding-retry discarded the half-init). Diagnosed via staged
  instrumentation (args-shape log → runInitializer failure log). Plus
  both-unknowable equality compares marker NAMES ((function shapeKind)
  vs .none → false). Ice passes (56 nodes). **618/618 counted — ZERO
  failures (eleventh saturation). 585 zips + 33 OSS repos green.**
- 2026-07-09 iter 138: step 9 — cloned Secretive (105 files, PASSED ON
  ARRIVAL), CotEditor (595 — the second-biggest repo), Plash (vendored no
  Swift, dropped); units 618 → 620. CotEditor's two classes:
  AttributedString attribute transforms (replacingAttributes/setting/
  merging/transforming — text carries through, styling-proxy precedent)
  and $binding.animation()/transaction() (presentation-side; the binding
  carries through). CotEditor passes (25 nodes); Secretive (98 nodes,
  13 actions). **620/620 counted — ZERO failures (twelfth saturation).
  585 zips + 35 OSS repos green. Suite 253.**
- 2026-07-09 iter 139: step 9 — cloned Apple's OWN samples: sample-food-truck
  (82 files, 34 nodes), sample-backyard-birds (114, SwiftData-heavy),
  mlx-swift-examples (101); units 620 → 623. ALL THREE PASSED ON ARRIVAL —
  no failure class existed this iteration; the material addition is the
  step-9 action. **623/623 counted — ZERO failures (thirteenth saturation).
  585 zips + 38 OSS repos green. The arrival-green streak (Secretive,
  KeyboardCowboy, CodeEdit, Aidoku, Clop, Rayon, VirtualBuddy, now Apple's
  flagship samples) marks the long-tail regime: classes surface as API
  breadth, not language gaps.**
- 2026-07-09 iter 140: AlDente-Charge-Limiter (8 files) — 187:25
  `Helper.instance.appleSilicon!` nil: the machineHardwareName chain
  (utsname/uname/EXIT_SUCCESS/_SYS_NAMELEN/Data(bytes:count:)/
  String(bytes:encoding:)) inside a ProcessInfo extension. Four classes:
  (1) HOST HARDWARE IS REAL — HostRegistry.cFunction answers uname
  truthfully (fills the struct bag with the actual host's utsname fields,
  returns 0); absorbedCValue gives absorbed C calls writable bags;
  SCREAMING_SNAKE constants are numeric-absorbing markers; concrete
  numbers compare with unknowables through zero. (2) bare C names inside
  host-extension bodies were hijacked by the LAST-resort modifier rescue
  (self = TraceNode reads as view + trace catch-all modifier table):
  looksLikeCImport names and registry-real cFunctions now skip the
  rescue. (3) String/Array elementsEqual are real members. (4) launch
  hooks — applicationDidFinishLaunching runs before root render. The
  hook exposed Mythic's INTENTIONAL infinite background cycle
  (`Task { while true { …; try? await Task.sleep } }`) draining the
  global budget: background tasks now run a bounded 20k-step slice and
  PARK (tick marks budgetTrip; only callBackgroundClosure catches it;
  caller's budget untouched). AlDente ✅ (9 nodes, 2 actions — real
  arm64 detected), Mythic ✅ held. UTM + swift-composable-architecture
  fail IDENTICALLY at HEAD (pre-existing, the next classes). **624/630
  counted; 623 → 624 vs HEAD on the identical corpus. Suite 253 → 256.**
- 2026-07-09 iter 141: swift-composable-architecture — top-level parse
  failure at a literal `…` in `store.send(\.addSyncUp…)`: a DocC TUTORIAL
  SNIPPET. `.docc` catalogs are documentation resources to SwiftPM, never
  compile sources (TCA ships 475 snippet files of intentionally elided
  code) — the merge now excludes them. Extracted the duplicated
  ProjectCheck/demo merge into shared, TESTED ProjectMaterial
  (SwiftUIBridge). SCA advances to its real wall: `unsupported
  declaration (macroDecl)` at 21934 — next class. **624/630 counted
  (docc class eliminated, no collateral). Suite 256 → 257.**
- 2026-07-09 iter 142: swift-composable-architecture — `unsupported
  declaration (macroDecl)`: TCA declares freestanding AND attached macros
  (`@Reducer`, `#externalMacro`). Macro DECLARATIONS are compile-time
  constructs — the runtime image holds no entity — so they no-op beside
  the import no-op; uses ride the existing attribute/expansion paths. SCA
  advances two walls deep into root body: `'TestCase' has no case or
  static member 'Cases'` — next class. **624/630 counted (macroDecl
  class eliminated). Suite 257 → 258.**
- 2026-07-09 iter 143: swift-composable-architecture — `'TestCase' has
  no case or static member 'Cases'`: enums are NAMESPACES as often as
  value types, but EnumSymbol had no nestedTypes. Nested enum/struct/
  class decls inside enum bodies now collect and register (dotted +
  unclaimed-bare names, the struct-path pattern); staticMember(of:
  EnumSymbol) consults them first. Registering them UN-ABSORBED real
  paths in Rayon and OnlySwitch, exposing three adjacent gaps fixed in
  the same sweep: operator-function references (`reduce(0, +)`,
  `sorted(by: >)` — operator identifiers now resolve via Builtins.binary,
  HOFs accept function values), `localizedDescription` on interpreted
  Error enums (LocalizedError.errorDescription wins, NSError boilerplate
  fallback), and `exactly:`-labeled numeric ctors (`CGFloat(exactly:)`,
  `Int(exactly:)` nil on fractional). SCA advances to `unsupported
  member 'description' on Int` — next class. **624/630 counted (class
  eliminated, collateral healed same-iteration). Suite 258 → 260.**
- 2026-07-09 iter 144: swift-composable-architecture — `unsupported
  member 'description' on Int` (`store.count.description`).
  CustomStringConvertible is UNIVERSAL: a `description`/
  `debugDescription` fallback before the unsupported-member throw prints
  any native (Int, Double, Bool — String's own member still wins). SCA
  advances to `'$store' requires an @State or @Binding property`
  (@Perception.Bindable — dotted wrapper attribute) — next class.
  **624/630 counted (description class eliminated). Suite 260 → 261.**
- 2026-07-09 iter 145: swift-composable-architecture — `'$store'
  requires an @State or @Binding property`: `@Perception.Bindable var
  store`. Two gaps: @Bindable wasn't a wrapper kind at all (now
  @ObservedObject-shaped — `$model.field` projects into the model's box;
  README notes it), and hasAttribute only matched bare spellings —
  MODULE-QUALIFIED attributes (`@Perception.Bindable` ≡ `@Bindable`,
  `@SwiftUI.State` ≡ `@State`) now match by last component. SCA advances
  to `expected a view, got ImplicitMemberCall(buildEither)` — result-
  builder statics, next class. **624/630 counted ($store class
  eliminated). Suite 261 → 262.**
- 2026-07-09 iter 146: swift-composable-architecture FALLS — `expected
  a view, got ImplicitMemberCall(buildEither)`: TCA's IfLetStore shim
  calls the compiler-reserved builder statics AS API
  (`ViewBuilder.buildEither(first:)`). The statics now pass their
  argument through on the shared marker path (buildEither first/second;
  buildBlock/buildExpression/buildOptional/buildIf/
  buildLimitedAvailability single-or-array). The 796-file point-free
  flagship renders end-to-end: **390 nodes, 81 actions** — the six-wall
  chain (docc snippets → macroDecl → nested enums → description →
  $store/@Perception.Bindable → buildEither) closed. **625/630 counted
  — STRICTLY IMPROVED (624 → 625); only UTM remains. Suite 262 → 263.**
- 2026-07-09 iter 147: UTM (219 files) — `call depth exceeded` in root
  body: a user View-extension OVERLOAD of a SwiftUI modifier
  (`onReceive(_ name: Notification.Name…)` delegating to
  `self.onReceive(publisher…)`). Real overload resolution picks the
  framework's; ours re-entered the user method forever. Host-extension
  method closures now carry an ExtensionFrame; while a frame is active,
  a re-entrant same-name dispatch on a VIEW self prefers the registry
  gateway — helpers with no gateway alternative (fib-style, non-view
  selves) still recurse. First draft used `modifier(named:) != nil`
  alone; the trace registry's catch-all modifier table claims ANY name
  (iter-114 lesson re-learned) — gated by isViewValue(self). UTM ✅ (47
  nodes, 6 actions). **626/630 counted — ZERO failures (FOURTEENTH
  saturation). 585 zips + 42 OSS repos green. Suite 263 → 264.**
- 2026-07-09 iter 148: step 9 — MochiDiffusion cloned (58 files, Stable
  Diffusion UI; Whisky/Loop/ControlRoom were already aboard). Three
  classes on arrival, all URL/Observation surface: mutating
  `url.append(path:directoryHint:)` writes through the lvalue (Data
  precedent); `url.path(percentEncoded:)` METHOD vs legacy `path`
  property resolves by call shape (first(where:) precedent);
  `$store.computed` binds through accessors — Observation's
  access/withMutation idiom (`sortType` wrapping `_sortType`) — via a
  Box whose onChange runs the setter. MochiDiffusion ✅ (39 nodes, 4
  actions). **627/631 counted — ZERO failures (fifteenth saturation).
  585 zips + 43 OSS repos green. Suite 264 → 265.**
- 2026-07-09 iter 149: step 9 — Pulse cloned (212 files, kean's logging
  framework; Maccy/Swiftfin clones failed on network, deferred). Four
  classes on arrival: LOCAL `typealias` statements (bind the target type
  in scope — LoggerStore's Entity/Attribute/Relationship aliases); clock
  idioms absorb numerically (`.now + .milliseconds(500)` = 0.5 — anchors
  read the fresh epoch, durations their seconds, the DispatchTime rule
  generalized); Set ALGEBRA on the array-backed model (subtracting/
  union/intersection/symmetricDifference by areEqual membership);
  Optional.map applies the closure to non-nil natives (`url.map`).
  Pulse ✅ (110 nodes, 15 actions). **628/632 counted — ZERO failures
  (sixteenth saturation). 585 zips + 44 OSS repos green. Suite
  265 → 266.**
- 2026-07-09 iter 150: step 9 — Maccy (106 files) + CopilotForXcode
  (405 files) cloned. Copilot's chain: LOCAL DI-wrapper declarations
  (`@Dependency(\.workspacePool) var pool` in an init — fresh shared
  instance per type, cycle-guarded cache); TWO native-stack cycle guards
  (evaluationDepth in evaluate(), resolveAnnotatedDepth for cyclic
  marker graphs — lazy-global cycles used to SIGSEGV with no output,
  now located errors); Bundle.main is REAL identity (bundleURL/path —
  locateHostBundleURL's climb to "/" terminates) via BundleBox whose
  resource/metadata lookups ABSORB (first real-Bundle draft broke 21
  units on path(forResource:)/infoDictionary/bundleIdentifier — real
  nil where markers flowed; healed with the box + representative
  bundleIdentifier stand-in, README documents it); Optional
  map/flatMap accept function REFERENCES (`.flatMap(Bundle.init(url:))`).
  Copilot ✅ (3 nodes, 1 action). Maccy still ❌ (`'>' cannot compare
  nil and 200.0` — Defaults[.windowSize] subscript) — next class.
  **629/634 counted; Suite 266 → 268 (all green — the cycle-guard limit
  needed tightening to 350 nestings post-commit: 2000 × large evaluate
  frames still overflowed the test stack; corpus unaffected at 350).**
- 2026-07-09 iter 151: Maccy (106 files) — `'>' cannot compare nil and
  200.0` at root init: the sindresorhus/Defaults library.
  `Defaults[.windowSize]` now answers the KEY'S DECLARED DEFAULT on a
  fresh store (`Defaults.Keys.windowSize = Key("…", default:
  NSSize(450, 800))` — the @Default-wrapper doctrine at subscript
  level); registry catch-all bags store LABELED ctor arguments in
  config so `Key(default:)` and `NSSize(width:height:)` read back;
  store WRITES land in the key bag (Box.onChange → hostSetMember) and
  round-trip in-run; Int promotes for `.rounded()`. The bag change made
  CotEditor's vendored Package.swift loop REAL (`(target.plugins ?? [])
  + [.plugin(…)]`) — healed by extending the fresh-state doctrine:
  unknowables read EMPTY in array concatenation (README updated).
  Maccy ✅ (118 nodes, 8 actions). **630/634 counted — ZERO failures
  (SEVENTEENTH saturation). 585 zips + 46 OSS repos green. Suite
  268 → 269.**
- 2026-07-09 iter 152: step 9 — reminders-menubar (119 files) + Ollamac
  (36, arrival-pass) cloned; Swiftcord's default branch is docs-only
  (dropped). Five classes: VARIADIC parameters (`arguments: CVarArg...`
  gathers present-or-empty, labeled-first + positional rest);
  force-unwrap LVALUES (`components.hour! += 1` writes through);
  nil STORED closure properties sharing a modifier's name apply the
  registry modifier (`.onSubmit { }` on a Representable — first draft
  in specialMemberCall double-evaluated EVERY member-call base against
  the trace catch-all → exponential budget blowups across ~50 zips;
  moved into accessMember single-eval, then narrowed to
  closure-TYPED properties after the catch-all claimed damus's
  `mndb` nil-check too — the iter-114 lesson, third bite); mutating
  `String.replaceSubrange`; real `Range(_:in:)` (marker NSRanges
  honestly nil). reminders-menubar ✅ (109 nodes, 16 actions).
  **632/636 counted — ZERO failures (EIGHTEENTH saturation). 585 zips
  + 48 OSS repos green. Suite 269 → 270.**
- 2026-07-09 iter 153: step 9 — Meshtastic-Apple (458 files), nos (308),
  Harbour (211) cloned. Harbour's chain fixed: unknown members on
  NATIVES in compiled mode are UNMERGED-package extensions
  (`query.isReallyEmpty` from a utility dependency) and absorb like the
  interpreted-instance rule (placed LAST, after description/map — the
  first placement shadowed real members); LOCAL computed vars
  (`var placement: ToolbarItemPlacement { #if os(iOS) … }`) evaluate
  their getter once at declaration in the current scope. Harbour ✅
  (172 nodes, 9 actions). Meshtastic (protobuf `Link` shadowing
  SwiftUI's) and nos (member on `()`) are the next classes. **633/639
  counted — strictly improved (632 → 633). 585 zips + 51 OSS repos.
  Suite 270 → 271.**
- 2026-07-09 iter 154: nos (308 files) — two classes. `()` in member
  position under compiled imports is a SYNTHESIS gap
  (`@Dependency(\.analytics)` on a non-view class that nothing
  injects — device DI had something real): absorbs. Modifier chains
  hanging off an unresolved root (unmerged asset extension's
  `.atSymbol` + .aspectRatio/.blendMode) render as OPAQUE leaf nodes
  named for the root (Lottie-degrade precedent). nos ✅ (57 nodes,
  2 actions). Note: the suite JUMPED 271 → 292 on a clean tree —
  the stale-build gotcha had been silently SKIPPING seven committed
  suites; all green once relinked. Meshtastic (protobuf `Link`
  shadowing SwiftUI's) is the last new-material class. **634/639
  counted — strictly improved (633 → 634). Suite 292 → 293.**
- 2026-07-09 iter 155: Meshtastic-Apple (458 files) — three classes.
  Protobuf's `struct Link` shadows SwiftUI's Link: when NO initializer
  fits the arguments and a registry constructor shares the name, the
  binding error now routes the existing cross-module retry (the
  `?? overloads.first` tolerance had silently picked protobuf's `init()`
  and dropped every argument). Overflow operators `&+ &- &* &<< &>>`
  wrap like real Swift (protobuf hashing). Instance.description is
  cycle-safe (depth-elided — protobuf parent/child links recursed
  describe-to-death, third guard-bypassing SIGSEGV found by pty
  backtrace). Meshtastic ✅. **635/639 counted — ZERO failures
  (NINETEENTH saturation). 585 zips + 51 OSS repos green. Suite
  296 → 297.**
- 2026-07-09 iter 156: step 9 — Pearcleaner (109 files), Applite (111),
  FreeChat (40, arrival-pass) cloned. Two classes: BITWISE operators
  absorb unknowable flags to zero (`kFSEventStreamCreateFlagUseCFTypes |
  …` — lowercase-k C constants from unmerged frameworks; the arithmetic
  doctrine extended); creating a directory at an UNKNOWABLE location is
  accepted inertly (fresh-sandbox analog — Applite's SQLite bootstrap
  fatalError'd where the device succeeds). Pearcleaner ✅, Applite ✅
  (32 nodes, 2 actions). **638/642 counted — ZERO failures (TWENTIETH
  saturation). 585 zips + 54 OSS repos green. Suite 300 → 301.**
- 2026-07-09 iter 157: step 9 — Swiftfin (817 files, the BIGGEST unit),
  Sidekick (276), Basic-Car-Maintenance (58, arrival-pass) cloned.
  Swiftfin's chain: `for case let x as T` patterns (primitives really
  type-check — String skips Ints); `[keyPath:]` subscripts read AND
  write; same-labeled overloads disambiguate by argument ARRAY-ness/
  CLOSURE-ness; a RUNNING declaration never re-enters itself — inits
  (extension convenience → memberwise; extension inits don't suppress
  memberwise) AND methods (TCA's `send#StoreTask ↔ send#Task`
  return-type siblings; exhausted sets absorb). The send fix initially
  no-oped — the callWithArguments bracket patch had silently not
  landed (caught by DEPTH/DISPATCH instrumentation: active=0 at depth
  199). SCA collateral healed same-iteration: @autoclosure zero-arg
  calls yield the value; ForEach iterates instance collections
  (elements-shaped property or fresh-empty); $store.scope dispatches
  the model's member; keypath-as-function (SE-0249); the fixed nesting
  guard became a REAL pthread stack probe (<1MB headroom → located
  error) after 350 undersized TCA and 1000 overflowed test threads.
  USER-reported live-render fixes: UnevenRoundedRectangle real ctor,
  unknowable shapes degrade to Rectangle, unknowables read "" in
  interpolation AND Text (marker dumps never render). Swiftfin ✅
  (14 nodes, 2 actions) + SCA ✅ held (390 nodes, 81 actions — real
  cores now). Sidekick next. **640/645 counted. Suite 301 → 302.**
- 2026-07-09 iter 158: Sidekick (276 files) — three classes. BACKTICKED
  statics on enums normalize (`static var \`default\`` — the
  case/property rule extended to enum static members); static COMPUTED
  setters are assignable via Self./TypeName. (the UserDefaults-backed
  settings idiom — a Box whose onChange runs the setter; `Self` resolves
  as the enclosing type in lvalue position); protocol-extension members
  dispatch on ENUM CASES through recorded conformances (`extension
  RawRepresentable where Self: NotificationName { var name }`), plus
  bare static LVALUES inside enum static bodies write the static cache
  (found by the regression test). Sidekick ✅ (115 nodes, 7 actions).
  **641/645 counted — ZERO failures (TWENTY-FIRST saturation). 585 zips
  + 57 OSS repos green. Suite 302 → 303.**
- 2026-07-10 iter 159: step 9 — ACHNBrowserUI (208 files) + Bark (117,
  arrival-pass) cloned (MovieSwiftUI/SwiftUI-Kit already aboard). One
  class: `fallthrough` runs the NEXT case's body without re-matching —
  selectCase exposes the case index; both the statement executor and
  the view-builder collector loop while the trailing statement is
  `fallthrough` (Swift requires it last, so trailing-drop is exact);
  builder switches collect views across chained cases.
  ACHNBrowserUI ✅ (90 nodes). **643/647 counted — ZERO failures
  (TWENTY-SECOND saturation). 585 zips + 59 OSS repos green. Suite
  322 → 323.**
- 2026-07-10 iter 160: step 9 — mlem cloned (1171 files, the BIGGEST
  unit yet; Lemmy client) — PASSED ON ARRIVAL (1 node: the root gates
  on absorbed onboarding state, honestly minimal headlessly).
  Vernissage's repo is README-only (dropped); Apple's Fruta isn't a
  git clone. No failure class existed this iteration — the material
  addition is the step-9 action, the second all-arrival iteration
  (139 precedent). **644/648 counted — ZERO failures (TWENTY-THIRD
  saturation). 585 zips + 60 OSS repos green. Suite 323 (unchanged —
  no new capability, no new test).**
- 2026-07-10 iter 161: step 9 — winston (448 files), OpenArtemis (92),
  swift-chat (5, arrival-pass) cloned. Two classes: FORMATTING
  recoveries parse to a correct tree and are tolerated
  (`@Environment (\.colorScheme)` with a stray space — Xcode builds
  it; SwiftParser recovers with an "extraneous whitespace" error we no
  longer treat as fatal); unlabeled trailing closures bind by SE-0286
  FORWARD scan — the first unbound function-typed parameter, not the
  last slot (`getNavigationView { … }` fills `content:` past defaulted
  Bools). winston ✅, OpenArtemis ✅ (259 nodes, 24 actions).
  **647/651 counted — ZERO failures (TWENTY-FOURTH saturation).
  585 zips + 63 OSS repos green. Suite 323 → 324.**
- 2026-07-10 iter 162: the biggest class was a REGRESSION from the
  merged parallel work (ObjC trampoline + RuntimeValue inline-scalar
  rework): an object-returning trampoline method handing back nil
  collapsed to `()` — fresh `UserDefaults.object(forKey:)` must be NIL
  (IceCubes + Meshtastic both died on `if let x = … as? Bool`). Fixed:
  returnsObject && nil result → .nilValue; void encodings keep ().
  Healing it exposed Whisky's bare `path(percentEncoded:)` INSIDE a URL
  extension (the method/property collision, implicit-self flavor) —
  routed like the member form. Meshtastic now renders 777 nodes (real
  trampoline formatters). IceCubes ✅, Meshtastic ✅, Whisky ✅.
  **647/651 counted — ZERO failures (TWENTY-FIFTH saturation).
  Suite 328 → 329.**
- 2026-07-10 iter 163: step 9 — Solstice (106 files, arrival-pass) +
  Gifski (39) cloned; sindresorhus/Actions has no public sources
  (dropped). One class, two halves: TUPLE-pattern stored properties
  (`let (first, second, third): (A, B, C)` — Gifski's
  @dynamicMemberLookup Tuple3 — each element declares with its split
  annotation) and tuple DESTRUCTURING assignment (`(self.first, …) =
  (first, …)` writes element-wise, `_` slots skip; the regression test
  exercised the init the headless run never reached). Gifski ✅
  (12 nodes, 3 actions). **649/653 counted — ZERO failures (TWENTY-
  SIXTH saturation). 585 zips + 65 OSS repos green. Suite 329 → 330.**
- 2026-07-10 iter 164: step 9 — NetNewsWire (601 files, the AppKit
  giant deferred since the ladder began) + AudioKit Cookbook (133)
  cloned; System-Color-Picker has no public sources (dropped). Three
  classes: SHEBANG lines strip in the merge (build-phase scripts are
  legal Swift after `#!`; NNW's VerifyNoBS.swift); marker ARITHMETIC
  reads unknowable operation-DSL operands as zero, one- and two-sided,
  AFTER typed marker arithmetic has its chance (AudioKit's
  `.phasor(f) * .randomNumberPulse(…)`, `0.0 + .jitter(…)`); member
  WRITES through a NIL base absorb in compiled mode
  (`sequencer.tracks[1].length = …` — the marker-write doctrine).
  NetNewsWire ✅ (14 nodes), Cookbook ✅ (171 nodes, 2 actions).
  **651/655 counted — ZERO failures (TWENTY-SEVENTH saturation).
  585 zips + 67 OSS repos green. Suite 330 → 331.**
- 2026-07-10 iter 165: step 9 — mastodon-ios (807 files, the official
  client) + DockDoor (189, arrival-pass) cloned; linearmouse was
  already aboard. One class: Sourcery inline-SCRATCH files hold bare
  method fragments meant for inlining elsewhere — HARD parse errors
  prove a file is not a member of any compiling target, so the merge
  skips it (gated on the sourcery:inline marker for cheapness;
  destination files with the same markers still merge — their inline
  blocks are real code inside extensions; the recovered-diagnostics
  tolerance from iter 161 keeps winston-style files IN).
  mastodon-ios ✅ (2 nodes). **653/657 counted — ZERO failures
  (TWENTY-EIGHTH saturation). 585 zips + 69 OSS repos green.
  Suite 331 → 332.**
- 2026-07-10 iter 166: step 9 — boring.notch (123 files, arrival-pass
  at 2056 NODES — the biggest render yet), Lunar (133, arrival-pass),
  iina (223) cloned. iina's chain: a guard-else ending in an ABSORBED
  Never-return (`exit(1)` in the bundled iina-cli tool) exits the scope
  as the compiler proved (.returnValue instead of the must-exit throw);
  STATIC-method overload sets never re-enter the running declaration
  (Logger.log's @autoclosure convenience → closure-taking sibling — the
  iter-157 instance rule extended to statics at all three pick sites).
  iina ✅ (12 nodes, 3 actions). **656/660 counted — ZERO failures
  (TWENTY-NINTH saturation). 585 zips + 72 OSS repos green. Suite
  332 → 333.**
- 2026-07-10 iter 167: step 9 — bitwarden-ios (1872 files, the NEW
  biggest unit — the SwiftUI-first password manager) and WWDC (259,
  insidegui's AppKit-heavy conference app) cloned. BOTH PASSED ON
  ARRIVAL (23 nodes/2 actions; 2 nodes) — the third all-arrival
  iteration (139, 160 precedents). **658/662 counted — ZERO failures
  (THIRTIETH saturation). 585 zips + 74 OSS repos green. Suite 333
  (unchanged — no new capability, no new test).**
- 2026-07-10 iter 168: step 9 — element-x-ios (1161 files,
  arrival-pass) + home-assistant-ios (893) cloned. home-assistant's
  chain: top-level `defer` runs at PROCESS exit on device — invisible
  to rendering, honestly skipped (block-level defer already existed
  via the parallel session); an interpreted enum SHADOWING a host type
  crosses the module boundary for statics it doesn't declare (design-
  token `Color` vs SwiftUI.Color — the registry marker path); and the
  PROTOCOL-DEFAULTS walk never re-enters the running overload
  (IconDrawable's image(ofSize:color:) → edgeInsets form — the FIFTH
  .first pick site, found after three instrumentation rounds; the
  superclass walk hardened alongside). home-assistant ✅ (27 nodes,
  3 actions). **660/664 counted — ZERO failures (THIRTY-FIRST
  saturation). 585 zips + 76 OSS repos green. Suite 333 → 334.**
- 2026-07-10 iter 169: step 9 — anytype-swift (3196 files, the NEW
  biggest unit by a factor of 1.7) + pocket-casts-ios (1631,
  arrival-pass) cloned. anytype's chain: generated NAMESPACE enums
  claim ubiquitous bare names (SwiftGen's Loc.Text registering bare
  `Text` — found via three-stage instrumentation: the shadow never hit
  invoke(.type), the alert-builder resolveIdentifier served
  .enumType(Loc.Text), and a protobuf extension's init(data:) got the
  tolerant pick) — the .enumType invoke path now carries the iter-155
  cross-module retry (strict-miss + host constructor → registry); VOID
  bases from absorbed chains accept member writes (the nil-base rule
  widened). anytype ✅ (6 nodes, 1 action). **662/666 counted — ZERO
  failures (THIRTY-SECOND saturation). 585 zips + 78 OSS repos green.
  Suite 336 → 337.**
- 2026-07-10 iter 170: the merged M4 root-selection work (the app's
  DECLARED root wins) made the verifier render every unit's REAL root —
  exposing twelve genuine gaps that the old heuristic roots never
  reached (650/666 at iteration start). The biggest class (2 units,
  MakeItSo + Mythic): enum-case ORDERED comparisons — synthesized
  Comparable orders by DECLARATION position (raw values ignored); bare
  unresolved `.member` operands resolve against the other side's own
  symbol; numeric raws compare through numbers; anything else reads
  FALSE (fresh-state ordering). MakeItSo ✅, Mythic ✅. Ten singleton
  classes remain at the honest roots — the next iterations' queue.
  **652/666 counted (650 → 652 strictly improved). Suite 340 → 341.**
- 2026-07-10 iter 171: honest-roots queue — NetNewsWire. Two classes:
  `value is Type` EXPRESSIONS (checkable shapes really check —
  primitives, interpreted symbols through the superclass walk, host
  natives by registry type name; unknowables read FALSE: fresh
  UserDefaults.object is nothing yet); bare static COMPUTED setters
  assign under a `.type` self (`firstRunDate = Date()` inside a
  property-initializer closure, the setter living in a private
  extension — the iter-158 member-form rule, bare flavor).
  NetNewsWire ✅ (22 nodes, 9 actions — richer than the heuristic
  root ever reached). **653/666 counted (652 → 653). Suite 341 → 342.**
- 2026-07-10 iter 172: honest-roots queue — swift-composable-
  architecture. `'TicTacToe' has no case or static member 'State'`:
  @Reducer on an ENUM generates nested State/Action at compile time —
  macro artifacts the merge can't see. MACRO-ATTRIBUTED enums (an
  uppercase attached attribute) absorb uppercase member misses as type
  markers, and DOTTED markers called as constructors build registry
  bags (TicTacToe.State()). Two collateral rounds tightened the gates:
  a broad absorb + plain-marker calls sent SwiftBar's launch hook into
  budget exhaustion — plain enums keep the fast throw the hook
  tolerance depends on. SCA ✅ (6 nodes, 2 actions at its honest
  root). **654/666 counted (653 → 654). Suite 342 → 344.**
- 2026-07-10 iter 173: honest-roots queue — winston. KEYED subscript
  assignment auto-vivifies the dictionary when the store reads
  deferred/nil/absorbed (`self.routers[tab] = router` where
  `var routers: [Tab: Router]` initializes in an init the synthesis
  absorbed) — the caching-subscript idiom round-trips. The regression
  test surfaced `===`/`!==`: IDENTITY operators now compare
  class-backed instances and host objects by reference. winston ✅ —
  121 nodes and 14 actions at the honest root (the heuristic root saw
  1 node). **655/666 counted (654 → 655). Suite 346 → 347.**
- 2026-07-10 iter 174: honest-roots queue — the biggest class had grown
  to TWO units (SwiftBar's hook advanced into it + pocket-casts):
  `DateFormatter.string(from:)` with an UNKNOWABLE operand now formats
  as the fresh string ("" — the string-context absorption; numeric
  intervals format as real epoch dates; wrong values still throw, now
  with the operand named). Coerce.isUnknowable is the shared test.
  SwiftBar ✅, pocket-casts ✅ (20 nodes, 4 actions at the honest
  root). **656/666 counted (654 → 656). Suite 347 → 348.**
- 2026-07-10 iter 175: honest-roots queue — home-assistant-ios. The
  Section-shadow retry kept failing DOWNSTREAM, unwinding a seven-class
  chain: STATIC overloads pick by call shape (KioskRow.label(_:
  systemSymbol:) vs (_:icon:) — .type/.enumType member-call dispatch
  mirrored the instance branch); keypaths compare by components;
  `.map(Type.init)` constructs per element; TYPE-declared operator
  functions run with Comparable DERIVATION (<=/>/>= from the declared
  <); tuples compare LEXICOGRAPHICALLY (the version-triple idiom);
  Info.plist loads REAL from a seeded sandbox file (BundleBox
  url(forResource:) writes minimal version stand-ins; real
  NSDictionary/NSArray(contentsOf:) constructors); NSRegularExpression
  is the REAL Foundation regex (RegexBox + NSTextCheckingResult ranges
  + NSRange ctor) — SwiftGen's PlistDocument and their strict Version
  parser run genuinely. home-assistant ✅ at 355 nodes/8 actions (was
  27). **657/666 counted (656 → 657). Suite 348 → 351.**
- 2026-07-10 iter 176: honest-roots queue — EhPanda. One tight class:
  annotation-less bindings in a MULTI-BINDING declaration share the
  NEXT annotation in their run (`var igneous, memberID, passHash:
  String?` — all three are String?, nil until assigned; initializers
  break the run). EhPanda ✅ at 164 nodes/20 actions. Four honest-root
  singletons remain (Basic-Car, Rayon, Pearcleaner, Planet).
  **658/666 counted (657 → 658). Suite 351 → 352.**
- 2026-07-10 iter 177: honest-roots queue — Basic-Car-Maintenance.
  PROPERTY/METHOD name collisions (`var filteredReadings` beside
  `func filteredReadings(for:)`): a BARE reference is the property when
  every method overload requires arguments; CALLS still dispatch the
  method (the unqualified and member call branches now engage on
  collisions even with a single overload — the regression test caught
  the call side going to the property). Basic-Car ✅ at 93 nodes/9
  actions. Three honest-root singletons remain (Rayon, Pearcleaner,
  Planet). **659/666 counted (658 → 659). Suite 352 → 354.**
- 2026-07-10 iter 178: honest-roots queue — Rayon. Two classes: bare
  sibling STATICS resolve from any member context (an init parameter
  defaulting to `defaultBlurRadius`, a static let — instanceMember
  falls through to staticMember); sibling app targets in a monorepo
  declaring the SAME namespace enum now UNION their members (Rayon +
  mRayon both ship `enum UIBridge`; last-wins had kept the iOS variant,
  which lacks toggleSidebar — separate targets never collide on
  device). Rayon ✅ at 157 nodes/15 actions (actions click now). Two
  honest-root singletons remain (Pearcleaner, Planet). **660/666
  counted (659 → 660). Suite 354 → 355.**
- 2026-07-10 iter 179: honest-roots queue — Pearcleaner. Two classes:
  [RuntimeValue] BRIDGES to NSObject (NSArray) and smuggled interpreter
  boxes into Foundation — trampoline marshaling now converts arrays
  ELEMENT-WISE before the NSObject cast, so
  UserDefaults.set(stringArray, forKey:) genuinely round-trips (the
  exception text showed RuntimeValue.host boxes inside the NSArray);
  UNMERGED environment-object types (an external package's Updater)
  absorb — a bag stands in for the App shell's real injection instead
  of throwing. Pearcleaner ✅ at 54 nodes/2 actions. Planet's init
  cycle is the LAST honest-root singleton. **661/666 counted
  (660 → 661). Suite 355 → 356.**
- 2026-07-10 iter 180: honest-roots queue — Planet, the LAST singleton.
  Two classes: GLOBAL function overloads pick by call shape with the
  running-declaration exclusion (L10n's variadic form delegates to its
  single-argument sibling; globals hold one closure per name, so a
  side table carries the set — the sixth and final home of the
  overload-delegation family); `Self.member = value` assigns statics
  from INSTANCE contexts (Self is the instance's type). Planet ✅ at
  170 nodes/7 actions. **662/666 counted — ZERO failures (THIRTY-THIRD
  saturation, the FIRST at the honest DECLARED roots). 585 zips + 77
  OSS repos green, actions clicking on real app roots end-to-end.
  Suite 356 → 357.**
- 2026-07-10 iter 181: step 9 — apple-browsers (4814 files, the
  DuckDuckGo macOS+iOS monorepo — the new biggest by 1.5×, a
  half-million-line merge) + WordPress-iOS (2582, arrival-pass)
  cloned. Two classes: SwiftParser's default nesting ceiling (~256)
  trips on generated preview fixtures (bookmark literals nested dozens
  deep) — parsing gets 2048 levels while evaluation keeps its own
  stack probe (densified to every-16th check + 1.5MB headroom after
  the regression test out-ran the 64-step sampling); an interpreted
  throw ESCAPING the launch hook is an absorbed-environment failure
  (didFinishLaunching can't throw in compiled Swift) and is tolerated.
  apple-browsers ✅ (4 nodes). **664/668 counted — ZERO failures
  (THIRTY-FOURTH saturation). 585 zips + 79 OSS repos green. Suite
  357 → 358.**
- 2026-07-10 iter 182: step 9 — firefox-ios (2034 files, Mozilla's
  browser) + WordPress-iOS (2582, arrival-pass) + kiwix-apple (193)
  cloned. Firefox's chain: LOCAL type declarations collect into the
  current scope (Danger scripts declare `struct FileCheck` inside a
  function); BOTH-unknowable arithmetic yields a CHAIN for any
  operator (the domain is unknowable — array concat vs signal math;
  bare `.implicitMember` operands joined the unknowable family) —
  with TYPED marker pairs excluded so init-elementwise and clock
  arithmetic keep their own rules (the suite caught both shadowings).
  firefox-ios ✅ (36 nodes, 1 action). kiwix's super-context class is
  next. **665/670 counted. 585 zips + 81 OSS repos. Suite 358 → 360.**
- 2026-07-10 iter 183: kiwix-apple — `super` in STATIC contexts: an
  NSManagedObject subclass's `static func fetchRequest()` delegates to
  `super.fetchRequest()`. Interpreted superclasses dispatch their real
  statics (.type parent); HOST superclasses absorb through a type
  marker. kiwix ✅ (9 nodes). **666/670 counted — ZERO failures
  (THIRTY-FIFTH saturation). 585 zips + 81 OSS repos green — Firefox,
  DuckDuckGo, Mastodon, Bitwarden, Home Assistant, WordPress, and
  NetNewsWire all interpreting at their declared roots. Suite
  360 → 361.**
- 2026-07-10 iter 184: THE QUARANTINE EMPTIES. Re-examined all three
  parked units against 150 iterations of accumulated capability: the
  Realm pair (parked at iters 32-35) PASSES OUTRIGHT — @Persisted/
  ObjectId/Results machinery absorbed by rules built long since; and
  isowords (parked ~iter 106 for its server half) needed exactly ONE
  class — Point-Free's `>=>` Kleisli composition (Prelude, unmerged)
  now composes like `>>>` (the monadic layer absorbs headlessly).
  isowords ✅ (19 nodes), SwiftUIRealm ✅, RealmDataBase ✅. The
  quarantine map is EMPTY; the only exclusion left is MonitorControl
  (⚪ genuinely no View structs). **669/670 counted — ZERO failures,
  ZERO quarantines (THIRTY-SIXTH saturation). Every SwiftUI unit in
  the corpus — 585 zips + 82 OSS repos — interprets, renders its
  declared root, and survives its clicks. Suite 368 → 369.**
- 2026-07-10 iter 185: step 9 — Signal-iOS (2522 files, the last
  untried giant) + ProtonMail ios-mail (960) cloned. BOTH PASSED ON
  ARRIVAL — the fourth all-arrival iteration (139/160/167 precedents).
  **671/672 counted — ZERO failures, ZERO quarantines (THIRTY-SEVENTH
  saturation). 585 zips + 84 OSS repos; the sole exclusion remains
  MonitorControl (⚪ no View structs). Suite 369 (unchanged — no new
  capability, no new test).**
- 2026-07-10 iter 186: step 9 — iTorrent (185 files), amperfy (382,
  arrival-pass), Unwatched (473, arrival-pass) cloned. iTorrent's
  chain: `(@MainActor() async -> Void)?` with no space is a formatting
  recovery Xcode accepts (the tolerance list gained the function-type
  pair, now SHARED between the parse gate and sourceHasHardErrors);
  and a file with HARD errors (a literal editor placeholder + a
  half-written member access in LiveActivityService.swift) can't be in
  any compiling target — the merge drops such files, gated on the two
  signatures (`<#`, sourcery:inline) after a universal per-file parse
  measured 14.5min corpus-wide vs 8. iTorrent ✅ (8 nodes, 2 actions).
  **674/675 counted — ZERO failures (THIRTY-EIGHTH saturation).
  585 zips + 89 OSS repos. Suite 369 → 373.**
- 2026-07-10 iter 187: step 9 — session-ios (993 files, the Signal
  fork) cloned; ProtonVPN/Grocy repos are gone from GitHub. Four
  classes: the THIRD `@MainActor()`-recovery sibling message joins the
  tolerance list; merged tooling SCRIPTS whose top-level statements
  throw or trap fail ALONE (their crash is the script's, not the
  app's — InterpretedThrow and non-fatal traps tolerate per-statement
  in compiled mode; budget/stack stay fatal); Double INTERVAL patterns
  match by containment (`case oneGigabyte...greatestFiniteMagnitude:`);
  `String.appending` is a real native so the optional-taking extension
  overload delegates instead of recursing. session-ios ✅ (7 nodes).
  **675/676 counted — ZERO failures (THIRTY-NINTH saturation).
  585 zips + 90 OSS repos. Suite 373 → 375.**
- 2026-07-10 iter 188: step 9 — dimeapp (94 files, arrival-pass at 255
  nodes/14 actions — the expense tracker renders its full dashboard)
  + nextcloud-ios (406, arrival-pass) cloned. The fifth all-arrival
  iteration. **677/678 counted — ZERO failures (FORTIETH saturation).
  585 zips + 92 OSS repos; sole exclusion MonitorControl (⚪). Suite
  375 (unchanged — no new capability, no new test).**
- 2026-07-10 iter 189: step 9 — blink (arrival-pass at 8 nodes) +
  Provenance (1989 files) cloned; Provenance's five-wall chain:
  Dangerfile.swift hard-errors out of the merge (Danger's Ruby-ish
  DSL), `throws async` effect-order recovery tolerated, type-base
  subscripts absorb in compiled mode (vendored Defaults shim shadowed
  by a design-token namespace), and — the big one — `#if` members
  inside ENUM bodies now expand to their active clause (theme palettes
  split `enum Colors` statics across canImport branches; collected
  ZERO before) with the same expansion for SWITCH arms (amperfy gates
  `case .developer` + its arm behind `#if DEBUG` — caught as a
  mid-iteration regression when the case appeared but the arm didn't).
  A speculative sibling-namespace UNION for nested enums was tried and
  REVERTED: EhPanda proved extension members attach to the specific
  dotted symbol, so franken-cases lose them; bare names stay
  first-wins, own-nested-types win in scope. **679/680 counted — ZERO
  failures (FORTY-FIRST saturation). 585 zips + 94 OSS repos. Suite
  375 → 377.**
- 2026-07-10 iter 190: LiveCheck queue #1 (icecubes fetch chain absorbs
  before respond) — SIX links unwound to make the request land:
  `type(of:)` builtin + metatype equality (MastodonClient's makeURL
  branches on `type(of: endpoint) == Oauth.self` — was "unresolved
  identifier 'type'"), return-position generic binding (`return try
  await client.get(…)` inside `-> [Status]` binds Entity via
  enclosingReturnAnnotations), `URLRequest(url:)`-as-TraceNode bags
  yield their url to `data(for:)` (THE silent wall: the trace
  registry's catch-all, not ViewRegistry's), unknowable `isEmpty` reads
  TRUE (agreeing with for-in-empty and count==0; IceCubes' cache guard
  falls to the network branch as on a fresh install; Bool equality
  compares through the fresh reading), Observation's typed environment
  (`@Environment(Client.self)`) fills from ambient `.environment(model)`
  injections (ambient-only — no fresh instantiation). Requests now
  land: "trends/statuses hit"; next wall named (HTMLString single-value
  custom decode → queue #1). Diagnostics added: LIVECHECK_TRACE +
  INTERP_TRACE_CALLS. **674/680 ProjectCheck (baseline moved -5 by
  parallel-session merges — SwiftUIRealm/ImageDrawing/SwiftBar/
  VirtualBuddy/winston fail at HEAD, pre-existing, next queue); suite
  383 → 388; LiveCheck 2/4 with the fetch-chain class ELIMINATED.**
- 2026-07-10 iter 191: property observers fired during INITIALIZATION
  (parallel-merge regression, 3 projects): a declared init's self-store
  ran willSet/didSet with the property still uninitialized — winston's
  Nav willSet compared the void read ("cannot compare () and
  TabIdentifier.posts"), VirtualBuddy hit the same in root init, and
  SwiftBar's observer-writes-property shape cycled to the nesting
  guard. Fix: `initializingInstances` bracket around runInitializer —
  self-stores inside a declared init are DIRECT, observers fire only
  post-init (compiled semantics; PropertyObserverTests grew the
  winston-shaped case). **674 → 677/680; suite 388 → 389; remaining:
  SwiftUIRealm ($task projection) + ImageDrawing (binding index) —
  next queue.**
- 2026-07-10 iter 192: Realm observation wrappers project
  (SwiftUIRealm): `@ObservedRealmObject var task` was an unmapped
  wrapper, so `$task.taskStatus.wrappedValue = .missed` threw "'$task'
  requires an @State or @Binding property" — mapped to .observedObject
  (@Bindable-shaped member projections) with @StateRealmObject →
  .stateObject alongside (RealmWrapperProjectionTests). ImageDrawing's
  binding-index singleton healed via parallel merge. **677 → 679/680 —
  ZERO failures (FORTY-SECOND saturation); suite 389 → 395.**
- 2026-07-10 iter 193: LiveCheck queue #1 (single-value custom Codable
  decode) — custom `init(from: Decoder)` now RUNS against Decoder stubs:
  scalar JSON through singleValueContainer (HTMLString decodes from a
  plain string), object JSON through a keyed container (decode/
  decodeIfPresent/contains with CodingKeys names + snake_case fallback;
  Account computes cachedDisplayName itself), structural decode kept as
  the fallback when a custom init trips an unsupported container
  feature. En route: module-qualified extensions merge into the bare
  declared type (`extension Models.Visibility` — iconName was
  unreachable), stdlib statics answer through SHADOWING app enums
  (Env.Duration vs Duration.seconds → typed clock marker), `Swift.`-
  qualified markers unwrap, and the LiveCheck probe's depth guard rose
  16 → 48 (IceCubes' composition nests past 16 — the list subtree
  vanished silently). icecubes: 101 → 939 strings, decode errors GONE;
  next wall named (EmojiText/HTMLString author content). **679/680
  unchanged; suite 395 → 397; LiveCheck 2/4 with the decode class
  ELIMINATED.**
- 2026-07-10 iter 194: LiveCheck queue #1 (icecubes author content) —
  four walls unwound, one precisely named: AttributedString's LABELED
  ctors carry text (`stringLiteral:` wrapped, `markdown:` converts for
  real — was always ""); ForEach rows SALT per-view state cells by
  element identity (id/scalar/index — closes the documented
  "ForEach rows share a site" divergence; placeholder rows held ONE
  shared StatusRowViewModel), threaded through the trace ForEach AND
  the generic recorder's data expansion; property-wrapper BACKING
  writes (`_label = .init(initialValue:)`) unwrap the seed BEFORE
  annotation resolution (a concrete String annotation ate the marker
  through its own ctor); one-arg `insert` on Set-typed storage is
  Set.insert (append-if-absent + (inserted, memberAfterInsert)) — a
  swallowed SceneDelegate task died on Array.insert(at:) semantics.
  Diagnostics grew: INTERP_TRACE_STATE (⌘ cell hits + ✍ property
  writes), ⊙ VM-identity probe, ⚠ swallowed-task deaths. The rung
  stays 🟡 on ONE scoped wall: the withAnimation-closure state write
  (queue #1, repro recipe included). **679/680 unchanged; suite
  397 → 405; LiveCheck 2/4.**
- 2026-07-10 iter 195: LiveCheck queue #1 CLOSED — **icecubes-timeline-ui
  GREEN (2/4 → 3/4 rungs): 20 fixture authors render in the tree.** The
  withAnimation write mystery resolved as a CASCADE of language gaps hit
  in sequence: payload wildcards (`case .display(let items, _)` died on
  discardAssignmentExpr), the property/method COLLISION rule missing
  from the protocol-defaults walk (Status's `var isHidden` vs AnyStatus's
  `isHidden(in:)` returned the METHOD closure for a bare read → `!` on a
  closure), the same collision at CALL sites (the own property evaluated
  then "false is not callable" — now dispatches the FITTING protocol-
  extension method), Layout-conformer callAsFunction sugar (media cells:
  `_Layout(…) { content }` renders its content), `_ =` discard sinks,
  and tuple-EXPRESSION patterns matching elementwise (`case (_,
  .hideAll)`). Plus: CGFloat(nil-from-absorbed-environment) reads fresh
  zero (amperfy's FFT array); UserDefaults.standard now maps to an
  ephemeral per-process suite (corpus apps' real writes accumulated in
  ~/Library/Preferences across runs). movieswiftui advanced too (1 → 12
  strings, 0 → 6 closures, root app:StoreProvider). **LiveCheck 3/4;
  suite 405 → 415; ProjectCheck 677/680 with the two failures proven
  ENVIRONMENT-FLAKY (fail at HEAD standalone; new queue #1 =
  determinism).**
- 2026-07-10 iter 196: ProjectCheck queue #1 (corpus-run determinism)
  CLOSED — the metric is REPRODUCIBLE again: (1) the check tools
  re-exec themselves under SWIFT_DETERMINISTIC_HASHING (per-process
  seeded hashing flipped nextcloud between failure CLASSES across
  identical runs); (2) per-VERIFICATION bridge resets — fresh sandbox
  root + blob store + ephemeral-defaults wipe (project N's files/
  defaults leaked into project N+1 within one --all run); (3) test-
  INFRASTRUCTURE exclusions (apple-browsers' `tests-server` web-server
  tool, `TestUtilities` RunLoop wrappers, `scripts/` repo tooling —
  its db-decrypt CLI runs a REPL loop at top level); (4) a clicked
  action's EXPLICIT fatalError is the app's designed termination
  (nextcloud's DEBUG "Crash test" button — record, continue clicking;
  render-time fatals stay fatal); (5) host-extension INITS dispatch as
  real ctor overloads when they strictly fit, running-init excluded
  (browsers' `extension Text { init(_ item:) }` was stringifying its
  enum arg into rendered text). **677 → 678/680 measured IDENTICALLY
  twice; LiveCheck 3/4 twice; suite 415 → 417. Sole failure: apple-
  browsers' main() boot recursion — new queue #1, now stable.**
- 2026-07-10 iter 197: apple-browsers' boot "recursion" CLOSED — the
  cycle was a generated namespace enum claiming bare `Text` (the
  SwiftGen shape): `Text(value)` inside `extension Text { init(_
  textItem:) }` dispatched through the .enumType init path, which had
  NO active-initializer exclusion and a label-loose registry-crossing
  test — 152 self-nested init frames before the stack probe (found
  via the new gated call-stack dump ✖). Fixed: active-init exclusion
  + POSITIVE runtime-type fit (valueIsType per argument) before
  interpreted-vs-registry choice, in both the enumType path and the
  hostFunction extension-init dispatcher. The unwound chain behind it:
  DOTTED extensions now collect order-independently (`extension
  Pixel.Event` in a file sorting before `extension Pixel { enum Event
  }` deferred + retried post-pass; stranded synthetics reconcile),
  Locale statics answer through shadowing enums, TimeInterval
  constructs as Double, unary minus reads unknowables' fresh numeric,
  and NUMBER-vs-Date comparisons bridge through the epoch (an absorbed
  pixel store's 0.0 read predates any real date — "never fired").
  Diagnostics: init-closure debugNames (init:/enumInit:/extInit:) +
  nesting-guard hot-frame dumps. The DuckDuckGo monorepo (4814 files)
  renders and clicks: 77 nodes, 4 actions. **678 → 679/680 — ZERO
  failures (FORTY-THIRD saturation); suite 417 → 424; LiveCheck 3/4.
  Queue: SwiftUIFlux (movieswiftui) is the top open class.**
- 2026-07-10 iter 198: LiveCheck queue #1 (SwiftUIFlux, movieswiftui)
  CLOSED — **LiveCheck 4/4: every live-data scenario GREEN.** The
  SOURCE-LIBRARY SHIM mechanism landed (LibraryShims: a library the
  merge imports but doesn't vendor gets its distilled public core
  appended — SwiftUIFlux's Store/dispatch/AsyncAction/StoreProvider/
  ConnectedView, ~60 lines of the real semantics). The chain to green:
  generic T binds from TYPED COMPLETION closures (makeClosure keeps
  closure-parameter annotations; the parallel-session unifier consumes
  them), generic APPLICATIONS decode (`PaginatedResponse<Movie>` rides
  textually via GenericApplication + typeDescriptor; the decode bridge
  substitutes ordered generic parameters into property annotations —
  results: [T] → [Movie]), `as?` returns NIL on DEFINITE interpreted
  mismatches (declared type/protocol targets with transitive protocol
  inheritance — SwiftUIFlux's `action as? AsyncAction` took the async
  branch for EVERY action under the optimistic divergence, so sync
  actions never reduced), custom property wrappers on STATICS read
  through wrappedValue (@UserDefault-genre), and ModifiedContent(
  content:modifier:) RUNS the ViewModifier's body (MovieRow's
  titleStyle was recording "TitleFont(size: 16)" where titles
  belonged). A `.modifier()` MEMBER-spelling interception was tried
  and REVERTED (broke isowords/winston/KeyboardCowboy — running
  arbitrary interpreted modifier bodies at member sites is queued
  behind a safer wiring). **679/680 unchanged; suite 426 → 431;
  LiveCheck 3/4 → 4/4.**
- 2026-07-10 iter 199: queue #1 (`.modifier(m)` member spelling) CLOSED
  with the safe wiring the 198 revert demanded: only the STRICT
  ViewModifier shape dispatches (declared conformance + single-content
  body method), and the modifier instance gets its OWN environment
  injected first — the 198 breakage was uninjected @Environment
  properties reading voids. Unwound behind it: NESTED payload patterns
  (`case let .edges(edges, .some(length))` recursed as expressions and
  died on the inner PatternExpr — payload args now recurse as PATTERNS;
  `.some(x)`/`.none`/`nil` match NATIVE optionals), and a NIL beside a
  number in arithmetic reads fresh zero (KeyboardCowboy's custom-
  wrapper keypath subscript on a fresh store — the CGFloat(nil)
  doctrine extended to operators). winston GREW 121 → 189 nodes and
  KeyboardCowboy 27 → 30 (modifier bodies render real UI). **679/680
  unchanged; suite 431 → 433; LiveCheck 4/4.**
- 2026-07-10 iter 200: queue #2b verified already-fixed (198's strict
  `as?` covers concrete types, protocols transitively, and class
  up/downcasts — pinned by CastFalsePositiveTests) and queue #3
  (@Query/@FetchRequest live-store wiring, M3) CLOSED: a new
  Wrapper.query case reads the LIVE per-run model store on EVERY
  render (LiveModelStore.refreshQueries at all injection points AND
  inside each root-render closure — the setup-only refresh missed
  post-click re-renders). @ObservedResults stays @State-shaped for
  Realm's projection semantics. The todo-app loop closes end to end:
  tap Add → context.insert → @Query shows the row
  (QueryLiveStoreTests). **679/680 unchanged; suite 433 → 435;
  LiveCheck 4/4. Queue: TestCheck seed classes are next.**
- 2026-07-10 iter 201: TestCheck engaged as the metric (ProjectCheck +
  LiveCheck both saturated). Its biggest bucket's exemplar
  (LoadableTests.valueIsMissing, natively-green) fell to ONE missing
  builtin: **NSLocalizedString** — now returns Foundation's tableless
  fallback (explicit value: when non-empty, else the key), so computed
  `localizedDescription` on interpreted Errors resolves
  (LocalizedErrorDescriptionTests). TestCheck @ --limit 8: 79 passed /
  52 failed / 12 errored; the #expect bucket's next exemplar
  (LoadableTests.map — generic enum map + conditional-conformance ==)
  is documented in the queue. Landing it unlocked a LATENT SIGSEGV:
  real `%@` formats reached String(format:) whose varargs marshaled
  Ints under OBJECT directives — the whole corpus run crashed at
  String.init(format:) until varargs matched their directives
  (FormatDirectiveTests). **679/680 verified post-fix; suite 435 →
  438; LiveCheck 4/4.**
