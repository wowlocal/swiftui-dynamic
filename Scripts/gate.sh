#!/bin/zsh
# The closing gate: ONE build, then the lightweight boards in parallel from
# prebuilt binaries. LiveCheck runs after that group: its deep-render pass can
# retain hundreds of MB, and overlapping it with the corpus sweep lets macOS
# kill it before its buffered verdict is written. ProjectCheck self-caches
# (unchanged sources return instantly), so verified trees still avoid a sweep.
#
# Usage: Scripts/gate.sh            (from the checkout root)
# Exits nonzero if ANY board is red; prints each board's verdict line.
set -u
cd "$(dirname "$0")/.." || exit 2

echo "── build (once) ──"
swift build --build-tests 2>&1 | grep -E "error:|warning: .*deprecat" | head -5
if ! swift build --build-tests > /dev/null 2>&1; then
    echo "BUILD RED"; exit 1
fi

out=$(mktemp -d)
echo "── suite + corpus + parity (parallel) ──"
( swift test --skip-build 2>&1 | tail -1 > "$out/suite" ) &
suite_pid=$!
( .build/debug/ProjectCheck --all 2>/dev/null | grep "═══" | tail -1 > "$out/corpus" ) &
corpus_pid=$!
( .build/debug/ParityCheck 2>/dev/null | tail -1 > "$out/parity" ) &
parity_pid=$!

wait $suite_pid $corpus_pid $parity_pid

echo "── live (memory-isolated) ──"
.build/debug/LiveCheck 2>/dev/null | grep "═══" | tail -1 > "$out/live"

red=0
for board in suite corpus live parity; do
    line=$(cat "$out/$board" 2>/dev/null)
    echo "$board: $line"
    case "$board:$line" in
        suite:*" passed"*) ;;
        corpus:*"projects pass"*)
            # Ledger floor (LOOP.md TestCheck Ledger): Widgets + Mythic are
            # documented native-real failures — 678/680 is the baseline,
            # ratchets UP only.
            passed=$(echo "$line" | sed -E 's/.*═══ ([0-9]+)\/680.*/\1/')
            [ "${passed:-0}" -ge 678 ] || red=1 ;;
        live:*"═══ 5/5 live-data scenarios pass ═══"*) ;;
        parity:*"0 diverge / 0 interp-error"*) ;;
        *) red=1 ;;
    esac
done
rm -rf "$out"
if [ $red -ne 0 ]; then echo "GATE RED"; exit 1; fi
echo "GATE GREEN"
