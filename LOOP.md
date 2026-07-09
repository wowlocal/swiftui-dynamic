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
- **Stale-build gotcha**: after changing the layout of a public core type
  (e.g. adding a field to RuntimeError), `touch` dependent sources
  (SwiftUIBridge, ProjectCheck, tests) before trusting results — SwiftPM's
  incremental build has linked stale objects twice (once a link error, once
  a SIGBUS with garbage error output).
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
- 2026-07-09 iter 8: memberwise trailing closures — unlabeled trailing closure
  binds to the last closure-shaped stored property; `@ViewBuilder var content`
  stores the BUILT view (Swift's synthesized builder-memberwise semantics).
  The 3-project `argument '_'` class eliminated; **14/25 holds** (all three
  advanced to deeper blockers). CustomContainer corpus added. Next: bare
  Color implicit members in view position (`.clear`/`.black`, 2).
- 2026-07-09 iter 9: nested type declarations — enums/structs inside types
  collect into `nestedTypes`, register under `Outer.Name` (annotations) and
  the bare name when unclaimed (in-scope refs); `.type` member access serves
  them. `DockProgress.ProgressType.linear` patterns work. **14/25 → 15/25**
  (60%). Remaining classes are all singletons: parameterized closure props,
  Color-as-view, doStmt, String.startIndex, colorScheme compare.
- 2026-07-09 iter 10: parameterized @ViewBuilder closure properties —
  function-typed annotations (`(CGSize) -> Content`) store the closure at
  memberwise init instead of pre-building; the body's `content(size)` call
  builds. SizedBox added to CustomContainer corpus. **15/25 holds**; class
  eliminated (ScrollParallax → `proxy.bounds(of:)` next; Canvas's identical
  message is really the GraphicsContext wall).
- 2026-07-09 iter 11: Colors as Views — `Coerce.colorLike` (bare `.black`,
  `Color.clear`, `.opacity` chains) accepted by both registries' isViewValue/
  anyView/node paths; view modifiers route on implicit-member bases
  (`Color.black.ignoresSafeArea()`), while `opacity`/`gradient` stay style
  chains. **15/25 holds**; class eliminated — both projects advanced (`round`
  builtin, dynamic range bounds are next-up singletons).
- 2026-07-09 iter 12: `@Environment(\.key)` values — the first known wall.
  Wrapper carries the key path; InterpretedView injects real reads
  (colorScheme, dismiss) before body; headless harnesses inject honest
  defaults (light, no-op dismiss) via InterpretedEnvironment.defaults().
  Table is extensible per-key. **15/25 → 16/25** (64%).
- 2026-07-09 iter 13: do/catch/throw/try/try?/try!/await — interpreted throws
  deliver their value to the catch binding; non-fatal host errors arrive as
  message strings (`.localizedDescription` works); budget errors are fatal and
  uncatchable; `await` evaluates inline (documented divergence). Also learned:
  stale incremental objects after core-type layout changes cause garbage
  crashes — rule added. **16/25 → 17/25** (68%).
- 2026-07-09 iter 14: math builtins (round/floor/ceil/sqrt/pow, joining
  abs/min/max). **17/25 holds**; class eliminated — Custom_Indicators advanced
  to `getWidth`, exposing interpreted `extension View { func … }` helpers as
  the real next class (host-protocol extensions currently skipped).
- 2026-07-09 iter 15: interpreted extensions of host types — `extension View`/
  `String`/`Int`/`Double` members collect into synthetic symbols, resolved on
  view values, view-conforming instances (implicit self), and native selves.
  Removing the silent skip made BlurredSheet_Updated execute deeper code,
  which forced two more condition kinds in the same iteration: `if case`
  pattern conditions (rides the switch matcher) and `#available` (passes on
  latest-SDK host). **17/25 holds — more honestly than before.**
- 2026-07-09 iter 16: writable host members — new hostSetMember/
  hostObjectConstructor registry hooks + LValue.hostProperty, with
  DateFormatterBox (real Foundation formatter: dateFormat get/set,
  string(from:), date(from:)) as the first user, shared by both registries.
  **17/25 holds**; the "cannot assign to host member" class is eliminated
  (DateTextField advanced into its closure-argument plumbing).
- 2026-07-09 iter 17: UIKit/AppKit representables — `*Representable` structs
  are accepted in view position (incl. modifiers on their instances) and
  render inert in both registries (make/update never run — documented).
  **17/25 → 18/25** (72%).
- 2026-07-09 iter 18: Timer publishers — `Timer.publish(every:on:in:)
  .autoconnect()` yields a box wrapping the REAL Combine publisher;
  `.onReceive` drives interpreted closures from actual ticks (trace records
  the modifier inert). AnimatedCounter corpus ticks a session counter.
  **18/25 → 19/25** (76% — one from the 80% window raise).
- 2026-07-09 iter 19: UIApplication window chain — `shared` → app stub,
  `windows` → one-window array, `safeAreaInsets` → zero EdgeInsets (honest
  macOS analog), EdgeInsets components as Doubles. Custom_Indicators passes
  after its 4-iteration march. **19/25 → 20/25 = 80% → window raised to
  --limit 50. New baseline: 25/50**; top classes: GeometryProxyStub members
  (4: minX/bounds family), $-projection on non-state (2), ImplicitMemberCall
  members (2), host statics (2).
- 2026-07-09 iter 20: GeometryProxy.safeAreaInsets + bounds(of:) on both the
  real proxy (NamedCoordinateSpace coercion, optional CGRect) and the stub
  (zero insets, canvas rect). 4-project class eliminated; **25/50 → 27/50**.
- 2026-07-09 iter 21: type context for statics, host inits, and mutating-array
  payloads — static properties keep their annotations (`static let samples:
  [Item] = [.init(...)]`); host-type annotations construct via host object
  constructors/global builtins (`: Date = .init()`, CGSize/CGPoint added,
  `Date.now`); `items.append(.init(...))` resolves against the target
  property's `[Type]` annotation. **27/50 → 28/50**; ShaderExample passed,
  the others advanced deeper.
- 2026-07-09 iter 22: state-like wrappers (@AppStorage/@SceneStorage/
  @GestureState/@FocusState) flatten to @State — bind, project, persist via
  StateStore; special semantics skipped (documented). All three class
  projects pass incl. DateTextField's five-iteration arc.
  **28/50 → 31/50** (62%). Next: `Type.self` statics (2).
- 2026-07-09 iter 23: universal `.self` (the value itself — Swift semantics),
  unblocking the PreferenceKey idiom (`.preference(key: SizeKey.self, …)`,
  trace-recorded). **31/50 → 33/50** (66%).
- 2026-07-09 iter 24: CG numeric type context — `CGFloat(x)` global builtin
  (our CGFloat model IS Double) and `.zero` statics for CGSize/CGPoint/CGRect
  via the marker path (covers `: CGSize = .zero` annotations). DropDown and
  MarqueeText pass. **33/50 → 35/50** (70%).
- 2026-07-09 iter 25: implicit members adopt the OTHER operand's host type in
  ==/!= (`dragOffset == .zero` resolves .zero as CGSize via the marker path);
  CG equality cases added. TouchAnimation passes. **35/50 → 36/50** (72%).
- 2026-07-09 iter 26: as/as?/as! casts — target type resolves markers via
  resolveAnnotated, Int/Double bridge, optimistic as? (nil only for nil;
  documented). AppStub gains connectedScenes/WindowSceneStub (screen,
  keyWindow). **36/50 holds**; CustomHUDs advanced to rootViewController —
  the UIKit hosting wall, possible quarantine candidate.
- 2026-07-09 iter 27: wrapper backing storage — `self._offset = offset` in
  custom inits canonicalizes `_x` → `x` (binding-stub swap included), and
  `State(initialValue:)` constructs as its value. Write-through verified:
  child button mutates parent state via assigned storage. Custom_ScrollView
  passes (156-node render). **36/50 → 37/50** (74%).
- 2026-07-09 iter 28: collection/Bool extensions — sugar-typed `extension
  [Item]` keys match array candidates alongside `extension Array`; implicit
  self on native values consults native members first (bare `count`/
  `firstIndex` inside extension bodies). StackedCards passes.
  **37/50 → 38/50** (76%).
- 2026-07-09 iter 29: BindingStub.wrappedValue — reads return the box value,
  writes go straight through the box (projectedValue returns the stub).
  PopUpNavigation passes. **38/50 → 39/50** (78% — one from the 100-window).
- 2026-07-09 iter 30: the Foundation date pipeline + crash guard. Format
  styles (`formatted(date:time:)`), plain assignments adopt property
  annotations (`self.amount = .random(in:)`), Double/CGFloat/Int `.random`
  statics, real-Calendar box (`Calendar.current.date(byAdding:value:to:)`,
  startOfDay, component) accepting `.now`/`.random` gateway args.
  CustomFileExtension passes → **40/50 = 80% → window raised to 100**.
  First 100-run SEGFAULTED (interpreted recursion overflows the native stack
  before the step budget) → call-depth guard (200, fatal, uncatchable) in
  calls and computed properties. **New baseline: 60/100.** Top classes:
  parameterized closures w/o data (7), member-on-void (6), appearance-proxy
  assigns (4).
- 2026-07-09 iter 31: label-aware parameter binding (the declared load-bearing
  lie, finally forced): labeled args match parameter labels, omitted MIDDLE
  defaults fall back correctly, positionals fill unlabeled params, the
  unlabeled trailing closure binds to the LAST unbound parameter. Plus
  ScrollViewReader (real proxy.scrollTo / no-op stub), joining the reader
  family. "missing argument" 7 → 4 (Canvas wall remains).
  **60/100 → 64/100** (64%).
- 2026-07-09 iter 32: uninitialized optionals are nil (real Swift semantics) —
  `var view: UICollectionView?` without initializer defaults to nil in stored
  properties AND locals, so optional chains propagate instead of dying on
  void. **64/100 → 66/100**. Remaining void-member subroots: unknown
  @Environment keys (modelContext → SwiftData), third-party wrappers
  (@ObservedResults/Realm — quarantine candidate).
- 2026-07-09 iter 33: UIKit appearance proxies — `X.appearance()` on any host
  marker yields an inert stub: writes accepted-and-ignored, config calls
  chain (`.standardAppearance.configureWithOpaqueBackground()`). Platform-stub
  doctrine, documented. **66/100 → 68/100**.
- 2026-07-09 iter 34: recursive marker chains — ChainedImplicitCall.base is
  now the full previous marker (not a bare name), member access on
  ImplicitMemberCall/ChainedImplicitCall extends the chain instead of
  throwing, and Coerce.animation folds combinator chains
  (`.easeInOut(duration:).delay(0.2).repeatForever(...)`, `.speed`,
  `.repeatCount`); colorLike/shapeStyle resolve chain bases recursively
  (`.blue.opacity(0.3).gradient`). Kills the 4-project "unsupported member
  on ImplicitMemberCall" class: CustomTabBar + ScrollParallax pass,
  3DGestureCard shifts to arithmetic-on-marker, MoreTabBar (.init-as-view)
  remains. **68/100 → 71/100**.
- 2026-07-09 iter 35: the member-on-void class (4) — store-shaped roots.
  `@Environment(Type.self)` ≡ @EnvironmentObject keyed by a synthesized type
  annotation + `.environment(model)` gateway in both registries (Observation
  idiom); `@Query`/`@ObservedResults` flatten to @State over a fresh-store
  `[]`; `@Environment(\.modelContext)` yields an inert ModelContextStub
  (insert/delete/save no-op, fetch empty); `$results.append/remove` write
  through the binding box. ObservationEnv + NotesStore corpus programs.
  PaginatingSwiftData + SwiftTransformer pass; NetflixUI pair advanced past
  env into a view-position marker class; SwiftUIRealm advanced to Realm
  ObjectId internals (quarantine candidate if it tops). **71/100 → 73/100**.
- 2026-07-09 iter 36: MapReader joins the reader family — content deep-renders
  with a MapProxyStub whose `convert(_:from:)` is honestly nil (no map exists
  headlessly; MapKit never imports). DraggableMapPin passes; the "missing
  argument" class shrinks 3 → 2 (Canvas = the GraphicsContext wall, Chips_UI =
  String text-measurement overload vs user extension — both single-project
  roots). **73/100 → 74/100**.
- 2026-07-09 iter 37: the String-member class — real text measurement +
  String.Index basics. `str.size(withAttributes:)` dispatches through a
  call-label-aware hook in specialMemberCall (user `size(_ font:)` extensions
  keep winning plain member access — the Chips pattern), measured bridge-side
  with real NSFonts mapped from UIFont markers (systemFont/weight/
  preferredFont(forTextStyle:)); startIndex/endIndex/index(_:offsetBy:)/
  distance(from:to:) join the String natives. Class eliminated: MarqueeText
  passes, Chips_UI advanced to a custom-Layout blocker, TextSelectionAPI
  advanced to a Bool-operand singleton. **74/100 → 75/100**.
- 2026-07-09 iter 38: the "() is not callable" class — two roots. Memberwise
  multiple-trailing-closure binding is now two-pass: labeled arguments claim
  their properties first, then unlabeled trailing closures fill remaining
  closure-shaped properties in DECLARATION order (SE-0286 forward scan) —
  `CustomButton(tint:) { content } action: {…}` binds correctly. Env action
  keys openWindow/dismissWindow/openURL are honest no-ops (no scene shell);
  AppStub gains inert terminate + mainWindow/keyWindow, WindowStub gains
  close (click-through fires Quit buttons — terminating the host is not an
  option). MultiWindowApp passes; AnimatedButton advanced to closure
  return-type annotation threading. **75/100 → 76/100**.
- 2026-07-09 iter 39: host-object property bags in trace — opaque constructed
  objects (UIPanGestureRecognizer() → generic TraceNode) now behave like the
  mutable objects they stand for: member writes land in node.config and read
  back (`gesture.name = id … gesture.name ?? ""` round-trips). Kills the
  "cannot assign on TraceNode" class; both FullScreenPop variants pass.
  **76/100 → 78/100**.
- 2026-07-09 iter 40: non-builder trailing closures on unknown constructors
  degrade to recorded configuration — the Lottie idiom (`LottieView { await
  LottieAnimation.loadedFrom(url:) }` loads data, not views) no longer fails
  the builder; genuine nested errors still propagate (fatal + non-view-shape
  guarded). Both NetflixUI units pass after their 3-iteration march, and
  MoreTabBar's `.init(value:)-as-view` rode the same shape. Only known walls
  (Canvas GraphicsContext, Chips_UI Layout) + singletons remain.
  **78/100 → 81/100**.
- 2026-07-09 iter 41: the Canvas wall, taken inert — `Canvas { context, size
  in }` runs the renderer with a no-op GraphicsContextStub + 390×844 size in
  BOTH registries (drawing never reaches a surface — documented divergence);
  `Path { path in }` builders execute against an inert PathDrawStub; Date
  gains timeIntervalSinceReferenceDate, Double gains remainder/
  truncatingRemainder(dividingBy:). WaveCanvas corpus program (Canvas + Path
  + Slider, real-hosted). Canvas passes; the class's other member (Chips_UI)
  is the Layout-protocol wall. **81/100 → 82/100**.
- 2026-07-09 iter 42: window raised 100 → 200 (82% ≥ 80%). New baseline
  142/200 (71%). Top class "has no member" (8) = user Shape structs hitting
  .fill/.stroke/.trim. StructSymbol.conformsToShape; instance member access
  falls back to modifiers for shapes; makeRenderable wraps them shape-typed —
  real side ShapeBox(InterpretedShape) whose nonisolated path(in:) calls the
  interpreted method via MainActor.assumeIsolated, PathDrawStub now
  accumulates a REAL Path (move/addLine/addCurve/addQuadCurve/addArc/addRect/
  addEllipse/closeSubpath), so user shapes draw actual geometry; trace side
  executes path(in:) against the standard rect and records inert. New public
  Interpreter.callMethod(named:on:arguments:). `.trim(from:to:)` hand
  modifier. CustomShapes corpus (fill/stroke/trim + state-driven redraw,
  real-hosted). 7 shape projects pass (WaterWave, SplashsAnimation, Glass,
  SegmentedControlAnimation, ScratchCard, Custom_Tab_Bar, Device_MockUp);
  the 8th (Tags) is a Layout — the protocols wall. **142/200 → 149/200**.
- 2026-07-09 iter 43: binding-collection ForEach — `ForEach($items) { $item
  in … }` iterates element bindings whose writes land back in the parent
  array (BindingStub.elementBindings, both registries); `$`-prefixed closure
  parameters also bind their bare name SHARING the binding's box (`item`
  reads live); `$item.field` projects field bindings via the instance's own
  box (Binding's @dynamicMemberLookup semantics). ChoreBoard corpus
  (Toggle(isOn: $chore.done) + reset click-through). All 5 in-window class
  projects pass. **149/200 → 155/200**.
- 2026-07-09 iter 44: DispatchQueue.main.asyncAfter — the deadline anchor
  `.now()` absorbs into its numeric offset in +/- arithmetic (the seconds the
  gateway needs), and MainQueueStub.asyncAfter schedules the interpreted
  closure via a delayed main-actor Task (real firing, like async). All three
  class projects pass (ParticleEmission, RepeatButton, LiquidTransition).
  **155/200 → 158/200**.
- 2026-07-09 iter 45: ScreenStub gains visibleFrame/frame (real NSScreen when
  present, laptop-shaped rect headlessly) — the NSScreen.main?.visibleFrame
  class. CustomTabBarMac + Login_Mac pass; FloatingWindow advanced to
  arithmetic-on-unresolved `.init(x:y:)` marker (the chain-combine class).
  **158/200 → 160/200**.
- 2026-07-09 iter 46: the "missing argument" class — three roots, two fixed.
  (1) Label-mismatch retry: when a member call binds a user extension whose
  labels don't fit (binding fails BEFORE the body runs), the call retries
  through the modifier table — `extension View { func offset(coordinateSpace:
  …) }` no longer shadows the built-in `.offset(x:)` (HeaderAnimation).
  (2) KeyframeAnimator/PhaseAnimator content receives its initialValue/first
  phase as seed; GlitchEffect then exposed tuple-element lvalues —
  `@State var trigger: (Bool, Bool, Bool)` + `trigger.0.toggle()` — added
  LValue.tupleElement with write-through-base (state notifies). Chips_UI
  (Layout protocol) remains the wall. **160/200 → 162/200**.
- 2026-07-09 iter 47: nested enums resolve as bare identifiers — nested
  STRUCTS defined globals but nested ENUMS only landed in the annotation map,
  so `enum ChartType` inside ContentView fell to HostTypeMarker and
  `ForEach(ChartType.allCases)` got a marker. Registration now mirrors the
  struct path (Outer.Name + unclaimed bare name). Class eliminated; both
  AnimatedCharts advanced to `Date.createDate` extension statics in annotated
  positions (new class). **162/200 holds — top class eliminated.**
