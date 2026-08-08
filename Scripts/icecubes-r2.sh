#!/bin/zsh
# Capture compiled Catalyst and interpreted IceCubes screens from the same
# recorded Mastodon bytes, then enforce each screen's exact per-pixel AE.
#
# Determinism contract: every scored screen is captured TWICE per side and the
# two passes must be pixel-identical (AE 0, no fuzz) before the board scores
# anything. A floor delta can then only mean interpreter fidelity moved —
# never spinner phase, settle timing, or machine load (the 2026-07-30 noise
# band was ~17-33k AE, larger than several committed ratchet ticks).
#
# TWO BOARDS, TWO QUESTIONS. The AE board asks whether the interpreter draws the
# same pixels; the latency board asks what those pixels cost. Both are committed
# ratchets and either one exits non-zero.
#
#   Scripts/icecubes-r2.sh              build, capture, score both boards
#   Scripts/icecubes-r2.sh --self-test  verify the latency arithmetic, the
#                                       ceiling comparison and the marker on
#                                       synthetic numbers; builds nothing,
#                                       captures nothing, exit 0
#
# There is deliberately no --print mode. Both boards always report and only the
# committed thresholds enforce, so a "report but do not enforce" run would mean
# paying half an hour of capture in order to ignore the answer — which is what
# having no ratchet at all already was.
set -u
cd "$(dirname "$0")/.." || exit 2

ROOT="$PWD"
FIXTURES="$ROOT/Fixtures/mastodon-public-timeline"
# Worktree-local by default so concurrent lanes never clobber each other's
# captures; the per-screen stdout lines carry the concrete paths.
TWIN_DIR="${ICECUBES_R2_TWIN_DIR:-$ROOT/.build/icecubes-r2-captures/native-twin}"
INTERP_DIR="${ICECUBES_R2_INTERP_DIR:-$ROOT/.build/icecubes-r2-captures/interpreted}"
TWIN_REPEAT_DIR="$TWIN_DIR-repeat"
INTERP_REPEAT_DIR="$INTERP_DIR-repeat"
# 2026-07-16T12:00:00Z, immediately after the recorded fixture was captured.
FROZEN_NOW=1784203200
CLOCK_DIR="$ROOT/Examples/IceCubesNativeTwin/.build/frozen-clock"
INTERP_SCRATCH_PATH="${ICECUBES_R2_SCRATCH_PATH:-$ROOT/.build/icecubes-r2-product}"
INTERP_BUILD_DIR="$INTERP_SCRATCH_PATH/arm64-apple-ios-macabi/debug"
INTERP_BINARY="$INTERP_BUILD_DIR/IceCubesCheck"
INTERP_APP="$INTERP_BUILD_DIR/IceCubesCheck.app"
INTERP_EXECUTABLE="$INTERP_APP/Contents/MacOS/IceCubesCheck"
# The scored screens, in capture order. ONE list: three copies drifted apart
# is how a screen ends up captured but never scored, which reads exactly like
# a screen that converged.
R2_SCREENS=(timeline status-detail account-header media tags-list media-browser
  trending-timeline trending-links instance-info display-settings
  hashtag-timeline)

# ── Latency board: the interpreted/native TIME ratio ─────────────────────────
# Every other number this script prints is FIDELITY. Until 2026-08-08 no metric,
# ratchet, gate stage or doctrine line anywhere in this repository measured TIME,
# so an interpreter that draws the timeline pixel-identically in 190 seconds
# passed every floor below, all nine function rungs and the whole close gate —
# while this stage grew into 49% of gate wall clock (2114s of the 2026-08-08
# gate) and ~85-90s more per screen admitted.
#
# WHAT IS ENFORCED IS THE AGGREGATE RATIO, NEVER ABSOLUTE SECONDS. Absolute
# seconds are load-sensitive, this machine runs many lanes at once, and load has
# already cost this project gate-hours in false reds.
#
# THE TWO SIDES DO NOT OVERLAP IN TIME, so the load term does NOT algebraically
# cancel — an earlier version of this comment claimed it did and that claim was
# simply false. The twin loop captures every pair and finishes (~50s of capture)
# before the interpreted loop starts, and the interpreted loop then runs 23-34
# minutes: the ratio divides two DISJOINT windows differing ~40x in length. What
# the denominator actually buys is weaker than cancellation, and is still the
# best instrument available here: a same-machine, same-stage, same-hour
# REFERENCE WORKLOAD — the compiled twin drawing the same screens through the
# same window server — so the number is anchored to this hardware under roughly
# this load rather than to a wall-clock constant that would red on a busy
# afternoon.
#
# The empirical case for it is stability, not algebra: the three full-board runs
# calibrated below read 42.12, 41.79 and 40.08 (a 5% spread), with twin
# per-screen sums of 24s, 24s and 25s — and the 40.08 run is the one whose own
# denominator says it was the most loaded of the three (25s, the slowest native
# side). The committed headroom is 42%, eight times that spread.
#
# THE RESIDUAL ERROR HAS A DIRECTION and only one direction is dangerous. The
# denominator is a ~50s sample while the numerator averages ~30 minutes, so a
# transient — another lane's build, a window-server stall — lands
# disproportionately on the denominator. Load INSIDE the twin window inflates
# the denominator and DEFLATES the ratio: a false GREEN, which no threshold can
# catch. A quiet twin window followed by a loaded interpreted window reads high:
# a false RED, which is what the headroom absorbs. So when this board reads
# suspiciously green, distrust the DENOMINATOR first — the marker's
# `twinSeconds` is the field to compare against the 24-25s series above.
#
# Per-screen ratios are REPORTED but deliberately NOT enforced: a twin capture
# pass is 2-3s, so one second of perturbation — one process launch landing
# behind another lane's build — is ±25-50% on that screen's ratio.
# trending-timeline reads 110.0x (220s/2s) in one of the runs calibrated below
# and 71.7x (215s/3s) in another, same tree, same day, same board: the whole
# 35% is one second on the denominator.
#
# CALIBRATION, WITH THE COMMAND THAT PRODUCES IT. Three independent full-board
# runs were still on disk on 2026-08-08, each an 11-screen gate on a machine
# under a 9-agent audit. Run from the repository root:
#
#   for c in /private/tmp/lane-gate-2f5715bc/.build/icecubes-r2-captures \
#            /private/tmp/lane-gate-755a599d/.build/icecubes-r2-captures \
#            .claude/worktrees/lane-foodtruck-run/.build/icecubes-r2-captures; do
#     (cd $c && for p in native-twin/*.png; do s=${p:t:r}
#        print -r -- "$s $(( $(stat -f %m interpreted-repeat/$s.png) \
#          - $(stat -f %m interpreted/$s.png) )) $(( \
#          $(stat -f %m native-twin-repeat/$s.png) \
#          - $(stat -f %m native-twin/$s.png) ))"
#      done | awk '{i+=$2; t+=$3} \
#        END {printf "interp %ds twin %ds ratio %.2f\n", i*2, t*2, i/t}')
#   done
#
# It reports 2022s/48s = 42.12, 2004s/50s = 40.08 and 2006s/48s = 41.79.
#
# THAT COMMAND IS A LOWER-BOUND PROXY, NOT THE INSTRUMENT THAT ENFORCES. The
# board below prices a screen with float `SECONDS` bracketing the WHOLE pair,
# from before pass 1 launches to after pass 2 exits. The command above reads
# twice the INTEGER mtime gap between a screen's two PNGs — one pass's
# write-to-write time, doubled — which excludes pass 1's launch-to-first-write
# and truncates every per-screen term to a whole second. On the numerator that
# truncation is ~1% of a 19-301s interpreted pass; on the DENOMINATOR it is ±1s
# of a 2-3s twin pass, so the proxy's error sits exactly where the ratio is most
# sensitive and a `SECONDS` reading of the same run can land tens of percent
# either side of 42.12. The proxy is what existed before any marker did.
# THEREFORE: 60.00 is deliberately loose, and IT IS TO BE RE-DERIVED FROM THE
# ENFORCING INSTRUMENT — the first real `@@icecubes-latency` marker in a gate
# receipt, whose `aggregateRatio` is the number this ceiling is actually
# compared against — in its own commit, downward only, carrying that marker.
#
# RUN-TO-RUN NOISE IS NOT WHY THIS CEILING IS LOOSE: 5% across three runs is
# nothing. The SCREEN MIX is. The same command with `[[ $s == hashtag-timeline
# ]] && continue` added — the ten screens this board scores today — reads 33.81,
# 31.86 and 31.82, so admitting ONE screen of the trending class moves the
# aggregate 25-31%. A ceiling with less headroom than that would turn admitting
# a screen into a latency RED, which is the mistake the stall detector already
# made once by summing R2_FLOORS per sha, where widening the board and
# regressing became the same signal. Against the board AS COMMITTED (ten
# screens, 31.8-33.8) the ceiling carries 1.8x; against the eleven-screen mix
# calibrated above, 1.42x.
#
# Those capture directories are gate scratch and get reaped, so the command
# above stops reproducing once they are gone. That is exactly why the board
# below prints `@@icecubes-latency` with the per-screen seconds in it — and as
# of 2026-08-08 gate.sh LIFTS BOTH LINES INTO THE RECEIPT, so the durable record
# is the receipt rather than /private/tmp: the aggregate line becomes
# `boards.iceCubesR2Latency` (matched `grep -E '^aggregate[[:space:]]+interpreted '`)
# and the marker's JSON becomes `boards.iceCubesR2LatencyDetail`. Both printf
# formats below are load-bearing for that lift: the aggregate line must begin at
# column 0 with `aggregate`, whitespace, `interpreted `, and the marker line with
# `@@icecubes-latency ` and one space before its JSON. Changing either without
# changing gate.sh leaves the gate matching nothing and reporting an empty board
# line as a shape failure that explains nothing.
#
# The bound from ABOVE is gate.sh's own deadline for this stage,
# `900 + r2_screen_count * 240` (gate.sh:168, and `r2_screen_count` is read out
# of R2_SCREENS in this file). A ceiling above that never speaks, because the
# watchdog kills the stage first and reports "timeout" while naming no screen.
# THE HONEST ARITHMETIC: 900 + 240*11 = 3540 over a 48s native side is 73.75,
# and 900 + 240*10 = 3300 over today's 42-44s native side is 75.0-78.6. (This
# comment said "~65" until 2026-08-08, which silently assumed ~400s of
# non-capture time that no command here produces.) Even 73.75 is not a tight
# bound in the useful direction: the same deadline also pays for the twin build,
# the interpreted build, the twin captures and three `xcrun swift
# Scripts/pixel-ae.swift` compiles per screen — all inside the deadline and all
# outside the ratio — so the ratio at which the watchdog really fires is LOWER
# than that quotient. 60.00 is therefore NOT derived from the deadline. It is
# 1.42x the 42.12 measurement, sized by the 25-31% screen-mix swing, and it
# happens to sit under the deadline quotient rather than being explained by it.
#
# IT RATCHETS DOWNWARD ONLY, exactly like R2_FLOORS. A faster run does not lower
# it automatically; lowering it is its own commit carrying the measurement, and
# it is never raised to excuse a regression. The one commit that may raise it is
# the commit that ADMITS A SCREEN, because that changes what is being averaged
# rather than how fast the interpreter is — and that commit states the new
# screen's own ratio and the recomputed aggregate, exactly as a new screen enters
# R2_FLOORS at its measured value.
R2_LATENCY_RATIO_CEILING=60.00

# Sub-second resolution is required, not a nicety: a twin capture pair is ~4s and
# integer SECONDS would quantize the denominator of every ratio by 25%.
typeset -F SECONDS
typeset -A R2_TWIN_SECONDS R2_INTERP_SECONDS
# WHAT THE PER-SCREEN SECONDS DO NOT BILL. A pair is priced by its LAST attempt,
# so a screen that needed three attempts is billed one pair and the stage
# actually spent up to three. The attempt index of the priced pair is therefore
# carried alongside it and reported in the marker as `interpretedAttempts` /
# `twinAttempts`, with `stageSeconds` (the whole script's wall clock, builds
# included) as the outer bound: `stageSeconds` minus interpretedSeconds minus
# twinSeconds is everything the ratio does not see. Without those fields a
# marker reading 1420s can belong to a stage that consumed 2000s+, and a
# retry-storm regression would be invisible to a board whose numbers all shrank.
typeset -A R2_TWIN_ATTEMPTS R2_INTERP_ATTEMPTS
typeset -F LATENCY_INTERP_TOTAL=0 LATENCY_TWIN_TOTAL=0 LATENCY_RATIO=0

# Sums both sides over the screens named in $@ and divides ONCE. The aggregate is
# total/total and deliberately NOT the mean of the per-screen ratios: an
# unweighted mean lets a 4-second screen outvote the 600-second one that actually
# costs the gate its wall clock, and the per-screen numbers are the noisy ones.
latency_totals() {
  local screen
  LATENCY_INTERP_TOTAL=0
  LATENCY_TWIN_TOTAL=0
  LATENCY_RATIO=0
  for screen in "$@"; do
    # A screen captured but never timed is indistinguishable from a free one —
    # the same trap the R2_SCREENS/R2_FLOORS cross-check closes for fidelity.
    if [[ -z "${R2_INTERP_SECONDS[$screen]+set}" \
      || -z "${R2_TWIN_SECONDS[$screen]+set}" ]]; then
      print -u2 "R2 latency board: '$screen' was captured but never timed"
      return 2
    fi
    (( LATENCY_INTERP_TOTAL += ${R2_INTERP_SECONDS[$screen]} ))
    (( LATENCY_TWIN_TOTAL += ${R2_TWIN_SECONDS[$screen]} ))
  done
  if (( LATENCY_TWIN_TOTAL <= 0 )); then
    print -u2 "R2 latency board: the native side totals" \
      "${LATENCY_TWIN_TOTAL}s over $# screens — refusing to divide by it"
    return 2
  fi
  (( LATENCY_RATIO = LATENCY_INTERP_TOTAL / LATENCY_TWIN_TOTAL ))
  return 0
}

# STRICTLY greater fails; equal is green, matching an AE line that reads "AT
# FLOOR" rather than red. Factored out so --self-test can exercise the
# comparison without a capture: the anti-drift ratchet was crossed by 0.045% and
# nothing noticed, so a fractional excess has to count as an excess.
latency_over_ceiling() {
  local value="$1" ceiling="$2"
  (( value > ceiling ))
}

latency_board_lines() {
  local screen interp twin
  for screen in "$@"; do
    interp="${R2_INTERP_SECONDS[$screen]}"
    twin="${R2_TWIN_SECONDS[$screen]}"
    if (( twin > 0 )); then
      printf '%s\tinterpreted %.1fs\ttwin %.1fs\tratio %.1fx\n' \
        "$screen" "$interp" "$twin" "$(( interp / twin ))"
    else
      printf '%s\tinterpreted %.1fs\ttwin %.1fs\tratio n/a\n' \
        "$screen" "$interp" "$twin"
    fi
  done
}

# Prints the aggregate line and the verdict, and RETURNS 1 when the aggregate is
# over the committed ceiling. Factored out of the board so --self-test can drive
# all three branches — over, inside, and far enough inside to be worth a ratchet
# — on synthetic totals, which is the only way to see the RED text without a
# forty-minute capture that is by construction green.
latency_verdict() {
  printf 'aggregate\tinterpreted %.1fs\ttwin %.1fs\tratio %.2fx\tceiling %.2fx\n' \
    "$LATENCY_INTERP_TOTAL" "$LATENCY_TWIN_TOTAL" "$LATENCY_RATIO" \
    "$R2_LATENCY_RATIO_CEILING"
  if latency_over_ceiling "$LATENCY_RATIO" "$R2_LATENCY_RATIO_CEILING"; then
    printf '═══ R2 latency board: OVER CEILING — interpreted is %.2fx native > %.2fx ═══\n' \
      "$LATENCY_RATIO" "$R2_LATENCY_RATIO_CEILING"
    print -r -- "═══ Answer it by making the interpreter faster, or by naming" \
      "the screen that grew — never by raising the ceiling, which moves DOWN" \
      "only, or in the commit that admits a screen ═══"
    return 1
  fi
  if (( LATENCY_RATIO * 2 < R2_LATENCY_RATIO_CEILING )); then
    # Advisory, and quiet on purpose: it asks for a ratchet only at more than 2x
    # inside the ceiling. The same-day mix swing measured 25-31% (ten screens
    # against eleven), so anything smaller than a doubling cannot be told apart
    # from the board changing shape, and a ratchet that nags every run is a
    # ratchet that gets ignored.
    printf '═══ R2 latency board: %.2fx native, more than 2x inside the %.2fx ceiling — lower it in its own commit with the measurement ═══\n' \
      "$LATENCY_RATIO" "$R2_LATENCY_RATIO_CEILING"
    return 0
  fi
  printf '═══ R2 latency board: interpreted is %.2fx native, ceiling %.2fx ═══\n' \
    "$LATENCY_RATIO" "$R2_LATENCY_RATIO_CEILING"
  return 0
}

# One machine-readable line the gate lifts into its receipt, in the shape
# validate-anti-drift.sh's `@@anti-drift {...}` established. It carries the
# PER-SCREEN numbers as well as the aggregate, because the aggregate alone
# cannot answer "which screen got slower" a week later, and no other artifact
# outlives the run: the captures are deleted with the gate's scratch directory.
latency_marker() {
  local screen sep="" per_screen="" interp twin ratio
  local interp_s twin_s ratio_s interp_attempts twin_attempts
  integer retried=0
  for screen in "$@"; do
    interp="${R2_INTERP_SECONDS[$screen]}"
    twin="${R2_TWIN_SECONDS[$screen]}"
    # The attempt the priced pair came from. A retried screen is billed ONE
    # pair — the last one — so without this the marker cannot distinguish a
    # stage that captured cleanly from one that paid for the same screen three
    # times, and `stageSeconds` below is the only place that time appears.
    interp_attempts="${R2_INTERP_ATTEMPTS[$screen]:-1}"
    twin_attempts="${R2_TWIN_ATTEMPTS[$screen]:-1}"
    if (( interp_attempts > 1 || twin_attempts > 1 )); then
      (( retried += 1 ))
    fi
    ratio=0
    if (( twin > 0 )); then
      (( ratio = interp / twin ))
    fi
    printf -v interp_s '%.1f' "$interp"
    printf -v twin_s '%.1f' "$twin"
    printf -v ratio_s '%.2f' "$ratio"
    per_screen+="$sep\"$screen\":{\"interpretedSeconds\":$interp_s"
    per_screen+=",\"twinSeconds\":$twin_s,\"ratio\":$ratio_s"
    per_screen+=",\"interpretedAttempts\":$interp_attempts"
    per_screen+=",\"twinAttempts\":$twin_attempts}"
    sep=","
  done
  printf '@@icecubes-latency {"version":2,"screens":%d,"capturesPerSide":%d' \
    "$#" "$(( $# * 2 ))"
  printf ',"interpretedSeconds":%.1f,"twinSeconds":%.1f' \
    "$LATENCY_INTERP_TOTAL" "$LATENCY_TWIN_TOTAL"
  printf ',"aggregateRatio":%.2f,"ratioCeiling":%.2f,"violation":%d' \
    "$LATENCY_RATIO" "$R2_LATENCY_RATIO_CEILING" "${latency_red:-0}"
  # `SECONDS` is elapsed since this script started, so stageSeconds prices
  # EVERYTHING the ratio excludes: both builds, every retried attempt, and the
  # three `xcrun swift Scripts/pixel-ae.swift` compiles each screen pays (twin
  # repeat, interpreted repeat, and the cross comparison). It is
  # reported, never enforced — it is the load-sensitive absolute this board
  # exists to avoid ratcheting on — but it is what makes "the marker says 1420s
  # and the stage took 2000s" answerable a week later instead of arguable.
  printf ',"stageSeconds":%.1f,"retriedPairs":%d' "$SECONDS" "$retried"
  printf ',"perScreen":{%s}}\n' "$per_screen"
}

# --self-test is the only mode of this script that builds nothing and captures
# nothing, so it is the only one that is safe to run while a gate holds the
# machine. It exercises the three things a capture could never reveal: that the
# aggregate is total/total and not a mean of ratios, that the ceiling fires
# strictly above and not at, and that the marker is one line of parseable JSON
# carrying the per-screen numbers a later trend needs.
if [[ "${1:-}" == "--self-test" ]]; then
  latency_self_test_failed() { print -u2 "latency self-test: $1"; exit 1 }
  probe_screens=(cheap dear)
  R2_INTERP_SECONDS=(cheap 10.0 dear 200.0)
  R2_TWIN_SECONDS=(cheap 5.0 dear 2.0)
  latency_totals "${probe_screens[@]}" \
    || latency_self_test_failed "totals rejected well-formed input"
  (( LATENCY_INTERP_TOTAL > 209.999 && LATENCY_INTERP_TOTAL < 210.001 )) \
    || latency_self_test_failed "interpreted total is $LATENCY_INTERP_TOTAL, wanted 210"
  (( LATENCY_TWIN_TOTAL > 6.999 && LATENCY_TWIN_TOTAL < 7.001 )) \
    || latency_self_test_failed "native total is $LATENCY_TWIN_TOTAL, wanted 7"
  # 210/7 = 30. The mean of the per-screen ratios (10/5 = 2 and 200/2 = 100) is
  # 51, so this single assertion is what discriminates the weighted aggregate
  # from the unweighted one — the whole reason the board sums before dividing.
  (( LATENCY_RATIO > 29.999 && LATENCY_RATIO < 30.001 )) \
    || latency_self_test_failed "aggregate is $LATENCY_RATIO, wanted 30 (51 = mean of ratios)"
  latency_over_ceiling 30.0 30.0 \
    && latency_self_test_failed "ceiling fired on a value exactly at it"
  latency_over_ceiling 29.99 30.0 \
    && latency_self_test_failed "ceiling fired on a value below it"
  latency_over_ceiling 30.01 30.0 \
    || latency_self_test_failed "ceiling missed a 0.03% excess"
  latency_over_ceiling 61.0 "$R2_LATENCY_RATIO_CEILING" \
    || latency_self_test_failed "the committed ceiling does not reject 61.0x"
  latency_over_ceiling 42.12 "$R2_LATENCY_RATIO_CEILING" \
    && latency_self_test_failed "the committed ceiling rejects the 2026-08-08 measurement"
  # An untimed screen must be fatal rather than free.
  unset "R2_INTERP_SECONDS[dear]"
  latency_totals "${probe_screens[@]}" 2>/dev/null \
    && latency_self_test_failed "an untimed screen was scored anyway"
  # So must a native side that did not advance: it is the divisor.
  R2_INTERP_SECONDS=(stopped 5.0)
  R2_TWIN_SECONDS=(stopped 0.0)
  latency_totals stopped 2>/dev/null \
    && latency_self_test_failed "a zero native total was divided by"
  R2_INTERP_SECONDS=(cheap 10.0 dear 200.0)
  R2_TWIN_SECONDS=(cheap 5.0 dear 2.0)
  latency_totals "${probe_screens[@]}" \
    || latency_self_test_failed "totals rejected well-formed input on retry"
  latency_red=0
  # One clean pair and one that took three attempts: the marker must say so,
  # because the seconds it prints are the LAST attempt's only.
  R2_INTERP_ATTEMPTS=(cheap 1 dear 3)
  R2_TWIN_ATTEMPTS=(cheap 1 dear 1)
  probe_marker="$(latency_marker "${probe_screens[@]}")"
  [[ "$probe_marker" == '@@icecubes-latency '* ]] \
    || latency_self_test_failed "marker lost its prefix: $probe_marker"
  # Split into an array rather than measuring the scalar: `${#${(f)x}}` on a
  # one-element result silently reports the string LENGTH, which passes any
  # "== 1" test only by accident and fails this one for the wrong reason.
  probe_marker_lines=( ${(f)probe_marker} )
  (( ${#probe_marker_lines} == 1 )) \
    || latency_self_test_failed "marker is not a single line: $probe_marker"
  # `stageSeconds` is asserted only for SHAPE and sign: it is wall clock, so
  # pinning a value here would make the self-test fail on a slow machine — the
  # ratchet-value-pinned-in-tests trap, one level down.
  print -r -- "${probe_marker#@@icecubes-latency }" | jq -e '
    .version == 2 and .screens == 2 and .capturesPerSide == 4
      and .interpretedSeconds == 210 and .twinSeconds == 7
      and .aggregateRatio == 30 and .violation == 0
      and .perScreen.cheap.ratio == 2 and .perScreen.dear.ratio == 100
      and .perScreen.dear.interpretedAttempts == 3
      and .perScreen.dear.twinAttempts == 1
      and .perScreen.cheap.interpretedAttempts == 1
      and .retriedPairs == 1
      and (.stageSeconds | type) == "number" and .stageSeconds >= 0
  ' >/dev/null || latency_self_test_failed "marker JSON is wrong: $probe_marker"
  probe_board="$(latency_board_lines "${probe_screens[@]}")"
  [[ "$probe_board" == *"dear	interpreted 200.0s	twin 2.0s	ratio 100.0x"* ]] \
    || latency_self_test_failed "board line is wrong: $probe_board"
  # All three verdict branches, against the COMMITTED ceiling rather than an
  # invented one, so a future edit to that constant is exercised here too.
  LATENCY_INTERP_TOTAL=2928.0
  LATENCY_TWIN_TOTAL=48.0
  LATENCY_RATIO=61.0
  probe_verdict="$(latency_verdict)" \
    && latency_self_test_failed "61.0x did not fail the verdict"
  [[ "$probe_verdict" == *"OVER CEILING"* ]] \
    || latency_self_test_failed "the red verdict does not say OVER CEILING: $probe_verdict"
  # The 2026-08-08 measurement itself: it must read green, and it must NOT read
  # as ratchet-ready, because the headroom it leaves is the screen-mix headroom.
  LATENCY_INTERP_TOTAL=2022.0
  LATENCY_TWIN_TOTAL=48.0
  LATENCY_RATIO=42.12
  probe_verdict="$(latency_verdict)" \
    || latency_self_test_failed "the 2026-08-08 measurement fails its own ceiling"
  [[ "$probe_verdict" == *"OVER CEILING"* ]] \
    && latency_self_test_failed "42.12x read as over the ceiling: $probe_verdict"
  [[ "$probe_verdict" == *"more than 2x inside"* ]] \
    && latency_self_test_failed "42.12x asked for a ratchet: $probe_verdict"
  [[ "$probe_verdict" == *"42.12x native, ceiling 60.00x"* ]] \
    || latency_self_test_failed "the green verdict is wrong: $probe_verdict"
  # THE LINE THE GATE ACTUALLY LIFTS, checked with the gate's own pattern
  # (gate.sh: `grep -E '^aggregate[[:space:]]+interpreted '` into "$out/r2latency").
  # A printf edit that breaks this leaves the gate reading an empty board line
  # and reporting a shape failure that names nothing, so the pin lives here
  # rather than in prose.
  print -r -- "$probe_verdict" \
    | grep -qE '^aggregate[[:space:]]+interpreted ' \
    || latency_self_test_failed \
      "the aggregate line no longer matches gate.sh's lift: $probe_verdict"
  # The board AS COMMITTED — ten screens, 33.81 on 2026-08-08 (the calibration
  # command above with hashtag-timeline skipped). It must read green and must
  # NOT ask for a ratchet: 2x inside 60.00 is 30.00, and the same-day screen-mix
  # swing between the ten- and eleven-screen boards is larger than the 3.81 that
  # separates today's reading from it.
  LATENCY_INTERP_TOTAL=1420.0
  LATENCY_TWIN_TOTAL=42.0
  LATENCY_RATIO=33.81
  probe_verdict="$(latency_verdict)" \
    || latency_self_test_failed "today's ten-screen board fails its own ceiling"
  [[ "$probe_verdict" == *"more than 2x inside"* ]] \
    && latency_self_test_failed \
      "the ten-screen board asked for a ratchet: $probe_verdict"
  # A real step change does ask for the ratchet.
  LATENCY_INTERP_TOTAL=576.0
  LATENCY_TWIN_TOTAL=48.0
  LATENCY_RATIO=12.0
  probe_verdict="$(latency_verdict)" \
    || latency_self_test_failed "12.0x failed the verdict"
  [[ "$probe_verdict" == *"more than 2x inside"* ]] \
    || latency_self_test_failed "12.0x did not ask for a ratchet: $probe_verdict"
  print "@@icecubes-latency-self-test passed"
  exit 0
fi
if (( $# > 0 )); then
  # A silently ignored flag is how a --self-test that never ran reads as a
  # passing one, so an unknown argument is refused rather than dropped.
  print -u2 "usage: Scripts/icecubes-r2.sh [--self-test]"
  exit 2
fi

# ── THE SHARED-STATE LOCK ─────────────────────────────────────────────────────
# Taken HERE: after `--self-test` and the argument refusal above, which touch
# nothing shared and so must not queue behind a running capture, and before the
# first line that writes any of the three paths this stage shares with
# Scripts/icecubes-r3.sh — the macabi scratch path (rebuilt and re-codesigned
# below), Examples/IceCubesNativeTwin/.build, and the frozen clock dylib both
# stages inject into every capture process.
#
# Until this landed the exclusion was one-sided: R3 took the lock and R2 did
# not, so R3's own comment conceded that "a concurrent R2 stage is still
# invisible here." Both boards now take the same lock at the same path, so
# whichever starts second waits or refuses instead of rebuilding a product the
# other is executing — and two capture processes can no longer race through the
# window server, which is the measured 141k-AE nondeterminism the
# reproducibility gate below exists to reject.
source "$ROOT/Scripts/icecubes-capture-lock.zsh"
# The trap is installed at TOP LEVEL, never inside the function: in zsh a `trap`
# set inside a function is scoped to it and fires on RETURN, which would release
# the lock immediately and silently.
take_shared_capture_lock "IceCubes R2" \
  "$INTERP_SCRATCH_PATH and $CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib"
trap 'release_shared_capture_lock' EXIT INT TERM

mkdir -p "$TWIN_DIR" "$INTERP_DIR" "$TWIN_REPEAT_DIR" "$INTERP_REPEAT_DIR"
for capture_dir in \
  "$TWIN_DIR" "$TWIN_REPEAT_DIR" "$INTERP_DIR" "$INTERP_REPEAT_DIR"; do
  rm -f "$capture_dir/timeline.json"
  for screen in "${R2_SCREENS[@]}"; do
    # `.tree` is cleared with the rest: a geometry dump left over from an
    # earlier run is indistinguishable from this run's, and a stale one is
    # read as evidence about the capture sitting next to it.
    rm -f "$capture_dir/$screen.png" "$capture_dir/$screen.log" \
      "$capture_dir/$screen.tree"
  done
done

echo "── native IceCubes twin ──"
(
  cd Examples/IceCubesNativeTwin || exit 2
  ./build.sh
) || exit 2

run_twin_screen() {
  local screen="$1"
  local twin_out="$2"
  (
    cd Examples/IceCubesNativeTwin || exit 2
    ICECUBES_FROZEN_NOW="$FROZEN_NOW" \
    DYLD_INSERT_LIBRARIES="$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib" \
    .build/arm64-apple-ios-macabi/debug/IceCubesNativeTwin.app/Contents/MacOS/IceCubesNativeTwin \
      --out "$twin_out" --fixtures "$FIXTURES" --screen "$screen" \
      -ApplePersistenceIgnoreState YES
  )
}

# Only a PROVEN-REPRODUCIBLE capture may be scored: each side captures twice
# and the pair must match exactly. A bounded number of fresh pairs absorbs
# transient window-server perturbation from unrelated lane activity on the
# same machine (`drawHierarchy` snapshots through the compositor); persistent
# divergence — a live animation, a settle bug — fails every attempt and exits
# loudly. The retry lives HERE, capped: never loop the script itself until a
# red goes green, and never answer this red by moving a floor.
#
# A capture process that DIES is retried by the same bounded loop rather than
# aborting the board on first sight. Measured 2026-08-03: a full gate lost the
# interpreted account-header capture to a launch-time death that wrote a
# zero-byte log, while the same screen captured cleanly 8/8 at idle and in a
# solo board run on the same binary — a transient the window server loses, not
# a divergence. Retrying cannot weaken the metric: the pair still has to match
# at AE 0 before anything is scored, so a retried capture can only produce the
# same pixels or fail again. Persistent death exhausts the attempts and exits
# loudly with the real status.
twin_reproducible=0
twin_failure="diverged"
for attempt in 1 2 3; do
  twin_diverged=0
  for screen in "${R2_SCREENS[@]}"; do
    # Timing is two reads of the shell's own clock around the pair and nothing
    # else: no `time`, no wrapper process, nothing sampling the machine while a
    # capture window is open, because this board's determinism contract is that
    # only interpreter fidelity may move the pixels. It prices the PAIR, and the
    # LAST attempt wins, so a screen retried past a transient death is priced at
    # what it costs when it works — which is deliberate for the ratio and
    # dishonest for the stage, so the attempt index rides along and the marker
    # reports it next to `stageSeconds`.
    twin_pair_started=$SECONDS
    run_twin_screen "$screen" "$TWIN_DIR"
    twin_status=$?
    if (( twin_status == 0 )); then
      run_twin_screen "$screen" "$TWIN_REPEAT_DIR"
      twin_status=$?
    fi
    R2_TWIN_SECONDS[$screen]=$(( SECONDS - twin_pair_started ))
    R2_TWIN_ATTEMPTS[$screen]=$attempt
    if (( twin_status != 0 )); then
      echo "twin $screen capture failed with status $twin_status" \
        "(attempt $attempt)" >&2
      twin_diverged=1
      twin_failure="died"
      break
    fi
    determinism_line="$(xcrun swift Scripts/pixel-ae.swift \
      "$TWIN_DIR/$screen.png" "$TWIN_REPEAT_DIR/$screen.png")"
    if (( $? != 0 )); then
      echo "twin $screen capture pair diverged (attempt $attempt: $determinism_line)"
      twin_diverged=1
      twin_failure="diverged"
      break
    fi
  done
  if (( twin_diverged == 0 )); then
    twin_reproducible=1
    break
  fi
done
if (( twin_reproducible == 0 )); then
  if [[ "$twin_failure" == died ]]; then
    echo "twin CAPTURE-DEATH: no capture survived 3 attempts —" \
      "fix the capture, not the floor" >&2
  else
    echo "twin CAPTURE-NONDETERMINISM: no reproducible capture pair in 3" \
      "attempts — fix the capture, not the floor" >&2
  fi
  exit 2
fi

# ONE FROZEN SOURCE OF WALL TIME IS NOT A FROZEN CLOCK, and the epoch check
# below cannot tell the difference. `Date()` is pinned by a dyld interposer, so
# `clockEpoch` reads the frozen instant and passes — while
# `Date.timeIntervalSinceNow` computes its own "now" INSIDE Foundation, never
# crossing an image boundary, and so kept reading the real clock. IceCubes
# renders exactly that on the settings screens (`ServerDate()` is newer than a
# day, so `relativeFormatted` takes the `Duration.seconds(-…timeIntervalSinceNow)`
# branch): the example post drew "527h" and ticked once an HOUR, with this
# script green the whole time because it only ever asked about `Date()`.
#
# Both sides now report that reading and the board refuses anything but an
# exact zero. The next unpinned wall-clock source fails an exit code here
# instead of waiting for a reviewer to notice a timestamp that looks plausible.
assert_frozen_relative_clock() {
  local label="$1" metadata="$2" key="$3"
  if ! jq -e --arg k "$key" '.[$k] == 0' "$metadata" >/dev/null; then
    echo "$label relative clock is not frozen: $key is" \
      "$(jq -r --arg k "$key" '.[$k]' "$metadata"), wanted exactly 0 — a" \
      "wall-clock source is leaking past the frozen instant" >&2
    exit 2
  fi
}

OBSERVED_CLOCK="$(jq -r '.clockEpoch' "$TWIN_DIR/timeline.json")"
if [[ "$OBSERVED_CLOCK" != "$FROZEN_NOW" ]]; then
  echo "native frozen clock mismatch: wanted $FROZEN_NOW, got $OBSERVED_CLOCK" >&2
  exit 2
fi
assert_frozen_relative_clock native "$TWIN_DIR/timeline.json" relativeClockDrift
if ! jq -e '
  .screenFixtures
  | [
      .status,
      .statusContext,
      .account,
      .featuredTags,
      .accountStatuses,
      .familiarFollowers
    ]
  | length == 6 and all(.[]; type == "string" and length > 0)
' "$TWIN_DIR/timeline.json" >/dev/null; then
  echo "native screen fixture metadata is missing or malformed" >&2
  exit 2
fi
screen_fixture_names=(
  "${(@f)$(jq -r '
    .screenFixtures
    | [
        .status,
        .statusContext,
        .account,
        .featuredTags,
        .accountStatuses,
        .familiarFollowers
      ][]
  ' "$TWIN_DIR/timeline.json")}"
)
for fixture_name in "${screen_fixture_names[@]}"; do
  if [[ ! -f "$TWIN_DIR/$fixture_name" ]]; then
    echo "native screen fixture is missing: $fixture_name" >&2
    exit 2
  fi
done

echo "── interpreted IceCubes ──"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_FRAMEWORKS="$SDK/System/iOSSupport/System/Library/Frameworks"
IOS_LIBS="$SDK/System/iOSSupport/usr/lib"
xcrun swift build \
  --scratch-path "$INTERP_SCRATCH_PATH" \
  --product IceCubesCheck \
  --triple arm64-apple-ios18.0-macabi \
  -Xcc -target -Xcc arm64-apple-ios18.0-macabi \
  -Xswiftc -target -Xswiftc arm64-apple-ios18.0-macabi \
  -Xswiftc -F -Xswiftc "$IOS_FRAMEWORKS" \
  -Xswiftc -I -Xswiftc "$IOS_LIBS/swift" \
  -Xlinker -F -Xlinker "$IOS_FRAMEWORKS" \
  -Xlinker -L -Xlinker "$IOS_LIBS" || exit 2
mkdir -p "$INTERP_APP/Contents/MacOS"
cp "$INTERP_BINARY" "$INTERP_EXECUTABLE"
cp "$ROOT/Scripts/IceCubesCheck-Info.plist" \
  "$INTERP_APP/Contents/Info.plist"
codesign --force --sign - "$INTERP_APP" >/dev/null || exit 2

capture_interpreted_screen() {
  local screen="$1"
  local out_dir="$2"
  local native_args=()
  # Mirrors IceCubesCaptureScreen.needsNativeFixtures: only the screens the
  # TWIN chose a status and prepared endpoints for read its output directory.
  # Stated as the SHORT side of that split — the screens that DO need them —
  # so adding a screen built from the checked-in recordings cannot silently
  # drift this condition away from the Swift enum.
  if [[ "$screen" == status-detail || "$screen" == account-header ]]; then
    native_args=(--native-fixtures "$TWIN_DIR")
  fi
  ICECUBES_FROZEN_NOW="$FROZEN_NOW" \
  SWIFT_DETERMINISTIC_HASHING=1 \
  DYLD_INSERT_LIBRARIES="$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib" \
  "$INTERP_EXECUTABLE" --capture "$out_dir" --screen "$screen" \
    "${native_args[@]}" -ApplePersistenceIgnoreState YES \
    > "$out_dir/$screen.log" 2>&1
}

# Captures run STRICTLY SERIALLY. Measured 2026-07-30: three parallel capture
# processes contend for the window server, `drawHierarchy` takes a different
# snapshot path per run, and two passes of the same binary on the same
# fixtures differ by 141k+ AE (±1-per-channel wobble plus spinner phase);
# serialized, four consecutive captures are pixel-exact. Do not restore the
# `&` fan-out without also proving the reproducibility gate below stays green.
capture_reproducible_interpreted_screen() {
  local screen="$1"
  local attempt determinism_line capture_status
  local failure="diverged"
  for attempt in 1 2 3; do
    local capture_died=0
    # Same two clock reads as the twin side, closed BEFORE the comparison below:
    # `xcrun swift Scripts/pixel-ae.swift` is a compile as well as a run, and
    # charging the interpreter for the comparator would inflate exactly the side
    # the ratio is asking about.
    local pair_started=$SECONDS
    for interp_out in "$INTERP_DIR" "$INTERP_REPEAT_DIR"; do
      capture_interpreted_screen "$screen" "$interp_out"
      capture_status=$?
      if (( capture_status != 0 )); then
        cat "$interp_out/$screen.log"
        echo "interpreted $screen capture failed with status" \
          "$capture_status (attempt $attempt)" >&2
        capture_died=1
        failure="died"
        break
      fi
    done
    if (( capture_died )); then
      continue
    fi
    R2_INTERP_SECONDS[$screen]=$(( SECONDS - pair_started ))
    # Same LAST-attempt-wins pricing as the twin side, and the same correction:
    # a screen that died twice before this pair is billed one pair, so the
    # attempt it was billed from is carried into the marker.
    R2_INTERP_ATTEMPTS[$screen]=$attempt
    determinism_line="$(xcrun swift Scripts/pixel-ae.swift \
      "$INTERP_DIR/$screen.png" "$INTERP_REPEAT_DIR/$screen.png")"
    if (( $? == 0 )); then
      return 0
    fi
    failure="diverged"
    echo "interpreted $screen capture pair diverged (attempt $attempt: $determinism_line)"
  done
  if [[ "$failure" == died ]]; then
    echo "interpreted $screen CAPTURE-DEATH: no capture survived 3" \
      "attempts — fix the capture, not the floor" >&2
  else
    echo "interpreted $screen CAPTURE-NONDETERMINISM: no reproducible capture" \
      "pair in 3 attempts — fix the capture, not the floor" >&2
  fi
  exit 2
}

for screen in "${R2_SCREENS[@]}"; do
  capture_reproducible_interpreted_screen "$screen"
  cat "$INTERP_DIR/$screen.log"
done

INTERP_OBSERVED_CLOCK="$(jq -r '.interpretedClockEpoch' "$INTERP_DIR/timeline.json")"
if [[ "$INTERP_OBSERVED_CLOCK" != "$FROZEN_NOW" ]]; then
  echo "interpreted frozen clock mismatch: wanted $FROZEN_NOW, got $INTERP_OBSERVED_CLOCK" >&2
  exit 2
fi
assert_frozen_relative_clock interpreted "$INTERP_DIR/timeline.json" \
  interpretedRelativeClockDrift

echo "── R2 AE board ──"
# Ratchet floors — enforced, committed baselines (AUDIT-2026-07-23-R2-stall.md
# rec #2, mirroring Scripts/foodtruck-r3.sh). The timeline remains the LOOP R2
# metric and exact at zero. Every other screen is measured independently so a
# green timeline cannot hide regressions or unmeasured screen gaps — and their
# SUM is the pixel half of the north star (LOOP-ICECUBES §13), so the honest
# way to keep it meaningful once the scored screens converge is to score the
# app's next screen, not to read three zeroes as a finished app.
typeset -A R2_FLOORS
R2_FLOORS=(
  timeline 0
  status-detail 0
  account-header 0
  media 0
  # Was 4. Two of those pixels were never interpreter fidelity: they were the
  # twin encoding its capture as Display P3 16-bit while IceCubesCheck encoded
  # sRGB 8-bit, so one side dithered a flat fill the other represented exactly.
  # Both sides now pin `preferredRange`, and the comparator refuses to score a
  # pair that disagrees on its encoding.
  #
  # THE REMAINING 2 ARE CLASSIFIED, AND NO RENDERER FIX IS OWED — recorded here
  # so they are not re-distilled a third time. `Scripts/pixel-diff-map.swift`
  # over a reproducible pair (each side AE 0 against its own repeat) reports:
  # two spatially separate 1x1 clusters, x 860 y 627 and x 857 y 638; MAGNITUDE
  # max 1 mean 1.00 of 255; EDGE 2 of 2 differing px sit on a twin edge and 0 in
  # any flat region; CHANNELS 0 neutral, 2 channel-skewed. Both sides therefore
  # drew the SAME shapes in the SAME places in the SAME colours and rounded the
  # antialiased coverage blend one level apart on two pixels. That is the
  # EDGE-BLEND class the map's own header warns is not distillable: an
  # in-process bitmap micro-twin compares rendered output and so cannot express
  # a compositing rounding difference at all. Reading it as a content
  # divergence is how a converged screen gets re-distilled with nothing to
  # find. This floor stays at 2 until the comparator's rasterization question
  # is answered, and it is NOT evidence of an interpreter gap.
  tags-list 2
  # ACKNOWLEDGED tags-list: two pixels of an anti-aliased edge blend, owing no
  # renderer fix — both sides draw the same edge and differ only in how the
  # compositor rounded one sub-pixel pair. The marker exempts this screen from
  # the STALL series ONLY; the floor above is still enforced, so it cannot
  # regress, and the headline still prints it. Delete this line to re-arm the
  # detector on this screen.
  # Was 367681 — the whole image block, behind a UIKit hosting stack that
  # stopped at a different statement every iteration (representable
  # conformance, then the generic hosting controller, then `.view`'s
  # optionality, then `autoresizingMask`, then `addSubview`). The last link was
  # not in that chain at all: an SDK parameter spelled `any View` refused every
  # value SwiftUI builds, so `UIHostingController(rootView:)` fell to its
  # payload-less stub and `.view` handed `addSubview` a typed inert `UIView`.
  # With a native view answering the View existential it satisfies, the image
  # draws and the cliff pays out.
  #
  # Was 18929 — the surrounding container, absorbed from `.scrollPosition(id:)`,
  # whose interface declares `Binding<(some Hashable)?>`: an opaque parameter
  # written IN PLACE inside a compound type, a third spelling BridgeGen
  # specialized in neither of its two paths. Now specialized like the named
  # generic it is sugar for, onto the carrier the wrapper projections already
  # drive.
  #
  # Was 1136 — `MediaUIShareLink`'s `ShareLink(item:preview:)`. ONE failure
  # that read as three: `Scripts/pixel-diff-map.swift` put the 1136 AE in three
  # 25x23 boxes, and the first two were pure ~3px SHIFTS of correct glyphs,
  # because toolbar items are trailing-aligned and the failing button's wrong
  # width displaced its neighbours. Two links: `SharePreview<Image, Icon>` is a
  # compound over TWO constrained generics, which BridgeGen had no spelling
  # for; and once `preview:` was typed at an instantiation, the leading-dot
  # `.init(…)` looked that whole spelling up in a table keyed by nominal.
  #
  # The other diagnostic this screen still prints is NOT a pixel: an absorbed
  # `.quickLookPreview` leaves its receiver rendering, and the info button it
  # decorates is byte-identical on both sides. It was named as a blocker by
  # prose; the pixels acquit it.
  media-browser 0
  # NEW SCREEN, entering at its first measured value — this is a measurement
  # that did not exist before, not a regression of one that did. The six
  # screens above are unchanged (2 AE, all of it tags-list).
  #
  # Why it is worth scoring: every timeline pixel already on this board comes
  # from a harness `StatusesFetcher` handed decoded fixture statuses, on BOTH
  # sides. The app's own `TimelineView` over its own `TimelineViewModel` — the
  # fetch, the state machine, the datasource, the toolbar — had never been
  # compared to the twin at all. `RouterDestination.trendingTimeline` is the
  # one spelling of it the unauthenticated app can drive end to end
  # (`Trends.statuses` is public, and `isCacheEnabled` is false on all three
  # of its terms, so nothing touches disk).
  #
  # What the number is made of, RE-MEASURED on this tree rather than carried
  # over. The screen's history is three states, and only the last one is a
  # floor: one error label at 389990 until `ToolbarSpacer` became constructible
  # (d10c6838); then the app's real view model stuck in `.loading` — redacted
  # placeholder rows against the twin's recorded statuses — at 461250; then
  # 1761, once `d4cf821a` made a model held as `@State` invalidate its view
  # (`TimelineView.viewModel` is exactly that spelling), which is the
  # Client-actor fetch class this loop's capability queue put first, running
  # end to end for the first time.
  #
  # It enters at 1761 and not at the `.loading` number because 461250 was
  # measured BEFORE `9b3afeb1`, when both readiness loops expired on a fixed
  # 30s total budget: this screen's capture legitimately stalls ~181s inside
  # interpreted `HTMLString.init(from:)`, so the frame was read mid-`.loading`.
  # Bounding readiness by lack of progress instead lets it settle. Scoring the
  # older number would enshrine ~459k AE of debt that no longer exists and then
  # read its removal as progress.
  #
  # Was 1761 — ONE 140x33 box at the navigation title. The twin drew TWO lines
  # there and the interpreter drew only the first, so 1296 AE was the missing
  # `Text(client.server)` and the other 465 was the surviving line sitting
  # ~1-2px low, because a one-child VStack centers where a two-child one does
  # not: one defect plus its displacement, not two bugs.
  #
  # `TimelineToolbarTitleView` is a `ToolbarContent` conformer, NOT a View. A
  # View's `@Environment` properties are filled by the host that renders it
  # (`InterpretedView`); a non-View result-builder conformer has no such host,
  # so `@Environment(MastodonClient.self)` stayed unset and `client.server`
  # read off `()`. The conformer now sees the environment its enclosing body
  # saw. The competing hypothesis — a ViewBuilder switch case yielding MULTIPLE
  # views rendering only the first — was REFUTED by the repro rather than
  # argued away: its headline expectation passes with the fix stashed.
  trending-timeline 0
  # NEW SCREEN, entering at its first measured value — a measurement that did
  # not exist before, not a regression of one that did. The seven screens above
  # are unchanged (2 AE, all of it tags-list).
  #
  # Why it is worth scoring: every row this board has ever compared is a
  # status, an account or a tag. `StatusRowCardView` — the app's link preview,
  # with its own reserved image frame, provider line, title, author byline and
  # people-talking chip — had no pixels on the board at all, on either side.
  # `RouterDestination.trendingLinks` is the route, and `Trends.links` is
  # public and unauthenticated, so the screen is drivable end to end from a
  # recording (10 cards).
  #
  # IT ENTERS AT 0, and that is stated plainly rather than dressed up: this
  # screen decomposes nothing and discharges no debt. It is regression
  # coverage for a row type that had none, not a repair. What it does buy is
  # an answer to a question the board could not previously ask — whether the
  # card row's reserved image frame, its title/description line breaking and
  # its provider byline match the compiled app — and the answer is that they
  # already did. A screen admitted at 0 is only worth its capture time because
  # it can go RED later; it is not evidence of progress this iteration.
  #
  # It also costs no requests: ten cards overflow the 900x700 canvas, so the
  # view's own `NextPageView` footer never appears and never fetches. That is
  # what keeps the pulse animation on that footer out of the capture, and it
  # is why this screen is reproducible rather than merely lucky — verified
  # twin-vs-twin and interp-vs-interp at AE 0 before being scored.
  trending-links 0
  # NEW SCREEN, entering at its first measured value — a measurement that did
  # not exist before, not a regression of one that did. The eight screens
  # above are unchanged (2 AE, all of it tags-list).
  #
  # It is the first scored screen declared in the app TARGET rather than in a
  # package, and admitting it is the point of the iteration: the twin
  # depended only on `Packages/*`, so all 36 of the app's own files — 30 of
  # them declaring View types — were uncompilable by it and therefore
  # unscorable FOREVER, no matter how many package screens were admitted.
  # Eight screens at ~0 AE read as a converged app while an entire region of
  # the codebase had never been compared at all: `scored-subset-reads-as-
  # converged` one level up, a subset of the CODEBASE rather than of screens.
  #
  # It entered at 143467 as the honest first measurement of that region. Both
  # sides are proven reproducible at AE 0 before scoring (twin-vs-twin and
  # interp-vs-interp), so every number here is interpreter debt, never capture
  # noise. That 143467 was characterized as two independent classes, and the
  # dominant one is now DISCHARGED:
  #
  # (1) 143082 AE, FIXED. Section structure did not survive an interpreted view
  #     boundary. The `Form` gateway REBUILT the `SectionSpec`s it recognised
  #     and wrapped everything else in one implicit anonymous `Section` — but
  #     it inspected only its OWN direct builder output, so a section arriving
  #     by any other route landed inside that wrapper and NESTED. The app
  #     writes `Form { InstanceInfoSection(instance:) }` and that view's body
  #     vends the Sections one level down, so their headers rendered as
  #     ordinary rows inside a single box instead of as headers above two, and
  #     everything below shifted — one structural defect plus its displacement,
  #     which is what made the number large.
  #
  #     The premise the rebuild rested on was measured and REFUTED rather than
  #     patched around: natively, a grouped `Form` boxes an `AnyView`-erased
  #     Section, one vended through a custom view's body, one inside an indexed
  #     `ForEach` and one carrying a row modifier all identically to a section
  #     written directly in its builder. `AnyView` erasure never hid section
  #     structure from a `Form`. So the fix is subtractive — `Form` now emits
  #     straight through `builderContent` exactly like `List`, and `anyView` is
  #     the single place a `SectionSpec` becomes a real `Section`. A per-
  #     container special case was DELETED, not another one added.
  #     Pinned by `Tests/SwiftUIBridgeTests/FormSectionBoundaryMicroTwinTests
  #     .swift`, six macOS micro-twins: three routes to the defect (across a
  #     view boundary, through an erased modifier receiver, both at once) each
  #     RED at ~30602 AE with the fix stashed, plus two counter-direction pins
  #     that keep loose rows grouped now that nothing wraps them implicitly.
  #
  # (2) Was 385 — a single 41x15 cluster at x 343...383 y 660...674, where the
  #     contact row's follower count read "874,788" against native's "875K".
  #     An interpolation segment carrying a `format:` argument lost its style:
  #     `LiteralEvaluator` recognised exactly one labeled interpolation,
  #     `specifier:`, so `.number.notation(.compactName)` was evaluated and
  #     discarded and the value fell back to its `_FormatSpecifiable` reading.
  #     The style is an SDK generic the interpreter cannot build, so it now
  #     rides UNRESOLVED to the host and renders at the one seam every
  #     generated localization-key position already flows through
  #     (`CallArguments.readingLocalizationKeys`) — fixing `Text` alone would
  #     have been a per-API special case. Which style a leading-dot chain
  #     denotes is not tabulated: candidates are read out of the generated
  #     `format:` parameter types and `FormatInput` selects among them, the
  #     same constraint the SDK's own `appendInterpolation` declares.
  #     Pinned by `Tests/SwiftUIBridgeTests/LocalizedInterpolationTests.swift`,
  #     five interpreted-vs-native observables driven RED with Sources/ stashed
  #     (954, 769, 937, 1421, 1558 AE) plus four native-vs-native controls, so
  #     none can pass by drawing nothing.
  #
  # One harness property to keep in mind when reading the capture: the app
  # target's own `.xcstrings` is not in either side's bundle, so app-declared
  # LocalizedStringKeys render as raw keys ("instance.info.name") on BOTH
  # sides. That is a substitution shared by the two sides, exactly like the
  # deterministic placeholder PNG standing in for remote images — it does not
  # affect the diff, but it does mean this screen measures the app's Form
  # layout and typography rather than its localized copy.
  instance-info 0
  # ENTERING THE BOARD at its MEASURED value, never at a placeholder. The app's
  # own `DisplaySettingsView`, and the first scored screen built from the
  # ENVIRONMENT rather than from recorded bytes — it reads no fixture at all.
  #
  # What it actually puts pixels on, stated from the capture rather than from
  # the file: the viewport holds the `ZStack`'s example-post card over the top
  # of a grouped `Form`, then the theme section — a `Toggle`, a `NavigationLink`
  # row with a trailing value, and four `ColorPicker`s in their disabled and
  # dimmed state — its conditional FOOTER, and the next section's header. The
  # `Slider`s and nine `Picker`s below the fold are built but not drawn, so this
  # screen scores section chrome, control rendering and a gradient-masked
  # overlay; it does not yet score a picker's selected case or a slider's knob.
  #
  # It is the screen that found both structural classes landed alongside it, and
  # both were invisible everywhere else on the board: a `Section` footer that
  # was never read (its section is the only one on the board written with one),
  # and a sectioned collection whose content opened on a loose row. 82806 -> 439.
  #
  # Was 439 — one 51x17 box at x 808...858 y 200...216, 100% channel-neutral,
  # entirely the relative timestamp in the example post's corner: the twin drew
  # "2m" and the interpreter drew nothing after the separator dot, with the
  # card, the Form, the sections and every control around it byte-identical. A
  # `ServerDate()` relative-format class, not a layout one, and the localized
  # residue read correctly — the fix was exactly where the box said it was.
  #
  # `ServerDate.relativeFormatted` is
  # `Duration.seconds(-date.timeIntervalSinceNow).formatted(.units(...))`, and
  # the receiver could not be BUILT: the interface sweep collected a type's
  # static STORAGE but not its static FUNCS, so `Duration.zero` existed and
  # `Duration.seconds(100)` did not. The value stayed an unresolved leading-dot
  # marker and `.formatted(...)` absorbed into a chain that renders as nothing.
  #
  # Three layers, each with its own repro: the generator collects the
  # call-shaped statics (bounded by the format family's own declared
  # `FormatInput`, not a name list); the bridge builds a real `Duration` where
  # it served a marker, with both clock readers taking the named spelling
  # counter-directionally; and member access consults the argument-selected
  # host bridge before absorbing, since `formatted` is generic over its style
  # and no per-receiver table declares it. Decomposed away from this
  # whole-screen AE by `namedDurationTimestampDrawsItsFormattedText`, which
  # measures the timestamp alone at AE 112 -> 0.
  #
  # Admitting it also forced the board's third determinism input, after the
  # frozen clock and the frozen network: `Theme` and `UserPreferences` are
  # `@AppStorage`, and this screen WRITES them back from six `.task(id:)`
  # blocks. Before both processes pinned the persistent domain, capture 1
  # differed from capture 2 by 232148 AE and captures 2, 3 and 4 then agreed —
  # a screen that was a pure function of run history and that this script's
  # own reproducibility gate would have certified, since that gate compares
  # each side only against itself.
  display-settings 0
  # Measured on the tree that admits it, never guessed. The screen first
  # captured at 104326 against this same twin; the two commits below it in
  # this lane (a scalar's type identity, then an array annotation's element
  # deciding the overload) took it to 4073 before it was ever scored, so the
  # floor it enters at is the post-fix number.
  #
  # It entered at 4073, which `Scripts/pixel-diff-map.swift` split into TWO
  # divergences at the row-1/row-2 boundary. One is now DISCHARGED:
  #
  # Was 1733 — the `status.row.is-thread` label, drawn 8pt left of the twin on
  # every scanline. `StatusRowView.swift:74` pads that group by
  # `AvatarView.FrameConfig.status.width + .statusColumnsSpacing`, and the
  # leading-dot operand absorbed, so the interpreter padded by the bare 48.
  # The avatar (48 wide) and `HStack(spacing: .statusColumnsSpacing)` (8) were
  # both already correct on the same rows, which is what said the defect was
  # the OPERAND POSITION rather than the static, the constant or the
  # `#if targetEnvironment(macCatalyst)` branch. Pinned by
  # `Tests/SwiftInterpreterTests/OperandContextualImplicitMemberTests.swift`.
  #
  # The separator that was left (2340 AE) is GONE, and the cause was never the
  # separator: `StatusesListView.swift:129` sets the trailing guide to
  # `viewDimensions.width + 100`, and `ViewDimensions` exposed ONLY its
  # alignment subscript to interpreted code, so the property read had no route
  # at all. The guide resolved at 100 instead of 960 — the twin's own tree
  # gives `w=1060` against the interpreter's `w=200`, a difference of exactly
  # the 860pt row width.
  #
  # READING THAT AS A SEPARATOR BUG IS WHAT COST THE PREVIOUS THREE FRAMINGS.
  # The same unresolved read is also why the operand-typing commit that landed
  # just before this one drove this screen to 205,515 AE: with `.width`
  # answering nothing, `viewDimensions.width + 100` became an unresolved
  # operand, and the whole `TimelineTagHeaderView` band (900x85 at y=115) went
  # missing, displacing every row under it. One capability gap, two very
  # different-looking screens. Pinned by
  # `IceCubesMicroTwinTests.alignmentGuideReadsItsViewDimensionsWidth`
  # (RED 2400 -> GREEN 0).
  hashtag-timeline 0
)
# A screen captured but unscored is indistinguishable from a screen that
# converged, so the two lists must name exactly the same screens.
for screen in "${R2_SCREENS[@]}"; do
  if [[ -z "${R2_FLOORS[$screen]+set}" ]]; then
    echo "R2 board: '$screen' is captured but carries no floor" >&2
    exit 2
  fi
done
for screen in "${(@k)R2_FLOORS}"; do
  if (( ! ${R2_SCREENS[(Ie)$screen]} )); then
    echo "R2 board: '$screen' carries a floor but is never captured" >&2
    exit 2
  fi
done
typeset -A R2_AE_LINES
board_red=0
board_below=0

for screen in "${R2_SCREENS[@]}"; do
  ae_line="$(xcrun swift Scripts/pixel-ae.swift \
    "$TWIN_DIR/$screen.png" "$INTERP_DIR/$screen.png")"
  ae_status=$?
  if (( ae_status == 2 )); then
    echo "$screen R2 board: pixel comparison failed —" \
      "$ae_line (size/format mismatch or unreadable capture)" >&2
    exit 2
  fi
  ae_count="$(print -r -- "$ae_line" | sed -E 's/^AE ([0-9]+) of .*/\1/')"
  if [[ ! "$ae_count" == <-> ]]; then
    echo "$screen R2 board: could not parse AE count from '$ae_line'" >&2
    exit 2
  fi
  R2_AE_LINES[$screen]="$ae_line"
  floor="${R2_FLOORS[$screen]}"
  print -r -- "$screen"$'\t'"$ae_line"$'\t'"floor=$floor"
  if (( ae_count > floor )); then
    echo "═══ $screen R2 board: OVER FLOOR — AE $ae_count > $floor (regression) ═══"
    board_red=1
  elif (( ae_count < floor )); then
    echo "═══ $screen R2 board: BELOW FLOOR — ratchet $floor to $ae_count in this commit ═══"
    board_below=1
  else
    echo "═══ $screen R2 board: AT FLOOR — AE $ae_count == $floor ═══"
  fi
done

# PRINTED BEFORE THE LATENCY BOARD, and that order is load-bearing. gate.sh
# lifts this stage's official metric with `grep '^AE [0-9]* of 630000 ' | tail -1`
# into "$out/r2", and an empty "$out/r2" reds the gate as a BOARD CONTRACT
# failure that names no screen and explains nothing. The latency board can exit 2
# on its own integrity checks (an untimed screen, a native side that did not
# advance), and while that stage-level failure is real, it must not also destroy
# the AE half's answer on its way out: the pixels were already measured and the
# gate should be told what they said. `tail -1` makes the position free — no
# later line in this script starts with `AE `, so moving it up costs nothing.
print -r -- "${R2_AE_LINES[timeline]}"

echo "── R2 latency board ──"
# Reported per screen, ENFORCED only in aggregate — see R2_LATENCY_RATIO_CEILING
# for why the per-screen numbers are too quantized to ratchet on.
if ! latency_totals "${R2_SCREENS[@]}"; then
  # Exit 2, not 1: this is the board failing to be SCORABLE, not the interpreter
  # failing a ratchet — the same distinction the capture-death path draws.
  echo "═══ R2 RED: the AE board above completed; the LATENCY board could not be" \
    "scored at all (reason on the line above) — this is a board integrity" \
    "failure, not a latency regression ═══" >&2
  exit 2
fi
latency_board_lines "${R2_SCREENS[@]}"
latency_red=0
latency_verdict || latency_red=1
# Emitted on red runs too: the captures die with the gate's scratch directory,
# so this line is the only durable record of where the time went.
latency_marker "${R2_SCREENS[@]}"

if (( board_red != 0 || latency_red != 0 )); then
  # Two boards now share one exit code, and a red whose cause is misread costs
  # this project days, so the last line says which one failed rather than
  # leaving it to be inferred from a tail.
  if (( board_red != 0 && latency_red != 0 )); then
    echo "═══ R2 RED: a screen is over its AE floor AND the board is over its" \
      "latency ceiling ═══"
  elif (( latency_red != 0 )); then
    echo "═══ R2 RED: every AE floor holds — the LATENCY ceiling is what" \
      "failed; the pixels are right and they cost too much ═══"
  fi
  exit 1
fi
if (( board_below != 0 )); then
  echo "═══ R2 board: GREEN below at least one floor; commit the tighter floor ═══"
  exit 0
fi
echo "═══ R2 board: GREEN at all floors ═══"
exit 0
