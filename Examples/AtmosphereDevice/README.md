# Atmosphere on iPhone

This iOS host bundles the split Swift sources from `../Atmosphere` and renders
them at runtime through `InterpreterHost`. The source files are resources, not
members of the native app target.

Regenerate the Xcode project after editing `project.yml`:

```bash
cd Examples/AtmosphereDevice
xcodegen generate
```

Then select the `AtmosphereDevice` scheme and an iPhone in Xcode. The scheme
runs its optimized Release configuration because an unoptimized tree-walking
evaluator can exhaust iOS's comparatively small main-thread stack.
