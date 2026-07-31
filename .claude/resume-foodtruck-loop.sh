#!/bin/zsh
# Resume the lane-foodtruck ralph loop (claude-opus-5, xhigh effort by
# default; override with LOOP_MODEL / LOOP_EFFORT).
#
#   watch:  tmux attach -t lane-foodtruck   (detach: Ctrl-B D)
#   stop:   tmux kill-session -t lane-foodtruck
#   logs:   /tmp/lane-foodtruck-loop/iter-*.log
mkdir -p /tmp/lane-foodtruck-loop
tmux kill-session -t lane-foodtruck 2>/dev/null
tmux new-session -d -s lane-foodtruck \
  '/Users/mike/src/tries/2026-07-08-swiftui-dynamic/.claude/run-foodtruck-loop.sh 2>&1 | tee -a /tmp/lane-foodtruck-loop/runner.log'
echo "loop resumed in tmux session 'lane-foodtruck'"
tmux ls
