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

    /// Shims whose library is IMPORTED by the material but not declared in
    /// it (the declaration test keeps vendored copies authoritative).
    public static func shims(importedIn imports: Set<String>, mergedSource: String) -> String {
        var out = ""
        if imports.contains("SwiftUIFlux"),
           !mergedSource.contains("public final class Store<") {
            out += swiftUIFlux
        }
        return out
    }
}
