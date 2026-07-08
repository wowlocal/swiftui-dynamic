extension View {
    func contentWidth() -> Double {
        UIScreen.main.bounds.width - 40.0
    }
}

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

    let screenWidth = UIScreen.main.bounds.width

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Geometry (screen \(Int(screenWidth))pt)")
                .font(.headline)

            GeometryReader {
                let size = $0.size
                let frame = $0.frame(in: .global)
                let insetTop = $0.safeAreaInsets.top
                let scrollBounds = $0.bounds(of: .scrollView(axis: .horizontal))
                VStack(alignment: .leading, spacing: 4) {
                    Text("canvas \(Int(size.width))×\(Int(size.height)) inset \(Int(insetTop))")
                        .font(.caption)
                        .monospaced()
                    Text("origin \(Int(frame.minX)),\(Int(frame.minY)) scroll \(Int(scrollBounds?.minX ?? 0))")
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

            Text("usable \(Int(contentWidth()))pt")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 0.0)
        .padding()
        .frame(maxWidth: 340)
    }
}
