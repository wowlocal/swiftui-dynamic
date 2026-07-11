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
keep short; these never count against the metric. Encoded mechanically in
TestCheck's `TestHarness.upstreamBrokenClasses` — entries report as
SKIPPED, keeping the histogram a true priority queue.)

- FreeChat.PromptTemplateTests (all 10): references Llama2Template/
  VicunaTemplate/ChatMLTemplate/AlpacaTemplate — types that exist NOWHERE
  in the checkout or its four package dependencies (markdown-ui,
  KeyboardShortcuts, Splash, EventSource). The test target cannot compile
  natively. Verified 2026-07-11 (iter 211).

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
6. **Verify — scaled to blast radius** (methodology audit 2026-07-10;
   verification had grown to ~2.6 full-corpus runs per iteration and
   10× iteration cost):
   - OPENING sweep: SKIP it when `.claude/last-verify.txt` matches the
     current HEAD and the tree is clean — the previous iteration's
     closing verify already proved that state. Confirm only the queued
     target (`--project X` / `--scenario Y` / `--filter Z`).
   - MID-iteration: targeted probes ONLY (single project, single
     scenario, single test filter). Never a full sweep to answer a
     narrow question.
   - CLOSING gate, exactly ONCE: full `swift test` green AND ProjectCheck
     pass count strictly improved (or same count with the top class
     eliminated). The cache write is PART OF the gate, not a follow-up —
     after the commit in step 7, run LITERALLY:
     `git rev-parse HEAD > .claude/last-verify.txt`
     (two iterations have skipped this since 2026-07-11; the opening-sweep
     skip has never engaged, which costs a full corpus run EVERY
     iteration. If you end an iteration without writing it, say why in
     the log entry.)
   - Long commands: give explicit timeouts (never a chained
     build+suite+corpus under the default 10m — it WILL be killed);
     build once, then invoke prebuilt binaries (.build/debug/…).
   - Bisect discipline: ONE patch at a time, re-probe after each; if
     the metric regresses, REVERT before continuing (never patch on a
     broken baseline). Cap a bisect at ~10 rebuild cycles per
     iteration — past that, commit a WIP checkpoint of findings to the
     log and finish next iteration.
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

## Instruments

- `swift run ParityCheck` — API parity vs a compiled twin (generated
  members surface; regenerate probes with `swift run BridgeGen --emit
  --probes`). Current: 292 match / 0 diverge / 0 error / 17 unstable of 309
  (ratchet: never regress 292 — the full stable surface matches; 17 types
  swept). Growing the surface is the cheap move now: add a type to
  BridgeGen's memberTypes + a seed to parityPrelude/seedReceivers,
  regenerate, and every finding ParityCheck reports is a real interpreter
  gap (missing constructor, alias mismatch — Decimal's runtime name is
  NSDecimal, see GeneratedMembers.keyTypeName). Property/method name
  collisions (url.query vs query(percentEncoded:)) dispatch call-aware:
  a non-callable or nil property at a call site retries the methods-only
  generated table (registry hostMethod hook).
- `INTERP_ABSORB_CENSUS=1 swift run ProjectCheck --all` — corpus-wide
  absorbed-member demand curve.

## Field notes (iteration-invariant facts — keep to ~12 lines)

- ProjectCheck --all ≈ 2 min prebuilt; swift test ≈ 1-4 s execution,
  build dominates. Time new harnesses once, note it here.
- macOS/BSD sed lacks `addr,+N` — use `awk NR` or `grep -A`.
- SwiftPM stale artifacts after public-signature changes → `touch`
  changed sources and rebuild before trusting exit-138 crashes.
- Write large patch payloads to files, not inline heredocs per turn —
  context overflow ("Prompt is too long") killed iteration 140's tail.
- After EVERY commit: `git rev-parse HEAD > .claude/last-verify.txt` —
  this is what arms step 6's opening-sweep skip. Still unwritten as of
  2026-07-11; every iteration is paying a ~2 min corpus sweep for it.
- Failed `Edit` on unread files: Read the region first or use the
  python patcher directly — dead tool calls otherwise.

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
