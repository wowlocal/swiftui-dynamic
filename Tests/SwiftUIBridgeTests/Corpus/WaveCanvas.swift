struct ContentView: View {
    @State private var amplify: CGFloat = 24
    var body: some View {
        VStack {
            Canvas { context, size in
                let offset = 0.4 * size.width
                context.translateBy(x: offset, y: 0)
                context.fill(wave(size: size), with: .color(.blue))
                context.translateBy(x: -size.width, y: 0)
                context.stroke(wave(size: size), with: .color(.cyan), lineWidth: 2)
            }
            .frame(height: 180)
            Slider(value: $amplify, in: 8...60)
            Text("amplitude \(amplify)")
                .font(.caption)
        }
        .padding()
    }

    func wave(size: CGSize) -> Path {
        Path { path in
            let midHeight = size.height / 2
            path.move(to: CGPoint(x: 0, y: midHeight))
            path.addCurve(
                to: CGPoint(x: size.width, y: midHeight),
                control1: CGPoint(x: size.width * 0.4, y: midHeight + amplify),
                control2: CGPoint(x: size.width * 0.65, y: midHeight - amplify)
            )
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
        }
    }
}
