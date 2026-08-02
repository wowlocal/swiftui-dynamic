#!/bin/zsh
# Ralph runner for lane-foodtruck-run: one LOOP-ICECUBES.md iteration per
# claude invocation, forever. Run inside tmux (`tmux attach -t lane-foodtruck`
# to watch, Ctrl-B D to detach, `tmux kill-session -t lane-foodtruck` to stop).
set -u
# `claude` lives in ~/.local/bin, which .zshrc adds - so an agterm --command
# session, a login-but-not-interactive `zsh -lc`, launchd or cron all start
# without it. Put it back here so the runner works whoever launched it.
export PATH="$HOME/.local/bin:$PATH"
LANE=/Users/mike/src/tries/2026-07-08-swiftui-dynamic/.claude/worktrees/lane-foodtruck-run
LOG_DIR=/tmp/lane-foodtruck-loop
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
  # A crashed CLI in a tight loop would spin; a healthy iteration takes
  # 30+ minutes, so a fixed pause costs nothing and absorbs API hiccups.
  sleep 60
done
