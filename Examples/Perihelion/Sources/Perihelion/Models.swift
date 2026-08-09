import Foundation

enum SpectralBand: String, CaseIterable, Identifiable, Sendable {
    case visible
    case infrared
    case ultraviolet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visible: return "Visible"
        case .infrared: return "Infrared"
        case .ultraviolet: return "Ultraviolet"
        }
    }

    var symbol: String {
        switch self {
        case .visible: return "eye"
        case .infrared: return "wave.3.right"
        case .ultraviolet: return "sun.max.trianglebadge.exclamationmark"
        }
    }

    var wavelengthOffset: Double {
        switch self {
        case .visible: return 0
        case .infrared: return 42
        case .ultraviolet: return -34
        }
    }

    var intensityMultiplier: Double {
        switch self {
        case .visible: return 1
        case .infrared: return 0.86
        case .ultraviolet: return 0.68
        }
    }
}

enum WorldClass: String, CaseIterable, Sendable {
    case ocean = "Ocean world"
    case volcanic = "Volcanic"
    case temperate = "Temperate"
    case gasDwarf = "Gas dwarf"
    case iceGiant = "Ice giant"

    var symbol: String {
        switch self {
        case .ocean: return "drop.fill"
        case .volcanic: return "flame.fill"
        case .temperate: return "leaf.fill"
        case .gasDwarf: return "wind"
        case .iceGiant: return "snowflake"
        }
    }
}

struct SpectralPoint: Identifiable, Hashable, Sendable {
    let id: Int
    let wavelength: Double
    let intensity: Double
}

struct CandidateWorld: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let system: String
    let classification: WorldClass
    let distance: Double
    let radius: Double
    let temperature: Int
    let orbitalPeriod: Double
    let confidence: Double
    let transitDepth: Double
    let orbitScale: Double
    let orbitPhase: Double
    let hue: Double
    let summary: String
    let tags: [String]
    let spectrum: [SpectralPoint]
    var isPinned: Bool

    var distanceLabel: String { String(format: "%.1f ly", distance) }
    var radiusLabel: String { String(format: "%.2f R⊕", radius) }
    var periodLabel: String { String(format: "%.1f days", orbitalPeriod) }
    var confidenceLabel: String { "\(Int(confidence * 100))%" }
    var temperatureLabel: String { "\(temperature) K" }
    var depthLabel: String { String(format: "%.3f%%", transitDepth) }
}

struct ObservationEvent: Identifiable, Hashable, Sendable {
    let id: Int
    let sequence: String
    let title: String
    let detail: String
    let symbol: String
    let accent: String
}

extension CandidateWorld {
    static let catalog: [CandidateWorld] = [
        CandidateWorld(
            id: 1,
            name: "Pelagos b",
            system: "HD 40307",
            classification: .ocean,
            distance: 42.1,
            radius: 1.42,
            temperature: 286,
            orbitalPeriod: 47.8,
            confidence: 0.94,
            transitDepth: 0.118,
            orbitScale: 0.36,
            orbitPhase: 0.42,
            hue: 0.53,
            summary: "A deep-water candidate with a persistent cobalt limb and a narrow oxygen-adjacent absorption line.",
            tags: ["H₂O", "stable transit", "priority"],
            spectrum: spectrum(seed: 0.8, peaks: [(438, 0.52), (528, 0.74), (688, 0.42)]),
            isPinned: true
        ),
        CandidateWorld(
            id: 2,
            name: "Cinder 9",
            system: "Kepler-1649",
            classification: .volcanic,
            distance: 301.4,
            radius: 0.91,
            temperature: 612,
            orbitalPeriod: 19.5,
            confidence: 0.88,
            transitDepth: 0.204,
            orbitScale: 0.52,
            orbitPhase: 2.18,
            hue: 0.04,
            summary: "Hot basaltic terrain, fast weathering, and a sulfur-rich exosphere that brightens after each transit.",
            tags: ["SO₂", "tidal lock", "active"],
            spectrum: spectrum(seed: 1.7, peaks: [(410, 0.31), (575, 0.82), (642, 0.68)]),
            isPinned: false
        ),
        CandidateWorld(
            id: 3,
            name: "Viridia c",
            system: "Luyten's Star",
            classification: .temperate,
            distance: 12.2,
            radius: 1.08,
            temperature: 294,
            orbitalPeriod: 31.4,
            confidence: 0.97,
            transitDepth: 0.086,
            orbitScale: 0.68,
            orbitPhase: 4.44,
            hue: 0.39,
            summary: "The nearest high-confidence target: temperate, cloud-banded, and unusually reflective along the dusk terminator.",
            tags: ["nearby", "O₃", "habitable zone"],
            spectrum: spectrum(seed: 2.4, peaks: [(472, 0.41), (548, 0.91), (619, 0.48)]),
            isPinned: true
        ),
        CandidateWorld(
            id: 4,
            name: "Auralis d",
            system: "TOI-700",
            classification: .gasDwarf,
            distance: 101.5,
            radius: 2.26,
            temperature: 341,
            orbitalPeriod: 68.9,
            confidence: 0.81,
            transitDepth: 0.391,
            orbitScale: 0.82,
            orbitPhase: 5.62,
            hue: 0.76,
            summary: "A lavender mini-Neptune with a high haze deck and repeating methane signatures in the evening hemisphere.",
            tags: ["CH₄", "haze", "deep atmosphere"],
            spectrum: spectrum(seed: 3.1, peaks: [(455, 0.66), (602, 0.38), (718, 0.86)]),
            isPinned: false
        ),
        CandidateWorld(
            id: 5,
            name: "Nix Arc",
            system: "Wolf 1061",
            classification: .iceGiant,
            distance: 14.0,
            radius: 3.72,
            temperature: 118,
            orbitalPeriod: 92.6,
            confidence: 0.76,
            transitDepth: 0.614,
            orbitScale: 0.96,
            orbitPhase: 1.36,
            hue: 0.58,
            summary: "A cold cyan giant with a tilted ring candidate and a slow radio pulse synchronized to its upper-atmosphere storms.",
            tags: ["rings?", "radio pulse", "cold"],
            spectrum: spectrum(seed: 4.2, peaks: [(424, 0.74), (493, 0.58), (667, 0.32)]),
            isPinned: false
        ),
    ]

    private static func spectrum(
        seed: Double,
        peaks: [(Double, Double)]
    ) -> [SpectralPoint] {
        (0..<31).map { index in
            let wavelength = 390.0 + Double(index) * 12.0
            var intensity = 0.14
                + sin(Double(index) * 0.61 + seed) * 0.045
                + cos(Double(index) * 0.23 + seed * 1.7) * 0.035

            for peak in peaks {
                let distance = abs(wavelength - peak.0)
                intensity += max(0, peak.1 * (1 - distance / 58))
            }

            return SpectralPoint(
                id: index,
                wavelength: wavelength,
                intensity: max(0.03, min(1, intensity))
            )
        }
    }
}
