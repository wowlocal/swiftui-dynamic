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

The interpreter run was tested only through the public project runner, without
inspecting interpreter implementation. The complete AppKit/SwiftUI workbench
renders, including gradients, controls, sliders, symbols, cards, and the idle
preview. Its idle 1160 × 780 snapshot is byte-for-byte pixel-identical to the
native snapshot.

Metal execution itself is not functional in that runner. Autorender reaches
the shared GPU pipeline, but the device name is empty and the shared-buffer
readback contains 0 bytes instead of the required 576,000. The pipeline's
general readback-size invariant catches that invalid result and the UI reports
`Metal returned 0 bytes; expected 576000.` rather than presenting a false
success. Runtime MSL compilation, command encoding, compute dispatch, and
buffer readback therefore need real Metal bridge semantics before this example
can produce its procedural image in the interpreter.

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

With `METAL_SIGNAL_AUTORENDER=1`, native shows the computed Aurora field while
the interpreter shows the caught Metal error state:

- exact absolute-error pixels: `245,594 / 904,800` (`27.143%`)
- absolute-error pixels with 5/255 channel fuzz: `244,145 / 904,800` (`26.983%`)
- normalized RMSE: `0.081006`

The functional diff is concentrated in the GPU preview, output metrics,
pipeline-state indicators, and status text. The surrounding UI stays aligned.
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
