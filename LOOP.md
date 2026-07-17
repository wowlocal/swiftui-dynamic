# The Loop

## High-level goal

A Swift interpreter that **matches native SwiftUI's abilities and runs real
open-source SwiftUI projects without errors**. Architecture (settled, don't
relitigate): tree-walk SwiftSyntax ASTs directly (never SIL), derive framework
API coverage from SDK swiftinterfaces through BridgeGen-generated tables, keep
only the narrow SwiftUI-magic semantic primitives allowed by `AGENTS.md`, and
use stub types (`InterpretedView`) for protocol conformance. See README.md for
what already works.

## RUN THE APP — R3 function climb, in a worktree (user directive 2026-07-16)

The loop's goal is now **running the app**: the interpreted FoodTruck must
FUNCTION — mutations re-render identically to the compiled twin, and
`swift run DynamicSwiftUIDemo --project
Examples/FoodTruckBuildingASwiftUIMultiplatformApp` launches an interactive
window a person can use. Climb R3 per `Scripts/foodtruck-r3-spec.md`
(model-API mutation parity, six scenarios, R2 floors carry over and never
widen). R2 residue (socialfeed 16.9%, content twin-side sidebar, Charts
forecast) stays on the queue but only blocks when a scenario's screen needs
it. North star: R3 scenarios green, then R4.

**Worktree protocol v2 (steering 2026-07-17 — EVERY agent works in its own
worktree; the main checkout is the steward's integration tree only):**
- Lanes: this loop in `.claude/worktrees/lane-foodtruck-run` (branch
  `worktree-lane-foodtruck-run`); the concurrency agent (Codex) in
  `.claude/worktrees/lane-concurrency` (branch `worktree-lane-concurrency`).
  Nobody builds, tests, or edits in the main checkout anymore — the 28-commit
  queue blocked ~8h on main-tree dirty files on 2026-07-17 is the incident
  this fixes. The steward uses main for serialized merges, steering commits,
  and gate verification only.
- Iteration START: `git merge main` inside your worktree.
- All work, builds, captures, and `Scripts/gate.sh` run INSIDE the worktree.
- Iteration CLOSE: commit on the lane branch (never `.claude/*.local.md`).
- MERGES INTO MAIN SERIALIZE THROUGH THE STEWARD. When your lane tip has a
  green closing gate, append `<UTC time> <lane> MERGE-READY <tip sha>
  <one-line gate summary>` to `.claude/claims.md` and keep iterating —
  MERGE-READY is not a stop. The steward merges MERGE-READY lanes into main
  `--no-ff`, oldest first, one at a time, and answers with a MERGE-DONE line.
  Liveness fallback: if no steward MERGE-DONE within ~2 hours of your
  MERGE-READY, take the lock yourself — append `<time> <lane> MERGE-LOCK`,
  confirm no other lane holds a MERGE-LOCK younger than ~2h without a
  MERGE-UNLOCK, re-verify the gate is green on the exact tip being merged,
  merge, then append `MERGE-UNLOCK <merge sha>`. Never merge a red or
  ungated tip; never force past another lane's fresh lock.
- The auto-push daemon publishes main after each merged iteration.

## PRIMARY TARGET: Food Truck — pixel-perfect, fully functional (user directive 2026-07-11)

Apple's WWDC sample at `Examples/FoodTruckBuildingASwiftUIMultiplatformApp`
(82 files; App/ + dependency-free FoodTruckKit SPM package) must run through
the interpreter **identical to the same app compiled natively with Xcode on
macOS: pixel-perfect on every screen, and functional** — navigation works,
the donut editor edits, orders complete, state flows exactly as compiled.
This target OUTRANKS every other queue: a FoodTruck failure class beats any
corpus/TestCheck/LiveCheck class of any size. The other boards are
regression backstops — they must never regress, but they no longer set
direction.

**The instrument: `swift run FoodTruckCheck` — bootstrap it first.** Rung
ladder per screen, strictly-improving total-rungs score, same discipline as
LiveCheck (deterministic, <3 min, per-screen timeout):
- R0 shell: merged App+Kit sources interpret; the @main FoodTruckApp scene
  renders through the app-shell path (its @StateObject model/accountStore
  MUST seed ContentView — never synthesized stand-ins).
- R1 render: each sidebar panel deep-renders with the app's own sample data
  visible in the tree (truck, orders, socialFeed, account, salesHistory,
  donuts, donutEditor, topFive, city) + order detail + store screen.
- R2 pixel: per-screen image diff against the NATIVE TWIN (below), AE=0 the
  end state; per-screen thresholds may ratchet down but never up.
- R3 function: scripted interactions — sidebar navigation lands the right
  panel, donut editor mutations show in the gallery, order status flow
  (placed → preparing → complete) updates the table, exactly as compiled.
- R4 identical: all screens AE=0 AND the R3 checklist green.

**The native twin (the only source of expectations).** FoodTruckKit builds
with plain `swift build`; the twin harness compiles Kit + App sources into a
scratch macOS executable (the Examples/ExpenseTrackerNative pattern) that
ImageRenderer-captures each screen headlessly at a FIXED size/appearance.
Expectations — pixels, strings, counts — are captured from the twin, never
hand-written. Known headless trap: macOS NavigationSplitView chrome can
blank headless — if it blanks in the TWIN it may blank in the interpreter
(fair comparison, native-baseline rule); pixel rungs then compare per-panel
CONTENT views at fixed sizes.

**Determinism rules (both sides, or the diff is noise):**
- Frozen clock: FoodTruckModel generates orders/sales from Date() — both
  twin and interpreter pin the same fixed date (env-injected), or rungs
  compare only date-independent screens until a clock policy lands.
- The app's OWN sample/preview data is the fixture — never invent data.
- App sources are READ-ONLY. Never patch the sample to pass; every gap is
  interpreter/gateway work (absorbed-environment doctrine as usual).
- Assets (Assets.xcassets in App and Kit) resolve through the Bundle
  machinery; missing-asset renders are a failure class, not a skip.

**Scope quarantine (auth doctrine extended, still must RENDER):** Sign in
with Apple flow, StoreKit purchase flow, live WeatherKit fetches — the
FLOWS are environmental (they don't run headless natively either), but the
Account/Store/City screens must still render pixel-identically in their
signed-out/unpurchased/sample-weather states. Widgets/, ActivityKit, and
AppIntents surfaces are OUT (extension processes, not the app window).

**Framework gaps this target will surface (build through BridgeGen when the
histogram demands, biggest first):** Swift Charts (salesHistory, topFive),
StoreKit 2 models/SubscriptionStoreView, AuthenticationServices,
WeatherKit types, CoreLocation, MapKit. The generated-members sweep +
parity harness (Instruments below) is the cheap way in for value-type
surface; view-producing API must also grow through generated interfaces and
reusable adapters. Only interface-inexpressible SwiftUI magic may remain
handwritten, under the rule in `AGENTS.md`.

**North-star metric: FoodTruckCheck total rungs**, then `swift run
ProjectCheck` pass rate as the health backstop. 587 real zipped SwiftUI
sample projects sit in `/Users/mike/Documents/sample-projects`. The runner
extracts them (into gitignored `External/`), merges each project's `.swift`
files, interprets, deep-renders every View body, and clicks every action.
Its failure-class histogram is the priority queue WITHIN the backstop.

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
keep short; these never count against the metric. Encoded mechanically in
TestCheck's `TestHarness.upstreamBrokenClasses` — entries report as
SKIPPED, keeping the histogram a true priority queue.)

- FreeChat.PromptTemplateTests (all 10): references Llama2Template/
  VicunaTemplate/ChatMLTemplate/AlpacaTemplate — types that exist NOWHERE
  in the checkout or its four package dependencies (markdown-ui,
  KeyboardShortcuts, Splash, EventSource). The test target cannot compile
  natively. Verified 2026-07-11 (iter 211).
- ProjectCheck analog — oss:Mythic onboarding "Back (DEBUG)" click:
  app-authored `precondition(stages.indices.contains(newIndex))` fires
  at stage 0 with delta -1 — a NATIVE DEBUG-build crash (the button is
  `#if DEBUG`-only and unguarded upstream; `firstIndex(of: stage0) ?? 0
  - 1 == -1` crashes identically compiled). Exposed when the app-shell
  root (M4) made onboarding the rendered root. Counts as the corpus's
  second known-failure alongside Widgets. Verified 2026-07-11 (iter
  227).

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
   - *Missing view/modifier/type* → this is a BridgeGen gap. Teach BridgeGen a
     coercion, mapping, interface analysis rule, or reusable generated adapter,
     then regenerate (`swift run BridgeGen --emit`). NEVER add a per-API entry
     to `ViewGateways`/`ModifierGateways` merely to pass the current example.
     Handwritten work is allowed only for the narrow, interface-inexpressible
     SwiftUI magic defined in `AGENTS.md`, and must be reusable, documented,
     and regression-tested.
   - *Missing MEMBER on a host native* (a Foundation/SDK value's property or
     method absorbs or errors) → this is a GENERATED-MEMBERS gap, not a
     hand-box job. Read the demand signal first: LiveCheck failure messages
     print the absorb histogram (`absorbed: Type.member×N`), and
     `Interpreter.absorbedHostMembers` carries it programmatically. Then fix
     in BridgeGen's member sweep (`Sources/BridgeGen/main.swift`): add the
     type to `memberTypes`, add a `memberMapping` entry + `ParamTag` coercion
     for a blocked parameter type (report mode prints the member-blocking
     histogram), or lift a sweep filter — and regenerate with `swift run
     BridgeGen --emit`. Do not add a member-specific hand box. A state-bearing
     host service whose lifecycle is absent from value-type interface metadata
     may use a reusable, type-level runtime adapter, but that is not an escape
     hatch for ordinary members. If the core's `nativeMember` already
     hand-serves a member the sweep would emit, pin it in `denyMembers` instead
     of shadowing it.
   - *iOS-only / platform-impossible API* (UIKit interop, UIScreen…) → add a
     minimal inert stub if cheap and honest (renders something reasonable),
     otherwise record the project name + reason in the Quarantine section
     below. Quarantine is a last resort and never used to inflate pass rate.
5. **Add regression coverage — distill a minimal repro (user directive
   2026-07-17)**: a failure class found inside a large app (FoodTruck, any
   OSS target) closes only when a SMALL, self-contained reproduction is
   committed alongside the fix — runnable in seconds, named after the
   class, citing the app+file that surfaced it, and demonstrated RED
   before the fix so the pin provably bites. Tier by class kind:
   - core-semantics class → a unit test whose distilled source snippet IS
     the repro (native-verified expectation, existing pattern);
   - render/app-shell/framework-interplay class → a corpus micro-program
     under `Tests/SwiftUIBridgeTests/Corpus/` (single file, deep-render +
     assertions, runs with the suite);
   - native-vs-interpreted PIXEL divergence → a micro-twin fixture: a tiny
     (≤~50-line) view distilled from the app, captured natively via the
     scratch-package pattern (Examples/ExpenseTrackerNative /
     FoodTruckNativeTwin) and pinned at AE=0. Bootstrap the shared
     MicroTwin harness the first time a pixel class needs it; every later
     class reuses it.
   Repros contain only distilled code (no app imports, no copied app
   files); the interpreter fix itself still obeys AGENTS.md — the repro
   never becomes a special case. New capability without its repro doesn't
   count. (The concurrency lane's native-probe + same-source-fixture
   discipline is the reference implementation of this rule.)
6. **Verify — cheap by structure, never by weakening** (user directive
   2026-07-11: reduce iteration cost AND allow no regressions — the two
   are reconciled by parallelism and caching, never by skipping checks):
   - THE NO-REGRESSION COVENANT: every board is a ratchet — suite count,
     ProjectCheck pass count, LiveCheck 5/5, ParityCheck zero-tail,
     FoodTruckCheck total rungs. None may decrease, tests are never
     deleted/weakened to go green, and the closing gate always runs ALL
     boards at full strength. Cost is cut by sharing ONE build, parallelizing
     the lightweight boards, and skipping only VERIFIED-UNCHANGED states.
     LiveCheck follows that group so its large deep-render working set never
     overlaps the corpus sweep and gets killed by memory pressure.
   - THE COVENANT BINDS MAIN ITSELF (steering 2026-07-17): main must be
     green at every commit it receives — no half-landed series, no commit
     that knowingly leaves a board or the suite red on main (the
     checked-continuation alias window of 2026-07-17, red on main
     ~03:30–08:50 and auto-pushed to origin throughout, is the precedent
     this rule prevents). Multi-commit work stages on a lane branch and
     reaches main only through a gate-green, steward-serialized merge
     (worktree protocol v2 above). If main turns red anyway, restoring it —
     revert first when the fix is not immediate — outranks every queue in
     every lane.
   - OPENING sweep: just run `ProjectCheck --all` — it SELF-CACHES
     (fingerprints Sources/ + Package.swift into `.claude/last-verify.txt`;
     unchanged sources return the recorded verdict in <1s; `--force`
     re-sweeps). The cache can only ever cause an EXTRA sweep, never a
     wrong skip.
   - MID-iteration: targeted probes ONLY — `swift test --filter <Suite>`,
     `ProjectCheck --project X`, single scenario. Never a full sweep to
     answer a narrow question; the full sweep happens once, at the gate.
   - CLOSING gate, exactly ONCE: `Scripts/gate.sh` — one build; suite +
     ProjectCheck + ParityCheck in parallel from prebuilt binaries; then
     memory-isolated LiveCheck. It is red if ANY board is red. Pass counts
     must strictly improve or hold with the top class eliminated.
   - Long commands: give explicit timeouts (never a chained
     build+suite+corpus under the default 10m — it WILL be killed);
     build once, then invoke prebuilt binaries (.build/debug/…).
   - Bisect discipline: ONE patch at a time, re-probe after each; if
     the metric regresses, REVERT before continuing (never patch on a
     broken baseline). Cap a bisect at ~10 rebuild cycles per
     iteration — past that, commit a WIP checkpoint of findings to the
     log and finish next iteration. Rebuilds dominate iteration cost:
     batch related edits into one build; probe with `--filter` between
     builds, not full suites.
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
      runtime-service adapter), URL.resourceValues (throws — sweep-filtered;
      consider a do/catch-wrapping emit policy for throwing members).
      RESOLUTION: Dictionary Collection members land in nativeMember —
      contains(where:)/filter/compactMap/map/sorted(by:) over native
      (key:, value:) tuple elements (DictEnumeratedTests). Post-fix
      histogram: only Array.append (member-position) + webSocketTask +
      URL.resourceValues remain.
   3c. [DONE iter 207] M2 BREADTH: achnbrowser-items-ui scenario SEEDED (4/5 board —
      the four green stay the invariant; the fifth is the new demand).
      ACHNBrowserUI is a THIRD async genre: bundled RESOURCE data
      (repo-committed real JSON, what Bundle.module ships) rides a
      COMBINE pipeline (Result.publisher → decode(type:decoder:) →
      mapError → subscribe(on:) → sink into @Published). First-run
      walls, outermost first: (a) root sceneExprError "expected a view,
      got ImplicitMemberCall(makeSheetView)" — the scene expression
      calls a helper the evaluator loses (fallback renders
      SettingsView); (b) Bundle.module.url(forResource:) must resolve
      against the project's Resources dirs (a BundleResourcePolicy like
      NetworkPolicy.replay — the compiled app HAS these files); (c) the
      Combine chain itself (absorbed: URLSessionBox.dataTaskPublisher×3;
      Result.publisher/decode operators unserved); (d) minor:
      FileManagerBox.containerURL (app-group), URL.appendPathExtension
      (mutating member).
      LADDER PROGRESS (штурман, 4 closed): sheet(item:) content skips
      on nil item and receives the UNWRAPPED item (was: eager call with
      unbound $0 — killed the root); Date(timeInterval:since:) joins
      the core builtin; CLASSIC EnvironmentKey defaults resolve
      (getter's self[Key.self] → static defaultValue — currentDate);
      nil in builder position renders nothing (ACHNLadderTests ×4).
      CURRENT WALL: "[Sort.name, …] is not callable" @5484 — an array
      value invoked as a function (enum-case list); then walls (b)
      Bundle.module resources and (c) Combine chain remain.
   4. TestCheck classes (native-baseline rule first; scoreboard
      2026-07-10 @ --limit 8: 79 passed / 52 failed / 12 errored).
      Top exemplar [DONE iter 202: LoadableTests.map — generic-
      application annotations resolve by HEAD; user-declared `static
      func ==` WINS over structural equality with structural fallback
      when its body trips; enumCase hashValue synthesized]. Behind it: FreeChat PromptTemplateTests
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
- **Swiftinterface-first bridge invariant:** ordinary SwiftUI/SDK API gaps are
  fixed only in BridgeGen, shared coercions, or reusable generated adapters.
  Never add an API/project/literal special case. Existing handwritten semantic
  overrides may stay authoritative at runtime only when they meet the narrow
  SwiftUI-magic exception in `AGENTS.md`; their dispatch priority is not
  permission to grow the handwritten surface.
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

## Instruments

- `swift run ParityCheck` — API parity vs a compiled twin (generated
  members surface; regenerate probes with `swift run BridgeGen --emit
  --probes`). Current: 345 match / 0 diverge / 0 error / 17 unstable of 362
  (ratchet: never regress 345 — the full stable surface matches; 17 types
  swept, 115 method variants). Two growth axes, both cheap: (a) new TYPE →
  memberTypes + seed in parityPrelude/seedReceivers; (b) new PARAM TAG →
  memberMapping (BridgeGen) + ParamTag/coerce (GeneratedSupport) +
  probeArgument. SATURATION VERDICT (2026-07-11, verified with
  `BRIDGEGEN_DUMP_BLOCKED=1 swift run BridgeGen`): the remaining blocker
  histogram for the current 17 types is ALL plumbing — encode(to:)/
  hash(into:) protocol machinery, rethrows-closure shapes, inout/pointer
  params, filesystem-volatile URL methods, opaque-Sequence iterators.
  Do NOT chase those counts; growth is NEW TYPES (absorb census names
  demand) or the JIT-thunk tier (chartered separately).
  All 247 swept property getters also carry parsed HostProperty contracts;
  GeneratedMemberTests invokes every descriptor directly against a typed SDK
  seed so handwritten/native lookup cannot mask a return-contract mismatch.
  Every finding ParityCheck reports is a real interpreter gap (missing
  constructor or executable-contract mismatch). Source/runtime Foundation
  aliases such as Decimal/NSDecimal and nested generic index types are handled
  by HostSignature's recursive name equivalence. Hand-box members must NEVER shadow swept
  overloads: on shape mismatch, retry the generated table before erroring
  (CalendarBox.generatedFallback is the pattern). Property/method name
  collisions (url.query vs query(percentEncoded:)) dispatch call-aware:
  a non-callable or nil property at a call site retries the methods-only
  generated table (registry hostMethod hook).
- `INTERP_ABSORB_CENSUS=1 swift run ProjectCheck --all` — corpus-wide
  absorbed-member demand curve. Current: ZERO absorptions across 586
  projects (2026-07-11) — M0-level host-API demand is fully served; a
  nonzero census after new corpus material is the signal to grow the
  sweep again.
- R2 FINDING (2026-07-11 18:5x, steward): content stuck at 52.45% even
  after the truck-grid fix — the DynamicTypeSize/platform-canvas
  environment reaches FoodTruckCheck's PANEL probe but NOT the
  app-shell root render (DemoApp/HeadlessVerifier scene route): the
  embedded TruckView inside ContentView still collapses to the dot
  column with "Order#121%02d". Class: environment parity between the
  two render routes — whatever env the panel probe seeds, the shell
  route must seed identically (one env-defaults path, two consumers).
- R2 BASELINE (2026-07-11 14:55): interpreted FoodTruck root vs native
  twin at 1000x650@1x — AE 52.470%. Both capture paths pinned to
  explicit 1x bitmaps. Interp render commands:
  `.build/debug/DynamicSwiftUIDemo --project Examples/FoodTruckBuilding…
  --render-png OUT --size 1000x650`; twin:
  `swift run FoodTruckNativeTwin --out DIR` (in its package). Visible
  classes in the first diff: String(format:) unapplied ("Order#121%02d"),
  detail-column layout collapse (dot column vs card grid). Sidebar with
  real model data (panels + Cities) already renders.
- R2 DETERMINISM (probed 2026-07-11 16:0x, twin run-to-run): 7 of 8
  screens are AE=0 stable — content, truck, donuts, orders and all
  leaf cards can ratchet straight to AE=0, no frozen-clock machinery
  needed. ONLY socialfeed drifts (0.183%) — SOURCE FOUND:
  SocialFeedContent.swift:73 rolls the UNSEEDED system RNG for post
  dates (-60 * .random(in: 5...30)) so relative timestamps shift every
  run — while OrderGenerator uses SeededRandomGenerator(seed: 1), which
  is why every other screen is AE=0 stable. The drift is upstream-REAL
  (a compiled app varies the same way): the socialfeed rung gets a
  documented fuzz floor (0.25%), never a patch, and the floor never
  widens to other screens.
- `Scripts/foodtruck-r3-spec.md` — the R3 function-parity protocol:
  model-API mutation (never event injection) → re-capture → diff at the
  screen's R2 floor; six scenarios coded against FoodTruckKit's public
  API (updateDonut, markOrderAsCompleted, orderBinding, popularity
  sort, Panel selection). Build R3 rungs from it when R2 saturates.
- `Scripts/foodtruck-r2.sh` — the R2 BOARD: captures both sides and
  prints per-screen AE. Convention: twin → /tmp/foodtruck-twin/<id>.png,
  interp → /tmp/foodtruck-interp/<id>.png; matching ids get diffed.
  FoodTruckCheck's R2 wiring should WRITE interp panel captures into
  that directory with the twin's ids (truck, donuts, orders, socialfeed,
  card-donuts, card-orders, donut-view) — each new capture joins the
  board automatically. Per-screen AE only ever decreases.
- `swift Scripts/pixel-ae.swift a.png b.png [--fuzz N]` — the R2 pixel
  primitive: AE count between twin and interpreter captures; exit 0 only
  at AE=0; SIZE-MISMATCH is a finding (same point size + backing scale
  both sides, never resample). A rung's fuzz may only tighten toward 0.
- `Scripts/gate.sh` — THE closing gate: one build, all boards parallel,
  red if any board is red. Use it instead of serial gate commands.
- `swift run FoodTruckCheck` — the PRIMARY TARGET's rung board (bootstrap
  it on the first iteration under the FoodTruck directive; ladder spec in
  the PRIMARY TARGET section).
- `INTERP_APPSHELL_CENSUS=1 swift run ProjectCheck --all` — M4 sizing
  (2026-07-11): 585/586 projects declare @main App shells; the static
  root walk resolves 584 (selection is NOT the M4 work). The real M4
  class: 15 projects seed ENVIRONMENT in the App body that fresh root
  instantiation loses (6 via @StateObject on the App struct —
  DeepLinkApp, Timer, TabBarSheet, PomodoroTimer…), 7 multi-scene
  shells, 4 onOpenURL handlers. They pass M0 on synthesized stand-ins;
  M4 = the App instance's own objects flow into the root's environment.

## Field notes (iteration-invariant facts — keep to ~12 lines)

- ProjectCheck --all ≈ 2 min prebuilt; swift test ≈ 1-4 s execution,
  build dominates. Time new harnesses once, note it here.
- macOS/BSD sed lacks `addr,+N` — use `awk NR` or `grep -A`.
- SwiftPM stale artifacts after public-signature changes → `touch`
  changed sources and rebuild before trusting exit-138 crashes.
- Write large patch payloads to files, not inline heredocs per turn —
  context overflow ("Prompt is too long") killed iteration 140's tail.
- ProjectCheck --all self-caches (fingerprint of Sources/ in
  `.claude/last-verify.txt`): unchanged sources return the verdict in
  <1s. Never write that file by hand; `--force` re-sweeps.
- Failed `Edit` on unread files: Read the region first or use the
  python patcher directly — dead tool calls otherwise.

## Mission ladder (functional parity with Xcode builds)

The end state: any GitHub SwiftUI project launches and FULLY functions as
if compiled in Xcode. **The PRIMARY TARGET section above (Food Truck) is
the concrete embodiment — it exercises every rung of this ladder on one
real Apple app and takes priority over the generic queues.** Milestones,
each with its measuring queue:

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

## Progress log — moved to LOOP_LOG.md

The append-only per-iteration log lives in LOOP_LOG.md (methodology
audit 2026-07-10: the log had grown to ~2,000 lines and was re-entering
context EVERY iteration — ~85% of the file, growing linearly). Rules:
- APPEND your one-line entry to LOOP_LOG.md (same format as before).
- READ only `tail -20 LOOP_LOG.md` when you need recent history.
- Never move the log back into this file.
- 2026-07-11 iter 208: the LEXICAL-SCOPING family — names inside a
  method body resolve in the scope that DECLARED the method, never
  through the runtime self. Infrastructure: collection stamps every
  method's declaring symbol (declLexicalOwners; extension merges
  re-home), closures carry it, callWithArguments pushes a frame. Three
  leaks closed: bare NESTED TYPES (`throw APIError.unexpectedResponse`
  inside `extension WebRepository` saw the conforming test double's
  shadowing APIError — clean-architecture), bare SIBLING STATICS (the
  same leak through instanceMember's staticMember fallback), and
  parameter ANNOTATIONS (resolveAnnotated prefers the owner's nested
  types AND member typealiases — `func mock(_ apiCall: API)` where
  `API = TestWebRepository.API`; unresolved member typealiases now
  retry after the extension pass). Downstream, the URLProtocol mock
  TRANSPORT came alive: URLRequest(url:) constructs a real config bag,
  NSLock/NSRecursiveLock's withLock RUNS its body (LockBox), host URLs
  compare for real, and BOUNDED asyncAfter delays (mock loadingTime:
  0.1) deliver once-per-drain — a self-rescheduling retry fires once
  per drain instead of spinning; the demo facade opts into wall-clock
  timers via MainQueueDrain.schedulesRealTimers (reset per
  verification). RequestMocking now matches, loads and delivers real
  bytes end-to-end. Diagnostics: ⌖ INTERP_TRACE_IDENT resolution
  tracer, ⌗ enum-registration trace, TESTCHECK_DUMP merged-source dump,
  TestCheck honors LIVECHECK_TRACE, readStatic. Pins:
  LexicalTypeScopingTests (native-verified), URLProtocolMockStoreTests,
  DottedExtensionInitTests, DelayedAsyncAfterTests. WATCH: ProjectCheck
  wall time roughly doubled (~10 min) — the delayed-drain work is the
  suspect; profile next saturation pause. **679/680; suite 479 green
  (+4 suites); LiveCheck 5/5; TestCheck 81→82 passed / 51→50 failed —
  strictly improved. Top open class stays clean-architecture's 6×
  did-not-throw (now transport-unblocked: the remaining wall is the
  generic `decoder.decode(Value.self)` + interactor plumbing).**
- 2026-07-11 iter 209: TestCheck's top class (6× did-not-throw,
  clean-architecture) ELIMINATED — two general fixes. (1) CLASS INIT
  INHERITANCE, the decisive one: a class declaring no initializers now
  inherits its nearest interpreted ancestor's designated inits, run
  with self = the subclass instance (the test-suite pattern
  `@Suite class Base { init() { sut = … } }` + `final class CaseTests:
  Base` left every inherited stored property VOID — `sut.refresh()`
  absorbed instead of throwing; InheritedInitializerTests). (2) RESULT
  AS A VALUE: implicit `.success(x)`/`.failure(e)` against Result-
  annotated storage construct the ResultBox carrier (incl. void
  `.success(())`) via marker statics + a resolveAnnotated path that
  invokes marker FACTORY functions; `try result.get()` throws the
  app's own error (InterpretedThrow); patterns match through a new
  core CaseShaped protocol (PatternMatcher reads host case shapes);
  thrown NSErrors compare with expectations (isEqual);
  hostTypeName(ResultBox) = "Result" so app extensions dispatch
  (ResultValueSemanticsTests). Distilled-but-passing scaffolds kept as
  pins: GenericCallDecodeTests/AsyncGenericCallDecodeTests (typed-let
  pins Value through `try await call()` — the machinery already
  worked; the real wall was the void sut). clean-architecture
  38 → 48 passed / 30 → 20 failed within the suite. QUEUE:
  resetBridgeEnvironment does NOT clear MainQueueDrain
  pending/delayedPending — delayed actions leak across verifications
  (determinism + the prime suspect for the doubled ProjectCheck wall
  time; fix + profile next iteration). **679/680; suite 483 green
  (+4 suites); LiveCheck 5/5; TestCheck 82→92 passed / 50→40 failed —
  top class eliminated.**
- 2026-07-11 iter 210: the queued DRAIN-ISOLATION invariant — one
  program's queued deliveries must never fire inside the next
  verification. resetBridgeEnvironment now clears DELAYED deliveries
  and restores a per-verification FIRE BUDGET (64): self-rescheduling
  retries fire a bounded number of times per verification then go
  quiet (a probe frame spans finite time). Zero-delay items stay —
  they self-drain within a tick, and clearing them RACED concurrent
  unit tests' in-flight deliveries (Swift Testing interleaves async
  tests; the dispatchQueueMainAsync test lost its queued action to
  another test's reset — caught in-iteration, suite green).
  DrainIsolationTests pins the delayed-clearing. The wall-time
  watch-item is ANSWERED BY MEASUREMENT, not fixed: ProjectCheck 615s
  / LiveCheck 458s, both CPU-bound (user≈real) — the cost is
  iter-207/208 coverage (destination walks, mock deliveries), not
  queue leakage; a profiling pass (sample/Instruments on one slow
  scenario) is the queued follow-up. **679/680; suite 484 green;
  LiveCheck 5/5; TestCheck 92/40/11 — all held under the invariant
  fix.**
- 2026-07-11 iter 211: the biggest TestCheck root (8 failures across 4
  message-classes — FreeChat's PromptTemplateTests) resolved by the
  NATIVE-BASELINE RULE, not a fix: Llama2Template/Vicuna/ChatML/Alpaca
  exist nowhere in the checkout or its package dependencies — the test
  target cannot compile natively → upstream-broken → Ledger. The Ledger
  is now MECHANICAL: TestHarness.upstreamBrokenClasses reports ledgered
  suites as SKIPPED with the verdict (FreeChat: 10 skipped; its lone
  "pass" was as phantom as its failures). Histogram is now all
  2-count classes — Milestones Comparable is next by age. **679/680 and
  LiveCheck 5/5 stand from iter 210 (no interpreter/bridge-behavior
  edits this iteration); suite 484 green; TestCheck 91 passed /
  31 failed / 11 errored / 10 skipped.**
- 2026-07-11 iter 212: the oldest 2-count class — Milestones' declared
  Comparable (`XCTAssertLessThan could not compare`). The infix path
  already dispatched `static func <` (and derived <=/>/>= from it);
  the GATEWAYS bypassed it via raw Builtins. The declared-operator
  dispatch is now extracted (declaredOperatorValue) and a public
  evaluateBinary(op:lhs:rhs:) serves gateways — XCTAssert comparisons
  dispatch declared operators exactly like infix expressions (tuple
  lexicographic `<` inside the operator body already worked). Native-
  verified via a distilled swiftc run (A<B true, B<A false, earlier
  date wins); pinned by DeclaredComparableGatewayTests (TestHarness-
  level). Milestones 15 → 17 passed. EN ROUTE a steward-lane parity
  commit (28ba319, real URLRequestBox) landed mid-iteration and broke
  nextcloud-ios (`cannot assign to 'headers'` — Alamofire's extension
  property): the box now ACCEPTS-AND-MEMOIZES unknown members (config
  bag; reads consult it) — ecosystem extension writes can't be
  rejected. **679/680 (nextcloud recovered); suite 485 green;
  LiveCheck 5/5; TestCheck 91→93 passed / 31→29 failed — strictly
  improved.**
- 2026-07-11 iter 213: the `BindingStub is not callable` class
  (clean-architecture's LoadableTests) ELIMINATED — three connected
  gaps. (1) App `extension Binding { func load }` members now dispatch
  BEFORE @dynamicMemberLookup projection (native precedence: real
  members beat dynamic lookup); the late extension walk also maps core
  stubs the bridge can't name (BindingStub → "Binding") — narrowly,
  after a hostCandidates-broadening attempt regressed 2 tests
  (isViewValue nodes started walking `extension View` first; caught by
  a stash-baseline diff, 48→46→48). (2) `wrappedValue = …` inside a
  Binding extension writes through the box (host-self lvalue,
  restricted to the binding's own properties so bare globals still
  reach globals). (3) `extension LoadableSubject` — a TYPEALIAS of
  Binding<Loadable<T>> — canonicalizes through a new aliasHeads
  prepass, so alias extensions collect into the real host symbol.
  Pinned by BindingExtensionMethodTests (typealias shape included).
  The two Loadable tests now RUN and fail honestly on a finer class
  (Loadable sequence equality/timing — errored 11 → 9, failed +2).
  **679/680; suite 486 green; LiveCheck 5/5; TestCheck 93/31/9/10 —
  class eliminated.**
- 2026-07-11 iter 214: the biggest remaining ROOT — clean-architecture's
  Store plumbing (`typealias Store<State> = CurrentValueSubject<State,
  Never>` + an extension `subscript<T>(keyPath: WritableKeyPath<…>)`
  with a compare-and-publish SETTER) spanned the UserPermissions,
  DeepLinks and state-write 2-count classes. CurrentValueSubject was
  UNBRIDGED: `Store<AppState>(…)` absorbed to a marker, the first
  keypath-subscript WRITE auto-vivified it into a dict, and every read
  after saw garbage ("unsupported member 'value' on DictValue").
  Landed: a real CurrentValueSubjectBox (value get/set + send),
  constructor lookup canonicalizes TYPEALIAS HEADS (aliasHeads:
  `Store<AppState>(…)` reaches the CurrentValueSubject ctor through
  the generic-specialization callee), and USER-SUBSCRIPT dispatch
  generalized to host bases: the runners take (symbol, selfValue),
  userSubscriptOwner finds extension subscripts under the value's
  host type name, subscript READS run the getter and subscript
  ASSIGNMENTS seed from the getter and write through the SETTER (a
  box whose onChange runs it — declared semantics beat element
  writes). Pinned by CurrentValueSubjectStoreTests (the exact Store
  shape: typealias + keypath subscript + compare-and-set + reads).
  clean-architecture 48 → 50 passed. **679/680; suite 487 green;
  LiveCheck 5/5; TestCheck 93→95 passed / 31→29 failed — strictly
  improved.**
- 2026-07-11 iter 215: the biggest root (4× Milestones AppReducer
  persist arrays) — old-style ComposableArchitecture is an UNVENDORED
  package, so per the LibraryShims doctrine it gained a DISTILLED CORE:
  Reducer (init/callAsFunction/combine/forEach), Effect (none/
  fireAndForget/timer/cancel/merge/map/cancellable/debounce),
  TestScheduler (virtual time, advance(by:), repeating entries, a
  global registry for cancel-by-id), DispatchQueue.testScheduler,
  AnySchedulerOf, TestStore with send/receive/do Steps whose effects
  really schedule and deliver. FOUR interpreter gaps surfaced en
  route, each general: (1) VARIADIC elements now resolve against the
  element annotation (implicit `.send(…)` factories in
  `assert(_ steps: Step…)` stayed markers); (2) closure LITERALS bound
  to function-typed parameters inherit the annotation's RETURN type,
  so `return .none` inside `Reducer { … }` resolves on exit
  (callWithArguments already applied returnTypeName — only attachment
  was missing); (3) `/AppAction.item` case paths RESOLVE (CasePathMarker
  carries the enum symbol + case; `.extract(_:)` matches enumCases AND
  never-context-typed ImplicitMemberCall markers, returning labeled
  payload tuples); (4) no-arg sort()/sorted() dispatch declared
  Comparable `<` via evaluateBinary, and remove(atOffsets:) lands
  (IndexSet arrays, descending). Milestones 17 → 21 passed (the two
  left are finer: debounce timing, date trimming). Pin:
  ComposableArchitectureShimTests (reducer + TestStore + fireAndForget
  persist + forEach case-path routing). **679/680; suite 488 green;
  LiveCheck 5/5; TestCheck 95→99 passed / 29→25 failed — strictly
  improved.**
- 2026-07-11 iter 216: the oldest 2-count — DeepLinks' `subscript
  assignment requires an Int index` — was an INITIALIZER OVERLOAD
  mis-pick, not a subscript gap: `DIContainer(appState: initialState,
  interactors:)` with an AppState argument chose the DESIGNATED
  `init(appState: Store<AppState>…)` by LABELS, storing a raw AppState
  where a store belongs (the ⌖ tracer showed
  `DIContainer(appState: AppState(…))`); the convenience
  `init(appState: AppState,…)` that wraps into a Store never ran.
  chooseInitializerStrict's type dimension gains a NOMINAL score:
  parameter annotation heads (typealias-canonicalized, Store →
  CurrentValueSubject) match the argument's dynamic name (instance
  symbol + conformances, enumCase symbol, host type name), weighted
  above the array/closure shape hints. Pinned by
  ChainedStoreSubscriptTests (the DIContainer chain shape, harness-
  level — it passed pre-fix through the DIRECT init; the suite path
  exercised the convenience). The two DeepLinks tests now RUN and fail
  honestly on routing-state comparison (errored 9 → 7, failed +2).
  **679/680; suite 489 green; LiveCheck 5/5; TestCheck 99/27/7/10 —
  class eliminated.**
- 2026-07-11 iter 217: the oldest 2-count — ImagesInteractor's
  `state.history` transition sequences (shared root with a LoadableTests
  pair). The missing middle transition (`isLoading`) traced to THREE
  small binding/value-semantics gaps: (1) bare `wrappedValue` READS in
  `extension Binding` bodies never resolved (selfMember's host path
  skipped the binding block — writes worked since iter 213, reads
  threw); (2) LValue.read for host-property bindings now reads the box;
  (3) MUTATING methods on ENUM receivers run on a copy whose `self`
  reassignment writes BACK through the receiver lvalue —
  `wrappedValue.setIsLoading(cancelBag:)` fires the binding's
  set-closure exactly once, the native read-modify-write. Pinned by
  LoadableTransitionHistoryTests (history records
  notRequested → isLoading → loaded, with the Task-delivered load).
  clean-architecture 50 → 53 passed. **679/680; suite 490 green;
  LiveCheck 5/5; TestCheck 99→102 passed / 27→24 failed — strictly
  improved (past 100).**
- 2026-07-11 iter 218: biggest remaining class (2×) —
  `stored.capital == details.capital` (CountriesDBRepositoryTests):
  SwiftData was absent. Added an in-memory SwiftData store:
  ModelContainerBox/ModelContextBox (insert/delete/save/transaction/
  fetch/fetchCount over stored interpreted instances),
  FetchDescriptorBox + PredicateBox; `Type<Generic>(...)` host ctors
  now receive `__genericArguments` (genericSpecializationExpr wrap);
  `#Predicate<T>{...}` registered through the macro path
  (invokeRegisteredMacro gained genericArguments); @ModelActor
  tolerance (attributeNames on StructSymbol; memberwise binds
  unmatched labels on macro-attributed symbols; `modelContext` →
  modelContainer.mainContext). Fetch matches by last dotted type-name
  component + predicate closure. First full gate caught a corpus
  regression — MinimalTodo/Meshtastic assign `descriptor.fetchLimit`
  — fixed by accept-and-memoize config on FetchDescriptorBox (fetch
  honors fetchLimit). Pinned by SwiftDataStoreTests (@ModelActor
  repository round-trip + mutable-descriptor config).
  clean-architecture 53 → 56 passed. **679/680; suite 492 green;
  LiveCheck 5/5; TestCheck 102→105 passed / 24→21 failed — class
  eliminated.**
- 2026-07-11 iter 219: biggest class (4×+ across suites) — struct
  equality compared instances by IDENTITY (`l === r` in areEqual), so
  `state.value == AppState()` and every fresh-vs-fresh comparison
  failed (UserPermissions/DeepLinks noSideEffectOnInit, Basic-Car
  contributorEncoding). Native truth: Equatable synthesis is
  member-wise. Fix in equalsViaDeclaredOperator: (1) synthesized
  member-wise equality for same-symbol STRUCT instances (classes keep
  identity — native classes never synthesize `==`), recursing through
  declared operators per member exactly like the compiled witness,
  with an active-pair set breaking reference cycles; (2)
  declaredEqualsOperator now also finds TOP-LEVEL `func == (lhs: T,
  rhs: T)` (clean-architecture's AppState style) matched by first-
  parameter type name; (3) the array arm recurses for instance
  elements without declared `==`. Native-verified via scratch swiftc
  (all four distilled flags true). Pinned by
  StructEqualitySynthesisTests. DeepLinks routing tests now fail
  HONESTLY on `.value` reference-aliasing (captured "copy" sees later
  mutation) — a different class, queued. clean-architecture 56 → 58.
  **679/680; suite 493 green; LiveCheck 5/5; TestCheck 105→108
  passed / 21→18 failed — class eliminated.**
- 2026-07-11 iter 220: biggest cluster (4×) — the web-repository mock
  genre (CountriesWebRepositoryTests 3× + ImageWebRepository). End-to-
  end distillation found FOUR stacked general gaps, each pinned:
  (1) Swift Testing suites clean their static mock store in `deinit`,
  which never ran — TestHarness now runs declared deinit bodies
  (superclass chain, native order) on the per-test instance right
  after tearDown, Swift Testing only (XCTest instances natively live
  to run end); StructSymbol.deinitBody + Interpreter
  .runDeinitializer. Pin: deinitRunsBetweenSuiteTests. (2)
  `httpCodes: HTTPCodes = .success` — typealias-annotated statics:
  resolveAnnotated now canonicalizes annotation heads through
  aliasHeads (guarded: declared types/nested/owner win), so extension
  statics collected under "Range" resolve. Pin:
  AliasedRangeStaticDefaultTests. (3) IMPLICIT single-expression
  bodies are return-position: they evaluate under the declared return
  annotation (like explicit `return`), skipped when the return type
  names the closure's own generic (the ambient caller hint must
  thread). Pin: WebRepositoryMockPipelineTests. (4) protocol-
  extension defaults resolve through protocol REFINEMENT
  (transitiveConformances: CountriesWebRepository: WebRepository
  reaches `call(endpoint:)`); applied to member lookup, call-site
  collision rescue, and bodyProperty. Pin: harness-shaped
  suiteStoredPropertySessionResolves. allCountriesSuccess +
  countryDetailsWhenDetailsAreEmpty flipped; countryDetailsSuccess
  remains (nested [Currency] decode — different root, queued).
  clean-architecture 58 → 61. **679/680; suite 497 green; LiveCheck
  5/5; TestCheck 108→111 passed / 18→16 failed / 7→6 errored — class
  strictly improved.**
- 2026-07-11 iter 221: biggest class (3×) — LoadableTests
  (cancelLoading + loadSuccess/loadFailure). Distillation found the
  Combine-cancellation layer missing plus two resolution gaps, all
  native-verified via scratch swiftc: (1) PassthroughSubjectBox (send
  delivers inline to sink subscribers) + AnyCancellableBox (cancel
  runs deregistration once); Task handles are UIKitStub with ROLES
  ["Task","Cancellable"]; new HostRegistry.hostProtocolCandidates
  feeds hostCandidates so user `extension Cancellable { store(in:) }`
  dispatches on host values (the app-side CancelBag genre). (2)
  mutating-enum write-back resolves `self = .loaded(last)` markers
  against the receiver's symbol. (3) `Binding<Loadable<String>>(get:
  set:)` resolves get()/onChange values through __genericArguments —
  `.notRequested` from the get closure becomes a real case, so
  setIsLoading's enumCase-receiver branch fires and the set-closure
  sequence matches native ([isLoading, loaded]). (4) equality: payload-
  carrying markers beside an enumCase resolve against that symbol
  before the declared == runs (`values == [.isLoading(last: nil,
  cancelBag: .test), …]`). Pins: CancelBagStoreTests,
  LoadableBindingSequenceTests. Mid-iteration a sloppy replace-all
  edit flipped two UNRELATED pins' expectations (count "1"→"2") and
  injected debug prints — caught by the suite gate, restored to the
  original native-verified expectations (extensionMethodDispatches
  OnBuiltBinding, replaceErrorFallbackResolvesDeferredDecode).
  clean-architecture 61 → 64. **679/680; suite 499 green; LiveCheck
  5/5; TestCheck 111→114 passed / 16→13 failed — class eliminated.**
- 2026-07-11 iter 222: biggest fixable class (2×) — DeepLinks routing
  (`.value` reference-aliasing; the ViewInspector 2× wall was assessed
  and deferred: its DSL needs render-tree introspection TestHarness's
  ViewRegistry can't answer — queued as its own arc). Root: the
  interpreter's reference-backed structs alias across the Store
  boundary (`DIContainer(appState: initialState)` — mutating the store
  mutated the caller's local). Fix: NATIVE value semantics at the
  CurrentValueSubject boundary — Builtins.valueSemanticsCopy (struct
  instances copy recursively, classes stay references, enum payloads/
  arrays/tuples/dicts element-wise) applied at ctor seed, `.value`
  get/set, and send. Second half (openingDeeplinkFromNonDefaultRouting)
  stacked three more gaps: ProcessInfo.processInfo bridged
  (ProcessInfoBox; environment/arguments/processIdentifier) with
  TestHarness presenting XCTestConfigurationFilePath exactly like
  native XCTest (isRunningTests → delay 0); asyncAfter accepts
  `execute:`-LABELED closure VALUES (the delivery was silently
  dropped); `Task.sleep`/`yield` drain the main queue (a sleep IS the
  runloop turn). Pins: StoreValueSemanticsTests (native-verified via
  scratch swiftc), executeLabeledAsyncAfterDeliversOnSleep (harness-
  level). clean-architecture 64 → 66. Steward-merge note: b5caaf9
  flipped allCountriesSuccess passed→errored (unexpectedResponse) —
  now a 1× in the web-repository genre, queued. **679/680; suite 501
  green; LiveCheck 5/5; TestCheck 114→116 passed / 13→11 failed —
  class eliminated.**
- 2026-07-11 iter 223: biggest cluster (4×) — the web-repository
  decode genre (allCountriesSuccess ERRORED — a regression exposed
  when the steward's container stubs made custom `init(from:)` RUN —
  plus countryDetailsSuccess/loadImage*). Root chain, distilled and
  pinned: (1) structural decode had NO dictionary arm —
  `[String: String?]` (Country.translations) threw "unsupported type
  argument"; decodeField gains `[String: V]` (JSON objects, null →
  nil), and annotationName names dictionary TYPE literals
  (`[String: String?].self`). (2) areEqual had no DictValue arm —
  even `[:] == [:]` was false; dictionaries now compare by entries,
  order-independent. (3) `container(keyedBy: CodingKeys.self)`
  DISCARDED the key type, so `.flag` markers lost their raw value
  (`case flag = "alpha2Code"`) and keyed lookups missed;
  KeyedContainerStub carries the keyedBy enum and resolves marker
  keys through case raw values. Pins: CountryModelRoundTripTests
  (full Country shape round trip + namespaced nested models).
  countryDetailsSuccess persists (distilled round trip PASSES — the
  residual root is deeper in the mock chain, queued with loadImage*).
  clean-architecture 66 → 67. **679/680; suite 502 green; LiveCheck
  5/5; TestCheck 116→117 passed / 6→5 errored — class strictly
  improved.**
- 2026-07-11 iter 224: biggest class (2×) — UserPermissions. Four
  general fixes, distilled + pinned: (1) TYPED markers — member access
  on host types the program EXTENDS mints ImplicitMemberCall with a
  typeHint (both the ctor-function and HostTypeMarker arms), and
  hostCandidates dispatches the extension's members through it
  (`UNAuthorizationStatus.notDetermined.map`); resolveAnnotated tags
  bare markers under extended-host-type annotations (the stored-
  property path). (2) ImplicitMemberCall is CaseShaped — `switch self`
  inside host-enum extensions matches marker case names. (3)
  KeyPathStub.appending(path:) — native KeyPath concatenation
  (`pathToPermissions.appending(path: \.push)` drives the Store
  subscript write). (4) ViewRegistry's catch-all ctor bags carry
  their type as roles. pushFirstResolveStatus flipped;
  authorizationStatusMapping 4/5 assertions pass (rawValue:10
  singleton queued). FIRST GATE RUN caught typed-marker fallout:
  five projects failed "is not callable" (static CALLS on extended
  types) and LiveCheck dropped 4/5 — fixed by a call-dispatch arm
  re-minting typed markers with arguments, and absorbedNumeric
  reading named constants (.pi) off typed markers; LiveCheck
  RESTORED 5/5. Pins: HostEnumExtensionTests,
  StoreKeyPathAppendingTests. clean-architecture 67 → 68. **suite
  522 green; LiveCheck 5/5; TestCheck 117→118 passed / 11→10 failed
  — class strictly improved. ProjectCheck rerun in flight at commit
  (user-requested commit); verified next iteration.**
- 2026-07-11 iter 225: HEALTH RESTORATION — iter 224's post-commit
  ProjectCheck landed 678/680: Expense_Tracker broke on a NESTED
  `.system` marker reaching a view slot. Root: the new call-dispatch
  arm re-minted EVERY called ImplicitMemberCall — including markers
  that already carried arguments (a re-call), whose "not callable"
  throw callers' gateway fallbacks depend on. Narrowed: only
  EMPTY-args (member-access) markers re-mint on call; argument-
  carrying markers keep the throw. Expense_Tracker passes; all six
  iter-224-regressed projects re-verified individually; suite 522
  green; LiveCheck 5/5. ProjectCheck --all completing in background
  (user-requested immediate resume); verdict lands next iteration.
- 2026-07-11 iter 226: biggest fixable class (2×) — ImageWebRepository,
  ELIMINATED (clean-architecture 68 → 70). Root chain, distilled and
  pinned end to end: (1) `URLSession.download(from:)` was unbridged
  (the tuple-binding wall) — bridged with REAL download semantics:
  mocked bytes land in a temp file the caller reads back, failure
  mocks throw the ORIGINAL NSError; (2) bare URLs wrap in a
  URLRequest before URLProtocol.canInit (download AND data(from:) —
  the session's native behavior; the mock store matched requests,
  never raw URLs); (3) UIGraphicsImageRenderer/UIImageBox — real
  pixel-exact bitmaps (bitmap-rep render, NOT lockFocus which
  rasterizes at backing scale), UIImage(data:) decodes failably;
  (4) absorbed UIColor/NSColor statics (SwiftUI Colors) dispatch
  user extensions of the UIKit faces via hostCandidates. Pin:
  ImageDownloadPipelineTests. Gates: suite 524 green; TestCheck
  118→120 passed / 10→9 failed / 5→4 errored; LiveCheck 5/5.
  ProjectCheck 677/680: the two ❌ (MakeItSo, Mythic — action index
  errors) REPRODUCE ON COMMITTED HEAD WITHOUT THIS ITERATION'S
  CHANGES (stash-verified) — they arrived with the parallel lane's
  Food Truck merge (3b76f49/c13a84a); attributed there, queued as
  next iteration's health check if unclaimed.
- 2026-07-11 iter 227: HEALTH RESTORATION (claimed the parallel lane's
  app-shell fallout). The M4 app-shell root exposed two dormant sites:
  (1) MakeItSo — `Array.index(after:)` was unbridged, so computeOrder's
  bounds guard compared a marker (absorbed 0) and the subscript trapped;
  index(after:)/index(before:)/index(_:offsetBy:) now do stdlib integer
  index arithmetic. Pin: ArrayIndexArithmeticTests. FIXED. (2) Mythic —
  the onboarding "Back (DEBUG)" click fires the app's OWN precondition
  at stage 0 (delta -1 → index -1): a NATIVE DEBUG-build crash,
  unguarded upstream — LEDGERED as the corpus's second known failure
  (with Widgets). **suite 525 green; TestCheck 120/9/4 held; LiveCheck
  5/5; ProjectCheck 678/680 = documented baseline (2 ledgered
  native-real failures).**
- 2026-07-11 iter 228: FOODTRUCKCHECK BOOTSTRAPPED (the PRIMARY
  TARGET's instrument, per the restructured loop). `swift run
  FoodTruckCheck [--screen substring]`: R0 renders the real @main
  FoodTruckApp shell (scene:FoodTruckApp with @StateObject
  model/accountStore); R1 renders each sidebar panel through a probe
  app (DetailColumn + one Panel selection + FoodTruckModel — App.swift
  swaps for the probe, the twin's documented divergence; app sources
  READ-ONLY). Markers are app-source-derived strings. Deterministic
  (SWIFT_DETERMINISTIC_HASHING re-exec), rung score strictly-
  improving. SwiftPM gotcha: new executable targets with
  defaultIsolation reject top-level code in main.swift — @main struct
  form instead. **BASELINE: 3/9 rungs** (R0-shell, socialFeed,
  donutEditor ✅). Histogram, biggest first: (1) String(localized:
  bundle:comment:) returns EMPTY — kills donut/city names across
  donuts/salesHistory/topFive/truck markers; (2) Order `<` comparator
  (sort over Comparable Order) throws; (3) `max(...)` shadowed by a
  non-ctor in city (6464:32); (4) truck renders 1 string (mostly
  absorbed). Suite 525 green (instrument-only change).
- 2026-07-11 iter 229 (FoodTruck ladder): biggest histogram class —
  String(localized:bundle:comment:) returned EMPTY (every donut/city
  name blank). The String builtin had no `localized:` arm, so the
  all-labeled call fell to the positional fallback and yielded "".
  Fixed: the KEY is the development-language value, exactly what an
  unlocalized native run surfaces. Pin: LocalizedStringInitTests.
  CLASS ELIMINATED — names now populate everywhere (Order dumps show
  real donut/city/parking names). Rungs hold 3/9: the donuts marker
  now bottoms out in a DIFFERENT root, precisely staked via direct
  probes — DonutGalleryGrid renders donut names standalone, but
  `model.donuts(sortedBy: .popularity(.month))` returns EMPTY: the
  combinedOrderSummary → Dictionary.sales → `.sorted($0.value/$0.key)`
  pipeline collapses (next class; also behind topFive/salesHistory
  and adjacent to orders' `<` comparator). Harness gained
  FTCHECK_TRACE strings dump + LIVECHECK_TRACE wiring. gate.sh
  corpus board fixed: grep the ═══ summary (tail -1 grabbed the
  histogram's e.g. line) + ledger floor 678/680 (Widgets + Mythic
  documented; ratchets up only). **GATE GREEN: suite 526; corpus
  678/680 (ledgered, cached); live 5/5; parity 345/0/0.**
- 2026-07-11 iter 230 (FoodTruck ladder): the staked popularity-sort
  pipeline — THREE stdlib gaps, distilled and pinned: (1) NO
  `Dictionary(...)` builtin — `Dictionary(uniqueKeysWithValues:)`
  (the dailyOrderSummaries seed) absorbed into a stub, so every
  summary was empty; ctor added (+ grouping:by:, bare init). (2)
  for-in over a Dictionary threw — now yields (key, value) tuples in
  stable order. (3) `reduce(into: .empty)` never resolved its marker
  seed — it resolves against the ambient return annotation, exactly
  where native inference reads it; and `sales[key, default: 0] += v`
  read nil→Double — dictionary subscripts (rvalue, and BOTH lvalue
  arms) now honor `default:`. Pin: DictionaryPipelineTests.
  **RUNG FLIPPED: donuts ✅ — 3/9 → 4/9.** salesHistory/topFive
  advanced into real data (new roots: dict-of-summaries member at
  4267:35; topFive renders 18 strings sans title). orders (`<` on
  Order) and city (`max` ctor shadow) unchanged, queued. **GATE
  GREEN: suite 527; corpus 678/680; live 5/5; parity 345/0/0.**
- 2026-07-11 iter 231 (FoodTruck ladder): THREE RUNGS FLIPPED — 4/9 →
  7/9 (truck, orders, topFive ✅). Class: OrdersView's `.sorted(using:
  [KeyPathComparator(\.status, order: .reverse)])` — the comparator
  ctor absorbed (positional key path dropped) and sorted fell back to
  raw `<` on Order. Fixed, all native-verified via scratch swiftc and
  pinned by SortedUsingComparatorTests: (1) KeyPathComparator/
  SortDescriptor builtins → KeyPathComparatorBox (key path +
  direction); (2) `sorted(using:)` applies comparators via
  applyKeyPath, earlier comparators win ties, reverse honored,
  unknowable comparators keep input order; (3) same-enum payload-less
  cases compare by DECLARATION ORDER (SE-0266 synthesized
  Comparable). Plus: navigationTitle/navigationBarTitle strings
  surface to the strings collector — title chrome IS rendered content
  natively (flipped truck + topFive markers alongside orders' 74-
  string table). Remaining: salesHistory (dict-of-summaries member
  at 4267:35), city (`max` ctor shadow). **GATE GREEN: suite 528;
  corpus 678/680; live 5/5; parity 345/0/0.**
- 2026-07-11 iter 232 (FoodTruck ladder): **R1 COMPLETE — 9/9 rungs.**
  The last two: (1) salesHistory — FoodTruckModel's stored dict
  `dailyOrderSummaries` shadowed the same-named METHOD
  `dailyOrderSummaries(cityID:)` at call sites; the collision rescue
  now dispatches the symbol's OWN fitting overload first (before the
  conformance walk). (2) city — `Swift.max(...)`: module-qualified
  names strip the qualifier (Swift/Foundation/SwiftUI/Combine/
  Dispatch → the global builtin). First gate caught the refinement:
  Interactive_Header's `SwiftUI.Tab.init(value:)` beside its OWN
  `enum Tab` — DECLARED types never answer qualified access (the
  qualifier explicitly asks for the framework's symbol); corpus
  restored 677→678. Pins: ModuleQualifiedAndCollisionTests (both
  shapes + the bypass). Next ladder work: R2 pixel rungs against the
  native twin (Examples/FoodTruckNativeTwin, NSWindow captures) and
  R3 interactions. **GATE GREEN: suite 530; corpus 678/680; live
  5/5; parity 345/0/0; FoodTruckCheck 9/9.**
- 2026-07-11 iter 233 (FoodTruck ladder): **R2 PIXEL BOARD BOOTSTRAPPED
  — 8/8 screens compared, first AE=0.** FoodTruckCheck gained
  `--capture DIR`: every twin id renders through InterpreterHost
  (real ViewRegistry views) into an NSHostingView + borderless aqua
  NSWindow + 1x bitmap — the EXACT twin technique, capture-for-
  capture; Scripts/foodtruck-r2.sh drives both sides and prints the
  AE board. BASELINE (ratchet — AE only ever decreases):
  donut-view 0.000% (PIXEL-IDENTICAL, Canvas-drawn donut included),
  card-donuts 0.339%, card-orders 51.4%, content 52.5%, truck 64.5%,
  donuts/orders/socialfeed 100%. Read: leaf content is already at or
  near parity; the 100% trio is blank-vs-content (container chrome
  or capture failure — next class); order-bearing screens diverge on
  RANDOM + CLOCK data (the doctrine's frozen-clock policy is now
  load-bearing; that plus drand48 seeding is queued before those
  screens can ratchet). **GATE GREEN: suite 530; corpus 678/680;
  live 5/5; parity 345/0/0; R1 9/9.**
- 2026-07-11 iter 234 (FoodTruck R2): the 100% blank trio. Root found
  by real-capture bisect probes (diag-grid/diag-geo, kept in
  FoodTruckCheck): the grid + GeometryReader painted fine — the
  killer was `.toolbar`/`.toolbarRole` UNREGISTERED in the real
  registry, absorbing the whole modified subtree into a marker →
  blank. Fixed: (1) toolbar/toolbarRole pass the view through
  (borderless captures show no toolbar chrome natively either;
  toolbar ACTIONS are R3 surface); (2) GeometryReader gateway for the
  REAL registry — content re-evaluates per layout pass with the real
  proxy behind an @unchecked carrier (the InterpretedShape pattern);
  (3) FoodTruckCheck captures surface RenderDiagnostics per screen.
  Pin: RealRegistryChromeTests. **BOARD RATCHET: donuts 100%→4.76%,
  socialfeed 100%→39.8%** (its next root staked by the new
  diagnostics: `.black` opacity color chain in SocialFeedPostView);
  orders stays 100% (Table gateway, queued); truck 64.5%/content
  52.5% unchanged. **GATE GREEN: suite 531; corpus 678/680; live
  5/5; parity 345/0/0.**
- 2026-07-11 iter 235 (FoodTruck R2): orders 100% → **12.27%**,
  socialfeed → 27.4%. Three layers, bisected with real-capture diag
  probes: (1) REAL Table gateway — NSTableView-backed SwiftUI Table
  from the interpreted TableColumn DSL (columns-only form + rows:
  builder of TableRow marks via a rows collector; cells prebuilt per
  row through the interpreter; native headers/stripes/metrics);
  tableStyle(.inset/.bordered) real; `.background(in: shape)` fills
  the ambient style. (2) THE PLATFORM KNOB —
  Interpreter.interpretsAsPlatform: `#if os(...)` interpreted as
  macOS for the FoodTruck target (matching the twin build) while the
  corpus doctrine stays iOS; OrdersView's `displayAsList` had taken
  the iOS sizeClass branch (marker == .compact read TRUE) and blanked
  the whole screen. R1 holds 9/9 under macOS interpretation. Pins:
  RealTableGatewayTests (+ corpus-default knob assert). Remaining
  board: truck 64.5% / content 52.5% / card-orders 51.4% (frozen
  clock + seeded RNG next), socialfeed 27.4% (.black opacity chain),
  donuts 4.86%. **GATE GREEN: suite 532; corpus 678/680; live 5/5;
  parity 345/0/0.**
- 2026-07-11 iter 236 (FoodTruck R2): the seeded-RNG parity layer —
  six pieces, native-verified bit-for-bit on the micro shapes
  (raw/ranged/double draws EXACTLY match a compiled run; pin
  SeededRNGParityTests): (1) srand48/drand48 are REAL libc calls;
  (2) UInt64 is an exact 64-bit host carrier — and was being
  SHADOWED by the later fixed-width loop whose Int(d) TRAPPED on
  >Int.max draws (loop excludes UInt64 now, clamps others);
  (3) random(in:using:)/(4) shuffled(using:) drive the REAL stdlib
  algorithms through an InterpretedGeneratorProxy calling the
  interpreted next() — parity by construction; (5) prefix/suffix/
  dropFirst/dropLast resolve Int-position implicit markers
  (`prefix(.random(in: 1...5, using:))` drew nothing and took ALL 17
  donuts); (6) numeric factory markers ADOPT the peer's family in
  operand position (`date -= .random(...)` must draw, not absorb) —
  first gate caught over-eager adoption breaking the init-marker
  rewrap doctrine; narrowed to `random`. Model data now draws from
  the correct value-universe (1-5 donuts, native grandTotals) but
  the stream is OFFSET a few draws — draw-by-draw trace next; board
  data-screens unchanged pending alignment. **GATE GREEN: suite 533;
  corpus 678/680; live 5/5; parity 345/0/0; R1 9/9.**
- 2026-07-11 iter 237 (FoodTruck R2): **DATA PARITY COMPLETE — the
  interpreted FoodTruckModel's orders are IDENTICAL to native,
  order-for-order** (donut counts + grand totals match the twin
  exactly: 2/34.68, 4/69.36, 2/40.46, 3/52.02, 1/17.34, 5/80.92).
  Draw-by-draw stack-tagged tracing (drand48 trace + interpreted
  call-stack tags) found the last two stream leaks: (1) a MARKER's
  stored `using: &generator` rides as an INOUT SLOT — the factory
  arm's .instance match failed SILENTLY and fell to the system RNG
  (undrawn, per-run variance); generatorInstance(from:) unwraps
  direct/.instance, BindingStub, and InoutSlot forms. (2) the
  compound path (`date -= .random(...)`) bypassed the infix marker
  adoption — adopted there too. Pin extended (SeededRNGParityTests:
  compound draw + follow-on == native 3). Diagnostics kept: drand48
  RNG_TRACE with call-stack tags; traceStateCells now settable.
  Board: orders 11.73% (ratchet), data screens' residual AE is
  RENDER-side (card-orders 51% visual diff next). **GATE GREEN:
  suite 533; corpus 678/680; live 5/5; parity 345/0/0; R1 9/9.**
- 2026-07-11 iter 238 (FoodTruck R2): the truck-screen LAYOUT class —
  TruckView rendered a single compact column (the twin: a 2×2 card
  grid). Root: WidthThresholdReader's `isCompact` read TRUE through
  two gaps: (1) `dynamicType >= .xxLarge` compared two markers
  (throw-ish) — DynamicTypeSize markers now order by the REAL case
  ladder in combineValues; (2) the env canvas was iPhone-doctrine
  (`horizontalSizeClass: compact`) regardless of target — defaults
  are platform-aware now (macOS = regular; corpus keeps compact).
  Truck renders the two-column grid with the orders card + socialFeed
  title; the CARDS' remaining absorbs staked for next iterations:
  card chrome (headers/backgrounds), the Swift Charts forecast
  (weather card), donuts card body, and `\(x, specifier: "%02d")`
  string-interpolation specifiers (Order ids read "Order#121%02d").
  Pin: DynamicTypeAndPlatformEnvTests. **GATE GREEN: suite 534;
  corpus 678/680; live 5/5; parity 345/0/0; R1 9/9.**
- 2026-07-11 iter 239 (FoodTruck R2): custom Layouts EXECUTE — the
  interpreted sizeThatFits/placeSubviews run through a real SwiftUI
  Layout (InterpretedLayout, the InterpretedShape carrier pattern),
  replacing the default-flow VStack. Three roots closed: (1) the
  direct spelling `SomeLayout { … }` SHORT-CIRCUITED to groupViews
  before instantiation (a pre-layout-era arm) — it now instantiates,
  stashes children, and wraps renderable like the parenthesized
  form; (2) ForEach children reach layouts one-subview-PER-ELEMENT
  via a ForEachFan carrier the layout arm splices (native-verified:
  AnyView does NOT block variadic expansion — a scratch compiled
  Layout counts AnyView(ForEach(0..<3)) as 3 subviews); (3) host
  geometry the layout math needs: CGRect(origin:size:)/
  (x:y:width:height:), UnitPoint(x:y:) ctors + host-UnitPoint
  coercion (tiles placed at (0,0) anchor .zero without them).
  card-orders now renders hero + 2×2 tiles at native-identical
  offsets (PLACE trace matches the compiled math exactly);
  HeroSquareTilingLayout sees 5 subviews, DiagonalDonutStackLayout
  3/3/3/3/2 — the native structure. Board: donuts 4.86%→0.44%,
  orders 11.73%→9.79%, donut-view 0.000%, card-donuts 0.339%;
  content 54.4%/truck 66.5%/card-orders 55.2% tick UP ~2-4pp — real
  layout geometry no longer accidentally aligns with the twin while
  CardNavigationHeader renders nothing (cards sit ~13px high, every
  square edge double-counts). NEXT (staked): card chrome —
  CardNavigationHeader + card white backgrounds — should drop all
  three together; then Swift Charts (forecast card), `%02d`
  interpolation specifiers, socialfeed opacity chain. Diagnostics
  kept: FTCHECK_TRACE prints LAYOUTSTASH/MAKELAYOUT/LAYOUT/PLACE/
  FOREACH; diag-layout + diag-minilayout capture probes. Pins:
  InterpretedLayoutTests (pixel-placement through a RENDERED
  interpreted layout + geometry-ctor evaluation). **GATE GREEN:
  suite 536; corpus 678/680; live 5/5; parity 345/0/0; R1 9/9.**
- 2026-07-11 iter 240 (FoodTruck R2): the card-chrome class — THREE
  roots, found by bisecting the blank CardNavigationHeader
  (Label✓ → NavigationLink✓ → .labelStyle ✗): (1) `labelStyle` was
  entirely unregistered — the modifier absorbed the SUBTREE into a
  marker (blank header). Custom LabelStyle conformers now run their
  interpreted makeBody(configuration:) through a REAL LabelStyle
  (InterpretedLabelStyle, carrier pattern #3 after Shape/Layout);
  the style value resolves from protocol-extension statics
  (`.cardNavigationHeader` → resolveForBridge typeName "LabelStyle")
  or direct instances; configuration.icon/.title are host members;
  builtins map (iconOnly/titleOnly/titleAndIcon/automatic).
  (2) `.quaternary.opacity(0.5)` (card-tile fill) THREW out of
  Coerce.shapeStyle (chains required a Color base) and fell to a
  flat-gray stand-in 12/255 darker than compiled — hierarchical/
  material bases now keep the REAL style through .opacity chains.
  (3) `#if canImport(UIKit)` held on the macOS canvas (canImport was
  blanket-true), so the compiled #else branch never ran — canImport
  is platform-truthful now (macOS: no UIKit/WatchKit; iOS canvas:
  no AppKit/Cocoa). Board after: **card-donuts 0.000% (SECOND
  pixel-identical screen), card-orders 55.2%→3.18%, truck
  66.5%→12.04%, content 54.4%→25.4%**; donuts 0.44%, orders 9.83%
  (+0.03pp — a canImport padding edge, twin is arbiter), donut-view
  0.000%, socialfeed 27.45% unchanged. Next classes staked, in AE
  order: socialfeed body (`.black.opacity` chain hits a COLOR
  coercion that rejects chains — diagnostics name it now, and error
  placeholders paint into the feed), content's twin-side blank
  sidebar (headless NavigationSplitView — fair-comparison policy),
  Swift Charts forecast body, `%02d` interpolation specifiers.
  Pins: InterpretedStyleTests (custom-style makeBody pixel pin +
  hierarchical-chain band pin) + PlatformCanImportTests. **GATE
  GREEN: suite 539; corpus 678/680; live 5/5; parity 345/0/0;
  R1 9/9.**
- 2026-07-12 Dictionary default-subscript fidelity: the dedicated Optional
  representation exposed a semantic leak in FoodTruck summary union — an
  existing `dictionary[key, default: value]` read returned `Optional<Value>`
  instead of `Value`, so `0 + Optional(41)` dropped two R1 screens (7/9).
  Defaulted reads now preserve the nonoptional result, distinguish an absent
  key from a present Optional `.none`, and evaluate the fallback only on a
  miss. Lvalue resolution carries its access mode: read-modify paths defer the
  fallback, while direct setters preserve native Swift's observable eager
  `@autoclosure` evaluation. Pins cover reads, direct/compound mutation,
  fallback side effects, Optional-valued dictionaries, and FoodTruck's exact
  two-summary union. SwiftScript comparison rechecked at upstream
  `71605b28`; FoodTruck restored 7/9→9/9. **GATE GREEN: suite 646; corpus
  678/680; live 5/5; parity 345/0/0; R1 9/9.**
- 2026-07-12 FoodTruck R2 Social Feed style-value boundary: the native-twin
  board confirmed the staked row-body failure and exposed its second layer.
  (1) Color-typed gateways used a stricter funnel than ShapeStyle positions,
  so every `.shadow(color: .black.opacity(0.15), …)` rejected the deferred
  chain and painted an error row. `Coerce.color` now delegates to the one
  recursive color-shaped resolver; a native probe and the focused pin both
  resolve the exact RGBA 0/0/0/0.15. (2) `AnyShapeStyle(...)` had no real
  constructor and became an absorbing SDK bag, so the interpreted
  `tagBackgroundStyle` computed property could not feed generated
  `.backgroundStyle(_:)`. The gateway now retains a real raw type-erased style
  across return/storage boundaries. SocialFeedPostView has zero render
  diagnostics and **socialfeed AE ratchets 27.448%→16.960%**; card-donuts and
  donut-view remain 0.000%, with the other established screen floors intact.
  Remaining Social Feed error is visibly a separate layout/content class.
  Pins: InterpretedStyleTests (native color components + rendered shadow,
  raw AnyShapeStyle identity + computed-property/generated-modifier round
  trip). **GATE GREEN: suite 648; corpus 678/680; live 5/5; parity 345/0/0;
  R1 9/9.**
- 2026-07-12 localized interpolation fidelity: FoodTruck's
  `String(localized: "#\(number, specifier: \"%02d\")")` exposed that an
  expression segment's labeled arguments were being rendered as independent
  values, producing `#1%02d` instead of native `#01`. Interpolation arguments
  now evaluate exactly once from left to right, labels select behavior rather
  than contribute output, and `specifier:` requires a String before formatting
  the value. The localized path and `String(format:)` share one host-safe
  C-vararg conversion boundary; ordinary unlabeled interpolation retains its
  allocation-free fast path. Native pins cover integer/float/hex formatting,
  exact FoodTruck output, evaluation order (`vs`), and invalid specifiers.
  FoodTruck R2 ratchets orders 9.828%→7.291%, card-orders 3.183%→3.053%,
  truck 12.036%→12.012%, socialfeed 16.960%→16.946%, and content
  25.408%→25.381%, with all eight screens non-regressing. Stabilized release
  SpeedBench holds a 9,426× geometric mean (interpolation loop 875×).
  **GATE GREEN: suite 651/139; corpus 678/680; live 5/5; parity 345/0/0;
  R1 9/9.**
- 2026-07-16 R3 BOOTSTRAP (run-the-app resume, first worktree iteration):
  the interp side of the function-parity protocol exists and the FIRST
  BOARD IS AT FLOORS. FoodTruckCheck gained `--scenario <name|all>`
  (with --capture): six scenario declarations mirror the twin's
  runScenarios exactly — same model-API mutations, same capture ids
  (order-steps splits into two staged fresh-model scenarios interp-side;
  same post-states, same ids). Scripts/foodtruck-r3.sh runs both sides
  and prints the AE board. First board (10 captures, zero render
  diagnostics): donut-view-after-rename 0.000% and
  card-donuts-after-popularity 0.000% — interpreted updateDonut and the
  bulk-complete popularity re-sort are PIXEL-IDENTICAL post-mutation;
  donuts-after-rename 0.463%, donuts-after-popularity/detail-donuts
  0.437%, orders-after-complete 7.506%, orders-after-preparing 7.450%,
  orders-after-steps 8.327%, detail-orders 7.452%, detail-truck 12.012%
  — every scenario lands AT its screen's R2 floor, so the mutations
  produce the same pixel deltas as compiled; the residuals are the KNOWN
  static classes (orders table chrome, truck Charts card), not function
  gaps. Changed-guard verified manually both sides (donuts pre-vs-post:
  twin 777px, interp 693px — mutation visibly renders, not absorbed);
  encoding the guard + floors into the board script is the next
  instrument class, then burn the orders/truck residue where R3 and R2
  share a root. These floors are the R3 ratchet baseline — down only.
- 2026-07-16 orders-family Table fidelity (worktree iteration 2): ONE
  root, six board rows — the OrdersTable columns. (1) The Donuts column
  was BLANK: numeric `formatted()` existed only for Date — Foundation
  publishes it on the numeric PROTOCOLS, and BridgeGen skipped protocol
  extensions entirely. BridgeGen now expands protocol extensions to
  their concrete runtime carriers (BinaryInteger/SignedInteger/
  FixedWidthInteger → Int, BinaryFloatingPoint/FloatingPoint → Double)
  and the regenerated tier serves Int/Double.formatted() — the column
  renders the twin's exact values row-for-row. (2) The Details column
  VANISHED: `.width(60)` on the TableColumn DSL had no host member, so
  the spec absorbed into a chain marker and the Table saw 4 of 5
  columns. The sanctioned Table gateway's spec now carries
  fixed/min/ideal/max widths applied to the real TableColumns. (3) Cell
  builds no longer swallow errors behind try? — failures record into
  RenderDiagnostics named per column. Board: orders 7.399%→2.953%,
  orders-after-complete 7.506%→2.965%, orders-after-preparing
  7.450%→3.057%, orders-after-steps 8.327%→4.141%, detail-orders
  7.452%→3.015%; all other rows hold (AE=0 rows stay 0.000%,
  detail-truck 11.889%). Residual orders classes staked: frozen clock
  (Date column drifts by capture time — protocol-level, both sides),
  Details Menu label icon, Status header sort chevron. Pins:
  NumericFormattedAndTableWidthTests (host-native formatted() parity +
  width spec round-trip).
- 2026-07-16 FROZEN CLOCK lands (worktree iteration 3): the R2/R3 boards
  are now deterministic across runs and days. FOODTRUCK_FROZEN_NOW
  (epoch seconds; boards pin 1784228400) freezes `Date.now` on BOTH
  sides through the SAME env-gated shim: the twin's sync.sh generates
  HarnessFrozenClock.swift into each target (module-scoped shadowing —
  the Kit is its own module; precedent: the ActivityKit sed), and
  FoodTruckCheck appends the identical extension to its merges. The
  interpreter needed the underlying SEMANTIC: program extensions now
  SHADOW imported statics (`extension Date { static var now }` beats
  Foundation's) on both the qualified member path (MemberEvaluator
  hostFunction arm — extension statics before readHostMember) and the
  annotation path (resolveAnnotated — hoisted extension static/method
  arms above the builtin marker arms), matching compiled Swift's
  same-module rule. Board: orders 2.953%→0.777%, orders-after-complete
  2.965%→0.777%, orders-after-preparing 3.057%→0.869%, detail-orders
  3.015%→0.777%, orders-after-steps 4.141%→2.995% (its extra residue is
  a distinct status-render class); all other rows hold, R1 9/9,
  AE=0 rows stay 0.000%. foodtruck-r3.sh id loop fixed for zsh (unquoted
  vars do not word-split). Remaining orders residue: Details Menu icon +
  Status sort chevron + the after-steps status class; biggest board row
  is now detail-truck/truck 11.9% (Swift Charts forecast). Pins:
  InterpretedStaticShadowingTests (qualified + annotation shadowing,
  env-gated frozen value).
- 2026-07-16 Swift Charts executes (worktree iteration 4): the Chart/
  ChartContent result builders run through a new magic-tier gateway
  (ChartsBridge — documented per AGENTS.md: result-builder execution +
  `.value` PlottableValue factory glue; everything downstream is REAL
  Charts). AreaMark/LineMark/BarMark/RectangleMark build as real marks
  erased to AnyChartContent; mark modifiers (foregroundStyle/opacity/
  interpolationMethod/cornerRadius/mask/annotation) apply on the erased
  content, with @ChartContentBuilder method returns and chart ForEach
  passing mark ARRAYS through makeGroup/the ForEach gateway; chartYScale
  bridges; custom chartXAxis/chartYAxis builders record a named
  diagnostic and render DEFAULT axes. Shared coercion:
  `.linearGradient(colors:startPoint:endPoint:)` resolves to a real
  LinearGradient in the style funnel (was the thrown error painting the
  forecast card red). PIN-verified: an interpreted @ChartContentBuilder
  method renders a REAL area chart (pixel-sampled), gradient factory
  coerces. Board: truck holds 11.889% — the forecast card body remains
  BLANK because `@State private var forecast = placeholderForecast`
  (static-seeded state) resolves empty entries; that data class + the
  `.indigo.shadow(.drop(…))` style shape + custom axis DSL are the
  staked next classes. Notable false lead pinned in memory: making
  [AnyChartContent] an isViewValue routed mark arrays into the STRICT
  view-modifier retry — reverted; marks are content, not views. Pins:
  InterpretedChartTests.
- 2026-07-16 forecast-blank diagnosis narrowed (worktree iteration 5,
  time-boxed): the staked "@State from static" hypothesis was WRONG —
  a distilled probe passes, and a data probe through the real card
  proves placeholderForecast resolves fully (25 entries, 1 night range,
  low 53.0; Calendar/DateComponents/computed props all work). A date-x
  AreaMark probe with entries/series/interpolation renders a REAL
  gradient area chart. The real failure is a TWO-PASS divergence:
  chartContents drop diagnostics (new this iteration — silent drops now
  record named RenderDiagnostics) show one body evaluation returning
  pure marks (FOREACH-KINDS elements=25 marks=25; night ForEach 1→3
  marks incl. mask+annotations) while ANOTHER evaluation of the SAME
  closures returns view-wrapped content (AnyView(ModifiedContent<
  AnyView,_ForegroundStyleModifier>) + a ForEachFan) that the Chart
  gateway rightly refuses — the blank card is the dropped pass. Landed:
  chart-content drop diagnostics + runtime-array splicing in
  chartContents, FOREACH-KINDS/CHARTMEMBER FTCHECK_TRACE probes,
  diag-forecast-data/diag-weather capture probes, capture diagnostic
  cap 4→12. NEXT (staked precisely): find which of the 2-3 InterpretedView
  body evaluations diverges and why mark constructors resolve to views
  there — suspects: post-adoption env injection changing registry
  dispatch, or the second evaluation running under a different builder
  context. Pins unchanged (InterpretedChartTests green). GATE-RED
  POSTMORTEM (same iteration): the "parallel test workers failed" REDs
  were NOT contention — GATE_KEEP_LOGS=1 named 42 issues in
  hostedRealRender corpus tests (arrived with the iteration-start merge)
  that assert EMPTY RenderDiagnostics: the new chart-drop diagnostic
  fired from makeGroup on every ordinary view group. Drop recording is
  now scoped to true chart contexts (Chart builder + mask) via a
  recordDrops flag; all 20 hostedRealRender cases +
  taskObservatoryExample pass. Instrument lesson logged: keep gate logs
  (GATE_KEEP_LOGS) BEFORE re-rolling a red gate.
- 2026-07-16 THE FORECAST CHART RENDERS (worktree iteration 6): the
  two-pass divergence root was the WeatherKit absorb — the card's .task
  called WeatherService.shared.weather(for:including:), the interpreter
  ABSORBED it into a stub (headless native THROWS without the
  entitlement), the map produced empty entries, and the state write
  overwrote placeholderForecast — the re-render pass drew an empty
  chart while the first pass had drawn marks. Fix per the scope
  quarantine + AGENTS.md documented allowlist: entitlement-gated
  service types FAIL CLOSED — a new environmentalServiceTypes allowlist
  (WeatherService) at the HostTypeMarker seam throws a catchable
  NSError-backed InterpretedThrow from any member call; the app's own
  catch keeps the sample data, exactly like compiled headless. The
  interpreted forecast card now renders the gradient temperature curve,
  masked night band, and pillar marks. Board: truck/detail-truck
  11.889%→12.625% (+0.74pp, ACCEPTED structure-first: the rendered
  chart's DEFAULT axes diverge more from the twin's custom axes than
  the old blank card did — same trade as iter 239, and the completing
  class is staked: the AxisMarks/AxisValueLabel/AxisTick/AxisGridLine/
  DateBins axis DSL, plus the annotation icons and the masked-band
  color). Pin: EnvironmentalServiceTests (throw + catch keeps state).
- 2026-07-17 CHART AXIS DSL + stdlib sweep (worktree iteration 7):
  truck/detail-truck **11.889% → 4.336%** — the completing class landed.
  Two roots: (1) the axis DSL is bridged through the ChartsBridge
  magic-tier gateway — DateBins(unit:by:range:) (real, ClosedRange
  Date), AxisMarks (values array / .automatic(minimumStride:
  desiredCount:roundLowerBound:)), AxisValueLabel (string +
  format: .dateTime chains), AxisTick/AxisGridLine, composed via
  AnyAxisMark(erasing: AxisMarkBuilder.buildBlock(...)) count-switch;
  the per-value content closure runs INTERPRETED through an
  AxisMarksSpec carrier (InterpretedLayout pattern — Charts calls it at
  layout), with AxisValue.as(Double/Int/Date/String) host members.
  (2) binRange's `first(where:)!` returned nil because Int.isMultiple
  (of:) was UNBRIDGED — a STDLIB protocol-extension member: BridgeGen
  now sweeps the Swift stdlib swiftinterface with the same
  protocol-receiver expansion (Self params/returns resolve to the
  concrete carrier in both mapping and contract). The forecast card
  now renders hour labels, °F labels, gradient curve, night band —
  near twin-identical. Same-day board (twin refreshed; the frozen
  clock shadows Date.now but Calendar.isDateInToday compares REAL
  now, so cross-day twin captures go stale — documented): truck/
  detail-truck 4.336%, orders family 0.777-0.869%, orders-after-steps
  3.144%, donuts 1.041% (+0.6pp residual, staked), card-orders
  2.385%, socialfeed 17.155%, content 26.201%, four AE=0 rows hold.
  Remaining truck residue: pillar .shadow(.drop) style + annotation
  icons. Pins: InterpretedChartTests.customAxisBuildersRender
  InterpretedLabels (pixel), StdlibNumericMemberTests.
- 2026-07-17 gate note (same iteration): the closing gate reads RED on
  the corpus floor (674/680) — the four new failures (CotEditor,
  kiwix-apple, element-x-ios, Provenance) all throw "isolated/MainActor
  deinitializer requires executor-owned teardown, not supported yet",
  from the concurrency lane's staged fail-closed deinit commits
  (55e38b0/b15585e/ea22b3a) inherited at iteration-start merge;
  suite/live/parity and all lane pins are green. Close-merge DEFERRED
  per worktree protocol until the upstream class lands its
  implementation and the floor recovers.
- 2026-07-17 socialfeed FlowLayout class (worktree iteration 8):
  **17.155% → 10.789%** — the tag pills flow. Three interpreter
  semantics gaps, bisected with PLACE/SIZEQ traces and distilled
  probes, every fix core/shared-tier: (1) LOCAL FUNCTIONS HOIST —
  FlowResult's for-loop calls finalizeRow/addToRow declared AFTER it;
  executeBlock now binds function decls up front (closures capture the
  environment OBJECT, so later vars resolve at call time). (2) stdlib
  `zip` — `for (index, subview) in zip(subviews.indices, subviews)`
  silently absorbed to zero iterations; a zip builtin pairs runtime
  sequences (arrays/ranges/strings) as unlabeled tuples. (3) the
  native factory now bridges CGFloat/Float into .double as its own doc
  comment promised — ViewSpacing.distance returned a host CGFloat that
  `'+' cannot combine 95.5 and 8.0` refused (the error that named the
  class). Plus the Layout gateway grew its documented ViewSpacing face
  (LayoutSubviewBox.spacing, ViewSpacing() ctor,
  distance(to:along:)). Remaining socialfeed residue: donut/city pill
  thumbnails (placeholder squares), post avatar circles. Pins:
  InterpreterScopeAndSequenceTests (hoisting + self-mutation, zip
  tuples, nested-row build). Upstream corpus floor still 674/680
  (isolated-deinit staging) — close-merge remains deferred.
- 2026-07-17 socialfeed pills COMPLETE (worktree iteration 9):
  **socialfeed 10.789% → 0.393%, truck 4.336% → 1.998%** (the truck's
  social card body rides the same fix). The pill texts were init
  markers: `var title: LocalizedStringKey { .init(donut.name) }` — a
  computed property returning `.init(…)`. Three-piece fix, all
  doctrine-tier: (1) LocalizedStringKey host ctor — a key IS its
  literal text in the merged model (String(localized:) doctrine);
  (2) computed-property markers now CARRY the property's declared type
  as their typeHint (the laziness contract said "resolve at the
  dispatch boundary" but a hintless marker never could); (3) the REAL
  Text gateway resolves hinted markers via resolveForBridge before the
  fresh-string doctrine blanks them. Board: content 25.806% (the last
  big row — twin-side blank sidebar policy; detail-* rows are the
  sanctioned per-panel comparison), donuts 1.041%, orders 0.777%,
  card-orders 2.385%, card-donuts/donut-view 0.000%. Pins:
  ComputedMarkerHintTests (typed marker + Text-boundary resolution +
  key ctor). Upstream deinit floor still holds three lane commits
  unmerged.
- 2026-07-17 gate note (same iteration): the closing gate's suite
  stage hangs REPRODUCIBLY at the upstream
  requiredModeRejectsExternalActor{ComputedSetter,SubscriptSetter}
  BeforeMutation pair (both at 0% CPU after ~89 passes; the pair
  passes together standalone in 1.5s — a worker-parallelism deadlock
  only under the gate's helper). Corpus RECOVERED upstream to
  678/680; live 5/5; parity 345/0/0; the full standalone suite
  passed 1029/1029 this session. Close-merge still deferred pending
  one clean gate; the exact pair is flagged to the concurrency lane
  in claims. Five lane commits queue: frozen clock, Charts gateway,
  axis DSL + stdlib sweep, FlowLayout semantics, socialfeed pills.
- 2026-07-17 gate-deadlock DIAGNOSED (worktree iteration 10, diagnosis
  iteration): the suite stage's reproducible hang is the upstream
  requiredModeRejectsExternalActor{ComputedSetter,SubscriptSetter}
  BeforeMutation tests spawning Scripts/
  validate-concurrency-parity-summaries.rb — the ruby child blocks at
  0% CPU (stdin pipe never closes under swiftpm-testing-helper's
  parallel workers) and the test's waitUntilExit stalls both workers
  after ~89 passes. Reproduced OUTSIDE the gate with the exact helper
  invocation; the pair passes together standalone in 1.5s. The fix
  belongs to the concurrency lane (their tests + validator script);
  the mechanism is posted in claims. Five lane commits remain queued
  for one clean gate.
- 2026-07-17 gate deadlock FIXED (worktree iteration 11): every test
  Process spawn now sets standardInput = FileHandle.nullDevice — the
  ruby validator child inherited the parallel worker's never-closing
  stdin pipe and waitUntilExit pinned both workers (~89 tests in).
  With the fix the suite RUNS TO COMPLETION under the gate (1064
  tests in 413s). One NEW failure surfaced and is attributed
  upstream: sessionScriptToleranceIntervalsAndAppending (top-level
  fatalError tolerance for merged tooling scripts) passes at lane
  ffedc48 and fails after merge 6909753 brought the concurrency
  lane's AsyncThrowingStream/actor series — flagged in claims. The
  six-commit queue still awaits one clean gate.
- 2026-07-17 upstream regression BISECTED (worktree iteration 12):
  sessionScriptToleranceIntervalsAndAppending fails from commit
  25ad8db "Correct AsyncStream producer ownership" (weak storage on
  producer handles — RuntimeAsyncStream.swift, 22 source lines);
  passes at its parent. git-bisect-run verified, standalone repro
  posted in claims for the concurrency lane. The lane queue (six
  commits: frozen clock, Charts gateway, axis DSL + stdlib sweep,
  FlowLayout semantics, socialfeed pills, gate stdin fix) remains
  ready for one clean gate; the FoodTruck board stands at four AE=0
  screens, socialfeed 0.393%, truck 1.998%, orders 0.777%, donuts
  1.041%, card-orders 2.385%.
- 2026-07-17 tile outlines land (worktree iteration 13): strokeBorder
  was entirely unbridged (the tiles' hairline outline silently
  absorbed). A centered-stroke approximation measured WORSE than blank
  (AA at 0.5pt); the REAL InsettableShape inside-stroke is retained at
  ShapeBox construction (`init(insettable:)` keeps a strokeBorder
  painter closure — erasure loses the conformance) and the five
  insettable constructors route through it. Board: **card-orders
  2.385%→0.168%, truck 1.998%→1.400%, orders 0.777%→0.492%, socialfeed
  0.393%→0.472%** (tiny AA shift from strokes now present, accepted),
  donuts 1.041%, content 25.979% (twin-side sidebar policy), four
  AE=0 rows hold. Upstream tolerance regression (25ad8db) still
  blocks the gate; queue is seven commits. Pin: StrokeBorderTests
  (inside-ink present, no outside leak, unfilled center).
- 2026-07-17 tolerance contract reconciled (worktree iteration 14): the
  25ad8db regression root was the located-rewrap invariant ("runtime
  traps stay fatal across gateway boundaries") colliding with the
  script-tolerance contract that had relied on the accidental
  fatal-flag drop. Reconciled: stack-guard trips now carry budgetTrip
  (they are resource trips, same family as the step budget), and the
  ProgramEvaluator top-level script arm tolerates trap errors by
  keying on !budgetTrip instead of !fatal — traps stay fatal at every
  gateway boundary, the documented top-level script exception holds,
  and budget/stack trips still abort. sessionScriptTolerance +
  runawayRecursion both green. REMAINING upstream blocker, proven on a
  pristine main merge: activeInterfaceAliasesResolveToRuntimeIntrinsics
  fails on PURE MAIN (the committed runtime/generator emit checked-
  continuation dispatch entries, the committed test expects 13 without
  them, and the checked-continuation registration path SIGTRAPs — the
  half-landed c7e1f14/6d2f294 series). Two convergence attempts hit
  their protective traps; theirs to complete. Lane queue: nine commits.
- 2026-07-17 R3 spec enforcement lands and CATCHES REAL GAPS (worktree
  iteration 15): foodtruck-r3.sh now enforces the spec — per-capture
  FLOORS (ratcheted from the current board + headroom) and the
  CHANGED-GUARD with disagreement semantics (one side re-renders the
  mutation, the other does not; both-zero = agreement, e.g. donut-view
  shows art, not the renamed label). First enforced board: 8/10
  scenarios green within floors; the guard EXPOSED two interp-side
  function no-ops — orders-after-preparing (twinΔ 0.092, interpΔ 0)
  and orders-after-steps (twinΔ 2.367, interpΔ 0):
  `model.orderBinding(for:).wrappedValue.markAsPreparing()/.markAsComplete()`
  mutations do not re-render, while the direct model-method route
  (markOrderAsCompleted) does — the Binding wrappedValue
  mutating-method write-back class, STAKED as the next iteration's
  work. The board script exits nonzero on the gaps, as the spec
  demands. Upstream checked-continuation half-landing still blocks the
  gate (their new Void-resume commit landed; the test-update commit
  has not).
- 2026-07-17 **R3 COMPLETE — all ten scenarios green** (worktree
  iteration 16): the guard-caught class was one line — the
  Binding(get:set:) gateway only accepted a LABELED get closure, so
  the Kit's trailing form `Binding<Order> { … } set: { … }`
  (orderBinding) seeded the box with VOID and
  `wrappedValue.markAsPreparing()` had nothing to land on. With the
  trailing get accepted, the status mutations render and the enforced
  board reads: donuts-after-rename 1.067%, donut-view-after-rename
  0.000%, orders-after-complete/preparing/steps 0.492%,
  donuts-after-popularity 1.041%, card-donuts-after-popularity 0.000%,
  detail-truck 1.400%, detail-orders 0.492%, detail-donuts 1.041% —
  ALL within floors, ALL mutations visible (changed-guard green). The
  ladder now stands R0 ✓, R1 9/9 ✓, R2 at floors (4× AE=0), R3 ✓ per
  the spec's model-API protocol. Pin: BindingTrailingGetTests. Next:
  R4 residue burn-down (donuts 1.04%, truck 1.40% annotation icons)
  and the interactive `--project` launch; the gate still awaits the
  upstream checked-continuation completion.
- 2026-07-17 **THE APP RUNS** (worktree iteration 17): `swift run
  DynamicSwiftUIDemo --project Examples/
  FoodTruckBuildingASwiftUIMultiplatformApp --platform macOS` launches
  a LIVE interactive window — the interpreted Food Truck renders its
  full sidebar (Truck/Orders/Social Feed/Sales History, Donuts,
  Cities), the New Orders card (hero + 2×2 tiles + Order#1201 12), and
  the Forecast chart (gradient curve, night band, hour + °F axes)
  inside a real NSWindow, correctly adapted to the system DARK
  appearance (hierarchical styles resolving against the live window —
  incidental proof the style pipeline is real, not baked). Evidence:
  Docs/evidence-foodtruck-live-window-2026-07-17.png, captured by a
  new env-gated harness hook (DYNAMIC_DEMO_SELF_CAPTURE writes the
  live window's contentView bitmap after settle and keeps running) —
  this session lacks screen-recording access, so the app self-reports.
  The RUN-THE-APP north star is standing: R0–R3 green ladder + a
  usable interactive window. Remaining: R4 pixel residue, click-driven
  interaction sweeps, and the upstream checked-continuation completion
  that still gates the eleven-commit merge.
- 2026-07-17 donuts-gallery residue diagnosed to the data (worktree
  iteration 18): the 1.041% donuts row is a SORT-ORDER divergence of
  two adjacent pairs (Cosmos/Picnic Basket, Nighttime/Strawberry
  Sprinkles) in DonutGallery's default `.popularity(.week)` sort. The
  interpreted sort and dictionary machinery are CORRECT (distilled
  probe passes; month sales match; comparator deterministic): the
  divergence is in the WEEK sales data itself — interp cosmos=218/
  picnic=216 and sprinkles=94/nighttime=93, while the twin's implied
  ordering requires the opposite by 1-2 counts. Orders are verified
  identical order-for-order (RNG parity), so the residual stream is
  the SALES-HISTORY generation tail (a different seeded path than
  todaysOrders). STAKED: diff the sales-history stream via RNG_TRACE
  + a twin dump extension, the way the orders stream was aligned on
  07-11. Upstream checked-continuation completion still gates the
  merge queue (fourteen commits).
- 2026-07-17 sales-stream suspects narrowed (worktree iteration 19):
  pow is BIT-EXACT against libm (pinned: PowBitExactTests), dates and
  the weekend multiplier are frozen-deterministic, and the summary
  union machinery is proven. The 1-2 count week drift therefore lives
  in the per-city seeded sequence of historicalDailyOrders — the
  14-donut shuffled(using:) order or the per-day Double.random draw
  sequence over city seeds (a longer stream than the pinned orders
  case). STAKED with the method: RNG_TRACE both sides + a twin dump of
  the per-city day-one sales vector, then align draw-by-draw as on
  07-11. Upstream: the checked-continuation series continues
  (throwing-MainActor characterization landed); the alias-test
  completion still gates the fifteen-commit merge queue.
- 2026-07-17 donuts residue ELIMINATED (worktree iteration 20):
  **donuts 1.041% → 0.437%, detail-donuts likewise** — the entire
  +0.6pp drift was ONE wall-clock leak. The stream diff (twin
  TWIN-HISTORY dump + interp day-0 vector probe) showed Cupertino's
  day-0 sales scaled by EXACTLY 1.25 — the weekend multiplier — and
  the chain probe isolated it: `startOfDay(for: .now)` resolves the
  bare `.now` ARGUMENT marker through the bridge's dateArg, which
  hardcoded the WALL clock (`Date()`), bypassing the program's frozen
  `extension Date { static var now }` shadow; day-60 landed on Monday
  instead of Sunday. Fix: Interpreter.ambientDateNowProvider —
  installed per run when the program shadows Date.now (both
  ProgramEvaluator entries), consulted by dateArg's `.now` arm — the
  shadowing rule now holds in Date ARGUMENT positions too. pow was
  cleared bit-exact en route (pinned). Board: donuts/detail-donuts
  0.437%, R3 all green, four AE=0 rows hold. Pins:
  AmbientDateNowTests (chain stamp + weekend parity vs native), twin
  TWIN-HISTORY dump kept as harness. Remaining R4 residue: truck
  1.400% (annotation icons + pillar shadow), socialfeed 0.472%,
  orders 0.492%, card-orders 0.168%. Upstream alias-test completion
  still gates the sixteen-commit merge.
- 2026-07-17 symbolRenderingMode joins the generated tier (worktree
  iteration 21): the annotation-icon chain's missing link —
  `.symbolRenderingMode(.palette)` was unbridged because
  SymbolRenderingMode (a static-constant struct, not an enum) wasn't in
  BridgeGen's modifier param whitelist. Added the mapping + ParamTag +
  marker coercion (palette/hierarchical/multicolor/monochrome);
  regenerated (501 modifier variants). Truck holds 1.400% — the icons
  STILL don't paint despite the chain now resolving and the annotation
  arm running without diagnostics; restaked with the next probe:
  annotation-in-isolation through the ChartsBridge arm (suspects: the
  omitted alignment parameter, or views.first coming up empty in the
  annotation builder). The `.shadow(.drop)` pillar style remains the
  other truck residue. Upstream alias-test completion still gates the
  seventeen-commit merge.
- 2026-07-17 annotation icon narrowed to the palette layers (worktree
  iteration 22): the isolation probe (diag-annotation) proves the
  annotation ARM works — the icon is placed at the pillar top — but it
  paints ALL-WHITE (visible only as a gap across the gridline): the
  palette two-layer styling isn't taking effect, so
  foregroundStyle(.white, .indigo) shows only the primary white layer.
  Suspects, in order: the env-propagated symbolRenderingMode not
  reaching the descendant Image through the AnyView wrapping, or the
  generated two-arg foregroundStyle applying to the wrapper instead of
  the symbol layers. Next probe: palette variants side-by-side
  (.multicolor, plain .foregroundStyle(.indigo), unwrapped Image).
  Upstream alias-test completion still gates the eighteen-commit
  merge.
- 2026-07-17 palette layers + deterministic .random (worktree iteration
  23, two classes closed): (1) the handwritten foregroundStyle gateway
  was shadowing the generated arity-1/2/3 variants and dropping the
  secondary style — deleted per bridge policy, palette annotation
  icons paint, truck ratchets 1.400% -> 1.330% (pinned:
  paletteSymbolPaintsSecondaryStyleLayer). (2) socialfeed's residue
  was UNSEEDED randomness: SocialFeedContent's `-60 * .random(in:
  5...30)` rolled fresh post minutes every run on both sides, making
  the floor bounce and R4's AE=0 impossible. Fixed with the frozen-
  clock doctrine: both harness shims (twin sync.sh + FoodTruckCheck
  merge) now inject an env-gated `extension Double { static func
  random(in:) }` LCG shadow. Interpreter work to honor it faithfully:
  adoptNumericFactoryMarker promotes an Int-literal peer family to a
  program Double shadow (native contextual typing); host-extension
  static METHOD sets dispatch at INVOKE time with a label-subset
  shape check so the seeded `.random(in:using:)` spellings (qualified
  AND marker forms — OrderGenerator) resolve past the 1-arg shadow to
  the stdlib exactly like native overload resolution
  (hostExtensionStaticMethodDispatcher in MemberEvaluator;
  extensionFallback in resolveAnnotated). Socialfeed 0.472% -> 0.166%
  and BIT-DETERMINISTIC across runs; R3 board all ten green; R2
  ratchet now: donut-view 0, card-donuts 0, card-orders 0.168,
  socialfeed 0.166, donuts 0.437, orders 0.492, truck 1.330, content
  26.023 (documented twin-side artifact). Pins:
  interpretedStaticFuncShadowResolvesImplicitMemberCalls (shadow via
  qualified + implicit-in-context paths, Foundation-bit-exact Date
  round-trip, seeded spellings bypass). Upstream alias test STILL red
  on lane tip (runtime emits 13 intrinsics, test wants the checked-
  continuation pair) — merge queue still waits on Codex.
- 2026-07-17 forecast pillars paint their real style (worktree iteration
  24): gate i23 attributed — the suite's single failure IS the upstream
  alias test (runtime now emits the checked-continuation pair; Codex's
  test update still pending), concurrency parity shards recovered to
  green, and the corpus '677/680' headline is a shard double-assignment
  artifact (unique accounting: 678 pass / 2 fail — Planet + Mythic,
  both pre-existing; Planet reproduced at 03d8452, well before the
  dispatch changes). Iteration class: TruckWeatherCard's
  `.indigo.shadow(.drop(color:radius:x:))` — the marker chain was
  eagerly consumed by the handwritten VIEW shadow gateway (defaults
  radius 4, drop marker silently absorbed) before any style funnel saw
  it. Fixes: shared-coercion tier gains Coerce.shadowStyle
  (drop/inner factories with the SDK's per-factory default colors) and
  a `.shadow` chain case in Coerce.shapeStyle (+ zero-arg marker-call
  normalization); the shadow gateway becomes a typed HostModifier —
  a ShadowStyle marker argument routes to ShapeStyle.shadow on the
  raw receiver (native overload resolution: the view shadow requires
  radius:), everything else keeps the view path. Truck ratchets
  1.330% -> 1.257%, detail-truck floor follows, the last chart ⚠ on
  the truck row is gone. Pin: shadowStyleChainCoercesOnChartMarks.
  Next truck class staked: x-axis label elision (twin 3-hourly, interp
  6-hourly — DateBins thresholds correct, label width/collision
  suspected). Merge queue: still waiting on the upstream alias-test
  update; corpus floor accounting artifact worth a harness look.
- 2026-07-17 axis thresholds are real dates (worktree iteration 25):
  the weather chart's "label elision" was never elision — `DateBins(
  unit:.hour, by:3, range:).thresholds` absorbed under
  assumesCompiledImports (unknown host member -> ChainedImplicitCall),
  so AxisMarks silently fell back to `.automatic` and rendered the
  6-hourly default where native draws 3-hourly. A compiled native
  control probe at identical size proved native renders all 8 labels.
  Policy-shaped fix: BridgeGen now sweeps the Charts swiftinterface
  with DateBins as a receiver seed (NumberBins stays out — generic
  over Value), and generatedMemberResult gains an element-wise array
  boundary so SDK arrays enter the interpreter's array plane
  (`thresholds.count`/subscripts work like any interpreted array;
  Calendar.monthSymbols etc. now cross as real arrays too — pins
  updated to the better boundary). Truck ratchets 1.257% -> 1.082%,
  detail-truck follows, axis labels match native 3-hourly. Pins:
  GeneratedChartsMemberTests.dateBinsThresholdsMatchNative (interp
  thresholds == native count/first/last), DateBins receiver seed in
  the generated-property validation sweep. Remaining truck residue
  ~1.08%: corner brackets, small icon tints, caption strip. Merge
  queue unchanged (upstream alias test).
- 2026-07-17 merge-close gates + array-boundary refinement (worktree
  iteration 26, in flight): upstream alias test went GREEN after
  merging main 16bab0c — the queue's blocker is gone. Close-gate
  attempt 1: RED on task-priority-escalation fixture TIMEOUTS (load
  flake — passes isolated, exit 0; same suite green under load in the
  i23 gate). Attempt 2: tests green, live 5/5, corpus 678/680 AT
  FLOOR, but API parity 344/1: the generic [Element] overload of
  generatedMemberResult re-ranked overload resolution inside emitted
  closures — Sequence.dropLast() -> [Int] beat IndexPath's own
  dropLast() -> IndexPath on the exact-generic-parameter match,
  violating the host contract. Fix: the boxing choice moved to EMIT
  time — BridgeGen routes array-typed contracts (non-optional) to the
  DISTINCTLY NAMED generatedMemberArrayResult and everything else to
  the plain helper, so emitted member resolution is untouched.
  Parity board verified 345/0/0 after the fix. Third gate rolling.
- 2026-07-17 continuous card corners (worktree iteration 27, while the
  gated merge of 69b1b7e waits on Codex's commit window): the truck
  residue's dominant class was L-bracket diffs at every card corner —
  `.continuous` squircles rendering as circular arcs. Three gaps wired
  together: the RoundedRectangle constructor dropped `style:` (now a
  shared Coerce.roundedCornerStyle, also applied to the `.rect(...)`
  marker), `.containerShape` was inert (ShapeBox(insettable:) now
  captures a containerShapeApplier with the CONCRETE shape — the
  strokeBorderPainter doctrine — and the gateway applies it), and
  ContainerRelativeShape() had no constructor (now an insettable box).
  Truck ratchets 1.082% -> 0.986% — under 1% for the first time. R3
  all ten green; pin continuousCornersMatchNativeSquircles asserts
  pixel equality against a compiled native control. MERGE STATE: gate
  GREEN on 69b1b7e; `git merge` into main still refused while Codex's
  uncommitted continuation work sits on parity-cases.json and the two
  continuation test files; watcher armed, merging the gated commit
  the moment their next commit clears the overlap.
- 2026-07-17 THE QUEUE MERGED + pill rows center (worktree iterations
  26 close + 28): main 2adea17 = gated lane 69b1b7e (gate GREEN 1273s,
  all boards) — the multi-day merge queue is CLOSED; the overlap
  watcher fired the moment Codex committed and the merge went through
  clean. Iteration 28's class was the truck strip: FlowLayout pill
  rows placed LEADING because `alignment.horizontal.percent` absorbed
  end-to-end — `.center` under an `: Alignment` annotation never
  became a host value. Fixes, seam by seam: the Alignment family
  joins the host statics (GeometryBridge, via Coerce.alignment),
  Alignment gains horizontal/vertical accessors (hostObjectMember),
  the family maps in bridgeHostTypeName so app extensions dispatch on
  host values, areEqual gains a GENERIC opened-existential arm for
  Equatable-only hosts, and matchRuntimePattern adopts the subject's
  host type for marker patterns (the infix == path's adoption, now
  shared) so `case .leading:` matches real values. Truck plunges
  0.986% -> 0.113% (pill rows center across the card flows). Pins:
  alignmentPercentMatchesNativeSwitch (all three alignments through
  the app's exact extension switch),
  continuousCornersMatchNativeSquircles (iteration 27). 133-test core
  smoke + R3 all green; Mythic pre-existing failure unchanged. Next:
  gate + close for the corners/alignment pair; remaining truck 0.113%
  = three header icons.
- 2026-07-17 TRUCK AE=0 — pixel-perfect (worktree iteration 29): the
  header-icon class was the style funnel handing back the CONCRETE
  Color.secondary in STYLE positions — native `.secondary` there is
  the HIERARCHICAL style deriving from the current primary, so the
  card-header icons rendered gray instead of the accent-derived tint.
  Funnel reordered: primary/secondary/tertiary/quaternary resolve as
  HierarchicalShapeStyle BEFORE colorNamed, and the foregroundColor
  gateway keeps true Color semantics (colorLike first — the deprecated
  API takes a Color, not a style). Truck 0.113% -> 0.000% AND
  card-orders 0.168% -> 0.000% (its status plate was the same class).
  FOUR rows at AE=0: donut-view, card-donuts, card-orders, TRUCK —
  the mission's primary screen is pixel-identical to native, including
  through the R3 mutation (detail-truck 0.000%). Pin:
  hierarchicalSecondaryDerivesFromAccent (bitmap equality against a
  compiled native control of the exact header shape). Remaining board:
  socialfeed 0.166, donuts 0.437, orders 0.492, content (documented
  artifact). Gate rolling for the close.
- 2026-07-17 orders Details menus render (worktree iteration 30): the
  per-row Details Menu (ellipsis.circle, iconOnly) vanished because
  `.menuStyle` was an UNKNOWN modifier — protocol-typed style param,
  closed set per the buttonStyle doctrine (AGENTS.md's sanctioned
  handwritten tier) — and the unknown modifier absorbed the whole Menu
  subtree. Added the menuStyle switch (borderlessButton/button/
  automatic) beside buttonStyle/pickerStyle. Orders 0.492% -> 0.039%
  (22 row menus paint); detail-orders follows. Pin:
  borderlessMenuRendersIconOnlyLabel (bitmap equality vs a compiled
  native control of the exact OrdersTable spelling). Remaining orders
  residue 0.039% = the sorted-column header treatment (bold + sort
  chevron on "Status"). Board: FOUR rows at AE=0 + orders 0.039 +
  socialfeed 0.166 + donuts 0.437 + content (documented). Gate next.
- 2026-07-17 donuts caption shift staked, chrome pinned (worktree
  iteration 31): the donuts row's 0.437% is the two visible grid
  captions sitting ~3px HIGHER on the interpreter (whole caption block
  shifts as a unit; thumbnails pixel-match). Elimination probes — the
  caption VStack alone, the full NavigationLink cell with a frame'd
  stand-in child, and an erased-ZStack child — ALL match native
  pixel-exactly (pinned: donutCellChromeMatchesNative). The residual
  therefore lives in the real DonutView's interpreted layout inside
  its fixed frame (suspects: scaledToFit reply of interpreted
  resizable image layers, or the kit view's internal padding). Next
  iteration: probe with the actual FoodTruckKit DonutView merged
  (FTCHECK diag capture at cell scale vs a twin crop). i30 merged
  earlier this turn-set as b55d188 (menuStyle; orders 0.492 -> 0.039;
  fourth green close of the day, after waiting out lane-concurrency's
  gate lock — multi-lane gate contention now a normal mode).
- 2026-07-17 donuts class bisected to a one-command repro (worktree
  iteration 32): the caption divergence is +3px of extra gap between
  the (pixel-identical, 80pt) DonutView thumbnail and the title, plus
  a lighter flavor line, appearing ONLY in the real DonutGalleryGrid.
  Elimination matrix — ALL of these match native pixel-exactly: the
  caption VStack; the NavigationLink cell; erased-ZStack and
  GeometryReader stand-in children; LazyVGrid+ForEach(range) with the
  stand-in; the REAL DonutView cell via harness probes (donut-cell,
  AE=0); ForEach over the model array with the real DonutView
  (donut-foreach, AE=0); a `let` binding inside the builder (unit
  pin). The reproducing artifact: the new donut-grid harness probe —
  DonutGalleryGrid(prefix(4), width: 700) at 700x300 — AE 1273, only
  cell 1's caption. Ink measurements: title twin rows 177-185 vs
  interp 180-188 (same glyphs, same x extent 58-125); thumbnail ink
  identical (0-71). Remaining deltas to try next: NavigationLink
  (value: donut.id) with a UUID-backed ID, and the gallery's computed
  thumbnailSize/dynamicTypeSize reads composing with GridItem
  alignment .top. Repro: both harnesses now capture donut-cell,
  donut-foreach, donut-grid deterministically. Pins:
  donutCellChromeMatchesNative (now grid-wrapped),
  letBindingInBuilderAddsNoPhantomChild.
- 2026-07-17 donuts class: kit eliminated, harness-context isolated
  (worktree iteration 33): the mimic bisection removed NavigationLink
  (still AE 1279), the builder `let` (still 1279), and the ENTIRE kit
  DonutView — its body shape (GeometryReader > ZStack > aspectRatio(1,
  .fit) > compositingGroup > frame(max .infinity)) with a gray circle
  REPRODUCES BIGGER (AE 2111). Pure core. But the SAME tree as a unit
  test (InterpreterHost.render + NSHostingView both sides) passes at
  0 mismatches, with range AND Identifiable ForEach. Matrix: the
  divergence needs LazyVGrid x the FTCHECK/twin harness render path —
  while donut-cell (VStack, same harness) is AE 0. Prime suspect:
  sub-pixel column layout — the harness pair's available width/scale
  differs slightly, LazyVGrid's adaptive column math lands cells on
  different fractional offsets, and the caption renders with
  half-pixel-shifted, lighter-AA glyphs (+3px ink drop, flavor line
  under the ink threshold). Next: dump LazyVGrid cell origins via a
  GeometryReader overlay probe through BOTH harnesses, compare
  fractional x/y. Probes now in both harnesses: donut-mimic (kit-free
  repro, AE 2111), donut-cell/donut-foreach (AE 0 controls). Unit
  pins: gridCellCaptionGapMatchesNative (grid+Identifiable),
  letBindingInBuilderAddsNoPhantomChild, donutCellChromeMatchesNative.
- 2026-07-17 DONUTS AE=0 — GridItem alignment (worktree iteration 34):
  the origin-dump probe found it in one cycle — all cell x positions
  matched but interp cell 1's thumbnail frame sat at global y 91.825
  vs 88.5 (+3.3254px = half of its 6.65px height shortfall vs the
  row): the GridItem CONSTRUCTOR dropped `alignment:`, so the app's
  `.top` never reached SwiftUI and shorter cells CENTERED in their
  row. One-line shared-constructor fix (Coerce.alignment). donut-mimic
  0 -> the whole board: DONUTS 0.437% -> 0.000%, all four diag rows 0.
  FIVE app screens pixel-perfect (donut-view, card-donuts,
  card-orders, truck, donuts) + detail-donuts 0.000 through the R3
  mutation. Pin gridItemAlignmentTopPinsUnequalCells (height-unequal
  cells — equal heights masked the bug in every earlier probe). Board:
  orders 0.039, socialfeed 0.166, content (artifact). Gate next.
- 2026-07-17 SOCIALFEED AE=0 — env-styled stroke defaults (worktree
  iteration 35): the five avatar rings rendered near-black because
  `strokeBorder(lineWidth:)` with NO style argument defaulted to
  .primary in the gateway — native reads the ENVIRONMENT foreground
  style (the rings' .foregroundStyle(.tertiary) view modifier).
  ShapeBox(insettable:) gains a strokeBorderPlainPainter and both
  stroke gateways use the env-styled overloads when the style argument
  is absent. Socialfeed 0.166% -> 0.000%. SIX app screens
  pixel-perfect: donut-view, card-donuts, card-orders, truck, donuts,
  socialfeed (+ 4 diag rows at 0). Remaining: orders 0.039% (sorted
  Status header bold+chevron) and content (documented twin artifact).
  Pin: styleLessStrokeBorderReadsEnvironmentStyle. Gate next.
- 2026-07-17 ORDERS AE=0 — sortable Table headers (worktree iteration
  36): the Table gateway dropped the app's `sortOrder:` binding, so
  the sorted column's native header treatment (bold title + direction
  chevron) never rendered — the last 253 diff pixels on orders. The
  gateway now coerces the binding via Coerce.bindingBox and builds
  REAL sortable TableColumns: TableShimRow gains nonisolated c0-c5
  sort keys, every column is typed sortUsing: a shim KeyPathComparator,
  and a translated Binding maps the app's KeyPathComparatorBox array
  to the shim comparators (get -> header state) and back (set -> header
  clicks rewrite the app's box so it re-sorts; writes on keyPath-less
  columns are dropped — native marks those columns unsortable).
  Orders 0.039% -> 0.000%. SEVEN app screens pixel-perfect; only
  content (documented twin artifact) remains on the R2 board. R3 all
  ten scenarios 0.000% (detail-orders floor 0.039 -> 0.000).
  Pin: TableSortHeaderProbeTests.sortedColumnHeaderMatchesNative.
  Gate next.
- 2026-07-17 R4 OPENS — live sidebar navigation works (worktree iteration
  37): the R4 rung had NO live-window verification. New instrument:
  `Scripts/foodtruck-r4.sh` runs the demo with `--sweep`, drives the REAL
  interactive window (SweepDriver: AppKit row selection on the sidebar
  outline — synthesized NSEvent pairs cannot aim or complete list
  tracking without an accessibility grant) and verifies each navigation
  lands its panel by changed-pixel floors. First sweep found the class:
  the List gateway DROPPED `selection:` and NavigationLink rows had no
  tags — clicks highlighted rows but never wrote interpreted state; the
  detail froze. Fix (reusable): rows tag with their stringified identity,
  NavigationSelectionValues maps tags back to the ORIGINAL runtime
  values, and List(selection:) binds through Coerce.bindingBox — click →
  state write → detail re-render now proven live (orders swap: 422k
  pixels) and pinned headlessly. Boards unmoved: R2 unchanged (content
  byte-identical 26.137%, rest 0), R3 ten scenarios 0.000. NEXT CLASS
  (sweep finding): after an interactive re-render the sidebar comes back
  blank/light — appearance context is lost on the re-rendered subtree
  (sweep-2/3 captures in /tmp/foodtruck-r4). Twin-side note: content
  pump probes (runloop + contentViewController) cannot make the REAL
  NavigationSplitView paint headless — cacheDisplay misses window-server
  material layers; the honest content row needs an own-window
  ScreenCaptureKit/CGWindowList capture arc on BOTH sides.
  Pin: NavigationSelectionProbeTests.sidebarSelectionWritesInterpretedStateAndSwapsDetail.
  Gate next.
- 2026-07-17 R4 SWEEP HARDENED — "blank sidebar" was the instrument, not
  the app (worktree iteration 38): the i37 sweep's follow-up class
  dissolved under instrumentation. SWEEP-TREE hierarchy walks show a
  healthy 12-row sidebar outline (280x774, visible) after EVERY
  navigation, plus the 26-row orders table appearing/disappearing
  exactly on cue — the live interpreted app re-renders correctly; the
  CALayer.render offscreen rasterization simply cannot see NSTableViews
  re-created after initial compositing (CATransaction.flush does not
  help; in-process AX traversal returns no children for hosted SwiftUI).
  The sweep now verdicts on hierarchy markers + repaint magnitude
  (orders: sidebar + >=20-row table + >100k changed; donuts: orders
  table gone + >100k; truck: >5k) — SWEEP GREEN, diagnostics 0. Pin
  strengthened: NavigationSelectionProbeTests also asserts the sidebar
  survives the selection re-render (sidebar-ink > 200; headless capture
  is not layer-partial). GATE NOTE: main is RED at 575d199 with
  "parallel test workers failed" (lane-concurrency regression, three
  reproductions, attribution in claims) — i37/i38 tips are gate-blocked
  until main heals; MERGE-READY will cover both.
- 2026-07-17 CITIES RENDER LIVE — full-sidebar R4 sweep, one process per
  panel (worktree iteration 39): extending the sweep to all nine sidebar
  navigations found the class chain in CityView — no bridge for
  LinearGradient(stops:startPoint:endPoint:) and no builder-closure
  gateway for AsyncImage(url:content:placeholder:); both city rows
  failed hard (no repaint, hard diagnostics). Fixes (policy-compliant):
  Coerce.gradientStop/gradientStops shared coercions (accepting
  .init(color:location:) markers) + a stops: arm on the existing
  LinearGradient gateway; a handwritten AsyncImage gateway (sanctioned
  builder-closure tier) that defers interpreted content/placeholder
  closures to PHASE time with the loaded image crossing as an ImageBox.
  Sweep architecture: one PROCESS per panel (offscreen layer
  rasterization is only trustworthy for the first re-render after
  compositing), fresh-diagnostic gating per step. R4 board: 7/9 GREEN —
  orders 422k, socialfeed 294k, donuts 810k, donuteditor 585k,
  cupertino/london 305k repainted pixels, truck back-nav. Remaining 2:
  saleshistory (43x "mark foregroundStyle shape not bridged") and
  topfive (8x "AxisValueLabel format shape not bridged") — the Charts
  bridge classes, next. R2 board intact (orders re-verified AE=0
  fresh-vs-fresh; the 110px scare was a stale twin PNG's font-AA drift).
  Pins: GradientStopsAndAsyncImageProbeTests (stops gradient AE=0,
  AsyncImage placeholder AE=0). Gate still blocked by main-red
  (lane-concurrency parallel-worker regression).
- 2026-07-17 SALES HISTORY RENDERS LIVE — categorical mark styling
  (worktree iteration 40): the 43-diagnostic class was the CATEGORICAL
  series forms — `.foregroundStyle(by: .value("Location", name))`,
  `.symbol(by: .value(...))`, and `.lineStyle(StrokeStyle(lineWidth:))`
  had no mark-member arms; every mark fell to the default style. The by:
  forms route through the existing shared plottable carrier
  (PlottableSpec) and lineStyle takes the host StrokeStyle — series
  colors, per-series point symbols, and the legend are the framework's
  own. Live capture shows the full panel: three per-city series in
  distinct colors with circle/square/triangle symbols, legend, cardinal
  smoothing, timeframe picker. R4 board 8/9 GREEN (saleshistory 193k
  repainted, 0 diagnostics); only topfive remains (8x AxisValueLabel
  format — next). R2 spot-check: orders AE=0 fresh-vs-fresh (stale-PNG
  font-AA drift is inter-session; the r2 script is immune).
  Pin: InterpretedChartTests.seriesColoredMarksMatchNative (AE=0 vs
  native). Gate still blocked by main-red; steward has made the
  worker-isolation fix lane-concurrency's drop-everything priority.
- 2026-07-17 R4 SWEEP BOARD FULLY GREEN — top-five axis labels (worktree
  iteration 41): the last sweep class chained three gaps in
  TopDonutSalesChart's axes — AxisValueLabel(format:
  IntegerFormatStyle<Int>()) reached the bridge as an inert stub
  (thrown), the AxisValueLabel { } content-closure form rendered empty
  labels, and the closure content's .frame(idealWidth: 80) had no
  gateway arm. Fixes: the integer look bridges through a fraction-0
  FloatingPointFormatStyle<Double> (bridged plottables are
  Double-backed — identical label strings, pixel-verified); closure
  labels evaluate their interpreted builders through the standard
  builder path; the frame gateway gains idealWidth/idealHeight in its
  flexible arm. Top-five renders live: gradient bars, value
  annotations, integer y-axis, per-donut x labels. ALL NINE sidebar
  navigations land with 0 diagnostics — the R4 interactive sidebar
  sweep is green end to end. Residue noted: DonutView thumbnails
  inside axis labels look absent in the live capture (no diagnostics;
  future pixel-row work). All 23 pins across 8 suites pass; fresh
  R2 board intact (orders 0.000 fresh-vs-fresh). Pin:
  InterpretedChartTests.integerAxisAndClosureLabelsMatchNative (AE=0).
  Gate still blocked by main-red.
- 2026-07-17 LIVE MUTATION LANDS — enum-tagged Picker selections
  (worktree iteration 42): the sweep gained a MUTATION phase — after
  landing saleshistory/topfive it drives the Timeframe segmented
  control through the genuine AppKit action path and requires a chart
  repaint. First run exposed the class: the Picker bound through a
  plain string binding, so the segment write stored the tag STRING in
  enum-typed state and the app's `switch timeframe` stopped matching
  ("switch was not exhaustive for Timeframe.month"). Fix (the i37
  registry doctrine, now shared): `.tag(...)` registers its ORIGINAL
  runtime value in NavigationSelectionValues and Picker binds through
  the new Coerce.selectionBinding — get reads the state's stringified
  identity, set writes the registered original back. The Month
  mutation now renders perfectly (segment highlighted, totals 7,983 →
  17,351 donuts, a month of points per series, y-axis rescaled, 0
  diagnostics). Headless note: SwiftUI's SegmentedControlCoordinator
  accepts the segment but only writes its binding inside a RUNNING
  app, so the end-to-end stays covered by the live r4 mutate step; the
  pin covers the two mechanisms directly (registry keys are
  type-prefixed stringified identities, e.g. "Timeframe.month"). All
  19 neighbor pins pass; R2/R3 within floors (orders 0.017% = the
  known ±1/255 AA flicker, floor 0.039). Pin:
  PickerSelectionProbeTests. Gate still blocked by main-red.
- 2026-07-17 DONUT EDITOR CLASS CHAIN — EdgeInsets markers + compound
  generic specialization (worktree iteration 43): the sweep's planned
  donut-editor rename mutation found the panel renders BLANK. New
  permanent diag row (diag-donuteditor) reproduced headlessly and
  attributed the chain: (1) `.listRowInsets(.init())` — the shared
  .edgeInsets coercion could not resolve bare `.init(...)` markers
  against the expected type; fixed in GeneratedSupport (benefits every
  EdgeInsets-taking generated modifier). (2) `Gauge(value:in:_:)` — NO
  range forms were ever emitted: ClosedRange<V> with
  V: BinaryFloatingPoint hit two generator gaps. BridgeGen now
  specializes compound types over constrained generics
  (ClosedRange<V> -> ClosedRange<Double>, new doubleRange ParamTag +
  coercion) and the <shared generic> rule allows repeats that agree on
  ONE concrete type (value: V + in: ClosedRange<V> both Double).
  Regenerated: 253 init variants (+22 new call shapes across the SDK).
  Probes added (ObservableBindingProbeTests): $model.property
  projection, struct-binding editors, HSplitView, harness control —
  all render. RESIDUE: diag-donuteditor now renders EMPTY with ZERO
  diagnostics (the silent-blank moved past bridging into layout/eval —
  next iteration's hunt). 55 tests across 7 suites pass; R2 intact.
  Gate still blocked by main-red.
- 2026-07-17 SILENT-BLANK DOCTRINE + formStyle (worktree iteration 44):
  the donut-editor hunt isolated the biggest silent absorber —
  `.formStyle(.grouped)` was COMPLETELY unbridged and the unknown
  modifier swallowed the whole Form with no diagnostic (unit bisect:
  form ink 171 -> 0 under the modifier). formStyle joins the sanctioned
  closed-set style switch tier (grouped/columns/automatic); grouped
  forms render with their section chrome (ink 665). Doctrine
  improvement: when a ChainedImplicitCall absorb at the anyView
  boundary WRAPS a real view (walking nested chains to the root base),
  it now records "unbridged view modifier chain '...' absorbed a
  rendered view; renders EMPTY" — the class of bisect-hunts formStyle
  cost becomes self-attributing. Bisection rows added
  (diag-editorviewer/editorsplit probes, unit form-bisect probe).
  RESIDUE: diag-donuteditor STILL renders empty with zero diagnostics
  even past the absorb tracer — the blank draws through a "successful"
  view; next iteration adds the TWIN-side editor row (native may
  equally render the toolbar/HSplitView shell empty headless, which
  would re-scope the class to live-only). model.newDonut reads
  correctly ("NAME=New Donut" probe); the empty viewer pane is
  asset-empty on BOTH sides by doctrine. 30 tests across 5 suites
  pass; R2/R3 within floors. Gate still blocked by main-red.
- 2026-07-17 EDITOR BLANK NARROWED TO A MINIMAL REPRO (worktree
  iteration 45): the twin-side diag-donuteditor row now exists — NATIVE
  renders the editor form fully headless (name field, six flavor
  gauges with values, ingredient pickers; left viewer pane asset-empty
  by doctrine), so the interp blank is a REAL class, not a live-only
  artifact. Elimination matrix (all probes kept): editorContent in a
  grouped Form standalone RENDERS through the interpreter (gauges from
  i43's range forms working); donutViewer renders (asset-empty);
  real-viewer + simple-right splits render; simple-left + REAL
  form/editorContent inside the split = BLANK RIGHT PANE. A saturated
  structural mimic (ZStack + #if-in-builder + #if-in-modifier-chain +
  member composition + toolbar/ToolbarTitleMenu + navigationTitle +
  formStyle(.grouped) + the exact frame chain) renders 1338 ink under
  macOS platform — the app's SHAPE is fine; the delta is the REAL
  sectioned editorContent volume inside the grouped (List-backed) Form
  under HSplitView pane sizing. Next: bisect editorContent's sections
  inside the split (suspect: NSTableView-backed grouped form collapsing
  in the split pane headless while native negotiates minWidth).
  Probes: memberComposedSplitBodyRenders (macOS-forced),
  editorSplitShapeBisect, form-bisect, wrapper-bisect. Gate still
  blocked by main-red.
- 2026-07-17 THE EDITOR RENDERS — generatedBuilder pane collapse
  (worktree iteration 46): the silent-blank root cause, found by an
  elimination cascade (sections bisect -> pure shape blanks under the
  probe env -> pure shape RENDERS in the unit harness -> merged-source
  bisect renders -> the capture showed "LEFT" centered = ONE-pane
  split): `generatedBuilder` wrapped multi-child builder content in a
  VSTACK, so every multi-child GENERATED container collapsed its
  children into one cell — HSplitView { viewer; form } became a
  one-pane split (handwritten gateways were immune; they fan out with
  indexed ForEach INSIDE the real container). Fix: generatedBuilder
  returns the neutral indexed fan-out; the receiving container sees its
  children as children. The donut editor NOW RENDERS through the
  interpreter: split divider, name field, six flavor gauges,
  ingredient pickers — diag-donuteditor 100%-blank -> 10.56% vs twin
  (residues: section-header styling, optional-tag Glaze/Topping
  labels, divider position). Probe adjustments: struct-binding probe
  canvas 700x300 + constrained form pane (the old pass was an
  artifact of the collapse; an UNCONSTRAINED pane collapsing a
  headless split is a known edge, noted). Corpus backstop 678/680
  (unchanged); full R2 board all-zero except content artifact; R3
  green; all pin suites pass. Scratch bisect harness kept
  (MergeBisectScratchTests) pending removal next close. Gate still
  blocked by main-red.
- 2026-07-17 OPTIONAL-CAST TAGS — Glaze/Topping pickers complete
  (worktree iteration 47): the editor's biggest remaining functional
  residue was `.tag(glaze as Donut.Glaze?)` / `.tag(nil as
  Donut.Glaze?)` — optional-cast tag identities never matched the
  non-optional stored state, so Glaze/Topping pickers showed no
  selected label. Fix: NavigationSelectionValues.identity(_:) — the
  ONE identity both `.tag(...)` and every selection binding use:
  optional layers unwrap (nil -> "nil"), then stringValue/stringified.
  Applied to the tag gateway, Picker selectionBinding, List selection,
  and NavigationLink rows. Editor form now shows Glaze "Chocolate
  Glaze" / Topping "Sprinkles" exactly like native. BOARD NOTE:
  content 26.137% -> 26.778% — the sidebar List now correctly
  HIGHLIGHTS the selected row (the identity get matches row tags), a
  fidelity IMPROVEMENT measured against the documented-broken twin
  content row (headless NavigationSplitView sidebar blank); the
  sanctioned detail-truck proxy remains 0.000. Remaining editor class:
  Sections flatten into ONE grouped box with centered inline headers
  vs native's separate grouped boxes with outside headers (the
  Section-in-grouped-Form structure) — next. 12 selection pins pass;
  R2 main rows 0.000; R3 green. Gate still blocked by main-red
  (steward's third escalation to lane-concurrency pending).
