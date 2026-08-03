/*
 Localize an R2 divergence instead of only counting it.
   swift Scripts/pixel-diff-map.swift twin.png interp.png [--bands N] [--out diff.png]

 `Scripts/pixel-ae.swift` answers "how many pixels differ"; a whole-screen count
 cannot say WHICH part of the screen diverged, so every fix aimed at it is aimed
 at the whole screen at once — the coupling LOOP-ICECUBES §1 requires us to
 decompose. This prints the same AE, then the horizontal band profile and the
 differing-pixel bounding box that say where to distill the micro-twin from, and
 optionally writes a diff PNG (differing pixels red over a dimmed twin) to look at.

 WHERE is only half of a decomposition; the other half is WHAT KIND, because the
 two kinds want opposite investigations. A divergence in a FLAT region means the
 two sides drew different content — a missing view, a wrong colour, a displaced
 frame — and distills to a micro-twin of that view. A divergence confined to
 antialiased EDGES, at a magnitude of a level or two, means both sides drew the
 same shapes in the same places in the same colours and merely blended the
 boundary differently — a rasterization or compositing question, which no
 micro-twin comparing rendered bitmaps in-process can even express. Reading the
 second as the first is how a screen gets re-distilled repeatedly with nothing to
 find. MAGNITUDE and EDGE below separate them: a pixel is an edge pixel when the
 TWIN's own 3x3 neighbourhood is non-uniform there, which is a property of the
 native baseline alone and never of the interpreter's output.

 Exit status mirrors pixel-ae.swift: 0 identical, 1 differing, 2 unusable input.
*/
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func loadPixels(_ path: String) -> (data: [UInt8], width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &data, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (data, width, height)
}

/// The MAGNITUDE/EDGE/CLASS block, over raw RGBA buffers so the same code that
/// classifies a real capture pair is what `--self-test` exercises.
func classify(
    _ a: [UInt8], _ b: [UInt8], width: Int, height: Int, differing: [Bool],
    differingCount: Int
) -> [String] {
    var lines: [String] = []
    // MAGNITUDE — how far apart the differing pixels actually are. A boundary
    // blend lands within a level or two; a wrong colour or a missing view does
    // not. Reported over the largest single-channel delta per pixel.
    var maxDelta = 0
    var deltaSum = 0
    var withinTwo = 0
    for pixel in 0..<(width * height) where differing[pixel] {
        let offset = pixel * 4
        var pixelDelta = 0
        for channel in 0..<4 {
            pixelDelta = max(pixelDelta, abs(Int(a[offset + channel]) - Int(b[offset + channel])))
        }
        maxDelta = max(maxDelta, pixelDelta)
        deltaSum += pixelDelta
        if pixelDelta <= 2 { withinTwo += 1 }
    }
    let meanDelta = Double(deltaSum) / Double(differingCount)
    let withinTwoShare = Double(withinTwo) * 100 / Double(differingCount)
    lines.append(String(
        format: "MAGNITUDE max %d  mean %.2f  of 255 — %d px (%.1f%%) differ by <= 2",
        maxDelta, meanDelta, withinTwo, withinTwoShare))

    // EDGE — a pixel counts as an edge pixel when the TWIN's own 3x3
    // neighbourhood is not uniform there. Judging that from the native baseline
    // alone keeps the classification independent of what the interpreter drew.
    func twinIsEdge(_ x: Int, _ y: Int) -> Bool {
        let offset = (y * width + x) * 4
        for dy in -1...1 {
            for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let neighbour = (ny * width + nx) * 4
                for channel in 0..<4 where a[offset + channel] != a[neighbour + channel] {
                    return true
                }
            }
        }
        return false
    }
    var edgeDiffering = 0
    var edgeTotal = 0
    for y in 0..<height {
        for x in 0..<width {
            guard twinIsEdge(x, y) else { continue }
            edgeTotal += 1
            if differing[y * width + x] { edgeDiffering += 1 }
        }
    }
    let flatDiffering = differingCount - edgeDiffering
    let edgeShare = Double(edgeDiffering) * 100 / Double(differingCount)
    lines.append(String(
        format: "EDGE %d of %d differing px (%.1f%%) sit on a twin edge; %d in flat regions"
            + "  [twin has %d edge px]",
        edgeDiffering, differingCount, edgeShare, flatDiffering, edgeTotal))
    // The verdict names the class so the next step is not chosen by eye.
    if flatDiffering == 0 && maxDelta <= 8 {
        lines.append("CLASS EDGE-BLEND — every differing pixel is an antialiased twin edge and"
            + " no flat region differs, so both sides drew the same shapes, in the same"
            + " places, in the same colours. This is a rasterization/compositing"
            + " divergence; an in-process bitmap micro-twin cannot reproduce it.")
    } else if flatDiffering == 0 {
        lines.append("CLASS EDGE-GEOMETRY — differences are confined to twin edges but reach"
            + " \(maxDelta) levels, which is a displaced or differently-shaped boundary"
            + " rather than a blend of the same one.")
    } else {
        lines.append("CLASS REGION — \(flatDiffering) differing px lie in flat twin regions, so"
            + " content differs (a missing view, a wrong colour, a displaced frame)."
            + " Distill the view covering the BBOX above.")
    }
    return lines
}

func differingMask(_ a: [UInt8], _ b: [UInt8], count: Int) -> (mask: [Bool], total: Int) {
    var mask = [Bool](repeating: false, count: count)
    var total = 0
    for pixel in 0..<count {
        let offset = pixel * 4
        for channel in 0..<4 where a[offset + channel] != b[offset + channel] {
            mask[pixel] = true
            total += 1
            break
        }
    }
    return (mask, total)
}

// A classifier whose verdict steers the next investigation must not be able to
// misname a class silently, so the two verdicts are pinned against synthetic
// buffers whose class is known by construction.
if CommandLine.arguments.contains("--self-test") {
    let width = 40, height = 40
    // A flat white field with a hard-edged black square: every interior pixel is
    // flat, every square boundary pixel is an edge.
    var twin = [UInt8](repeating: 255, count: width * height * 4)
    for y in 10..<30 {
        for x in 10..<30 {
            let offset = (y * width + x) * 4
            twin[offset] = 0; twin[offset + 1] = 0; twin[offset + 2] = 0
        }
    }
    // REGION: recolour pixels strictly inside the square, away from its border.
    var region = twin
    for y in 15..<20 {
        for x in 15..<20 {
            let offset = (y * width + x) * 4
            region[offset] = 0; region[offset + 1] = 200; region[offset + 2] = 0
        }
    }
    let regionMask = differingMask(twin, region, count: width * height)
    let regionLines = classify(
        twin, region, width: width, height: height,
        differing: regionMask.mask, differingCount: regionMask.total)
    guard regionMask.total == 25, regionLines.last?.hasPrefix("CLASS REGION") == true else {
        FileHandle.standardError.write(Data(
            "self-test: flat-region divergence misclassified: \(regionLines)\n".utf8))
        exit(2)
    }
    // EDGE-BLEND: nudge only pixels on the square's border, by one level.
    var blend = twin
    for y in 0..<height {
        for x in 0..<width {
            let onBorder = (y == 10 || y == 29) && (10...29).contains(x)
                || (x == 10 || x == 29) && (10...29).contains(y)
            guard onBorder else { continue }
            let offset = (y * width + x) * 4
            blend[offset] = 1; blend[offset + 1] = 1; blend[offset + 2] = 1
        }
    }
    let blendMask = differingMask(twin, blend, count: width * height)
    let blendLines = classify(
        twin, blend, width: width, height: height,
        differing: blendMask.mask, differingCount: blendMask.total)
    guard blendLines.last?.hasPrefix("CLASS EDGE-BLEND") == true else {
        FileHandle.standardError.write(Data(
            "self-test: edge-only divergence misclassified: \(blendLines)\n".utf8))
        exit(2)
    }
    // The same edge pixels, moved far enough that a blend cannot explain them.
    var displaced = twin
    for pixel in 0..<(width * height) where blendMask.mask[pixel] {
        let offset = pixel * 4
        displaced[offset] = 120; displaced[offset + 1] = 120; displaced[offset + 2] = 120
    }
    let displacedMask = differingMask(twin, displaced, count: width * height)
    let displacedLines = classify(
        twin, displaced, width: width, height: height,
        differing: displacedMask.mask, differingCount: displacedMask.total)
    guard displacedLines.last?.hasPrefix("CLASS EDGE-GEOMETRY") == true else {
        FileHandle.standardError.write(Data(
            "self-test: displaced edge misclassified: \(displacedLines)\n".utf8))
        exit(2)
    }
    print("@@pixel-diff-map-self-test passed")
    exit(0)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data(
        "usage: pixel-diff-map.swift twin.png interp.png [--bands N] [--out diff.png]\n".utf8))
    exit(2)
}
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
    else { return nil }
    return arguments[index + 1]
}
let bandCount = Int(option("--bands") ?? "24") ?? 24
guard let a = loadPixels(arguments[1]), let b = loadPixels(arguments[2]) else {
    FileHandle.standardError.write(Data("cannot read images\n".utf8))
    exit(2)
}
guard a.width == b.width, a.height == b.height else {
    print("SIZE-MISMATCH \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
    exit(2)
}

let width = a.width, height = a.height
var differing = [Bool](repeating: false, count: width * height)
var differingCount = 0
for pixel in 0..<(width * height) {
    let offset = pixel * 4
    for channel in 0..<4 where a.data[offset + channel] != b.data[offset + channel] {
        differing[pixel] = true
        differingCount += 1
        break
    }
}

let total = width * height
let percent = total == 0 ? 0 : Double(differingCount) * 100 / Double(total)
print(String(format: "AE %d of %d (%.3f%%)  %dx%d", differingCount, total, percent, width, height))

if differingCount > 0 {
    var minX = width, maxX = -1, minY = height, maxY = -1
    for y in 0..<height {
        for x in 0..<width where differing[y * width + x] {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // Origin is top-left, matching how the screens are read on screen.
    print("BBOX x \(minX)...\(maxX)  y \(minY)...\(maxY)"
        + "  (\(maxX - minX + 1)x\(maxY - minY + 1))")

    for line in classify(
        a.data, b.data, width: width, height: height,
        differing: differing, differingCount: differingCount
    ) {
        print(line)
    }

    let bandHeight = max(1, Int((Double(height) / Double(bandCount)).rounded(.up)))
    print("BANDS \(bandHeight)px each — y-range  AE  share  bar")
    for bandStart in stride(from: 0, to: height, by: bandHeight) {
        let bandEnd = min(height, bandStart + bandHeight)
        var bandAE = 0
        for y in bandStart..<bandEnd {
            for x in 0..<width where differing[y * width + x] { bandAE += 1 }
        }
        guard bandAE > 0 else { continue }
        let share = Double(bandAE) * 100 / Double(differingCount)
        let bar = String(repeating: "#", count: max(1, Int(share / 2)))
        print(String(format: "  %4d-%4d  %7d  %5.1f%%  %@",
                     bandStart, bandEnd - 1, bandAE, share, bar))
    }
}

if let outPath = option("--out") {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for pixel in 0..<(width * height) {
        let offset = pixel * 4
        if differing[pixel] {
            pixels[offset] = 255; pixels[offset + 1] = 0
            pixels[offset + 2] = 0; pixels[offset + 3] = 255
        } else {
            // Dimmed twin, so the divergence reads against its own screen.
            for channel in 0..<3 {
                pixels[offset + channel] = UInt8(Int(a.data[offset + channel]) / 3 + 168)
            }
            pixels[offset + 3] = 255
        }
    }
    guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        FileHandle.standardError.write(Data("cannot write \(outPath)\n".utf8))
        exit(2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("cannot finalize \(outPath)\n".utf8))
        exit(2)
    }
    print("DIFF \(outPath)")
}

exit(differingCount == 0 ? 0 : 1)
