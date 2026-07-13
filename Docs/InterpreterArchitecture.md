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
- `LiteralEvaluator` evaluates each interpolation argument once in source
  order and treats labels as overload controls rather than output segments.
  `Runtime/StringFormatting.swift` owns the host-safe C-vararg conversion
  shared by localized `specifier:` interpolation and `String(format:)`.
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
- BridgeGen emits an exact accepted declaration for every generated
  Foundation method call shape and every generated property accessor.
  `GeneratedMembers` parses the 115 method and 247 property declarations once,
  derives receiver/member keys from them, binds methods through `HostFunction`
  overload selection, and exposes 179 read-only plus 68 mutable properties
  through shared `HostProperty` descriptors. Mutable entries carry a
  statically compiled SDK copy mutation used both by reference-carrier writes
  and value-lvalue copy-out/write-back. `ParamTag` remains only as the final
  method-argument conversion
  into statically compiled Foundation calls; it no longer decides labels,
  arity, types, ranking, receiver validity, or result validity for this family.
- Clang-imported AppKit/UIKit declarations are recovered from the SDK symbol
  graphs (their textual Swift overlays omit most of the public surface).
  BridgeGen selects platform roots at the type level and emits every
  mechanically supported constructor, method, property, and contextual value
  beneath them. The generated calls are statically compiled on the native
  platform; the opposite platform uses the same `HostFunction`/`HostProperty`
  contracts with typed inert results. A shared carrier preserves SDK struct
  copies and framework-object identity without placing either framework in the
  interpreter core. Shapes omitted by the importer or rejected by the shared
  coercion rules fall through to the existing inert compiled-import boundary;
  they never bypass a generated declaration that actually matches the call.
- `HostRegistry` is the only framework capability boundary. SwiftUIBridge and
  test registries implement it independently; the typed layer has no SwiftUI
  dependency.
- SwiftUIBridge's expected-type coercion funnels are semantic adapters, not
  lossy boxes. They recursively resolve deferred implicit-member chains (for
  example `.black.opacity(0.15)`) and retain protocol-erased framework values
  such as `AnyShapeStyle` as raw host values across source-language storage and
  return boundaries. Turning those values into `AnyView` or an absorbing bag
  destroys the conformance that generated gateways need.

## Swiftinterface-first bridge invariant

Ordinary SwiftUI and SDK API coverage is derived from SDK interface metadata:
swiftinterfaces where they contain the Swift declarations, and symbol graphs
for Clang-imported platform declarations omitted from textual overlays. A
missing initializer, modifier, or member must be fixed by improving BridgeGen,
shared type coercions, or a reusable generated adapter and regenerating the
checked-in tables. Per-API, per-project, fixture-name, source-name, and literal
special cases are forbidden.

The sole exception is SwiftUI runtime magic not represented in interface
metadata: result-builder execution and framework-supplied closure arguments,
state/binding/observation identity, collection child identity/composition, and
preservation or erasure of opaque `View`, `Shape`, and `ShapeStyle` values.
These remain centralized semantic primitives, not precedent for API-specific
gateways. If an API-specific hook is unavoidable, it belongs to a small
documented allowlist with the absent interface semantics and native-parity or
integration coverage. The binding agent instructions live in `AGENTS.md`.

## Runtime-value migration

`RuntimeValue` stores primitives, strings, arrays, Sets, dictionaries, tuples,
ranges, and Optionals in dedicated enum cases. `RuntimeValue.host(Any)` is the escape
hatch for opaque framework or embedder objects such as `AnyView`, `Date`, and
`URL`. `RuntimePayload` and the typed accessors form the stable dispatch
surface, and `hostPayload` boxes a core value only when a host gateway
explicitly asks for one. Arrays use Swift's copy-on-write storage;
`RuntimeSetValue`, `TupleValue`, and `DictValue` are value types, and collection
lvalues perform read-modify-write through their owner so nested updates retain
value semantics. Opaque host classes retain identity by default; a registry's
class-backed carrier for a native Swift struct can explicitly adopt
`HostValueSemantic`, causing ordinary and deep storage copies to clone the
carrier. The Foundation bridge uses that opt-in for `DateComponents`,
`URLComponents`, and `URLRequest`; the generated platform carrier applies it
from symbol-graph nominal-kind metadata to AppKit/UIKit structs.

`RuntimeOptionalValue` retains both `.some` and `.none` as physical runtime
values, including every layer of a nested Optional. Its wrapped-type metadata
lets an empty `T?` bind host generics without manufacturing a payload, and an
IUO flag preserves `T!`'s direct-use behavior while keeping Optional storage.
Typed declarations, assignments, parameters, returns, enum payloads,
collection elements, casts, failable initializers, `try?`, generated members,
Codable, and Objective-C marshaling all enter this representation. Optional
binding, patterns, chaining, `??`, force unwrap, `map`/`flatMap`, equality,
and host matching unwrap exactly one layer at their language-defined boundary.
The untyped `.nilValue` case remains only as the context-free nil literal and
legacy boundary sentinel; annotation resolution converts it to typed `.none`.

`RuntimeSetValue` is deliberately separate from Array. It keeps a deterministic
first-seen backing order because dynamically interpreted equality cannot use a
native `Hashable` table, but membership, equality, and algebra are set-based
and order-independent. Construction deduplicates through declared or
synthesized source equality, Set-only APIs dispatch only on this case, and the
value retains static element context for empty generic storage and typed host
matching. Sequence consumers use a read-only common element view without
collapsing the two runtime types.

`Runtime/ValueSemantics.swift` is the single ownership authority for source
values. A new `Environment` binding, call parameter/return slot, lvalue write,
or container/property slot copies a source struct's immediate storage envelope
while preserving source-class and opaque-host identity. Native arrays, Sets,
dictionaries, tuples, ranges, and immutable enum cases retain their value/COW
storage instead of being walked eagerly. `Instance` remains a shared physical
storage node, but `StructSymbol.isClass` selects its language semantics.
Wrapper-bearing struct copies share only the locations that are
reference-bearing in SwiftUI (`@State`, `@StateObject`, `@Binding`).
Escaping host snapshot stores that can mutate without an interpreter lvalue
use the same module's explicit deep-isolation operation on copy-in and
copy-out; `CurrentValueSubject` is the canonical example.

`OperatorEvaluator.LValue` composes source-value property and subscript paths
with array, dictionary, tuple, and host-value paths. A nested write or
`mutating` call executes against an independent receiver and commits the final
value outward one owner at a time, so outer property observers and state hooks
fire. Dictionary paths distinguish a missing key from a stored Optional
`.none`; a `default:` read returns the dictionary's `Value` and defers its
fallback during read-modify access, while a direct write preserves Swift's
setter-side fallback evaluation. The same transaction spans suspending methods.
Nonmutating member reads
borrow struct `self`; bound method values and closures created inside a struct
member snapshot it when they escape. Explicit closure capture lists likewise
create snapshot environments, while ordinary lexical captures continue
sharing their variable box.

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

1. Consider a distinct/COW struct representation if profiling shows
   storage-envelope copies are material; the observable struct/class
   semantics no longer depend on that refactor.
2. Move generated SwiftUI modifier/constructor tables and existing
   compatibility gateways onto the landed typed declarations. Migrate every
   interface-expressible gateway into BridgeGen; retain only the documented
   SwiftUI-magic primitives without weakening deliberate absorption fallbacks.
3. Tighten compile-time-only rules (mutability/exclusivity and unsupported
   ownership forms) where runtime diagnostics add practical value.

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
