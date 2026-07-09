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

- SwiftUIRealm — Realm ORM internals: `@Persisted(primaryKey:) var id:
  ObjectId` and Object base-class storage; third-party database library,
  not SwiftUI surface (candidate since iter 32, blocked on ObjectId since
  iter 35).
- RealmDataBase — Realm ORM internals: live `Results` objects and
  `@ObservedRealmObject` backing storage.

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
- 2026-07-09 iter 48: genericSpecializationExpr + computed bindings —
  `Binding<Int?>(get:set:)` evaluates its base (type args are unchecked
  annotations) and a Binding(get:set:) host constructor backs a BindingStub
  whose box snapshots get() per render pass and calls set(newValue) on
  writes. JSONWithPagination + HorizontalWheelPicker_Updated pass (the
  latter a 359-node render). **162/200 → 164/200**.
- 2026-07-09 iter 49: window raised 200 → 400 (82% ≥ 80%), new baseline
  283/400 (71%). Top class: subscripting (9) — two roots. (1) `$items[index]`
  → BindingStub.elementBinding(at:) write-through element bindings in the
  subscript evaluator; Array(repeating:count:) builtin joined (DarkMode's
  empty-toggles root). (2) AttributedString styling — real Foundation-backed
  AttributedStringBox: range(of:), s[range] proxies via a new host-subscript
  hook (registry hostMember "subscript"), foregroundColor/font attribute
  writes on ranges AND whole strings, Text(attributed) renders styled.
  WindowStub.isKeyWindow = true. StyledConsent corpus. LottieRatingBar,
  GlassMorphism, Split, LikedAnimation + ripple pass; GSignin/
  DarkModeAnimation advanced into UIKit window introspection, DownloadTask
  opaque, Cart/AnimationChallenge4 into marker-arithmetic.
  **283/400 → 290/400**.
- 2026-07-09 iter 50: the member-on-void class (7) — environment holes.
  Missing env objects synthesize one fresh instance per type (the App shell
  that would inject them never runs; ambient wins — fresh-store doctrine,
  documented); verify() now injects env objects at the ROOT too.
  `@Environment(\.self)` serves the whole values table via
  EnvironmentValuesStub (member reads hit the same defaults, real-side
  overrides included). `@FetchRequest`/`@SectionedFetchRequest` join the
  query-flatten family and `\.managedObjectContext` maps to the inert
  context. PopupImagePicker + InteractiveToasts ×2 pass (+ripple); TaskApp →
  CalendarBox class, IconGenerator → marker-compare, SwiftUIRealm stays
  (ObjectId). **290/400 → 297/400**.
- 2026-07-09 iter 51: the CalendarBox class (5) — real-Calendar breadth:
  dateComponents(_:from:[to:]) → mutable DateComponentsBox (member reads AND
  writes, plus a DateComponents() constructor), range(of:in:for:),
  month/weekday symbols, isDateInToday/Tomorrow/Yesterday/Weekend,
  isDate(_:inSameDayAs:), date(from: components). Fallout fixes with general
  value: STATIC COMPUTED properties (`static var x: T { … }`) collect into
  staticComputedProperties and evaluate with self = the TYPE (bare sibling
  statics resolve; staticMember rewritten symbol-based — the old inout cache
  caused an exclusivity crash on re-entry); user host-extension statics
  (`extension Date { static var currentMonth }`) resolve in annotated
  positions; Int gains promoting truncatingRemainder; Date joins
  hostCandidates (user Date-extension instance methods). SleepTime ×2,
  ElegantTaskApp, CustomScrollAnimation pass; TaskApp/AnimatedCharts
  advanced. **297/400 → 301/400**.
- 2026-07-09 iter 52: the "expected a Bool" class — @FocusState defaults.
  Uninitialized non-optional `@FocusState var x: Bool` synthesizes `false`
  (real SwiftUI semantics; optionals stay nil), and BindingStub joins
  hostCandidates so user `extension Binding { … }` members dispatch on
  projections ($otpText.limit(6)). AutoOtpTF, ExpandableSearchBar,
  Custom_Header pass (+ripple); ImageColorPicker ×2 remain (marker-typed
  extension dispatch on Color values — deferred), FaceID_Login is
  LocalAuthentication. **301/400 → 306/400**.
- 2026-07-09 iter 53: parameterized closures on unknown constructors are
  callbacks, not builders — recorded as configuration and never invoked
  (`SignInWithAppleButton { request in }`, `UIAction(…) { _ in }`); the
  generic recorder previously called them argument-less. Apple_Signin,
  AppleSignIn, CustomContentMenu pass (+ripple). The "missing argument"
  class is now purely the Layout-protocol wall (Chips_UI, LoopingCards).
  **306/400 → 311/400**.
- 2026-07-09 iter 54: lazy-forceable globals + static context in property
  initializers — the "unresolved identifier" class. Top-level identifier
  bindings hoist as LazyGlobal thunks (forward/cross-file references force
  on first read) while STILL executing eagerly in statement order unless
  already forced (main.swift sequential semantics preserved — first attempt
  broke 6 tests by going fully lazy). Property initializers evaluate with
  self = the type, so bare statics resolve (`Timer.publish(every:
  autoScrollDuration…)`). FacebookGradientMask, HeroNavigationStack,
  AutoScrollCarousel, WidgetsDemo pass. **311/400 → 315/400**.
- 2026-07-09 iter 55: conditional compilation — the harness identifies as an
  iOS-shaped canvas: os(iOS)/canImport/DEBUG/swift() hold, os(macOS)/
  targetEnvironment and unknowns take #else (documented; consistent with the
  UIKit-flavored stubs). Wired through all four positions: top-level
  (expandedTopLevelItems feeds collector + run), struct members, statements
  (control flow propagates), builders (active clause contributes views), and
  postfix modifier chains (PostfixIfConfigExpr grafts the base onto the
  active clause's chain). TabBars advanced (UIDevice chain), NotesMacOS +
  SharedLogin-Updated pass. **315/400 → 318/400**.
- 2026-07-09 iter 56: @Bindable locals — `$name` resolution consults scope
  LOCALS before the self property path: a local holding a model instance
  projects member bindings (ModelProjection), a local binding projects
  itself. `@Bindable var x = model; $x.activeTab` — the Observation binding
  idiom. TabBarSheet, CustomNavigationPopItems, ZoomTransitions pass.
  **318/400 → 321/400 (80.25% — next iteration raises the window to --all).**
- 2026-07-09 iter 57: window raised 400 → --all (80.25% ≥ 80%). Full-corpus
  baseline **431/587 (73.4%)**. Top class: doStmt in view builders (13) —
  imperative statements inside builder-evaluated closures (`.task { do { try
  await fetch() } catch {} }`) now execute for effect via executeStatement
  (explicit returns contribute views); do/guard/for/while all covered.
  Ride-alongs the class projects needed: `#selector(...)`/macro expressions
  evaluate as inert markers, AppStub.sendAction inert (keyboard dismissal).
  CompositionalLayout, EmailLogin, SocialMedia ×2 pass (+ripple).
  **431/587 → 444/587**.
- 2026-07-09 iter 58: the TraceNode-arithmetic class (7) — two big roots plus
  a chain of Foundation gaps behind them. (1) `Text + Text` concatenation:
  new HostRegistry.combineValues hook — trace records a TextConcat node,
  real approximates with a zero-spacing HStack (documented). (2) Formatter
  values leaking as nodes: real NumberFormatterBox (numberStyle/
  fraction-digit writes, string(from:)/number(from:)), NSNumber passthrough,
  Float builtin, String(format:) real formatting, `.init` on host
  constructor functions calls them, marker-tolerant date/number formatters,
  chained markers resolve in annotated positions (`.now.startOfMonth` runs
  the user Date extension), Calendar date() gains DateComponents-marker
  byAdding + bySettingHour forms. Image_Viewer, MovieAppUI, Food_App_UI,
  Cart, Fitness_DashBoard pass; the Expense series advanced deep.
  **444/587 → 450/587**.
- 2026-07-09 iter 59: query-wrapper CONSTRUCTORS are fresh-store empties —
  `_list = Query(descriptor, animation:)` in custom inits assigned a
  TraceNode over the flattened `[]` (Query/FetchRequest/SectionedFetch/
  ObservedResults ctors now return empty results); unknown store-query
  TraceNodes act empty for map/compactMap/filter/sorted/count/isEmpty (the
  realm.objects(...) reading). MinimalTodo, NotesApp, Task_Management ×2 +
  ripple pass; RealmDataBase/Expense EP5 advanced. **450/587 → 455/587**.
- 2026-07-09 iter 60: the superExpr wall, taken as inheritance-lite —
  StructSymbol.superclassName (first non-protocol inherited type); `super`
  evaluates to a SuperReference: interpreted parents dispatch methods/
  computed with self unchanged, host parents (NSObject…) make super.* inert.
  Ride-along general gaps the same chains hit: IUO annotations (`Track!`)
  seed nil; marker comparisons are name-based (authorization checks read as
  fresh-system-state false); member WRITES on markers are inert
  (`manager.delegate = self`); break/continue execute in builder position.
  ShazamKitApp, CameraControlAPI, PomodoroTimer pass; LocationSearch pair →
  Combine $published pipelines, HeaderAnimation → window wall.
  **455/587 → 470/587 (+15 — the marker fixes rippled corpus-wide).**
- 2026-07-09 iter 61: the UIKit window/app surface (WindowStub 6 + AppStub 6,
  sibling classes). New HostRegistry.hostTypeName hook: stubs name the host
  type they stand for (AppStub → UIApplication, trace nodes → their
  constructor kind), so user `extension UIApplication { … }` members dispatch
  on stubs; bare host members resolve as implicit self inside those extension
  bodies. window.rootViewController opens a UIKitStub island — memoized
  chainable reads, round-tripping writes, InertCallable calls (present/
  dismiss inert). AppStub gains canOpenURL (true — schemes resolve on real
  devices) + open (inert). GSignin, DarkModeAnimation, MultiLogin ×2,
  InAppNotifications, LinkPreview ×2, Signal_ImagePicker, DLogin,
  DynamicProgressView pass. **470/587 → 481/587 (81.9%)**.
- 2026-07-09 iter 62: optional-binding pattern breadth — `if let _ = x`
  (wildcard AND expression-pattern-wrapped discard: presence check, no
  binding) and `if let (a, b) = pair` (tuple destructuring via TuplePattern
  or expression-pattern tuples of unresolved names/pattern exprs).
  ImageRenderer-PDF, MapRoutes, 3DCardAnimation, HabitTracker pass;
  ImageDrawing advanced. **481/587 → 485/587**.
- 2026-07-09 iter 63: Double division follows IEEE 754 — x/0 is ±inf, 0/0 is
  NaN, exactly like real Swift (the old always-throw was WRONG for doubles;
  Int division still traps). The stub canvas width 390 was cancelling
  hardcoded 390s in scroll-geometry ratios (`width / (width - 390)`).
  Filled, ScrollDetection, AppleWalletScroll, PinterestGridAnimation pass;
  TwitterProfileScrolling remains (honest Int-division trap fed a stub
  zero). **485/587 → 489/587**.
- 2026-07-09 iter 64: the String-member class (4) — the card-formatting
  genre. Mutating append (positional + contentsOf:) and insert(_:at:
  String.Index) through lvalues; enumerated() with (offset, element)-labeled
  tuples; count(where:) via the call-aware hook (the property keeps winning
  plain .count); components(separatedBy:); forEach over characters. Two
  language companions: one tuple argument SPLATS across multi-parameter
  closures ({ index, char in } over enumerated()), and for-in destructures
  tuple patterns (`for (index, digit) in text.enumerated()`). PaymentCard,
  WalletAnimation, QuizGame, SequencedAnimation pass. **489/587 → 493/587**.
- 2026-07-09 iter 65: marker arithmetic — the chain-combine class (4).
  Members read off `.init(labeled:)` markers return the matching labeled
  argument (memberwise read-back: `.init(width: 100, height: 120).height` →
  120); CG-shaped init markers do arithmetic on their labeled numeric
  arguments and REWRAP (`Angle(degrees:) * 0.1`, `sizeA - sizeB` elementwise,
  scalar broadcasts), staying typed markers for later coercion; chained
  markers compare by final member name (`.current.orientation ==
  .landscapeRight` → false). 3DGestureCard, FloatingWindow,
  Pomodoro_Timer_Part_1, CustomVideoPlayer_-_Part_2 pass (+ripple).
  **493/587 → 499/587**.
- 2026-07-09 iter 66: CalendarBox round two — `dateInterval(of:for:)` with a
  DateIntervalBox (start/end/duration), weekOfMonth/weekOfYear/quarter
  components, and Foundation boxes gain host type names (CalendarBox →
  "Calendar", DateFormatter/NumberFormatter/DateComponents likewise) so user
  `extension Calendar { var hours … }` members dispatch on the real-backed
  boxes. TaskManagement, TaskPlanner (162 nodes — its Calendar extension
  evaluates for real), TaskManagementCoreData ×2 pass.
  **499/587 → 503/587 (85.7%).**
- 2026-07-09 iter 67: the protocols wall, first slice — protocol declarations
  collect inertly (requirements carry no bodies; conformance is duck typing),
  and protocol-EXTENSION members dispatch as DEFAULTS through the conformer's
  inheritance clause (own definitions win). Operator/precedence/typealias
  declarations skip inertly (vendored-Pods projects declare custom
  operators). Quiz + Global_Chat (despite merged Firebase Pods!) pass;
  SplashScreen advanced deep into vendored lib internals.
  **503/587 → 505/587 (86.0%).**
- 2026-07-09 iter 68: custom @resultBuilders — the member-on-closure class
  (3). Builder detection widened from @ViewBuilder to any *Builder-suffixed
  attribute; builder properties with `[X]` annotations collect their block's
  items into an ARRAY (buildBlock semantics), view-typed ones keep grouping.
  CustomSwipeActions_Updated + Expense_Tracker EP2/EP3 pass (146/138-node
  renders — the Expense march ends). **505/587 → 508/587 (86.5%).**
- 2026-07-09 iter 69: `.constant(x)` bindings — the marker-compare class (3).
  Constant bindings resolve to fixed-value boxes at @Binding memberwise
  positions (annotation-resolved) and in the bridge's binding coercions
  (Toggle(isOn: .constant(true))), so side-menu rows comparing
  `selectedMenu == title` read the constant. Custom_Side_Menu, Drawer,
  Instagram_Desktop (266 nodes / 29 actions — the largest render yet) pass.
  **508/587 → 511/587 (87.1%).**
- 2026-07-09 iter 70: the date(byAdding:) remainder — bare `.init()` markers
  construct Dates in date positions (timeIntervalSince1970/Now labeled forms
  included); Dates compare with </<=/>/>=; sorted accepts by:-labeled
  closures; calendar.compare(_:to:toGranularity:) returns marker-comparable
  ComparisonResults. Task_Management ×2 (92 nodes) + CardAnimation pass.
  **511/587 → 514/587 (87.6%).**
- 2026-07-09 iter 71: Combine `$published` projections — the $searchText
  class (3). Inside a model, `$published` yields a PublishedProjection whose
  pipeline stages (debounce/removeDuplicates/sink/store) chain inertly and
  never emit (documented: schedulers don't run headlessly). `&inout`
  expressions evaluate pass-through (reference semantics) and Set() joins
  the builtins (array-backed set-lite). LocationSearch ×2 + Marvel_API pass.
  **514/587 → 517/587 (88.1%).**
- 2026-07-09 iter 72: the member-on-void class resolved three ways. Path is a
  Shape/View: draw commands chain (`Path{}.strokedPath(StrokeStyle(...))
  .fill(...)`), strokedPath/addLines apply for REAL, StrokeStyle constructs,
  fill/stroke accept PathDrawStub, Path renders in view position in both
  registries — CustomScrollViewBottomShee passes. The two Realm projects are
  QUARANTINED (ProjectCheck gains the mechanism, reasons printed as 🚧 and
  recorded above) — third-party ORM internals, the sanctioned last resort.
  Metric basis is now 585. **517 → 518 passing / 66 failing / 2 quarantined
  (88.5% of the metric).**
- 2026-07-09 iter 73: the tied 3-classes — WindowStub.frame/bounds read as
  the canvas rect (ResponsiveUI ×3, one advancing through `.zero + .init`
  zero-marker arithmetic), and the Expense string(from:) chase ended at
  numeric `.zero` statics: Double/CGFloat/Int/TimeInterval `.zero` (+
  infinity/pi) resolve via the marker table, formatter belt-and-suspenders
  included. The WHOLE Expense_Tracker series passes (EP2→Complete). +11
  ripple. **518 → 529/585 (90.4% — past 90%).**
- 2026-07-09 iter 74: enum static computed properties (the iter-51 struct fix
  applied to the enum collector — `static var count: CGFloat` on a
  CaseIterable Tab), trig/math builtins (sin/cos/tan/asin/acos/atan/atan2/
  log/log2/exp/hypot), and bare numeric markers absorb in arithmetic
  (`x / .pi`, `.infinity`). PS_TabBar + Interactive_Header pass.
  **529 → 531/585 (90.8%).**
- 2026-07-09 iter 75: the Layout wall, taken as containers — Layout
  conformers accept trailing content (children stash at init) and modifiers,
  rendering as a default flow in both registries (sizeThatFits/placeSubviews
  never run — documented). Clears the TagLayout pair AND the long-standing
  wall pair: TagView, TagTextField, Chips_UI (blocked since iter 36),
  LoopingCards. **531 → 534/585 (91.3%).**
- 2026-07-09 iter 76: hosted-object nodes act like objects — TraceNodes with
  UIKit-ish constructor prefixes (UI/NS/CA/AV/CL/MK/WK/SK/PH) serve members
  as memoized chained bags (`engine.mainMixerNode.outputVolume = 0.5`
  round-trips) instead of falling into the view-modifier catch-all, and
  TraceNode is InertCallable (calls absorb, clearing the "not callable"
  class too). Canvas_Editor, ImageDrawing, InteractiveToasts,
  Responsive_UI_New (218 nodes) pass — two classes, one stroke.
  **534 → 538/585 (92.0%).**
- 2026-07-09 iter 77: fresh-state Bool doctrine — hosted-object values
  (InertCallable) AND unresolved markers in Bool positions read false
  (`canEvaluatePolicy` → no biometrics, `session.isRunning` → nothing runs
  headlessly); `!` negates from that. Clears the Bool/TraceNode 3-class and
  half the Bool-operand pair: Music, FaceID_Login ×2, QRCodeScanner pass;
  TextSelectionAPI advanced (patternExpr singleton).
  **538 → 543/585 (92.8%).**
- 2026-07-09 iter 78: real Color statics — `Color.white` etc. resolve to real
  Colors (user `extension Color/UIColor` members dispatch via the
  hostTypeName precedence rule: user extensions of a stub's host type WIN
  over bridge members); tuple locals destructure (`var (r, g, b, a) =
  (0,0,0,0)`); native-Color members (opacity/gradient), AnyGradient.opacity,
  AnyShapeStyle pass-through, and AnyHashable equality (realized Colors
  compare) — the last three recovered a 4-project regression the
  realization caused. ImageColorPicker ×2 pass. **543 → 545/585 (93.2%).**
- 2026-07-09 iter 79: size-class env keys — horizontalSizeClass reads
  .compact / verticalSizeClass .regular (the iPhone-portrait canvas), plus
  dynamicTypeSize/.scenePhase defaults; Query-shaped `.init(filter:sort:)`
  markers act as fresh empty stores in ForEach. AdaptiveLayoutDesign +
  Notes_App_Complete pass. **545 → 547/585 (93.5%).**
- 2026-07-09 iter 80: array `append(contentsOf:)` splices through the
  mutating-lvalue path (both AnimatedCharts units pass — their multi-
  iteration march ends). **547 → 549/585 (93.8%).**
- 2026-07-09 iter 81: fractional ranges — `0.01...0.1` constructs
  ClosedRange<Double> (Int semantics unchanged), doubleRangeValue bridges
  Int ranges, and the consumers speak both: Slider(in:), Double.random(in:),
  Int-context random over double bounds. HackerTextEffect passes;
  MatrixRainEffect advanced to stub-fed index math.
  **549 → 550/585 (94.0%).**
- 2026-07-09 iter 82: property-shadowed modifiers — the modifier-retry
  (iter 46) extends to "is not callable" failures: `var offset: CGFloat` on
  a view struct no longer shadows `.offset(y:)` at call sites (invocation
  fails before any body runs → the retry is safe). BottomSheet,
  CustomCarouselSlider, CompositionalGridLayout pass (+ripple); the LAST
  2-class is gone — the histogram is all singletons.
  **550 → 554/585 (94.7%).**
- 2026-07-09 iter 83: the OSS rung (step 9) — the zip histogram went
  all-singletons, so the ladder gains real GitHub material: SwiftUI-Kit
  (jordansinger, 18 files), SwiftUI-2048 (unixzii, 11), Milestones (jpsim,
  21) cloned into External/oss/ (gitignored); ProjectCheck scans oss/
  directories as `oss:<name>` units. First contact: **SwiftUI-Kit passes
  immediately** (37-node catalog render); 2048 fails on `[.Index]`-typed
  call shapes and Milestones on the `/` case-path prefix operator — new
  class material the zip corpus never produced. Metric basis 588.
  **554 → 555/588 (94.4%).**
- 2026-07-09 iter 84: the 2048 quartet (first OSS-driven fixes) — USER
  SUBSCRIPTS (get/set, tuple indices, arity-matched, lvalue writes through
  setters), typed empty containers (`[Index]()`, `[String: Int]()`),
  typealiases resolve to their target types (top-level AND member-level,
  generic args dropped), and `defer` runs LIFO on every exit path.
  oss:SwiftUI-2048 advanced four walls deep (now at custom postfix
  operators); the zip corpus holds. **555/588 steady, four language
  features banked.**
- 2026-07-09 iter 85: the second 2048 batch — custom PREFIX/POSTFIX operator
  functions dispatch by name (`postfix func >*` — the AnyView-erasure
  operator; builtins keep priority for -/!), AnyView(x) is identity in both
  registries, backtick-escaped parameter labels normalize (`` `for` ``),
  and deferred-init locals (`let x: T` assigned in branches) hold void
  until first assignment. +1 zip ripple; 2048 now at capture-list self.
  **555 → 556/588 (94.6%).**
- 2026-07-09 iter 85: the second 2048 batch — custom PREFIX/POSTFIX operator
  functions dispatch by name (postfix func >* — the AnyView-erasure
  operator; builtins keep priority for -/!), AnyView(x) is identity in both
  registries, backtick-escaped parameter labels normalize, and
  deferred-init locals (let x: T assigned in branches) hold void until
  first assignment. +1 zip ripple; 2048 now at capture-list self.
  **555 → 556/588 (94.6%).**
- 2026-07-09 iter 86: **oss:SwiftUI-2048 PASSES — 7,445 nodes, the largest
  render ever** (the full game-board matrix deep-rendered). The final batch:
  static METHODS bind self = the type (statics/`self`/`Self` resolve in
  static bodies), `Self` resolves to the enclosing type, `Type.init(...)` ≡
  `Type(...)`, and Array.flatMap. A real GitHub game app runs end to end
  after 3 iterations / 11 language features. **556 → 557/588 (94.7%).**
- 2026-07-09 iter 87: min/max with predicates — the charts genre's
  `analytics.max { $0.value < $1.value }` compared whole instances via the
  no-closure path; by:-labeled and trailing predicates now drive both (min
  probes closure(element, best), max closure(best, element) — Swift's exact
  areInIncreasingOrder semantics). A 6-project class had been hiding as
  stringified-singleton histogram entries. InteractiveCharts ×2, DashBoards,
  BankingMacApp, SwiftCharts + ripple pass. **557 → 564/588 (95.9%).**
- 2026-07-09 iter 88: fresh-state numerics — the compare/combine family (10
  projects hiding across stringified messages). Unresolved markers/hosted
  objects read ZERO in arithmetic and FALSE in ordered comparisons;
  marker-vs-concrete equality is false; hosted objects compare by identity;
  numeric markers (.zero/.pi/.infinity) absorb in compare like arithmetic.
  Companions the chain exposed: FocusState false-synthesis is Bool-only,
  nil-optional switches match `.none`/`nil` cases, and `break` exits a
  SWITCH (not the enclosing function). StretchySlider, Game, IconGenerator,
  CustomTabView, CustomHUDs, CustomHeader, CardCreation_Updated + ripple.
  **564 → 571/588 (97.1%).**
- 2026-07-09 iter 89: value-type member writes — `size.width = 300` and
  nested `rect.origin`/`rect.size` swaps write through mutated copies (new
  registry hostMutatedCopy hook + LValue.hostValueMember; structs with
  readable members route there, class-backed boxes keep reference writes);
  `$tuple.0`/`$point.x` binding projections write through the parent box;
  `let _ = …` wildcard locals evaluate for effect. CustomScrollView (184
  nodes/34 actions) + Sticky_Header (152/18) pass.
  **571 → 572/588 (97.3%).**
- 2026-07-09 iter 90: custom @resultBuilder parameters — closures bound to
  `@…Builder` params undergo the builder transform (collect items, not
  last-expression); `[X]`-returning builder closures/functions collect into
  ARRAYS (view-typed still group). Attribute lives on
  FunctionParameterSyntax.attributes, not the type node.
  InteractiveFloatingButton passes (31 nodes, 4 actions).
  **572 → 573/588 (97.4%).**
- 2026-07-09 iter 91: name-resolution order — identifier lookup now walks
  locals (chain BEFORE globals) → implicit-self members → globals, matching
  real Swift scoping: a method named like a top-level type wins in its own
  body (`func OTPField()` vs `enum OTPField`), member properties shadow
  global constants. New Environment.box(for:before:) boundary walk.
  AutoOTP passes (44 nodes, 3 actions). **573 → 574/588 (97.4%).**
- 2026-07-09 iter 92: case patterns vs unknowable subjects — `.selection(let
  range)` against a host marker can't match, so the switch falls to
  `default` (fresh-state) instead of choking on the `let` binding; plus
  String.Index ranges (String.range(of:), Range<String.Index>
  lowerBound/upperBound/isEmpty, `text[range]`/`text[i]` subscripts).
  TextSelectionAPI passes (11 nodes, 4 actions). **574 → 575/588 (97.6%).**
- 2026-07-09 iter 93: inherited host-superclass initializers — classes whose
  superclass is a host type (class RainFall: SKScene) accept inherited-init
  labeled arguments as instance properties (readable later: `size` in
  sceneDidLoad); interpreted-superclass/protocol shapes keep the strict
  memberwise error (new isInterpretedType gate).
  WeatherAppScrolling_Rain_Effect_Updated passes (199 nodes).
  **575 → 576/588 (97.8%).**
- 2026-07-09 iter 94: numeric conversions absorb unknowables — Int()/
  Double()/Float() of host markers/chains read the fresh state (0; .pi/
  .infinity markers keep their constants) via new Builtins.absorbedNumeric,
  instead of yielding nil that poisons downstream comparisons
  (`Int(player.currentTime.truncatingRemainder(…)) < 9`).
  Audio_Player passes (40 nodes, 9 actions). **576 → 577/588 (98.0%).**
- 2026-07-09 iter 95: Locale host bridge — Locale.current/autoupdatingCurrent
  return the REAL host locale (CalendarBox precedent); members regionCode/
  identifier/languageCode/currencyCode/currencySymbol/localizedString(for…)
  via modern non-deprecated APIs; Locale(identifier:) constructor;
  hostTypeName "Locale" for extension dispatch.
  PhoneAuth_Updated_Latest passes (35 nodes, 13 actions).
  **577 → 578/588 (98.3%).**
- 2026-07-09 iter 96: FileManager sandbox + real URLs — FileManager.default
  performs real file ops confined to a per-run temp sandbox (fresh
  container: documents start empty; ops outside the sandbox throw);
  urls/fileExists/remove/copy/move/createDirectory/contentsOfDirectory;
  URL(string:) has real semantics (invalid → nil) with unknowable marker
  strings flowing through (openSettingsURLString — caught a mid-iteration
  Signal_ImagePicker regression); URL members (path/lastPathComponent/
  appending…/deleting…). README fresh-state doctrine updated.
  DownloadTask passes (7 nodes). **578 → 579/588 (98.5%).**
- 2026-07-09 iter 97: fresh-identity absorption — unknowables read each
  context's identity value: "" in string concat (suffix survives:
  NSTemporaryDirectory() + "….mov"), empty in for-in iteration
  (Activity<T>.activities; bare `.member` sequences too). README doctrine
  extended. ReelsCamera (22 nodes) + Lockscreen_Dock (13) pass.
  **579 → 581/588 (98.8%).**
- 2026-07-09 iter 98: appearance proxy = UIKitStub — `.appearance()` returns
  the read/write bag (writes stick, reads memoize, config calls chain);
  UIKitStub geometry members (bounds/frame → CGRect.zero, center/
  contentOffset → CGPoint.zero, contentSize → CGSize.zero) read REAL
  fresh-layout values so CGRect math works; AppearanceStub deleted.
  CustomHeader passes (18 nodes). **581 → 582/588 (99.0%).**
- 2026-07-09 iter 99: Double-family annotation coercion — CGFloat/Double/
  TimeInterval/Float-annotated storage coerces Int values to Double at
  resolveAnnotated, so `20 / titleOffset` with a zero offset is IEEE
  infinity (compiled-Swift behavior) instead of an Int-division trap.
  TwitterProfileScrolling passes (242 nodes, 5 actions).
  **582 → 583/588 (99.1%).**
- 2026-07-09 iter 100: Array(String) splits into characters — the Array()
  builtin maps a string to single-char strings (our character model), so
  `Array(constant)[getRandomIndex(…)]` indexes real characters instead of
  a one-element wrap. MatrixRainEffect passes (711 nodes — full grid).
  **583 → 584/588 (99.3%). Only the three SDK/Pods walls remain.**
- 2026-07-09 iter 101: static stored property WRITES — `ChatClient.shared =
  ChatClient(config:…)` (extension statics on host types, declared without
  initializers → nil until written) and `Palette.accent = "red"` (interpreted
  types) write through new LValue.staticProperty into the symbol's static
  cache; reads serve extension statics off host constructor functions;
  locals shadow via the before-globals walk. Stream_Tutorials passes
  (12 nodes). **584 → 585/588 (99.5%). Remaining: Milestones (TCA),
  SplashScreen (Pods).**
- 2026-07-09 iter 102: oss:Milestones — three layers peeled: (1) CasePaths
  prefix `/` yields an inert CasePathMarker (operand kept textual — case
  references aren't standalone values); (2) DateFormatterBox config setters
  (locale/calendar/timeZone/dateStyle/timeStyle/am-pmSymbol); (3) ROOT view
  parameter synthesis — parameterized roots (no ContentView) instantiate
  with fresh values per annotation: identity primitives, empty collections,
  nil optionals, recursive fresh instances for interpreted types (custom
  inits included), Binding stubs, unknowable chains for host generics
  (Store<A,B>). oss:Milestones passes. **585 → 586/588 (99.7%).
  Remaining: SplashScreen (vendored Pods).**
- 2026-07-09 iter 103: vendored type-name collisions — Lottie's `struct
  Color` (12.8k lines of vendored Pods) shadowed SwiftUI.Color under our
  merged-module model. Two fallthroughs, both binding-safe: constructor
  binding failures on interpreted types retry the same-named registry
  constructor (Color("bg") → asset color); static-member misses on
  registry-known type names fall through to bridge statics/implicit
  members (Color.black). SplashScreen passes (33 nodes, 3 actions).
  **586 → 587/587 counted units — ZERO failures. The local ladder + OSS
  rung are saturated; step 9 (new OSS material) applies next.**
