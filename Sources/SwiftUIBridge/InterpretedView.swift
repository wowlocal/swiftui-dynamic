import SwiftUI
import SwiftInterpreter

/// Persists `@State` boxes across instance recreations. `@StateObject` gives
/// the store SwiftUI structural identity: parent re-renders build fresh
/// `Instance`s (mirroring how real SwiftUI recreates view values), and
/// `adopt` swaps the persisted boxes back in so state survives. A re-parse
/// gets a whole new identity via `.id(generation)` at the demo root, which
/// deliberately resets state — the old program's state may not even fit the
/// new program.
final class StateStore: ObservableObject {
    private var boxes: [String: Box] = [:]

    /// Idempotent and cheap — runs on every body evaluation.
    func adopt(into instance: Instance) {
        for name in instance.symbol.statePropertyNames {
            if let persisted = boxes[name] {
                instance.stateBoxes[name] = persisted
            } else if let fresh = instance.stateBoxes[name] {
                boxes[name] = fresh
            }
            boxes[name]?.onChange = { [weak self] in self?.objectWillChange.send() }
        }
    }
}

/// The stub type that makes an interpreted `struct Foo: View` renderable:
/// a real SwiftUI View whose body asks the interpreter to evaluate the
/// interpreted `body` property. The Bitrig trick — protocol requirements
/// implemented by delegating back into the interpreter.
public struct InterpretedView: View {
    let instance: Instance
    let interpreter: Interpreter
    @StateObject private var store = StateStore()

    public init(instance: Instance, interpreter: Interpreter) {
        self.instance = instance
        self.interpreter = interpreter
    }

    public var body: some View {
        store.adopt(into: instance)
        return interpretedBody
    }

    private var interpretedBody: AnyView {
        do {
            return try ViewRegistry.anyView(interpreter.evaluateBody(of: instance))
        } catch let error as RuntimeError {
            return AnyView(errorLabel(error.description))
        } catch {
            return AnyView(errorLabel(String(describing: error)))
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.red)
    }
}
