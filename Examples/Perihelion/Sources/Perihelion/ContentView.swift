import SwiftUI

struct ContentView: View {
    @Environment(PerihelionStore.self) private var store

    var body: some View {
        @Bindable var store = store

        ZStack {
            ObservatoryBackground()

            HStack(spacing: 0) {
                CatalogSidebar(store: store)

                VStack(spacing: 14) {
                    commandBar

                    HStack(alignment: .top, spacing: 14) {
                        OrbitalField(store: store)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        SpectrumInspector(store: store)
                            .frame(width: 370)
                    }

                    EventTimeline(events: store.events)
                        .frame(height: 116)
                }
                .padding(18)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: store.isScanning) {
            if store.isScanning {
                await store.runScan()
            }
        }
        .sheet(isPresented: $store.showingFieldNotes) {
            FieldNotesSheet(store: store)
        }
    }

    private var commandBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                SectionEyebrow(text: "Observation 38 · Night cycle")
                Text("Exoplanet signal workspace")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(PerihelionPalette.mint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SIGNAL QUALITY")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(store.signalQualityLabel)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.045))
            .clipShape(Capsule())

            Button {
                store.showingFieldNotes = true
            } label: {
                Label("Field note", systemImage: "note.text.badge.plus")
            }
            .buttonStyle(.borderless)

            Button {
                store.captureReading()
            } label: {
                Label("Capture", systemImage: "camera.aperture")
            }
            .buttonStyle(.bordered)
            .tint(PerihelionPalette.cyan)

            Button {
                store.toggleScan()
            } label: {
                Label(store.scanButtonTitle, systemImage: store.scanButtonSymbol)
            }
            .buttonStyle(PrimaryActionStyle(accent: PerihelionPalette.amber))
        }
    }
}
