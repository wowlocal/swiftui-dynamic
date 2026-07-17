import SwiftUI

@MainActor
var swiftUIRefreshableEvents: [String] = []

@MainActor
var swiftUIRefreshableRelease = false

struct SwiftUIRefreshableCompletionProbe: View {
    var body: some View {
        RefreshActionTrigger {
            swiftUIRefreshableEvents.append("returned")
        }
        .refreshable {
            swiftUIRefreshableEvents.append("started")
            while !swiftUIRefreshableRelease {
                try? await Task.sleep(for: .milliseconds(10))
            }
            swiftUIRefreshableEvents.append("finished")
        }
    }
}
