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
    // Explicit 1x bitmap (same technique as the interpreter's snapshot
    // path): backing-scale reps paint point coordinates into 2x pixels
    // (black quadrants), and 1x pins determinism across display scales —
    // both sides MUST capture at 1x for pixel-ae.
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: max(1, Int(hosting.bounds.width.rounded(.up))),
        pixelsHigh: max(1, Int(hosting.bounds.height.rounded(.up))),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        print("\(id)\tREP-NIL")
        return
    }
    rep.size = hosting.bounds.size
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
        if ProcessInfo.processInfo.environment["FOODTRUCK_TWIN_DUMP"] != nil {
            let counts = model.orders.prefix(6).map { "\($0.donuts.count)/\($0.grandTotal)" }
            print("TWIN-DUMP orders=\(model.orders.count) firsts=\(counts.joined(separator: ","))")
            // Week sales-stream alignment: day-one vector per city, sorted
            // by donut id, encodes the shuffle + per-day draw sequence.
            for city in City.all {
                if let day = model.dailyOrderSummaries(cityID: city.id).first {
                    let vector = day.sales.sorted { $0.key < $1.key }
                        .map { "\($0.key):\($0.value)" }.joined(separator: ",")
                    print("TWIN-HISTORY \(city.id) day0=\(vector)")
                }
            }
        }

        // Full screens (grow toward the complete Panel list as rungs open).
        capture("content", size: screenSize, ContentView(model: model, accountStore: accountStore))
        capture("truck", size: screenSize, TruckView(model: model, navigationSelection: .constant(.truck)))
        capture("donuts", size: screenSize, DonutGallery(model: model))
        capture("orders", size: screenSize, OrdersView(model: model))
        capture("socialfeed", size: screenSize, SocialFeedView())
        capture("diag-donuteditor", size: screenSize,
                DonutEditor(donut: .constant(model.newDonut)))

        // Leaf content cards — the pixel currency while container chrome
        // stays headless-hostile on both sides.
        capture("card-donuts", size: cardSize,
                TruckDonutsCard(donuts: Array(model.donuts.prefix(15))).padding(10).background(Color.white))
        capture("card-orders", size: cardSize,
                TruckOrdersCard(model: model).padding(10).background(Color.white))
        capture("donut-view", size: cardSize,
                DonutView(donut: model.donuts[0]).padding(10).background(Color.white))
        // The gallery CELL at cell scale — the donuts-row caption-shift
        // class isolates here (DonutView is a GeometryReader; the caption
        // gap depends on its layout reply inside the fixed frame).
        capture("donut-cell", size: NSSize(width: 200, height: 200),
                VStack {
                    DonutView(donut: model.donuts[0])
                        .frame(width: 80, height: 80)
                    VStack {
                        Text(model.donuts[0].name)
                        HStack(spacing: 4) {
                            model.donuts[0].flavors.mostPotentFlavor.image
                            Text(model.donuts[0].flavors.mostPotentFlavor.name)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
                .padding(10).background(Color.white))

        capture("donut-grid", size: NSSize(width: 700, height: 300),
                DonutGalleryGrid(donuts: Array(model.donuts.prefix(4)), width: 700)
                    .background(Color.white))

        capture("donut-foreach", size: NSSize(width: 200, height: 200),
                VStack {
                    ForEach(Array(model.donuts.prefix(1))) { donut in
                        VStack {
                            GeometryReader { proxy in
                                    ZStack {
                                        Circle().fill(Color.gray)
                                    }
                                    .aspectRatio(1, contentMode: .fit)
                                    .compositingGroup()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .frame(width: 80, height: 80)
                            VStack {
                                Text(donut.name)
                                HStack(spacing: 4) {
                                    donut.flavors.mostPotentFlavor.image
                                    Text(donut.flavors.mostPotentFlavor.name)
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(10).background(Color.white))

        capture("donut-mimic", size: NSSize(width: 700, height: 300),
                MimicGrid(donuts: Array(model.donuts.prefix(4)))
                    .background(Color.white))

        // R3 function scenarios (Scripts/foodtruck-r3-spec.md): mutate
        // through the model's OWN public API, then re-capture — the
        // post-mutation captures are the parity expectations. A fresh
        // model per scenario keeps them independent.
        if let scenario = argument("--scenario") {
            runScenarios(scenario == "all"
                ? ["donut-rename", "order-completes", "order-steps",
                   "popularity-moves", "nav-selection"]
                : [scenario])
        }
        exit(0)
    }

    @MainActor
    private func runScenarios(_ names: [String]) {
        for name in names {
            let model = FoodTruckModel()
            switch name {
            case "donut-rename":
                var donut = model.donuts[0]
                donut.name = "Parity Deluxe"
                model.updateDonut(id: donut.id, to: donut)
                capture("donuts-after-rename", size: screenSize, DonutGallery(model: model))
                capture("donut-view-after-rename", size: cardSize,
                        DonutView(donut: model.donut(id: donut.id)).padding(10).background(Color.white))
            case "order-completes":
                if let first = model.orders.first(where: { !$0.isComplete }) {
                    model.markOrderAsCompleted(id: first.id)
                }
                capture("orders-after-complete", size: screenSize, OrdersView(model: model))
            case "order-steps":
                if let first = model.orders.first(where: { !$0.isComplete }) {
                    let binding = model.orderBinding(for: first.id)
                    binding.wrappedValue.markAsPreparing()
                    capture("orders-after-preparing", size: screenSize, OrdersView(model: model))
                    binding.wrappedValue.markAsComplete()
                    capture("orders-after-steps", size: screenSize, OrdersView(model: model))
                }
            case "popularity-moves":
                for order in model.orders where !order.isComplete {
                    model.markOrderAsCompleted(id: order.id)
                }
                capture("donuts-after-popularity", size: screenSize, DonutGallery(model: model))
                capture("card-donuts-after-popularity", size: cardSize,
                        TruckDonutsCard(donuts: Array(model.donuts(sortedBy: .popularity(.month)).prefix(15)))
                            .padding(10).background(Color.white))
            case "nav-selection":
                capture("detail-truck", size: screenSize,
                        DetailColumn(selection: .constant(.truck), model: model))
                capture("detail-orders", size: screenSize,
                        DetailColumn(selection: .constant(.orders), model: model))
                capture("detail-donuts", size: screenSize,
                        DetailColumn(selection: .constant(.donuts), model: model))
            default:
                print("unknown-scenario\t\(name)")
            }
        }
    }
}

let app = NSApplication.shared
let delegate = TwinDelegate()
app.delegate = delegate
app.run()


struct MimicGrid: View {
    var donuts: [Donut]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20, alignment: .top)], spacing: 20) {
            ForEach(donuts) { donut in
                VStack {
                    VStack {
                        GeometryReader { proxy in
                                    ZStack {
                                        Circle().fill(Color.gray)
                                    }
                                    .aspectRatio(1, contentMode: .fit)
                                    .compositingGroup()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            .frame(width: 80, height: 80)
                        VStack {
                                                        Text(donut.name)
                            HStack(spacing: 4) {
                                donut.flavors.mostPotentFlavor.image
                                Text(donut.flavors.mostPotentFlavor.name)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                    }
                }
            }
        }
        .padding()
    }
}
