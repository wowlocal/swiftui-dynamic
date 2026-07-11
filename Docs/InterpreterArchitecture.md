# Interpreter architecture

The interpreter is organized as a language runtime with an explicit host
boundary. SwiftUI is a client of the runtime, not a language feature.

```text
source
  -> Parsing.swift
  -> DeclarationCollector.swift
  -> Eval/*Evaluator.swift
  -> RuntimeValue + RuntimePayload
  -> HostRegistry
  -> SwiftUIBridge / trace registries
```

## Responsibilities

- `Interpreter.swift` owns session state, caches, recursion state, and callable
  metadata. It should not accumulate syntax-feature implementations.
- `Parsing.swift` owns SwiftParser diagnostics and operator folding.
- `Eval/ProgramEvaluator.swift` owns top-level execution.
- `Eval/ExpressionEvaluator.swift` only routes expression syntax to the
  relevant feature evaluator.
- `Eval/MemberEvaluator.swift`, `CallEvaluator.swift`,
  `InvocationEvaluator.swift`, `OperatorEvaluator.swift`, and
  `LiteralEvaluator.swift` own their corresponding language semantics.
- `Eval/InstanceEvaluator.swift` owns interpreted instance construction,
  annotation resolution, and instance lifecycle behavior.
- `Runtime/` owns value representation, containers, built-ins, and execution
  limits. It must not import SwiftUI.
- `HostRegistry` is the only framework capability boundary. SwiftUIBridge and
  test registries implement it independently.

## Typed-runtime migration

`RuntimeValue.host(Any)` currently stores both opaque framework objects and
some Swift-shaped values inherited from the original prototype. Core evaluator
code must switch on `RuntimeValue.payload`, which exposes strings, arrays,
dictionaries, tuples, ranges, and primitives explicitly while preserving the
existing `hostPayload` contract for gateways.

This permits storage to migrate incrementally without another evaluator-wide
rewrite:

1. Route standard-library dispatch through `RuntimePayload`.
2. Add dedicated `RuntimeValue` storage for strings and collections behind
   the stable payload/accessor APIs.
3. Separate value-backed struct storage from reference-backed class and model
   storage.
4. Add copy-in/copy-out semantics at assignment, argument, and closure
   boundaries.
5. Make evaluator suspension and cancellation explicit before adding real
   concurrent task execution.

New core code should not downcast `host(Any)` to a Swift-shaped value. Direct
downcasts are reserved for opaque host/framework implementations and should be
kept at the registry boundary or in a clearly named compatibility path.

## Verification invariants

Every migration step must keep these layers green:

1. `swift test --filter SwiftInterpreterTests` for language semantics.
2. `swift test` for SwiftUI integration and state behavior.
3. `ParityCheck` for generated Foundation behavior.
4. `ProjectCheck` and `LiveCheck` for real-project compatibility.

Architectural refactors should be behavior-preserving unless a semantic change
has a native Swift cross-check and a dedicated regression test.
