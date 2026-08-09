import Charts
import SwiftUI

struct SpectrumInspector: View {
    @Bindable var store: PerihelionStore

    var body: some View {
        ObservatoryPanel {
            VStack(alignment: .leading, spacing: 16) {
                identity
                tags
                spectrum
                metrics
                controls
            }
        }
    }

    private var identity: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                SectionEyebrow(
                    text: store.selectedWorld.classification.rawValue,
                    color: PerihelionPalette.worldColor(store.selectedWorld)
                )
                Text(store.selectedWorld.name)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(store.selectedWorld.system)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ZStack {
                Circle()
                    .fill(PerihelionPalette.worldColor(store.selectedWorld).opacity(0.11))
                    .frame(width: 52, height: 52)
                Image(systemName: store.selectedWorld.classification.symbol)
                    .font(.title2)
                    .foregroundStyle(PerihelionPalette.worldColor(store.selectedWorld))
            }
        }
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.selectedWorld.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(store.selectedWorld.tags, id: \.self) { tag in
                        TagChip(
                            title: tag,
                            accent: PerihelionPalette.worldColor(store.selectedWorld)
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var spectrum: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionEyebrow(
                    text: "Transmission spectrum",
                    color: PerihelionPalette.bandColor(store.selectedBand)
                )
                Spacer()
                Text("\(Int(store.cursorWavelength())) nm cursor")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Chart {
                ForEach(store.selectedWorld.spectrum) { point in
                    AreaMark(
                        x: .value("Wavelength", point.wavelength),
                        y: .value("Intensity", store.adjustedIntensity(point))
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                PerihelionPalette.bandColor(store.selectedBand).opacity(0.36),
                                PerihelionPalette.bandColor(store.selectedBand).opacity(0.015),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Wavelength", point.wavelength),
                        y: .value("Intensity", store.adjustedIntensity(point))
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(PerihelionPalette.bandColor(store.selectedBand))
                }

                RuleMark(x: .value("Cursor", store.cursorWavelength()))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(Color.white.opacity(0.42))
            }
            .chartXScale(domain: 390...750)
            .chartYScale(domain: 0...1.2)
            .chartXAxis {
                AxisMarks(values: [400, 500, 600, 700]) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.055))
                    AxisValueLabel {
                        if let wavelength = value.as(Int.self) {
                            Text("\(wavelength)")
                        }
                    }
                    .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis(.hidden)
            .chartPlotStyle { plot in
                plot
                    .background(Color.black.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(height: 160)
        }
    }

    private var metrics: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ],
            spacing: 8
        ) {
            MetricTile(
                title: "Planet radius",
                value: store.selectedWorld.radiusLabel,
                detail: "±0.04",
                symbol: "circle.dotted",
                accent: PerihelionPalette.cyan
            )
            MetricTile(
                title: "Equilibrium",
                value: store.selectedWorld.temperatureLabel,
                detail: "model",
                symbol: "thermometer.medium",
                accent: PerihelionPalette.coral
            )
            MetricTile(
                title: "Orbit period",
                value: store.selectedWorld.periodLabel,
                detail: "sidereal",
                symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                accent: PerihelionPalette.violet
            )
            MetricTile(
                title: "Transit depth",
                value: store.selectedWorld.depthLabel,
                detail: "flux",
                symbol: "waveform.path.ecg.rectangle",
                accent: PerihelionPalette.mint
            )
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker("Spectral band", selection: $store.selectedBand) {
                ForEach(SpectralBand.allCases) { band in
                    Label(band.title, systemImage: band.symbol)
                        .tag(band)
                }
            }
            .pickerStyle(.segmented)

            instrumentSlider(
                title: "Exposure",
                value: $store.exposure,
                symbol: "camera.aperture"
            )
            instrumentSlider(
                title: "Aperture",
                value: $store.aperture,
                symbol: "circle.hexagongrid"
            )
        }
    }

    private func instrumentSlider(
        title: String,
        value: Binding<Double>,
        symbol: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(PerihelionPalette.cyan)
                .frame(width: 18)
            Text(title)
                .font(.caption)
                .frame(width: 58, alignment: .leading)
            Slider(value: value, in: 0.2...1)
                .tint(PerihelionPalette.cyan)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

struct EventTimeline: View {
    let events: [ObservationEvent]

    var body: some View {
        ObservatoryPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionEyebrow(text: "Observation log", color: PerihelionPalette.mint)
                    Spacer()
                    Text("live event stream")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal) {
                    HStack(spacing: 9) {
                        ForEach(events.prefix(5)) { event in
                            HStack(spacing: 9) {
                                Image(systemName: event.symbol)
                                    .foregroundStyle(PerihelionPalette.accent(named: event.accent))
                                    .frame(width: 26, height: 26)
                                    .background(
                                        PerihelionPalette.accent(named: event.accent).opacity(0.1)
                                    )
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Text("\(event.sequence) · \(event.detail)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(10)
                            .frame(width: 242, alignment: .leading)
                            .background(Color.white.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

struct FieldNotesSheet: View {
    @Bindable var store: PerihelionStore

    var body: some View {
        ZStack {
            ObservatoryBackground()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionEyebrow(text: "Logbook entry")
                        Text("Field notes · \(store.selectedWorld.name)")
                            .font(.title2.weight(.semibold))
                    }
                    Spacer()
                    Button {
                        store.showingFieldNotes = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }

                TextEditor(text: $store.fieldNote)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.white.opacity(0.055))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )

                HStack {
                    Text("Saved notes become events in the observation log.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save note") {
                        store.saveFieldNote()
                    }
                    .buttonStyle(PrimaryActionStyle(accent: PerihelionPalette.cyan))
                }
            }
            .padding(26)
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}
