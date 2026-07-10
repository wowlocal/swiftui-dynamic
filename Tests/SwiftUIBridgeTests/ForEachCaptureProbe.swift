import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct ForEachCaptureProbe {
    @Test func forEachElementSurvivesIntoLifecycleClosure() throws {
        let source = """
        struct AppState: FluxState {
            var fetched: [String] = []
        }
        enum Menu: String, CaseIterable {
            case alpha, beta
            func title() -> String { rawValue }
        }
        struct Home: ConnectedView {
            struct Props {
                let marker: String
            }
            func map(state: AppState, dispatch: @escaping DispatchFunction) -> Props {
                Props(marker: "m")
            }
            @EnvironmentObject var store: Store<AppState>
            private func row(menu: Menu, props: Props) -> some View {
                Text("row " + menu.title())
                    .onAppear {
                        store.dispatch(action: Actions.FetchList(list: menu, page: 1))
                    }
            }
            func body(props: Props) -> some View {
                VStack {
                    Text("direct").onAppear {
                        store.dispatch(action: Actions.FetchList(list: .alpha, page: 1))
                    }
                    List {
                        ForEach(Menu.allCases, id: \\.self) { menu in
                            Group {
                                if menu == .beta {
                                    Text("beta branch")
                                } else {
                                    self.row(menu: menu, props: props)
                                }
                            }
                        }
                    }
                    Text("STATE:" + store.state.fetched.joined(separator: ","))
                }
            }
        }
        struct Actions {
            struct FetchList: AsyncAction {
                let list: Menu
                let page: Int
                func execute(state: FluxState?, dispatch: @escaping DispatchFunction) {
                        dispatch(DidFetch(title: "fired:" + list.title() + "/p\\(page)"))
                }
            }
        }
        struct DidFetch: Action {
            let title: String
        }
        func appReducer(state: AppState, action: Action) -> AppState {
            var state = state
            if let did = action as? DidFetch {
                state.fetched = state.fetched + [did.title]
            }
            return state
        }
        let store = Store<AppState>(reducer: appReducer, state: AppState())
        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup {
                    StoreProvider(store: store) { Home() }
                }
            }
        }
        """
        let deps = "/Users/mike/src/tries/2026-07-08-swiftui-dynamic/External/deps"
        let flux = ProjectMaterial.mergedSource(at: deps + "/SwiftUIFlux/Sources")
        let strings = try LiveCheckSupport.renderedStrings(source: flux + "\n" + source)
        #expect(strings.contains { $0.contains("fired:alpha") },
                "ForEach element lost in lifecycle closure: \(strings)")
    }
}
