#!/bin/zsh
# reap-gate-scratch.sh — remove finished clean-detached gate checkouts from /tmp.
#
# The worktree protocol has each iteration build a FRESH clean-detached checkout for its closing
# gate (`git worktree add /tmp/lane-gate-<sha>`), and nothing ever removes it: gate.sh cannot,
# because it runs INSIDE that directory, and the iteration that made it has usually exited by the
# time the gate finishes. By 2026-08-07 that had left 26 checkouts holding ~78G of `du` and 23 live
# `git worktree` registrations. Plain `rm -rf` is not enough — it leaves the registration behind,
# and a stale registration makes `git worktree add` refuse the path on a later run.
#
#   Scripts/reap-gate-scratch.sh            reap; prints what it freed
#   Scripts/reap-gate-scratch.sh --dry-run  list what would go, touch nothing
#
# Safe by construction, in this order:
#   1. never reaps a directory any live process has open (one lsof pass);
#   2. never reaps a directory younger than the grace period (default 6h — a gate runs ~1h), so a
#      gate whose files lsof happens to miss between stages is still protected;
#   3. never reaps the directory this script is running inside.
set -u

grace_hours=${REAP_GRACE_HOURS:-6}
dry_run=false
[[ "${1:-}" == "--dry-run" ]] && dry_run=true

cd "$(dirname "$0")/.." || exit 2

# FOUR naming schemes are on disk from the project's life so far —
# lane-gate-<sha>, lane-<sha>-gate[.XXXX], lane-<sha>-full-gate.XXXX and
# lane-<x>-clean-gate.XXXX. An earlier version of this script matched only the
# first two and left 62 directories behind, which is exactly the failure it
# exists to prevent. Match on "gate" anywhere so a fifth spelling is covered
# too; the loop's own log directory (lane-foodtruck-loop) has no "gate" in it
# and is therefore never a candidate.
scratch_dirs=()
for pattern in /tmp/lane-*gate* /private/tmp/lane-*gate*; do
    for candidate in $~pattern(N); do
        [[ -d "$candidate" ]] && scratch_dirs+=("$candidate:A")
    done
done
# :A resolved /tmp -> /private/tmp, so the two globs collapse to the same paths; dedupe.
scratch_dirs=(${(u)scratch_dirs})

if (( ${#scratch_dirs} == 0 )); then
    print "reap: no gate scratch found"
    exit 0
fi

# One lsof pass for every path any process currently holds open. Cheaper and far more reliable than
# probing each directory, and it catches a gate's children (swift, xcodebuild, capture apps) too.
live_paths=$(/usr/sbin/lsof -n 2>/dev/null | grep -oE '/private/tmp/lane-[a-zA-Z0-9._-]+' | sort -u)
self_path="${PWD:A}"

typeset -a reapable
for dir in $scratch_dirs; do
    if print -r -- "$live_paths" | grep -qxF -- "$dir"; then
        print "keep (live process): $dir"
        continue
    fi
    if [[ "$self_path" == "$dir"* ]]; then
        print "keep (this script runs inside it): $dir"
        continue
    fi
    # -mmin is portable here and exact; find prints the path only when it is OLD enough.
    if [[ -z "$(find "$dir" -maxdepth 0 -mmin +$((grace_hours * 60)) 2>/dev/null)" ]]; then
        print "keep (younger than ${grace_hours}h): $dir"
        continue
    fi
    reapable+=("$dir")
done

if (( ${#reapable} == 0 )); then
    print "reap: nothing eligible"
    exit 0
fi

if $dry_run; then
    print "reap --dry-run would remove ${#reapable} checkout(s):"
    for dir in $reapable; do print "  $dir"; done
    exit 0
fi

integer free_before=$(df -g / 2>/dev/null | tail -1 | awk '{print $4}')
for dir in $reapable; do
    # Deregister first: `git worktree remove` refuses a dirty tree, and a gate checkout always is,
    # hence --force. If the path was never registered this fails harmlessly and rm does the work.
    git worktree remove --force "$dir" 2>/dev/null
    rm -rf "$dir"
    print "reaped: $dir"
done
git worktree prune
integer free_after=$(df -g / 2>/dev/null | tail -1 | awk '{print $4}')

print "reap: removed ${#reapable} checkout(s); free ${free_before}Gi -> ${free_after}Gi"
# df can move less than du suggested: APFS clones share blocks between checkouts, and local Time
# Machine snapshots pin the blocks of deleted files until the system reclaims them under pressure.
# Both are normal; the space is purgeable even when df has not caught up.
