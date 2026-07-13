import SwiftUI

struct ContentView: View {
    @State private var game = CircuitGame()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.teal.opacity(0.16),
                    Color.indigo.opacity(0.1),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 18) {
                header

                HStack(alignment: .top, spacing: 18) {
                    boardPanel
                    controlPanel
                }
            }
            .padding(24)
        }
        .frame(width: 920, height: 680)
        .background(Color.primary.opacity(0.025))
    }

    var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(Color.mint.opacity(0.15))
                    .frame(width: 54, height: 54)

                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 27))
                    .foregroundStyle(.mint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("CIRCUIT GARDEN")
                    .font(.title2)
                    .bold()
                Text("Pulse a node to flip it and its nearest neighbors")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(game.isComplete ? "GARDEN ONLINE" : "SIGNAL INCOMPLETE")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(game.isComplete ? .green : .orange)
                Text(game.patternName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    var boardPanel: some View {
        VStack(spacing: 12) {
            ForEach(0..<4) { row in
                HStack(spacing: 12) {
                    ForEach(0..<4) { column in
                        Button {
                            game.tap(row * 4 + column)
                        } label: {
                            CircuitNode(
                                index: row * 4 + column,
                                isOn: game.cells[row * 4 + column],
                                wasLast: game.lastPulse == row * 4 + column
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 474, height: 474)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 5)
    }

    var controlPanel: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Garden energy", systemImage: "bolt.fill")
                        .font(.headline)
                    Spacer()
                    Text("\(game.litCount) / 16")
                        .font(.headline)
                        .foregroundStyle(.mint)
                }

                ProgressView(value: game.progress)
                    .tint(.mint)

                HStack(spacing: 10) {
                    MetricCard(value: "\(game.moves)", label: "PULSES", color: .orange)
                    MetricCard(value: "\(game.patternIndex + 1)", label: "PATTERN", color: .purple)
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 17))

            VStack(spacing: 10) {
                Button {
                    game.tap(5)
                } label: {
                    Label("Center pulse", systemImage: "dot.scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)

                Button {
                    game.nextPattern()
                } label: {
                    Label("Next pattern", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    game.reset()
                } label: {
                    Label("Reset garden", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(game.moves == 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("How it works", systemImage: "lightbulb")
                    .font(.subheadline)
                    .bold()
                Text("Each pulse flips one node plus the nodes directly above, below, left, and right. Try to light the entire garden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 474, maxHeight: 474)
    }
}

struct CircuitNode: View {
    let index: Int
    let isOn: Bool
    let wasLast: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: isOn
                            ? [Color.mint.opacity(0.85), Color.teal.opacity(0.7)]
                            : [Color.primary.opacity(0.055), Color.primary.opacity(0.025)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    wasLast ? Color.orange : Color.primary.opacity(isOn ? 0.05 : 0.1),
                    lineWidth: wasLast ? 3 : 1
                )

            VStack(spacing: 8) {
                Image(systemName: isOn ? "bolt.fill" : "circle.dotted")
                    .font(.system(size: 24))
                    .foregroundStyle(isOn ? Color.white : Color.secondary)

                Text("\(index + 1)")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(isOn ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .frame(width: 96, height: 96)
        .shadow(color: isOn ? Color.mint.opacity(0.22) : Color.clear, radius: 8, y: 3)
    }
}

struct MetricCard: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title2)
                .bold()
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
