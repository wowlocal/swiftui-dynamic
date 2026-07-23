# Trajectory audit — 2026-07-23: the IceCubes R2 stall

**Scope.** The 24 commits ending `29aac877` (2026-07-23 18:40). **Method.** Four
parallel read-only audits — revert cluster; per-commit identity-vs-property
classification; quantitative drift-fingerprint trend; target-metric trajectory —
cross-checked by hand against git history and `.claude/claims.md` (the live metric
ledger; `LOOP.md`'s running log is stale since 2026-07-19 and must not be read as
current).

## TL;DR

The engineering methodology is healthy and must **not** be loosened. Target progress
has **stalled**: the IceCubes R2 pixel floor did not move across the audited window,
and ~40% of the day's commits (10 of 24: 5 add + 5 revert) were self-cancelling
capability experiments. The stall is a **characterized local minimum plus two process
defects** — not a discipline failure. Tightening the anti-drift rules would repair what
is not broken and leave the actual problem untouched. Do not conflate the two axes.

## Healthy — do not change

- **Anti-drift fingerprint is flat.** Identity-keyed branches over SDK/host names
  (the drift signature per `AGENTS.md` §"Generality safeguards" #3): 169 → 169 over the
  last 24 commits; the primary hand dispatcher `bridgeHostObjectConstructor`
  (`Sources/SwiftUIBridge/HostObjects.swift`) 41 → 42 over the last 52 commits, against
  ~250 feature commits in that span. Sublinear and recently flat — the shape the rule
  calls healthy. The 2026-07-19 detached-FileManager drift incident is resolved
  (generalized to an `Operation`/`FileServiceRouting` table).
- **Every kept handwritten-surface commit dispatches on a PROPERTY, not identity.** All
  11 non-reverted commits touching interpreter/bridge surfaces introduce a new dispatch
  property (marker protocols `GeneratedBinaryOperatorCarrier` /
  `RuntimeStringInterpolationAttachment`, the metadata flag `requiresExplicitTry`, the
  structural predicate `parsedBodyContainsExplicitReturn`, the immutable
  `buildConfiguration`) or generalize an existing branch toward one. `db1e3e31`'s "four
  UIFontMetrics overloads" is a genuine overload-family rule, not a hardcoded list. No
  new `case "SomeAPI"` / `if typeName == "Foo"` was added. The commit messages
  pre-emptively assert compliance; this was verified structurally, not from wording.
- **Repro doctrine and gate are rigorous.** Each capability ships a distilled,
  app-independent pixel repro driven RED → GREEN at AE=0. Every commit is gated on a
  fresh clean-detached checkout (≈1580 tests, 6 concurrency-parity shards, corpus
  678/680, live 5/5, API parity 361/0/0/1). Continuous gating catches regressions within
  1–2 commits (the 2026-07-20 "67 unlanded commits" lesson has been internalized).
- **Target selection is correct.** IceCubes-primary is the 2026-07-19 user directive;
  FoodTruck was proven pixel- and function-identical on 2026-07-18 and correctly demoted
  to a regression backstop. The apparent "FoodTruck neglect" is by design, not drift.

The five reverts are the immune system working, not failing. The one revert with a
recorded reason (`19336b79`) is a textbook catch: a capability raised R2 AE
59,695 → 60,547, and the floor covenant refused to trade a pixel regression for a
capability slice.

## The stall

IceCubes R2 AE floor trajectory (`.claude/claims.md`):

| Time (UTC) | R2 AE / 630,000 |
|---|---|
| 2026-07-21 22:13 | 535,233 |
| 2026-07-22 02:17 | 500,265 |
| 2026-07-22 05:24 | 62,078 |
| 2026-07-22 08:57 | 60,037 |
| **2026-07-22 10:19** | **59,695 — last real decrease** |
| … 2026-07-23 21:17 | 59,695 (unchanged) |

**The floor has been flat at 59,695 (9.475%) for 35h+ — zero improvement across the
entire audited window.** Of the 24 commits, ~12 are durable capability/semantic changes;
none moved the north-star. IceCubesCheck rungs are 6/6 (already at the R1 ceiling); the
ladder cannot advance to R3/R4 until R2 drops.

## Local-minimum mechanism

All 20 visible timeline rows terminate at the SDK cross-import modifier
`.translationPresentation`, which the interpreter **absorbs** instead of rendering. The
one change that would move R2 — generating the cross-import-overlay modifiers so the rows
draw — simultaneously exposes an offscreen pagination footer / mispositioned content that
raises **whole-screen** AE above the floor, so the R2 check reverts it (`19336b79`,
`ef6bd671`). All 5 reverts are this shape. The row-render win and the footer regression
are coupled at the whole-screen metric, so partial progress on either is penalized. This
is a genuine local minimum, not sloppiness — but the current "land a slice, measure whole
screen, revert if worse" loop cannot climb out of it.

A related unresolved question drives the "opaque value" revert cluster (`0e1dff50`,
`f0577484`, `0b47a4db`): when a value is partially opaque at a boundary (a `+` operator, a
`String`-typed slot, an unbridged modifier in a chain), does the interpreter preserve the
concrete value or collapse to a safe default? It is being answered boundary-by-boundary
and thrashing; the general-adapter answer (`1d82bb4f`'s carrier protocol) survives while
the per-boundary heuristics are all reverted.

## Two process defects

1. **Silent clobber of landed work.** The worktree-merge flow reverted a landed fix *and
   its regression test* invisibly, inside the unrelated commit `7ca94306` ("Keep nested
   source types in their module"): the opaque renderable-root preservation from
   `e0e161d1` was removed, re-implemented byte-for-byte 16h later (`0b47a4db`), and
   reverted again (`7ef876a7`). Net at HEAD: `Sources/SwiftUIBridge/ViewRegistry.swift`
   is back to `var wrapsView = false`, the "rows render EMPTY through opaque modifier
   chains" bug is open, and two engineering attempts were wasted. `git log -S
   "preservedRoot" -- Sources/SwiftUIBridge/ViewRegistry.swift` shows exactly these four
   commits. The loop bisected it (`.claude/claims.md` 2026-07-23 01:52, "first-bad
   `7ca94306` … accidental removal") — but only after the fact. Cause: a lane carried a
   stale file over newer `main`, hidden inside a multi-file commit, and the co-deleted
   regression test could not turn the suite red.

2. **The north-star metric is not in the merge gate.** `Scripts/gate.sh` enforces corpus
   678/680 + live 5/5 + parity, but **not** R2 AE — R2 is measured out-of-band by
   `Scripts/icecubes-r2.sh` *after* landing. So `0b47a4db` passed the gate GREEN, landed
   on `main`, and blew R2 to **158,178** (2.6×) before a post-landing capture caught it
   and revert-first restored 59,695 (`.claude/claims.md` 2026-07-23 02:21). The floor
   value itself is committed nowhere — it lives only in commit prose and the
   `.gitignored` `.claude/claims.md`.

## Recommendations

**Do not touch:** the `AGENTS.md` swiftinterface-first bridge rule and the anti-drift
safeguards. They are working and are the project's main quality asset. Tightening them now
treats the healthy axis.

**Change the iteration strategy to escape the R2 minimum:**

1. **Decouple the metric.** The frontier (`.translationPresentation`) is measured against
   the full 630k-pixel screen, so a real win (rows draw) is masked by a coupled regression
   (footer). Apply the repro doctrine to the *floor-blocker*, not only to capability:
   separate micro-twins for "a row through `.translationPresentation`" and for
   "pagination-footer position," each driven to AE=0 independently. The doctrine is
   already followed for capability; the one place it is *not* applied is the divergence
   that holds the floor.
2. **Put R2 in the gate.** Commit a per-region R2 floor artifact and check it in
   `gate.sh` (or a mandatory sibling gate) so R2 regressions are caught before landing,
   not after. This also makes the floor durable instead of prose-only.
3. **Fix worktree-merge.** (a) One concern per commit — `7ca94306` mixed
   DeclarationCollector work with a ViewRegistry revert, which is what hid the clobber.
   (b) Rebase a lane onto `main` before close, or diff against `main` for "this commit
   reverts a line `main` changed." (c) Protect regression tests from clobber — deleting a
   test alongside its fix is what suppressed the red signal.
4. **Put the metric delta in the commit body.** Commit bodies are mostly empty; the
   progress signal lives only in `.gitignored` `.claude/claims.md`, so `git log` alone
   reads as undifferentiated churn.
5. **Add a stall-detector.** The floor was flat ~35h over ~12 durable commits and a human
   had to notice. The loop caps iteration by time but has no "motion without progress"
   rule: north-star flat for K iterations → stop incrementing, force a root-cause
   decomposition (the per-region micro-twin) or escalate.
6. **Settle the opaque-value question once, centrally.** Generalize `1d82bb4f`'s
   carrier-protocol pattern to the modifier-chain and scalar boundaries instead of
   re-litigating each boundary with a local heuristic.

**One line:** the path is right, the pace has stopped. Do not rewrite the methodology —
it holds the quality bar. Change tactics to break out of the R2 minimum (decouple the
metric with per-region micro-twins), close the two process gaps (R2 in the gate;
anti-clobber worktree-merge), and add a stall-detector so next time the loop notices, not
a human.
