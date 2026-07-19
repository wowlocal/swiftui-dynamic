#!/bin/zsh
# Build the Catalyst command-line twin. Xcode normally supplies these
# iOSSupport framework/library paths when it builds a Catalyst app; SwiftPM's
# generic command-line driver does not.
set -eu
cd "$(dirname "$0")"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_FRAMEWORKS="$SDK/System/iOSSupport/System/Library/Frameworks"
IOS_LIBS="$SDK/System/iOSSupport/usr/lib"
CLOCK_SOURCE="$PWD/FrozenClock.c"
CLOCK_DIR="$PWD/.build/frozen-clock"
mkdir -p "$CLOCK_DIR"

# Build the same harness clock for both processes on the R2 board. A Catalyst
# dylib cannot be loaded into the macOS interpreter executable (or vice versa),
# even though both are arm64.
xcrun clang -dynamiclib -target arm64-apple-ios18.0-macabi \
  -isysroot "$SDK" -F "$IOS_FRAMEWORKS" -L "$IOS_LIBS" \
  -framework Foundation \
  "$CLOCK_SOURCE" -o "$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib"
xcrun clang -dynamiclib -target arm64-apple-macosx15.0 \
  -isysroot "$SDK" -framework Foundation \
  "$CLOCK_SOURCE" -o "$CLOCK_DIR/libIceCubesFrozenClock-macos.dylib"
codesign --force --sign - "$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib" >/dev/null
codesign --force --sign - "$CLOCK_DIR/libIceCubesFrozenClock-macos.dylib" >/dev/null

xcrun swift build \
  --triple arm64-apple-ios18.0-macabi \
  -Xcc -target -Xcc arm64-apple-ios18.0-macabi \
  -Xswiftc -target -Xswiftc arm64-apple-ios18.0-macabi \
  -Xswiftc -F -Xswiftc "$IOS_FRAMEWORKS" \
  -Xswiftc -I -Xswiftc "$IOS_LIBS/swift" \
  -Xlinker -F -Xlinker "$IOS_FRAMEWORKS" \
  -Xlinker -L -Xlinker "$IOS_LIBS"

BIN="$PWD/.build/arm64-apple-ios-macabi/debug/IceCubesNativeTwin"
APP="$PWD/.build/arm64-apple-ios-macabi/debug/IceCubesNativeTwin.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/IceCubesNativeTwin"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
echo "$CLOCK_DIR"
