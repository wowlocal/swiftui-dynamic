# Dynamic SwiftUI

<p align="center">
  <strong>Run Swift and SwiftUI source at runtime — from a single live-edited view to a real multi-file app.</strong>
</p>

<p align="center">
  <img alt="Swift 6.2+" src="https://img.shields.io/badge/Swift-6.2%2B-F05138?logo=swift&logoColor=white">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white">
  <img alt="iOS 18+" src="https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white">
  <img alt="Status: experimental" src="https://img.shields.io/badge/status-experimental-orange">
</p>

Dynamic SwiftUI is a tree-walking Swift interpreter built with
[SwiftSyntax]. It evaluates Swift source inside a running app and turns
interpreted `View` values into real SwiftUI views — with state, bindings,
observation, navigation, networking, and async work kept alive across
re-renders.

This is not a WebView, a JSON UI schema, or a reimplementation of SwiftUI.
Generated, statically compiled gateways call the platform's actual SwiftUI,
Foundation, AppKit, and UIKit APIs.

![Perihelion exoplanet observation desk running through Dynamic SwiftUI](Docs/perihelion-interpreted-demo.png)

<p align="center"><em>Perihelion running from interpreted multi-file Swift source: Observation state, custom orbital geometry, materials, controls, and the real Swift Charts renderer.</em></p>

## Why it is interesting

- **Edit and run SwiftUI without rebuilding the host.** The included demo puts
  a source editor beside a live, interactive preview.
- **Load whole projects.** Merge Swift files, discover the `@main App`
  composition root, preserve project resources, and render the app's own model
  graph rather than a hand-built fixture.
- **Use native framework behavior.** Supported SDK calls cross typed gateways
  into the frameworks already installed on the target platform.
- **Keep source semantics alive.** `@State`, `@Binding`, Observation,
  `ObservableObject`, environment values, representables, task lifecycles, and
  actor mailboxes participate in the running view tree.
- **Measure against native Swift.** The repository includes compiled twins,
  same-source differential tests, deterministic network replay, pixel boards,
  interaction boards, and a large real-project corpus.

## Quick start

You need macOS and an Xcode toolchain capable of building a Swift 6.2 package.
The current checkout is verified with Apple Swift 6.3.3 and the macOS 26.5 SDK;
the package deployment targets are macOS 15 and iOS 18.

```bash
git clone https://github.com/wowlocal/swiftui-dynamic.git
cd swiftui-dynamic
xcrun swift run DynamicSwiftUIDemo
```

The demo opens with **Atmosphere**, a live weather and air-quality app. Edit its
Swift source on the left; the interpreted SwiftUI hierarchy updates on the
right. The default demo uses live HTTP for city search and forecast data.

For a deterministic offline run, replay the checked-in Lisbon responses:

```bash
xcrun swift run DynamicSwiftUIDemo \
  --project Examples/Atmosphere \
  --network replay:Fixtures/open-meteo-lisbon
```

Or launch a larger multi-file project directly:

```bash
xcrun swift run DynamicSwiftUIDemo \
  --platform macOS \
  --project Examples/Perihelion/Sources/Perihelion
```

**Perihelion** is an original exoplanet observation desk designed as a normal,
native SwiftUI product rather than around a curated interpreter subset. Its
animated orbital map, searchable catalog, Observation model, asynchronous scan,
Charts spectrum, instrument controls, event stream, and field notes all come
from the same multi-file source that also builds as a standalone Swift package.

You can also render a sample to a deterministic PNG without opening the editor:

```bash
xcrun swift run DynamicSwiftUIDemo \
  --sample Calculator \
  --appearance dark \
  --render-png /tmp/calculator.png
```

The built-in picker includes Perihelion, Atmosphere, Counter, Calculator,
Tic-Tac-Toe, Todo, Form, Weather, Layout, List, Segments, Material, Popup, and
Albums.

## Example gallery

The repository includes examples at very different levels of difficulty. The
same runner that displays a counter also loads apps with native platform views,
network clients, structured concurrency, Charts, and GPU compute.

Run any source-only example with:

```bash
xcrun swift run DynamicSwiftUIDemo --project <example-directory>
```

| Example | What the interpreter executes | Executable evidence |
| --- | --- | --- |
| [Perihelion](Examples/Perihelion) | An original multi-file exoplanet observation desk with an interactive orbital field, custom shapes, Observation state, async scan lifecycle, searchable and pinnable data, Swift Charts spectra, sheets, sliders, filters, and a reactive event log. | The directory is also a standalone Swift package. It builds natively, then the same files are merged into the built-in picker and whole-project interpreter runner; the README screenshot is captured from that interpreted run. |
| [Atmosphere](Examples/Atmosphere) | Six Swift files; an actor-based generic API client, three-stage Open-Meteo request flow, nested Codable models, observable state, debounced search, animations, and interpreted custom `Shape` geometry. | Live HTTP and a checked-in Lisbon replay exercise the same source. Focused tests assert the typed query, all three requests, decoded models, and rendered values. |
| [Task Observatory](Examples/TaskObservatory) | `async let`, task groups, priorities, cancellation handlers, `Task.sleep`, `Task.yield`, shared `Task.value`, `@MainActor`, and `@concurrent` methods in one interactive dashboard. | Its checklist observes joined children, completion-order reduction to `orbit-10`, cancellation delivery, two waiters receiving one result, and runtime cleanup. |
| [Circuit Garden](Examples/CircuitGarden) | A mutable 4×4 puzzle model, nested collection views, array-subscript writes, button actions, conditional styling, disabled state, and state-driven re-rendering. | The same puzzle tests run natively with SwiftPM and through `TestCheck` over interpreted source. |
| [Synth Lab](Examples/SynthLab) | A three-voice control surface with nested models, `ForEach`, gradients, shapes, progress, sliders, toggles, bindings, and adaptive colors. | The CLI can drive the live UI or render a deterministic dark snapshot. |
| [Apple Food Truck](Examples/FoodTruckBuildingASwiftUIMultiplatformApp) | The 82-file Apple sample: its `@main App`, `NavigationSplitView`, model graph, Charts, resources, sidebar navigation, order workflow, and donut editing. | A compiled native twin and the interpreter agree on all 18 scored screens at pixel AE 0; mutation and live-navigation boards are green. |
| [AppKit Metal Signal](Examples/AppKitMetalSignal) | Real AppKit and Metal calls: runtime MSL compilation, compute dispatch, shared-buffer readback, bitmap creation, telemetry, and PNG export. | Native and interpreted runs produce the same GPU bytes and Aurora checksum; the 480×300 preview crop is pixel-identical. |
| [AppKit Pixel Relay](Examples/AppKitPixelRelay) | URLSession download, `NSBitmapImageRep` decode, nested pixel loops, `NSColor` transforms, histogram calculation, `NSImage`, pasteboard, and PNG export. | The end-to-end interpreter pipeline reproduces the native 2,067-byte PNG, checksum `328447`, and average color `#233427`. |
| [IceCubes native twin](Examples/IceCubesNativeTwin) | A networked, multi-package Mastodon client with app-owned view models, HTML/AttributedString content, pagination, navigation, media, Observation, and UIKit-hosted lists. | Eleven deterministic screens, nine functional rungs, live HTTP invariants, and two post-mutation scenarios are compared against the compiled Catalyst app. |

The AppKit examples use a source directory inside their package and an explicit
platform identity. For example:

```bash
METAL_SIGNAL_AUTORENDER=1 \
  xcrun swift run DynamicSwiftUIDemo \
  --platform macOS \
  --project Examples/AppKitMetalSignal/Sources/AppKitMetalSignal
```

## What interpreted Swift looks like

These are ordinary Swift declarations consumed by the runtime. They are not a
parallel DSL or a serialized view format.

<details>
<summary><strong>Observation + SwiftUI task lifecycle + structured concurrency</strong></summary>

```swift
@Observable
final class Loader {
    var phase = "pending"

    func load() async {
        phase = await withTaskGroup(of: String.self) { group in
            group.addTask { "loaded" }
            return await group.next() ?? "missing"
        }
    }
}

struct ContentView: View {
    @State private var loader = Loader()

    var body: some View {
        Text(loader.phase)
            .task { await loader.load() }
    }
}

ContentView()
```

The integration test in
[`InterpreterHostSchedulingTests.swift`](Tests/SwiftUIBridgeTests/InterpreterHostSchedulingTests.swift)
hosts this source, lets real SwiftUI start `.task`, and requires the rendered
tree to change from `pending` to `loaded`.

</details>

<details>
<summary><strong>Actor identity, isolated mutation, and awaited calls</strong></summary>

```swift
actor Counter {
    var value = 0

    func bump() async -> Int {
        value += 1
        return value
    }
}

let counter = Counter()
var seen: [Int] = []

func drive() async {
    seen.append(await counter.bump())
    seen.append(await counter.bump())
}

await drive()
seen
```

This exact program is pinned by
[`ActorExecutionTests.swift`](Tests/SwiftUIBridgeTests/ActorExecutionTests.swift):
the interpreter must produce `[1, 2]`. The broader concurrency suite additionally
checks mailbox ownership, suspension/re-entry, cross-actor failure and
cancellation, task-local preservation, and actor cleanup against native Swift.

</details>

<details>
<summary><strong>Generic Codable networking inside a source actor</strong></summary>

```swift
actor AtmosphereClient {
    private let decoder = JSONDecoder()

    private func request<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            throw AtmosphereError.server(response.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }

    func snapshotForPlace(_ place: Place) async throws -> AtmosphereSnapshot {
        let forecast = try await request(Forecast.self, from: weatherURL(place))
        let air = try await request(AirQuality.self, from: airURL(place))
        return AtmosphereSnapshot(place: place, forecast: forecast, air: air)
    }
}
```

The complete implementation is
[`AtmosphereClient.swift`](Examples/Atmosphere/AtmosphereClient.swift). The
runtime preserves the generic `T` selected at each call, executes URLComponents
and URLSession through host contracts, synthesizes nested Codable values, and
returns across the actor boundary before the observable store updates SwiftUI.

</details>

<details>
<summary><strong>A source-defined Shape drawing through real SwiftUI</strong></summary>

```swift
struct TemperatureCurve: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        Path { path in
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let spread = max(1.0, high - low)

            for index in values.indices {
                let x = rect.minX
                    + rect.width * CGFloat(index) / CGFloat(values.count - 1)
                let ratio = (values[index] - low) / spread
                let y = rect.maxY - rect.height * CGFloat(ratio)

                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }
}
```

SwiftUI supplies the `CGRect`; the interpreted `path(in:)` performs the
geometry; the returned real `Path` continues through native `.fill`, `.stroke`,
`.trim`, animation, and compositing. See the complete component in
[`Components.swift`](Examples/Atmosphere/Components.swift).

</details>

## Embed the runtime

The package exposes two library products:

- `SwiftInterpreter` — the framework-neutral Swift execution engine.
- `SwiftUIBridge` — the native SwiftUI and Apple SDK bridge.

The high-level bridge API is deliberately small:

```swift
import SwiftUIBridge

let source = #"""
struct Greeting: View {
    @State private var count = 0

    var body: some View {
        Button("Hello \(count)") {
            count += 1
        }
        .buttonStyle(.borderedProminent)
    }
}

Greeting()
"""#

let rendered = InterpreterHost().render(source: source)
// Result<AnyView, RuntimeError>
```

For whole projects, `InterpreterHost` also accepts a target-aware
`ProjectBuildManifest`, optional compiler preflight, an explicit platform
configuration, and a project resource root.

## What runs today

Dynamic SwiftUI implements a practical, demand-driven subset of Swift rather
than a toy expression language.

| Area | Current coverage |
| --- | --- |
| Swift language | Functions and closures, structs and classes, enums with associated values, protocols and extensions, generics, optionals, collections, subscripts, key paths, control flow, error handling, property observers, result builders, Codable synthesis, and value/reference semantics across calls and storage. |
| SwiftUI | Stacks, lists, forms, grids, navigation, tabs, controls, presentations, environment propagation, shapes and paths, gradients, styles, toolbars, representables, custom `View` bodies, and hundreds of generated initializers and modifiers. |
| State and data flow | `@State`, `@Binding`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject`, typed Observation environments, `@Observable`, `@Published`, bindable projections, and an in-memory query store for SwiftData/Core Data-shaped flows. |
| Concurrency | `async`/`await`, `Task`, cancellation, task groups, async let, task locals, clocks, continuations, async sequences, actor identity/mailboxes, executor hops, SwiftUI `.task`, and opt-in bounded physical execution for explicitly admitted Sendable work. |
| Apple SDKs | Generated SwiftUI, Foundation, AppKit, UIKit, Core Graphics, QuartzCore, WebKit, MapKit, Core Location, Metal, Charts, StoreKit, PhotosUI, MusicKit, Symbols, and related overlay surface. |
| Projects and I/O | Multi-file source loading, `@main App` discovery, resources, target-aware conditional compilation, URLSession live/replay modes, JSON decoding, sandboxed file operations, and located runtime diagnostics. |

Coverage is intentionally grown from real source demand. An unsupported call
is a runtime boundary to improve, not an invitation to add an app-specific
shortcut.

## Proven on real apps

The project treats native Swift as the oracle. Expectations come from code
compiled with the same Xcode toolchain, not from values copied into interpreter
tests.

![Apple's Food Truck sample running through Dynamic SwiftUI](Docs/evidence-foodtruck-live-window-2026-07-17.png)

<p align="center"><em>Apple's 82-file Food Truck sample running through the interpreter on macOS.</em></p>

| Board | Current committed result |
| --- | --- |
| Apple Food Truck | 18/18 deterministic screen captures at pixel AE 0; model mutation and live navigation boards green. |
| IceCubes | 10 of 11 scored screens at pixel AE 0; the remaining screen differs on two classified antialiasing pixels. Both committed cross-screen interaction scenarios match the compiled Catalyst twin exactly. |
| Real-project corpus | 678/680 project units pass in the full corpus; the standalone 586-unit corpus is 586/586. The two accepted full-corpus misses are explicit ledger entries, not silently skipped checks. |
| Generated API parity | 345/345 stable compiled-vs-interpreted probes match, with zero divergences and zero interpreter errors; 17 clock/locale-volatile probes are reported separately. |
| Replay networking | 5/5 deterministic live-data scenarios pass against recorded TMDB and Mastodon responses plus bundled app resources. |
| Concurrency parity | 264 manifest-owned cases and 5,128 bounded native/interpreter repetitions cover successes, diagnostics, traps, cancellation, cleanup, ownership, and physical-worker boundaries. |

The IceCubes boards go beyond first render: they run the app's own Mastodon
client and view models, paginate a timeline, push status detail, switch
destinations, and compare post-interaction output with a compiled native twin.
Live HTTP is checked separately so fixture determinism cannot hide schema drift.

## SDK coverage is generated

Hand-writing one bridge for every SDK overload does not scale. `BridgeGen`
reads the SDK's `swiftinterface` files and Clang-imported symbol graphs, maps
their type structure into reusable coercions, and emits statically compiled
gateways.

The checked-in generated surface currently includes:

- **1,076 modifier overload variants** across **392 names**;
- **746 initializer variants** across **115 SwiftUI structs**;
- **272 value-type properties** and **232 method variants**;
- **1,020 Foundation reference-type property contracts**;
- **221 contextual SDK value types** and **60 environment writers**; and
- generated platform constructors, properties, methods, globals, and
  contextual values across AppKit, UIKit, and Metal.

Every emitted call is compiled against the real framework. Incorrect signatures
therefore fail during the build, while overload selection at runtime still uses
the labels, defaults, generic constraints, effects, and coercible parameter
types parsed from the interface.

Regenerate or inspect coverage with:

```bash
xcrun swift run BridgeGen --emit
xcrun swift run BridgeGen --report-json .build/bridgegen-coverage.json
```

Ordinary API gaps must be fixed in interface analysis, type mapping, coercion,
or a reusable generated adapter. Handwritten bridge code is reserved for
framework semantics an interface cannot express, such as result-builder
execution, framework-supplied closure inputs, state identity, child identity,
and preservation of opaque `View`, `Shape`, and `ShapeStyle` values. The
binding development rule lives in [`AGENTS.md`](AGENTS.md).

## How it works

```text
Swift source files
      │
      ▼
SwiftParser + SwiftOperators
      │  parsed and precedence-folded syntax
      ▼
immutable declaration, call-site, type, and source indexes
      │
      ▼
tree-walking evaluator ───────▶ task runtime / actor mailboxes
      │
      ▼
typed HostRegistry contracts
      │
      ├──▶ BridgeGen gateways ──▶ real SwiftUI / Foundation / platform APIs
      │
      └──▶ semantic adapters for interface-inexpressible SwiftUI behavior
      │
      ▼
AnyView hosted by SwiftUI
```

The interpreter core does not import SwiftUI. It produces `RuntimeValue`s and
talks through typed host contracts. `SwiftUIBridge` owns framework-specific
behavior and wraps a source-defined `View` in `InterpretedView`; when SwiftUI
asks for `body`, the interpreter evaluates that source body. State writes
publish through the same hosted tree, causing SwiftUI to request it again.

For the deeper design, see
[`Docs/InterpreterArchitecture.md`](Docs/InterpreterArchitecture.md).

## Verification

Run the public test suite with:

```bash
xcrun swift test
```

The full development closing gate runs test shards, same-source concurrency
parity, project-corpus evaluation, generated API parity, replay networking,
anti-drift checks, and the deterministic IceCubes pixel and interaction boards:

```bash
Scripts/gate.sh
```

The closing gate expects the repository's pinned external OSS corpus and native
twin inputs; a fresh public checkout can run `swift test`, the bundled examples,
BridgeGen, and the checked-in Atmosphere replay without that external working
set. Parallelism and gate tuning are documented in
[`Docs/ParallelVerification.md`](Docs/ParallelVerification.md).

Concurrency claims are machine-owned rather than inferred from syntax support:

- [`Docs/SwiftConcurrencyArchitecture.md`](Docs/SwiftConcurrencyArchitecture.md)
  defines the target architecture and milestone boundaries.
- [`Tests/ConcurrencyParity/Manifests/milestone-acceptance.json`](Tests/ConcurrencyParity/Manifests/milestone-acceptance.json)
  is the status source of truth.
- [`Docs/ConcurrencyVerificationMethodology.md`](Docs/ConcurrencyVerificationMethodology.md)
  explains native baselines, negative controls, repetition, and receipts.
- [`Docs/ConcurrencyParity.md`](Docs/ConcurrencyParity.md) records the evidence
  behind each landed slice.

## Current boundaries

Dynamic SwiftUI is an experimental runtime, not a replacement for `swiftc` or
an App Store production dependency yet.

- The evaluator implements a growing Swift subset; it does not provide general
  compiler-grade type inference or exhaustive language coverage. Optional
  compiler preflight can fail closed against a real Apple target before a
  project runs.
- Cooperative execution is the default. Physical parallelism is opt-in and
  only admits operations that can cross the checked Sendable snapshot boundary;
  the remaining M9 surface is explicitly partial.
- Device-, account-, entitlement-, persistence-, and hardware-backed services
  use deterministic fresh-state or inert behavior unless a real host gateway is
  available. The native twin decides what parity can honestly be claimed.
- Some compiler ownership features, including general coroutine `_read` and
  `_modify` accessors, are diagnosed at the point of demand rather than
  approximated.
- Re-parsing source starts a new program generation, so live edits intentionally
  reset program state that may no longer match the edited declarations.

These constraints are deliberate and tested. Unsupported behavior should be
visible, located, and attributable — never hidden behind a fixture-specific
success path.

## Repository map

| Path | Purpose |
| --- | --- |
| [`Sources/SwiftInterpreter`](Sources/SwiftInterpreter) | Parser integration, runtime values, evaluator, sessions, concurrency, and host contracts. |
| [`Sources/SwiftUIBridge`](Sources/SwiftUIBridge) | SwiftUI semantics, native hosting, platform adapters, and generated gateways. |
| [`Sources/BridgeGen`](Sources/BridgeGen) | Interface and symbol-graph analysis plus code generation. |
| [`Sources/DynamicSwiftUIDemo`](Sources/DynamicSwiftUIDemo) | Live editor, project runner, snapshot mode, and interaction sweep. |
| [`Examples`](Examples) | Bundled interpreted apps, native twins, and focused platform demos. |
| [`Tests`](Tests) | Unit, integration, native differential, compiler-preflight, platform, and concurrency parity suites. |
| [`Scripts`](Scripts) | Closing gate, capture boards, corpus runners, and verification tooling. |

## Contributing

Start with a minimal source reproducer and a native Swift observation. Add a
focused regression test, improve the reusable runtime or generated bridge
mechanism, regenerate checked-in outputs when needed, and finish with the
relevant parity board. Do not edit files under
`Sources/SwiftUIBridge/Generated/` by hand.

Dynamic SwiftUI was inspired by [Bitrig's Swift interpreter series][bitrig-1]
and [Cocoanetics/SwiftScript][swiftscript].

[SwiftSyntax]: https://github.com/swiftlang/swift-syntax
[bitrig-1]: https://bitrig.com/blog/swift-interpreter
[swiftscript]: https://github.com/Cocoanetics/SwiftScript
