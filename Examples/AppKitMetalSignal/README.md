# AppKit Metal Signal Lab

Metal Signal Lab is a functional macOS GPU workbench built from shared AppKit,
SwiftUI, and Metal source. A runtime-compiled Metal Shading Language compute
kernel writes a deterministic 480 × 300 RGBA field into shared GPU memory;
AppKit converts that buffer into the preview and exported PNG.

The UI offers four shader modes, phase and spatial-scale uniforms, individual
dispatches, a 12-frame benchmark, raw-output checksum and luminance telemetry,
PNG export, and digest copy. No pre-rendered image is bundled with the example.

Run the interpreted project from the repository root:

```bash
swift run DynamicSwiftUIDemo \
  --platform macOS \
  --project Examples/AppKitMetalSignal/Sources/AppKitMetalSignal
```

Launch the same shared source with native Swift:

```bash
swift run --package-path Examples/AppKitMetalSignal AppKitMetalSignalNative
```

Run the native GPU checks:

```bash
swift run --package-path Examples/AppKitMetalSignal \
  AppKitMetalSignalNative --self-test

swift test --package-path Examples/AppKitMetalSignal
```

Set `METAL_SIGNAL_AUTORENDER=1` to compile and dispatch the shader as soon as
the UI appears. Export writes `/tmp/appkit-metal-signal.png` by default; set
`METAL_SIGNAL_EXPORT_PATH` to override it.

Create a deterministic dark snapshot with either runner by adding:

```bash
--render-png /tmp/metal-signal.png --size 1160x780 --appearance dark
```

## Verification on 2026-07-13

The native package builds on macOS and uses the machine's `Apple M4 Max` Metal
device. Its command-line self-test passed all 10 checks: device discovery,
compute dispatch, four distinct pattern outputs, deterministic repeated
uniforms, phase sensitivity, luminance range, sampled-color diversity, AppKit
PNG encoding, `NSImage` construction, and byte-for-byte export round-trip. At
320 × 200, the four pattern checksums were `832953`, `544489`, `932468`, and
`884591`. The Swift package's GPU regression test also passes.

The interpreter now executes the same Metal path through generated SDK
bindings. It discovers the real `Apple M4 Max`, compiles the runtime MSL,
encodes and waits for a command buffer, reads all 576,000 shared-buffer bytes,
writes AppKit bitmap storage, and encodes the PNG. Native and interpreted runs
produce the same Aurora checksum (`307310`), mean (`#0F1F36`), luminance range
(`98%`), and sampled-color count (`795`). A generated-bridge integration test
also dispatches an independent Metal kernel and verifies ABI struct layout,
owned pointer reads, writable AppKit memory, and PNG encoding.

One additional black-box API-shape difference surfaced: native Swift accepts
`Image(nsImage: image).resizable()`, while the runner diagnoses that chain as
`.resizable applies to Image`. The shared example displays its 480 × 300 image
at intrinsic size, which is accepted by both paths and avoids hiding the Metal
failure behind a separate image-modifier diagnostic.

## Pixel comparison

The idle-state comparison isolates the UI renderer from Metal and is exact:

- exact absolute-error pixels: `0 / 904,800` (`0.000%`)
- absolute-error pixels with 5/255 channel fuzz: `0 / 904,800` (`0.000%`)
- normalized RMSE: `0`

With `METAL_SIGNAL_AUTORENDER=1`, both sides show the same computed Aurora
field and telemetry. In the final verification run:

- exact absolute-error pixels: `313 / 904,800` (`0.035%`)
- absolute-error pixels with 5/255 channel fuzz: `231 / 904,800` (`0.026%`)
- normalized RMSE: `0.00292162`
- 480 × 300 GPU preview crop: `0 / 144,000` differing pixels (`0.000%`)

The remaining whole-window difference is the deliberately live GPU-duration
label: native and interpreted dispatch plumbing has different CPU overhead,
and neither value is deterministic, so the whole-window count varies between
runs. Every differing pixel in this run was inside that label's 48 × 9-pixel
bounding box; rendering, output bytes, derived metrics, layout, and every other
visible state match.

The interpreter prepares the repeated integer operations in large, finite
byte loops once while retaining the ordinary evaluator as an all-or-nothing
fallback for unsupported syntax and capture-sensitive bodies. On the same
debug build, the two-dispatch interpreted autorender snapshot now completes in
`3.83 s` (`3.63 s` user CPU), down from `72.09 s`; the native snapshot takes
`0.63 s`. Metal itself remains a few milliseconds on both paths. The remaining
gap is interpreter overhead, but it no longer presents as an application hang.

Reproduce both functional snapshots from the repository root with:

```bash
METAL_SIGNAL_AUTORENDER=1 \
  Examples/AppKitMetalSignal/.build/arm64-apple-macosx/debug/AppKitMetalSignalNative \
  --render-png /tmp/appkit-metal-signal-native.png \
  --size 1160x780 --appearance dark

METAL_SIGNAL_AUTORENDER=1 \
  .build/arm64-apple-macosx/debug/DynamicSwiftUIDemo \
  --platform macOS \
  --project Examples/AppKitMetalSignal/Sources/AppKitMetalSignal \
  --render-png /tmp/appkit-metal-signal-interpreted.png \
  --size 1160x780 --appearance dark

swift Scripts/pixel-ae.swift \
  /tmp/appkit-metal-signal-native.png \
  /tmp/appkit-metal-signal-interpreted.png
```
