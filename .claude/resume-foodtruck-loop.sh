#!/bin/zsh
# Resume the lane-foodtruck ralph loop in a dedicated agterm session.
#
#   watch:  pick "lane-foodtruck" in the agterm sidebar (workspace "loops")
#   stop:   agtermctl session close --target "$(cat /tmp/lane-foodtruck-loop/session-id)"
#   logs:   /tmp/lane-foodtruck-loop/runner.log, .../iter-*.log
#
# agterm rather than tmux: the loop's `claude` inherits AGTERM_SESSION_ID from
# the session it runs in, so the agent-status hooks drive *this* session's
# sidebar glyph. A tmux server started from inside agterm instead captures the
# AGTERM_* of whichever session happened to spawn it, and every loop after that
# reports its status to that one stale session.
set -u

REPO=/Users/mike/src/tries/2026-07-08-swiftui-dynamic
LANE="$REPO/.claude/worktrees/lane-foodtruck-run"
RUNNER="$REPO/.claude/run-foodtruck-loop.sh"
LOG_DIR=/tmp/lane-foodtruck-loop
WORKSPACE=loops
SESSION=lane-foodtruck

mkdir -p "$LOG_DIR"

# tee: the iteration stream has to outlive the session's scrollback.
SHELL_LINE="$RUNNER 2>&1 | tee -a $LOG_DIR/runner.log"

if ! command -v agtermctl >/dev/null 2>&1 || ! agtermctl tree >/dev/null 2>&1; then
  echo "agterm not reachable - falling back to tmux" >&2
  tmux kill-session -t "$SESSION" 2>/dev/null
  tmux new-session -d -s "$SESSION" "$SHELL_LINE"
  echo "loop resumed in tmux session '$SESSION' (tmux attach -t $SESSION)"
  exit 0
fi

# Idempotent resume: drop a session still holding an older run of the loop.
for old in ${(f)"$(agtermctl tree --json | jq -r --arg n "$SESSION" '
      .result.tree.workspaces[].sessions[]? | select(.name == $n) | .id')"}; do
  [ -n "$old" ] && agtermctl session close --target "$old" >/dev/null
done

# --command spawns the process directly under agterm's GUI PATH, so the runner
# goes through a login shell for the rest of the toolchain (swiftly, homebrew).
# --wait holds the session open with the final output if the runner ever falls
# out of its while-loop, instead of closing the tab over the evidence.
# --no-select: nothing here needs driving by hand, so resuming must not yank
# the selection out of whatever session you are working in. The sidebar glyph
# (agent-status hooks) is how the loop asks for attention.
sid=$(agtermctl session new --json \
  --workspace-name "$WORKSPACE" --create-workspace \
  --name "$SESSION" --cwd "$LANE" --wait --no-select \
  --command "zsh -lc '$SHELL_LINE'" | jq -r '.result.id')
if [ -z "$sid" ] || [ "$sid" = null ]; then
  echo "agterm session new failed" >&2
  exit 1
fi
print -r -- "$sid" > "$LOG_DIR/session-id"

# Pin the same line as the pane's restore command so relaunching agterm brings
# the loop back instead of a bare shell. Sticky - it fires on every launch
# until `agtermctl session restore --clear`. Gated on Settings > "Restore
# running commands on restart"; agtermctl says so when that switch is off.
agtermctl session restore "$SHELL_LINE" --target "$sid"

echo "loop resumed in agterm session '$SESSION' ($sid), workspace '$WORKSPACE'"
echo "watch: agtermctl session select --target $sid   (or click it in the sidebar)"
