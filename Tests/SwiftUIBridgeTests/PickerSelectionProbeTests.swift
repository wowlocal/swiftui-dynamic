import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// The saleshistory live-mutation root cause: the Picker bound through a
// plain string binding, so driving a segment wrote the tag STRING into
// enum-typed state and the app's `switch timeframe` stopped matching
// ("switch was not exhaustive for Timeframe.month"). `.tag(...)` now
// registers its ORIGINAL value and the Picker binds through the shared
// registry-aware selection binding. The full control-to-chart chain is
// exercised LIVE by Scripts/foodtruck-r4.sh's saleshistory-mutate step
// (SwiftUI's segmented coordinator only writes its binding in a running
// app); this pin covers the two mechanisms directly.
@Suite struct PickerSelectionProbeTests {
    @MainActor
    @Test func tagRegistersOriginalValueAndSelectionBindingWritesItBack() throws {
        NavigationSelectionValues.byTag.removeAll()
        let source = """
        enum Timeframe: String, CaseIterable {
            case week
            case month
        }

        @main
        struct P: App {
            @State private var timeframe: Timeframe = .week
            var body: some Scene {
                WindowGroup {
                    Picker(String("Timeframe"), selection: $timeframe) {
                        Text(String("Week")).tag(Timeframe.week)
                        Text(String("Month")).tag(Timeframe.month)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success = rendered else {
            Issue.record("render failed")
            return
        }
        // 1. The tags registered their ORIGINAL enum-case values.
        print("PROBE registry keys:", NavigationSelectionValues.byTag.keys.sorted())
        guard let registered = NavigationSelectionValues.byTag["Timeframe.month"] else {
            Issue.record("tag did not register 'month'")
            return
        }
        guard case .enumCase = registered else {
            Issue.record("registry holds \(registered.stringified), not the enum case")
            return
        }

        // 2. The selection binding writes the registered value back through
        // the state box — not the tag string.
        let box = Box(NavigationSelectionValues.byTag["Timeframe.week"] ?? .string("Timeframe.week"))
        let binding = try Coerce.selectionBinding(.host(BindingStub(box: box)))
        #expect(binding.wrappedValue == "Timeframe.week")
        binding.wrappedValue = "Timeframe.month"
        guard case .enumCase(let written) = box.value else {
            Issue.record("write-back stored \(box.value.stringified), not the enum case")
            return
        }
        #expect(box.value.stringified.contains("month"))
        _ = written
        print("PROBE picker write-back:", box.value.stringified)
    }
}
