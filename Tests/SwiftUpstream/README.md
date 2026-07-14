# Official Swift upstream parity corpus

This directory contains a deliberately small set of executable tests copied
without source changes from the official Swift repository, plus a complete
machine-readable intake inventory for the concurrency runtime suite:

- repository: <https://github.com/swiftlang/swift.git>
- release: `swift-6.3.3-RELEASE`
- commit: `064859e41d68596f486c5d724401cb370f260409`
- upstream directories: `test/Interpreter` and `test/Concurrency/Runtime`

`SwiftUpstreamParityTests` compiles and runs every fixture with the active
native `swiftc`, runs the exact same file through `SwiftInterpreter`, and
checks both results against the fixture's oracle. The original interpreter
fixtures compare stdout byte-for-byte. Selected concurrency fixtures use a
strict literal subset of FileCheck (`CHECK`, `CHECK-NEXT`, `CHECK-SAME`,
`CHECK-DAG`, `CHECK-NOT`, and `CHECK-LABEL`); regexes and variables are
rejected instead of silently weakened. LLVM `lit` and FileCheck are therefore
not required by this repository.

Fixtures with an async `@main` declaration receive one generic harness entry
when interpreted (`await <detected type>.main()`). Their checked-in source is
not rewritten, and native Swift always compiles the unmodified fixture.

`inventory.json` classifies every Swift source in
`test/Concurrency/Runtime` as `direct`, `diagnostic`, `needs-adapter`, or
`unsupported`, with a non-empty reason. `direct` is intentionally an allowlist:
a test reaches it only after native Swift 6 compilation and deterministic
interpreter review. The inventory makes unsupported cases visible without
pretending that an unexecuted upstream test passes.

The current concurrency allowlist contains five unchanged runtime fixtures.
`async_taskgroup_is_empty.swift` is the first fixture whose admission is backed
by dispatch generated from the active SDK's `_Concurrency.swiftinterface`; it
also exercises the SDK's deprecated `TaskGroup.async` compatibility spelling.

The corpus is checked in so normal test runs do not need network access. To
refresh it reproducibly, run:

```sh
Scripts/sync-swift-upstream-tests.sh
```

The sync script uses a depth-one, blob-filtered sparse checkout, verifies the
resolved commit, copies only manifest-selected fixtures byte-for-byte, and
regenerates the complete concurrency inventory. Additions should stay
self-contained and deterministic: no SDK-specific inputs, auxiliary modules,
unstable output, or `StdlibUnittest` dependency.

The imported files are distributed under Swift's Apache License 2.0 with
Runtime Library Exception; see `LICENSE.txt` in this directory.
