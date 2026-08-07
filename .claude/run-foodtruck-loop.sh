#!/bin/zsh
# Ralph runner for lane-foodtruck-run: one LOOP-ICECUBES.md iteration per
# claude invocation, forever. Started by .claude/resume-foodtruck-loop.sh,
# which runs it in its own agterm session.
#
#   pause:  touch /tmp/lane-foodtruck-loop/stop
#           The flag is read at the ITERATION BOUNDARY, so the in-flight
#           iteration finishes and commits first - nothing is cut mid-work.
#           Killing the session instead SIGHUPs claude wherever it happens to
#           be. resume clears the flag, so a stale one never blocks a restart.
set -u
# `claude` lives in ~/.local/bin, which .zshrc adds - so an agterm --command
# session, a login-but-not-interactive `zsh -lc`, launchd or cron all start
# without it. Put it back here so the runner works whoever launched it.
export PATH="$HOME/.local/bin:$PATH"
REPO=/Users/mike/src/tries/2026-07-08-swiftui-dynamic
LANE="$REPO/.claude/worktrees/lane-foodtruck-run"
LOG_DIR=/tmp/lane-foodtruck-loop
STOP_FLAG="$LOG_DIR/stop"
MODEL="${LOOP_MODEL:-claude-opus-5}"
EFFORT="${LOOP_EFFORT:-xhigh}"
mkdir -p "$LOG_DIR"
cd "$LANE" || exit 2

iteration=0
while true; do
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
  if [ -e "$STOP_FLAG" ]; then
    echo "=== paused at the iteration boundary: $STOP_FLAG present ==="
    exit 0
  fi
  # Reap finished clean-detached gate checkouts. gate.sh cannot do this itself
  # - it runs INSIDE the directory being removed - and the iteration that made
  # it has usually exited by the time its gate finishes, so nothing ever did.
  # By 2026-08-07 that had left 26 checkouts and 23 live worktree
  # registrations. The reaper protects anything with a live process, anything
  # younger than 6h, and itself.
  "$REPO/Scripts/reap-gate-scratch.sh" 2>&1 | grep -vE '^keep ' || true
  # A crashed CLI in a tight loop would spin; a healthy iteration takes
  # 30+ minutes, so a fixed pause costs nothing and absorbs API hiccups.
  sleep 60
done
