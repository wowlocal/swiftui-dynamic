# AppKit Focus Studio

A functional macOS focus dashboard whose palette math, font metadata, geometry,
progress probe, text probe, level meter, and clipboard action use AppKit. The
interpreter and native Swift package run the same `ContentView` and model
sources, making the example useful for black-box parity checks.

## Run it

From the repository root, launch the interpreted app:

```bash
swift run DynamicSwiftUIDemo \
  --platform macOS \
  --project Examples/AppKitFocusStudio/Sources/AppKitFocusStudio
```

Launch the same source compiled by native Swift:

```bash
swift run --package-path Examples/AppKitFocusStudio AppKitFocusStudioNative
```

The UI supports a live countdown, preset selection, start/pause, reset,
advancing to the next session, progress adjustment, and copying a generated
AppKit color summary. Run the native model and AppKit checks with:

```bash
swift run --package-path Examples/AppKitFocusStudio \
  AppKitFocusStudioNative --self-test
```

## Black-box parity result

Tested on 2026-07-13 without inspecting interpreter implementation:

| Probe | Native Swift | Interpreter |
| --- | --- | --- |
| State transitions and timer mutation | Pass | Pass |
| `NSColor` construction, blending, alpha, and components | Pass | Pass |
| `NSView` frame and `NSProgressIndicator` properties | Pass | Pass |
| `NSFont` metadata and `NSTextField` mutation | Pass | Pass |
| Isolated `NSPasteboard` string round-trip | Pass | Fail: `setString` returns `false` |
| `NSLevelIndicator` through `NSViewRepresentable` | Renders | Does not render; SwiftUI fallback remains visible |
| One-second dispatch timer cadence | 1.049 s average | 0.224 s average |

The interpreted timer fires and advances the countdown, but it runs about 4.7
times too fast. The measurements above use host wall-clock timestamps between
the app's `scheduled timer fired` lines, so they do not depend on interpreted
clock APIs. Set `FOCUS_STUDIO_AUTOSTART=1` to start that probe automatically.

Other API-shape differences found while building the shared example:

- `String(value, radix: 16)` ignored the radix, so the example uses reusable
  manual hexadecimal conversion.
- Adding `.keyboardShortcut(...)` made the affected buttons disappear, so the
  example leaves shortcuts off.
- `StrokeStyle(lineWidth:lineCap:)` lost the requested width, so the progress
  ring uses the simpler generated `stroke(_:lineWidth:)` overload.

## Pixel comparison

Create the two dark snapshots with:

```bash
swift run --skip-build DynamicSwiftUIDemo \
  --platform macOS \
  --project Examples/AppKitFocusStudio/Sources/AppKitFocusStudio \
  --render-png /tmp/appkit-focus-interpreted.png \
  --size 980x700 --appearance dark

swift run --package-path Examples/AppKitFocusStudio --skip-build \
  AppKitFocusStudioNative \
  --render-png /tmp/appkit-focus-native.png \
  --size 980x700 --appearance dark
```

The interpreted renderer currently emits 980×721 for that request. Normalize
it with a top-aligned crop, then compare with ImageMagick:

```bash
magick /tmp/appkit-focus-interpreted.png \
  -gravity north -crop 980x700+0+0 +repage \
  /tmp/appkit-focus-interpreted-980x700.png

magick compare -metric AE \
  /tmp/appkit-focus-native.png \
  /tmp/appkit-focus-interpreted-980x700.png \
  /tmp/appkit-focus-diff.png
```

The normalized images differ at 4,850 of 686,000 pixels (0.707%). With a 2%
color fuzz, 4,682 pixels differ (0.683%); normalized RMSE is 0.02158. The
visible differences are concentrated in the missing native level meter and
the orange 4/5 status caused by the pasteboard failure.
