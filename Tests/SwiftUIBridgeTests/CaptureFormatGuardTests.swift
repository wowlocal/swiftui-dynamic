import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Distilled repro for the 2026-08-05 capture-format class.
///
/// `Scripts/icecubes-r2.sh` scored the IceCubes twin against the interpreted
/// harness while the two processes wrote DIFFERENT image encodings: the twin
/// Display P3 at 16 bits per component, IceCubesCheck sRGB at 8. Both run the
/// same capture code — `UIGraphicsImageRendererFormat()`, scale 1, opaque
/// false, `drawHierarchy`, `pngData()` — but `preferredRange` defaults to
/// `.automatic`, which resolves from the PROCESS's ambient display
/// association, and the two harnesses ship different Info.plists.
///
/// The board could not see it. Each side captured perfectly reproducibly
/// against ITSELF, which is all the R2 determinism gate asserts, so the
/// mismatch was invisible to the one check designed to catch capture noise.
/// What it cost: the 8-bit side dithers a flat near-white fill by ±1 per
/// channel where the 16-bit side represents it exactly, and `pixel-ae.swift`
/// counts a ±1 pixel exactly as heavily as a solid mismatch. Measured on the
/// media-browser screen, that was 77,274 AE of pure encoding noise — enough to
/// red a correct fix that had strictly REDUCED real divergence.
///
/// The general mechanism is the guard: a comparator must refuse to score two
/// captures that do not agree on their encoding, exactly as it already refuses
/// a size mismatch. Normalizing instead would be the wrong answer — it would
/// delete the evidence that the remaining pixels agree exactly.
@Suite("Capture format guard")
struct CaptureFormatGuardTests {
    /// Writes a PNG whose pixels are all `value` in the given colour space and
    /// bit depth — the two encodings the two harnesses actually produced.
    private func writePNG(
        to url: URL,
        colorSpace: CFString,
        bitsPerComponent: Int,
        value: Double,
        nudgeFirstPixel: Bool = false
    ) throws {
        let side = 4
        let space = CGColorSpace(name: colorSpace)!
        let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0, space: space,
            bitmapInfo: bitsPerComponent == 16
                ? CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
                : CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(
            red: value, green: value, blue: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        if nudgeFirstPixel {
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Runs the real comparator, so this pins the shipped script rather than a
    /// restatement of it.
    private func runComparator(
        _ a: URL, _ b: URL
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swift",
            Self.packageRoot.appendingPathComponent("Scripts/pixel-ae.swift").path,
            a.path, b.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func inTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capture-format-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    /// RED before the guard: these two files carry the SAME nominal colour and
    /// the comparator happily scored them, attributing the encoding delta to
    /// the interpreter.
    @Test func comparatorRefusesToScoreMismatchedEncodings() throws {
        try inTemporaryDirectory { directory in
            let twin = directory.appendingPathComponent("twin.png")
            let interpreted = directory.appendingPathComponent("interpreted.png")
            // Exactly the pair the board compared: P3/16 against sRGB/8.
            try writePNG(
                to: twin, colorSpace: CGColorSpace.displayP3,
                bitsPerComponent: 16, value: 1.0)
            try writePNG(
                to: interpreted, colorSpace: CGColorSpace.sRGB,
                bitsPerComponent: 8, value: 1.0)

            let result = try runComparator(twin, interpreted)
            #expect(result.status == 2, Comment(rawValue:
                "a format mismatch is a FINDING, not a score: \(result.output)"))
            #expect(result.output.contains("FORMAT-MISMATCH"), Comment(rawValue:
                "the comparator must name the mismatch it refused to score, "
                    + "got: \(result.output)"))
        }
    }

    /// The guard must not fire on the matched case, or every board reds — this
    /// is the half that keeps the fix from being a blunt refusal to measure.
    @Test func comparatorScoresMatchedEncodingsExactly() throws {
        try inTemporaryDirectory { directory in
            let a = directory.appendingPathComponent("a.png")
            let b = directory.appendingPathComponent("b.png")
            try writePNG(
                to: a, colorSpace: CGColorSpace.sRGB,
                bitsPerComponent: 8, value: 1.0)
            try writePNG(
                to: b, colorSpace: CGColorSpace.sRGB,
                bitsPerComponent: 8, value: 1.0)

            let result = try runComparator(a, b)
            #expect(result.status == 0, Comment(rawValue:
                "identical captures in one encoding must score AE 0: "
                    + result.output))
            #expect(result.output.contains("AE 0 of 16"))
        }
    }

    /// And a real difference in a matched encoding must still be scored as a
    /// difference — the guard narrows what is comparable, never what counts.
    @Test func comparatorStillScoresRealDifference() throws {
        try inTemporaryDirectory { directory in
            let a = directory.appendingPathComponent("a.png")
            let b = directory.appendingPathComponent("b.png")
            try writePNG(
                to: a, colorSpace: CGColorSpace.sRGB,
                bitsPerComponent: 8, value: 1.0)
            try writePNG(
                to: b, colorSpace: CGColorSpace.sRGB,
                bitsPerComponent: 8, value: 1.0,
                nudgeFirstPixel: true)

            let result = try runComparator(a, b)
            #expect(result.status == 1, Comment(rawValue:
                "one differing pixel must still exit 1: " + result.output))
            #expect(result.output.contains("AE 1 of 16"))
        }
    }

    /// The capture harnesses on BOTH sides must name their colour range rather
    /// than inherit it from whichever display the process attached to. This is
    /// the source-level half: the guard above catches a mismatch once captures
    /// exist, but only pinning the format keeps the twin's reference stable.
    @Test func bothCaptureHarnessesPinTheirColourRange() throws {
        for (path, description) in [
            ("Sources/IceCubesCheck/IceCubesCheck.swift", "interpreted harness"),
            (
                "Examples/IceCubesNativeTwin/Sources/IceCubesNativeTwin/"
                    + "IceCubesNativeTwin.swift",
                "native twin"
            ),
            (
                "Examples/IceCubesNativeTwin/Sources/IceCubesNativeTwin/"
                    + "ReplayURLProtocol.swift",
                "replay placeholder"
            ),
        ] {
            let source = try String(
                contentsOf: Self.packageRoot.appendingPathComponent(path),
                encoding: .utf8)
            #expect(
                source.contains("format.preferredRange = .standard"),
                Comment(rawValue:
                    "\(description) left its renderer's colour range to "
                        + "resolve from the process's display association; "
                        + "the two sides then encode differently and the "
                        + "board scores the gap as interpreter fidelity"))
        }
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
