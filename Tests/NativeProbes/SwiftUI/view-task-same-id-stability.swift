import SwiftUI

@MainActor
var swiftUIViewTaskSameIDEvents: [String] = []

@MainActor
var swiftUIViewTaskSameIDRelease = false

struct SwiftUIViewTaskSameIDProbe: View {
    let id: Int
    let generation: String

    var body: some View {
        Text("view-task-same-id-\(generation)")
            .task(id: id) {
                swiftUIViewTaskSameIDEvents.append("start:\(generation)")
                do {
                    while !swiftUIViewTaskSameIDRelease {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    swiftUIViewTaskSameIDEvents.append("finish:\(generation)")
                } catch is CancellationError {
                    swiftUIViewTaskSameIDEvents.append("cancel:\(generation)")
                } catch {
                    swiftUIViewTaskSameIDEvents.append("error:\(generation)")
                }
            }
            .onChange(of: generation, initial: true) {
                swiftUIViewTaskSameIDEvents.append("render:\(generation)")
            }
    }
}
