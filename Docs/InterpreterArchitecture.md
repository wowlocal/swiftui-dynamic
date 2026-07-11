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

## Runtime-value migration

`RuntimeValue` stores primitives, strings, arrays, dictionaries, tuples, and
ranges in dedicated enum cases. `RuntimeValue.host(Any)` is the escape hatch
for opaque framework or embedder objects such as `AnyView`, `Date`, and `URL`.
`RuntimePayload` and the typed accessors form the stable dispatch surface, and
`hostPayload` boxes a core value only when a host gateway explicitly asks for
one.

The remaining semantic migration is deliberately ordered:

1. Convert tuple and dictionary storage from shared reference containers to
   value-backed or copy-on-write storage.
2. Separate value-backed interpreted structs from reference-backed classes and
   observable models.
3. Enforce copy-in/copy-out semantics at assignment, argument, `inout`, return,
   capture, and collection-mutation boundaries.
4. Make evaluator suspension and cancellation explicit before adding real
   concurrent task execution.
5. Replace dynamically interpreted host calls with parsed, validated
   signatures while retaining the injected `HostRegistry` boundary.

New core code should not downcast `host(Any)` to a Swift-shaped value. Direct
downcasts are reserved for opaque host/framework implementations and should be
kept at the registry boundary or in a clearly named compatibility path.

The current comparison and acceptance criteria for this migration are recorded
in [SwiftScriptGapMatrix.md](SwiftScriptGapMatrix.md).

## Verification invariants

Every migration step must keep these layers green:

1. `swift test --filter SwiftInterpreterTests` for language semantics.
2. `swift test` for SwiftUI integration and state behavior.
3. `ParityCheck` for generated Foundation behavior.
4. `ProjectCheck` and `LiveCheck` for real-project compatibility.

Architectural refactors should be behavior-preserving unless a semantic change
has a native Swift cross-check and a dedicated regression test.
