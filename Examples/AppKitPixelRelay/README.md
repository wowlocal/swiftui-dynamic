# AppKit Pixel Relay

Pixel Relay is a functional macOS network image-processing workbench. It uses
`URLSession` to download a PNG, `NSBitmapImageRep` and `NSColor` to transform
every pixel and calculate a histogram, `NSImage` for the preview, and AppKit
PNG encoding, pasteboard, and file export APIs.

The UI has four independently testable effects, a continuous intensity
control, live download/encoding telemetry, a luminance histogram, digest copy,
and PNG export. The bundled 96 × 64 fixture keeps network and pixel tests
deterministic while still exercising a real HTTP request.

Run the interpreted app from the repository root:

```bash
swift run DynamicSwiftUIDemo \
  --platform macOS \
  --network live \
  --project Examples/AppKitPixelRelay/Sources/AppKitPixelRelay
```

Run the same shared source natively:

```bash
swift run --package-path Examples/AppKitPixelRelay AppKitPixelRelayNative
```

The deterministic network test uses the included fixture over localhost:

```bash
python3 -m http.server 8765 \
  --directory Examples/AppKitPixelRelay/Fixtures
```

In another shell, run the native self-test:

```bash
swift run --package-path Examples/AppKitPixelRelay \
  AppKitPixelRelayNative --self-test \
  --url http://127.0.0.1:8765/pixel-relay-source.png
```

Set `PIXEL_RELAY_AUTOFETCH_URL` to the same URL to make either UI fetch and
process the fixture on launch. The export button writes
`/tmp/appkit-pixel-relay-export.png` by default; override it with
`PIXEL_RELAY_EXPORT_PATH`.

## Verification on 2026-07-13

The native package builds successfully. Its self-test made one HTTP request and
passed all 9 checks:

- HTTP 200 with the complete 3,171-byte payload
- 96 × 64 `NSBitmapImageRep` decode
- four effects with four distinct output checksums
- zero-intensity identity behavior
- a normalized 12-bin luminance histogram
- AppKit PNG encoding and `NSImage` construction
- byte-for-byte export round-trip

The native UI autoload also completed one job and produced a 2,067-byte warm
PNG with checksum `328447` and average color `#233427`.

After the generated AppKit bridge repair, the public interpreter CLI completes
the same live workflow end to end. It received HTTP 200 with all 3,171 bytes,
decoded and transformed the 96 × 64 bitmap, produced the same 2,067-byte warm
PNG, checksum `328447`, and average color `#233427`, then reported one completed
UI job. The deterministic interpreter integration test also runs the actual
Pixel Relay pipeline over the bundled 96 × 64 fixture; it completed in 7.69 s
on the verification machine.

The repair is generator-level rather than app-specific: SDK-derived failable
constructors, inherited members, dictionary parameters, nil unsafe-pointer
parameters, platform-valued SwiftUI initializers such as `Image(nsImage:)`, and
CoreGraphics compatibility aliases now share reusable generated contracts.
Finite `for-in` loops also receive bounded per-element evaluator slices, so
legitimate nested pixel work can exceed the global syntax-step count while an
infinite loop inside any element still trips the fatal budget guard.

## Pixel diff

The native renderer produced the requested 1,100 × 760 image. The interpreter
produced 1,100 × 774, adding 14 pixels of bottom canvas. After a north-aligned
crop to the common 1,100 × 760 region:

- exact absolute-error pixels: `13,779 / 836,000` (`1.6482%`)
- absolute-error pixels with 2% fuzz: `10,592 / 836,000` (`1.2670%`)
- normalized RMSE: `0.0136578`

In other words, 98.35% of pixels match exactly after size normalization. The
major layout, artwork, controls, spacing, and colors align visually; remaining
differences are concentrated around text/control rasterization, the focused
text field, and a few shape edges.

Reproduce the snapshots and comparison from the repository root:

```bash
Examples/AppKitPixelRelay/.build/arm64-apple-macosx/debug/AppKitPixelRelayNative \
  --render-png /tmp/appkit-pixel-relay-native.png \
  --size 1100x760 --appearance dark

.build/arm64-apple-macosx/debug/DynamicSwiftUIDemo \
  --platform macOS \
  --project Examples/AppKitPixelRelay/Sources/AppKitPixelRelay \
  --render-png /tmp/appkit-pixel-relay-interpreted.png \
  --size 1100x760 --appearance dark

magick /tmp/appkit-pixel-relay-interpreted.png \
  -gravity north -crop 1100x760+0+0 +repage \
  /tmp/appkit-pixel-relay-interpreted-normalized.png

magick compare -metric AE \
  /tmp/appkit-pixel-relay-native.png \
  /tmp/appkit-pixel-relay-interpreted-normalized.png null:

magick compare -metric RMSE \
  /tmp/appkit-pixel-relay-native.png \
  /tmp/appkit-pixel-relay-interpreted-normalized.png null:
```
