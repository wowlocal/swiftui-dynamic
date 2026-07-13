# Synth Lab

An interactive three-voice synthesizer control surface. It exercises custom
models and subviews, data-driven `ForEach` content, gradients, shapes,
progress, buttons, state, slider and toggle bindings, and adaptive colors.

Run it through Dynamic SwiftUI from the repository root:

```sh
swift run DynamicSwiftUIDemo --project Examples/SynthLab
```

Create a deterministic snapshot:

```sh
swift run DynamicSwiftUIDemo --project Examples/SynthLab \
  --render-png /tmp/synth-lab.png --appearance dark
```
