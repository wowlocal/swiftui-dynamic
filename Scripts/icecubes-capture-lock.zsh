# ── THE SHARED-STATE LOCK, ONE DEFINITION FOR BOTH CAPTURE BOARDS ─────────────
# Sourced by Scripts/icecubes-r2.sh and Scripts/icecubes-r3.sh. It is a FILE
# rather than a copied function because the two boards must agree on the lock
# PATH, and two copies of a path default is exactly how a mutual-exclusion
# primitive stops being mutual: each side takes a lock the other never looks at,
# both report success, and the failure surfaces only as capture nondeterminism
# nobody can reproduce.
#
# WHAT IS BEING EXCLUDED. The two stages share three mutable paths: the macabi
# scratch path (and the `.app` bundle rebuilt and re-codesigned inside it),
# `Examples/IceCubesNativeTwin/.build`, and the frozen clock dylib both stages
# inject into every capture process. Two of those are WRITTEN by one stage while
# the other may be EXECUTING them — the rebuild-during-a-prebuilt-test-run trap —
# and even where nothing is rewritten, two capture processes racing through the
# window server is the measured 141k-AE nondeterminism the reproducibility gates
# exist to reject.
#
# HISTORY. Scripts/icecubes-r3.sh carried this logic privately and stated its own
# honest limit: it "only excludes another R3 run, because Scripts/icecubes-r2.sh
# does not take the lock yet ... until it lands a concurrent R2 stage is still
# invisible here." Extracting it is what lets that sentence be deleted rather
# than restated — the exclusion is now symmetric.
#
# The caller supplies its own stage label and the prose naming what IT mutates,
# because a lock-held message that cannot say which stage is blocked, and on
# what, sends the reader to `ps` to find out what the tool already knew.
#
# HONEST LIMIT, AND IT IS THE ONE THAT STILL BITES. This lock is scoped to
# `$ROOT`, i.e. to ONE CHECKOUT. The exclusion it makes symmetric is R2 against
# R3 within a single tree; it does NOT exclude the case this project actually
# keeps hitting, which is a lane capture racing the CLOSE GATE, because the gate
# runs clean-detached from `/tmp/lane-gate-<sha>` and therefore takes a lock at a
# different path entirely. Two checkouts, two locks, no mutual exclusion — while
# the window server they perturb is machine-wide.
#
# So the admission instructions in Scripts/icecubes-r3.sh still say "check
# `ps ax | grep lane-gate` first", and they are not redundant with this file.
# Widening the default to a machine-wide path is the obvious repair and is
# deliberately NOT done here: today the holder is REFUSED (exit 2), so a
# machine-wide default would kill a 40-minute gate at its last stage whenever a
# lane happened to be capturing. That trade wants a WAIT rather than a refusal,
# which is a behaviour change with its own blast radius across lanes and belongs
# in its own commit with its own repro — not smuggled in under an extraction.
# Until then this file is one half of the exclusion and `ps` is the other, and
# saying so is the point: a mutual-exclusion primitive that overstates its scope
# is how the next reader skips the check that was actually load-bearing.

: ${ICECUBES_CAPTURE_LOCK_ROOT:=$ROOT}
SHARED_LOCK="${ICECUBES_CAPTURE_LOCK:-$ICECUBES_CAPTURE_LOCK_ROOT/.build/icecubes-capture.lock}"

_write_shared_capture_lock_owner() {
  print -r -- "pid=$$ started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    > "$SHARED_LOCK/owner"
}

# take_shared_capture_lock <stage label> <what this stage mutates>
#
# MUST be called AFTER any source-only checks the caller performs: those read
# `.swift` files and touch nothing shared, so making them queue behind a running
# capture is pure obstruction — and worse, it holds the lock against a capture
# that has real work to do.
#
# The caller installs the release trap ITSELF, at top level, immediately after
# this returns:
#
#     take_shared_capture_lock "IceCubes R3" "$INTERP_SCRATCH_PATH"
#     trap 'release_shared_capture_lock' EXIT INT TERM
#
# In zsh a `trap` set inside a function is scoped to that function, so
# installing it in here would arm a handler that disarms on return — a lock
# released at the wrong moment, which is worse than one never released.
take_shared_capture_lock() {
  local stage="$1" mutates="$2"
  local lock_owner lock_pid
  mkdir -p "$(dirname "$SHARED_LOCK")"
  if mkdir "$SHARED_LOCK" 2>/dev/null; then
    _write_shared_capture_lock_owner
    return 0
  fi
  lock_owner="$(cat "$SHARED_LOCK/owner" 2>/dev/null)"
  lock_pid="${lock_owner%% *}"
  lock_pid="${lock_pid#pid=}"
  # A lock whose owner is gone is a crash residue, not a running stage, and
  # leaving it would wedge every later run behind a process that no longer
  # exists. Reclaiming it is safe precisely because the owner is dead.
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    echo "$stage: SHARED-CAPTURE-LOCK-HELD — $SHARED_LOCK is owned by" \
      "$lock_owner, which is still running. This stage rebuilds and" \
      "re-codesigns $mutates, which the holder may be executing; running" \
      "anyway fakes a regression nobody can reproduce. Wait for it, or point" \
      "the scratch path and ICECUBES_CAPTURE_LOCK somewhere private." >&2
    exit 2
  fi
  echo "$stage: reclaiming stale $SHARED_LOCK (owner '$lock_owner' is" \
    "not running)" >&2
  rm -rf "$SHARED_LOCK"
  if ! mkdir "$SHARED_LOCK" 2>/dev/null; then
    echo "$stage: SHARED-CAPTURE-LOCK-HELD — could not take" \
      "$SHARED_LOCK after reclaiming it" >&2
    exit 2
  fi
  _write_shared_capture_lock_owner
}

# Release ONLY a lock this process still owns. The unguarded `rm -rf` this
# replaces had one bad case: a stage slow enough to look dead has its lock
# reclaimed by the other board, and then its own EXIT trap deletes the
# REPLACEMENT — handing a third process a lock while the second is mid-capture.
# Checking the owner first makes a late release a no-op instead of an aliasing
# bug that presents as capture nondeterminism.
release_shared_capture_lock() {
  local lock_owner lock_pid
  lock_owner="$(cat "$SHARED_LOCK/owner" 2>/dev/null)"
  lock_pid="${lock_owner%% *}"
  lock_pid="${lock_pid#pid=}"
  [[ "$lock_pid" == "$$" ]] || return 0
  rm -rf "$SHARED_LOCK"
}
