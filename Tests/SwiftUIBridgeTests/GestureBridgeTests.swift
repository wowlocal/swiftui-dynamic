import SwiftUI
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// DragGesture chains — 2048's swipe input. The stub accumulates interpreted
/// closures; `.gesture` attaches the real SwiftUI gesture.
@Suite struct GestureBridgeTests {
    @Test func dragChainAccumulatesClosures() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let value = try interpreter.run(source: """
        DragGesture(minimumDistance: 30)
            .onChanged { v in }
            .onEnded { _ in }
            .onChanged { v in }
        """)
        guard case .native(let any) = value, let gesture = any as? GestureBox else {
            Issue.record("expected a GestureBox, got \(value.stringified)")
            return
        }
        #expect(gesture.onChanged.count == 2)
        #expect(gesture.onEnded.count == 1)
    }

    @Test func gestureModifierAttachesToView() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let value = try interpreter.run(source: """
        struct ContentView: View {
            @State private var offset = 0.0

            var drag: some Gesture {
                DragGesture()
                    .onChanged { v in
                        offset = v.translation.width
                    }
                    .onEnded { _ in
                        offset = 0
                    }
            }

            var body: some View {
                Text("board \\(offset)")
                    .gesture(drag, including: .all)
            }
        }
        ContentView()
        """)
        guard case .instance(let instance) = value else {
            Issue.record("expected ContentView instance")
            return
        }
        let rendered = registry.makeRenderable(instance: instance, interpreter: interpreter)
        #expect(registry.isViewValue(rendered))
    }

    @Test func tapGestureAttaches() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let value = try interpreter.run(source: """
        Text("tap me").gesture(TapGesture().onEnded { })
        """)
        #expect(registry.isViewValue(value))
    }
}
