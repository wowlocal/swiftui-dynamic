# Official Swift upstream parity corpus

This directory contains a deliberately small set of executable tests copied
without source changes from the official Swift repository:

- repository: <https://github.com/swiftlang/swift.git>
- release: `swift-6.2.3-RELEASE`
- commit: `484e622d1c0afcae5b12a31c090a74ad0901e44f`
- upstream directory: `test/Interpreter`

`SwiftUpstreamParityTests` compiles and runs every fixture with the active
native `swiftc`, runs the exact same file through `SwiftInterpreter`, and
compares stdout byte-for-byte. The original `RUN`, `REQUIRES`, and `CHECK`
comments remain in each fixture as upstream provenance; LLVM `lit` and
`FileCheck` are not required by this repository.

The corpus is checked in so normal test runs do not need network access. To
refresh it reproducibly, run:

```sh
Scripts/sync-swift-upstream-tests.sh
```

The sync script uses a depth-one, blob-filtered sparse checkout containing only
`test/Interpreter` and verifies the resolved commit before copying the selected
files. Additions should stay self-contained and deterministic: no SDK-specific
inputs, auxiliary modules, unstable output, or `StdlibUnittest` dependency.

The imported files are distributed under Swift's Apache License 2.0 with
Runtime Library Exception; see `LICENSE.txt` in this directory.
