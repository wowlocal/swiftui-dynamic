# Dynamic SwiftUI

A tree-walking Swift interpreter that parses Swift source **at runtime** with
[SwiftSyntax] and renders user-defined SwiftUI views live — type a counter app
into the editor pane, click its buttons in the preview pane.

Inspired by [Bitrig's Swift interpreter series][bitrig-1] ([part on
expressions][bitrig-2]) and [Cocoanetics/SwiftScript][swiftscript].

```
swift run DynamicSwiftUIDemo
```

An editor opens on the left, the live interpreted view renders on the right.
Built-in samples (toolbar picker): **Counter** (`@State` + Button
actions), **Todo** (MVVM `ObservableObject` store shared by views), **Form**
(`$state` bindings driving `Toggle`/`Slider`/`TextField`), **Weather** (enums
with methods, `switch` in bodies, gradients), **Layout** (stacks, modifiers,
`ForEach` chips), **List** (nested user-defined views), plus two lifted from
the sample-projects corpus: **Segments** (Kavsoft's AnimatedSegmentedControl —
generic view with a `@ViewBuilder` closure property, GeometryReader indicator
math) and **Material** (Kavsoft's MaterialTF — floating-label text field).

```
swift test
```

## How it works

```
source ──SwiftParser──▶ AST ──SwiftOperators.foldAll──▶ precedence-folded AST
       ──DeclarationCollector──▶ StructSymbols in globals
       ──tree-walking eval──▶ RuntimeValue (type-erased enum)
       ──HostRegistry gateways──▶ real SwiftUI views (AnyView)
```

- **No custom parser.** SwiftSyntax parses; `SwiftOperators` folds flat
  operator sequences into precedence trees, so the evaluator never implements
  precedence.
- **No reimplemented frameworks.** The interpreter core (`SwiftInterpreter`)
  never imports SwiftUI. "What does `VStack` mean" is answered by the
  `SwiftUIBridge` target through hand-written *gateway* tables — functions
  that accept dynamic arguments and call the real SwiftUI API (the Bitrig
  trick). A `TraceRegistry` implements the same protocol for headless tests.
- **User View structs become real views** via a stub: `InterpretedView` is a
  SwiftUI `View` whose `body` asks the interpreter to evaluate the interpreted
  `body` property.
- **`@State` re-render loop:** state lives in `Box`es on the instance; an
  interpreted Button action mutates the box → the box's `onChange` fires →
  a `StateStore` (`@StateObject`) publishes `objectWillChange` → SwiftUI
  re-runs `InterpretedView.body` → the interpreted body re-evaluates with the
  new value. `StateStore.adopt` carries boxes across instance recreations, so
  state survives parent re-renders just like real SwiftUI.
- **Implicit members** (`.title`, `.blue`, `.leading`) evaluate to a marker
  value and are resolved against the *expected* parameter type inside each
  gateway — type-inference dodged with lookup tables.

## Supported subset

**Language**: literals + interpolation, arrays/dictionaries/tuples with
subscripts, operators with real precedence, optionals (`if let`/`guard
let`/shorthand, `??`, `?.` chaining, `!`), `if`/`else`, `switch` with
expression/range/enum-payload/`where` patterns (also as expressions and in
builders), `for`-in, `while`, `break`/`continue`, functions (defaults,
implicit return, trailing closures, `@ViewBuilder`/`some View` builder
bodies), closures (`$0` shorthand, capture-by-reference), structs (stored/
computed properties, methods, custom `init`s, memberwise init, statics),
enums (raw + associated values, methods, computed properties, `CaseIterable`),
**classes** (reference semantics, custom inits, statics, `super`
inheritance-lite), **user subscripts** (get/set, tuple and multi-arg
indices), `defer` (LIFO, all exit paths), typealiases (target types,
generic args dropped), **protocols** (declarations inert — conformance is duck
typing; protocol-EXTENSION members serve as defaults, conformers' own
definitions win), extensions,
**view models** — `ObservableObject`/`@Observable` with `@Published`,
`@StateObject` (model persists across view recreation), `@ObservedObject`
(shared models re-render every observing view), `$store.field` bindings onto
model properties — plus `@State`, `@Binding`, `$` projections, ~40 stdlib members
(`map`/`filter`/`reduce`/`sorted`/`first(where:)`/`contains`/`joined`/
mutating `append`/`remove(at:)`/…, string methods), and global
`print`/`abs`/`min`/`max`/`String`/`Int`/`Double`/`Array`.

**Type context, dynamically**: bare `.member` values resolve against known
enums via the type annotations on properties, parameters, and return types —
no inference engine, just annotations.

**SwiftUI**: `Text`, `Image(systemName:)`, `Label`, stacks, `Group`,
`ScrollView`, `List`, `Form`, `Section`, `LazyVGrid`/`LazyHGrid`/`GridItem`,
`NavigationStack`/`NavigationLink`, `TabView`/`.tabItem`, `Button` (with
roles), `Toggle`, `Slider`, `TextField`/`SecureField`, `Picker` (String
selection), `ForEach` (ranges, arrays, and `ForEach($items) { $item in … }`
binding collections — element bindings write back into the array, and
`$item.field` projects field bindings à la `@dynamicMemberLookup`), `ProgressView`, `Spacer`/`Divider`, shapes (`Circle`,
`Capsule`, `Rectangle`, `RoundedRectangle`, `Ellipse`) with `.fill`/`.stroke`,
`LinearGradient`, `withAnimation`, **user `Shape` structs** (`func path(in:)
-> Path` runs interpreted and draws real geometry; `.fill`/`.stroke`/`.trim`
apply); presentation — `.sheet(isPresented:)`,
`.alert(_:isPresented:actions:message:)`, `.confirmationDialog`; environment —
`.environmentObject(_:)` + `@EnvironmentObject` (carried on SwiftUI's real
Environment, so scoping and propagation into sheets come for free); **AttributedString styling** (`range(of:)` + `text[range].foregroundColor =`
applied to the real Foundation type, rendered by `Text`); `$items[index]`
element bindings; `UUID()`
and `Date()` basics; ~50 modifiers including `padding`/`frame`/`font`/
`foregroundStyle` (colors, materials, hierarchicals, `.color.opacity`/
`.gradient` chains)/`background`/`overlay`/`shadow`/`clipShape`/`offset`/
`scaleEffect`/`rotationEffect`/`animation(value:)`/`onAppear`/`onTapGesture`/
`task`/`navigationTitle`/`listStyle`/`buttonStyle`/`pickerStyle`.

## Generated gateways (BridgeGen)

Hand-writing gateways doesn't scale to SwiftUI's real surface, so
`swift run BridgeGen --emit` parses the SDK's **actual swiftinterface files**
(SwiftUICore + SwiftUI — the modern SDK splits them) and generates
`Generated/GeneratedModifiers.swift` (**214 overload variants across ~127
modifier names**) and `Generated/GeneratedViews.swift` (**44 initializer
variants across 15 View structs** — Button, Toggle, TextField, Label,
ContentUnavailableView, gradients…). Struct inits mostly live in *extensions*
with same-type constraints (`extension GroupBox where Label == Text`), so the
generator threads struct-level generics plus extension where-clauses (both
conformance sets and concrete substitutions) into parameter analysis. Every
entry is a statically-compiled call against the real SDK, so a wrong signature
fails at build time rather than in a session. Dispatch
goes through the ArgumentMatcher (`GeneratedSupport.swift`): per-overload
parameter specs (label + coercible type tag), label/coercibility filtering,
most-specific-first ranking. Hand-written gateways are consulted first and
always win. The report mode (no `--emit`) prints the blocking-type histogram —
the priority list for new coercions. Defaulted parameters are handled by
emitting suffix variants (full call, then trailing defaults dropped).

## Corpus verification

`Tests/SwiftUIBridgeTests/Corpus/` holds ten realistic programs (todo list,
settings form, weather card, grid gallery, navigation profiles, stats
dashboard, animated counter, string toolkit, shape showcase, traffic light).
Each must: interpret; **deep-render** (every View body force-evaluated via the
trace registry, not just the lazy root); survive a click-through pass where
every Button action fires against a fresh render; and host through real
SwiftUI (`NSHostingView` in a never-shown window) with zero inline errors
(observed via `RenderDiagnostics`). This suite is the working definition of
"runs real-world code" — new corpus files are the cheapest way to grow
coverage.

## Deliberate divergences from Swift

- **Interpreted structs are reference-backed.** `Instance` is a class; there
  is no copy-on-assignment. This is exactly what makes `@State` mutation from
  an action closure observable without copy machinery. `mutating` is ignored.
- **Argument labels aren't checked** — binding is positional (trailing
  closures bind last).
- **State resets on re-parse.** Each successful edit gets a fresh identity
  (`.id(generation)`); the old program's state may not fit the new program.
- **ForEach/container identity is positional** — bodies re-evaluate wholesale,
  so `@State` inside reordered children won't track.
- **No type checking.** Type annotations parse but are ignored; errors show up
  at evaluation time, located (`line:col`) in the error bar.
- **Bindings are Box handles.** `$name` projects the state's storage box; the
  bridge wraps it in a real `Binding` whose setter writes the box (rounding
  back to Int when the state was declared Int, e.g. for `Slider`).
- **Platform stubs.** `UIScreen.main.bounds` maps to the main screen's frame
  (390×844 headlessly); `DispatchQueue.main.async` dispatches interpreted
  closures through the real main queue; `UIViewRepresentable`/
  `NSViewRepresentable` structs are accepted in view position but render
  inert (their make/update methods never run); `X.appearance()` proxies accept
  all configuration inertly (writes ignored, config calls chain).
- **Conditional compilation identifies as iOS.** `#if os(iOS)`,
  `canImport(_)`, `DEBUG`, and `swift(…)`/`compiler(…)` hold;
  `os(macOS)`/`targetEnvironment(simulator)` and unknown conditions take
  the `#else` branch — consistent with the iOS-shaped platform stubs.
  Works in declaration, statement, builder, and postfix (modifier-chain)
  positions.
- **Custom `Layout` containers flow.** `TagLayout(spacing:) { … }` renders
  its children in a default vertical flow; the interpreted
  `sizeThatFits`/`placeSubviews` never run.
- **Hosted-object truths are fresh-state false.** Unknown host objects and
  unresolved markers in Bool positions read `false` (`context.
  canEvaluatePolicy(…)`, `session.isRunning` — no biometrics, nothing
  running headlessly); `!` negates from that. The same absorption reads
  unknowables as each context's fresh identity: 0 in arithmetic and numeric
  conversions, `""` in string concatenation
  (`NSTemporaryDirectory() + name` keeps the name), and empty in `for-in`
  iteration (`Activity<T>.activities` on a fresh device).
- **Canvas drawing is inert.** `Canvas { context, size in … }` runs the
  renderer once against a no-op context (390×844) — the closure's math
  executes, but fill/stroke/translate commands never reach a real
  `GraphicsContext`; the canvas area renders empty. `Path { … }` builders
  execute the same way.
- **Casts are optimistic.** `as`/`as!` pass the value through; `as?` only
  yields nil for nil inputs. The target type does resolve implicit-member
  markers and bridges Int/Double.
- **State-like wrappers flatten to @State.** `@AppStorage`, `@SceneStorage`,
  `@GestureState`, and `@FocusState` bind and project like `@State` but skip
  their special semantics (no UserDefaults persistence, no gesture reset, no
  focus plumbing).
- **Store-query wrappers act on a fresh empty store.** `@Query` (SwiftData),
  `@ObservedResults` (Realm), and `@FetchRequest` (CoreData) flatten to
  `@State` defaulting to `[]`; `@Environment(\.modelContext)` and
  `\.managedObjectContext` yield an inert context (insert/delete/save
  accepted and ignored, fetch returns empty); `$results.append/remove`
  mutate the flattened state array. Nothing persists.
- **The file system is a per-run sandbox.** `FileManager.default` performs
  real file operations confined to a temp-directory sandbox (the analog of
  an app's fresh container): `urls(for:in:)` returns a sandbox Documents
  directory that starts empty, `fileExists` is honestly false until the
  program writes, copy/move/remove genuinely happen inside the sandbox and
  throw outside it. `URL(string:)` has real Foundation semantics (invalid
  strings are nil).
- **Missing environment objects synthesize fresh models.** When
  `@EnvironmentObject`/`@Environment(Type.self)` finds no ambient model (the
  `App` shell that would inject it never runs), a fresh instance of the type
  is constructed once and shared — the fresh-store doctrine applied to
  models. Ambient injections always win.
- **Typed environment rides the model environment.**
  `@Environment(Type.self)` + `.environment(model)` behave exactly like
  `@EnvironmentObject` + `.environmentObject(_:)`, keyed by type name.
- **Actors are reference-typed classes.** `actor` declarations collect like
  classes (reference semantics, methods, properties); isolation is not
  enforced — calls run synchronously on the caller, which is faithful in
  practice: the interpreter is single-threaded.
- **`super` is inheritance-lite.** Interpreted superclasses dispatch
  methods/computed properties with `self` unchanged (plain member access
  walks the chain too), and stored properties MERGE down the interpreted
  chain at instantiation (child declarations win). Host superclasses
  (NSObject, UIViewController…) make `super.init()` and lifecycle calls
  inert.
  Member writes on unresolvable host markers (`manager.delegate = self`)
  are accepted and ignored; marker comparisons are name-based
  (`authorizationStatus(for: .video) == .authorized` is false — fresh
  system state).
- **Property observers are inert.** `willSet`/`didSet` bindings parse as plain
  stored properties; the observer bodies never run.
- **`$published` pipelines are silent.** The Combine projection inside a
  model (`$searchText.debounce(…).sink {…}`) chains inertly and never
  emits — debounce schedulers and timers don't run headlessly, so sinks
  stay quiet.
- **Model notification is box-level.** Writing a `@Published` property (or any
  stored property of an `@Observable` class) fires the model's change signal.
  Mutating an instance nested *inside* a published collection doesn't — 
  reassign through the collection (`todos[i] = item`) to notify. `@StateObject`
  initializer side effects re-run (and are discarded) on view recreation.
- Not supported (v1): generics, protocols, enums, custom `init`, optionals
  beyond `nil` literals, `guard`, `switch`, dictionaries.
- An evaluation **step budget** (100k) guards the main thread against
  `while true {}`.

[SwiftSyntax]: https://github.com/swiftlang/swift-syntax
[bitrig-1]: https://bitrig.com/blog/swift-interpreter
[bitrig-2]: https://bitrig.com/blog/interpreter-expressions
[swiftscript]: https://github.com/Cocoanetics/SwiftScript
