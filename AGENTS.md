# Agent instructions

## Swiftinterface-first bridge rule (binding)

For missing SwiftUI or SDK API coverage, improve `Sources/BridgeGen`, its type
mapping/coercion system, or a reusable generated adapter, then regenerate the
checked-in outputs. Never fix an ordinary API gap by adding a constructor,
modifier, member, app, fixture, source-name, or literal-specific special case.
Do not edit files under `Sources/SwiftUIBridge/Generated/` by hand.

The only exception is narrowly scoped **SwiftUI magic**: runtime semantics
that a `swiftinterface` does not encode, such as result-builder execution and
framework-supplied closure inputs, state/binding/observation identity,
collection child identity/composition, and preservation or erasure of opaque
`View`/`Shape`/`ShapeStyle` values.

Even SwiftUI magic must:

- be implemented as a reusable semantic primitive or generator adapter rather
  than an API-name special case whenever possible;
- contain no project-, app-, fixture-, or literal-specific behavior;
- be kept in a small documented allowlist when an API-specific hook is truly
  unavoidable, with the missing interface semantics stated explicitly; and
- have native-parity or integration regression coverage.

Existing handwritten gateways are not precedent for new ones. When touching
one, migrate it to generation if its behavior is expressible from interface
metadata and shared adapters; retain it only when it satisfies the SwiftUI
magic rule above.

## Generality safeguards (anti-drift, binding)

The bridge rule above is enforced by *tooling* for the value-type tier
(BridgeGen generates coverage from swiftinterfaces; the 587-project corpus and
ParityCheck cannot be passed by special-casing). It is NOT enforced for
handwritten host boxes and semantic-shape work, where each per-instance change
passes its own correctness and demand checks yet the aggregate is per-API drift
(the 2026-07-19 detached-FileManager physical-worker gateway descope is the
reference incident: `createDirectory`/`fileExists`/`removeItem`/`move` were each
demand-cited and gate-green, and the sum was Foundation grinding, not structured
concurrency). These safeguards close that gap and are binding:

1. **Generality is a merge criterion, not only correctness.** A change to any
   handwritten surface (host box, gateway, dispatch table) states whether it is
   the Nth instance of a pattern. If it is, generalize the rule or cite why the
   case is irreducibly specific (distinct argument validation, throwing shape, or
   interface-inexpressible semantics). "Demand-cited and gate-green" is necessary
   but not sufficient — many green per-instance changes still sum to drift.

2. **The depth cap covers all hand surface, not just concurrency.** A host box or
   gateway earns a general dispatch rule, not per-method cases; adding case N+1 by
   hand is a smell that must be justified against safeguard 1. This is the §14
   within-slice depth cap of `Docs/SwiftConcurrencyArchitecture.md`, generalized
   beyond concurrency constructs.

3. **Dispatch on PROPERTY, not IDENTITY.** The special-case smell is structural,
   not lexical — do not detect it by commit wording. It is a branch keyed on a
   specific *identity* (a hardcoded API name, type name, or string/number literal)
   where a rule over a *property* — derivable from interface metadata, type
   structure, or a protocol conformance — would subsume it. Before adding an
   identity-keyed branch (`case "fileExists"`, `if typeName == "Foo"`, a literal
   match), name the property that makes the case special and dispatch on that
   property. Identity-keyed branches that grow one-per-feature are the drift
   fingerprint; the health signal is that the count of identity-keyed branches
   over SDK/host names holds or falls as coverage grows, never scales linearly
   with features.
