# The Loop

## High-level goal

A Swift interpreter that **matches native SwiftUI's abilities and runs real
open-source SwiftUI projects without errors**. Architecture (settled, don't
relitigate): tree-walk SwiftSyntax ASTs directly (never SIL), delegate all
framework behavior to gateways (hand-written overrides + BridgeGen-generated
tables from the SDK's swiftinterfaces), stub types (`InterpretedView`) for
protocol conformance. See README.md for what already works.

**North-star metric: `swift run ProjectCheck` pass rate.** 587 real zipped
SwiftUI sample projects sit in `/Users/mike/Documents/sample-projects`. The
runner extracts them (into gitignored `External/`), merges each project's
`.swift` files, interprets, deep-renders every View body, and clicks every
action. Its failure-class histogram is the priority queue.

## The iteration algorithm (never invent the next step)

Each iteration does exactly this:

1. **Health check**: `swift test` (~100 tests). If red, fix that first — the
   suite is never weakened, tests are never deleted to go green.
2. **Measure**: `swift run ProjectCheck --limit N` (N grows over time; start
   25, raise when the current window passes ~80%). Read the failure-class
   histogram.
3. **Pick the single biggest failure class** (most projects blocked). If two
   tie, pick the one that's an interpreter-language gap over a gateway gap.
4. **Classify and fix properly** (no per-project hacks):
   - *Language gap* (unsupported syntax/semantics) → implement in
     `Sources/SwiftInterpreter/` following existing evaluator patterns.
   - *Missing view/modifier/type* → prefer teaching BridgeGen a coercion or
     mapping and regenerate (`swift run BridgeGen --emit`); hand-write in
     `ViewGateways`/`ModifierGateways` only when generation can't express it.
   - *iOS-only / platform-impossible API* (UIKit interop, UIScreen…) → add a
     minimal inert stub if cheap and honest (renders something reasonable),
     otherwise record the project name + reason in the Quarantine section
     below. Quarantine is a last resort and never used to inflate pass rate.
5. **Add regression coverage**: a corpus program under
   `Tests/SwiftUIBridgeTests/Corpus/` or a unit test that captures the fixed
   class. New capability without a test doesn't count.
6. **Verify**: full `swift test` green AND ProjectCheck pass count strictly
   improved (or same count with the histogram's top class eliminated).
7. **Commit** with the failure class named in the message.
8. **Update the Progress log below** (date, pass rate, what was fixed). Keep
   entries to one line.
9. If ProjectCheck passes everything in the current window: raise `--limit`
   (25 → 50 → 100 → … → --all). When the local ladder is exhausted, find
   harder material: search GitHub for small real SwiftUI apps (10–40 files,
   stars > 100), clone into `External/oss/<name>`, and point ProjectCheck at
   them. Never fabricate passing material.

## Rules

- **Model & attribution**: the loop is intended to run on **Claude Fable 5 at
  xhigh reasoning effort** (session-level settings — `/model` and `/effort`;
  the loop cannot change them itself). Every commit made by the loop MUST
  record who made the change with a trailer line before Co-Authored-By:
  `Model: <model name> (<model id>), effort=<effort>`.
- Small commits, one failure class each. No drive-by refactors.
- Hand-written gateways stay authoritative over generated ones.
- Semantic divergences (reference-backed structs, positional identity, etc.)
  are documented in README.md, not silently extended. If a fix requires a NEW
  divergence, document it in the same commit.
- The step budget, located errors (`line:col`), and headless verifiability
  are invariants — don't trade them away for pass rate.
- Known deep walls, in preferred order when the ladder forces them:
  `@Environment` values (dismiss, colorScheme…) → value semantics for structs
  → protocols/generics in interpreted code → async/await → `@main App`/scene
  shell → Foundation breadth (Date formatting, Timer, URLSession stubs).
  Don't start one preemptively; wait until it's the top failure class.

## Quarantine

(projects excluded from the metric, with reasons — keep short)

## Progress log

- 2026-07-09: Loop bootstrapped. Corpus (12 programs) + 97 unit tests green.
  ProjectCheck baseline over smallest 25 real projects: **1/25**. Top classes:
  top-level `#Preview` as expression (12), `Bool.toggle()` (3), get/set
  computed properties (3), `UIScreen.main` (2), `Color.black` static (2).
- 2026-07-09 iter 1: statement-position `#Preview` (MacroExpansionExpr) made
  inert — 12-project class eliminated; **1/25 → 3/25**. Next top classes:
  `Bool.toggle()` (3), get/set computed properties (3), statics on host types
  like `Color.black` (2+2 related).
- 2026-07-09 iter 2: `Bool.toggle()` via the lvalue path (state notification
  fires); **3/25 → 7/25**. Next: get/set computed properties (3), member
  access on host-type functions (`Color.black`, `String.…`, ~4 related).
- 2026-07-09 iter 3: settable computed properties (get/set accessors, custom
  setter param names, compound assignment through getter+setter; observer-only
  bindings are stored+inert, documented). Class eliminated; **7/25 → 7/25**
  (freed projects hit next blockers). Noted for later: Int literals don't
  promote to Double-annotated storage. Next: host-type static members
  (`Color.black` family, ~5 across variants).
- 2026-07-09 iter 4: host-type static members — unknown uppercase identifiers
  become HostTypeMarker; member access on markers/host constructors yields
  implicit members (`Color.red` ≡ `.red`), calling a marker is a clear located
  error. Trace registry's generic recorder is uppercase-only (lowercase
  unresolveds error truthfully) with an explicit withAnimation case.
  **7/25 → 9/25**.
- 2026-07-09 iter 5: GeometryReader/TimelineView proxy closures — the 4-project
  class behind `$0`/`proxy`/`timeLine` failures. Real gateways evaluate content
  at layout time with the real proxy (errors → RenderDiagnostics + EmptyView);
  trace uses honest stubs (390×844). New `hostMember` registry hook serves
  GeometryProxy/CGSize/CGRect/CGPoint members as Doubles, frame(in:) coerces
  coordinate spaces. GeometryCard corpus program added. **9/25 → 10/25**.
- 2026-07-09 iter 6: host static chains — the bridge intercepts type markers
  AND host constructor functions via hostMember: `UIScreen.main.bounds` maps
  to the real screen frame, `DispatchQueue.main.async` defers interpreted
  closures via a main-actor Task (GCD's queue never drains under swift test).
  **10/25 → 12/25**. Noted next: `.init()` in annotated positions (2 projects),
  colorScheme `@Environment` comparison (1).
- 2026-07-09 iter 7: annotated implicit members for structs/classes —
  `: T = .init(...)` instantiates, `.factory()` dispatches static methods,
  bare `.staticValue` resolves, and `[T]` annotations resolve array elements
  (covers `(1...8).map { .init(...) }`). **12/25 → 14/25** (56% of window;
  --limit stays 25 until ~80%).
