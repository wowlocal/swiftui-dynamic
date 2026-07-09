import AppKit
import SwiftUI
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// Corpus files live next to this test file (excluded from compilation in the
/// manifest) and are listed via #filePath. Test arguments are enumerated off
/// the main actor, so this path must be nonisolated despite the package-wide
/// MainActor default — hence the free function instead of a closure initializer.
private nonisolated func listCorpusFiles() -> [String] {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Corpus")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".swift") }.sorted()
}

nonisolated let corpusFiles: [String] = listCorpusFiles()

/// The "runs real-world code" gate: every program in Corpus/ must interpret,
/// deep-render (every View body force-evaluated, not just the lazy root),
/// survive having all its actions invoked, and render through real SwiftUI
/// hosting without inline errors.
enum Corpus {
    static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Corpus")
            .appendingPathComponent(file)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite struct CorpusTests {
    @Test func corpusIsPopulated() {
        #expect(corpusFiles.count >= 10)
    }

    @Test(arguments: corpusFiles)
    func traceDeepRenderWithInteractions(file: String) throws {
        let report = try HeadlessVerifier.verify(source: try Corpus.source(file))
        #expect(report.nodeCount > 1, "\(file) rendered a trivial tree")
    }

    /// User extensions of UIKit types dispatch on the stubs standing in for
    /// them, with bare host members as implicit self; the window/VC island
    /// is inert-chainable with round-tripping writes.
    @Test func uiApplicationExtensionsDispatchOnStubs() throws {
        let source = """
        extension UIApplication {
            func closeKeyboard() {
                sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }

            func rootController() -> UIViewController {
                return (windows.first?.rootViewController)!
            }
        }

        struct ContentView: View {
            @State private var status = "editing"

            var body: some View {
                VStack {
                    Text(status)
                    Button("Done") {
                        UIApplication.shared.closeKeyboard()
                        UIApplication.shared.rootController().view.tag = 7
                        status = UIApplication.shared.canOpenURL("https://x.co") ? "openable" : "sandboxed"
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
        #expect(report.actionsInvoked == 1)
    }

    /// Query-wrapper CONSTRUCTORS are fresh-store empty results, so custom
    /// inits assigning backing storage (`_list = Query(descriptor)`) keep
    /// ForEach iterable; unknown store-query objects act empty.
    @Test func queryConstructorAssignsFreshStore() throws {
        let source = """
        struct Todo: Identifiable {
            let id: Int
            var title: String
        }

        struct ContentView: View {
            @Query private var activeList: [Todo]

            init() {
                _activeList = Query(FetchDescriptor(), animation: .snappy)
            }

            var body: some View {
                List {
                    ForEach(activeList) { todo in
                        Text(todo.title)
                    }
                    if activeList.isEmpty {
                        Text("No todos yet")
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// Text concatenation (`Text + Text`) and real NumberFormatter output.
    @Test func textConcatAndNumberFormatter() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                Text("Steps: ")
                    .foregroundColor(.gray)
                +
                Text(formatted(6521.5))
                    .fontWeight(.bold)
            }

            func formatted(_ value: CGFloat) -> String {
                let format = NumberFormatter()
                format.numberStyle = .decimal
                format.maximumFractionDigits = 1
                return format.string(from: NSNumber(value: value)) ?? ""
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Imperative statements inside builder-evaluated closures execute for
    /// effect — `do/catch` (the `.task { do { try await … } catch {} }`
    /// idiom), plus `#selector` staying an inert marker.
    @Test func doCatchInBuilderPositionsExecutes() throws {
        let source = """
        struct ContentView: View {
            @State private var status = "loading"

            var body: some View {
                do {
                    status = try checked("ready")
                } catch {
                }
                Text(status)
                Button("Dismiss keyboard") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }

            func checked(_ value: String) throws -> String {
                return value
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
        #expect(report.actionsInvoked == 1)
    }

    /// `@Bindable var x = model` as a body-local: `$x.field` projects a
    /// binding into the observable model's own storage.
    @Test func bindableLocalProjectsModelBindings() throws {
        let source = """
        @Observable
        class SharedModel {
            var activeTab: String = "home"
            var showsSheet: Bool = false
        }

        struct ContentView: View {
            @Environment(SharedModel.self) private var sharedModel

            var body: some View {
                @Bindable var bindableObject = sharedModel
                VStack {
                    Toggle("Sheet", isOn: $bindableObject.showsSheet)
                    Text(bindableObject.activeTab)
                    Button("Go profile") {
                        sharedModel.activeTab = "profile"
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
        #expect(report.actionsInvoked == 1)
    }

    /// `#if os(iOS)` in builder and postfix (modifier-chain) positions.
    @Test func conditionalCompilationInBuildersAndPostfix() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack {
                    #if os(iOS)
                    Text("touch UI")
                    #else
                    Text("pointer UI")
                    #endif
                    Text("shared")
                    #if os(iOS)
                        .padding()
                        .font(.caption)
                    #endif
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Parameterized closures on unknown constructors are callbacks we
    /// can't honestly drive (SignInWithAppleButton's onRequest, UIAction
    /// handlers) — recorded as configuration, never invoked.
    @Test func callbackClosuresOnUnknownConstructorsAreNotInvoked() throws {
        let source = """
        struct ContentView: View {
            @State private var status = "idle"

            var body: some View {
                VStack {
                    SignInWithAppleButton { request in
                        request.requestedScopes = [.fullName]
                    } onCompletion: { result in
                        status = "done"
                    }
                    Text(status)
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// Uninitialized `@FocusState var x: Bool` defaults false (real SwiftUI
    /// semantics), so it works in Bool positions immediately.
    @Test func focusStateDefaultsFalse() throws {
        let source = """
        struct ContentView: View {
            @FocusState private var isKeyboardShowing: Bool
            @State private var text = ""

            var body: some View {
                VStack {
                    TextField("code", text: $text)
                        .focused($isKeyboardShowing)
                    let status = (isKeyboardShowing && text.count == 0)
                    Text(status ? "active" : "idle")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// User `extension Binding { … }` members dispatch on projections.
    @Test func bindingExtensionMembersDispatch() throws {
        let source = """
        extension Binding where Value == String {
            func isLong(_ length: Int) -> Bool {
                return self.wrappedValue.count > length
            }
        }

        struct ContentView: View {
            @State private var text = "hello"

            var body: some View {
                Text($text.isLong(3) ? "long" : "short")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// Real-Calendar members: dateComponents(from:to:), range(of:in:for:),
    /// symbols, isDateInToday — plus user Date-extension statics resolving
    /// in annotated positions.
    @Test func calendarMembersAndDateExtensionStatics() throws {
        let source = """
        extension Date {
            static var anchor: Date {
                return Date()
            }
        }

        struct ContentView: View {
            @State private var pinned: Date = .anchor

            var body: some View {
                let calendar = Calendar.current
                let later = calendar.date(byAdding: .hour, value: 2, to: pinned) ?? pinned
                let gap = calendar.dateComponents([.hour, .minute], from: pinned, to: later)
                let days = calendar.range(of: .day, in: .month, for: pinned)?.count ?? 0
                VStack {
                    Text("gap \\(gap.hour ?? 0)h")
                    Text(calendar.monthSymbols.first ?? "?")
                    Text(calendar.isDateInToday(pinned) ? "today" : "past")
                    Text("days \\(days)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// A typed env object with no ambient injection (the App shell that
    /// would provide it never runs) synthesizes one fresh instance per type.
    @Test func missingEnvironmentObjectSynthesizesFreshModel() throws {
        let source = """
        @Observable
        class Router {
            var path: [String] = []
        }

        struct ContentView: View {
            @Environment(Router.self) private var router

            var body: some View {
                VStack {
                    Text("depth \\(router.path.count)")
                    Button("Push") {
                        router.path.append("detail")
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
        #expect(report.actionsInvoked == 1)
    }

    /// `@Environment(\.self)` — the whole EnvironmentValues; member reads
    /// serve the keyed defaults (colorScheme…).
    @Test func wholeEnvironmentValuesServesMembers() throws {
        let source = """
        struct ContentView: View {
            @Environment(\\.self) var env

            var body: some View {
                Text(env.colorScheme == .dark ? "dark" : "light")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// `@FetchRequest` (CoreData) joins the fresh-store query wrappers:
    /// results are empty, the empty-state branch renders.
    @Test func fetchRequestFlattensToEmptyResults() throws {
        let source = """
        struct ContentView: View {
            @FetchRequest(entity: nil, sortDescriptors: []) var results: [Int]

            var body: some View {
                if results.isEmpty {
                    Text("No Tasks !!!")
                } else {
                    Text("\\(results.count) tasks")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// `Binding<T>(get:set:)` — generic specialization evaluates as its base
    /// and the computed binding snapshots get() per render pass.
    @Test func computedBindingWithGenericSpecialization() throws {
        let source = """
        struct ContentView: View {
            @State private var celsius = 25.0

            var body: some View {
                VStack {
                    Slider(value: Binding<Double>(get: {
                        celsius * 9 / 5 + 32
                    }, set: { newValue in
                        celsius = (newValue - 32) * 5 / 9
                    }), in: 32...212)
                    Text("F = \\(celsius * 9 / 5 + 32)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// A CaseIterable enum nested in the very view that iterates it:
    /// `ForEach(ChartType.allCases, id: \.rawValue)`.
    @Test func nestedEnumAllCasesDrivesForEach() throws {
        let source = """
        struct ContentView: View {
            @State private var chartType: ChartType = .bar

            var body: some View {
                VStack {
                    ForEach(ChartType.allCases, id: \\.rawValue) { type in
                        Text(type.rawValue)
                    }
                }
            }

            enum ChartType: String, CaseIterable {
                case bar = "Bar"
                case line = "Line"
                case pie = "Pie"
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// KeyframeAnimator/PhaseAnimator content receives the animated value —
    /// headlessly the initialValue (or first phase) seeds it.
    @Test func keyframeAnimatorContentReceivesInitialValue() throws {
        let source = """
        struct Frame {
            var top: CGFloat = 0
            var opacity: CGFloat = 1
        }

        struct ContentView: View {
            var body: some View {
                KeyframeAnimator(initialValue: Frame(), trigger: true) { value in
                    Text("t")
                        .offset(y: value.top)
                        .opacity(value.opacity)
                } keyframes: { _ in
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// `NSScreen.main?.visibleFrame` — real screen when present, a
    /// laptop-shaped rect headlessly; members read as numbers.
    @Test func screenVisibleFrameServesRectMembers() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let frame = NSScreen.main?.visibleFrame ?? .zero
                let size = NSScreen.main?.visibleFrame.size
                Text("w=\\(frame.width) h=\\(size?.height ?? 0)")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// `DispatchQueue.main.asyncAfter(deadline: .now() + delay)` schedules
    /// the interpreted closure without error (click-through fires it).
    @Test func asyncAfterSchedulesInertly() throws {
        let source = """
        struct ContentView: View {
            @State private var fired = false

            var body: some View {
                VStack {
                    Text(fired ? "fired" : "waiting")
                    Button("Later") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                            fired = true
                        }
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// Unknown-API trailing closures that don't yield views (the Lottie
    /// idiom: `LottieView { await LottieAnimation.loadedFrom(url:) }`) are
    /// recorded as configuration instead of failing the builder.
    @Test func nonBuilderClosureOnUnknownConstructorDegrades() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack {
                    LottieView {
                        await LottieAnimation.loadedFrom(url: "logo.json")
                    }
                    .playing(true)
                    Text("ready")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Opaque host objects recorded as trace nodes behave like the mutable
    /// objects they stand for: property writes round-trip on reads
    /// (`gesture.name = id … gesture.name`).
    @Test func hostObjectPropertyWritesRoundTripInTrace() throws {
        let source = """
        struct ContentView: View {
            @State private var gesture: UIPanGestureRecognizer = {
                let gesture = UIPanGestureRecognizer()
                gesture.name = "pop-gesture"
                gesture.isEnabled = false
                return gesture
            }()

            var body: some View {
                Text(gesture.name ?? "unset")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// Scene-management env actions are honest no-ops (no scene shell in our
    /// hosting) — declaring, rendering, and firing them must all work.
    @Test func windowActionsAreInertlyCallable() throws {
        let source = """
        struct ContentView: View {
            @Environment(\\.openWindow) private var openWindow
            @Environment(\\.dismissWindow) private var dismissWindow
            @State private var clicks = 0

            var body: some View {
                VStack {
                    Text("clicks: \\(clicks)")
                    Button("New window") {
                        openWindow(id: "second")
                        clicks += 1
                    }
                    Button("Close") {
                        dismissWindow()
                        clicks += 1
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount > 2)
    }

    /// MapKit views can't real-host (the bridge never imports MapKit), so the
    /// reader-family stub is verified trace-only: content deep-renders with a
    /// MapProxyStub whose conversions are honestly nil.
    @Test func mapReaderContentRendersWithProxyStub() throws {
        let source = """
        struct ContentView: View {
            @State private var status = "unresolved"

            var body: some View {
                MapReader { proxy in
                    VStack {
                        Text(status)
                        Button("Locate") {
                            if let point = proxy.convert(CGPoint(x: 10, y: 10), from: .global) {
                                status = "converted \\(point)"
                            } else {
                                status = "no map"
                            }
                        }
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount > 2)
    }

    @Test(arguments: corpusFiles)
    func hostedRealRender(file: String) throws {
        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: try Corpus.source(file)) {
        case .failure(let error):
            Issue.record("\(file): \(error)")
        case .success(let view):
            // Hosting in a (never-shown) window forces every nested
            // InterpretedView body to evaluate through the real gateways.
            let hosting = NSHostingView(rootView: view.frame(width: 480, height: 640))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for (viewName, error) in RenderDiagnostics.errors {
                Issue.record("\(file) → \(viewName): \(error)")
            }
        }
    }

}
