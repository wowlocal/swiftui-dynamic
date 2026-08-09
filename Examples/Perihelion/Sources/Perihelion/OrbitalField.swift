import SwiftUI

struct OrbitalField: View {
    @Bindable var store: PerihelionStore

    var body: some View {
        ObservatoryPanel {
            VStack(alignment: .leading, spacing: 14) {
                header

                GeometryReader { geometry in
                    ZStack {
                        starDust(in: geometry.size)

                        OrbitalGrid()
                            .stroke(
                                PerihelionPalette.cyan.opacity(0.13),
                                style: StrokeStyle(
                                    lineWidth: 0.7,
                                    dash: [2, 7]
                                )
                            )

                        ForEach(store.worlds) { world in
                            orbit(for: world, in: geometry.size)
                            worldButton(for: world, in: geometry.size)
                        }

                        scanBeam(in: geometry.size)
                        centralStar
                    }
                    .clipShape(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.nudgeOrbit()
                    }
                }
                .frame(minHeight: 330)

                footer
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                SectionEyebrow(text: "Live orbital solution")
                Text("Meridian Array · Field 07")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Click a world to retarget · click the field to advance the ephemeris")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(store.isScanning ? PerihelionPalette.mint : PerihelionPalette.amber)
                    .frame(width: 7, height: 7)
                    .shadow(
                        color: (store.isScanning
                            ? PerihelionPalette.mint
                            : PerihelionPalette.amber).opacity(0.7),
                        radius: 6
                    )
                Text(store.isScanning ? "TRACKING" : "STANDBY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.055))
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func starDust(in size: CGSize) -> some View {
        ForEach(0..<52, id: \.self) { index in
            let x = size.width * CGFloat((index * 47 + 13) % 101) / 100
            let y = size.height * CGFloat((index * 29 + 7) % 97) / 96
            let diameter = CGFloat(1 + (index % 3)) * 0.72

            Circle()
                .fill(Color.white.opacity(0.12 + Double(index % 5) * 0.075))
                .frame(width: diameter, height: diameter)
                .position(x: x, y: y)
        }
    }

    private func orbit(for world: CandidateWorld, in size: CGSize) -> some View {
        let diameter = min(size.width, size.height) * world.orbitScale
        let color = PerihelionPalette.worldColor(world)

        return Ellipse()
            .stroke(
                color.opacity(store.selectedWorldID == world.id ? 0.34 : 0.12),
                style: StrokeStyle(
                    lineWidth: store.selectedWorldID == world.id ? 1.4 : 0.7,
                    dash: store.selectedWorldID == world.id ? [] : [3, 6]
                )
            )
            .frame(width: diameter, height: diameter * 0.62)
    }

    private func worldButton(
        for world: CandidateWorld,
        in size: CGSize
    ) -> some View {
        let position = worldPosition(world, in: size)
        let selected = store.selectedWorldID == world.id

        return Button {
            store.select(world)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if selected {
                        Circle()
                            .stroke(PerihelionPalette.worldColor(world).opacity(0.55), lineWidth: 1)
                            .frame(width: 38, height: 38)
                            .scaleEffect(store.isScanning ? 1.18 : 1)
                    }

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white,
                                    PerihelionPalette.worldColor(world),
                                    PerihelionPalette.worldColor(world).opacity(0.36),
                                ],
                                center: .topLeading,
                                startRadius: 1,
                                endRadius: 15
                            )
                        )
                        .frame(
                            width: selected ? 19 : 14,
                            height: selected ? 19 : 14
                        )
                        .shadow(
                            color: PerihelionPalette.worldColor(world).opacity(0.75),
                            radius: selected ? 11 : 5
                        )
                }

                if selected {
                    Text(world.name)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.74), value: selected)
        }
        .buttonStyle(.plain)
        .position(position)
        .accessibilityLabel("Observe \(world.name)")
    }

    private func scanBeam(in size: CGSize) -> some View {
        let diameter = min(size.width, size.height) * 0.96

        return ScanBeam()
            .fill(
                AngularGradient(
                    colors: [
                        Color.clear,
                        PerihelionPalette.cyan.opacity(store.isScanning ? 0.22 : 0.055),
                        Color.clear,
                    ],
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(54)
                )
            )
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(store.scanProgress * 360 - 28))
            .animation(.linear(duration: 0.14), value: store.scanProgress)
            .allowsHitTesting(false)
    }

    private var centralStar: some View {
        ZStack {
            Circle()
                .fill(PerihelionPalette.amber.opacity(0.07))
                .frame(width: 116, height: 116)
                .blur(radius: 10)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white,
                            PerihelionPalette.amber,
                            PerihelionPalette.coral,
                        ],
                        center: UnitPoint(x: 0.36, y: 0.30),
                        startRadius: 1,
                        endRadius: 31
                    )
                )
                .frame(width: 47, height: 47)
                .shadow(color: PerihelionPalette.amber.opacity(0.72), radius: 22)
            Circle()
                .stroke(Color.white.opacity(0.34), lineWidth: 0.7)
                .frame(width: 60, height: 60)
        }
        .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Label(
                "\(store.worlds.count) candidates",
                systemImage: "circle.hexagongrid.fill"
            )
            Label(
                "\(store.worlds.filter(\.isPinned).count) queued",
                systemImage: "pin.fill"
            )
            Label("0.04° residual", systemImage: "scope")
            Spacer()
            Text("PHASE \(Int(store.orbitalPhase * 360))°")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PerihelionPalette.cyan)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func worldPosition(
        _ world: CandidateWorld,
        in size: CGSize
    ) -> CGPoint {
        let phase = world.orbitPhase + store.orbitalPhase * Double.pi * 2
        let radius = min(size.width, size.height) * world.orbitScale * 0.5
        return CGPoint(
            x: size.width * 0.5 + cos(phase) * radius,
            y: size.height * 0.5 + sin(phase) * radius * 0.62
        )
    }
}

struct OrbitalGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)

        path.move(to: CGPoint(x: rect.minX, y: center.y))
        path.addLine(to: CGPoint(x: rect.maxX, y: center.y))
        path.move(to: CGPoint(x: center.x, y: rect.minY))
        path.addLine(to: CGPoint(x: center.x, y: rect.maxY))

        for fraction in [0.24, 0.48, 0.72, 0.96] {
            let width = min(rect.width, rect.height) * fraction
            path.addEllipse(
                in: CGRect(
                    x: center.x - width * 0.5,
                    y: center.y - width * 0.31,
                    width: width,
                    height: width * 0.62
                )
            )
        }

        return path
    }
}

struct ScanBeam: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(
            center: center,
            radius: min(rect.width, rect.height) * 0.5,
            startAngle: .degrees(0),
            endAngle: .degrees(54),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
