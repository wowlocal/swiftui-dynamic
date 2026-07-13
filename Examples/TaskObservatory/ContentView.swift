import SwiftUI

struct ContentView: View {
    @StateObject private var store = TaskObservatoryStore()

    var body: some View {
        VStack(spacing: 18) {
            header

            HStack(spacing: 14) {
                ForEach(store.workers) { worker in
                    WorkerCard(worker: worker)
                }
            }

            HStack(spacing: 14) {
                sharedResultPanel
                eventTimeline
            }

            controls
        }
        .padding(22)
        .frame(width: 980, height: 720)
        .background(Color.primary.opacity(0.025))
    }

    var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 32))
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 3) {
                Text("Task Observatory")
                    .font(.title)
                    .bold()
                Text("Detached workers, suspension, cancellation, and shared task results")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Text("PARALLELISM PROBE")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.purple)
                Text("Watch Main thread vs Worker pool")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.purple.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    var sharedResultPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Shared Task.value", systemImage: "arrow.triangle.branch")
                .font(.headline)

            Text("Comet produces one result. Two independent tasks suspend on the same handle and resume with that value.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ObserverRow(name: "Waiter 1", status: store.observerOne)
            ObserverRow(name: "Waiter 2", status: store.observerTwo)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Label("What to retest", systemImage: "checklist")
                    .font(.subheadline)
                    .bold()
                Text("Worker-pool lanes, overlapping progress, cancellation isolation, and both waiters receiving one result.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
        .frame(width: 310, height: 330)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    var eventTimeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Runtime events", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Text("\(store.events.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 7) {
                    if store.events.isEmpty {
                        ContentUnavailableView(
                            "No task events",
                            systemImage: "waveform.path.ecg",
                            description: Text("Press Run experiment to create a task tree.")
                        )
                        .frame(height: 240)
                    } else {
                        ForEach(store.events) { event in
                            EventRow(event: event)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 330, maxHeight: 330)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    var controls: some View {
        HStack(spacing: 12) {
            Button {
                store.start()
            } label: {
                Label(store.isRunning ? "Restart experiment" : "Run experiment", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button {
                store.cancelBeacon()
            } label: {
                Label("Cancel Beacon", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!store.canCancelWorker)

            Spacer()

            Button("Reset") {
                store.reset()
            }
            .disabled(store.events.isEmpty && !store.isRunning)
        }
    }
}

struct WorkerCard: View {
    let worker: WorkerSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: worker.symbol)
                    .foregroundStyle(worker.color)
                Text(worker.name)
                    .font(.headline)
                Spacer()
                Text(worker.phase)
                    .font(.caption)
                    .bold()
                    .foregroundStyle(phaseColor)
            }

            ProgressView(value: worker.progress)
                .tint(worker.color)

            Text(worker.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Label(worker.lane, systemImage: worker.lane == "Main thread" ? "macwindow" : "square.stack.3d.up")
                .font(.caption)
                .foregroundStyle(worker.lane == "Worker pool" ? .green : .secondary)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 138)
        .background(Color.primary.opacity(0.055))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(worker.color.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    var phaseColor: Color {
        if worker.phase == "Completed" {
            return .green
        }
        if worker.phase == "Cancelled" {
            return .red
        }
        if worker.phase == "Suspended" {
            return .orange
        }
        return worker.color
    }
}

struct ObserverRow: View {
    let name: String
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.hasPrefix("Received") ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(status.hasPrefix("Received") ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .bold()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct EventRow: View {
    let event: TaskEvent

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(event.sequence)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Circle()
                .fill(event.color)
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.worker + " · " + event.message)
                    .font(.caption)
                Text(event.lane)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}
