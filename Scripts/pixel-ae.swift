/*
 The R2 pixel primitive: absolute-error count between two PNGs.
   swift Scripts/pixel-ae.swift a.png b.png [--fuzz N]
 Prints "AE <count> of <total> (<percent>%)"; exit 0 when AE == 0,
 exit 1 on any difference, exit 2 on usage/size mismatch (a size
 mismatch is a FINDING — both sides must capture at the same point
 size AND backing scale, never resample to hide it).
 --fuzz N tolerates per-channel deltas <= N (0-255); the ratchet may
 START with a fuzz but only ever tightens toward 0.
*/
import Foundation
import CoreGraphics
import ImageIO

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
    FileHandle.standardError.write(Data("usage: pixel-ae.swift a.png b.png [--fuzz N]\n".utf8))
    exit(2)
}
var fuzz: UInt8 = 0
if let index = arguments.firstIndex(of: "--fuzz"), index + 1 < arguments.count {
    fuzz = UInt8(arguments[index + 1]) ?? 0
}
guard let a = loadPixels(arguments[1]), let b = loadPixels(arguments[2]) else {
    FileHandle.standardError.write(Data("cannot read images\n".utf8))
    exit(2)
}
guard a.width == b.width, a.height == b.height else {
    print("SIZE-MISMATCH \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
    exit(2)
}
var differing = 0
let total = a.width * a.height
for pixel in 0..<total {
    let offset = pixel * 4
    for channel in 0..<4 {
        let delta = abs(Int(a.data[offset + channel]) - Int(b.data[offset + channel]))
        if delta > Int(fuzz) { differing += 1; break }
    }
}
let percent = total == 0 ? 0 : Double(differing) * 100 / Double(total)
print(String(format: "AE %d of %d (%.3f%%)", differing, total, percent))
exit(differing == 0 ? 0 : 1)
