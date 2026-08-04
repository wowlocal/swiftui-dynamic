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

 WHERE and WHAT KIND are still whole-screen answers, and a screen may hold more
 than one divergence. Then the single BBOX spans their union — a region neither
 of them occupies — and the single CLASS is whichever verdict the worse pixels
 force, so the other divergence is invisible until the first is fixed. COMPONENTS
 splits the differing pixels into spatially separate clusters and gives each its
 own AE, box, magnitude and class, which is what makes two divergences on one
 screen two targets rather than one blob.

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

/// The same pixels at the depth and in the colour space the capture actually
/// carries, used ONLY as evidence about channels — never for the AE, which stays
/// on the 8-bit sRGB path above so this tool and `pixel-ae.swift` can never
/// disagree about the number a floor is compared against.
///
/// The scored captures are 16-bit Display P3. Reading them at 8 bits throws away
/// the byte that says WHICH KIND of divergence they are: the tags-list residue is
/// 16-32 parts in 65535, which quantizes to the same "1 of 255" whatever its
/// per-channel shape, and the media residue's decisive property — equal ink on
/// R, G and B — is not expressible at all once the samples have been requantized
/// through a different colour space.
func loadNativeSamples(_ path: String) -> (data: [UInt16], depth: Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    var data = [UInt16](repeating: 0, count: width * height * 4)
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder16Little.rawValue
    let drawn = data.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 16,
            bytesPerRow: width * 8, space: space, bitmapInfo: bitmapInfo) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }
    return (data, image.bitsPerComponent)
}

/// Per-channel delta shape over the differing pixels, which is the evidence the
/// EDGE/CLASS pair cannot supply on its own.
///
/// Coverage and colour are distinguishable HERE and nowhere else in this tool.
/// A coverage change contributes `dAlpha * (shape - background)` at a pixel, so its
/// per-channel deltas inherit the local contrast and are equal across R, G and B
/// only when that contrast happens to be neutral. A shape whose COLOUR changed
/// contributes `alpha * (new - old)`, so a neutral recolour lands equally on all
/// three channels no matter what it is drawn over. Counting the two shapes is
/// therefore the measurement that separates them.
func channelSignature(
    _ a: [UInt16], _ b: [UInt16], differing: [Bool], count: Int
) -> (neutral: Int, skewed: Int, maxAbs: Int) {
    var neutral = 0, skewed = 0, maxAbs = 0
    for pixel in 0..<count where differing[pixel] {
        let offset = pixel * 4
        let dR = Int(b[offset]) - Int(a[offset])
        let dG = Int(b[offset + 1]) - Int(a[offset + 1])
        let dB = Int(b[offset + 2]) - Int(a[offset + 2])
        maxAbs = max(maxAbs, max(abs(dR), max(abs(dG), abs(dB))))
        // Equal on every channel INCLUDING the zeros: a delta of (-32,-32,0) is
        // not a neutral shift, it is a skew that happens to spare one channel.
        if dR == dG, dG == dB, dR != 0 { neutral += 1 } else { skewed += 1 }
    }
    return (neutral, skewed, maxAbs)
}

/// A pixel counts as an edge pixel when the TWIN's own 3x3 neighbourhood is not
/// uniform there. Judging that from the native baseline alone keeps the
/// classification independent of what the interpreter drew.
func twinIsEdge(_ a: [UInt8], _ x: Int, _ y: Int, width: Int, height: Int) -> Bool {
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

/// The verdict itself, shared by the whole-screen CLASS line and the per-component
/// ones so the two can never drift to different thresholds.
func classVerdict(flatDiffering: Int, maxDelta: Int) -> String {
    if flatDiffering == 0 && maxDelta <= 8 { return "EDGE-BLEND" }
    if flatDiffering == 0 { return "EDGE-GEOMETRY" }
    return "REGION"
}

/// The MAGNITUDE/EDGE/CLASS block, over raw RGBA buffers so the same code that
/// classifies a real capture pair is what `--self-test` exercises.
func classify(
    _ a: [UInt8], _ b: [UInt8], width: Int, height: Int, differing: [Bool],
    differingCount: Int,
    native: (a: [UInt16], b: [UInt16], depth: Int)? = nil
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

    // CHANNELS — the per-channel shape of those deltas, at the depth the capture
    // carries. This is the line that says colour-or-coverage; MAGNITUDE and EDGE
    // between them cannot.
    let samples = native
        ?? (a: a.map(UInt16.init), b: b.map(UInt16.init), depth: 8)
    let signature = channelSignature(
        samples.a, samples.b, differing: differing, count: width * height)
    let fullScale = (1 << samples.depth) - 1
    let neutralShare = Double(signature.neutral) * 100 / Double(differingCount)
    lines.append(String(
        format: "CHANNELS at %d-bit — %d px neutral (dR==dG==dB), %d px channel-skewed;"
            + " max |delta| %d of %d  (%.1f%% neutral)",
        samples.depth, signature.neutral, signature.skewed, signature.maxAbs,
        fullScale, neutralShare))

    // EDGE — how many of the differing pixels sit on the twin's own edges.
    var edgeDiffering = 0
    var edgeTotal = 0
    for y in 0..<height {
        for x in 0..<width {
            guard twinIsEdge(a, x, y, width: width, height: height) else { continue }
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
    switch classVerdict(flatDiffering: flatDiffering, maxDelta: maxDelta) {
    case "EDGE-BLEND":
        // What "no flat pixel differs" licenses is narrower than it reads, and the
        // 2026-08-04 media screen is the proof: its residue was a pure COLOUR
        // difference (systemGray resolved dark against light) that presented here
        // as edge-only for three iterations. A stroke thinner than a pixel, or a
        // fill completely covered by something else, has no fully-covered pixel to
        // land in a flat region — so a recolour of it is edge-only by construction.
        // The verdict therefore states the geometry it established and defers the
        // colour question to CHANNELS instead of answering it by assumption.
        lines.append("CLASS EDGE-BLEND — every differing pixel is an antialiased twin edge and"
            + " no flat region differs, so both sides drew the same shapes in the same"
            + " places. Whether they drew them in the same COLOURS is decided by"
            + " CHANNELS above, not by this line.")
        if signature.neutral == differingCount {
            lines.append("  ^ CHANNELS says every delta is neutral, which coverage cannot"
                + " produce over non-neutral contrast: read this as a COLOUR difference on a"
                + " sub-pixel stroke or a covered fill, and look for a dynamic colour"
                + " resolving differently, before any rasterization theory.")
        } else if signature.skewed == differingCount {
            lines.append("  ^ CHANNELS says every delta is channel-skewed, i.e. it follows the"
                + " local contrast — the signature of a coverage/compositing difference over"
                + " identical colours. An in-process bitmap micro-twin cannot reproduce it;"
                + " compare what the two sides COMPOSITED (surfaces, atlas cells, filters).")
        } else {
            lines.append(String(
                format: "  ^ CHANNELS is mixed (%.1f%% neutral), so more than one divergence is"
                    + " present here; split them with COMPONENTS before theorising about either.",
                neutralShare))
        }
    case "EDGE-GEOMETRY":
        lines.append("CLASS EDGE-GEOMETRY — differences are confined to twin edges but reach"
            + " \(maxDelta) levels, which is a displaced or differently-shaped boundary"
            + " rather than a blend of the same one.")
    default:
        lines.append("CLASS REGION — \(flatDiffering) differing px lie in flat twin regions, so"
            + " content differs (a missing view, a wrong colour, a displaced frame)."
            + " Distill the view covering the BBOX above.")
    }
    return lines
}

/// One spatially separate cluster of differing pixels, with the same numbers the
/// whole-screen block reports — measured over that cluster alone.
struct DivergenceComponent {
    var ae = 0
    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
    var maxDelta = 0
    var deltaSum = 0
    var flatDiffering = 0
    var verdict: String {
        classVerdict(flatDiffering: flatDiffering, maxDelta: maxDelta)
    }
    var meanDelta: Double { ae == 0 ? 0 : Double(deltaSum) / Double(ae) }
}

/// Cluster the differing pixels, joining two of them when they lie within `gap`
/// pixels of each other. Pure 8-connectivity would shatter one divergence into
/// dozens of components wherever its own antialiasing happens to agree for a
/// pixel or two — a hairline rim that matches exactly at four places along its
/// length is still ONE rim, not five. `gap` is what keeps a cluster the size of
/// the thing that drew it, while staying far below the distance between two
/// unrelated features.
func divergenceComponents(
    _ a: [UInt8], _ b: [UInt8], width: Int, height: Int, differing: [Bool], gap: Int
) -> [DivergenceComponent] {
    var label = [Int](repeating: -1, count: width * height)
    var components: [DivergenceComponent] = []
    var queue: [Int] = []
    for seed in 0..<(width * height) where differing[seed] && label[seed] == -1 {
        let index = components.count
        var component = DivergenceComponent()
        label[seed] = index
        queue.removeAll(keepingCapacity: true)
        queue.append(seed)
        var head = 0
        while head < queue.count {
            let pixel = queue[head]; head += 1
            let x = pixel % width, y = pixel / width
            let offset = pixel * 4
            var pixelDelta = 0
            for channel in 0..<4 {
                pixelDelta = max(pixelDelta, abs(Int(a[offset + channel]) - Int(b[offset + channel])))
            }
            component.ae += 1
            component.deltaSum += pixelDelta
            component.maxDelta = max(component.maxDelta, pixelDelta)
            component.minX = min(component.minX, x); component.maxX = max(component.maxX, x)
            component.minY = min(component.minY, y); component.maxY = max(component.maxY, y)
            if !twinIsEdge(a, x, y, width: width, height: height) {
                component.flatDiffering += 1
            }
            for dy in -gap...gap {
                let ny = y + dy
                guard ny >= 0, ny < height else { continue }
                for dx in -gap...gap {
                    let nx = x + dx
                    guard nx >= 0, nx < width else { continue }
                    let neighbour = ny * width + nx
                    guard differing[neighbour], label[neighbour] == -1 else { continue }
                    label[neighbour] = index
                    queue.append(neighbour)
                }
            }
        }
        components.append(component)
    }
    return components.sorted { $0.ae > $1.ae }
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
    // The CLASS line is no longer the last line — EDGE-BLEND is followed by the
    // channel reading that says which kind of edge divergence it is — so the
    // verdict is looked up by prefix rather than by position.
    func verdict(_ lines: [String]) -> String {
        lines.first(where: { $0.hasPrefix("CLASS ") }) ?? "(no CLASS line)"
    }
    func channelNote(_ lines: [String]) -> String {
        lines.first(where: { $0.hasPrefix("  ^ CHANNELS") }) ?? "(no channel note)"
    }
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
    guard regionMask.total == 25, verdict(regionLines).hasPrefix("CLASS REGION") else {
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
    guard verdict(blendLines).hasPrefix("CLASS EDGE-BLEND") else {
        FileHandle.standardError.write(Data(
            "self-test: edge-only divergence misclassified: \(blendLines)\n".utf8))
        exit(2)
    }
    // THE MEDIA CASE, pinned so it cannot be misread a fourth time. Those border
    // pixels moved by the SAME amount on R, G and B — a neutral recolour of a
    // one-pixel stroke, which is what the media screen's 3410 AE turned out to be
    // after three iterations spent looking for a rasterization difference. The
    // geometry verdict is legitimately EDGE-BLEND; what must not happen again is
    // the tool volunteering "in the same colours" on top of it.
    guard channelNote(blendLines).contains("COLOUR difference") else {
        FileHandle.standardError.write(Data(
            ("self-test: neutral recolour of a sub-pixel stroke was not reported as a"
             + " colour difference: \(blendLines)\n").utf8))
        exit(2)
    }
    guard !blendLines.contains(where: { $0.contains("in the same colours") }) else {
        FileHandle.standardError.write(Data(
            ("self-test: EDGE-BLEND still asserts equal colours, which it cannot"
             + " establish: \(blendLines)\n").utf8))
        exit(2)
    }
    // The coverage twin of that case: the same border pixels, nudged by amounts
    // that FOLLOW the local contrast instead of ignoring it. Same geometry, same
    // magnitude, opposite reading — so the two are separated by the channel
    // evidence alone and not by anything MAGNITUDE or EDGE can see.
    var covered = twin
    for pixel in 0..<(width * height) where blendMask.mask[pixel] {
        let offset = pixel * 4
        covered[offset] = 2; covered[offset + 1] = 1; covered[offset + 2] = 0
    }
    let coveredMask = differingMask(twin, covered, count: width * height)
    let coveredLines = classify(
        twin, covered, width: width, height: height,
        differing: coveredMask.mask, differingCount: coveredMask.total)
    guard verdict(coveredLines).hasPrefix("CLASS EDGE-BLEND"),
          channelNote(coveredLines).contains("coverage/compositing") else {
        FileHandle.standardError.write(Data(
            ("self-test: channel-skewed edge divergence was not reported as coverage:"
             + " \(coveredLines)\n").utf8))
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
    guard verdict(displacedLines).hasPrefix("CLASS EDGE-GEOMETRY") else {
        FileHandle.standardError.write(Data(
            "self-test: displaced edge misclassified: \(displacedLines)\n".utf8))
        exit(2)
    }
    // Two divergences on one screen: a flat recolour inside the square, and a
    // one-level nudge along the border of a SECOND, far-away square. The
    // whole-screen verdict can only be REGION — the flat pixels force it — so
    // the edge-blend divergence is invisible until the components split them.
    var twoShapes = twin
    for y in 4..<9 {
        for x in 32..<37 {
            let offset = (y * width + x) * 4
            twoShapes[offset] = 0; twoShapes[offset + 1] = 0; twoShapes[offset + 2] = 0
        }
    }
    var twoDivergences = twoShapes
    for y in 15..<20 {
        for x in 15..<20 {
            let offset = (y * width + x) * 4
            twoDivergences[offset] = 0
            twoDivergences[offset + 1] = 200
            twoDivergences[offset + 2] = 0
        }
    }
    for y in 4..<9 {
        for x in 32..<37 {
            let onBorder = y == 4 || y == 8 || x == 32 || x == 36
            guard onBorder else { continue }
            let offset = (y * width + x) * 4
            twoDivergences[offset] = 1
            twoDivergences[offset + 1] = 1
            twoDivergences[offset + 2] = 1
        }
    }
    let twoMask = differingMask(twoShapes, twoDivergences, count: width * height)
    let whole = classify(
        twoShapes, twoDivergences, width: width, height: height,
        differing: twoMask.mask, differingCount: twoMask.total)
    guard verdict(whole).hasPrefix("CLASS REGION") else {
        FileHandle.standardError.write(Data(
            "self-test: two-divergence screen should read REGION whole-screen: \(whole)\n".utf8))
        exit(2)
    }
    let split = divergenceComponents(
        twoShapes, twoDivergences, width: width, height: height,
        differing: twoMask.mask, gap: 4)
    guard split.count == 2 else {
        FileHandle.standardError.write(Data(
            ("self-test: expected 2 components, got \(split.count)"
                + " \(split.map { ($0.ae, $0.minX, $0.minY) })\n").utf8))
        exit(2)
    }
    // The recolour is 25 px and REGION; the nudged border is 16 px and EDGE-BLEND.
    guard split[0].ae == 25, split[0].verdict == "REGION",
          split[0].minX == 15, split[0].maxX == 19,
          split[1].ae == 16, split[1].verdict == "EDGE-BLEND",
          split[1].minX == 32, split[1].maxX == 36 else {
        FileHandle.standardError.write(Data(
            ("self-test: components misattributed:"
                + " \(split.map { ($0.ae, $0.verdict, $0.minX, $0.maxX, $0.minY, $0.maxY) })\n").utf8))
        exit(2)
    }
    print("@@pixel-diff-map-self-test passed")
    exit(0)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data(
        ("usage: pixel-diff-map.swift twin.png interp.png"
            + " [--bands N] [--gap N] [--components N] [--out diff.png]\n").utf8))
    exit(2)
}
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
    else { return nil }
    return arguments[index + 1]
}
let bandCount = Int(option("--bands") ?? "24") ?? 24
let componentGap = Int(option("--gap") ?? "4") ?? 4
let componentLimit = Int(option("--components") ?? "8") ?? 8
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

    // The native samples are evidence, not the metric: when a capture cannot be
    // re-read at its own depth the AE and every verdict above still stand, and
    // CHANNELS simply reports at 8 bits.
    var nativeSamples: (a: [UInt16], b: [UInt16], depth: Int)?
    if let nativeA = loadNativeSamples(arguments[1]),
       let nativeB = loadNativeSamples(arguments[2]),
       nativeA.data.count == width * height * 4,
       nativeB.data.count == width * height * 4,
       nativeA.depth == nativeB.depth
    {
        nativeSamples = (nativeA.data, nativeB.data, nativeA.depth)
    }
    for line in classify(
        a.data, b.data, width: width, height: height,
        differing: differing, differingCount: differingCount,
        native: nativeSamples
    ) {
        print(line)
    }

    let components = divergenceComponents(
        a.data, b.data, width: width, height: height,
        differing: differing, gap: componentGap)
    print("COMPONENTS \(components.count) cluster(s) at gap \(componentGap)px"
        + " — AE  share  box  magnitude  class")
    for (index, component) in components.prefix(componentLimit).enumerated() {
        let share = Double(component.ae) * 100 / Double(differingCount)
        print(String(
            format: "  #%d  %7d  %5.1f%%  x %d...%d y %d...%d (%dx%d)  max %d mean %.2f  %@",
            index + 1, component.ae, share,
            component.minX, component.maxX, component.minY, component.maxY,
            component.maxX - component.minX + 1, component.maxY - component.minY + 1,
            component.maxDelta, component.meanDelta, component.verdict))
    }
    // Never let a truncated list read as the whole picture.
    if components.count > componentLimit {
        let dropped = components.dropFirst(componentLimit)
        print("  … \(dropped.count) further cluster(s) not shown,"
            + " \(dropped.reduce(0) { $0 + $1.ae }) AE between them"
            + " (raise --components to list them)")
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
