#!/bin/zsh
# Apply one idempotent plist mutation or convert a plist to JSON with bounded
# retry. This contains transient plutil read/write failures without weakening
# the caller's final schema validation.
set -u

mode="${1:-}"
plutil_bin="${GATE_PLUTIL_BIN:-/usr/bin/plutil}"
attempts="${GATE_PLUTIL_ATTEMPTS:-3}"
retry_delay="${GATE_PLUTIL_RETRY_DELAY_SECONDS:-0.1}"

if [[ "$attempts" != <1-> ]] || (( attempts > 10 )); then
    echo "GATE_PLUTIL_ATTEMPTS must be in 1...10, got '$attempts'" >&2
    exit 2
fi

retry_pause() {
    if (( $1 < attempts )); then
        /bin/sleep "$retry_delay"
    fi
}

case "$mode" in
    set)
        if (( $# < 4 )); then
            echo "usage: $0 set INPUT.plist PATH TYPE [VALUE]" >&2
            exit 2
        fi
        input="$2"
        path="$3"
        shift 3
        integer attempt
        for (( attempt = 1; attempt <= attempts; attempt++ )); do
            action=insert
            if (( attempt > 1 )); then action=replace; fi
            if "$plutil_bin" "-$action" "$path" "$@" "$input" \
                >/dev/null 2>&1
            then
                exit 0
            fi
            if (( attempt > 1 )) \
                && "$plutil_bin" -insert "$path" "$@" "$input" \
                    >/dev/null 2>&1
            then
                exit 0
            fi
            retry_pause "$attempt"
        done
        echo "could not set gate receipt path '$path' after $attempts attempts" \
            >&2
        exit 1
        ;;
    convert-json)
        if (( $# != 3 )); then
            echo "usage: $0 convert-json INPUT.plist OUTPUT.json" >&2
            exit 2
        fi
        input="$2"
        output="$3"
        integer attempt
        for (( attempt = 1; attempt <= attempts; attempt++ )); do
            rm -f "$output"
            if "$plutil_bin" -convert json -r -o "$output" "$input" \
                >/dev/null 2>&1 \
                && [[ -s "$output" ]]
            then
                exit 0
            fi
            retry_pause "$attempt"
        done
        rm -f "$output"
        echo "could not convert gate receipt plist after $attempts attempts" >&2
        exit 1
        ;;
    *)
        echo "usage: $0 {set|convert-json} ..." >&2
        exit 2
        ;;
esac
