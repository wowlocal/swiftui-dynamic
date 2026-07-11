/*
 The twin harness entry: renders FoodTruck screens headlessly to PNG at
 FIXED sizes — the ONLY source of pixel expectations for FoodTruckCheck's
 R2 rungs. Usage:
   swift run FoodTruckNativeTwin --out /tmp/twin [--panel id]
 Prints "id<TAB>path<TAB>WxH" per capture.

 Capture mechanism: NSHostingView + cacheDisplay in a borderless aqua
 NSWindow under an NSApplication lifecycle — the exact path that reached
 AE=0 on the ExpenseTracker twin. ImageRenderer is NOT used: it draws
 AppKit-backed containers (NavigationSplitView/ScrollView/List) blank
 headlessly.
*/
import SwiftUI
import AppKit
import FoodTruckKit

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let outDirectory = argument("--out") ?? "/tmp/foodtruck-twin"
let only = argument("--panel")

let screenSize = NSSize(width: 1000, height: 650)
let cardSize = NSSize(width: 400, height: 300)

@MainActor
func capture(_ id: String, size: NSSize, _ view: some View) {
    guard only == nil || only == id else { return }
    let hosting = NSHostingView(rootView: AnyView(view).frame(width: size.width, height: size.height))
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        print("\(id)\tREP-NIL")
        return
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("\(id)\tPNG-NIL")
        return
    }
    let path = outDirectory + "/\(id).png"
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("\(id)\t\(path)\t\(rep.pixelsWide)x\(rep.pixelsHigh)")
    } catch {
        print("\(id)\tWRITE-FAILED \(error)")
    }
}

final class TwinDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(
            atPath: outDirectory, withIntermediateDirectories: true)

        // The app's own state objects, exactly as FoodTruckApp seeds them.
        let model = FoodTruckModel()
        let accountStore = AccountStore()

        // Full screens (grow toward the complete Panel list as rungs open).
        capture("content", size: screenSize, ContentView(model: model, accountStore: accountStore))
        capture("truck", size: screenSize, TruckView(model: model, navigationSelection: .constant(.truck)))
        capture("donuts", size: screenSize, DonutGallery(model: model))
        capture("orders", size: screenSize, OrdersView(model: model))
        capture("socialfeed", size: screenSize, SocialFeedView())

        // Leaf content cards — the pixel currency while container chrome
        // stays headless-hostile on both sides.
        capture("card-donuts", size: cardSize,
                TruckDonutsCard(donuts: Array(model.donuts.prefix(15))).padding(10).background(Color.white))
        capture("card-orders", size: cardSize,
                TruckOrdersCard(model: model).padding(10).background(Color.white))
        capture("donut-view", size: cardSize,
                DonutView(donut: model.donuts[0]).padding(10).background(Color.white))
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = TwinDelegate()
app.delegate = delegate
app.run()
