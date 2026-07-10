# Atmosphere

This is the split-file version of the interpreted Atmosphere demo. The demo
host merges these Swift files, interprets them together, and renders
`ContentView` through real SwiftUI. City input is debounced and backed by the
live geocoding endpoint; matching places appear in a dismissible, tappable
overlay. The search field has clear and refresh actions, and the temperature
control switches the complete dashboard between Celsius and Fahrenheit with
animated numeric transitions. Ambient weather motion and staggered panel,
chart, sun, and air-quality reveals keep updates fluid without obscuring data.

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
