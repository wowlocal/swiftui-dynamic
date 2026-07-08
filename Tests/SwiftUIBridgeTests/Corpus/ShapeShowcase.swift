struct ContentView: View {
    @State var strokeWidth = 3

    @ViewBuilder
    func swatch(title: String) -> some View {
        VStack(spacing: 6) {
            if title == "circle" {
                Circle()
                    .fill(.pink.gradient)
                    .frame(width: 56, height: 56)
                    .shadow(radius: 4, y: 2)
            } else if title == "ring" {
                Circle()
                    .stroke(.purple, lineWidth: Double(strokeWidth))
                    .frame(width: 56, height: 56)
            } else if title == "capsule" {
                Capsule()
                    .fill(.mint)
                    .frame(width: 72, height: 36)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.orange.opacity(0.7))
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(8))
            }
            Text(title)
                .font(.caption)
        }
    }

    var badge: some View {
        ZStack {
            Circle()
                .fill(.red)
            Text("\(strokeWidth)")
                .font(.caption)
                .bold()
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
        .offset(x: 10, y: -10)
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Shapes")
                .font(.title2)
                .bold()
                .overlay(alignment: .topTrailing) {
                    badge
                }

            HStack(spacing: 16) {
                swatch(title: "circle")
                swatch(title: "ring")
                swatch(title: "capsule")
                swatch(title: "square")
            }

            HStack {
                Text("Stroke: \(strokeWidth)")
                    .font(.caption)
                    .monospaced()
                Slider(value: $strokeWidth, in: 1...10, step: 1)
                    .frame(width: 160)
            }

            Rectangle()
                .fill(LinearGradient(colors: [.purple, .pink, .orange], startPoint: .leading, endPoint: .trailing))
                .frame(height: 8)
                .cornerRadius(4)

            ZStack {
                Color.black.opacity(0.05)
                Color.clear
                Text("color layers")
                    .font(.caption2)
            }
            .frame(height: 36)
            .cornerRadius(6)
        }
        .padding(24)
        .frame(maxWidth: 400)
    }
}
