# SwiftScript architectural gap matrix

This is a source-level comparison against
[Cocoanetics/SwiftScript at `71605b28`](https://github.com/Cocoanetics/SwiftScript/tree/71605b28d1afa26d71eb4bce4d6fd0b63dba4983),
the upstream `main` revision checked on 2026-07-11. It is an engineering
backlog, not a feature-count scorecard.

## Current verdict

SwiftScript still has the stronger general-purpose value model because it
separates Swift structs from reference-backed classes. This interpreter now
has the stronger async runtime and host-contract architecture: parsed
declarations govern ordinary sync and suspending calls, overloads,
constructors, methods, properties, generic bindings, effects, and return
values while the framework stays injected. SwiftScript's parsed `Signature`
is used by its generic-method candidate path; its separate ordinary-call
validator is hand-built and does not make the declaration key one executable
contract. Our remaining typed-gateway migration is breadth work, not a missing
boundary design. The overall core verdict stays with SwiftScript until source
structs have real value semantics.

| Area | SwiftScript | This interpreter | Verdict / next acceptance criterion |
| --- | --- | --- | --- |
| Evaluator decomposition | Feature-oriented files under `Execution/` | Feature-oriented evaluators under `Eval/`; `Interpreter` owns shared session state | Comparable. Keep syntax implementations out of `Interpreter.swift`. |
| Core value algebra | Dedicated optional, array, dictionary, set, tuple, range, struct, class, enum, and opaque cases | Dedicated primitive, string, array, value-backed dictionary/tuple, range, instance, enum, and host cases | SwiftScript leads: add explicit optional/set representation where semantics require it and split source structs from classes. |
| Struct/class semantics | Struct fields live in enum values; classes use a reference cell | One class-backed `Instance` represents both source structs and classes | SwiftScript leads. Native differential tests must prove assignment, argument, return, capture, nested member, and mutating-method behavior. |
| Async execution | `eval`, statement evaluation, expression evaluation, calls, and bridges are uniformly `async throws`; async bridges may suspend, while `Task`/task-group shims run bodies inline | Dual-mode evaluator preserves synchronous rendering while `runAsync` propagates suspension through expressions, statements, user calls, task bodies, host gateways, and host-to-interpreter callbacks; real tasks have descendant lifetime/cancellation and park evaluator frames across reentrancy | This interpreter leads in behavior and safety; SwiftScript's single async evaluator remains simpler. Keep sync and async semantics differential-tested as the language surface grows. |
| Host-call API | Bridge keys are Swift-shaped; cached `Signature` matching serves generic method candidates, while a separate hand-built `CallSignature` validator covers selected ordinary calls | `HostSignature` parses global functions, initializers, instance/static methods and properties; `HostFunction`/`HostProperty` centrally enforce labels, defaults, variadics, trailing closures, generic consistency/constraints, effects, overload ambiguity, arguments, returns, and property writes across sync/async paths | This interpreter leads architecturally. Continue migrating legacy and generated tables so contract coverage matches the boundary's capability. |
| Framework isolation | Foundation modules and generated bridges live inside the interpreter package | The language runtime does not import SwiftUI; `SwiftUIBridge` and test registries implement `HostRegistry` | This interpreter leads. Preserve this boundary during signature work. |
| Resource safety | No general evaluator-wide step/call-depth budget or evaluator cancellation polling found in the compared revision | Fatal step/call-depth limits, bounded background slices, a 1,024-task session cap, cancellation checks at every evaluation tick, and per-task frame parking across host suspension | This interpreter leads. Preserve these limits and frame isolation as more async constructs land. |
| Verification depth | 410+ feature tests and runnable parity examples | Language/integration tests plus native parity, live scenarios, and a 680-project corpus gate | This interpreter leads in breadth. Every semantic migration must add focused native differential tests and keep all boards non-empty and green. |
| Product surface | General scripting, broad generated Foundation bridge, CLI, cross-platform library | Dynamic SwiftUI execution, observable state, framework gateways, headless app/project checks | Different strengths. General-language gaps cannot be excused by the larger SwiftUI surface. |

## Remaining blockers

1. **Struct value semantics:** make source structs copy like Swift values while
   preserving identity for source classes, observable models, bindings, and
   host objects. Core array, dictionary, tuple, and range storage is already
   value-backed.
2. **Typed-gateway coverage:** the executable contract layer is landed and
   representative globals, constructors, methods, and mutable properties use
   it. Move generated tables and remaining hand gateways off local extraction;
   deliberate absorbing fallbacks may remain explicitly dynamic.

## Definition of “better”

The overall architectural claim can change only when source structs have value
semantics, typed coverage reaches the generated boundary, their native
differential suites pass, the public host boundary remains
framework-independent, and `Scripts/gate.sh` reports non-empty green results
for the unit, corpus, live, and parity boards. Until then the accurate verdict
is: stronger host/async/resource architecture, weaker general Swift value
semantics.
