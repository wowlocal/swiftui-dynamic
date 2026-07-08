struct ContentView: View {
    @State var count = 0
    @State var spinning = false

    var milestone: Bool {
        count != 0 && count % 5 == 0
    }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(milestone ? .orange.opacity(0.25) : .blue.opacity(0.15))
                    .frame(width: 140, height: 140)
                Text("\(count)")
                    .font(.system(size: 48, weight: .bold))
                    .monospaced()
                    .rotationEffect(.degrees(spinning ? 360.0 : 0.0))
                    .scaleEffect(milestone ? 1.3 : 1.0)
                    .animation(.spring, value: count)
            }

            HStack(spacing: 12) {
                Button("−1") {
                    withAnimation(.easeInOut) {
                        count -= 1
                    }
                }
                Button("+1") {
                    withAnimation(.easeInOut) {
                        count += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Spin") {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        spinning.toggle()
                    }
                }
            }

            if milestone {
                Label("Milestone!", systemImage: "star.fill")
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
        .padding(32)
    }
}
