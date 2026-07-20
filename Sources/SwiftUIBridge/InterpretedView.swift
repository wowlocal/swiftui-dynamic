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

/// `@Environment(\.self)` — the whole EnvironmentValues as one value; member
/// reads serve the same table the keyed wrappers use.
public struct EnvironmentValuesStub {
    public let values: [String: RuntimeValue]

    public init(values: [String: RuntimeValue]) {
        self.values = values
    }
}

/// `@Environment(\.key)` values for interpreted views. Headless harnesses use
/// these defaults; InterpretedView overrides with real environment reads.
public enum InterpretedEnvironment {
    public static func defaults(
        platformName: String? = nil
    ) -> [String: RuntimeValue] {
        let effectivePlatform = platformName
            ?? Interpreter.interpretsAsPlatform
        var values: [String: RuntimeValue] = [
            "colorScheme": .implicitMember("light"),
            "dismiss": .hostFunction(HostFunction(name: "dismiss") { _, _ in .void }),
            // SwiftData/CoreData contexts — fresh-in-memory-store stubs
            // everywhere (real hosting included): persistence is a platform
            // side-channel.
            "modelContext": .native(ModelContextStub()),
            "managedObjectContext": .native(ModelContextStub()),
            // Scene-management actions — our hosting has no scene shell, so
            // these accept their arguments and do nothing (what real SwiftUI
            // does without a matching WindowGroup, minus the console warning).
            "openWindow": .hostFunction(HostFunction(name: "openWindow") { _, _ in .void }),
            "dismissWindow": .hostFunction(HostFunction(name: "dismissWindow") { _, _ in .void }),
            "openURL": .hostFunction(HostFunction(name: "openURL") { _, _ in .void }),
            // The canvas matches the interpreted platform: iPhone-portrait
            // (compact/regular) for the corpus, regular/regular for macOS
            // targets (the FoodTruck twin).
            "horizontalSizeClass": .implicitMember(
                effectivePlatform == "macOS" ? "regular" : "compact"),
            "verticalSizeClass": .implicitMember("regular"),
            "dynamicTypeSize": .implicitMember("large"),
            "scenePhase": .implicitMember("active"),
        ]
        values["self"] = .native(EnvironmentValuesStub(values: values))
        return values
    }
}

/// Body-evaluation errors render inline (the view keeps working), but tests
/// and tools need to observe them — hosted rendering is otherwise silent.
public enum RenderDiagnostics {
    public private(set) static var errors: [(view: String, error: RuntimeError)] = []

    /// Process-level diagnostic selectors are immutable after launch. Cache
    /// this once instead of rebuilding and bridging the full environment from
    /// host-member and layout hot paths.
    static let traceEnabled = ProcessInfo.processInfo.environment["FTCHECK_TRACE"] != nil

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
    /// Bumped on every body evaluation — the self-healing resend proves a
    /// sync objectWillChange actually re-rendered before skipping the
    /// deferred one (split islands drop synchronous sends; i70/i71).
    var renderTick: UInt64 = 0
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

    /// A view with @Query/@FetchRequest storage re-renders when the live
    /// model store mutates — the store's changeSignal is the model
    /// changeSignal pattern, and the send is the same self-healing shape.
    func wireQuerySubscription(of instance: Instance, interpreter: Interpreter) {
        guard instance.symbol.storedProperties.contains(where: { $0.wrapper == .query })
        else { return }
        LiveModelStore.for(interpreter).changeSignal.subscribe(ObjectIdentifier(self)) { [weak self] in
            guard let store = self else { return }
            let tick = store.renderTick
            store.objectWillChange.send()
            DispatchQueue.main.async { [weak store] in
                guard let store, store.renderTick == tick else { return }
                store.objectWillChange.send()
            }
        }
    }

    /// Any @StateObject/@ObservedObject model this view declares re-renders it
    /// when a notifying property mutates. Keyed subscription keeps repeated
    /// adoption idempotent.
    private func wireModelSubscriptions(of instance: Instance) {
        for property in instance.symbol.storedProperties
        where property.wrapper == .stateObject || property.wrapper == .observedObject
            || property.wrapper == .environmentObject {
            guard case .instance(let model)? = instance.box(for: property.name)?.value else { continue }
            if ProcessInfo.processInfo.environment["INTERP_TRACE_BINDING"] != nil {
                print("TRACE-BINDING subscribe \(instance.symbol.name) store=\(ObjectIdentifier(self))")
            }
            model.changeSignal.subscribe(ObjectIdentifier(self)) { [weak self, viewName = instance.symbol.name] in
                if ProcessInfo.processInfo.environment["INTERP_TRACE_BINDING"] != nil {
                    print("TRACE-BINDING signal -> \(viewName) store=\(self.map { String(describing: ObjectIdentifier($0)) } ?? "DEAD")")
                }
                // Sync send first (headless probes and the HStack hosting
                // re-render on it, and pins encode that contract) — then a
                // SELF-HEALING resend: a synchronous send during AppKit
                // action dispatch inside a NavigationSplitView column's
                // hosting island is DROPPED by SwiftUI (A/B body-eval
                // traces, i70/i71). If this store's render tick has not
                // advanced by the next runloop turn, the send is re-issued;
                // when the sync send worked, the tick advanced and no
                // second render happens.
                guard let store = self else { return }
                let tick = store.renderTick
                store.objectWillChange.send()
                DispatchQueue.main.async { [weak store] in
                    guard let store, store.renderTick == tick else { return }
                    store.objectWillChange.send()
                }
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
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @SwiftUI.Environment(\.dismiss) private var dismiss

    public init(instance: Instance, interpreter: Interpreter) {
        self.instance = instance
        self.interpreter = interpreter
    }

    /// Probe surface: total InterpretedView body evaluations this process
    /// (idle-flat / advances-on-signal causality in re-render pins).
    public static var bodyEvaluationCount = 0

    public var body: some View {
        store.renderTick &+= 1
        Self.bodyEvaluationCount += 1
        if ProcessInfo.processInfo.environment["INTERP_TRACE_BINDING"] != nil {
            print("TRACE-BINDING body-eval \(instance.symbol.name)")
        }
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
        var environmentValues = InterpretedEnvironment.defaults(
            platformName: interpreter.buildConfiguration.platformName)
        environmentValues["colorScheme"] = .implicitMember(colorScheme == .dark ? "dark" : "light")
        let dismissAction = dismiss
        environmentValues["dismiss"] = .hostFunction(HostFunction(name: "dismiss") { _, _ in
            dismissAction()
            return .void
        })
        environmentValues["self"] = .native(EnvironmentValuesStub(values: environmentValues))
        interpreter.injectEnvironmentValues(into: instance, values: environmentValues)
        LiveModelStore.refreshQueries(into: instance, interpreter: interpreter)
        store.adopt(into: instance)
        store.wireQuerySubscription(of: instance, interpreter: interpreter)
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
