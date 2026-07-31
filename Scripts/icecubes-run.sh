#!/bin/zsh
# EXPERIMENTAL interactive live run: the interpreted IceCubes timeline in a
# Catalyst window over live-fetched Mastodon bytes. Close the window to quit.
# Content is live and changes run to run — nothing here feeds a metric.
#
# KNOWN-BROKEN 2026-07-31: the window composites NOTHING on screen — not even
# native SwiftUI (the loading ProgressView and a plain white background never
# paint), under both direct-exec and LaunchServices launches — while the same
# binary's offscreen `drawHierarchy` captures (the whole R2 board) and the
# headless LIVE board render correctly. The gap is in the SwiftPM-built
# Catalyst .app's on-screen render path (bundle/Info.plist/signing), NOT in
# the interpreter. Distill with a native-only probe before touching
# interpreter code.
set -u
cd "$(dirname "$0")/.." || exit 2

ROOT="$PWD"
SCRATCH_PATH="${ICECUBES_RUN_SCRATCH_PATH:-$ROOT/.build/icecubes-r2-product}"
BUILD_DIR="$SCRATCH_PATH/arm64-apple-ios-macabi/debug"
BINARY="$BUILD_DIR/IceCubesCheck"
APP="$BUILD_DIR/IceCubesCheck.app"
EXECUTABLE="$APP/Contents/MacOS/IceCubesCheck"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_FRAMEWORKS="$SDK/System/iOSSupport/System/Library/Frameworks"
IOS_LIBS="$SDK/System/iOSSupport/usr/lib"
xcrun swift build \
  --scratch-path "$SCRATCH_PATH" \
  --product IceCubesCheck \
  --triple arm64-apple-ios18.0-macabi \
  -Xcc -target -Xcc arm64-apple-ios18.0-macabi \
  -Xswiftc -target -Xswiftc arm64-apple-ios18.0-macabi \
  -Xswiftc -F -Xswiftc "$IOS_FRAMEWORKS" \
  -Xswiftc -I -Xswiftc "$IOS_LIBS/swift" \
  -Xlinker -F -Xlinker "$IOS_FRAMEWORKS" \
  -Xlinker -L -Xlinker "$IOS_LIBS" || exit 2
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$EXECUTABLE"
cp "$ROOT/Scripts/IceCubesCheck-Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null || exit 2

# A Catalyst app only gets an on-screen render-server connection when it is
# launched through LaunchServices — exec'ing the inner binary yields a live
# scene whose window never composites (offscreen drawHierarchy still works,
# which is why the R2 capture harness never noticed).
exec open -n -W \
  --stdout /tmp/icecubes-live-run.log --stderr /tmp/icecubes-live-run.log \
  "$APP" --args --run --root "$ROOT" "$@" -ApplePersistenceIgnoreState YES
