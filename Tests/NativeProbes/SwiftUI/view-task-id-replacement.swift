import SwiftUI

@MainActor
var swiftUIViewTaskIDEvents: [String] = []

struct SwiftUIViewTaskIDProbe: View {
    let id: Int

    var body: some View {
        Text("view-task-id-\(id)")
            .task(id: id) {
                swiftUIViewTaskIDEvents.append("start:\(id)")
                do {
                    try await Task.sleep(for: .seconds(60))
                    swiftUIViewTaskIDEvents.append("finish:\(id)")
                } catch is CancellationError {
                    swiftUIViewTaskIDEvents.append("cancel:\(id)")
                } catch {
                    swiftUIViewTaskIDEvents.append("error:\(id)")
                }
            }
    }
}
