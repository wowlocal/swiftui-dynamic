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

**Worktree protocol (Codex owns the MAIN tree for concurrency work —
never build, test, or edit in the main checkout):**
- The loop lane lives in `.claude/worktrees/lane-foodtruck-run`, branch
  `worktree-lane-foodtruck-run`.
- Iteration START: `git merge main` inside the worktree (absorb Codex's
  committed progress; their UNCOMMITTED main-tree files are theirs alone).
- All work, builds, captures, and `Scripts/gate.sh` run INSIDE the worktree.
- Iteration CLOSE: commit on the lane branch (never `.claude/*.local.md`),
  then merge the lane branch into main: `git -C <main-checkout> merge
  --no-ff worktree-lane-foodtruck-run`. Git refuses if the merge would
  touch one of Codex's dirty files — in that case leave the branch
  unmerged, note it in `.claude/claims.md`, and continue; NEVER stash,
  checkout, or commit Codex's in-flight files to force a merge through.
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
5. **Add regression coverage**: a corpus program under
   `Tests/SwiftUIBridgeTests/Corpus/` or a unit test that captures the fixed
   class. New capability without a test doesn't count.
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
