import SwiftUI

struct WorkerSnapshot: Identifiable {
    let id: Int
    let name: String
    let symbol: String
    let color: Color
    var phase: String
    var detail: String
    var lane: String
    var progress: Double
}

struct TaskEvent: Identifiable {
    let id = UUID()
    let sequence: Int
    let worker: String
    let message: String
    let lane: String
    let color: Color
}
