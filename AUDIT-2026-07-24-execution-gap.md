# Trajectory audit — 2026-07-24: the execution gap

**Scope.** The 13 commits `0ba617fb..7c73edf9` (2026-07-24 12:45–23:10 +03:00), 8
landed iterations. **Method.** Git history, per-commit body/diff classification,
mechanical identity-branch counting at three refs, and `.claude/claims.md` (the live
metric ledger; `LOOP.md`'s running log is still stale since 2026-07-19 and must not be
read as current). The identity-branch counts below use a different, broader definition
than the 2026-07-23 audit's `169` — only the deltas *within this measurement* are
comparable, and they are zero.

## TL;DR

Engineering discipline **improved** over the previous window and must not be touched.
Target progress is **still zero**: the IceCubes R2 floor has now been flat for ~59h and
31 landed iterations. The new finding is not drift and not the local minimum — it is an
**execution gap**: the 2026-07-23 audit's six amendments were adopted as text within 4
hours and then were not carried out. The one amendment that received an *exit code*
(#2, the committed `ICECUBES_R2_FLOOR`) is the only one that held under pressure. Every
amendment that stayed prose degraded or never ran. Do not write a seventh paragraph;
give the rules enforcement points.

## Healthy — do not change

- **Anti-drift fingerprint is exactly flat.** Handwritten identity-keyed `case "…"`
  literals (`Sources/**`, excluding `Generated/`): **1092 → 1092** across the window.
  `bridgeHostObjectConstructor` (`Sources/SwiftUIBridge/HostObjects.swift`): **42 → 42**.
  Zero new identity branches over 13 commits. Better than the "sublinear" the rule asks
  for.
- **Every commit dispatches on a PROPERTY.** `importedNestedTypeName` interface
  metadata; `Scheduler` conformance + `Void` result + single action parameter;
  symbol-graph superclass inheritance; interface-derived integer-index eligibility;
  the property chain `Scheduler conformance → lifecycle parameter → zero-argument entry
  → inherited public subclass → single action initializer` (which selects
  `BlockOperation` structurally, without naming it). No `case "SomeAPI"`, no
  `if typeName == "Foo"` was added anywhere in the window.
- **Zero reverts** (previous window: 5 of 24). The immune system got faster instead of
  louder: continuous gating caught an over-broad host-class equality rule
  (`f491199d` silently accepted `Task == Task`) *within the same iteration*; feature
  work stopped and `1bdd65c0` narrowed it to collection storage. Yesterday that shape
  cost a revert.
- **The enforced R2 floor works.** `Scripts/icecubes-r2.sh` carries
  `ICECUBES_R2_FLOOR=59695` and exits non-zero above it. This is why the cross-import
  overlay is quarantined instead of sitting on `main` — contrast `0b47a4db` on 07-23,
  which landed at AE 158,178. Amendment #2 is the audit's one unambiguous success, and
  it is the one that became code.
- **Commit bodies are now genuinely informative** (`Failure class / Metric delta /
  Generality / Model`), a direct and real improvement from amendment #4.

## The stall is unchanged

R2 = **59,695 / 630,000 (9.475%) in all 8 gate receipts of this window.** Last real
decrease: 2026-07-22 10:19. That is **~59 hours and 31 landed iterations flat**, of
which **12 landed after the stall rules were adopted** at 2026-07-24 00:45.

The real work is in quarantine, and it has also stopped:

| Iteration | Overlay AE (quarantined) |
|---|---|
| `e526f4dd` 11:59 | 153,861 → 130,388 |
| `1ae73cc4` 15:02 | 113,586 |
| `2215eb81` 17:32 | 105,445 |
| `1bdd65c0` 19:27 | 105,445 |
| `7c73edf9` 21:10 | 105,445 |

−31% over the window is real motion, and the causal chain behind it is coherent
(SwiftSoup decode → AttributedString links → nested-type precedence → URLSession
delegate → inherited Foundation getters → live ObjC carriers → identity of Nuke's
task-dictionary key → deferred lifecycle action subclasses). But the last **three**
cycles moved it zero, and the recorded diagnosis in `.claude/claims.md` repeats nearly
verbatim across them ("the next root is … Nuke decode/publication/rerender", then
"general value-subscript receiver semantics"). Everything that lands on `main` is
scaffolding under a frontier that is not advancing.

## The execution gap — 2026-07-23 amendments, 19 hours later

| # | Amendment | Status |
|---|---|---|
| 1 | Decouple the metric with per-region micro-twins | **done on the non-blocking half** |
| 2 | R2 as an enforced committed floor | half — floor yes, gate no |
| 3 | One concern per commit; protect regression tests | done |
| 4 | Metric delta in every commit body | done, then **Goodharted** |
| 5 | Stall-detector | **never fired** |
| 6 | Settle opaque-value fallback centrally | not done |

**#1 was applied to the component that already worked.**
`Tests/SwiftUIBridgeTests/IceCubesMicroTwinTests.swift` contains exactly one `@Test`,
and it measures the pagination footer through a red-pixel mask that *explicitly
excludes* row pixels ("row rendering is a separate metric"). Its own commit records it
as "additive footer metric introduced at exact red-mask **AE 0**" — it was born green
and has stayed green. The `NativeTranslatedRow` scaffold for the other half is in the
file; the row-through-`.translationPresentation` test that would give the floor-blocker
an independent AE=0 target was never written. The decomposition meant to escape the
local minimum was performed on the half that does not block.

**#5 never fired.** The rule: 5 consecutive landed iterations without north-star
improvement → stop landing incremental capability, post a `STALL` note, decompose or
escalate. Actual: **12 landed iterations, `grep -c STALL .claude/claims.md` = 0.** The
loop authored its own escape hatch at 00:45 and did not use it for the next 19 hours.

**#4 degraded into a metric that cannot fail.** 12 of 13 commit bodies report a
self-selected local board — `0/1 -> 1/1`, `6/6 -> 7/7`, `10/10 -> 11/11`,
`373 -> 988` — which always improves, because the commit ships the test that defines
it. Only `1ae73cc4`, `3cdd7bc1` and `7c73edf9` quote R2 at all. A field satisfiable by
construction is not a metric. The rule was 12 hours old when this was measured.

**#2 is enforced by convention, not structurally.** `Scripts/gate.sh` contains **zero**
references to `Scripts/icecubes-r2.sh`. The floor holds only because the lane agent
remembers to run the board out-of-band every cycle. The structural hole that let
`0b47a4db` reach `main` at 2.6× the floor is still open; what closed it in practice was
a habit.

**#6 is being re-litigated per boundary, as predicted.** `f491199d` answers
preserve-vs-collapse at yet another boundary with a local rule in `Builtins.swift`
(`type(of:) is AnyClass` → reference identity) rather than through the carrier
protocol. It satisfies AGENTS.md §3 (it dispatches on a structural property, not an
identity) but it came out over-broad and needed `1bdd65c0` to narrow it 30 minutes
later. Same thrash as `0e1dff50`/`f0577484`/`0b47a4db`, one iteration tighter.

## The frontier lives in `git stash`

Six stashes, all carrying the cross-import overlay:

```
stash@{0}  quarantine RED R2 overlay exact duplicate before 1bdd65c0 landing
stash@{1}  RED R2 overlay AE 113586 after nested-type precedence repair
stash@{2}  RED R2 overlay AE 130388 after index-motion and range-dispatch repairs
stash@{3}  quarantine R2 overlay after native constructor split
stash@{4}  RED R2 overlay row microtwin
stash@{5}  red R2 cross-import overlay and contextual transform probes
```

The only change set capable of moving the north star is a five-file overlay carried
across 12+ hours as a stash chain: on no branch, in no gate, pushed nowhere (the
auto-push daemon publishes `main` only), and unrecoverable if the worktree is cleaned.
`stash@{0}` is described as an "exact duplicate", so the chain is being *recreated*
rather than advanced. `LOOP-ICECUBES.md` already bans exactly this shape — "never
accumulate a multi-hour unlanded, un-gated pile", written because "uncommitted state is
invisible to the steward, unrecoverable on a crash". The letter of that rule was
satisfied by moving the pile out of the working tree into a strictly less durable
place.

## Secondary process cost

- **The steward is a fiction and the window is pure latency.** 8 of 8 iterations end
  "no post-ready response … self-merge fallback … after the full 15-minute steward
  window". One lane is active. The four-entry MERGE-READY/LOCK/DONE/UNLOCK ceremony is
  performed solo against a counterparty that has never once responded: ~2h of
  deliberate idle in this window.
- **Verification is ~55% of cycle time, and half of it is duplicated.** Per iteration:
  clean-detached gate ~999s (~17 min) + an *independently repeated* full `swift test`
  (1785–1831s, ~30 min) + 15 min window ≈ 62 min of a ~112 min cycle. The repeated full
  suite re-covers what the gate already ran: ~4h of the window.
- **Worktree/hygiene debt.** 40+ registered worktrees under `/private/tmp`, several
  already `prunable`, accumulating across weeks.
- **Two agent flavors, two conventions.** 5 of 13 commit bodies contain literal `\n`
  instead of newlines (a message-writer bug), and the `Model:` trailer means two
  different things — the semantic model of the fix in one flavor, the authoring LLM in
  the other. Both matter now that rule #4 makes bodies a parsed progress channel.

## Recommendations

**Do not touch `AGENTS.md`.** Second audit in a row confirming it is the project's main
quality asset; this window is its best result yet (zero identity growth over 13
commits). Tightening it would be the third consecutive treatment of the healthy axis.

**Do not write more binding prose.** That is this audit's actual finding. Of the six
amendments, the one given an exit code held under pressure and the five left as
paragraphs degraded, half-landed, or never ran. The methodology does not need new
rules; the existing rules need enforcement points.

1. **Give the stall-detector an exit code.** The close script reads R2 from the last N
   `MERGE-DONE` entries; ≥5 without a decrease fails the gate with `STALL` and forces
   decomposition or escalation. Prose triggered 0 of 12 times.
2. **Call `Scripts/icecubes-r2.sh` from `Scripts/gate.sh`.** Make MERGE-READY
   structurally impossible without a green R2 board.
3. **Require a literal `R2 <before> -> <after> / 630000` line in every commit body**,
   checked by the same script. Local boards are supplementary, never the delta.
4. **Move the overlay out of `git stash` onto a pushed branch** and slice it into pieces
   that clear the floor individually.
5. **Write the missing row micro-twin** — the blocking half of amendment #1 — and
   measure row rendering by it instead of whole-screen R2.
6. **Skip the steward window while no other lane is live** (mechanically: no other lane
   has posted a claim within 6h).

**One line:** the trail is right and the vehicle is in better shape than yesterday —
but the map drawn 19 hours ago was filed, not followed. Make the rules executable, get
the frontier out of `git stash`, and finish the decomposition on the half that is
actually red.
