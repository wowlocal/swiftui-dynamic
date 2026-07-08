struct Sample {
    var label = ""
    var value = 0

    init(label: String, value: Int) {
        self.label = label
        self.value = value
    }
}

struct BarView: View {
    var sample = Sample(label: "", value: 0)
    var scale = 1.0

    var body: some View {
        VStack(spacing: 4) {
            Spacer()
            Capsule()
                .fill(.blue.gradient)
                .frame(width: 24, height: Double(sample.value) * scale)
            Text(sample.label)
                .font(.caption2)
        }
    }
}

struct ContentView: View {
    static let data = [
        Sample(label: "Mon", value: 12),
        Sample(label: "Tue", value: 31),
        Sample(label: "Wed", value: 8),
        Sample(label: "Thu", value: 22),
        Sample(label: "Fri", value: 27),
    ]

    var values: [Int] {
        ContentView.data.map { $0.value }
    }

    var total: Int {
        values.reduce(0) { $0 + $1 }
    }

    var peak: Int {
        values.max() ?? 1
    }

    var average: Int {
        total / values.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Weekly activity")
                .font(.title2)
                .bold()

            HStack(spacing: 20) {
                statBox(title: "Total", value: total)
                statBox(title: "Peak", value: peak)
                statBox(title: "Average", value: average)
            }

            HStack(alignment: .bottom, spacing: 12) {
                ForEach(ContentView.data, id: \.label) { sample in
                    BarView(sample: sample, scale: 120.0 / Double(peak))
                }
            }
            .frame(height: 150)

            Text("Best day beat the average by \(peak - average).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: 380)
    }

    func statBox(title: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3)
                .bold()
                .monospaced()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.blue.opacity(0.1))
        .cornerRadius(8)
    }
}
