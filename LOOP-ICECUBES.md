# LOOP — IceCubes: run a real networked SwiftUI app pixel- and function-identical to native

Second primary target (user directive 2026-07-19), after FoodTruck was proven
pixel- and function-identical. The FoodTruck approach worked; this applies the
same discipline to a **networked, multi-package** app — the axis FoodTruck did
not exercise (it was local sample data with a frozen clock).

## Mission

The interpreted IceCubes app (`External/oss/IceCubesApp`) must run **identical
to the same app compiled natively with Xcode on macOS: pixel-perfect on every
screen, and functional.** A public Mastodon timeline shows real author display
names, status text (HTML→attributed), boosts, and media; scroll appends the
next page; tapping a status pushes its detail with the real content; tab/column
switches land the right screen — exactly as compiled.

This target OUTRANKS every other queue. FoodTruck, ExpenseTracker, ProjectCheck,
LiveCheck, and the concurrency parity boards become **regression backstops**:
they must never regress, but they no longer set direction.

## Standing machinery (unchanged — do not relitigate)

- **Bridge rule** (`AGENTS.md`, binding): ordinary SwiftUI/SDK gaps are fixed in
  BridgeGen, shared coercions, or reusable generated adapters — never a per-API,
  per-app, or per-fixture special case. Only interface-inexpressible SwiftUI
  magic may be handwritten, under the allowlist rule.
- **Iteration algorithm** (`LOOP.md`): health check → measure → pick the single
  biggest failure class → classify & fix properly → add regression coverage →
  verify cheaply (one closing gate) → commit (class named) → log. Commit SMALL
  and OFTEN along the way — see the binding cadence section below.
- **Worktree protocol v2** (`LOOP.md`): work in `.claude/worktrees/lane-foodtruck-run`;
  merge main at iteration start; gate clean-detached inside the worktree; post
  `MERGE-READY <sha> <gate summary>` in `.claude/claims.md` for the steward to
  serialize into main — with the self-merge fallback in the cadence section
  below so gated work never queues unlanded. Never build or edit in the main
  checkout.
- **Native-baseline rule**: an interpreted failure is an interpreter bug ONLY if
  the same expectation holds under the real compiler / real recorded bytes.
  Expectations are captured from the twin and the fixtures, never hand-written.

## Commit and landing cadence (binding — user directive 2026-07-19)

- **Commit small, commit often.** Every green step is a commit: a distilled
  repro turning green, a rung flipping, a capability slice passing its focused
  tests, a twin capture landing. Never accumulate a multi-thousand-line
  uncommitted working tree — an interrupted session must lose minutes of work,
  not a day. Uncommitted state is invisible to the steward, unrecoverable on a
  crash, and un-reviewable in the claims channel.
- **Push the lane branch on every commit.** The remote ref
  `origin/worktree-lane-foodtruck-run` went stale at the 2026-07-18 i80 tip
  because plain post-commit pushes bounce non-fast-forward; heal it once with
  `git push --force-with-lease origin worktree-lane-foodtruck-run` and keep
  pushing on each commit. The remote branch is backup and visibility — never an
  integration source; merges into main come only from local gated tips.
- **Land on main every iteration.** An iteration is not closed until its gated
  tip is ON main and pushed. The full loop: absorb main at iteration start →
  work in small commits → clean-detached full gate at close → post
  `MERGE-READY <sha> <gate summary>` in `.claude/claims.md` → if no steward
  `MERGE-LOCK` responds within ~15 minutes (and no unreleased `MERGE-LOCK` from
  anyone else is pending), self-merge the EXACT gated sha into main
  (`--ff-only` when main has not moved, else `--no-ff` with the standard
  "Merge lane-foodtruck-run (gated <sha>, clean full-corpus): <class>" subject),
  push main, and post `MERGE-DONE`. Never merge anything that is not the exact
  gated sha; never let gated work queue behind an absent steward; main stays
  green — revert-first if a landing turns it red.

## Gate regressions CONTINUOUSLY, not just at iteration close (user directive 2026-07-20)

"Gate at iteration close" is worthless when the iteration never closes. The
2026-07-20 incident proves it: a `Date(timeIntervalSince1970:)` regression (the
lane's init-matching work started requiring init arguments to match STORED
PROPERTIES, which breaks SDK labeled inits like `Date`) sat undetected through
**67 unlanded commits / 12.5h**, discovered only when the steward finally ran a
full gate — by then it blocked the entire batch from landing. A long climb MUST
verify regressions along the way:

- **Run the fast suite FREQUENTLY — never more than ~5 commits or ~30 minutes
  apart.** `swift test` (prebuilt, seconds-to-minutes) over the backstop boards
  (concurrency parity, HostSignature, corpus micro-programs) after every
  green-step batch. This is `LOOP.md` step 1's health check run CONTINUOUSLY, not
  once at iteration start. The suite is cheap; a buried regression is not.
- **A RED backstop STOPS feature work.** If any backstop board regresses, fix it
  before the next feature commit. A regression caught within 2–3 commits is a
  one-line bisect; buried in dozens it blocks everything and costs a full gate to
  even locate.
- **The clean-detached FULL gate at close is the LAST check, never the FIRST.**
  If the close gate is the first time the suite ran this iteration, the iteration
  was already too long.
- **Cap iteration size by TIME, not just by rung.** If you cannot land a
  gate-green batch within ~1–2 hours, the iteration is too big: land the
  gate-green foundational slice you already have (additive capability is landable
  before the rung moves) and continue. Never accumulate a multi-hour unlanded,
  un-gated pile — it hides regressions and blocks the batch.

## The instrument: `swift run IceCubesCheck` — bootstrap it first

Per-screen rung ladder, strictly-improving total-rungs score, same discipline as
FoodTruckCheck (deterministic, <3 min, per-screen timeout):

- **R0 shell**: the local `Packages/*/Sources` + App sources merge and interpret;
  the `@main IceCubesApp` scene renders through the app-shell path. Its own
  environment objects (Client, Theme, CurrentAccount/UserPreferences, RouterPath)
  MUST seed the tree — never synthesized stand-ins.
- **R1 render**: the timeline deep-renders with the replay fixture's real data
  visible in the tree (author names, status text, boost attribution, media
  attachment placeholders), plus a status-detail screen and an account-header
  screen.
- **R2 pixel**: per-screen image diff against the NATIVE TWIN (below), AE=0 the
  end state; per-screen thresholds ratchet down, never up.
- **R3 function**: scripted interactions — scroll appends the next fixture page,
  tapping row N pushes its status detail showing that status's content, tab/
  column switch lands the right screen — exactly as compiled.
- **R4 identical**: all screens AE=0 AND the R3 checklist green.

## The native twin + FROZEN NETWORK (the only source of expectations)

The twin harness compiles the Timeline view + its package dependencies (Models,
NetworkClient, StatusKit, DesignSystem, Env) into a scratch macOS executable
(the `Examples/FoodTruckNativeTwin` pattern) that runs with `NetworkPolicy.replay`
serving **RECORDED real Mastodon API responses** from `Fixtures/` and
ImageRenderer-captures each screen headlessly at a FIXED size/appearance.

BOTH the twin and the interpreter run the **same replay fixtures** → deterministic
pixels. This extends FoodTruck's frozen *clock* to a frozen *network*. Seed
fixture already present from LiveCheck: `mastodon-public-timeline`; capture more
public endpoints (instance info, a status context/detail, an account) by curl,
**once**, and never hand-edit them — they are the network's native baseline.
Expectations (pixels, strings, counts) are captured from the twin, never written.

## Determinism rules (both sides, or the diff is noise)

- **Frozen network**: replay serves recorded bytes; every media/image request
  serves a DETERMINISTIC placeholder PNG (a generated solid image). No live
  network, no randomness.
- **Frozen clock**: relative timestamps ("2h ago") pin to a fixed injected date.
- **Public/unauthenticated timeline is the fixture** — never invent data, never
  patch the app to pass; every gap is interpreter/gateway work.
- App sources are READ-ONLY. Assets (DesignSystem theming, SF Symbols, fonts)
  resolve through the real machinery; a missing-asset render is a failure class,
  not a skip.

## Scope quarantine (out of the metric, but must still RENDER)

- **OAuth / Sign-in with a Mastodon instance is OUT** — public/unauthenticated
  data only (the LiveCheck auth quarantine). The signed-out / instance-picker /
  onboarding screens must still render pixel-identically in their signed-out state.
- **Push notifications and streaming timelines are OUT** — flaky-by-design.
- **Extension targets are OUT** — Share, Widgets, AppIntents, Notifications,
  ActionExtension are extension processes, not the app window.

## Capability gaps this target will surface (priority queue, biggest first)

Build through BridgeGen / core when the histogram demands, largest failure class
first. Expected walls, in rough order:

1. **The Client-actor networking path** — the timeline fetch runs through an
   `actor Client` with async `get`/`fetch` methods. This was the historical
   LiveCheck wall ("the timeline fetch dies in the Client-actor path"). It is now
   MUCH more passable: the concurrency lane landed M5 actor support + M9 physical
   parallelism, so actor methods execute. This target is the proof that work pays
   off end-to-end.
2. **Mastodon Codable decoding** — `Status`/`Account`/`MediaAttachment` custom
   `init(from:)` bodies must run (a documented LiveCheck divergence: only
   synthesized memberwise decode works today). Real `init(from:)` synthesis is
   the class to burn down.
3. **HTML → attributed text** — status content is HTML; the twin renders it a
   specific way. Match it.
4. **AsyncImage / media loading** — resolves to deterministic placeholder PNGs
   under replay.
5. **Infinite-scroll pagination** — `@Published` timeline state + fetch-next-page
   on scroll (M3 interactive-persistence shape).
6. **The multi-package merge** — the interpreter merges App + all local
   `Packages/*/Sources` cleanly; DesignSystem theming and Env environment-object
   injection flow into the tree.

## Repro doctrine — distill a minimal reproduction for every failure class

IceCubes is huge (13 packages, networked, HTML). **NEVER debug a failure class
against the full app.** When `IceCubesCheck` surfaces a class, distill it to the
*smallest self-contained reproduction* that isolates it, demonstrated **RED
before the fix**, committed as a permanent regression pin — runnable in seconds,
named after the class, citing the IceCubes file/type that surfaced it. This is
what made FoodTruck tractable (TwinRetitleApp, the donut-grid probe,
menu-link-probe, the blank-grouped-form repro, a bisect instrument). Tier by
class kind (this is `LOOP.md` step 5, sharpened for a networked app):

- **Core-semantics / language class** (Client-actor fetch, Codable decode, async
  pagination) → a unit test whose distilled Swift snippet IS the repro,
  expectation **native-verified** (compile the snippet with real `swiftc`, copy
  the exact output). E.g. a 20-line `actor Client { func get<T: Decodable>(_:)
  async throws -> T }` + a 3-field `Decodable` — not the real `NetworkClient`
  package.
- **Render / app-shell / framework-interplay class** → a single-file corpus
  micro-program under `Tests/SwiftUIBridgeTests/Corpus/` (deep-render +
  assertions, runs with the suite). E.g. one `StatusRowView`-shaped view over a
  hand-built `Status` model — not the `StatusKit` package.
- **Native-vs-interpreted PIXEL divergence** → a **micro-twin**: a ≤~50-line view
  distilled from the screen PLUS a minimal replay fixture (one recorded status
  object, not the full 40-item timeline), captured natively via the twin harness
  and pinned at AE=0. Reuse the MicroTwin harness the FoodTruck lane bootstrapped.
- **Networked class** → always pair the distilled decoder/view with a hand-trimmed
  **minimal fixture** (real recorded bytes, trimmed to just the failing field) so
  the repro stays fast and deterministic — never the whole timeline response.

Repros contain only distilled code — no IceCubes package imports, no copied app
files — and the interpreter fix still obeys `AGENTS.md` (a general mechanism,
never an app-specific special case). **New capability without its distilled repro
doesn't count.**

## North-star metric + backstops

- **North star**: `IceCubesCheck` total rungs, strictly improving.
- **Backstops (never regress)**: FoodTruckCheck total rungs, ExpenseTracker
  pixel parity, `ProjectCheck` pass count, `LiveCheck` board, concurrency parity
  zero-tail. The closing gate runs all boards at full strength; a receipt is only
  `MERGE-READY` when its own metric strictly improved and no backstop regressed.

## First iteration

Bootstrap `IceCubesCheck` (R0 shell + R1 render rungs) and the IceCubes native
twin skeleton (Timeline view + Models/NetworkClient/StatusKit/DesignSystem/Env
deps → scratch executable capturing the public-timeline screen under
`NetworkPolicy.replay` with `mastodon-public-timeline`). Record the R0/R1
baseline and the first R2 AE against the twin. Then climb the ladder, one biggest
failure class per iteration, each closed with its distilled repro.
