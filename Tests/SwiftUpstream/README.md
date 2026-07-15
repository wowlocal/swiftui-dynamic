# Official Swift upstream parity corpus

This directory contains a deliberately small set of executable tests copied
without source changes from the official Swift repository, plus a complete
machine-readable intake inventory for the concurrency runtime suite:

- repository: <https://github.com/swiftlang/swift.git>
- release: `swift-6.3.3-RELEASE`
- commit: `064859e41d68596f486c5d724401cb370f260409`
- upstream directories: `test/Interpreter` and selected `test/Concurrency`
  compiler/runtime paths

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

The current concurrency allowlist contains twelve unchanged runtime fixtures.
`async_taskgroup_is_empty.swift` is the first fixture whose admission is backed
by dispatch generated from the active SDK's `_Concurrency.swiftinterface`; it
also exercises the SDK's deprecated `TaskGroup.async` compatibility spelling.
`async_taskgroup_addUnlessCancelled.swift` adds the first direct discarding-group
oracle and checks its already-cancelled conditional-add behavior against the
ordinary task-group contract.
`async_taskgroup_cancel_then_spawn.swift` proves the deprecated
`spawnUnlessCancelled` spelling returns `true` and delivers a child before
cancellation, returns `false` without a child afterward, and contrasts it with
unconditional `spawn` creating an already-cancelled child. Its unused
`import Dispatch` is retained byte-for-byte rather than adapted away.
`async_taskgroup_throw_recover.swift` independently covers recovery after a
throwing-group child failure followed by nonthrowing `nextResult()` delivery.
`async_taskgroup_is_asyncsequence.swift` exercises the deprecated `spawn`
aliases on ordinary and throwing groups while draining both through async
iteration, with result sums that do not depend on child scheduling order.

Every allowlisted fixture has a manifest SHA-256, so a local edit fails before
native/interpreted comparison instead of silently weakening the pinned oracle.
The pinned compiler corpus also includes
`test/Concurrency/taskgroup_cancelAll_from_child.swift` unchanged. Production
compiler preflight typechecks it in Swift 6 strict-concurrency mode and checks
the upstream `inout TaskGroup` capture diagnostics.

The unchanged `test/Concurrency/sendable_checking_captures_swift6.swift`
extends that production boundary to Swift 6 `@Sendable` local-function,
closure, and mutable `inout` capture errors. The harness requires error
severity plus the upstream filename, line, and message fragment rather than
accepting an unrelated compiler failure.

The unchanged
`test/Concurrency/effectful_properties_async_if_optional_unwrap.swift`
pins the compiler's async-property diagnostics across ordinary reads,
optional binding, shorthand optional binding, and invalid `if let await`
syntax. Runtime gateway tests separately require a legal typed async getter to
enter a first-class host suspension before it can complete.

The exact upstream support inputs
`test/Concurrency/Inputs/GlobalActorIsolatedFunction.swift`,
`test/Concurrency/Inputs/GlobalVariables.swift`, and
`test/Concurrency/Inputs/implicit_nonisolated_things.swift` are also
SHA-pinned.
Production preflight compiles them as separate host declaration modules,
imports each module into a minimal client, and requires Swift 6 to preserve the
serialized `MainActor` isolation diagnostic for a global function and a static
property. The `GlobalVariables` module retains its upstream Swift 5 compiler
mode while its client remains checked in Swift 6. These auxiliary-module
oracles also require an extension member to inherit `MainActor` from an
imported nominal type. They test the same boundary that generated
bridge manifests use rather than copying expected diagnostic strings. The
small clients under `Clients/` are repository-owned oracle plumbing, not
upstream tests or independently claimed concurrency-parity cases.

The unchanged positive compiler oracle
`test/Concurrency/async_task_groups_and_actors.swift` is SHA-pinned alongside
those module inputs. Production preflight must accept its ordinary, throwing,
and discarding task groups inside `MainActor`-isolated code. This complements
the executable task-group fixtures by checking the isolation contract directly
against swiftlang source without treating the interpreter's generated routing
table as semantic proof.

The corpus is checked in so normal test runs do not need network access. To
refresh it reproducibly, run:

```sh
Scripts/sync-swift-upstream-tests.sh
```

The sync script uses a depth-one, blob-filtered sparse checkout, verifies the
resolved commit, copies only manifest-selected fixtures byte-for-byte, and
regenerates the complete concurrency inventory. Additions should stay
self-contained and deterministic: no SDK-specific inputs, unstable
output, or `StdlibUnittest` dependency. Auxiliary modules are admitted
only when their source is independently pinned and their compiler contract is
bounded by production preflight.

The imported files are distributed under Swift's Apache License 2.0 with
Runtime Library Exception; see `LICENSE.txt` in this directory.
