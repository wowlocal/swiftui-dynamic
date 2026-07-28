#!/bin/zsh
# Convert a valid property list to JSON with a bounded retry for transient
# plutil conversion failures. The caller remains responsible for validating
# the resulting JSON schema.
set -u

if (( $# != 2 )); then
    echo "usage: $0 INPUT.plist OUTPUT.json" >&2
    exit 2
fi

input="$1"
output="$2"
plutil_bin="${GATE_PLUTIL_BIN:-/usr/bin/plutil}"
attempts="${GATE_PLUTIL_CONVERSION_ATTEMPTS:-3}"
retry_delay="${GATE_PLUTIL_CONVERSION_RETRY_DELAY_SECONDS:-0.1}"

if [[ "$attempts" != <1-> ]] || (( attempts > 10 )); then
    echo "GATE_PLUTIL_CONVERSION_ATTEMPTS must be in 1...10, got '$attempts'" >&2
    exit 2
fi
if ! "$plutil_bin" -lint "$input" >/dev/null 2>&1; then
    echo "gate receipt plist is invalid: $input" >&2
    exit 1
fi

integer attempt
for (( attempt = 1; attempt <= attempts; attempt++ )); do
    rm -f "$output"
    if "$plutil_bin" -convert json -r -o "$output" "$input" 2>/dev/null \
        && [[ -s "$output" ]]
    then
        exit 0
    fi
    if (( attempt < attempts )); then
        /bin/sleep "$retry_delay"
    fi
done

rm -f "$output"
echo "could not convert gate receipt plist after $attempts attempts" >&2
exit 1
