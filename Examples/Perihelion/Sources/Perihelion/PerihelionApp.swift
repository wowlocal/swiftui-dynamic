import SwiftUI

@main
struct PerihelionApp: App {
    @State private var store = PerihelionStore()

    var body: some Scene {
        WindowGroup("Perihelion") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
    }
}
