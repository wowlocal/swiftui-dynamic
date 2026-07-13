# LOOP-LIVE — the Live/M2 lane

You are one of TWO parallel ralph loops plus a steering integrator
(штурман). This lane owns the LIVE-DATA board. The core/M1 lane (LOOP.md)
owns TestCheck and interpreter semantics. Read this file and execute
exactly ONE iteration per prompt.

## Mission

Every LiveCheck scenario green, and the board GROWING: real GitHub apps'
launch flows run interpreted — scene → lifecycle → state → network/
resources → decode → observable state → re-render → REAL content in the
tree — exactly as compiled. `swift run LiveCheck` is your metric.

## Territory

- YOURS: `Sources/SwiftUIBridge/`, `Sources/LiveCheck/`, `Fixtures/`,
  `External/deps/`, LiveCheck-facing tests in `Tests/SwiftUIBridgeTests/`.
- SHARED HOT ZONE (minimize, always claim first): `Sources/SwiftInterpreter/`
  — the core/M1 lane lives here. Prefer gateway-side fixes; touch the core
  only when the wall is genuinely a language/semantics gap, keep the hunk
  surgical, and expect the integrator to reconcile.
- NEVER: merge to main, edit `main`'s tree, or rewrite others' queue items.

## Claims — FIRST action of every iteration

The lock is a FILE outside git (instant, no merge latency):
`/Users/mike/src/tries/2026-07-08-swiftui-dynamic/.claude/claims.md`

1. Read it. A claim younger than ~2 hours by another agent = that item is
   TAKEN — pick a different wall.
2. Append one line BEFORE you start work:
   `<UTC ISO time> lane-live CLAIM <one-line class description>`
3. Append `<UTC ISO time> lane-live DONE <same description>` when your
   commit lands.

## The iteration

1. **Health**: `swift test` in THIS worktree. Red → fix that first.
2. **Measure**: `swift run LiveCheck`. The board's 🟡 scenario diagnostics
   (lifecycle errors, `network:` log, `absorbed:` histogram,
   LIVECHECK_TRACE=1 string dump) name the walls; LOOP.md's queue ledger
   (items 3c etc.) carries the current rung's analysis — read it.
3. **Pick ONE wall** — the outermost blocker of the top 🟡 scenario, or a
   new-scenario seed when the board is all green (corpus apps of a NEW
   genre: different async stack, different persistence, different
   architecture; fixtures are REAL recorded bytes or the repo's own
   committed resources, never hand-written).
4. **Claim it** (see above).
5. **Fix properly** — no per-scenario hacks. A missing ordinary SwiftUI/SDK
   API is fixed in BridgeGen, shared coercions, or a reusable generated
   adapter, never with a new API-name gateway special case. The only exception
   is the narrow interface-inexpressible SwiftUI magic defined in `AGENTS.md`.
   The absorbed-environment doctrine holds: gateways absorb rather than die;
   native-baseline rule: expectations encode what COMPILED SwiftUI does. New
   capability without a regression test doesn't count.
6. **Verify (lane gate, scaled to blast radius)**: mid-iteration use
   targeted probes ONLY (`--scenario X`, `--filter Y`); the full lane
   gate runs exactly ONCE at close: `swift test` green AND
   `swift run LiveCheck` — every previously-green scenario STAYS green,
   your wall's scenario strictly improved. Spot-check
   `swift run ProjectCheck --limit 25` when you touched anything outside
   SwiftUIBridge/LiveCheck. Long commands get explicit timeouts; build
   once and reuse prebuilt binaries. One patch at a time in bisects —
   revert on metric regression, never stack onto a broken baseline.
   The integrator runs the FULL board + corpus before main — not your
   job. On success write `.claude/last-verify-live.txt` (`<sha> <board>
   <time>`) and SKIP your next opening measure if HEAD is unchanged.
7. **Commit to THIS branch** with the wall named, the ledger updated
   (LOOP.md queue item progress notes), and the attribution trailer:
   `Model: <model> (<id>), effort=<effort>` then
   `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
8. Append the DONE line to the claims file.

## Rules (inherited from LOOP.md, binding)

- Small commits, one wall each. No drive-by refactors.
- Existing handwritten semantic overrides stay authoritative only for the
  SwiftUI-magic exception in `AGENTS.md`. Runtime priority is not permission to
  add per-API special cases; grow ordinary coverage through BridgeGen.
- Tests are never weakened; divergences are documented in README or fixed.
- Fixtures: real bytes captured once (curl / repo-committed resources).
- Network only through NetworkPolicy; auth flows out of scope.
