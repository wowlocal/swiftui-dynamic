/*
 Localize an R2 divergence instead of only counting it.
   swift Scripts/pixel-diff-map.swift twin.png interp.png [--bands N] [--out diff.png]

 `Scripts/pixel-ae.swift` answers "how many pixels differ"; a whole-screen count
 cannot say WHICH part of the screen diverged, so every fix aimed at it is aimed
 at the whole screen at once — the coupling LOOP-ICECUBES §1 requires us to
 decompose. This prints the same AE, then the horizontal band profile and the
 differing-pixel bounding box that say where to distill the micro-twin from, and
 optionally writes a diff PNG (differing pixels red over a dimmed twin) to look at.

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
