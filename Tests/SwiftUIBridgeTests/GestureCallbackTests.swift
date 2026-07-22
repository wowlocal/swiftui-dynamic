import SwiftUI
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The full 2048 input pipeline minus the OS event: an interpreted
/// DragGesture closure (with withTransaction, exactly as the app writes it)
/// fired with a translation-carrying value must run game-logic side effects.
@Suite struct GestureCallbackTests {
    @Test func transactionAcceptsNilOptionalAnimation() throws {
        _ = Transaction(animation: nil)

        let result = try Interpreter(registry: ViewRegistry()).run(source: """
        var completed = false
        withTransaction(Transaction(animation: nil)) {
            completed = true
        }
        completed
        """)

        #expect(result.boolValue == true)
    }

    @Test func onChangedClosureRunsWithTranslationValue() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let result = try interpreter.run(source: """
        final class Model {
            var lastMove = ""
        }

        struct Probe {
            var translation: CGSize
        }

        let model = Model()
        let gesture = DragGesture()
            .onChanged { v in
                let threshold: CGFloat = 44
                withTransaction(Transaction(animation: .spring())) {
                    if v.translation.width > threshold {
                        model.lastMove = "right"
                    } else if v.translation.width < -threshold {
                        model.lastMove = "left"
                    }
                }
            }
        (gesture, Probe(translation: CGSize(width: 100, height: 0)), model)
        """)
        guard let tuple = result.tupleValue,
              case .host(let any) = tuple.values[0], let gesture = any as? GestureBox,
              case .instance(let model) = tuple.values[2] else {
            Issue.record("expected (GestureBox, Probe, Model), got \(result.stringified)")
            return
        }
        #expect(gesture.onChanged.count == 1)
        _ = try interpreter.callClosure(gesture.onChanged[0], arguments: [tuple.values[1]])
        #expect(model.box(for: "lastMove")?.value.stringValue == "right")
    }
}
