import SwiftInterpreter
import SwiftUI
import Testing

@testable import SwiftUIBridge

#if canImport(AppKit)
import AppKit
#endif

/// An SDK initializer whose availability is newer than the generated bridge's
/// deployment floor was DROPPED rather than guarded: `processInit` counted it
/// as "newer-OS (skipped)" and emitted nothing, so 23 SwiftUI constructors —
/// every type introduced after the floor — had no generated entry at all.
///
/// That is not a neutral omission on this board. Interpreted app source takes
/// the same `#available` branches the compiled twin takes, so a screen whose
/// toolbar reads
///
///     if #available(iOS 26.0, *) { ToolbarSpacer(placement: .topBarTrailing) }
///
/// (IceCubes `TimelineView.timelineView`) evaluates the branch, finds no
/// constructor for the newer type, and hands the `ToolbarContent` builder a
/// value that is not `ToolbarContent`. The generated carrier then throws
/// `expected ToolbarContent builder content`, which loses the WHOLE receiver:
/// the app's own timeline screen rendered as one error label.
///
/// The fix states the interface's own availability as a runtime guard, exactly
/// as the modifier tier already does for iOS/Catalyst floors, so the entry
/// exists on hosts that have the type and is absent on hosts that do not.
@Suite(.serialized)
struct GeneratedNewerOSConstructorTests {
    /// The capability, read off the generated table rather than through a
    /// render: `ToolbarSpacer` is an iOS/macOS 26 type whose interface init is
    /// `init(_ sizing: SpacerSizing = .flexible, placement: ToolbarItemPlacement = .automatic)`.
    /// Both parameters are defaulted and mapped, so the ONLY reason it could
    /// be missing is the newer-OS skip.
    @MainActor
    @Test func aNewerOSToolbarTypeIsConstructible() throws {
        let overloads = try #require(
            GeneratedConstructors.table["ToolbarSpacer"],
            "ToolbarSpacer has a generated constructor set")
        let placement = overloads.byArity[1]?.first {
            $0.params.first?.label == "placement"
        }
        #expect(
            placement != nil,
            "ToolbarSpacer(placement:) is reachable by its interface label")
    }

    /// The negative half, so the guard is proven to be a GUARD and not a
    /// blanket emission: a type whose availability the interface does not
    /// state as newer stays exactly as it was, registered unconditionally.
    @MainActor
    @Test func aFloorEraToolbarTypeIsStillConstructible() throws {
        let overloads = try #require(
            GeneratedConstructors.table["ToolbarItem"],
            "ToolbarItem is unaffected by the availability guard")
        #expect(overloads.byArity[2]?.isEmpty == false)
    }

    /// The behavioural half on the render path, in the app's own shape: a
    /// `.toolbar` whose builder holds an availability-guarded newer-OS item
    /// beside an ordinary one. What this pins is the RECEIVER — a builder
    /// element the carrier rejects takes the whole hosted view down with it,
    /// so `Text("receiver")` disappearing is the failure this reproduces.
    @MainActor
    @Test func anAvailabilityGuardedToolbarKeepsItsReceiver() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                NavigationStack {
                    Text("receiver")
                }
                .toolbar {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        ToolbarSpacer(placement: .automatic)
                    }
                    ToolbarItem(placement: .automatic) {
                        Text("ordinary")
                    }
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let view = try InterpreterHost().render(source: source).get()
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        hosting.layoutSubtreeIfNeeded()
#endif
        for (viewName, error) in RenderDiagnostics.errors {
            Issue.record("\(viewName): \(error)")
        }
        #expect(RenderDiagnostics.errors.isEmpty)
    }
}
