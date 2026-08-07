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

**Executed by `Scripts/validate-anti-drift.sh`, a closing-gate stage that exits 1.** These
safeguards were prose from 2026-07-19 to 2026-08-07 and fired zero times: the §5 leverage ratchet
was crossed inside the 2026-08-04..08-07 window and nothing noticed. Each threshold in that script
commits **the command that produces it**, not only the number — the 2026-08-07 audit could not
reproduce a single figure from the three prior audits (1092, 270, 7) because each committed a
number and no command, and three different file selections give three different answers for the
same tree. A violation is not a request to move the threshold; move it only with a measurement, in
its own commit, saying why.

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

4. **The PAYLOAD is a special case too, not just the key.** Safeguard 3 counts
   what a branch is *keyed on*. That leaves a hole, and four adapters on main
   are already in it (`AUDIT-2026-07-28-generation-leverage.md` §D): a branch
   keyed on a closed property — `ControlSize`, a semantic font role, a scroll
   axis — whose *body* carries a constant obtained by measuring the compiled
   target. `(12,7,8)` of chrome padding, a transcribed `UIFont` role table,
   fill RGB `233/233/235`, `.padding(.bottom, -1)`. The magic number moved out
   of the condition into the body, where nothing counts it.

   A constant calibrated by measuring the compiled target is the same
   violation as `case "someAPI"`. If a number is not derivable from a
   swiftinterface, it must not be hardcoded — **execute the target framework
   instead of transcribing it**. Adding row N+1 to such a table is adding case
   N+1 by hand. This class cannot converge: chrome metrics, role point sizes
   and fill colors are compiled framework internals, so the tail is unbounded
   by construction, and the residue it chases is dominated by glyph advance
   widths that no table can express.

   Ratchet (must hold or fall; **37** at 2026-07-28):
   `grep -rhoE '\b[0-9]+(\.[0-9]+)?\b' Sources/SwiftUIBridge/TargetPlatform*.swift | wc -l`

5. **Generation must keep its LEVERAGE.** "It is a generator, not a hand box"
   is not sufficient — a generator that grows one module per API family is
   hardcoding in a costume. Between 07-15 and 07-28 BridgeGen's leverage
   (generated lines per generator line) fell **1:21.7 → 1:7.8**, marginally to
   **1:2** over the last day, while seven single-family modules were added in
   ten days (`UnicodeDecodingGeneration`, `CaseTransformGeneration`,
   `AttributedStringKeyGeneration`, …). Hand-writing a bridge is 1:1.

   Before adding a module to `Sources/BridgeGen`, state the leverage it buys
   and whether it is the Nth single-family module. A new generator that serves
   exactly one API family must instead be argued as a general mechanism, or
   cite why the family is irreducibly specific. When the honest answer is that
   a generic *shape* cannot be instantiated at runtime, that is a signal to
   move the boundary — let the real compiler instantiate it — not to model the
   shape by hand; see §D/§prototype of the audit, where a 66-line
   signature-driven emitter covered 127/127 registered method overloads.

   Ratchet (must hold or rise; **7** at 2026-07-28, down from 21 on 07-15):
   `echo $(( $(cat Sources/SwiftUIBridge/Generated/*.swift | wc -l) / $(cat Sources/BridgeGen/*.swift | wc -l) ))`

Safeguards 4 and 5 carry a command because this repository has now twice shown
that a rule left as prose does not fire — only exit codes do
(`AUDIT-2026-07-24-execution-gap.md`, `AUDIT-2026-07-28-generation-leverage.md`).
