# IceCubes native twin

This harness compiles IceCubes' real local `Timeline`, `Models`,
`NetworkClient`, `StatusKit`, `DesignSystem`, `Env`, `Account`, and
`AppAccount` packages as a Catalyst app. A fail-closed `URLProtocol` serves
the recorded Mastodon fixture and a deterministic solid PNG for image
requests; no request falls through to the live network.

`build.sh` supplies the Catalyst SDK paths that Xcode normally adds and
assembles the SwiftPM executable into a minimally signed app bundle so the
real SwiftUI/UIKit lifecycle exists. The driver decodes the public timeline
through `MastodonClient`, renders the actual `StatusesListView` in a live
window, appends the recorded real boost used by the R1 probe, and captures its
fixed 900×700 content hierarchy. It then installs the same `QuickLook`
namespace as IceCubes' app dependency graph and captures the boost's real image
row as `media.png`. Alongside `timeline.png`, `timeline.json` records
expectations derived from the decoded models: status count, display names, raw
HTML-derived text, the trending detail's native Markdown, media count, the
focused media URL, and the replay request log. The latter proves that the
single-image row requests the attachment's original JPEG, while replay supplies
the deterministic solid PNG.
`FrozenClock.c` is one harness-level interposer for
Foundation's wall-clock `Date()` construction. The board injects the same
fixed epoch into both processes while leaving monotonic scheduling clocks live.

`ImageRenderer` cannot rasterize UIKit-backed `List` content (it emits the
framework's prohibited-render placeholder), the same headless limitation
already documented by the FoodTruck twin. The twin therefore rasterizes the
actual fixed-size SwiftUI hierarchy after it is installed in a live Catalyst
window; it does not replace or reconstruct the app view.

From the repository root, run `Scripts/icecubes-r2.sh` to build and capture
both the native and interpreted sides and print the exact AE.
