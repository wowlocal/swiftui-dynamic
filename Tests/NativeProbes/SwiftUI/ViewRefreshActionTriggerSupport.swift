import SwiftUI

/// Test-only control that invokes the public RefreshAction installed by
/// `.refreshable`. Keeping the trigger outside the fixture lets the exact same
/// authored view source run through native Swift and the interpreter bridge.
struct RefreshActionTrigger: View {
    @Environment(\.refresh) private var refresh
    let onReturned: @MainActor @Sendable () -> Void

    var body: some View {
        Text("refresh-action-trigger")
            .task {
                if let refresh {
                    await refresh()
                }
                onReturned()
            }
    }
}
