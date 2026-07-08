struct MeterBar: View {
    var fraction = 0.5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.gray.opacity(0.2))
                Capsule()
                    .fill(.blue.gradient)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 12)
    }
}

struct ContentView: View {
    @State var level = 0.7

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Geometry")
                .font(.headline)

            GeometryReader {
                let size = $0.size
                let frame = $0.frame(in: .global)
                VStack(alignment: .leading, spacing: 4) {
                    Text("canvas \(Int(size.width))×\(Int(size.height))")
                        .font(.caption)
                        .monospaced()
                    Text("origin \(Int(frame.minX)),\(Int(frame.minY))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 44)

            MeterBar(fraction: level)
            Button("More") {
                level = min(1.0, level + 0.1)
            }

            TimelineView(.animation) { timeline in
                Text("tick \(timeline.date)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: 340)
    }
}
