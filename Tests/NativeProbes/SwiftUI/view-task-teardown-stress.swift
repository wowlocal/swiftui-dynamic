import SwiftUI

@MainActor
var swiftUIViewTaskTeardownStarts: [Int] = []

@MainActor
var swiftUIViewTaskTeardownCancellations: [Int] = []

@MainActor
var swiftUIViewTaskTeardownUnexpected: [Int] = []

struct SwiftUIViewTaskTeardownProbe: View {
    let id: Int

    var body: some View {
        Text("view-task-teardown-\(id)")
            .task(id: id) {
                swiftUIViewTaskTeardownStarts.append(id)
                do {
                    // This is a cancellable suspension point, not timing-based
                    // synchronization: the harness removes the view only
                    // after observing the matching start marker.
                    try await Task.sleep(for: .seconds(60))
                    swiftUIViewTaskTeardownUnexpected.append(id)
                } catch is CancellationError {
                    swiftUIViewTaskTeardownCancellations.append(id)
                } catch {
                    swiftUIViewTaskTeardownUnexpected.append(id)
                }
            }
    }
}
