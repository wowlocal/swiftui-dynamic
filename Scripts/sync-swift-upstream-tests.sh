#!/bin/sh
set -eu

repository=https://github.com/swiftlang/swift.git
revision=swift-6.3.3-RELEASE
expected_commit=064859e41d68596f486c5d724401cb370f260409

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
git -C "$checkout" sparse-checkout set \
    test/Interpreter \
    test/Concurrency/Runtime

actual_commit=$(git -C "$checkout" rev-parse HEAD)
if [ "$actual_commit" != "$expected_commit" ]; then
    echo "unexpected Swift commit: $actual_commit (expected $expected_commit)" >&2
    exit 1
fi

xcrun swift "$script_directory/SwiftUpstreamInventory.swift" \
    "$checkout" \
    "$destination"

echo "synced and inventoried Swift upstream tests from $revision ($actual_commit)"
