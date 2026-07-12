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
- `Host/HostSignature.swift` owns the declaration model and SwiftParser-based
  parsing; `HostSignatureMatching.swift` owns call shape, generic binding, and
  diagnostics; `HostTypeMatching.swift` owns structural runtime type checks.
- `HostCallable.swift`'s `HostFunction` and `HostProperty` are the executable
  typed boundary. They
  validate registration effects once, then validate every argument/result or
  property read/write. Legacy dynamic descriptors remain an explicit
  compatibility path while tables migrate. Module descriptors are immutable
  singletons, so parsing is registration work rather than per-session or
  per-lookup work.
- `HostRegistry` is the only framework capability boundary. SwiftUIBridge and
  test registries implement it independently; the typed layer has no SwiftUI
  dependency.

## Runtime-value migration

`RuntimeValue` stores primitives, strings, arrays, dictionaries, tuples, and
ranges in dedicated enum cases. `RuntimeValue.host(Any)` is the escape hatch
for opaque framework or embedder objects such as `AnyView`, `Date`, and `URL`.
`RuntimePayload` and the typed accessors form the stable dispatch surface, and
`hostPayload` boxes a core value only when a host gateway explicitly asks for
one. Arrays use Swift's copy-on-write storage; `TupleValue` and `DictValue` are
value types, and collection lvalues perform read-modify-write through their
owner so nested updates retain value semantics.

Declaration bodies also retain lexical ownership independently of their
runtime caller. Functions, initializers, computed properties, view bodies,
and deferred closures push their declaring type onto an outward-searching
scope stack. This keeps nested types deterministic when merged projects contain
several private declarations with the same bare name.

## Async execution migration

`runAsync` is the async session entry point. Source `Task {}` bodies become
real Swift main-actor tasks, never run inline with their constructor, and the
session waits for the complete descendant-task tree. `RuntimeTaskHandle`
exposes pending/running/succeeded/cancelled/failed state and drives real task
cancellation. The evaluator checks native cancellation at every budget tick,
so cancellation cannot be swallowed by interpreted `do`/`catch`.

Await-bearing code runs through `AsyncEvaluator` and
`AsyncStatementEvaluator`. Eager expression shells are lowered back into the
established synchronous operator/member machinery after their awaited roots
finish; lazy branches (`&&`, `||`, `??`, ternary, `if`, `switch`, and `try?`)
stay suspension-aware so untaken work never runs. `HostFunction` has explicit
sync and async gateway faces, and async gateways can re-enter interpreted code
through `EvalContext.callClosureAsync`. When a gateway suspends, the current
task's evaluator frames are parked and restored on resume, preventing
main-actor reentrancy from mixing lexical, return-type, recursion, or budget
stacks between interpreted tasks.

Parsed `HostSignature` effects and gateway implementations agree at
registration: a synchronous implementation cannot claim an `async`
declaration and vice versa. Both invocation faces share argument, generic,
and return validation. An async overload set selects a declaration before it
suspends, and typed property access uses the same runtime type service as
calls. Custom `EvalContext` implementations inherit primitive/container type
matching; the concrete interpreter adds source-symbol and registry-owned host
types.

The synchronous `run` entry point deliberately keeps inline task execution and
inline `await` compatibility for the SwiftUI renderer and existing embedding
clients. An async-only host gateway reports a clear error there rather than
blocking the main actor.

The remaining semantic migration is deliberately ordered:

1. Separate value-backed interpreted structs from reference-backed classes and
   observable models.
2. Extend copy-in/copy-out semantics to source structs, captures, and their
   mutating-method boundaries.
3. Move generated and hand-written compatibility gateways onto the landed
   typed declarations without weakening deliberate absorption fallbacks.

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
