# SwiftScript architectural gap matrix

This is a source-level comparison against
[Cocoanetics/SwiftScript at `71605b28`](https://github.com/Cocoanetics/SwiftScript/tree/71605b28d1afa26d71eb4bce4d6fd0b63dba4983),
the upstream `main` revision checked on 2026-07-12. It is an engineering
backlog, not a feature-count scorecard.

## Current verdict

SwiftScript's former decisive advantage—source structs accidentally behaving
like classes here—is closed. This interpreter has one central ownership
contract for bindings, arguments, returns, captures, properties, containers,
and sync/async mutating lvalues; source classes, models, bindings, and host
objects retain their required identity. Dedicated Set storage and explicit
Optional storage are now closed as representation gaps too: arrays and Sets
have separate dispatch and type identity here, while nested Optionals retain
their wrappers and declared type context. SwiftScript still has the cleaner
physical struct/class split.

This interpreter leads in the larger runtime architecture: parsed executable
host contracts, genuinely suspending/cancellable task execution, resource
limits, framework isolation, and multi-board verification. SwiftScript's
parsed `Signature` serves its generic-method candidate path, while a separate
hand-built validator covers selected ordinary calls. The old statement that
“SwiftScript is architecturally better overall” no longer holds. This project
still avoids an unqualified language-completeness claim: generated Foundation
methods now use the typed boundary, but legacy handwritten and generated
SwiftUI modifier/constructor gateways still include dynamic paths.

| Area | SwiftScript | This interpreter | Verdict / next acceptance criterion |
| --- | --- | --- | --- |
| Evaluator decomposition | Feature-oriented files under `Execution/` | Feature-oriented evaluators under `Eval/`; `Interpreter` owns shared session state | Comparable. Keep syntax implementations out of `Interpreter.swift`. |
| Core value algebra | Dedicated optional, array, dictionary, set, tuple, range, struct, class, enum, and opaque cases; Optional stores only `Value?` | Dedicated primitive, string, array, Set, value-backed dictionary/tuple, range, Optional, instance, enum, and host cases plus one centralized shallow/COW ownership contract; Optional additionally retains wrapped-type and IUO metadata | This interpreter now has the richer Optional model and SwiftScript retains the simpler physical struct/class split. Adopt a distinct/COW struct case only if profiling or API clarity justifies it. |
| Optional semantics | Explicit recursive storage, nil coalescing/equality, binding, chaining, force unwrap, `map`/`flatMap`, and common failable APIs | Explicit recursive storage with typed `.none`, nested-layer identity, IUO behavior, annotated assignment/parameters/returns/enum and collection payloads, sync/async `try?`, casts, patterns, chaining/subscripts, `map`/`flatMap`, generated/ObjC/Codable boundaries, and generic binding from empty values | This interpreter now leads representation and covered boundary fidelity. Keep the untyped nil sentinel confined to literals/legacy inputs and add native differential tests for every new Optional-producing API. |
| Set semantics | Dedicated ordered unique storage, sequence construction, iteration, algebra, relations, filtering, and core mutation; `insert` intentionally returns only `Bool` | Dedicated deterministic value storage with static element context, order-independent interpreter-aware equality, typed host matching, native-shaped `insert` tuple, `update(with:)`, strict relations, algebra/mutation, and Array/Set isolation | This interpreter now leads Set fidelity. Keep native differential tests around every added operation and never restore Array compatibility shims. |
| Struct/class semantics | Struct fields live in enum values; classes use a reference cell | `Instance` is shared physical storage, but source-struct envelopes copy at language boundaries and composed lvalues detach only the nested mutation path; sync/async mutating calls copy out, classes/models retain identity, and wrapper locations follow SwiftUI identity | Behavioral parity on the covered boundaries, with native differential tests for assignment, arguments, returns, captures, containers, nesting, observers, classes, wrappers, and suspension. SwiftScript's physical split is simpler; this interpreter's ownership/write-back policy is more centralized and explicit. |
| Async execution | `eval`, statement evaluation, expression evaluation, calls, and bridges are uniformly `async throws`; async bridges may suspend, while `Task`/task-group shims run bodies inline | Dual-mode evaluator preserves synchronous rendering while `runAsync` propagates suspension through expressions, statements, user calls, task bodies, host gateways, and host-to-interpreter callbacks; real tasks have descendant lifetime/cancellation and park evaluator frames across reentrancy | This interpreter leads in behavior and safety; SwiftScript's single async evaluator remains simpler. Keep sync and async semantics differential-tested as the language surface grows. |
| Host-call API | Bridge keys are Swift-shaped; cached `Signature` matching serves generic method candidates, while a separate hand-built `CallSignature` validator covers selected ordinary calls | `HostSignature` parses global functions, initializers, instance/static methods and properties; `HostFunction`/`HostProperty` centrally enforce labels, defaults, variadics, trailing closures, generic consistency/constraints, effects, overload ambiguity, arguments, returns, and property writes across sync/async paths. All 115 generated Foundation method variants emit cached executable declarations and use that same overload engine; generated tags only convert already-selected arguments for static host calls. | This interpreter leads architecturally. Continue migrating remaining handwritten and generated SwiftUI tables so contract coverage matches the boundary's capability. |
| Framework isolation | Foundation modules and generated bridges live inside the interpreter package | The language runtime does not import SwiftUI; `SwiftUIBridge` and test registries implement `HostRegistry` | This interpreter leads. Preserve this boundary during signature work. |
| Resource safety | No general evaluator-wide step/call-depth budget or evaluator cancellation polling found in the compared revision | Fatal step/call-depth limits, bounded background slices, a 1,024-task session cap, cancellation checks at every evaluation tick, and per-task frame parking across host suspension | This interpreter leads. Preserve these limits and frame isolation as more async constructs land. |
| Verification depth | 410+ feature tests and runnable parity examples | Language/integration tests plus native parity, live scenarios, and a 680-project corpus gate | This interpreter leads in breadth. Every semantic migration must add focused native differential tests and keep all boards non-empty and green. |
| Product surface | General scripting, broad generated Foundation bridge, CLI, cross-platform library | Dynamic SwiftUI execution, observable state, framework gateways, headless app/project checks | Different strengths. General-language gaps cannot be excused by the larger SwiftUI surface. |

## Remaining blockers

1. **Value-algebra completeness:** decide from profiling whether the
   now-correct struct semantics should move from
   shallow storage-envelope copies to a distinct copy-on-write representation.
2. **Typed-gateway coverage:** the executable contract layer is landed and
   representative globals, constructors, methods, mutable properties, and the
   complete generated Foundation-method family use it. Move generated SwiftUI
   modifier/constructor tables and remaining hand gateways off local
   extraction; deliberate absorbing fallbacks may remain explicitly dynamic.

## Definition of “better”

The source-struct acceptance criterion is now met. The accurate architectural
verdict is: this interpreter leads overall runtime design and verification;
SwiftScript retains a cleaner physical struct/class split, while this
interpreter now has the richer Optional model and the more faithful Set
subsystem. The architectural verdict is that this interpreter is stronger
overall; an unqualified language-completeness claim still waits for the
remaining dynamic gateways and broader language coverage. `Scripts/gate.sh`
is green across the unit, corpus, live, and parity boards and must remain the
ratcheting acceptance boundary.
