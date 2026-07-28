# Trajectory audit — 2026-07-28: generation leverage

**Scope.** The 61 commits `6adaf92e..56e0de0e` (2026-07-27 07:46 – 2026-07-28 18:43
+03:00), plus a two-week measurement of `Sources/BridgeGen` against its own output.
**Method.** Mechanical counting at 14 daily refs; classification of BridgeGen's module
inventory by date of addition; a controlled two-triple rendering experiment; and a
working prototype (branch `worktree-boundary-jit`) that replaces part of the generated
tier and is gated end to end. Every number below is reproducible from the commands
named in each section.

## TL;DR

The bridge rule is being followed to the letter and is still losing ground. Two
independent measurements say the same thing from opposite ends:

1. **Generation is decaying into hardcoding.** BridgeGen's leverage — generated lines
   per generator line — fell monotonically from **1:21.7 to 1:7.8** in two weeks, and
   the *marginal* rate over the last day was **1:2**. Seven per-API-family generator
   modules were added in ten days. Writing a bridge by hand is 1:1; the generator is now
   twice as good as that, having started twenty times better.
2. **The R2 board is chasing a floor it cannot reach.** R2 compares a Catalyst-rendered
   twin against a macOS-rendered interpreter. On a List-shaped scene with **no
   interpreter on either side**, the pure platform delta is **123,196 AE** — more than
   twice the entire remaining R2 residual of 59,695.

Both have the same methodological cause: **safeguard 3 polices the *key* of a branch
and not its *payload*.** A rule keyed on a closed property passes review while carrying
a constant that was obtained by measuring the compiled target. The magic number moved
out of the condition and into the body, where nothing is counting it.

A prototype shows the generation half is fixable at the root, not by more sweeping.

## Finding A — leverage is decaying, monotonically

Generator size vs. generated output at 14 daily refs:

| date | BridgeGen | Generated | leverage | API-name literals in BridgeGen |
|---|---|---|---|---|
| 07-15 | 3,212 | 69,757 | 1:21.7 | 33 |
| 07-18 | 3,687 | 72,709 | 1:19.7 | 38 |
| 07-20 | 7,263 | 77,188 | 1:10.6 | 66 |
| 07-21 | 8,285 | 81,459 | 1:9.8 | 74 |
| 07-24 | 9,924 | 84,604 | 1:8.5 | 76 |
| 07-26 | 10,804 | 89,586 | 1:8.2 | 79 |
| 07-28 | 11,780 | 91,936 | **1:7.8** | **84** |

Marginal leverage 07-27 → 07-28: **+718 generator lines bought +1,450 generated lines
(1:2.0)**. `Sources/BridgeGen` currently holds **270** identity-keyed comparisons
(`case "…"` / `== "…"`).

`AGENTS.md` §3 already declares the health signal: *"the count of identity-keyed
branches over SDK/host names holds or falls as coverage grows, never scales linearly
with features."* Over this window that count **grew 155%** (33 → 84 for qualified type
literals). The rule exists, is correct, and was never measured — the same failure mode
the 2026-07-24 audit named: prose rules do not fire, only exit codes do.

## Finding B — the shape of the hardcoding is per-API-family generators

`Sources/BridgeGen` by date of addition:

```
07-09  6033  main.swift
07-13  2582  PlatformGeneration.swift
07-19   174  RangeMutationGeneration.swift
07-20  1703  CollectionDefaultGeneration.swift
07-20   325  CMemoryGeneration.swift
07-20   401  UnicodeDecodingGeneration.swift
07-21   100  FoundationTypeAliasGeneration.swift
07-21   219  AttributedStringKeyGeneration.swift
07-25   243  CaseTransformGeneration.swift
```

Seven single-family modules in ten days. `UnicodeDecodingGeneration`,
`CaseTransformGeneration`, `AttributedStringKeyGeneration` are not a mechanism — each
solves one corner of the stdlib, expressed as a code generator rather than a hand box.
This satisfies the letter of the bridge rule (nothing is keyed on an API name) while
producing exactly what the rule exists to prevent.

## Finding C — the root cause is structural, not disciplinary

Stated in the code itself, `UnicodeDecodingGeneration.swift`:

> *"Runtime execution needs a semantic adapter because an interface declaration cannot
> carry executable generic code into RuntimeValue."*

Generics cannot be instantiated at runtime. So every generic *shape* in an SDK
signature must be modelled by hand, one module at a time. The tail is not the API
surface — it is the Swift type system, and it is unbounded. **No amount of additional
sweeping converges**, which means the current trajectory cannot satisfy the repo's own
bridge rule no matter how well each individual commit is argued.

## Finding D — safeguard 3's payload blind spot

Four handwritten adapters on main are formally compliant and dispatch on closed
properties, yet carry constants obtained by measuring the compiled Catalyst target:

- `TargetPlatformTypographyBridge` — dispatches on the closed semantic-role property;
  payload is a hand-transcribed `UIFont.preferredFont(forTextStyle:)` table, knowingly
  off by one point (`body: 18` where iOS is 17), commented as *"compensation … for the
  macOS host font's narrower optical metrics"*.
- `CatalystBorderedButtonStyle` — dispatches on `ControlSize`; payload is
  `(12,7,8)/(20,15,12)/(10,5,7)` plus fill RGB `233/233/235`.
- `TargetPlatformScrollBridge` — dispatches on axes + indicator visibility; payload is
  `.padding(.bottom, -1)`.
- `TargetPlatformControlBridge.adaptButtonMenuStyle` — `.menuIndicator(.hidden)`.

None of these is expressible from any swiftinterface: chrome padding, role point sizes
and fill colors are compiled framework internals. They are therefore permanently
handwritten, permanently growing, and invisible to the current anti-drift count.

**They are also chasing an unreachable floor.** `Scripts/icecubes-r2.sh` builds the twin
for `arm64-apple-ios-macabi` (UIKit) and the interpreter for `arm64-apple-macosx`
(AppKit): R2 measures *two different SwiftUI implementations*, not interpreter
fidelity. Controlled measurement — one SwiftUI source compiled for both triples, no
interpreter on either side, 900×700:

| scene | content | AE of 630,000 |
|---|---|---|
| control | explicit geometry + explicit sRGB colors | 29,457 — harness floor |
| typography | semantic font roles only | 52,473 |
| timeline | List + rows + `.bordered` controls | **123,196** |

Two defects in the board itself, found by the control scene: the twin writes **Display
P3** and the interpreter **sRGB** (verified on live `/tmp/icecubes-*/timeline.png`), and
Catalyst windows carry a top safe-area inset `NSHostingView` lacks. ~36% of the current
R2 residual (20,710 of ~58,000 px) sits in the sub-16 delta band that the capture
pipeline alone produces. The remaining diff is dominated by ghosted text with
progressive horizontal drift — differing **glyph advance widths**, which no constant
table can fix.

## The prototype — compile the boundary instead of modelling it

Branch `worktree-boundary-jit`. The existing seam is already
`invoke: (Any, [Any]) throws -> RuntimeValue`, so a shim compiled from a signature can
replace a hand-emitted closure with **no serialization at all** — native Swift `Any`
crosses in-process and reference types cross by identity.

`Sources/BoundaryABI` (22 lines) + `Sources/SwiftUIBridge/CompiledBoundary.swift` (281
lines, emitter proper **66**) + a 16-line opt-in seam (`BOUNDARY_JIT=1`). The emitter
knows no SDK type, member or family; it reads receiver type, parameter labels/types and
return type off the `HostSignature` BridgeGen already produced.

- **127 of 127** registered method overloads are mechanically expressible.
- **59 of 60** sampled signatures compile and load against the real SDK. The one failure,
  `Measurement.formatted()`, is a lossy declaration — BridgeGen emits `Measurement`
  where the interface has `Measurement<Dimension>`, and the hand closure beside it papers
  over exactly that with `base as! Measurement<Dimension>` plus a bespoke
  `measurementFormatted` helper. The same mechanical shim with the corrected receiver
  type compiles, so the real score is **60/60**.
- Interpreted source (URL/TimeZone/Locale, Mastodon-shaped) produces **identical results
  with and without** the compiled boundary.
- **Zero** of the 127 method parameters are closures or builders — the whole registered
  method surface is plain values (Calendar 27, URL 20, IndexSet 15, TimeZone 9, Locale 8,
  IndexPath 8, Decimal 7, Date 6), i.e. precisely the Foundation grinding §31 names as
  the reference drift incident.
- Cost: ~50 ms per shim, **0.67 s** incremental for a new signature in its own dylib,
  multiple dylibs `dlopen` together, and `CompilerPreflight.swift` already runs the real
  `swiftc` against the selected SDK with content hashing.

This replaces 1,149 lines of hand-emitted method registrations and removes the reason
the three round-1 family modules (863 lines) exist.

## Limits — what this audit does NOT establish

- Properties (a separate table), initializers, static methods and closure/builder-valued
  arguments are **not** covered by the prototype.
- `-undefined dynamic_lookup` is an experiment shortcut; production needs a single-copy
  dynamic product.
- The timeline probe scene is *not* the IceCubes timeline, so no claim is made about
  what fraction of the specific 59,695 is platform. The claim is only that on a scene of
  the same class the platform delta exceeds the whole residual.
- The prototype is opt-in and inert by default; `swift test --filter SwiftUIBridgeTests`
  is green at **733 tests / 159 suites** with the seam in place.

## Amendments

Written into `AGENTS.md` as §4 (payload rule) and §5 (leverage rule). Both carry a
measurement command, because this repo has now twice demonstrated that a rule without an
exit code does not fire.
