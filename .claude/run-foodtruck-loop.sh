#!/bin/zsh
# Ralph runner for lane-foodtruck-run: one LOOP-ICECUBES.md iteration per
# claude invocation, forever. Started by .claude/resume-foodtruck-loop.sh,
# which runs it in its own agterm session.
#
#   pause:  touch /tmp/lane-foodtruck-loop/stop
#           The flag is read at the ITERATION BOUNDARY, so the in-flight
#           iteration finishes and commits first - nothing is cut mid-work. It
#           is also read every LOOP_TICK_SECONDS during EVERY wait this script
#           can enter - the gate wait, the session-limit wait, and the ordinary
#           inter-iteration pause - so a pause during a wait takes effect in
#           seconds rather than hours. There is deliberately no plain `sleep`
#           left outside responsive_sleep()/wait_for_gate(): the terminal
#           inter-iteration `sleep 60` used to be one, and a pause set inside
#           that window was not honoured until a whole further iteration (30+
#           minutes) had run.
#           Killing the session instead SIGHUPs claude wherever it happens to
#           be. resume clears the flag, so a stale one never blocks a restart.
#
# EDITING THIS FILE WHILE IT RUNS: zsh reads a script incrementally from its
# file offset, so an in-place edit makes the RUNNING loop execute a splice of
# old and new bytes. Write the new text elsewhere and `mv` it over this path -
# the rename leaves the running shell on a stable inode and the new text is
# picked up at the next launch (resume-foodtruck-loop.sh).
set -u
# `claude` lives in ~/.local/bin, which .zshrc adds - so an agterm --command
# session, a login-but-not-interactive `zsh -lc`, launchd or cron all start
# without it. Put it back here so the runner works whoever launched it.
export PATH="$HOME/.local/bin:$PATH"
# TWO different trees, and confusing them makes an assertion vacuous.
#   REPO             - this machine's steward checkout. Only the RUN path may
#                      use it: the lane worktree to cd into and the reaper to
#                      invoke both legitimately target this machine.
#   TREE_UNDER_TEST  - the checkout this very file was read from, derived from
#                      $0. Every cross-file ASSERTION must read this one. The
#                      closing gate runs --self-test from a clean-detached
#                      candidate checkout somewhere else entirely; an assertion
#                      that reached back into $REPO would be checking the
#                      steward's copy of the other file and would pass no
#                      matter what the candidate contained.
REPO=/Users/mike/src/tries/2026-07-08-swiftui-dynamic
TREE_UNDER_TEST="${0:A:h:h}"
LANE="$REPO/.claude/worktrees/lane-foodtruck-run"
LOG_DIR=/tmp/lane-foodtruck-loop
STOP_FLAG="$LOG_DIR/stop"
MODEL="${LOOP_MODEL:-claude-opus-5}"
EFFORT="${LOOP_EFFORT:-xhigh}"
mkdir -p "$LOG_DIR"
if ! cd "$LANE"; then
  # --self-test and --print (defined below) are hermetic on purpose: the
  # closing gate runs them from a clean-detached checkout that has no business
  # depending on the lane worktree still existing. Only an actual run needs it.
  case "${1:-}" in --self-test|--print) ;; *) exit 2 ;; esac
fi

# ── waiting constants ─────────────────────────────────────────────────────────
# Every number below is one of exactly two kinds, and each says which it is:
#   MEASURED  - it names the command that produced it and the literal reading
#               that command gave on 2026-08-08 on this machine. Re-run the
#               command before moving one.
#   SAFETY BOUND - it is not measured and no command produces it. It exists so
#               that a wrong parse cannot park the loop for an unbounded time.
#               A number with no measurement behind it must say so out loud;
#               "looks measured but isn't" is the failure AGENTS.md safeguard 4
#               is about.
# Where a constant's reading comes from files that are machine-local and swept
# (gate receipts, iteration logs), the comment says the command is a
# RE-MEASUREMENT RECIPE, not a reproducible derivation - running it on a fresh
# checkout returns nothing, and nothing is not a refutation of the sample.

# Granularity of every wait: how long the runner sleeps before re-checking the
# stop flag, the gate pid, or the clock. Kept at or under 30s because
# Scripts/loop-dashboard.py:114 (`if seconds is not None and seconds > 30`)
# attributes ANY runner child older than 30s to "the iteration in flight" - a
# longer sleep slice would make the dashboard report a waiting loop as working.
# MEASURED, and re-read from the tree under test by --self-test rather than
# restated here:
#   grep -n 'seconds > 30' Scripts/loop-dashboard.py
LOOP_TICK_SECONDS=25

# How often a wait says it is still waiting, in the same `=== ... ===` line
# style the dashboard and the audits read. A multiple of the tick, so the
# modulo below lands exactly.
WAIT_HEARTBEAT_SECONDS=300

# DEFECT 2 (gate awareness). A full close gate runs far longer than one
# iteration, so a gate started by iteration N is still running for iterations
# N+1..N+5, each of which had to rediscover it, and 44 of 141 iteration logs did
# exactly that.
#
# MEASURED, but by a RE-MEASUREMENT RECIPE rather than a reproducible
# derivation. Both commands below read machine-local, ephemeral files:
# /private/tmp/lane-gate-*-receipt.json is written per gate into a scratch area
# that Scripts/reap-gate-scratch.sh sweeps, and the runner log is this
# machine's. On a fresh checkout, another machine, or after a sweep they print
# `[]` and nothing - that is ABSENCE OF THE INPUT, not a refutation of the
# sample below. The literal readings of 2026-08-08 on this machine are recorded
# here so a later re-measurement has something to compare against; if they no
# longer reproduce here, re-measure and move the constant in its own commit
# rather than reading the empty result as either agreement or disagreement.
#   python3 -c "import json,glob;print(sorted(json.load(open(p))['durationSeconds'] for p in glob.glob('/private/tmp/lane-gate-*-receipt.json')))"
#   -> [3157, 3413, 3759, 3760]        (4 receipts present, 2026-08-08)
# against a median iteration start-to-start of 656s:
#   python3 -c "import re,datetime as d;s=[d.datetime.strptime(m,'%Y%m%dT%H%M%SZ') for m in re.findall(r'=== iteration \d+ @ (\S+) ',open('/tmp/lane-foodtruck-loop/runner.log',errors='replace').read())];v=sorted((b-a).total_seconds() for a,b in zip(s,s[1:]));print(int(v[len(v)//2]))"
#   -> 656                             (201 iteration logs, 2026-08-08)
# The cap is 1.28x the longest gate in that sample (4800 / 3760), because a
# loop that blocks forever on a HUNG gate is worse than one that spawns a
# session to diagnose it: past the cap the runner logs the fact and spawns.
# --print reports the same list, and deliberately never asserts on it: one hung
# gate would otherwise red every later run off a file nobody reads.
GATE_WAIT_CAP_SECONDS=4800

# DEFECT 1 (session-limit backoff). Iterations 162-184 on 2026-08-08 each exited
# in ~62s having produced one line - "You've hit your session limit · resets 1pm
# (Europe/Moscow)" - and the runner relaunched immediately every time:
#   grep -lE 'hit your (session|usage) limit' /tmp/lane-foodtruck-loop/iter-*.log | sort | sed -n '1p;$p'
#   -> iter-20260808T092849Z.log .. iter-20260808T095940Z.log   (1851s span)
#   grep -lE 'hit your (session|usage) limit' /tmp/lane-foodtruck-loop/iter-*.log | wc -l
#   -> 23   of 201 logs, and all 23 exited non-zero - zero false positives
# 60/120/240/480/960 sums to 1860s, so the blind exponential path alone would
# have covered that entire outage in 5 launches instead of 23.
#
# The cap is MEASURED, and pinned from BOTH sides against that 1851s span by
# --self-test, because a one-sided pin is not a pin:
#   lower  - five rungs must sum past 1851s, or the fallback is slower than the
#            outage it exists for. That alone admits any cap >= 960, including
#            86400, and 86400 would have printed GREEN.
#   upper  - no single rung may exceed 1851s either. A rung longer than the
#            whole measured outage sleeps through the recovery it is waiting
#            for, which is the failure the old 62s cadence had in mirror image.
# 1800 sits inside [960, 1851] with the ladder reaching it on rung 6.
SESSION_LIMIT_BACKOFF_BASE=60
SESSION_LIMIT_BACKOFF_CAP=1800

# SAFETY BOUND - NOT MEASURED. No command produces 21600, and it must not be
# read as though one did. It is a round 6h ceiling on how long a single parsed
# reset may park the loop, and its only job is to make a parse this script got
# wrong cost hours rather than a day.
#
# What IS asserted about it (by --self-test, so it has an exit code):
#   - the clamp is exercised, i.e. session_reset_wait_seconds() really does
#     return the cap when handed a longer delay, and returns its input
#     untouched otherwise;
#   - it stays below what the parser can now emit, so it is a live bound and
#     not decoration. session_reset_delay() resolves the stated time on the
#     CURRENT day in its own zone and refuses anything not strictly in the
#     future, so its output is strictly inside one day (< 86400 + grace)
#     whatever the zone offset - the cap sits well under that.
# Clamping costs at most one extra launch, because waking early just re-probes.
SESSION_RESET_WAIT_CAP=21600
# The stated reset has minute granularity at best. The only observed successful
# recovery (iteration 185) started 42s after the stated 10:00Z reset, so wake a
# minute late rather than a second early and burn a launch on the boundary.
SESSION_RESET_GRACE_SECONDS=60

# The closing gate takes an exclusive lock in the GIT COMMON dir - one directory
# shared by every worktree of this repo - and writes pid/worktree/started-at
# into it (Scripts/gate.sh:21,39-43; receipt keys gateLockPolicy
# "exclusive-git-common-dir" and gateLockDirectory). That lock is the
# AUTHORITATIVE liveness signal. /private/tmp/lane-gate-<id>.log is not: it also
# exists for gates that died, and the sibling .exit file only appears afterwards.
# Honour the same override gate.sh does, so a gate configured elsewhere is still
# seen rather than silently missed.
gate_common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [[ -z "$gate_common_dir" ]]; then gate_common_dir="$REPO/.git"; fi
GATE_LOCK_DIR="${GATE_LOCK_DIRECTORY:-$gate_common_dir/dynamic-swiftui-closing-gate.lock}"

exit_if_paused() {
  [[ -e "$STOP_FLAG" ]] || return 0
  echo "=== paused at the iteration boundary: $STOP_FLAG present ==="
  exit 0
}

# Sleep $1 seconds in LOOP_TICK_SECONDS slices, staying responsive to the pause
# flag and announcing progress under $2. A single long `sleep` would ignore a
# pause for as long as it lasts, which for the session-reset path is hours.
responsive_sleep() {
  local total=$1 label=$2 slept=0 slice
  while (( slept < total )); do
    exit_if_paused
    slice=$(( total - slept ))
    if (( slice > LOOP_TICK_SECONDS )); then slice=$LOOP_TICK_SECONDS; fi
    sleep "$slice"
    slept=$(( slept + slice ))
    if (( slept < total && slept % WAIT_HEARTBEAT_SECONDS == 0 )); then
      echo "=== $label: ${slept}s of ${total}s elapsed ==="
    fi
  done
}

# Echo the pid of a LIVE gate holding the lock, or return 1 (no lock, or a lock
# whose owner is gone). Mirrors gate.sh's own ownership test - numeric pid file
# plus `kill -0` (Scripts/gate.sh:56-64) - so the two never disagree about who
# is running.
gate_lock_pid() {
  local pid="" attempt
  # gate.sh acquires by `mkdir` and writes the pid file immediately AFTER
  # (Scripts/gate.sh:47-49), so a gate that started microseconds ago looks
  # exactly like an abandoned one. Re-read once before deciding.
  for attempt in 1 2; do
    pid=$(/bin/cat "$GATE_LOCK_DIR/pid" 2>/dev/null || true)
    if [[ "$pid" == <-> ]]; then break; fi
    if (( attempt == 1 )); then sleep 2; fi
  done
  [[ "$pid" == <-> ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  print -r -- "$pid"
}

# Wait out a gate that is already running instead of spawning a session that
# will only discover it and hand off again. Returns as soon as the owning pid
# is gone, and unconditionally at the cap.
wait_for_gate() {
  local pid worktree started waited=0
  [[ -d "$GATE_LOCK_DIR" ]] || return 0
  if ! pid=$(gate_lock_pid); then
    # STALE: the directory is there but nobody owns it - a gate that was killed
    # (three iterations killed one outright) leaves exactly this. Do NOT remove
    # it here. gate.sh reclaims a stale lock itself, and only under a protocol
    # that survives a race (rename-aside, then re-mkdir; Scripts/gate.sh:70-79);
    # deleting it from the loop could destroy a lock a gate created one
    # millisecond ago. Say so and spawn, so a stale lock never wedges the loop.
    echo "=== gate lock $GATE_LOCK_DIR is stale (no live owner); not waiting ==="
    return 0
  fi
  worktree=$(/bin/cat "$GATE_LOCK_DIR/worktree" 2>/dev/null || echo unknown)
  started=$(/bin/cat "$GATE_LOCK_DIR/started-at" 2>/dev/null || echo unknown)
  echo "=== gate in flight: pid=$pid worktree=$worktree started=$started - waiting, not spawning ==="
  while (( waited < GATE_WAIT_CAP_SECONDS )); do
    exit_if_paused
    sleep "$LOOP_TICK_SECONDS"
    waited=$(( waited + LOOP_TICK_SECONDS ))
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "=== gate pid=$pid finished after ${waited}s - spawning the next iteration ==="
      return 0
    fi
    if (( waited % WAIT_HEARTBEAT_SECONDS == 0 )); then
      echo "=== still waiting on gate pid=$pid: ${waited}s of ${GATE_WAIT_CAP_SECONDS}s cap ==="
    fi
  done
  echo "=== gate pid=$pid outlived the ${GATE_WAIT_CAP_SECONDS}s wait cap - spawning anyway to diagnose it ==="
}

# Echo the session-limit line if this iteration died of one, else return 1. The
# non-zero exit code is part of the test on purpose: an iteration that merely
# WRITES about session limits (this very defect, for instance) exits 0, and
# must not park the loop for hours. Verified against the whole corpus - 23 of
# 201 logs match, all 23 exited 1.
session_limit_line() {
  local rc=$1 log=$2 line
  (( rc != 0 )) || return 1
  line=$(grep -m1 -iE 'hit your (session|usage) limit' "$log" 2>/dev/null) || return 1
  [[ -n "$line" ]] || return 1
  print -r -- "$line"
}

# Seconds to sleep for the reset stated in $1, or return 1 to take the blind
# exponential path. $2 optionally overrides "now" as a unix epoch, so the
# parser can be asserted against fixed instants instead of against the wall
# clock (the assertions then never decay and never race midnight).
#
# The time is printed in a LOCAL zone name ("resets 1pm (Europe/Moscow)"), so
# every field is validated before it is trusted: date(1) treats an unknown TZ
# as UTC SILENTLY, which is how a defensive parse turns into a confidently
# wrong multi-hour sleep. An abbreviation like (PDT) is not in the zoneinfo
# database, so it takes the fallback rather than a guess.
#
# A STATED TIME THAT HAS ALREADY PASSED IS REFUSED, not rolled to tomorrow.
# The message carries a wall-clock time and no date, and the two readings of
# that are not equally likely: "1pm (Europe/Moscow)" seen at 13:04 Moscow means
# the LOG IS STALE (this is also exactly what the reset-boundary race looks
# like - the limit line was written before the reset and read after it), not
# that the next reset is 24h out. Rolling it forward by 86400 fed the caller a
# ~24h delay, which the cap then turned into a SIX HOUR park on a message whose
# reset had already happened. Returning 1 falls through to the blind
# exponential ladder, which re-probes in 60s and is correct in both readings:
# if the outage really is still on, the ladder covers it (see the 1851s
# measurement above); if it is over, the loop is back at work in a minute.
# Refusing also removes the day-roll arithmetic entirely, which added a literal
# 86400 rather than resolving the same wall-clock time on the next day and so
# would have woken an hour off across a DST boundary.
session_reset_delay() {
  local line="$1" now="${2:-}" spec hour minute meridiem zone target today
  spec=$(print -r -- "$line" \
    | grep -oiE 'resets[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*([ap]\.?m\.?)?[[:space:]]*\([^)]+\)' \
    | head -1)
  [[ -n "$spec" ]] || return 1
  hour=$(print -r -- "$spec"     | sed -nE 's/.*[Rr]esets[[:space:]]+([0-9]{1,2}).*/\1/p')
  minute=$(print -r -- "$spec"   | sed -nE 's/.*[Rr]esets[[:space:]]+[0-9]{1,2}:([0-9]{2}).*/\1/p')
  meridiem=$(print -r -- "$spec" | sed -nE 's/.*[0-9][[:space:]]*([AaPp])\.?[Mm].*/\1/p' \
    | tr '[:upper:]' '[:lower:]')
  zone=$(print -r -- "$spec"     | sed -nE 's/.*\(([^)]+)\).*/\1/p')
  [[ "$hour" == <-> ]] || return 1
  if [[ -z "$minute" ]]; then minute=0; fi
  [[ "$minute" == <-> ]] || return 1
  [[ -n "$zone" && -e "/usr/share/zoneinfo/$zone" ]] || return 1
  hour=$(( 10#$hour ))
  minute=$(( 10#$minute ))
  case "$meridiem" in
    p) if (( hour < 12 )); then hour=$(( hour + 12 )); fi ;;
    a) if (( hour == 12 )); then hour=0; fi ;;
  esac
  (( hour <= 23 && minute <= 59 )) || return 1
  if [[ -z "$now" ]]; then now=$(date -u +%s); fi
  [[ "$now" == <-> ]] || return 1
  # "Today" is today IN THE STATED ZONE as of `now`, not the host's today and
  # not the wall clock - deriving it from $now is what makes the override total.
  today=$(TZ="$zone" date -r "$now" +%Y-%m-%d 2>/dev/null)
  [[ "$today" == <->-<->-<-> ]] || return 1
  target=$(TZ="$zone" date -j -f '%Y-%m-%d %H:%M:%S' \
    "$today $(printf '%02d:%02d:00' "$hour" "$minute")" +%s 2>/dev/null)
  [[ "$target" == <-> ]] || return 1
  # Already past (or exactly at) the stated instant: the message is stale, or
  # this is the reset boundary itself. Refuse - see the header. `<=` and not
  # `<` on purpose: a delay of 0 is the boundary race, and re-probing in 60s
  # beats sleeping the grace period on a reset that has already landed.
  (( target > now )) || return 1
  print -r -- $(( target - now + SESSION_RESET_GRACE_SECONDS ))
}

# Clamp a parsed reset delay to SESSION_RESET_WAIT_CAP. A separate function
# from the parser only so the clamp itself has an exit code in --self-test -
# it lived inline in the loop body, where nothing could reach it. The notice
# goes to stderr so the value can be captured from stdout; the runner is
# launched under `2>&1 | tee`, so it still lands in runner.log in order.
session_reset_wait_seconds() {
  local delay=$1
  if (( delay > SESSION_RESET_WAIT_CAP )); then
    print -u2 "=== session limit: stated reset is ${delay}s out, clamped to ${SESSION_RESET_WAIT_CAP}s ==="
    delay=$SESSION_RESET_WAIT_CAP
  fi
  print -r -- "$delay"
}

# The blind ladder: 0 -> base, then doubling, capped. A separate function only
# so --self-test can walk it without launching anything.
next_backoff_delay() {
  local d=$1
  if (( d == 0 )); then d=$SESSION_LIMIT_BACKOFF_BASE; else d=$(( d * 2 )); fi
  if (( d > SESSION_LIMIT_BACKOFF_CAP )); then d=$SESSION_LIMIT_BACKOFF_CAP; fi
  print -r -- "$d"
}

# ── --self-test / --print ─────────────────────────────────────────────────────
# The two decisions above - "is this a session limit?" and "is a gate live?" -
# are the ones that burned 23 launches in 31 minutes and left 44 of 141
# iterations without a commit or a ledger marker, and BOTH are unobservable in
# normal operation: they only execute when the outage they answer is happening.
# So they get exercised against synthetic fixtures instead, with an exit code,
# because this project has three recorded incidents of a rule that was only
# prose never firing. --self-test never launches claude, never builds, never
# captures, and never touches the live lock or the live log directory.
#
#   .claude/run-foodtruck-loop.sh --self-test   verify the decisions, exit 1 on any miss
#   .claude/run-foodtruck-loop.sh --print       report the constants and what is live, exit 0
selftest_failures=0
selftest_checks=0
expect() {   # $1 label, $2 got, $3 want
  (( selftest_checks++ ))
  if [[ "$2" == "$3" ]]; then
    print "  ok   $1"
  else
    print -u2 "  FAIL $1: got '$2', want '$3'"
    (( selftest_failures++ ))
  fi
}

# The instant every parser assertion below is made against: 2026-08-08T09:28:49Z,
# the start of iter-20260808T092849Z.log - the first of the 23 session-limited
# iterations, whose line was "resets 1pm (Europe/Moscow)" and whose real
# recovery landed at 10:00Z. Injecting it makes the parser assertions exact
# numbers rather than "whatever the clock says", which is what lets the
# stale-time refusal be asserted at all: the same corpus line is legitimately
# parseable at 09:28Z and legitimately stale at 13:00 Moscow, and a
# wall-clock-driven test can only ever see one of the two.
#   TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' '2026-08-08 09:28:49' +%s   -> 1786181329
SELFTEST_NOW=1786181329

run_self_test() {
  local dir line spec rest want got delay rung sum step tick_ceiling dash zone
  dir=$(mktemp -d "${TMPDIR:-/tmp}/foodtruck-loop-selftest.XXXXXX") || return 1

  # DEFECT 1, detector. The non-zero exit code is load-bearing: an iteration
  # that merely WRITES about session limits must not park the loop for hours.
  print -r -- "You've hit your session limit · resets 1pm (Europe/Moscow)" > "$dir/limit.log"
  print -r -- "I edited the runner so it can hit your session limit gracefully" > "$dir/prose.log"
  print -r -- "ordinary iteration output" > "$dir/normal.log"
  expect "detector fires on a failed limited iteration" \
    "$(session_limit_line 1 "$dir/limit.log" >/dev/null; print $?)" "0"
  expect "detector ignores a SUCCESSFUL iteration that mentions the phrase" \
    "$(session_limit_line 0 "$dir/prose.log" >/dev/null; print $?)" "1"
  expect "detector ignores an ordinary failure" \
    "$(session_limit_line 1 "$dir/normal.log" >/dev/null; print $?)" "1"

  # DEFECT 1, parser. Asserted as the exact number of seconds it returns for a
  # FIXED instant (SELFTEST_NOW), so the assertion pins both halves - the
  # wall-clock resolution AND the arithmetic - and cannot decay as the clock
  # moves or flake at a day boundary. Each `want` is (target - SELFTEST_NOW) +
  # SESSION_RESET_GRACE_SECONDS; the middle column re-derives the target:
  #   TZ=Europe/Moscow date -j -f '%Y-%m-%d %H:%M:%S' '2026-08-08 13:00:00' +%s -> 1786183200
  for line in "resets 1pm (Europe/Moscow)|1786183200|1931" \
              "resets 12pm (UTC)|1786190400|9131" \
              "resets 11:30pm (UTC)|1786231800|50531" \
              "resets 21:05 (UTC)|1786223100|41831"; do
    spec=${line%%|*}
    rest=${line#*|}
    want=${rest##*|}
    if delay=$(session_reset_delay "You've hit your session limit · $spec" "$SELFTEST_NOW"); then
      expect "parses '$spec' at 09:28:49Z" "$delay" "$want"
    else
      expect "parses '$spec' at 09:28:49Z" "refused" "$want"
    fi
  done
  # date(1) resolves an unknown zone to UTC in silence, which is how a
  # defensive parse becomes a confidently wrong multi-hour sleep. These must
  # all take the exponential fallback rather than guess.
  for spec in "resets 1pm (PDT)" "resets 1pm (Nowhere/Bogus)" "resets soon" \
              "resets 1pm" "resets 25:00 (UTC)"; do
    expect "refuses '$spec'" \
      "$(session_reset_delay "You've hit your session limit · $spec" "$SELFTEST_NOW" >/dev/null; print $?)" "1"
  done
  # A STATED TIME ALREADY PAST means the message is stale, not that the reset
  # is tomorrow. Rolling forward by 86400 made each of these a ~24h delay that
  # the caller clamped to SESSION_RESET_WAIT_CAP - a SIX HOUR park off a log
  # line whose reset had already happened. All must fall through to the ladder.
  # The last two are the corpus line itself, at the reset instant and one
  # second after it: the reset-boundary race, which is the case most likely to
  # be seen for real because the limit line is written just before the reset
  # and read just after it.
  for line in "resets 12am (UTC)|$SELFTEST_NOW" \
              "resets 09:05 (UTC)|$SELFTEST_NOW" \
              "resets 1pm (Europe/Moscow)|1786183200" \
              "resets 1pm (Europe/Moscow)|1786183201"; do
    spec=${line%%|*}
    got=${line##*|}
    expect "refuses stale '$spec' (now=$got)" \
      "$(session_reset_delay "You've hit your session limit · $spec" "$got" >/dev/null; print $?)" "1"
  done
  # ...and the same line at an instant BEFORE the stated reset is still parsed,
  # so the refusal above is a staleness test and not a blanket disable.
  expect "the corpus line one second before its reset is still parsed" \
    "$(session_reset_delay "You've hit your session limit · resets 1pm (Europe/Moscow)" 1786183199)" \
    "$(( 1 + SESSION_RESET_GRACE_SECONDS ))"

  # SESSION_RESET_WAIT_CAP is a safety bound, so what is asserted is that it
  # BOUNDS something: the clamp fires above it, is transparent below it, and
  # sits under everything the parser can now emit. The parser resolves the
  # stated time on the current day in its own zone and refuses anything not
  # strictly future, so its output is inside one day whatever the zone offset -
  # checked here at the extremes of the offset range (UTC+14 .. UTC-12) and at
  # the latest time of day a message can name.
  expect "clamp returns the cap for a longer delay" \
    "$(session_reset_wait_seconds $(( SESSION_RESET_WAIT_CAP + 1 )) 2>/dev/null)" \
    "$SESSION_RESET_WAIT_CAP"
  expect "clamp is transparent at the cap" \
    "$(session_reset_wait_seconds $SESSION_RESET_WAIT_CAP 2>/dev/null)" "$SESSION_RESET_WAIT_CAP"
  expect "clamp is transparent below the cap" "$(session_reset_wait_seconds 1931 2>/dev/null)" "1931"
  for zone in UTC Pacific/Kiritimati Etc/GMT+12; do
    if delay=$(session_reset_delay "resets 11:59pm ($zone)" "$SELFTEST_NOW"); then
      expect "parsed delay for '$zone' 23:59 stays inside one day" \
        "$(( delay < 86400 + SESSION_RESET_GRACE_SECONDS ))" "1"
    else
      expect "parsed delay for '$zone' 23:59 stays inside one day" "refused" "inside"
    fi
  done
  # ...and the cap is a LIVE bound rather than decoration: a perfectly ordinary
  # stated time is above it, so the clamp is on a reachable path.
  delay=$(session_reset_delay 'resets 11:59pm (UTC)' "$SELFTEST_NOW")
  expect "a parseable reset can exceed the cap (the clamp is reachable)" \
    "$delay $(( delay > SESSION_RESET_WAIT_CAP ))" "52271 1"

  # DEFECT 1, ladder. This is the measurement made executable: the observed
  # outage spanned 1851s (iter-20260808T092849Z.log .. iter-20260808T095940Z.log),
  # and five steps of the blind ladder must cover it, or the fallback is slower
  # than the outage it exists for.
  sum=0; step=0; rung=0
  while (( step < 5 )); do
    rung=$(next_backoff_delay "$rung"); sum=$(( sum + rung )); (( step++ ))
  done
  expect "five blind backoff steps cover the measured 1851s outage" "$(( sum >= 1851 ))" "1"
  expect "ladder starts at the base" "$(next_backoff_delay 0)" "$SESSION_LIMIT_BACKOFF_BASE"
  expect "ladder saturates at the cap" \
    "$(next_backoff_delay $SESSION_LIMIT_BACKOFF_CAP)" "$SESSION_LIMIT_BACKOFF_CAP"
  # The check above pins the cap only FROM BELOW - it walks 60/120/240/480/960
  # and passes for any cap >= 960, so a cap of 86400 would also have printed
  # GREEN while sleeping a day per rung. Pin the other side against the same
  # measurement: no single rung may sleep longer than the whole 1851s outage
  # the ladder exists to cover, because a rung that long sleeps through the
  # recovery it is waiting for.
  expect "no single backoff rung outlasts the measured 1851s outage" \
    "$(( SESSION_LIMIT_BACKOFF_CAP <= 1851 ))" "1"
  # ...and the cap is a value the loop actually sleeps rather than an unused
  # constant: walking the ladder from cold must arrive at it, and soon.
  rung=0; step=0
  while (( step < 8 && rung < SESSION_LIMIT_BACKOFF_CAP )); do
    rung=$(next_backoff_delay "$rung"); (( step++ ))
  done
  expect "the ladder reaches the cap from cold within 8 rungs" "$rung" "$SESSION_LIMIT_BACKOFF_CAP"

  # DEFECT 2, liveness. A lock whose owner is gone must NOT wedge the loop, and
  # must NOT be deleted here either - gate.sh reclaims it under a protocol that
  # survives a race, and this runner racing that would destroy a live lock.
  mkdir -p "$dir/stale.lock"
  print -r -- 999999 > "$dir/stale.lock/pid"     # pid 999999 is never live on macOS
  GATE_LOCK_DIR="$dir/stale.lock"
  expect "stale lock is not treated as live" \
    "$(gate_lock_pid >/dev/null 2>&1; print $?)" "1"
  expect "stale lock does not wedge the wait" \
    "$(wait_for_gate | grep -c 'is stale (no live owner)')" "1"
  expect "stale lock is left for gate.sh to reclaim" "$([[ -d $dir/stale.lock ]] && print yes)" "yes"
  print -r -- "not-a-pid" > "$dir/stale.lock/pid"
  expect "non-numeric owner is not treated as live" \
    "$(gate_lock_pid >/dev/null 2>&1; print $?)" "1"
  rm -f "$dir/stale.lock/pid"
  expect "missing owner file is not treated as live" \
    "$(gate_lock_pid >/dev/null 2>&1; print $?)" "1"
  mkdir -p "$dir/live.lock"; print -r -- "$$" > "$dir/live.lock/pid"
  GATE_LOCK_DIR="$dir/live.lock"
  expect "a live owner is reported" "$(gate_lock_pid)" "$$"
  GATE_LOCK_DIR="$dir/absent.lock"
  expect "an absent lock says nothing and waits for nothing" "$(wait_for_gate | wc -l | tr -d ' ')" "0"

  # Cross-file invariant. loop-dashboard.py attributes any runner child older
  # than its own threshold to "the iteration in flight", so a sleep slice above
  # it would make a WAITING loop read as a working one on the dashboard. Read
  # the threshold out of the dashboard rather than restating it here.
  #
  # It must be read from TREE_UNDER_TEST, never from $REPO. This is the only
  # assertion here that leaves the file, and pointing it at the hardcoded
  # steward path made it VACUOUS under the gate: the gate runs --self-test from
  # a clean-detached candidate checkout, so the assertion read the steward's
  # loop-dashboard.py and passed whatever the candidate's said - including a
  # candidate that moved the threshold to 5 and made every tick a lie.
  dash="$TREE_UNDER_TEST/Scripts/loop-dashboard.py"
  if [[ -f "$dash" ]]; then
    tick_ceiling=$(sed -nE 's/.*seconds is not None and seconds > ([0-9]+).*/\1/p' "$dash" | head -1)
    # Present but unreadable is a FAILURE, not a skip: the file is still there
    # and the coupling still exists, so a silent skip would hide exactly the
    # refactor that breaks it.
    expect "loop-dashboard.py in the tree under test still states its threshold" \
      "$([[ "$tick_ceiling" == <-> ]] && print yes || print "unreadable")" "yes"
    if [[ "$tick_ceiling" == <-> ]]; then
      expect "sleep slice ($LOOP_TICK_SECONDS s) stays under the dashboard's ${tick_ceiling}s iteration threshold" \
        "$(( LOOP_TICK_SECONDS <= tick_ceiling ))" "1"
    fi
  else
    # Genuinely vacuous - there is no dashboard in this tree to disagree with.
    # Say which tree was looked at, so a wrong TREE_UNDER_TEST reads as a skip
    # with an address rather than as a pass.
    print "  skip no Scripts/loop-dashboard.py under $TREE_UNDER_TEST"
  fi
  expect "heartbeat is a whole number of ticks" \
    "$(( WAIT_HEARTBEAT_SECONDS % LOOP_TICK_SECONDS ))" "0"

  rm -rf "$dir"
  # One marker line, printed on pass AND fail, so the closing gate can record
  # the waiting policy in its receipt. Nothing in this project measures loop
  # latency yet; this at least puts the numbers that govern the loop's idle
  # time somewhere an audit can read them per landing.
  print "@@foodtruck-loop-self-test {\"version\":1,\"checks\":$selftest_checks,\"failures\":$selftest_failures,\"loopTickSeconds\":$LOOP_TICK_SECONDS,\"waitHeartbeatSeconds\":$WAIT_HEARTBEAT_SECONDS,\"gateWaitCapSeconds\":$GATE_WAIT_CAP_SECONDS,\"sessionBackoffBaseSeconds\":$SESSION_LIMIT_BACKOFF_BASE,\"sessionBackoffCapSeconds\":$SESSION_LIMIT_BACKOFF_CAP,\"sessionResetCapSeconds\":$SESSION_RESET_WAIT_CAP,\"sessionResetGraceSeconds\":$SESSION_RESET_GRACE_SECONDS}"
  if (( selftest_failures > 0 )); then
    print -u2 "run-foodtruck-loop --self-test: $selftest_failures of $selftest_checks failed"
    return 1
  fi
  print "run-foodtruck-loop --self-test GREEN ($selftest_checks checks)"
  return 0
}

run_print() {
  local pid durations
  print "── run-foodtruck-loop waiting policy ──"
  printf '  loop tick              %8s s\n' "$LOOP_TICK_SECONDS"
  printf '  wait heartbeat         %8s s\n' "$WAIT_HEARTBEAT_SECONDS"
  printf '  gate wait cap          %8s s\n' "$GATE_WAIT_CAP_SECONDS"
  printf '  session backoff        %8s s  base, cap %s s\n' \
    "$SESSION_LIMIT_BACKOFF_BASE" "$SESSION_LIMIT_BACKOFF_CAP"
  printf '  session reset cap      %8s s  grace %s s\n' \
    "$SESSION_RESET_WAIT_CAP" "$SESSION_RESET_GRACE_SECONDS"
  printf '  gate lock              %s\n' "$GATE_LOCK_DIR"
  if pid=$(gate_lock_pid); then
    printf '  gate now               LIVE pid=%s worktree=%s started=%s\n' "$pid" \
      "$(/bin/cat "$GATE_LOCK_DIR/worktree" 2>/dev/null || print unknown)" \
      "$(/bin/cat "$GATE_LOCK_DIR/started-at" 2>/dev/null || print unknown)"
  elif [[ -d "$GATE_LOCK_DIR" ]]; then
    print '  gate now               STALE lock present, no live owner (would not wait)'
  else
    print '  gate now               none'
  fi
  # Reported, never asserted: these receipts are machine-local, and one hung
  # gate would otherwise red every later gate forever off a file nobody reads.
  durations=$(python3 -c "import json,glob;print(sorted(json.load(open(p))['durationSeconds'] for p in glob.glob('/private/tmp/lane-gate-*-receipt.json')))" 2>/dev/null)
  printf '  gate durations seen    %s (cap is %s s)\n' "${durations:-none}" "$GATE_WAIT_CAP_SECONDS"
  return 0
}

case "${1:-}" in
  --self-test) run_self_test; exit $? ;;
  --print)     run_print;     exit 0  ;;
  "")          ;;
  *) print -u2 "usage: $0 [--self-test|--print]"; exit 2 ;;
esac

iteration=0
backoff_delay=0
while true; do
  wait_for_gate
  iteration=$((iteration + 1))
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  log="$LOG_DIR/iter-$stamp.log"
  echo "=== iteration $iteration @ $stamp (model=$MODEL effort=$EFFORT) ==="
  claude -p "$(cat LOOP-ICECUBES.md)" \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --dangerously-skip-permissions \
    > "$log" 2>&1
  rc=$?
  tail -3 "$log"
  echo "=== iteration $iteration exit=$rc log=$log ==="
  exit_if_paused
  # Reap finished clean-detached gate checkouts. gate.sh cannot do this itself
  # - it runs INSIDE the directory being removed - and the iteration that made
  # it has usually exited by the time its gate finishes, so nothing ever did.
  # By 2026-08-07 that had left 26 checkouts and 23 live worktree
  # registrations. The reaper protects anything with a live process, anything
  # younger than 6h, and itself.
  "$REPO/Scripts/reap-gate-scratch.sh" 2>&1 | grep -vE '^keep ' || true
  if limit_line=$(session_limit_line "$rc" "$log"); then
    echo "=== session limit: $limit_line ==="
    if delay=$(session_reset_delay "$limit_line"); then
      delay=$(session_reset_wait_seconds "$delay")
      backoff_delay=0
      echo "=== session limit: sleeping ${delay}s until the stated reset ==="
    else
      # No usable reset time - including a stated time that has already passed,
      # which means the line is stale or we are on the reset boundary. Both are
      # answered by re-probing soon, not by sleeping until tomorrow.
      backoff_delay=$(next_backoff_delay "$backoff_delay")
      delay=$backoff_delay
      echo "=== session limit: no usable reset time, backing off ${delay}s (cap ${SESSION_LIMIT_BACKOFF_CAP}s) ==="
    fi
    responsive_sleep "$delay" "session-limit backoff"
    continue
  fi
  backoff_delay=0
  # A crashed CLI in a tight loop would spin; a healthy iteration takes
  # 30+ minutes, so a fixed pause costs nothing and absorbs API hiccups.
  # responsive_sleep, not `sleep`: this was the last plain sleep in the script,
  # and the header promises the stop flag is read every LOOP_TICK_SECONDS
  # during every wait. A pause set inside a plain 60s sleep here was not
  # honoured until the NEXT iteration had spawned and run to completion.
  responsive_sleep 60 "inter-iteration pause"
done
