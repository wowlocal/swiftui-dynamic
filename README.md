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
Three built-in samples (toolbar picker): **Counter** (`@State` + Button
actions), **Layout** (stacks, modifiers, `ForEach` chips), **List** (nested
user-defined views).

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

## Supported subset (v1)

Literals (incl. string interpolation), arrays + subscripts, operators with real
precedence, `if`/`else`, `for`-in over ranges/arrays, `while`, functions
(defaults, implicit return, trailing closures), closures (incl. `$0`
shorthand, capture-by-reference), structs with stored/computed properties and
methods, memberwise init, `@State`.

SwiftUI: `Text`, `VStack`/`HStack`/`ZStack`, `Button`, `Image(systemName:)`,
`Spacer`, `Divider`, `ForEach`; modifiers `padding`, `font`, `bold`, `italic`,
`fontWeight`, `foregroundStyle`/`foregroundColor`, `background`,
`cornerRadius`, `opacity`, `frame`.

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
- Not supported (v1): generics, protocols, enums, custom `init`, optionals
  beyond `nil` literals, `guard`, `switch`, dictionaries, `Binding`
  (`$`-projection) — so no `Toggle`/`Slider` yet.
- An evaluation **step budget** (100k) guards the main thread against
  `while true {}`.

[SwiftSyntax]: https://github.com/swiftlang/swift-syntax
[bitrig-1]: https://bitrig.com/blog/swift-interpreter
[bitrig-2]: https://bitrig.com/blog/interpreter-expressions
[swiftscript]: https://github.com/Cocoanetics/SwiftScript
