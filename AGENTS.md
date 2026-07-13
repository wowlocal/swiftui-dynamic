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
