struct Wedge: Shape {
    var depth: CGFloat = 30

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY),
                control: CGPoint(x: rect.midX, y: rect.midY + depth)
            )
            path.closeSubpath()
        }
    }
}

struct ContentView: View {
    @State private var deep = false

    var body: some View {
        VStack(spacing: 14) {
            Wedge().fill(.blue)
                .frame(height: 100)
            Wedge(depth: deep ? 70 : 30)
                .stroke(.red, lineWidth: 2)
                .frame(height: 100)
            Circle()
                .trim(from: 0, to: 0.5)
                .stroke(.green, lineWidth: 3)
                .frame(width: 70, height: 70)
            Button(deep ? "Flatten" : "Deepen") {
                deep.toggle()
            }
        }
        .padding()
    }
}
