import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// MARK: - Native twins
//
// Compiled by the real compiler, so what each one draws IS the expectation.
// Every twin is driven from the same starting values the interpreted source
// declares, so a divergence can only be the bridge's.

private struct NativeColorPickerRow: View {
    @State private var tint = Color.black

    var body: some View {
        Form {
            ColorPicker("tint-row", selection: $tint)
        }
        .formStyle(.grouped)
    }
}

/// The app's own shape: the binding is projected through a member of an
/// `@Observable` model held in `@State`, not off a `@State` scalar.
@Observable private final class NativeTintModel {
    var tint = Color.black
}

private struct NativeColorPickerThroughModel: View {
    @State private var model = NativeTintModel()

    var body: some View {
        Form {
            ColorPicker("model-tint-row", selection: $model.tint)
        }
        .formStyle(.grouped)
    }
}

/// A DIFFERENT value type behind a DIFFERENT control, so a fix that only
/// taught the bridge about `Color` cannot pass this file.
///
/// It is the `init(_:selection:)` overload rather than the
/// `displayedComponents:` one on purpose. That sibling is unbridged for an
/// unrelated reason — `DatePickerComponents` is an OptionSet the mapping does
/// not carry, so the overload is absent from the generated surface entirely
/// and was equally absent before this class was fixed. Writing it here would
/// make this twin fail for a reason its name does not describe, which is the
/// conflation the repro doctrine exists to prevent.
private struct NativeDatePickerRow: View {
    @State private var day = Date(timeIntervalSince1970: 1_784_203_200)

    var body: some View {
        Form {
            DatePicker("day-row", selection: $day)
        }
        .formStyle(.grouped)
    }
}

/// Counter-direction pins: the four binding value types that were ALREADY
/// bridged must keep drawing what they drew. Each of those carries a value
/// CONVERSION, which is why they are spelled by hand and must not be folded
/// into the host-carried path.
private struct NativeToggleRow: View {
    @State private var on = true

    var body: some View {
        Form {
            Toggle("toggle-row", isOn: $on)
        }
        .formStyle(.grouped)
    }
}

private struct NativeSliderRow: View {
    @State private var amount = 0.4

    var body: some View {
        Form {
            Slider(value: $amount, in: 0 ... 1)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tests

/// THE CLASS: `Binding<Value>` was bridged for exactly four `Value` types —
/// `Bool`, `String`, `Double` and the Hashable-optional selection carrier —
/// because each of those needs a value CONVERSION and so was spelled by hand.
/// Every other instantiation the SDK declares fell through to BridgeGen's
/// "generic value struct whose arguments are all supplied" branch and was
/// emitted as `nativeSwiftUIValue("Binding<T>")`.
///
/// That tag asks whether the ARGUMENT ALREADY IS the native value. For a
/// `Color` that is answerable; for a `Binding<Color>` it never is, because an
/// interpreted `$model.tint` is a projection onto interpreted storage and can
/// never be a `Binding` SwiftUI itself built. So the parameter was not merely
/// unbridged — it was UNMATCHABLE, and the overload could not be selected no
/// matter what the caller wrote.
///
/// IceCubes surfaced it at `DisplaySettingsView.swift:114`, where
/// `ColorPicker("settings.display.theme.tint", selection: $localValues.tintColor)`
/// reported "no matching initializer for ColorPicker(_:selection:) — argument
/// types or labels don't fit" while the interpreted box held a perfectly good
/// `SwiftUI.Color`. The failure took the WHOLE screen with it: the app's
/// `display-settings` screen rendered nothing but the diagnostic.
///
/// The blocked set is not one control. Across the generated surface it is
/// `Binding<Color>`, `Binding<Date>`, `Binding<Data>`, `Binding<NavigationPath>`,
/// `Binding<ScrollPosition>`, `Binding<TabViewCustomization>`,
/// `Binding<NavigationSplitViewColumn>` and
/// `Binding<NavigationSplitViewVisibility>` — the last two being the very
/// shape IceCubes' own iPad column layout is written in.
@Suite(.serialized)
struct BindingValueTypeMicroTwinTests {
    private static let size = NSSize(width: 420, height: 220)

    @Test func aColorBindingOffStateReachesItsControl() async throws {
        try await Self.expectIdentical(
            source: """
            struct ContentView: View {
                @State private var tint = Color.black

                var body: some View {
                    Form {
                        ColorPicker("tint-row", selection: $tint)
                    }
                    .formStyle(.grouped)
                }
            }
            """,
            native: AnyView(NativeColorPickerRow()),
            label: "color-binding-off-state")
    }

    /// The app's own route: `@State` holding an `@Observable` model, the
    /// binding projected through one of its members.
    @Test func aColorBindingThroughAModelMemberReachesItsControl() async throws {
        try await Self.expectIdentical(
            source: """
            @Observable class TintModel {
                var tint = Color.black
            }

            struct ContentView: View {
                @State private var model = TintModel()

                var body: some View {
                    Form {
                        ColorPicker("model-tint-row", selection: $model.tint)
                    }
                    .formStyle(.grouped)
                }
            }
            """,
            native: AnyView(NativeColorPickerThroughModel()),
            label: "color-binding-through-model")
    }

    /// Generality: a different `Value` behind a different control. A fix that
    /// taught the bridge only about `Color` leaves this one red.
    @Test func aDateBindingReachesItsControl() async throws {
        try await Self.expectIdentical(
            source: """
            struct ContentView: View {
                @State private var day = Date(timeIntervalSince1970: 1784203200)

                var body: some View {
                    Form {
                        DatePicker("day-row", selection: $day)
                    }
                    .formStyle(.grouped)
                }
            }
            """,
            native: AnyView(NativeDatePickerRow()),
            label: "date-binding")
    }

    /// COUNTER-DIRECTION: `Binding<Bool>` keeps its hand-written conversion.
    @Test func aBoolBindingStillReachesItsControl() async throws {
        try await Self.expectIdentical(
            source: """
            struct ContentView: View {
                @State private var on = true

                var body: some View {
                    Form {
                        Toggle("toggle-row", isOn: $on)
                    }
                    .formStyle(.grouped)
                }
            }
            """,
            native: AnyView(NativeToggleRow()),
            label: "bool-binding-unchanged")
    }

    /// COUNTER-DIRECTION: `Binding<Double>` keeps its hand-written conversion,
    /// which is what lets an interpreted `Int` state drive a `Double` slider.
    @Test func aDoubleBindingStillReachesItsControl() async throws {
        try await Self.expectIdentical(
            source: """
            struct ContentView: View {
                @State private var amount = 0.4

                var body: some View {
                    Form {
                        Slider(value: $amount, in: 0 ... 1)
                    }
                    .formStyle(.grouped)
                }
            }
            """,
            native: AnyView(NativeSliderRow()),
            label: "double-binding-unchanged")
    }

    // MARK: - Harness

    @MainActor
    private static func expectIdentical(
        source: String,
        native: AnyView,
        label: String
    ) async throws {
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("\(label): interpreted render failed: \(rendered)")
            return
        }
        let interpreted = bitmap(view, size: size)
        let expected = bitmap(native, size: size)
        let ae = pixelAE(interpreted, expected, size: size)
        // The diagnostics ride along because a refused constructor reads as a
        // pixel divergence with no other trace of why — which is exactly how
        // this class presented on the board.
        let diagnostics = RenderDiagnostics.errors
            .prefix(3)
            .map { String($0.error.message.prefix(110)) }
            .joined(separator: " | ")
        #expect(
            ae == 0,
            Comment(rawValue:
                "\(label): interpreted vs natively-compiled AE \(ae)"
                    + " of \(Int(size.width * size.height));"
                    + " diagnostics: \(diagnostics)"))
    }

    @MainActor
    private static func bitmap(
        _ view: AnyView,
        size: NSSize
    ) -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)!
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private static func pixelAE(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        size: NSSize
    ) -> Int {
        guard let a = lhs.bitmapData, let b = rhs.bitmapData else { return .max }
        var differing = 0
        for y in 0 ..< Int(size.height) {
            for x in 0 ..< Int(size.width) {
                let offsetA = y * lhs.bytesPerRow + x * (lhs.bitsPerPixel / 8)
                let offsetB = y * rhs.bytesPerRow + x * (rhs.bitsPerPixel / 8)
                if a[offsetA] != b[offsetB]
                    || a[offsetA + 1] != b[offsetB + 1]
                    || a[offsetA + 2] != b[offsetB + 2] {
                    differing += 1
                }
            }
        }
        return differing
    }
}
