/*
 The twin harness entry: renders FoodTruck screens headlessly to PNG at a
 FIXED size. Usage:
   swift run FoodTruckNativeTwin --out /tmp/twin [--panel truck|content|donuts]
 Each capture prints "id<TAB>path<TAB>widthxheight" — FoodTruckCheck's R2
 rungs diff these against the interpreter's renders of the SAME views.
*/
import SwiftUI
import FoodTruckKit
import AppKit
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let outDirectory = argument("--out") ?? "/tmp/foodtruck-twin"
let only = argument("--panel")
try? FileManager.default.createDirectory(atPath: outDirectory, withIntermediateDirectories: true)

let captureSize = CGSize(width: 1000, height: 650)

@MainActor
func capture(_ id: String, _ view: some View) {
    guard only == nil || only == id else { return }
    let renderer = ImageRenderer(content: view.frame(width: captureSize.width, height: captureSize.height))
    renderer.scale = 1
    guard let cgImage = renderer.cgImage else {
        print("\(id)\tRENDER-NIL")
        return
    }
    let path = outDirectory + "/\(id).png"
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("\(id)\tDEST-NIL")
        return
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
    print("\(id)\t\(path)\t\(cgImage.width)x\(cgImage.height)")
}

@MainActor
func runCaptures() {
    // The app's own state objects, exactly as FoodTruckApp seeds them.
    let model = FoodTruckModel()
    let accountStore = AccountStore()

    // Screen inventory (grows toward the full Panel list as rungs open).
    capture("content", ContentView(model: model, accountStore: accountStore))
    capture("truck", TruckView(model: model, navigationSelection: .constant(.truck)))
    capture("donuts", DonutGallery(model: model))
    capture("orders", OrdersView(model: model))
    capture("socialfeed", SocialFeedView())
}

// Top-level main.swift runs on the main thread.
MainActor.assumeIsolated { runCaptures() }
