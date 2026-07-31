#!/bin/zsh
# Run a focused Swift Testing selection from the existing package test bundle.
# Build once with `xcrun swift build --build-tests`, then invoke this script as many
# times (or in as many independent processes) as the iteration needs.
set -u
set -o pipefail
cd "$(dirname "$0")/.." || exit 2

scratch_path=${PREBUILT_TEST_SCRATCH_PATH:-.build}
if [[ "$scratch_path" == /* ]]; then
    scratch_root="$scratch_path"
else
    scratch_root="$PWD/$scratch_path"
fi
bundle="$scratch_root/debug/DynamicSwiftUIPackageTests.xctest/Contents/MacOS/DynamicSwiftUIPackageTests"
if [[ ! -f "$bundle" ]]; then
    echo "prebuilt test bundle is missing under '$scratch_path'; run 'xcrun swift build --build-tests --scratch-path $scratch_path'" >&2
    exit 2
fi

# The bundle is built by the xcrun-selected Xcode (see Scripts/gate.sh), so the
# test helper and the injected Swift/swift-testing runtimes must come from that
# same toolchain. Resolving the driver from PATH instead lets an ambient
# Swiftly/Homebrew install run a bundle against a different runtime than the one
# it was compiled against — the silent mismatch gate.sh already refuses.
swift_driver=$(xcrun --find swift 2>/dev/null || true)
if [[ -z "$swift_driver" ]]; then
    echo "xcrun could not locate the Swift driver" >&2
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

export DYLD_LIBRARY_PATH="$library_path"
export DYLD_FRAMEWORK_PATH="$framework_path"
if [[ -n "${PREBUILT_TEST_DYLD_INSERT_LIBRARIES:-}" ]]; then
    export DYLD_INSERT_LIBRARIES="$PREBUILT_TEST_DYLD_INSERT_LIBRARIES"
fi
exec "$helper" --test-bundle-path "$bundle" --skip-build \
    "$@" "$bundle" --testing-library swift-testing
