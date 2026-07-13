#!/bin/sh
set -eu

repository=https://github.com/swiftlang/swift.git
revision=swift-6.2.3-RELEASE
expected_commit=484e622d1c0afcae5b12a31c090a74ad0901e44f

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
destination="$repository_root/Tests/SwiftUpstream"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-upstream-tests.XXXXXX")
checkout="$temporary_root/swift"

cleanup() {
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

git -c advice.detachedHead=false clone \
    --quiet \
    --depth 1 \
    --filter=blob:none \
    --sparse \
    --branch "$revision" \
    "$repository" \
    "$checkout"
git -C "$checkout" sparse-checkout set test/Interpreter

actual_commit=$(git -C "$checkout" rev-parse HEAD)
if [ "$actual_commit" != "$expected_commit" ]; then
    echo "unexpected Swift commit: $actual_commit (expected $expected_commit)" >&2
    exit 1
fi

mkdir -p "$destination/Fixtures"
for fixture in \
    hello_toplevel.swift \
    hello_func.swift \
    ternary_expr.swift \
    array_of_optional.swift \
    break_continue.swift \
    protocols.swift \
    capture_inout.swift \
    RosettaCode.swift
do
    cp "$checkout/test/Interpreter/$fixture" "$destination/Fixtures/$fixture"
done
cp "$checkout/LICENSE.txt" "$destination/LICENSE.txt"

echo "synced Swift upstream tests from $revision ($actual_commit)"
