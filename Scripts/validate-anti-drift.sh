#!/bin/zsh
# validate-anti-drift.sh — executes the AGENTS.md "Generality safeguards" as EXIT CODES.
#
# Those safeguards are binding and, until this script, were enforced by prose alone. The project's
# own governing rule (LOOP-ICECUBES.md, after the 2026-07-24 execution-gap audit) says a rule that
# can be checked mechanically MUST be checked by a script that fails the close gate — because prose
# rules demonstrably do not fire. They did not: the §5 leverage ratchet was crossed inside the
# 2026-08-04..08-07 window (7.1987 -> 6.9968 under that audit's file selection) and nothing noticed,
# the third recurrence of the same execution gap.
#
# EVERY THRESHOLD BELOW COMMITS THE COMMAND THAT PRODUCES IT, not just the number. The 2026-08-07
# audit could not reproduce ANY prior audit's figure (1092, 270, 7) because each committed a number
# and no command — three different file selections give three different "leverages" for the same
# tree. A ratchet whose measurement cannot be re-run is decoration.
#
#   ./Scripts/validate-anti-drift.sh            enforce; exit 1 on any violation
#   ./Scripts/validate-anti-drift.sh --print     report only, always exit 0
#   ./Scripts/validate-anti-drift.sh --self-test verify the comparison logic, exit 0
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
# steering decision) but it makes a REGRESSION impossible to land silently.
FLOOR_RUNGS=9

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

measure() {
    # generated: every Swift line the generator emits — files under a Generated/ directory plus
    # files named Generated*.swift. Both spellings exist in this tree and they are disjoint.
    generated_lines=$(find Sources -name '*.swift' \
        \( -path '*/Generated/*' -o -name 'Generated*.swift' \) -exec cat {} + 2>/dev/null | wc -l)
    # generator: the BridgeGen sources that produce them.
    generator_lines=$(find Sources/BridgeGen -name '*.swift' -exec cat {} + 2>/dev/null | wc -l)

    # handwritten: everything in Sources that is NOT generated. Identity branches are counted as
    # OCCURRENCES (grep -o), not matching lines — one line can carry two.
    handwritten_files=$(find Sources -name '*.swift' \
        ! -path '*/Generated/*' ! -name 'Generated*.swift')
    identity_branches=$(print -r -- "$handwritten_files" \
        | tr '\n' '\0' | xargs -0 grep -ohE 'case "|== "' 2>/dev/null | wc -l)

    rung_count=$(grep -ohE '"R[0-9][a-z-]*"' Sources/IceCubesCheck/IceCubesCheck.swift 2>/dev/null \
        | sort -u | wc -l)
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
    identity_branches=${identity_branches// /}
    rung_count=${rung_count// /}
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

    leverage=$(awk -v g="$generated_lines" -v b="$generator_lines" 'BEGIN{printf "%.4f", g/b}')
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
    (( violations == 3 )) || { print -u2 "fractional floor miss not detected"; exit 1 }
    print "@@anti-drift-self-test passed"
    exit 0
fi

measure

print "── anti-drift (AGENTS.md generality safeguards) ──"
printf '  §5 leverage            %8s   floor %s   (generated %s / generator %s)\n' \
    "$leverage" "$FLOOR_LEVERAGE" "$generated_lines" "$generator_lines"
printf '  §3 identity density    %8s   ceil  %s   (%s branches per 1000 generated)\n' \
    "$identity_density" "$CEIL_IDENTITY_DENSITY" "$identity_branches"
printf '  rung ladder            %8s   floor %s\n' "$rung_count" "$FLOOR_RUNGS"
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
check_ceiling "identity-density"    "$identity_density"  "$CEIL_IDENTITY_DENSITY" \
    "identity-keyed branches are outrunning coverage — dispatch on a PROPERTY (§3)"
check_floor   "rungs"               "$rung_count"        "$FLOOR_RUNGS" \
    "a rung was removed; the function half may not regress"
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

print "@@anti-drift {\"version\":1,\"leverage\":$leverage,\"leverageFloor\":$FLOOR_LEVERAGE,\"identityBranches\":$identity_branches,\"identityDensity\":$identity_density,\"identityDensityCeiling\":$CEIL_IDENTITY_DENSITY,\"generatedLines\":$generated_lines,\"generatorLines\":$generator_lines,\"rungs\":$rung_count,\"rungFloor\":$FLOOR_RUNGS,\"platformSpecs\":$platform_specs,\"payloadConstants\":$payload_constants,\"layoutConstants\":$layout_constants,\"acknowledgedScreens\":$acknowledged_screens,\"unrecordedStranded\":$unrecorded_stranded,\"violations\":$violations}"

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
