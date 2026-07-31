#!/bin/zsh
# LIVE board: interpreted IceCubes app shell against the app's own default
# Mastodon instance over real HTTP — invariant assertions, never pixels and
# never a monotonic metric (content changes run to run by design).
#
# Semantics (LOOP-ICECUBES real-endpoint tier 1):
#   exit 0 + "UNSTABLE" marker  — the instance was unreachable; not a finding.
#   exit 0 + "LIVE (...) n/n"   — all invariants held on live data.
#   exit 1                      — schema drift or a broken render invariant.
# Never loop this script to turn a red green: a red here means live bytes
# stopped decoding or the interpreted shell stopped rendering real content.
set -u
cd "$(dirname "$0")/.." || exit 2

xcrun swift build --product IceCubesCheck || exit 2
exec .build/debug/IceCubesCheck --live "$@"
