#!/bin/zsh
# Run a focused Swift Testing selection from the existing package test bundle.
# Build once with `swift build --build-tests`, then invoke this script as many
# times (or in as many independent processes) as the iteration needs.
set -u
set -o pipefail
cd "$(dirname "$0")/.." || exit 2

bundle="$PWD/.build/debug/DynamicSwiftUIPackageTests.xctest/Contents/MacOS/DynamicSwiftUIPackageTests"
if [[ ! -f "$bundle" ]]; then
    echo "prebuilt test bundle is missing; run 'swift build --build-tests'" >&2
    exit 2
fi

swift_driver=$(whence -p swift 2>/dev/null || true)
if [[ -z "$swift_driver" ]]; then
    echo "could not locate the active Swift driver" >&2
    exit 2
fi
target_info=$("$swift_driver" -print-target-info 2>/dev/null || echo '{}')
runtime_resource=$(printf '%s' "$target_info" \
    | plutil -extract paths.runtimeResourcePath raw -o - - 2>/dev/null \
    || true)
helper="${runtime_resource%/lib/swift}/libexec/swift/pm/swiftpm-testing-helper"
if [[ -z "$runtime_resource" || ! -x "$helper" ]]; then
    echo "could not locate the active toolchain's SwiftPM test helper" >&2
    exit 2
fi

library_path="$runtime_resource/macosx/testing:$runtime_resource/macosx"
framework_path="$library_path"
sdk_platform=$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null || true)
if [[ -n "$sdk_platform" \
      && -d "$sdk_platform/Developer/Library/Frameworks" ]]; then
    framework_path="$sdk_platform/Developer/Library/Frameworks:$framework_path"
fi
if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
    library_path="$library_path:$DYLD_LIBRARY_PATH"
fi
if [[ -n "${DYLD_FRAMEWORK_PATH:-}" ]]; then
    framework_path="$framework_path:$DYLD_FRAMEWORK_PATH"
fi

exec env DYLD_LIBRARY_PATH="$library_path" \
    DYLD_FRAMEWORK_PATH="$framework_path" \
    "$helper" --test-bundle-path "$bundle" --skip-build \
    "$@" "$bundle" --testing-library swift-testing
