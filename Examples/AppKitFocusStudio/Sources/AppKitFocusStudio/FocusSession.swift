import AppKit
import Foundation

public struct FocusSessionEngine {
    public var selectedPreset: Int
    public var progress: Double
    public var isRunning: Bool
    public var completedSessions: Int

    public init(
        selectedPreset: Int = 0,
        progress: Double = 0.42,
        isRunning: Bool = false,
        completedSessions: Int = 3
    ) {
        self.selectedPreset = selectedPreset
        self.progress = progress
        self.isRunning = isRunning
        self.completedSessions = completedSessions
    }

    public mutating func choosePreset(_ index: Int) {
        selectedPreset = max(0, min(index, 2))
        progress = selectedPreset == 0 ? 0.42 : selectedPreset == 1 ? 0.24 : 0.68
        isRunning = false
    }

    public mutating func toggleRunning() {
        isRunning.toggle()
    }

    public mutating func advance() {
        selectedPreset = (selectedPreset + 1) % 3
        progress = 0.12
        completedSessions += 1
        isRunning = false
        print("[FocusStudio] advanced to preset \(selectedPreset); completed \(completedSessions)")
    }

    public mutating func tick() {
        guard isRunning else { return }
        let durationMinutes = selectedPreset == 0 ? 52 : selectedPreset == 1 ? 45 : 12
        progress = min(1, progress + 1 / Double(durationMinutes * 60))
        if progress >= 1 {
            progress = 1
            isRunning = false
            completedSessions += 1
        }
        print("[FocusStudio] tick \(Int(progress * 100_000))")
    }

    public mutating func reset() {
        progress = 0
        isRunning = false
    }
}

public struct AppKitPalette {
    public let name: String
    public let subtitle: String
    public let symbol: String
    public let durationMinutes: Int
    public let nativeAccent: NSColor
    public let nativeShadow: NSColor
    public let red: Double
    public let green: Double
    public let blue: Double
    public let shadowRed: Double
    public let shadowGreen: Double
    public let shadowBlue: Double
    public let hex: String
    public let alphaPercent: Int

    public init(index: Int) {
        let source: NSColor
        switch index {
        case 1:
            name = "Flow"
            subtitle = "Creative momentum"
            symbol = "waveform.path.ecg"
            durationMinutes = 45
            source = NSColor(calibratedRed: 0.19, green: 0.72, blue: 0.78, alpha: 1)
        case 2:
            name = "Recover"
            subtitle = "Intentional reset"
            symbol = "leaf.fill"
            durationMinutes = 12
            source = NSColor(calibratedRed: 0.96, green: 0.47, blue: 0.31, alpha: 1)
        default:
            name = "Deep focus"
            subtitle = "Quiet, deliberate work"
            symbol = "scope"
            durationMinutes = 52
            source = NSColor(calibratedRed: 0.43, green: 0.38, blue: 0.98, alpha: 1)
        }

        let highlighted = source.blended(withFraction: 0.18, of: .white) ?? source
        let shadowed = source.blended(withFraction: 0.38, of: .black) ?? source
        nativeAccent = highlighted.withAlphaComponent(0.78)
        nativeShadow = shadowed

        red = Double(highlighted.redComponent)
        green = Double(highlighted.greenComponent)
        blue = Double(highlighted.blueComponent)
        shadowRed = Double(shadowed.redComponent)
        shadowGreen = Double(shadowed.greenComponent)
        shadowBlue = Double(shadowed.blueComponent)
        alphaPercent = Int(nativeAccent.alphaComponent * 100)
        hex = Self.hexString(red: red, green: green, blue: blue)
    }

    private static func hexString(red: Double, green: Double, blue: Double) -> String {
        "#" + hexComponent(red) + hexComponent(green) + hexComponent(blue)
    }

    private static func hexComponent(_ component: Double) -> String {
        let value = max(0, min(Int(component * 255), 255))
        return hexDigit(value / 16) + hexDigit(value % 16)
    }

    private static func hexDigit(_ value: Int) -> String {
        switch value {
        case 0: return "0"
        case 1: return "1"
        case 2: return "2"
        case 3: return "3"
        case 4: return "4"
        case 5: return "5"
        case 6: return "6"
        case 7: return "7"
        case 8: return "8"
        case 9: return "9"
        case 10: return "A"
        case 11: return "B"
        case 12: return "C"
        case 13: return "D"
        case 14: return "E"
        default: return "F"
        }
    }
}

public struct AppKitObjectProbe {
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let meterValue: Int
    public let fontName: String
    public let fontSize: Int
    public let labelValue: String

    public init(progress: Double) {
        let canvas = NSView(frame: CGRect(x: 4, y: 8, width: 240, height: 120))
        canvas.frame = CGRect(x: 12, y: 16, width: 420, height: 236)

        let meter = NSProgressIndicator(frame: CGRect(x: 0, y: 0, width: 180, height: 12))
        meter.isIndeterminate = false
        meter.minValue = 0
        meter.maxValue = 100
        meter.doubleValue = progress * 100

        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let label = NSTextField(labelWithString: "AppKit online")
        label.stringValue = label.stringValue.uppercased()

        canvasWidth = Int(canvas.frame.width)
        canvasHeight = Int(canvas.frame.height)
        meterValue = Int(meter.doubleValue)
        fontName = font.fontName
        fontSize = Int(font.pointSize)
        labelValue = label.stringValue
    }
}

public struct AppKitFunctionalReport {
    public let stateTransitions: Bool
    public let paletteMath: Bool
    public let nativeGeometryAndMeter: Bool
    public let nativeTypographyAndText: Bool
    public let nativePasteboard: Bool

    public var passedCount: Int {
        (stateTransitions ? 1 : 0)
            + (paletteMath ? 1 : 0)
            + (nativeGeometryAndMeter ? 1 : 0)
            + (nativeTypographyAndText ? 1 : 0)
            + (nativePasteboard ? 1 : 0)
    }

    public var allPassed: Bool { passedCount == 5 }
}

public enum AppKitFocusChecks {
    public static func run() -> AppKitFunctionalReport {
        var session = FocusSessionEngine()
        session.choosePreset(1)
        session.toggleRunning()
        let choseAndStarted = session.selectedPreset == 1
            && session.isRunning
            && session.progress == 0.24
        session.advance()
        let advanced = session.selectedPreset == 2
            && session.completedSessions == 4
            && session.progress == 0.12
            && !session.isRunning
        var tickingSession = FocusSessionEngine(progress: 0.42, isRunning: true)
        let progressBeforeTick = tickingSession.progress
        tickingSession.tick()
        let timerTicked = tickingSession.progress > progressBeforeTick
            && tickingSession.isRunning

        let palette = AppKitPalette(index: 2)
        let paletteWorked = palette.hex.hasPrefix("#")
            && palette.hex.count == 7
            && palette.alphaPercent == 78
            && palette.red > palette.blue

        let probe = AppKitObjectProbe(progress: 0.64)
        let geometryWorked = probe.canvasWidth == 420
            && probe.canvasHeight == 236
            && probe.meterValue == 64
        let textWorked = probe.fontSize == 15
            && !probe.fontName.isEmpty
            && probe.labelValue == "APPKIT ONLINE"

        let isolatedPasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.dynamic-swiftui.focus-studio.check")
        )
        let pasteboardWorked = AppKitClipboard.copyAndVerify(
            "Focus Studio check",
            on: isolatedPasteboard
        )
        isolatedPasteboard.clearContents()

        print(
            "[FocusStudio] checks state=\(choseAndStarted && advanced && timerTicked)"
                + " palette=\(paletteWorked) geometry=\(geometryWorked)"
                + " text=\(textWorked) pasteboard=\(pasteboardWorked)"
        )

        return AppKitFunctionalReport(
            stateTransitions: choseAndStarted && advanced && timerTicked,
            paletteMath: paletteWorked,
            nativeGeometryAndMeter: geometryWorked,
            nativeTypographyAndText: textWorked,
            nativePasteboard: pasteboardWorked
        )
    }
}

public enum AppKitClipboard {
    @discardableResult
    public static func copyAndVerify(_ text: String) -> Bool {
        copyAndVerify(text, on: .general)
    }

    @discardableResult
    public static func copyAndVerify(_ text: String, on pasteboard: NSPasteboard) -> Bool {
        _ = pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        let readBack = pasteboard.string(forType: .string)
        if !wrote {
            print("[FocusStudio] pasteboard write returned false")
        } else if readBack == nil {
            print("[FocusStudio] pasteboard read returned nil")
        } else if readBack != text {
            print("[FocusStudio] pasteboard read did not match")
        } else {
            print("[FocusStudio] pasteboard round-trip passed")
        }
        return wrote && readBack == text
    }
}
