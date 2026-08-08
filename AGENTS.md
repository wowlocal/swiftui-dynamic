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

   Ratchet (must hold or rise) — **the authority is `Scripts/validate-anti-drift.sh`,
   `FLOOR_LEVERAGE` (6.50)**, because it is the only thing here that exits non-zero. A reading
   below that floor reds the close gate. Its selection is EVERY generated line
   in the tree over EVERY line of `Sources/BridgeGen`: files under any `Generated/` directory
   plus files named `Generated*.swift` sitting beside handwritten code. Both spellings exist,
   they are disjoint, and no single-directory glob can see the second. It reads **7.3414**
   (117469/16001) on 2026-08-08:
   `awk -v g="$(find Sources -name '*.swift' \( -path '*/Generated/*' -o -name 'Generated*.swift' \) -exec cat {} + | wc -l)" -v b="$(find Sources/BridgeGen -name '*.swift' -exec cat {} + | wc -l)" 'BEGIN{printf "%.4f\n", g/b}'`

   The original one-directory glob is KEPT as a second, narrower series so the 1:21.7 (07-15) →
   1:7.8 (07-28) history above stays comparable — every prior figure, including the audit's
   7.1987 → 6.9968, was measured with it. It reads **6.8781** on 2026-08-08 — 7413 lines narrower
   because it cannot see `Sources/SwiftInterpreter/Generated/` (6 files, 1851 lines) or the
   flat-name `Generated*.swift` spelling (5 files, 5562 lines). The verbatim form below is `$(( ))`
   integer arithmetic, so it TRUNCATES and prints `6`; the second form is the same selection to
   four places. It is REPORTED, not enforced, and has no floor of its own — a second prose ratchet
   is the exact failure this section exists to prevent, so the only floor is the one in the script.
   `echo $(( $(cat Sources/SwiftUIBridge/Generated/*.swift | wc -l) / $(cat Sources/BridgeGen/*.swift | wc -l) ))`
   `awk -v g="$(cat Sources/SwiftUIBridge/Generated/*.swift | wc -l)" -v b="$(cat Sources/BridgeGen/*.swift | wc -l)" 'BEGIN{printf "%.4f\n", g/b}'`
   `find Sources -name '*.swift' -path '*/Generated/*' ! -path 'Sources/SwiftUIBridge/Generated/*' -exec cat {} + | wc -l; find Sources -name 'Generated*.swift' ! -path '*/Generated/*' -exec cat {} + | wc -l`

   That narrow series crossed below 7 on **2026-08-06** (7f01f789, 7.0655 → 6.9977) and has not
   recovered. The `7 at 2026-07-28` this line asserted until 2026-08-08 was the integer
   truncation of 7.8044 at c16592c6 — the same measurement the `1:7.8` above reports, one rounded
   and one truncated — so for two days the document stated a floor its own tree no longer met and
   nothing fired, the same execution gap the preamble describes, one level up. The
   2026-08-08 audit found the §5 collapse has **stopped**, and the residual fall is dilution
   rather than drift: no single-family module has been added since 2026-07-25
   (`CaseTransformGeneration`, 8d0c9ec6); the seven of them are 3165 of the 16001 denominator
   lines yet return only 985 generated lines (**0.3112x**, so they are near-pure denominator);
   `PlatformGeneration.swift` returns **28.6907x**; and core leverage — non-platform generated per
   line of `BridgeGen/main.swift` — has been RISING, 2.4465 at c16592c6 (07-28) → 2.4940 at
   7f01f789 (08-06) → **2.5868** today. Read the falling headline as PlatformGeneration's
   89974-line output being diluted by seven modules that never paid for themselves, not as a
   collapse still under way — and note that this does not retire the rule: the seven are why the
   headline falls, and an eighth would push it further.
   `for s in c16592c6 7f01f789^ 7f01f789; do awk -v g="$(git ls-tree --name-only $s Sources/SwiftUIBridge/Generated/ | grep '\.swift$' | while read p; do git cat-file blob $s:$p; done | wc -l)" -v b="$(git ls-tree --name-only $s Sources/BridgeGen/ | grep '\.swift$' | while read p; do git cat-file blob $s:$p; done | wc -l)" 'BEGIN{printf "%.4f\n", g/b}'; done`
   `git log -1 --diff-filter=A --format='%ad %h' --date=short -- 'Sources/BridgeGen/*Generation.swift'`
   `awk -v g="$(cat Sources/SwiftInterpreter/Generated/Generated{CaseTransform,CollectionDefault,RangeMutation,UnicodeDecoding,UnsafeMemory}Surface.swift Sources/SwiftUIBridge/Generated/GeneratedCMemoryBridge.swift Sources/SwiftUIBridge/GeneratedCMemorySupport.swift | wc -l)" -v b="$(find Sources/BridgeGen -name '*.swift' ! -name main.swift ! -name PlatformGeneration.swift -exec cat {} + | wc -l)" 'BEGIN{printf "%.4f  (%d / %d)\n", g/b, g, b}'`
   `awk -v g="$(wc -l < Sources/SwiftUIBridge/Generated/GeneratedPlatformBridge.swift)" -v b="$(wc -l < Sources/BridgeGen/PlatformGeneration.swift)" 'BEGIN{printf "%.4f  (%d / %d)\n", g/b, g, b}'`
   `for s in c16592c6 7f01f789 HEAD; do awk -v g="$(git ls-tree -r --name-only $s Sources | grep -E '(/Generated/|/Generated[A-Za-z]*\.swift$)' | grep -v GeneratedPlatform | while read p; do git cat-file blob $s:$p; done | wc -l)" -v b="$(git cat-file blob $s:Sources/BridgeGen/main.swift | wc -l)" 'BEGIN{printf "%.4f\n", g/b}'; done`

Safeguards 4 and 5 carry a command because this repository has now twice shown
that a rule left as prose does not fire — only exit codes do
(`AUDIT-2026-07-24-execution-gap.md`, `AUDIT-2026-07-28-generation-leverage.md`).
