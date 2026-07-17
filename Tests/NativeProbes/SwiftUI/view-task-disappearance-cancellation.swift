import SwiftUI

@MainActor
var swiftUIViewTaskCancellationEvents: [String] = []

struct SwiftUIViewTaskCancellationProbe: View {
    var body: some View {
        Text("view-task-cancellation-probe")
            .task {
                swiftUIViewTaskCancellationEvents.append("started")
                do {
                    try await Task.sleep(for: .seconds(60))
                    swiftUIViewTaskCancellationEvents.append("finished")
                } catch is CancellationError {
                    swiftUIViewTaskCancellationEvents.append("cancelled")
                } catch {
                    swiftUIViewTaskCancellationEvents.append("unexpected-error")
                }
            }
    }
}
