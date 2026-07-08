import SwiftUI
import SwiftInterpreter

/// Interpreted models injected with `.environmentObject(_:)`, carried by
/// SwiftUI's own Environment so scoping/propagation (including into sheets)
/// comes from SwiftUI for free. Only ever touched on the main actor.
struct ModelEnvironment: @unchecked Sendable {
    var models: [String: Instance] = [:]
}

private struct InterpretedModelsKey: EnvironmentKey {
    nonisolated static let defaultValue = ModelEnvironment()
}

extension EnvironmentValues {
    var interpretedModels: ModelEnvironment {
        get { self[InterpretedModelsKey.self] }
        set { self[InterpretedModelsKey.self] = newValue }
    }
}

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
        where property.wrapper == .stateObject || property.wrapper == .observedObject
            || property.wrapper == .environmentObject {
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
    // Qualified: the interpreter core also exports an `Environment` type.
    @SwiftUI.Environment(\.interpretedModels) private var modelEnvironment

    public init(instance: Instance, interpreter: Interpreter) {
        self.instance = instance
        self.interpreter = interpreter
    }

    public var body: some View {
        do {
            try interpreter.injectEnvironmentObjects(into: instance, models: modelEnvironment.models)
        } catch let error as RuntimeError {
            RenderDiagnostics.record(error, in: instance.symbol.name)
            return AnyView(errorLabel(error.description))
        } catch {
            let wrapped = RuntimeError(message: String(describing: error))
            RenderDiagnostics.record(wrapped, in: instance.symbol.name)
            return AnyView(errorLabel(wrapped.description))
        }
        store.adopt(into: instance)
        return interpretedBody
    }

    private var interpretedBody: AnyView {
        do {
            // Presented content (sheets) re-reads the environment through
            // SwiftUI, so nested InterpretedViews resolve their own models.
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
