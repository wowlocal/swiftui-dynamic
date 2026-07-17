import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct ObservableBindingProbe {
    @MainActor
    @Test func projectedModelPropertyBinding() throws {
        let source = """
        class Model: ObservableObject {
            @Published var name: String = "Alpha"
        }

        struct Editor: View {
            @Binding var name: String
            var body: some View {
                VStack {
                    Text(String("EDITOR:") + name)
                    TextField(String("Name"), text: $name)
                }
            }
        }

        @main
        struct P: App {
            @StateObject private var model = Model()
            var body: some Scene {
                WindowGroup {
                    Editor(name: $model.name)
                        .background(Color.white)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed: \(rendered)")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 300, height: 120))
        var ink = 0
        for x in 0..<300 { for y in 0..<120 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { ink += 1 }
        } }
        print("PROBE observable-binding ink:", ink, "diags:", RenderDiagnostics.errors.count)
        for e in RenderDiagnostics.errors.prefix(5) {
            print("PROBE-DIAG \(e.view): \(e.error.message.prefix(100))")
        }
        #expect(ink > 100)
    }

    @MainActor
    static func bitmap(_ view: AnyView, size: NSSize) -> NSBitmapImageRep {
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
                .background(Color.white))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fatalError("no rep")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    @MainActor
    @Test func hSplitViewRendersBothPanes() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    HSplitView {
                        Text(String("LEFT PANE")).frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(String("RIGHT PANE")).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Color.white)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 300, height: 120))
        var ink = 0
        for x in 0..<300 { for y in 0..<120 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { ink += 1 }
        } }
        print("PROBE hsplit ink:", ink, "diags:", RenderDiagnostics.errors.count)
        for e in RenderDiagnostics.errors.prefix(3) {
            print("PROBE-DIAG \(e.view): \(e.error.message.prefix(100))")
        }
        #expect(ink > 100)
    }

    @MainActor
    @Test func structBindingThroughModelRendersEditor() throws {
        let source = """
        struct Donut {
            var name: String = "Sprinkles"
        }

        class Model: ObservableObject {
            @Published var newDonut = Donut()
        }

        struct Editor: View {
            @Binding var donut: Donut
            var body: some View {
                HSplitView {
                    Text(String("VIEW:") + donut.name)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Form {
                        TextField(String("Name"), text: $donut.name)
                    }
                    .frame(minWidth: 200, maxHeight: .infinity)
                }
            }
        }

        @main
        struct P: App {
            @StateObject private var model = Model()
            var body: some Scene {
                WindowGroup {
                    Editor(donut: $model.newDonut)
                        .background(Color.white)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        // A REAL two-pane split needs pane-viable space (the old 300x120
        // pass was an artifact of the generatedBuilder VStack collapse).
        let rep = Self.bitmap(view, size: NSSize(width: 700, height: 300))
        var ink = 0
        for x in 0..<700 { for y in 0..<300 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { ink += 1 }
        } }
        print("PROBE struct-binding ink:", ink, "diags:", RenderDiagnostics.errors.count)
        for e in RenderDiagnostics.errors.prefix(3) {
            print("PROBE-DIAG \(e.view): \(e.error.message.prefix(100))")
        }
        #expect(ink > 100)
    }

    @MainActor
    @Test func groupedFormInsideSplitRenders() throws {
        for (name, body) in [
            ("form-alone", "Form { Text(String(\"RIGHT\")) }"),
            ("form-grouped", "Form { Text(String(\"RIGHT\")) }.formStyle(.grouped)"),
            ("form-in-split", """
                HSplitView {
                    Text(String("LEFT")).frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                    Form { Text(String("RIGHT")) }
                        .formStyle(.grouped)
                        .padding()
                        .frame(minWidth: 300, idealWidth: 350, maxHeight: .infinity, alignment: .top)
                }
                """),
        ] {
            let source = """
            @main
            struct P: App {
                var body: some Scene {
                    WindowGroup {
                        \(body)
                    }
                }
            }
            """
            RenderDiagnostics.reset()
            let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
            guard case .success(let view) = rendered else {
                Issue.record("render failed for \(name)")
                continue
            }
            let rep = Self.bitmap(view, size: NSSize(width: 500, height: 200))
            var ink = 0
            for x in 0..<500 { for y in 0..<200 {
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.88 { ink += 1 }
            } }
            print("PROBE form-bisect \(name): ink=\(ink) diags=\(RenderDiagnostics.errors.count)")
        }
    }

    @MainActor
    @Test func noArgBackgroundAndLayoutPriorityRender() throws {
        for (name, body) in [
            ("bg-noarg", "Text(String(\"MARK\")).background()"),
            ("layout-priority", "Text(String(\"MARK\")).layoutPriority(1)"),
            ("combined", "Text(String(\"MARK\")).background().layoutPriority(1)"),
        ] {
            let source = """
            @main
            struct P: App {
                var body: some Scene {
                    WindowGroup {
                        \(body)
                    }
                }
            }
            """
            RenderDiagnostics.reset()
            let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
            guard case .success(let view) = rendered else {
                print("PROBE wrapper-bisect \(name): RENDER FAILED")
                continue
            }
            let rep = Self.bitmap(view, size: NSSize(width: 300, height: 100))
            var ink = 0
            for x in 0..<300 { for y in 0..<100 {
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.88 { ink += 1 }
            } }
            print("PROBE wrapper-bisect \(name): ink=\(ink) diags=\(RenderDiagnostics.errors.count) \(RenderDiagnostics.errors.first.map { String($0.error.message.prefix(60)) } ?? "")")
        }
    }

    @MainActor
    @Test func editorSplitShapeBisect() throws {
        let leftFull = """
        Circle().fill(Color.gray)
                .frame(minWidth: 100, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                .listRowInsets(.init())
                .padding(.horizontal, 40)
                .padding(.vertical)
                .background()
                .layoutPriority(1)
        """
        let leftNoInsets = """
        Circle().fill(Color.gray)
                .frame(minWidth: 100, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.vertical)
                .background()
                .layoutPriority(1)
        """
        let leftEmpty = """
        EmptyView()
                .frame(minWidth: 100, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.vertical)
                .background()
                .layoutPriority(1)
        """
        for (name, left) in [("split-full", leftFull), ("split-noinsets", leftNoInsets), ("split-emptyleft", leftEmpty)] {
            _ = (name, left)
        }
        for (name, right) in [
            ("plainform", "Form { Text(String(\"RIGHT\")) }"),
            ("sectionform", "Form { Section(String(\"Head\")) { Text(String(\"RIGHT\")) } }"),
        ] {
            let source = """
            @main
            struct P: App {
                var body: some Scene {
                    WindowGroup {
                        HSplitView {
                            Text(String("LEFT")).frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                            \(right)
                                .formStyle(.grouped)
                                .padding()
                                .frame(minWidth: 300, idealWidth: 350, maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
            }
            """
            RenderDiagnostics.reset()
            let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
            guard case .success(let view) = rendered else {
                print("PROBE section-split \(name): RENDER FAILED")
                continue
            }
            for (w, h) in [(700, 300), (1000, 650)] {
                let rep = Self.bitmap(view, size: NSSize(width: CGFloat(w), height: CGFloat(h)))
                var ink = 0
                for x in (w/2)..<w { for y in 0..<h {
                    if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.88 { ink += 1 }
                } }
                print("PROBE section-split \(name)@\(w)x\(h): right-ink=\(ink)")
            }
        }
        for (name, left) in [("noop", "Text(String(\"X\"))")] {
            let source = """
            @main
            struct P: App {
                var body: some Scene {
                    WindowGroup {
                        HSplitView {
                            \(left)
                            Form { Text(String("RIGHT")) }
                                .formStyle(.grouped)
                                .padding()
                                .frame(minWidth: 300, idealWidth: 350, maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
            }
            """
            RenderDiagnostics.reset()
            let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
            guard case .success(let view) = rendered else {
                print("PROBE split-shape \(name): RENDER FAILED")
                continue
            }
            let rep = Self.bitmap(view, size: NSSize(width: 700, height: 300))
            var ink = 0
            for x in 0..<700 { for y in 0..<300 {
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.88 { ink += 1 }
            } }
            print("PROBE split-shape \(name): ink=\(ink) diags=\(RenderDiagnostics.errors.count) \(RenderDiagnostics.errors.first.map { String($0.error.message.prefix(70)) } ?? "")")
        }
    }

    @MainActor
    @Test func memberComposedSplitBodyRenders() throws {
        let source = """
        #if os(iOS)
        extension View {
            func storeMessagesDeferred(_ deferred: Bool) -> some View { self }
        }
        #endif

        struct Ed: View {
            @Binding var name: String

            var viewer: some View {
                EmptyView()
                    .frame(minWidth: 100, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.vertical)
                    .background()
            }

            @ViewBuilder
            var content: some View {
                Section(String("Donut")) {
                    TextField(String("Name"), text: $name, prompt: Text(String("Donut Name")))
                }
            }

            var body: some View {
                ZStack {
                    #if os(macOS)
                    HSplitView {
                        viewer
                            .layoutPriority(1)
                        Form {
                            content
                        }
                        .formStyle(.grouped)
                        .padding()
                        .frame(minWidth: 300, idealWidth: 350, maxHeight: .infinity, alignment: .top)
                    }
                    #else
                    Text(String("IOS BRANCH"))
                    #endif
                }
                .toolbar {
                    ToolbarTitleMenu {
                        Button {

                        } label: {
                            Label(String("My Action"), systemImage: String("star"))
                        }
                    }
                }
                .navigationTitle(name)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarRole(.editor)
                // We don't want store messages to interrupt any donut editing.
                .storeMessagesDeferred(true)
                #endif
            }
        }

        @main
        struct P: App {
            @State private var name: String = "New Donut"
            var body: some Scene {
                WindowGroup {
                    Ed(name: $name)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let previousPlatform = Interpreter.interpretsAsPlatform
        Interpreter.interpretsAsPlatform = "macOS"
        defer { Interpreter.interpretsAsPlatform = previousPlatform }
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 700, height: 300))
        var ink = 0
        for x in 0..<700 { for y in 0..<300 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.88 { ink += 1 }
        } }
        print("PROBE member-composed-split ink:", ink, "diags:", RenderDiagnostics.errors.count,
              RenderDiagnostics.errors.first.map { String($0.error.message.prefix(70)) } ?? "")
        #expect(ink > 200)
    }

    @MainActor
    @Test func feedListSectionsRender() throws {
        let source = """
        struct PostRow: View {
            let index: Int
            var body: some View {
                Section {
                    Text(String("POST ") + String(index))
                }
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    List {
                        Section(String("Posts")) {
                            ForEach(0..<3) { index in
                                PostRow(index: index)
                            }
                        }
                    }
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 400, height: 300))
        var ink = 0
        for x in 0..<400 { for y in 0..<300 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.88 { ink += 1 }
        } }
        print("PROBE feed-sections ink:", ink, "diags:", RenderDiagnostics.errors.count,
              RenderDiagnostics.errors.first.map { String($0.error.message.prefix(70)) } ?? "")
        #expect(ink > 300)
    }

    @MainActor
    @Test func reRenderKeepsInactivePlatformChainInert() throws {
        let source = """
        enum Panel: String, CaseIterable {
            case home
            case editor
        }

        struct Ed: View {
            var body: some View {
                Text(String("EDITOR PANEL"))
                    .navigationTitle(String("Donut"))
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarRole(.editor)
                    // We don't want store messages to interrupt any donut editing.
                    .storeMessagesDeferred(true)
                    #endif
            }
        }

        @main
        struct P: App {
            @State private var selection: Panel? = Panel.home
            var body: some Scene {
                WindowGroup {
                    HStack(spacing: 0) {
                        List(selection: $selection) {
                            NavigationLink(value: Panel.home) { Text(String("Home")) }
                            NavigationLink(value: Panel.editor) { Text(String("Editor")) }
                        }
                        .frame(width: 160)
                        switch selection {
                        case .editor:
                            Ed()
                        default:
                            Text(String("HOME PANEL"))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let previousPlatform = Interpreter.interpretsAsPlatform
        Interpreter.interpretsAsPlatform = "macOS"
        defer { Interpreter.interpretsAsPlatform = previousPlatform }
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 420, height: 200)
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
                .background(Color.white))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let initialDiagnostics = RenderDiagnostics.errors.count

        // Drive the selection to re-render the detail as the editor.
        var table: NSTableView?
        func walk(_ view: NSView) {
            if table == nil, let t = view as? NSTableView { table = t }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        guard let sidebar = table else {
            Issue.record("no sidebar table")
            return
        }
        sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        for _ in 0..<25 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let fresh = RenderDiagnostics.errors.dropFirst(initialDiagnostics)
        for entry in fresh.prefix(3) {
            print("PROBE re-render-diag:", entry.view, String(entry.error.message.prefix(90)))
        }
        print("PROBE re-render fresh-diags:", fresh.count)
        // The inactive-platform chain must stay inert across re-renders.
        #expect(fresh.isEmpty)
    }

    @MainActor
    @Test func demoMergeEditorNavigationDiagnostics() throws {
        let root = FileManager.default.currentDirectoryPath
            + "/Examples/FoodTruckBuildingASwiftUIMultiplatformApp"
        let previousPlatform = Interpreter.interpretsAsPlatform
        Interpreter.interpretsAsPlatform = "macOS"
        defer { Interpreter.interpretsAsPlatform = previousPlatform }
        RenderDiagnostics.reset()
        let source = ProjectMaterial.mergedSource(at: root)
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 1000, height: 650)
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
                .background(Color.white))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        for _ in 0..<15 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let initialDiagnostics = RenderDiagnostics.errors.count

        var table: NSTableView?
        func walk(_ view: NSView) {
            if table == nil, let t = view as? NSTableView { table = t }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        guard let sidebar = table, sidebar.numberOfRows >= 7 else {
            print("PROBE demo-merge sidebar rows:", table?.numberOfRows ?? -1)
            Issue.record("sidebar not found")
            return
        }
        // Row 6 = Donut Editor (headers are rows).
        sidebar.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let fresh = RenderDiagnostics.errors.dropFirst(initialDiagnostics)
        for entry in fresh.prefix(4) {
            print("PROBE demo-merge diag:", entry.view, String(entry.error.message.prefix(100)))
        }
        // Landing proof: the editor's Gauge bridges to AppKit — an
        // NSLevelIndicator/SwiftUI gauge host appears only on the editor.
        var controlTypes: Set<String> = []
        var fields = 0
        func walkControls(_ view: NSView) {
            let name = String(describing: type(of: view))
            if view is NSControl { controlTypes.insert(name) }
            if let field = view as? NSTextField, field.isEditable { fields += 1 }
            view.subviews.forEach(walkControls)
        }
        if let content = window.contentView { walkControls(content) }
        print("PROBE demo-merge fresh-diags:", fresh.count,
              "editable-fields:", fields,
              "controls:", controlTypes.sorted().prefix(6).joined(separator: ","))
    }

    @MainActor
    @Test func harnessControlPlainText() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Text(String("HELLO CONTROL"))
                        .background(Color.white)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 300, height: 120))
        var ink = 0
        for x in 0..<300 { for y in 0..<120 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { ink += 1 }
        } }
        print("PROBE harness-control ink:", ink)
        #expect(ink > 100)
    }

    @MainActor
    @Test func plainModelPropertyRead() throws {
        let source = """
        class Model: ObservableObject {
            @Published var name: String = "Alpha"
        }

        @main
        struct P: App {
            @StateObject private var model = Model()
            var body: some Scene {
                WindowGroup {
                    Text(String("NAME:") + model.name)
                        .background(Color.white)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 300, height: 120))
        var ink = 0
        for x in 0..<300 { for y in 0..<120 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { ink += 1 }
        } }
        print("PROBE plain-model-read ink:", ink, "diags:", RenderDiagnostics.errors.count)
        #expect(ink > 100)
    }
}
