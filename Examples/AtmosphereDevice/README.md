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
runs normally in Debug. The package keeps `SwiftInterpreter` optimized for iOS
Debug builds because Swift's `-Onone` stack frames for its large syntax
dispatch functions exceed the iOS main-thread stack at valid nesting depths;
the app and bridge remain debuggable.

Add `--stress-evaluator-stack` as a launch argument to verify on-device that
runaway interpreted recursion is converted into a fatal `RuntimeError` before
Atmosphere renders, rather than overflowing the native stack.
