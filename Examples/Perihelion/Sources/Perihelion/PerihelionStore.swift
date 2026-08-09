import Foundation
import Observation

@MainActor
@Observable
final class PerihelionStore {
    var worlds = CandidateWorld.catalog
    var selectedWorldID = CandidateWorld.catalog[0].id
    var selectedBand: SpectralBand = .visible
    var searchText = ""
    var exposure = 0.64
    var aperture = 0.72
    var orbitalPhase = 0.08
    var scanProgress = 0.0
    var isScanning = false
    var onlyPinned = false
    var showingFieldNotes = false
    var fieldNote = ""
    var observationCount = 38
    var events: [ObservationEvent] = [
        ObservationEvent(
            id: 1,
            sequence: "T−18m",
            title: "Viridia c reacquired",
            detail: "Transit chord aligned within 0.04°",
            symbol: "scope",
            accent: "mint"
        ),
        ObservationEvent(
            id: 2,
            sequence: "T−11m",
            title: "Pelagos b spectrum stabilized",
            detail: "Signal-to-noise rose to 18.6 dB",
            symbol: "waveform.path.ecg",
            accent: "cyan"
        ),
        ObservationEvent(
            id: 3,
            sequence: "T−03m",
            title: "Calibration frame accepted",
            detail: "Visible band · 64% exposure",
            symbol: "checkmark.seal.fill",
            accent: "amber"
        ),
    ]

    private var nextEventID = 4

    var selectedWorld: CandidateWorld {
        worlds.first(where: { $0.id == selectedWorldID }) ?? worlds[0]
    }

    var filteredWorlds: [CandidateWorld] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return worlds.filter { world in
            let matchesPin = !onlyPinned || world.isPinned
            let matchesQuery = query.isEmpty
                || world.name.lowercased().contains(query)
                || world.system.lowercased().contains(query)
                || world.classification.rawValue.lowercased().contains(query)
                || world.tags.contains(where: { $0.lowercased().contains(query) })
            return matchesPin && matchesQuery
        }
        .sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.confidence > rhs.confidence
        }
    }

    var signalQuality: Double {
        let bandPenalty = 1 - abs(selectedBand.intensityMultiplier - 1) * 0.35
        return min(1, selectedWorld.confidence * exposure * 1.34 * bandPenalty)
    }

    var signalQualityLabel: String {
        "\(Int(signalQuality * 100))%"
    }

    var scanButtonTitle: String {
        isScanning ? "Pause scan" : "Begin scan"
    }

    var scanButtonSymbol: String {
        isScanning ? "pause.fill" : "play.fill"
    }

    func select(_ world: CandidateWorld) {
        guard selectedWorldID != world.id else { return }
        selectedWorldID = world.id
        scanProgress = 0
        record(
            title: "Target locked: \(world.name)",
            detail: "\(world.system) · \(world.distanceLabel)",
            symbol: "scope",
            accent: "cyan"
        )
    }

    func togglePinned(_ world: CandidateWorld) {
        guard let index = worlds.firstIndex(where: { $0.id == world.id }) else {
            return
        }
        worlds[index].isPinned.toggle()
        let verb = worlds[index].isPinned ? "Pinned" : "Unpinned"
        record(
            title: "\(verb) \(world.name)",
            detail: "Observation queue updated",
            symbol: worlds[index].isPinned ? "pin.fill" : "pin.slash",
            accent: "violet"
        )
    }

    func toggleScan() {
        isScanning.toggle()
        if isScanning, scanProgress >= 1 { scanProgress = 0 }
        record(
            title: isScanning ? "Spectral scan started" : "Spectral scan paused",
            detail: "\(selectedBand.title) band · \(selectedWorld.name)",
            symbol: scanButtonSymbol,
            accent: isScanning ? "mint" : "amber"
        )
    }

    func runScan() async {
        while isScanning && scanProgress < 1 {
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            guard !Task.isCancelled, isScanning else { return }
            scanProgress = min(1, scanProgress + 0.025)
            orbitalPhase = (orbitalPhase + 0.007).truncatingRemainder(
                dividingBy: 1)
        }

        if scanProgress >= 1 {
            isScanning = false
            observationCount += 1
            record(
                title: "Observation \(observationCount) captured",
                detail: "\(selectedWorld.name) · quality \(signalQualityLabel)",
                symbol: "sparkles",
                accent: "mint"
            )
        }
    }

    func nudgeOrbit() {
        orbitalPhase = (orbitalPhase + 0.08).truncatingRemainder(dividingBy: 1)
        record(
            title: "Ephemeris advanced",
            detail: "Projected orbital positions +08°",
            symbol: "forward.frame.fill",
            accent: "violet"
        )
    }

    func captureReading() {
        observationCount += 1
        scanProgress = 0
        record(
            title: "Quick reading \(observationCount)",
            detail: "\(selectedWorld.name) · \(selectedBand.title) · \(signalQualityLabel)",
            symbol: "camera.aperture",
            accent: "amber"
        )
    }

    func saveFieldNote() {
        let note = fieldNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            record(
                title: "Field note attached",
                detail: note,
                symbol: "note.text",
                accent: "cyan"
            )
        }
        fieldNote = ""
        showingFieldNotes = false
    }

    func adjustedIntensity(_ point: SpectralPoint) -> Double {
        let shifted = point.intensity * selectedBand.intensityMultiplier
        let response = 0.74 + exposure * 0.42 + aperture * 0.16
        return min(1.18, shifted * response)
    }

    func cursorWavelength() -> Double {
        548 + selectedBand.wavelengthOffset
    }

    private func record(
        title: String,
        detail: String,
        symbol: String,
        accent: String
    ) {
        events.insert(
            ObservationEvent(
                id: nextEventID,
                sequence: "NOW",
                title: title,
                detail: detail,
                symbol: symbol,
                accent: accent
            ),
            at: 0
        )
        nextEventID += 1
        if events.count > 8 { events.removeLast() }
    }
}
