#!/bin/zsh
# validate-anti-drift.sh — executes the AGENTS.md "Generality safeguards" as EXIT CODES.
#
# Those safeguards are binding and, until this script, were enforced by prose alone. The project's
# own governing rule (LOOP-ICECUBES.md, after the 2026-07-24 execution-gap audit) says a rule that
# can be checked mechanically MUST be checked by a script that fails the close gate — because prose
# rules demonstrably do not fire. They did not: the §5 leverage ratchet was crossed inside the
# 2026-08-04..08-07 window and nothing noticed, the third recurrence of the same execution gap.
#
# WHICH selection crossed matters, and naming it is the whole lesson. The 7.1987 (1501ab98, 08-04)
# -> 6.9968 (f2fdf747, 08-07) figures are the NARROW one-directory series:
#   awk -v g="$(cat Sources/SwiftUIBridge/Generated/*.swift | wc -l)" \
#       -v b="$(cat Sources/BridgeGen/*.swift | wc -l)" 'BEGIN{printf "%.4f\n", g/b}'
# The WIDE whole-tree selection that FLOOR_LEVERAGE enforces read 7.6724 -> 7.4729 over those same
# two shas and never came near its floor — so until 2026-08-08 this file documented one measurement
# in its preamble and enforced a different one below it, which is the same defect one level down
# from the AGENTS.md §5 text. Both series now carry a floor of their own: FLOOR_LEVERAGE (wide) and
# FLOOR_NARROW_LEVERAGE (narrow), each with the command that produces it.
#
# EVERY THRESHOLD BELOW COMMITS THE COMMAND THAT PRODUCES IT, not just the number. The 2026-08-07
# audit could not reproduce ANY prior audit's figure (1092, 270, 7) because each committed a number
# and no command — three different file selections give three different "leverages" for the same
# tree. A ratchet whose measurement cannot be re-run is decoration.
#
#   ./Scripts/validate-anti-drift.sh            enforce; exit 1 on any violation
#   ./Scripts/validate-anti-drift.sh --print     report only; exit 0 however the thresholds land
#   ./Scripts/validate-anti-drift.sh --self-test verify the comparison logic, exit 0
#
# EXIT 2 IS NOT A THRESHOLD VIOLATION AND --print DOES NOT SUPPRESS IT. It means a measurement
# stopped measuring — a file selection matched nothing, or a list this script counts was respelled
# — so the number it would print describes nothing and every mode must stop instead of reporting
# it. --print exits 0 for any reading that was actually taken, however bad, and reports `n/a` for a
# metric that is legitimately unavailable in this checkout (the ledger one). The guards live at the
# end of measure(); each says which selection went empty.
#
# Measures the WORKING TREE, so it is correct in the main checkout, in a lane worktree, and in the
# clean-detached checkout the closing gate builds.
set -u

# ── Thresholds ────────────────────────────────────────────────────────────────────────────────
# Set from the frontier at 358d3ff3 (2026-08-07) with deliberate headroom. These are trend alarms,
# not style police: a ratchet tight enough to fire on noise gets disabled, and a disabled ratchet is
# the prose it replaced. Tighten only with a measurement showing the new floor held for a week.

# §5 generation leverage: generated lines per line of generator. Falls when the hand tier grows
# faster than generated coverage. LOOSE ON PURPOSE — adding a general spelling to BridgeGen raises
# the denominator before the generated output catches up, and that is exactly the work we want. The
# collapse this must catch is the 1:21.7 -> 1:7.8 slide of 2026-07-28, not a 0.05 wobble.
FLOOR_LEVERAGE=6.50

# §5, the NARROW one-directory series — the one every historical figure was measured with, and the
# one that actually collapsed: 21.7 (07-15) -> 7.8 (07-28) -> 7.1987 (08-04) -> 6.8781 (today). It
# gets a floor of its own because the wide selection above cannot fire for it. The two are the same
# ratio plus an OFFSET — wide = narrow + extras/denominator, where the extras are the 7413 lines the
# narrow glob cannot see (Sources/SwiftInterpreter/Generated/, and the flat-name Generated*.swift
# spelling), today 7413/16001 = 0.4633, exactly 7.3414 - 6.8781. So the wide series sits half a
# point higher at all times and reaches a given floor half a point later. Measured, not assumed:
# across 1501ab98..HEAD the narrow series fell 0.3206 and the wide one fell 0.3310 — the same fall
# — but the wide one fell 7.6724 -> 7.3414, a full point clear of its floor throughout, so the
# enforced series could not have fired for the fall the audit is about, and did not. (Note what is
# NOT the mechanism: GeneratedPlatformBridge.swift is 89974 lines and dominates BOTH numerators —
# 77% of wide, 82% of narrow — so "one file dominates the wide numerator" does not discriminate
# between them. The offset does.) Reported-not-enforced is how §5 spent 07-19..08-07.
#   awk -v g="$(cat Sources/SwiftUIBridge/Generated/*.swift | wc -l)" \
#       -v b="$(cat Sources/BridgeGen/*.swift | wc -l)" 'BEGIN{printf "%.4f\n", g/b}'  -> 6.8781
# Headroom is 0.3781 (5.5%), set against measured volatility rather than taste: over the last 60
# commits the largest step between ADJACENT commits is 0.1086 (88a74a7a 7.1755 -> 65b358ad 7.0669),
# so the floor is 3.5 single-commit wobbles away and cannot be reached by dilution without several
# days of it — the whole 08-04..08-08 fall was 0.32. It equals FLOOR_LEVERAGE by arithmetic accident,
# not by copying: two selections, two commands, two independently calibrated numbers that happen to
# round to the same place today. Moving it is a decision with a measurement, like every other here.
FLOOR_NARROW_LEVERAGE=6.50

# §3 dispatch on PROPERTY, not IDENTITY. Counted as DENSITY (identity branches per 1000 generated
# lines), never as an absolute, for two reasons the 2026-08-07 audit established:
#   - absolute is gameable without moving a single key: 65b358ad rewrote a `switch` into a
#     dictionary literal, `case "` fell 1248 -> 1244, and the identical keys survived untouched;
#   - absolute cannot distinguish "grew because coverage doubled" from "grew one-per-feature",
#     which is the ONLY distinction §3 actually makes ("never scales linearly with features").
# Density holds flat when identity grows proportionally to coverage and rises when it outruns it.
CEIL_IDENTITY_DENSITY=19.50

# The function half of the north star. Zero rungs were added across the 72 commits of the audit
# window while ~500k AE of pixel debt was retired; this floor does not force growth (that is a
# steering decision) but it makes a REGRESSION impossible to land silently. Growth is no longer
# purely a steering decision: CEIL_BOARD_GAP below forces it once the pixel half runs far enough
# ahead, which is the hole this floor left open and the 2026-08-08 audit found in it.
FLOOR_RUNGS=9

# COUPLING — the two halves of the north star may not drift apart. FLOOR_RUNGS above only notices a
# rung being REMOVED, and removal was never the failure mode: the ladder reached 9 rungs at
# 4e0489c3 (2026-08-03 20:34 +0300) and has not moved since, through
#   git rev-list --count 4e0489c3..HEAD                                            -> 104 commits
# and 110 hours, while the pixel half went from 3 scored screens (timeline, status-detail,
# account-header — the whole board at that sha) to 10. All five rung functions in
# Sources/IceCubesCheck/IceCubesCheck.swift are byte-identical to their state at 4e0489c3. Nothing
# fired, because no metric compared the two halves: each was watched alone, and neither regressed.
#
# The two counts, each by the command that produces it:
#   screens  awk '/^R2_SCREENS=\(/{f=1} f{print} f&&/\)/{exit}' Scripts/icecubes-r2.sh \
#              | tr '\n' ' ' | sed -e 's/^R2_SCREENS=(//' -e 's/).*$//' | wc -w     -> 10 today
#   rungs    grep -ohE '"R[0-9][a-z-]*"' Sources/IceCubesCheck/IceCubesCheck.swift \
#              | sort -u | wc -l                                                    -> 9 today
#
# The ratchet is the LEAD — how many scored screens the pixel half carries that the function half
# has no rung for. Arithmetic, against today's ladder of 9 rungs:
#   10 - 9  = 1   this tree                                       GREEN, one screen of headroom
#   11 - 9  = 2   the hashtag-timeline board already gated and pushed on
#                 land-hostext-lookup-cost and overlay-hashtag-timeline  GREEN, at the ceiling
#   12 - 9  = 3   the screen after that, admitted on its own             RED — it needs a rung
#   12 - 10 = 2   the same screen admitted together with that rung       GREEN
# The allowance is 2 and not 1 because the eleventh screen is already in flight on two branches,
# and a ratchet that reds work already gated is a defect, not a win. From the twelfth screen on,
# admission and rungs move together. Raising this number is a decision to let the halves separate
# again, and gets the same treatment as any other: a measurement, its own commit, and a reason.
CEIL_BOARD_GAP=2

# COVERAGE, the other direction — and the reason CEIL_BOARD_GAP cannot be satisfied by shrinking. A
# lead ceiling on its own is dischargeable by DELETING a screen from R2_SCREENS, which would retire
# that screen's debt without fixing anything. It is also the stagnation nothing watches any more:
# Scripts/validate-icecubes-close-policy.rb fires when open pixel debt fails to FALL across a window
# of landings and requires that debt to be POSITIVE so a converged board does not read as stalled
# (LOOP-ICECUBES.md §14) — with the non-acknowledged floor sum at exactly 0 and discharge outrunning
# admission ~2.2x, that detector cannot fire at all. The stall this project can now actually suffer
# is "nobody admitted a new screen for N landings", so the board's WIDTH gets a floor of its own:
# both counts hold or rise, and a commit that silently drops a screen fails the gate whatever it
# does to the lead.
#   (screen command as above)                                                       -> 10 today
FLOOR_SCORED_SCREENS=10

# The one-row-per-family surface the audit found growing monotonically (3 -> 13 rows in 24 days)
# and invisible to every existing metric. Its defence is strong today — d8c33e9d bought 2,214
# generated lines with 10 rows — so this is a watch, not a ban: generous ceiling, always reported.
CEIL_PLATFORM_SPECS=20

# §4 THE PAYLOAD IS A SPECIAL CASE TOO. The four adapters named in AUDIT-2026-07-28 §D carry
# measurement-calibrated constants (`red: 233.0/255.0`, `.padding(.bottom, -1)`, a pointSize known
# to be wrong). They are frozen, not dissolved — zero commits in the audit window touched them. No
# headroom: adding a calibrated constant to this surface should require moving this number and
# saying why.
CEIL_PAYLOAD_CONSTANTS=11

# §4, widened. The check above watches four FILENAMES, which is why it reads
# "saturated at 11" while saying nothing about the rest of the bridge: a
# constant tuned until pixels matched is a §4 violation wherever it lives, and
# nothing stopped the next one landing in a file the glob does not name. This
# counts the SHAPE instead — a number written next to a layout word
# (padding/inset/offset/width/height/spacing/pointSize/cornerRadius) anywhere in
# the handwritten bridge. Today that is five, and two of them are honest clamps
# (`max(1, …)` against a zero-size surface) while one is `padding(.bottom, -1)`,
# named by AUDIT-2026-07-28 §D. A sixth is the finding.
CEIL_LAYOUT_CONSTANTS=5

# Bounds the exemption added to the close policy in this same change. A screen
# marked `# ACKNOWLEDGED <screen>:` in the R2 board stops counting toward the
# STALL series, which is correct for a residue that owes no renderer fix and is
# an escape hatch for everything else. One exists (tags-list, an anti-aliased
# edge pair). Marking a second is a decision, not a reflex, and moving this
# number is how that decision gets reviewed.
CEIL_ACKNOWLEDGED_SCREENS=1

# Work that is pushed, unlanded, and mentioned NOWHERE in the ledger is
# invisible: nothing schedules it, nothing reviews it, and it is found only when
# somebody goes looking. r3-row-tap (bf0c0407) sat that way for 140 hours
# carrying two regression pins the landed rung has no repro for. Three such
# branches exist today (r3-row-tap, backup-pre-rewrite, and the two old
# overlay-integration refs, which share a name) — the ceiling is that baseline,
# so history is not punished. All four are now named in the ledger, so the line
# is ZERO: every pushed branch carrying unlanded work must be mentioned there,
# and a new one fails the close gate the first time it is gated after being
# forgotten. The branch under gate is exempt -- it posts its MERGE-READY only
# after this check passes. A branch is "recorded" when the ledger mentions its
# name at all; parking it deliberately, as frontier-duration-units-format does,
# satisfies this.
CEIL_UNRECORDED_STRANDED=0

# ── Measurement ───────────────────────────────────────────────────────────────────────────────
# Each metric names the exact command below it. Change the command and you change the number: bump
# the threshold in the same commit and say so, or the ratchet silently means something else.

# The coupling metric, factored out of measure() so --self-test can exercise the ARITHMETIC and not
# only the comparison. The defect this answers was never a comparison that returned the wrong
# answer; it was a comparison nobody had written, so the self-test has to pin what it computes.
# Negative is legitimate (the rung ladder ahead of the board) and passes any non-negative ceiling.
board_gap_of() { print -r -- $(( $1 - $2 )) }

measure() {
    # generated: every Swift line the generator emits — files under a Generated/ directory plus
    # files named Generated*.swift. Both spellings exist in this tree and they are disjoint.
    generated_lines=$(find Sources -name '*.swift' \
        \( -path '*/Generated/*' -o -name 'Generated*.swift' \) -exec cat {} + 2>/dev/null | wc -l)
    # generator: the BridgeGen sources that produce them.
    generator_lines=$(find Sources/BridgeGen -name '*.swift' -exec cat {} + 2>/dev/null | wc -l)

    # The narrow series, verbatim the historical selection: ONE generated directory over the
    # BridgeGen sources. `find -maxdepth 1` rather than a `*.swift` glob so an empty directory
    # yields 0 lines instead of a zsh no-match error, and so the count is identical to the
    # documented `cat .../Generated/*.swift` form as long as both stay flat — they are today
    # (14 files / 9 files, no subdirectories), and the zero guard below catches it if they stop.
    narrow_generated_lines=$(find Sources/SwiftUIBridge/Generated -maxdepth 1 -name '*.swift' \
        -exec cat {} + 2>/dev/null | wc -l)
    narrow_generator_lines=$(find Sources/BridgeGen -maxdepth 1 -name '*.swift' \
        -exec cat {} + 2>/dev/null | wc -l)

    # handwritten: everything in Sources that is NOT generated. Identity branches are counted as
    # OCCURRENCES (grep -o), not matching lines — one line can carry two.
    handwritten_files=$(find Sources -name '*.swift' \
        ! -path '*/Generated/*' ! -name 'Generated*.swift')
    identity_branches=$(print -r -- "$handwritten_files" \
        | tr '\n' '\0' | xargs -0 grep -ohE 'case "|== "' 2>/dev/null | wc -l)

    rung_count=$(grep -ohE '"R[0-9][a-z-]*"' Sources/IceCubesCheck/IceCubesCheck.swift 2>/dev/null \
        | sort -u | wc -l)
    # ONE list is the board — Scripts/icecubes-r2.sh says so at the array itself ("three copies
    # drifted apart is how a screen ends up captured but never scored") — so counting that array
    # counts the pixel half exactly as the R2 stage scores it. awk rather than a
    # sed '/^R2_SCREENS=(/,/)/p' range because a sed range searches its END address starting from
    # the line AFTER the start, so a one-line R2_SCREENS=(a b c) runs on to the next ')' anywhere in
    # the script and only the trailing s/).*$// truncation happens to cut it back to the right
    # answer. Correct by accident is not measured. The awk form terminates on the start line too;
    # checked against a synthetic one-line array (3) and the real two-line one (10).
    scored_screens=$(awk '/^R2_SCREENS=\(/{f=1} f{print} f&&/\)/{exit}' \
        Scripts/icecubes-r2.sh 2>/dev/null \
        | tr '\n' ' ' | sed -e 's/^R2_SCREENS=(//' -e 's/).*$//' | wc -w)
    platform_specs=$(sed -n '/^private let platformFrameworkSpecs/,/^]/p' \
        Sources/BridgeGen/PlatformGeneration.swift 2>/dev/null \
        | grep -cE '^[[:space:]]*(\.init|PlatformFrameworkSpec)')
    payload_constants=$(find Sources -name 'TargetPlatform*.swift' \
        -exec grep -hoE '[0-9]+\.[0-9]+|, -?[0-9]+\)' {} + 2>/dev/null | wc -l)
    layout_constants=$(find Sources/SwiftUIBridge -name '*.swift' \
        ! -path '*/Generated/*' ! -name 'Generated*.swift' \
        -exec grep -hoiE \
        '(padding|inset|offset|width|height|spacing|pointsize|cornerradius)[^,)]{0,20}[,(][[:space:]]*-?[0-9]+(\.[0-9]+)?' \
        {} + 2>/dev/null | wc -l)
    acknowledged_screens=$(grep -cE '^[[:space:]]*#[[:space:]]*ACKNOWLEDGED[[:space:]]' \
        Scripts/icecubes-r2.sh 2>/dev/null || echo 0)

    # The ledger is gitignored, so it is ABSENT from the gate's clean-detached
    # checkout unless the gate passes its path. Counting zero mentions against a
    # ledger that is not there would report every branch as stranded; -1 means
    # "not measurable here" and is skipped rather than guessed.
    local claims="${ANTI_DRIFT_CLAIMS_PATH:-.claude/claims.md}"
    local head_sha=$(git rev-parse HEAD 2>/dev/null)
    if [[ -f "$claims" ]]; then
        unrecorded_stranded=$(
            git for-each-ref --format='%(refname:short)%09%(objectname)' \
                refs/heads refs/remotes/origin 2>/dev/null \
            | while IFS=$'\t' read -r ref sha; do
                [[ "$ref" == *main* || "$ref" == *HEAD* ]] && continue
                # The candidate under gate has not posted its MERGE-READY yet --
                # that happens after this check passes -- so counting it would
                # red every first gate of a new topic branch.
                [[ "$sha" == "$head_sha" ]] && continue
                git merge-base --is-ancestor "$sha" origin/main 2>/dev/null && continue
                short=${ref#origin/}
                grep -q -- "$short" "$claims" 2>/dev/null || print -r -- "$short"
            done | sort -u | wc -l
        )
    else
        unrecorded_stranded=-1
    fi

    generated_lines=${generated_lines// /}
    generator_lines=${generator_lines// /}
    narrow_generated_lines=${narrow_generated_lines// /}
    narrow_generator_lines=${narrow_generator_lines// /}
    identity_branches=${identity_branches// /}
    rung_count=${rung_count// /}
    scored_screens=${scored_screens// /}
    platform_specs=${platform_specs// /}
    payload_constants=${payload_constants// /}
    layout_constants=${layout_constants// /}
    acknowledged_screens=${acknowledged_screens// /}
    unrecorded_stranded=${unrecorded_stranded// /}

    if (( generator_lines == 0 || generated_lines == 0 )); then
        print -u2 "anti-drift: the generated/generator file selection matched nothing —" \
            "run this from a checkout root, not a subdirectory"
        exit 2
    fi

    if (( narrow_generator_lines == 0 || narrow_generated_lines == 0 )); then
        print -u2 "anti-drift: the NARROW selection (Sources/SwiftUIBridge/Generated/*.swift over" \
            "Sources/BridgeGen/*.swift) matched nothing — the generated tier was relocated;" \
            "re-point this measurement rather than letting the wide series stand in for it"
        exit 2
    fi

    # A zero screen count is never a real board, and it must not be treated as one. The list has
    # already been respelled once: at 4e0489c3 it was `typeset -A R2_FLOORS` plus a hardcoded
    # `for screen in timeline status-detail account-header`, and the single-list refactor arrived
    # later with 5acae73b. If it is respelled again, this has to stop the gate and be re-pointed —
    # scoring 0 would red FLOOR_SCORED_SCREENS with a message about screens nobody deleted, and
    # would hand CEIL_BOARD_GAP a lead of -9, i.e. green. Loud beats plausible.
    if (( scored_screens == 0 )); then
        print -u2 "anti-drift: no 'R2_SCREENS=(' array found in Scripts/icecubes-r2.sh —" \
            "the scored-screen list was renamed or respelled; re-point this measurement"
        exit 2
    fi

    # The same failure from the other side, and it is reachable: move
    # Sources/IceCubesCheck/IceCubesCheck.swift and rung_count is 0, which reds FLOOR_RUNGS with a
    # message about a rung nobody removed and hands CEIL_BOARD_GAP a lead of 10 — a coupling
    # violation invented entirely by the measurement failing. A zero-rung ladder is not a north
    # star half that regressed; it is this script pointing at a file that is no longer there.
    if (( rung_count == 0 )); then
        print -u2 "anti-drift: no '\"R<n>...\"' rung ids found in" \
            "Sources/IceCubesCheck/IceCubesCheck.swift — the rung ladder was renamed, respelled," \
            "or moved out of that file; re-point this measurement"
        exit 2
    fi
    board_gap=$(board_gap_of "$scored_screens" "$rung_count")

    leverage=$(awk -v g="$generated_lines" -v b="$generator_lines" 'BEGIN{printf "%.4f", g/b}')
    narrow_leverage=$(awk -v g="$narrow_generated_lines" -v b="$narrow_generator_lines" \
        'BEGIN{printf "%.4f", g/b}')
    identity_density=$(awk -v i="$identity_branches" -v g="$generated_lines" \
        'BEGIN{printf "%.3f", i*1000/g}')
}

# floor: value must be >= threshold. ceiling: value must be <= threshold.
violations=0
check_floor() {
    local name=$1 value=$2 floor=$3 rule=$4
    if awk -v v="$value" -v f="$floor" 'BEGIN{exit !(v+0 < f+0)}'; then
        print -u2 "ANTI-DRIFT $name: $value is BELOW its committed floor $floor — $rule"
        (( violations++ ))
    fi
}
check_ceiling() {
    local name=$1 value=$2 ceiling=$3 rule=$4
    if awk -v v="$value" -v c="$ceiling" 'BEGIN{exit !(v+0 > c+0)}'; then
        print -u2 "ANTI-DRIFT $name: $value is ABOVE its committed ceiling $ceiling — $rule"
        (( violations++ ))
    fi
}

if [[ "${1:-}" == "--self-test" ]]; then
    check_floor probe 5 6 "self-test"          # must count 1
    (( violations == 1 )) || { print -u2 "floor check failed to fire"; exit 1 }
    check_floor probe 7 6 "self-test"          # must not count
    (( violations == 1 )) || { print -u2 "floor check fired on a passing value"; exit 1 }
    check_ceiling probe 7 6 "self-test"        # must count
    (( violations == 2 )) || { print -u2 "ceiling check failed to fire"; exit 1 }
    check_ceiling probe 5 6 "self-test"        # must not count
    (( violations == 2 )) || { print -u2 "ceiling check fired on a passing value"; exit 1 }
    check_floor probe 6.9968 7 "self-test"     # the miss that went unnoticed: 0.045% counts
                                               # (that pair is the NARROW §5 series at f2fdf747
                                               #  against the 7 the AGENTS.md text then asserted)
    (( violations == 3 )) || { print -u2 "fractional floor miss not detected"; exit 1 }

    # EVERY THRESHOLD IN THIS BLOCK IS A LITERAL, never the live constant it stands for. The probes
    # exist to prove the comparison behaves; interpolating $CEIL_BOARD_GAP or $FLOOR_SCORED_SCREENS
    # would instead pin those constants to exactly the value they hold today, so the ratchet's own
    # intended advance — admitting a screen and raising the floor, the entire point of the metric —
    # would break its self-test and pressure whoever advances it to weaken the probe. The three
    # probes above use literals for exactly this reason. Each literal below names the board or
    # reading it was calibrated from, so a future reader can see what it was ever about.

    # The coupling and coverage ratchets (2026-08-08). Their arithmetic is pinned here, not just
    # their comparison: the failure they answer is that for 110 hours the two halves of the north
    # star had no shared number at all, so what this computes is the whole claim.
    # 2 below is CEIL_BOARD_GAP as calibrated for the 2026-08-08 board (10 scored screens, 9 rungs,
    # an eleventh screen already gated in flight); 10 below is FLOOR_SCORED_SCREENS at that board.
    (( $(board_gap_of 10 9) == 1 )) \
        || { print -u2 "coupling arithmetic wrong for the 10-screen / 9-rung board of 08-08"
             exit 1 }
    (( $(board_gap_of 9 10) == -1 )) \
        || { print -u2 "coupling arithmetic wrong when the rung ladder leads the board"; exit 1 }
    check_ceiling probe "$(board_gap_of 11 9)" 2 "self-test"   # in flight, at the ceiling: no fire
    (( violations == 3 )) \
        || { print -u2 "coupling ceiling fired on the 11-screen board already gated in flight"
             exit 1 }
    check_ceiling probe "$(board_gap_of 12 9)" 2 "self-test"   # 12th screen, no rung: must fire
    (( violations == 4 )) \
        || { print -u2 "coupling ceiling failed to fire on a 12th screen with no new rung"; exit 1 }
    check_ceiling probe "$(board_gap_of 12 10)" 2 "self-test"  # same screen, rung paid: no fire
    (( violations == 4 )) \
        || { print -u2 "coupling ceiling fired on a screen that arrived with its rung"; exit 1 }
    check_floor probe 9 10 "self-test"          # a screen dropped from the 08-08 board: must count
    (( violations == 5 )) \
        || { print -u2 "screen floor failed to fire on a screen dropped from R2_SCREENS"; exit 1 }
    check_floor probe 10 10 "self-test"         # the 08-08 board itself: must not count
    (( violations == 5 )) \
        || { print -u2 "screen floor fired on the board it was calibrated to"; exit 1 }
    check_floor probe 11 10 "self-test"         # the board in flight, one wider: must not count
    (( violations == 5 )) \
        || { print -u2 "screen floor fired on the 11-screen board already gated in flight"; exit 1 }

    # The narrow §5 series (2026-08-08). Literals again: 6.50 is FLOOR_NARROW_LEVERAGE as
    # calibrated against the 6.8781 this tree reads, and 6.8781 is that reading. The point of the
    # pair is that a fractional fall of 0.38 must be caught while today's value must not fire —
    # the wide series could not do either, since it stood a full point above its floor throughout
    # the 08-04..08-08 fall these numbers come from.
    check_floor probe 6.8781 6.50 "self-test"   # today's narrow reading: must not count
    (( violations == 5 )) || { print -u2 "narrow leverage floor fired on today's 6.8781"; exit 1 }
    check_floor probe 6.4999 6.50 "self-test"   # one ten-thousandth under: must count
    (( violations == 6 )) \
        || { print -u2 "narrow leverage floor failed to fire just below its floor"; exit 1 }
    check_floor probe 6.50 6.50 "self-test"     # exactly at the floor: a floor is inclusive
    (( violations == 6 )) || { print -u2 "narrow leverage floor fired at exactly its floor"; exit 1 }

    print "@@anti-drift-self-test passed"
    exit 0
fi

measure

print "── anti-drift (AGENTS.md generality safeguards) ──"
printf '  §5 leverage            %8s   floor %s   (generated %s / generator %s)\n' \
    "$leverage" "$FLOOR_LEVERAGE" "$generated_lines" "$generator_lines"
printf '  §5 leverage (narrow)   %8s   floor %s   (%s / %s, one-directory historical series)\n' \
    "$narrow_leverage" "$FLOOR_NARROW_LEVERAGE" "$narrow_generated_lines" "$narrow_generator_lines"
printf '  §3 identity density    %8s   ceil  %s   (%s branches per 1000 generated)\n' \
    "$identity_density" "$CEIL_IDENTITY_DENSITY" "$identity_branches"
printf '  rung ladder            %8s   floor %s\n' "$rung_count" "$FLOOR_RUNGS"
printf '  scored screens         %8s   floor %s   (R2_SCREENS in Scripts/icecubes-r2.sh)\n' \
    "$scored_screens" "$FLOOR_SCORED_SCREENS"
printf '  board coupling lead    %8s   ceil  %s   (screens the rung ladder has no rung for)\n' \
    "$board_gap" "$CEIL_BOARD_GAP"
printf '  platformFrameworkSpecs %8s   ceil  %s   (one-row-per-family watch)\n' \
    "$platform_specs" "$CEIL_PLATFORM_SPECS"
printf '  §4 payload constants   %8s   ceil  %s   (AUDIT-2026-07-28 §D surface)\n' \
    "$payload_constants" "$CEIL_PAYLOAD_CONSTANTS"
printf '  §4 layout constants    %8s   ceil  %s   (whole handwritten bridge, by shape)\n' \
    "$layout_constants" "$CEIL_LAYOUT_CONSTANTS"
printf '  acknowledged screens   %8s   ceil  %s   (STALL-series exemptions)\n' \
    "$acknowledged_screens" "$CEIL_ACKNOWLEDGED_SCREENS"
if (( unrecorded_stranded >= 0 )); then
    printf '  unrecorded stranded    %8s   ceil  %s   (pushed, unlanded, unmentioned)\n' \
        "$unrecorded_stranded" "$CEIL_UNRECORDED_STRANDED"
else
    print '  unrecorded stranded         n/a             (ledger not readable here)'
fi

check_floor   "leverage"            "$leverage"          "$FLOOR_LEVERAGE" \
    "the hand tier is outgrowing generated coverage (§5)"
check_floor   "leverage-narrow"      "$narrow_leverage"   "$FLOOR_NARROW_LEVERAGE" \
    "the one-directory series that carried the 21.7 -> 7.8 -> 6.88 collapse is falling again; the wide series above cannot see this because GeneratedPlatformBridge dominates its numerator (§5)"
check_ceiling "identity-density"    "$identity_density"  "$CEIL_IDENTITY_DENSITY" \
    "identity-keyed branches are outrunning coverage — dispatch on a PROPERTY (§3)"
check_floor   "rungs"               "$rung_count"        "$FLOOR_RUNGS" \
    "a rung was removed; the function half may not regress"
check_floor   "scored-screens"      "$scored_screens"    "$FLOOR_SCORED_SCREENS" \
    "a screen was dropped from R2_SCREENS; the pixel half may not narrow, and a narrowed board retires debt without fixing anything"
check_ceiling "board-coupling"      "$board_gap"         "$CEIL_BOARD_GAP" \
    "the pixel board is running ahead of the rung ladder — admit the screen together with the rung that exercises it, or the function half freezes again while the pixel half triples (LOOP-ICECUBES.md: BOTH halves)"
check_ceiling "platform-specs"      "$platform_specs"    "$CEIL_PLATFORM_SPECS" \
    "the per-family config surface is galloping (§2 depth cap)"
check_ceiling "payload-constants"   "$payload_constants" "$CEIL_PAYLOAD_CONSTANTS" \
    "a measurement-calibrated constant was added to a frozen surface (§4)"
check_ceiling "layout-constants"    "$layout_constants"  "$CEIL_LAYOUT_CONSTANTS" \
    "a number was written beside a layout word in the handwritten bridge — derive it, or say why this case is irreducibly specific (§4)"
check_ceiling "acknowledged"        "$acknowledged_screens" "$CEIL_ACKNOWLEDGED_SCREENS" \
    "another screen was exempted from the STALL series; an exemption is a decision, not a reflex"
if (( unrecorded_stranded >= 0 )); then
    check_ceiling "unrecorded-stranded" "$unrecorded_stranded" "$CEIL_UNRECORDED_STRANDED" \
        "a pushed branch carries unlanded work the ledger never mentions — post it, or land it"
fi

# version 2 (2026-08-08): the payload gained scoredScreens/scoredScreenFloor/boardGap/
# boardGapCeiling and narrowLeverage/narrowLeverageFloor/narrowGeneratedLines/narrowGeneratorLines.
# The field exists so a consumer can key off the SHAPE; leaving it at 1 while the shape changed
# would make it the kind of number that describes nothing, which is the whole subject of this file.
# All six new keys are additions — no key from version 1 was renamed or dropped, so a consumer that
# reads only the version-1 set keeps working.
print "@@anti-drift {\"version\":2,\"leverage\":$leverage,\"leverageFloor\":$FLOOR_LEVERAGE,\"narrowLeverage\":$narrow_leverage,\"narrowLeverageFloor\":$FLOOR_NARROW_LEVERAGE,\"narrowGeneratedLines\":$narrow_generated_lines,\"narrowGeneratorLines\":$narrow_generator_lines,\"identityBranches\":$identity_branches,\"identityDensity\":$identity_density,\"identityDensityCeiling\":$CEIL_IDENTITY_DENSITY,\"generatedLines\":$generated_lines,\"generatorLines\":$generator_lines,\"rungs\":$rung_count,\"rungFloor\":$FLOOR_RUNGS,\"scoredScreens\":$scored_screens,\"scoredScreenFloor\":$FLOOR_SCORED_SCREENS,\"boardGap\":$board_gap,\"boardGapCeiling\":$CEIL_BOARD_GAP,\"platformSpecs\":$platform_specs,\"payloadConstants\":$payload_constants,\"layoutConstants\":$layout_constants,\"acknowledgedScreens\":$acknowledged_screens,\"unrecordedStranded\":$unrecorded_stranded,\"violations\":$violations}"

if [[ "${1:-}" == "--print" ]]; then
    exit 0
fi

if (( violations > 0 )); then
    print -u2 "ANTI-DRIFT RED — $violations safeguard(s) violated"
    print -u2 "A violation is not a request to move the threshold. Name the property the case is" \
        "keyed on, or cite why it is irreducibly specific (AGENTS.md safeguard 1)."
    exit 1
fi
print "anti-drift GREEN"
