import SwiftUI
import SwiftInterpreter

/// Body-evaluation errors render inline (the view keeps working), but tests
/// and tools need to observe them — hosted rendering is otherwise silent.
public enum RenderDiagnostics {
    public private(set) static var errors: [(view: String, error: RuntimeError)] = []

    public static func reset() { errors = [] }

    static func record(_ error: RuntimeError, in view: String) {
        errors.append((view, error))
    }
}

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
        // @State values and @StateObject models persist via their boxes; a
        // fresh instance's just-initialized box is discarded in favor of the
        // persisted one (mirrors @StateObject keeping its first model).
        for name in instance.symbol.persistentPropertyNames {
            if let persisted = boxes[name] {
                instance.stateBoxes[name] = persisted
            } else if let fresh = instance.stateBoxes[name] {
                boxes[name] = fresh
            }
            boxes[name]?.onChange = { [weak self] in self?.objectWillChange.send() }
        }
        wireModelSubscriptions(of: instance)
    }

    /// Any @StateObject/@ObservedObject model this view declares re-renders it
    /// when a notifying property mutates. Keyed subscription keeps repeated
    /// adoption idempotent.
    private func wireModelSubscriptions(of instance: Instance) {
        for property in instance.symbol.storedProperties
        where property.wrapper == .stateObject || property.wrapper == .observedObject {
            guard case .instance(let model)? = instance.box(for: property.name)?.value else { continue }
            model.changeSignal.subscribe(ObjectIdentifier(self)) { [weak self] in
                self?.objectWillChange.send()
            }
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
            RenderDiagnostics.record(error, in: instance.symbol.name)
            return AnyView(errorLabel(error.description))
        } catch {
            RenderDiagnostics.record(RuntimeError(message: String(describing: error)), in: instance.symbol.name)
            return AnyView(errorLabel(String(describing: error)))
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.red)
    }
}
