# Atmosphere

This is the split-file version of the interpreted Atmosphere demo. The demo
host merges these Swift files, interprets them together, and renders
`ContentView` through real SwiftUI. City input is debounced and backed by the
live geocoding endpoint; matching places appear in a tappable overlay.

Run deterministically with the committed network responses:

```bash
swift run DynamicSwiftUIDemo \
  --project Examples/Atmosphere \
  --network replay:Fixtures/open-meteo-lisbon
```

Or call the live Open-Meteo services:

```bash
swift run DynamicSwiftUIDemo \
  --project Examples/Atmosphere \
  --network live
```
