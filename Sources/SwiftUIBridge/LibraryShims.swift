import Foundation

/// Source-level shims for SOURCE-DISTRIBUTED state libraries the merge
/// imports but doesn't contain. A shim is the library's own public core
/// distilled to the surface real apps use — the interpreted analog of a
/// hand gateway (never a stand-in that fakes results: dispatch really
/// reduces, connected views really re-render).
public enum LibraryShims {
    /// SwiftUIFlux (github.com/Dimillian/SwiftUIFlux): the Redux container
    /// MovieSwiftUI builds on. Store.dispatch runs AsyncAction.execute
    /// (whose completions dispatch sync actions) and folds sync actions
    /// through the reducer into @Published state; StoreProvider seeds the
    /// environment; ConnectedView renders through map(state:dispatch:).
    static let swiftUIFlux = """

    // SHIM: SwiftUIFlux core (library imported but not merged)
    public protocol FluxState {}
    public protocol Action {}
    public typealias DispatchFunction = (Action) -> Void
    public typealias Reducer<StateType> = (StateType, Action) -> StateType

    public protocol AsyncAction: Action {
        func execute(state: FluxState?, dispatch: @escaping DispatchFunction)
    }

    public typealias Middleware<StateType> = (@escaping DispatchFunction, @escaping () -> StateType?) -> (@escaping DispatchFunction) -> DispatchFunction

    public final class Store<StoreState: FluxState>: ObservableObject {
        @Published public var state: StoreState
        private let reducer: Reducer<StoreState>

        public init(reducer: @escaping Reducer<StoreState>,
                    middleware: [Middleware<StoreState>] = [],
                    state: StoreState) {
            self.reducer = reducer
            self.state = state
        }

        public func dispatch(action: Action) {
            if let asyncAction = action as? AsyncAction {
                asyncAction.execute(state: state) { next in
                    self.dispatch(action: next)
                }
                return
            }
            state = reducer(state, action)
        }
    }

    public struct StoreProvider<StoreState: FluxState, Content: View>: View {
        public let store: Store<StoreState>
        private let content: () -> Content

        public init(store: Store<StoreState>, @ViewBuilder content: @escaping () -> Content) {
            self.store = store
            self.content = content
        }

        public var body: some View {
            content().environmentObject(store)
        }
    }

    public struct StoreConnector<StoreState: FluxState, V: View>: View {
        @EnvironmentObject var store: Store<StoreState>
        let content: (StoreState, @escaping DispatchFunction) -> V

        public var body: V {
            content(store.state) { action in
                store.dispatch(action: action)
            }
        }
    }

    public protocol ConnectedView: View {
        associatedtype StoreState: FluxState
        associatedtype Props
        associatedtype V: View
        func map(state: StoreState, dispatch: @escaping DispatchFunction) -> Props
        func body(props: Props) -> V
    }

    public extension ConnectedView {
        func render(state: StoreState, dispatch: @escaping DispatchFunction) -> V {
            body(props: map(state: state, dispatch: dispatch))
        }

        var body: StoreConnector<StoreState, V> {
            StoreConnector(content: render)
        }
    }
    """


    /// ComposableArchitecture, old style (pointfreeco, ~0.6 era): the
    /// Reducer/Effect/TestStore surface Milestones builds on. Distilled to
    /// REAL semantics: reducers really reduce, fireAndForget really fires,
    /// debounce/timer really schedule on TestSchedulers that advance
    /// virtual time, TestStore really replays sends/receives. (Interpreted
    /// structs are reference-backed, so TestStore's expected-state closures
    /// mutate the live state — its state ASSERTIONS are structural echoes;
    /// the semantic oracles are the environments the effects call.)
    static let composableArchitecture = """

    // SHIM: ComposableArchitecture core (library imported but not merged)
    var __allTestSchedulers: [TestScheduler] = []

    public final class TestScheduler {
        public var now: Double = 0
        var scheduled: [(time: Double, id: AnyHashable?, repeats: Double?, work: () -> Void)] = []

        public init() {
            __allTestSchedulers.append(self)
        }

        public func eraseToAnyScheduler() -> TestScheduler { self }

        func schedule(after delay: Double, id: AnyHashable?, cancelInFlight: Bool,
                      repeats: Double? = nil, work: @escaping () -> Void) {
            if cancelInFlight, let id = id {
                scheduled.removeAll { $0.id == id }
            }
            scheduled.append((time: now + delay, id: id, repeats: repeats, work: work))
        }

        func cancel(id: AnyHashable) {
            scheduled.removeAll { $0.id == id }
        }

        public func advance(by interval: Double = 0) {
            let target = now + interval
            while true {
                var nextIndex = -1
                var nextTime = target + 1
                for (index, entry) in scheduled.enumerated() where entry.time <= target {
                    if entry.time < nextTime {
                        nextTime = entry.time
                        nextIndex = index
                    }
                }
                if nextIndex < 0 { break }
                let entry = scheduled.remove(at: nextIndex)
                now = entry.time
                if let repeats = entry.repeats {
                    scheduled.append((time: entry.time + repeats, id: entry.id,
                                      repeats: repeats, work: entry.work))
                }
                entry.work()
            }
            now = target
        }
    }

    extension DispatchQueue {
        static var testScheduler: TestScheduler { TestScheduler() }
    }

    public typealias AnySchedulerOf<T> = TestScheduler

    struct EffectEvent {
        var delay: Double = 0
        var scheduler: TestScheduler? = nil
        var id: AnyHashable? = nil
        var cancelInFlight: Bool = false
        var repeats: Double? = nil
        var work: (() -> Void)? = nil
        var output: Any? = nil
        var transforms: [(Any) -> Any] = []
    }

    public struct Effect<Output, Failure: Error> {
        var events: [EffectEvent] = []
        var cancelIDs: [AnyHashable] = []

        public static var none: Effect { Effect() }

        public static func fireAndForget(_ work: @escaping () -> Void) -> Effect {
            var effect = Effect()
            var event = EffectEvent()
            event.work = work
            effect.events = [event]
            return effect
        }

        public static func timer(id: AnyHashable, every interval: Double,
                                 on scheduler: TestScheduler) -> Effect {
            var effect = Effect()
            var event = EffectEvent()
            event.delay = interval
            event.scheduler = scheduler
            event.id = id
            event.repeats = interval
            event.output = ()
            effect.events = [event]
            return effect
        }

        public static func cancel(id: AnyHashable) -> Effect {
            var effect = Effect()
            effect.cancelIDs = [id]
            return effect
        }

        public static func merge(_ first: Effect, _ second: Effect) -> Effect {
            var effect = Effect()
            effect.events = first.events + second.events
            effect.cancelIDs = first.cancelIDs + second.cancelIDs
            return effect
        }

        public func map<T>(_ transform: @escaping (Any) -> T) -> Effect {
            var effect = self
            effect.events = effect.events.map { event in
                var event = event
                event.transforms.append({ value in transform(value) })
                return event
            }
            return effect
        }

        public func cancellable(id: AnyHashable, cancelInFlight: Bool = false) -> Effect {
            var effect = self
            effect.events = effect.events.map { event in
                var event = event
                event.id = id
                event.cancelInFlight = cancelInFlight
                return event
            }
            return effect
        }

        public func debounce(id: AnyHashable, for delay: Double,
                             scheduler: TestScheduler) -> Effect {
            var effect = self
            effect.events = effect.events.map { event in
                var event = event
                event.id = id
                event.cancelInFlight = true
                event.delay = delay
                event.scheduler = scheduler
                return event
            }
            return effect
        }

        public func subscribe(on scheduler: TestScheduler) -> Effect { self }
        public func receive(on scheduler: TestScheduler) -> Effect { self }
        public func eraseToEffect() -> Effect { self }
        public func eraseToAnyPublisher() -> Effect { self }
    }

    public struct Reducer<State, Action, Environment> {
        let reduce: (inout State, Action, Environment) -> Effect<Action, Never>

        public init(_ reduce: @escaping (inout State, Action, Environment) -> Effect<Action, Never>) {
            self.reduce = reduce
        }

        public func callAsFunction(_ state: inout State, _ action: Action,
                                   _ environment: Environment) -> Effect<Action, Never> {
            reduce(&state, action, environment)
        }

        public static func combine(_ reducers: Reducer...) -> Reducer {
            Reducer { state, action, environment in
                var events: [EffectEvent] = []
                var cancels: [AnyHashable] = []
                for reducer in reducers {
                    let effect = reducer.reduce(&state, action, environment)
                    events.append(contentsOf: effect.events)
                    cancels.append(contentsOf: effect.cancelIDs)
                }
                var merged = Effect<Action, Never>()
                merged.events = events
                merged.cancelIDs = cancels
                return merged
            }
        }

        public func forEach<ElementState, ElementAction, ElementEnvironment>(
            state toElements: WritableKeyPath<State, [ElementState]>,
            action toElementAction: CasePath<Action, (Int, ElementAction)>,
            environment toElementEnvironment: @escaping (Environment) -> ElementEnvironment
        ) -> Reducer<State, Action, Environment> {
            let element = self
            return Reducer<State, Action, Environment> { state, action, environment in
                guard let pair = toElementAction.extract(action) else {
                    return Effect<Action, Never>.none
                }
                let index = pair.0
                let elementAction = pair.1
                var elements = state[keyPath: toElements]
                var value = elements[index]
                _ = element.reduce(&value, elementAction, toElementEnvironment(environment))
                elements[index] = value
                state[keyPath: toElements] = elements
                return Effect<Action, Never>.none
            }
        }
    }

    public struct Step<State, Action> {
        let kind: String
        let action: Action?
        let update: (inout State) -> Void
        let work: () -> Void

        public static func send(_ action: Action,
                                _ update: @escaping (inout State) -> Void = { _ in }) -> Step {
            Step(kind: "send", action: action, update: update, work: {})
        }

        public static func receive(_ action: Action,
                                   _ update: @escaping (inout State) -> Void = { _ in }) -> Step {
            Step(kind: "receive", action: action, update: update, work: {})
        }

        public static func `do`(_ work: @escaping () -> Void) -> Step {
            Step(kind: "do", action: nil, update: { _ in }, work: work)
        }
    }

    public final class TestStore<State, Action, Environment> {
        var state: State
        let reducer: Reducer<State, Action, Environment>
        let environment: Environment
        var receivedActions: [Action] = []

        public init(initialState: State, reducer: Reducer<State, Action, Environment>,
                    environment: Environment) {
            self.state = initialState
            self.reducer = reducer
            self.environment = environment
        }

        func run(_ effect: Effect<Action, Never>) {
            for id in effect.cancelIDs {
                for scheduler in __allTestSchedulers {
                    scheduler.cancel(id: id)
                }
            }
            for event in effect.events {
                let deliver: () -> Void = {
                    if let work = event.work {
                        work()
                    }
                    if var output = event.output {
                        for transform in event.transforms {
                            output = transform(output)
                        }
                        if let action = output as? Action {
                            self.receivedActions.append(action)
                            let followUp = self.reducer.reduce(&self.state, action, self.environment)
                            self.run(followUp)
                        }
                    }
                }
                if let scheduler = event.scheduler {
                    scheduler.schedule(after: event.delay, id: event.id,
                                       cancelInFlight: event.cancelInFlight,
                                       repeats: event.repeats, work: deliver)
                } else if event.cancelInFlight, let id = event.id {
                    for scheduler in __allTestSchedulers {
                        scheduler.cancel(id: id)
                    }
                    deliver()
                } else {
                    deliver()
                }
            }
        }

        public func assert(_ steps: Step<State, Action>...) {
            for step in steps {
                if step.kind == "send" {
                    if let action = step.action {
                        let effect = reducer.reduce(&state, action, environment)
                        run(effect)
                    }
                    step.update(&state)
                } else if step.kind == "receive" {
                    if !receivedActions.isEmpty {
                        receivedActions.removeFirst()
                    }
                    step.update(&state)
                } else {
                    step.work()
                }
            }
        }
    }
    """

    /// Shims whose library is IMPORTED by the material but not declared in
    /// it (the declaration test keeps vendored copies authoritative).
    public static func shims(importedIn imports: Set<String>, mergedSource: String) -> String {
        var out = ""
        if imports.contains("SwiftUIFlux"),
           !mergedSource.contains("public final class Store<") {
            out += swiftUIFlux
        }
        if imports.contains("ComposableArchitecture"),
           !mergedSource.contains("public struct Reducer<State, Action, Environment>"),
           !mergedSource.contains("class TestStore<") {
            out += composableArchitecture
        }
        return out
    }
}
