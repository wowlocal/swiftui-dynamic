import SwiftUI

@MainActor
var swiftUIViewTaskEvents: [String] = []

struct SwiftUIViewTaskRuntimeEntryProbe: View {
    var body: some View {
        Text("view-task-probe")
            .task {
                swiftUIViewTaskEvents.append("started")
                let value = await withTaskGroup(of: Int.self) { group in
                    group.addTask { 21 }
                    return await group.next() ?? -1
                }
                swiftUIViewTaskEvents.append("value:\(value)")
            }
    }
}
