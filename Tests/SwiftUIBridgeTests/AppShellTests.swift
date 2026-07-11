import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// M4 app-shell parity: HeadlessVerifier renders through the app's OWN
/// declared scene — the App instance's @StateObject properties and its
/// .environmentObject seeding reach the root exactly as at launch.
/// Native baseline: compiled SwiftUI runs the App's init and the seeded
/// object (constructed with the App's arguments) flows into the tree; a
/// synthesized stand-in would take the other branch.
@Suite struct AppShellTests {
    private let source = """
    class Theme: ObservableObject {
        let name: String
        init(name: String) { self.name = name }
    }

    struct ShellRoot: View {
        @EnvironmentObject var theme: Theme

        var body: some View {
            VStack {
                if theme.name == "midnight" {
                    Text("seeded")
                    Text(theme.name)
                }
            }
        }
    }

    @main
    struct DemoApp: App {
        @StateObject var theme = Theme(name: "midnight")

        var body: some Scene {
            WindowGroup {
                ShellRoot().environmentObject(theme)
            }
        }
    }
    """

    @Test func appShellSeedsEnvironmentIntoRoot() throws {
        // Compiled SwiftUI renders the "midnight" branch: VStack + 2 Texts.
        // Without launch-faithful seeding the branch is empty (1 node).
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }
}
