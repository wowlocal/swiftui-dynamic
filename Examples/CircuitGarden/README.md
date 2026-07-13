# Circuit Garden

An interactive 4×4 light puzzle. Pulsing a node flips it and its nearest
neighbors, while the app tracks moves, energy, the active pattern, reset
state, and completion.

It exercises nested data-driven views, custom value-model mutation, array
subscripts, button actions, conditional styles, progress, disabled state,
and SwiftUI state-driven rerendering.

Run it through Dynamic SwiftUI from the repository root:

```sh
swift run DynamicSwiftUIDemo --project Examples/CircuitGarden
```

Create a deterministic snapshot:

```sh
swift run DynamicSwiftUIDemo --project Examples/CircuitGarden \
  --render-png /tmp/circuit-garden.png --appearance dark
```

Run the native puzzle-logic checks:

```sh
swift test --package-path Examples/CircuitGarden
```

Run the same tests through the interpreter:

```sh
swift run TestCheck Examples --project CircuitGarden --all
```
