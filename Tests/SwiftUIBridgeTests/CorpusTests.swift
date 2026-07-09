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


    /// Numeric `.zero` statics resolve in annotated positions and window
    /// frames read as the canvas rect — the responsive-layout genre.
    @Test func numericZeroAndWindowFrame() throws {
        let source = """
        struct ContentView: View {
            @State private var total: Double = .zero

            var body: some View {
                let frame = UIApplication.shared.windows.first?.frame ?? .zero
                VStack {
                    Text(currencyString(total))
                    Text(frame.width > 0 ? "sized" : "zero")
                }
            }

            func currencyString(_ value: Double) -> String {
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                return formatter.string(from: .init(value: value)) ?? ""
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// Custom Layout containers take trailing content and modifiers;
    /// children render in a default flow (the layout math doesn't run).
    @Test func layoutContainersRenderChildren() throws {
        let source = """
        struct TagLayout: Layout {
            var alignment: Alignment = .center
            var spacing: CGFloat = 10

            func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
                return proposal.replacingUnspecifiedDimensions()
            }

            func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            }
        }

        struct ContentView: View {
            let tags = ["swift", "ui", "layout"]

            var body: some View {
                TagLayout(alignment: .center, spacing: 10) {
                    ForEach(tags, id: \\.self) { tag in
                        Text(tag)
                    }
                }
                .padding()
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// UIKit-ish constructed objects get property-bag member semantics —
    /// nested writes round-trip, calls absorb (views keep modifier chains).
    @Test func hostObjectNodesChainBagsAndAbsorbCalls() throws {
        let source = """
        struct ContentView: View {
            @State private var status = "idle"

            var body: some View {
                Text(status)
                Button("Configure") {
                    let engine = AVAudioEngine()
                    engine.mainMixerNode.outputVolume = 0.5
                    engine.prepare()
                    engine.start()
                    status = engine.mainMixerNode.outputVolume == 0.5 ? "wired" : "lost"
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
        #expect(report.actionsInvoked == 1)
    }

    /// Hosted-object and marker truths read FALSE (fresh system state: no
    /// biometrics, no running sessions); negation reads true.
    @Test func hostedObjectTruthsAreFreshStateFalse() throws {
        let source = """
        struct ContentView: View {
            @State private var status = "checking"

            var body: some View {
                Text(status)
                Button("Auth") {
                    let context = LAContext()
                    if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                        status = "biometrics"
                    } else {
                        status = "fallback"
                    }
                    let session: AVCaptureSession = .init()
                    if !session.isRunning {
                        status = status + "/stopped"
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
        #expect(report.actionsInvoked == 1)
    }

    /// Color statics are real Colors; user Color/UIColor extensions
    /// dispatch on them (isDarkColor reads fresh-state luminance 0 = dark);
    /// tuple locals destructure.
    @Test func colorExtensionsAndTupleLocals() throws {
        let source = """
        extension Color {
            var isDarkColor: Bool {
                return UIColor(self).isDarkColor
            }
        }

        extension UIColor {
            var isDarkColor: Bool {
                var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
                self.getRed(&r, green: &g, blue: &b, alpha: &a)
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                return lum < 0.50
            }
        }

        struct ContentView: View {
            @State private var selectedColor: Color = Color.white

            var body: some View {
                Text("sample")
                    .foregroundColor(selectedColor.isDarkColor ? .white : .black)
                    .background(Color.black.opacity(0.3))
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
        let real = InterpreterHost().render(source: source)
        if case .failure(let error) = real {
            Issue.record("real render failed: \(error)")
        }
    }

    /// Size-class env keys read as the iPhone-portrait canvas; Query-shaped
    /// init markers act as fresh (empty) stores in ForEach.
    @Test func sizeClassesAndQueryMarkers() throws {
        let source = """
        struct ContentView: View {
            @Environment(\\.horizontalSizeClass) private var hSize
            @Environment(\\.verticalSizeClass) private var vSize

            var body: some View {
                VStack {
                    Text(hSize == .regular ? "wide" : "narrow")
                    Text(vSize == .regular ? "tall" : "short")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Fractional ranges: Slider(in: 0.01...0.1), Double.random over
    /// computed double bounds.
    @Test func fractionalRanges() throws {
        let source = """
        struct ContentView: View {
            @State private var speed: CGFloat = 0.05

            var body: some View {
                let size = CGSize(width: 390, height: 844)
                let randomHeight: CGFloat = .random(in: (size.height / 2)...size.height)
                VStack {
                    Slider(value: $speed, in: 0.01...0.1)
                    Text(randomHeight >= 422 ? "tall" : "short")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
        let real = InterpreterHost().render(source: source)
        if case .failure(let error) = real {
            Issue.record("real render failed: \(error)")
        }
    }

    /// A property named like a modifier (`var offset`) must not shadow the
    /// modifier at CALL sites — `.offset(y:)` retries the modifier table.
    @Test func propertyShadowedModifierRetries() throws {
        let source = """
        struct SheetCard: View {
            @Binding var offset: CGFloat

            var body: some View {
                Text("sheet")
            }
        }

        struct ContentView: View {
            @State private var offset: CGFloat = 0

            var body: some View {
                SheetCard(offset: $offset)
                    .offset(y: 140)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
        let real = InterpreterHost().render(source: source)
        if case .failure(let error) = real {
            Issue.record("real render failed: \(error)")
        }
    }

    /// Value-type member writes (`size.width = 300`, nested
    /// `rect.origin` swaps) and `$tuple.0` element bindings.
    @Test func valueMemberWritesAndTupleBindings() throws {
        let source = """
        struct ContentView: View {
            @State private var card: (CGFloat, Bool) = (0, false)

            var body: some View {
                var size = CGSize(width: 100, height: 40)
                let _ = { size.width = 300 }()
                VStack {
                    Slider(value: $card.0, in: 0...100)
                    Toggle("flip", isOn: $card.1)
                    Text("w \\(size.width > 200 ? "wide" : "narrow")")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Custom @resultBuilder closure parameters undergo the builder
    /// transform: the block's items collect into an array.
    @Test func customResultBuilderParameters() throws {
        let source = """
        @resultBuilder
        struct ItemBuilder {
            static func buildBlock(_ items: Item...) -> [Item] { items }
        }

        struct Item: Identifiable {
            var id: Int
            var name: String
        }

        struct Menu {
            var items: [Item]
            init(@ItemBuilder items: () -> [Item]) {
                self.items = items()
            }
        }

        struct ContentView: View {
            var body: some View {
                let menu = Menu {
                    Item(id: 1, name: "a")
                    Item(id: 2, name: "b")
                    Item(id: 3, name: "c")
                }
                VStack {
                    ForEach(menu.items) { item in
                        Text(item.name)
                    }
                    Text("count \\(menu.items.count)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// Real Swift scoping order: implicit-self members shadow globals.
    /// A method named like a top-level enum wins in call position; a
    /// stored property named like a global constant wins in reads.
    @Test func selfMembersShadowGlobals() throws {
        let source = """
        let title = "global"

        enum OTPField {
            case one
        }

        struct ContentView: View {
            var title: String = "member"

            var body: some View {
                VStack {
                    OTPField()
                    Text(title)
                }
            }

            func OTPField() -> some View {
                Text("field")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Case patterns with payload bindings against an unknowable host
    /// subject fall to `default` (fresh-state), and String.Index ranges:
    /// range(of:), bounds members, and string-by-range subscripting.
    @Test func casePatternsOnMarkersAndStringRanges() throws {
        let source = """
        struct ContentView: View {
            @State private var selection: TextSelection? = .init(insertionPoint: "".startIndex)

            var kind: String {
                if let selection {
                    switch selection.indices {
                    case .selection(let range):
                        return "sel \\(range)"
                    default: return "other"
                    }
                }
                return "nil"
            }

            var body: some View {
                let text = "say Hello Guys"
                VStack {
                    Text(kind)
                    if let range = text.range(of: "Hello") {
                        Text(text[range])
                        Text("at \\(range.isEmpty ? "empty" : "found")")
                    }
                    if text.range(of: "missing") == nil {
                        Text("absent")
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 5)
    }

    /// Host-superclass classes inherit their initializers: unmatched
    /// labeled init arguments bind as properties (SKScene(size:)-style),
    /// readable from methods (implicit self) and from outside.
    @Test func hostSuperclassInheritedInit() throws {
        let source = """
        class Emitter: SKScene {
            func summary() -> String {
                "w \\(size.width)"
            }
        }

        struct ContentView: View {
            var body: some View {
                let scene = Emitter(size: CGSize(width: 320, height: 200))
                VStack {
                    Text(scene.summary())
                    Text(scene.size.height > 100 ? "tall" : "short")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Numeric conversions of unknowable values read the fresh state:
    /// Int(stub chain) is 0 (not nil), so downstream comparisons and
    /// formatting work like a just-launched app.
    @Test func numericConversionsAbsorbUnknowables() throws {
        let source = """
        struct ContentView: View {
            func formatted(_ value: TimeInterval) -> String {
                "\\(Int(value / 60)):\\(Int(value.truncatingRemainder(dividingBy: 60)) < 9 ? "0" : "")\\(Int(value.truncatingRemainder(dividingBy: 60)))"
            }

            var body: some View {
                let player = AVAudioPlayer()
                VStack {
                    Text(formatted(player.currentTime))
                    Text(Double(player.duration) == 0 ? "fresh" : "playing")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Locale is bridged to the real host locale: `Locale.current`
    /// chains (regionCode ?? "" into a dictionary lookup) behave like a
    /// device instead of erroring on marker comparisons.
    @Test func localeBridgesToHost() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let region = Locale.current.regionCode ?? ""
                let codes = ["US": "+1", "IN": "+91"]
                VStack {
                    Text(Locale.current.identifier.isEmpty ? "none" : "have locale")
                    Text(codes[region] ?? "unknown")
                    Text(Locale(identifier: "en_US").identifier)
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// FileManager bridges to a per-run sandbox (fresh container:
    /// documents start empty) and URL values are real Foundation URLs.
    @Test func fileManagerSandboxAndRealURLs() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let file = docs.appendingPathComponent("track.mp3")
                VStack {
                    Text(FileManager.default.fileExists(atPath: file.path) ? "cached" : "fresh")
                    Text(file.lastPathComponent)
                    if let remote = URL(string: "https://example.com/a/song.mp3") {
                        Text(remote.lastPathComponent)
                    }
                    Text(URL(string: "") == nil ? "invalid" : "valid")
                    Text(URL(string: UIApplication.openSettingsURLString) == nil ? "lost" : "flows")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 5)
    }

    /// Unknowables read fresh-state identities in typed contexts:
    /// "" in string concat (suffix survives), empty in for-in iteration.
    @Test func unknowablesReadFreshIdentities() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let path = NSTemporaryDirectory() + "clip.mov"
                var visited = 0
                let _ = {
                    for _ in Activity<DockAttributes>.activities {
                        visited += 1
                    }
                }()
                VStack {
                    Text(path)
                    Text(path.hasSuffix("clip.mov") ? "suffix kept" : "lost")
                    Text("visited \\(visited)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// The appearance proxy is a read/write bag with real fresh-layout
    /// geometry: bounds reads CGRect.zero, member writes stick, config
    /// calls chain inertly.
    @Test func appearanceProxyReadsAndWrites() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let refreshControl = UIRefreshControl.appearance()
                let _ = {
                    refreshControl.bounds = CGRect(x: refreshControl.bounds.origin.x,
                                                   y: -350 + refreshControl.bounds.origin.y,
                                                   width: refreshControl.bounds.size.width,
                                                   height: refreshControl.bounds.size.height)
                    refreshControl.tintColor = .white
                }()
                VStack {
                    Text(refreshControl.bounds.origin.y < 0 ? "moved" : "zero")
                    Text("w \\(refreshControl.bounds.size.width)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Double-family annotations (CGFloat/Double/TimeInterval) store
    /// doubles even from Int literals: division is IEEE (infinity), not
    /// an Int-division trap.
    @Test func doubleFamilyAnnotationsCoerceIntLiterals() throws {
        let source = """
        struct ContentView: View {
            @State var titleOffset: CGFloat = 0
            var interval: TimeInterval = 3

            func slideProgress() -> CGFloat {
                let progress = 20 / titleOffset
                return 60 * (progress > 0 && progress <= 1 ? progress : 1)
            }

            var body: some View {
                VStack {
                    Text("offset \\(slideProgress())")
                    Text(interval / 2 == 1.5 ? "halved" : "int-divided")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Array("abc") splits into characters (single-char strings), so
    /// index math over a constant string works like compiled Swift.
    @Test func arrayOfStringSplitsCharacters() throws {
        let source = """
        let constant = "matrix"

        struct ContentView: View {
            func shifted(_ index: Int) -> Int {
                let max = constant.count - 1
                return index + 2 > max ? index : index + 2
            }

            var body: some View {
                VStack {
                    ForEach(0..<constant.count, id: \\.self) { index in
                        Text(String(Array(constant)[shifted(index)]))
                    }
                    Text("count \\(Array(constant).count)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 7)
    }

    /// Static stored properties write and read back — including
    /// host-type extension statics declared without initializers
    /// (`extension ChatClient { static var shared: ChatClient! }`).
    @Test func staticStoredPropertyWrites() throws {
        let source = """
        extension ChatClient {
            static var shared: ChatClient!
        }

        struct Palette {
            static var accent = "blue"
        }

        struct ContentView: View {
            var body: some View {
                let before = ChatClient.shared == nil ? "fresh" : "set"
                let _ = {
                    ChatClient.shared = ChatClient(config: "demo")
                    Palette.accent = "red"
                }()
                VStack {
                    Text(before)
                    Text(ChatClient.shared == nil ? "still nil" : "assigned")
                    Text(Palette.accent == "red" ? "recolored" : "stale")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// A parameterized ROOT view (no ContentView) renders standalone:
    /// required parameters synthesize fresh values — identity primitives,
    /// recursive fresh instances for interpreted types (through custom
    /// inits), unknowable chains for host generics. Formatter config
    /// setters (locale/dateStyle) and the case-path prefix `/` parse.
    @Test func parameterizedRootViewSynthesis() throws {
        let source = """
        extension DateFormatter {
            convenience init(calendar: Calendar, dateFormat: String) {
                self.init()
                self.calendar = calendar
                self.dateFormat = dateFormat
            }
        }

        struct DayView: View {
            struct ViewState {
                let text: String

                init(date: Date, calendar: Calendar, isDisabled: Bool) {
                    let formatter = DateFormatter(calendar: calendar, dateFormat: "d")
                    formatter.locale = .current
                    self.text = formatter.string(from: date)
                }
            }

            let state: ViewState
            let store: Store<String, Never>
            let count: Int
            let scale: CGFloat
            let path = /DayAction.selected

            var body: some View {
                VStack {
                    Text(state.text.isEmpty ? "no day" : "day \\(state.text)")
                    Text("count \\(count) scale \\(scale)")
                    Text(store.isLoading ? "loading" : "fresh")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// A vendored type sharing a host type's name (Lottie's `struct
    /// Color`) must not shadow the framework: constructor binding
    /// failures and static-member misses fall through to the registry.
    @Test func vendoredTypeNameCollision() throws {
        let source = """
        struct Color {
            var r: Double
            var g: Double
            var b: Double

            init(r: Double, g: Double, b: Double) {
                self.r = r
                self.g = g
                self.b = b
            }
        }

        struct ContentView: View {
            var body: some View {
                let lottie = Color(r: 0.1, g: 0.2, b: 0.3)
                ZStack {
                    Color("bg").ignoresSafeArea()
                    VStack {
                        Text("vendored g \\(lottie.g)")
                            .foregroundColor(Color.black)
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Fresh-store persistence reads fail honestly: Data(contentsOf:)
    /// of a missing sandbox file throws (try? -> nil), decode through a
    /// stub decoder throws, so archived-state restores take their else
    /// branch and later writes land on real instances. Trap builtins
    /// (fatalError family) resolve; FileManager.url singular forms work.
    @Test func freshStoreRestorePath() throws {
        let source = """
        struct MoviesState {
            var movies: [Int: String] = [:]
        }

        final class AppState: ObservableObject {
            var moviesState: MoviesState
            var savePath: URL

            init() {
                do {
                    let documentDirectory = try FileManager.default.url(for: .documentDirectory,
                                                                        in: .userDomainMask,
                                                                        appropriateFor: nil,
                                                                        create: false)
                    savePath = documentDirectory.appendingPathComponent("userData")
                } catch {
                    fatalError("Couldn't create save state data with error: \\(error)")
                }
                if let data = try? Data(contentsOf: savePath),
                   let savedState = try? JSONDecoder().decode(AppState.self, from: data) {
                    self.moviesState = savedState.moviesState
                } else {
                    self.moviesState = MoviesState()
                }
                moviesState.movies[0] = "sample"
            }
        }

        struct ContentView: View {
            var body: some View {
                let state = AppState()
                VStack {
                    Text("movies \\(state.moviesState.movies.count)")
                    Text(state.moviesState.movies[0] ?? "missing")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Multi-target repos redeclare views per platform (iOS/macOS
    /// ContentView + PostList). Duplicate names resolve LAST-wins
    /// consistently — the root-view pick and member resolution must
    /// agree, or a 2-param body binds a 5-param symbol.
    @Test func duplicateTypeNamesLastWins() throws {
        let source = """
        struct PostList: View {
            let subreddit: String
            var body: some View { Text("ios \\(subreddit)") }
        }

        struct ContentView: View {
            var body: some View { PostList(subreddit: "swift") }
        }

        struct PostList: View {
            let posts: [String]
            let isLoading: Bool

            var body: some View {
                if isLoading {
                    Text("loading")
                } else {
                    Text("posts \\(posts.count)")
                }
            }
        }

        struct ContentView: View {
            var body: some View {
                PostList(posts: ["a"], isLoading: false)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// Date bounds form ranges (`soon..<later`, `soon...later`) and feed
    /// DatePicker's `in:` — the DatePickerPage idiom.
    @Test func dateRanges() throws {
        let source = """
        struct ContentView: View {
            @State private var picked = Date()

            var body: some View {
                let soon = Date()
                let later = Calendar.current.date(byAdding: .year, value: 1, to: soon) ?? Date()
                let window = soon..<later
                let full = soon...later
                VStack {
                    DatePicker("half-open", selection: $picked, in: window)
                    DatePicker("closed", selection: $picked, in: full)
                    Text("windowed")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// Percent-encoding with CharacterSet markers: the API-URL-building
    /// idiom (addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
    /// and its removing inverse.
    @Test func percentEncoding() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let query = "forecast/48.85,2.35?units=ca&lang=fr résumé"
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                VStack {
                    Text(encoded.contains("%20") ? "encoded" : "raw")
                    Text(encoded.removingPercentEncoding ?? "lost")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// `actor` declarations collect as reference-typed classes: state
    /// mutates through methods, reads see the shared instance.
    @Test func actorDeclarations() throws {
        let source = """
        actor ImageCache {
            var stored: [String: String] = [:]

            func insert(_ value: String, forKey key: String) {
                stored[key] = value
            }

            func lookup(_ key: String) -> String? {
                stored[key]
            }
        }

        struct ContentView: View {
            var body: some View {
                let cache = ImageCache()
                let _ = {
                    cache.insert("hero.png", forKey: "hero")
                }()
                VStack {
                    Text(cache.lookup("hero") ?? "miss")
                    Text("count \\(cache.stored.count)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

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

    /// `Path{}.strokedPath(StrokeStyle(...)).fill(...)` — Path is a
    /// Shape/View: draw commands chain, stroke styles apply for real.
    @Test func pathChainsStrokeAndFill() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLines([CGPoint(x: 20, y: 40), CGPoint(x: 60, y: 10)])
                }
                .strokedPath(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .fill(.blue.opacity(0.5))
                .frame(height: 100)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
        let real = InterpreterHost().render(source: source)
        if case .failure(let error) = real {
            Issue.record("real render failed: \(error)")
        }
    }

    /// `$published` pipelines inside models chain inertly and never emit
    /// headlessly (debounce schedulers don't run) — the honest silent
    /// pipeline; `&inout` args and Set() holders ride along.
    @Test func publishedProjectionPipelinesAreSilent() throws {
        let source = """
        class SearchModel: ObservableObject {
            @Published var searchText = ""
            var cancellable: AnyCancellable?
            var fired = false

            init() {
                cancellable = $searchText
                    .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
                    .removeDuplicates()
                    .sink(receiveValue: { value in
                        self.fired = true
                    })
            }
        }

        struct ContentView: View {
            @StateObject var model = SearchModel()

            var body: some View {
                VStack {
                    TextField("Search", text: $model.searchText)
                    Text(model.fired ? "fired" : "silent")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// `.constant("")` bindings: fixed-value boxes for @Binding properties
    /// and real Binding coercions; comparisons read the constant.
    @Test func constantBindingsResolve() throws {
        let source = """
        struct MenuRow: View {
            var title: String
            @Binding var selectedMenu: String

            var body: some View {
                Button(title) {
                    selectedMenu = title
                }
                .opacity(selectedMenu == title ? 1 : 0.6)
            }
        }

        struct ContentView: View {
            @State private var selected = "Home"

            var body: some View {
                VStack {
                    MenuRow(title: "Home", selectedMenu: $selected)
                    MenuRow(title: "Log out", selectedMenu: .constant(""))
                    Text(selected)
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
        #expect(report.actionsInvoked == 2)
    }

    /// Bare `.init()` dates in Calendar args, Date comparison operators,
    /// sorted(by:) labeled closures, calendar.compare(to:toGranularity:).
    @Test func dateComparisonAndCalendarCompare() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let calendar = Calendar.current
                let now = Date()
                let later = calendar.date(byAdding: .hour, value: 2, to: .init()) ?? now
                let ordered = [later, now].sorted(by: { $0 < $1 })
                let ordering = calendar.compare(now, to: later, toGranularity: .hour)
                VStack {
                    Text(ordered[0] <= ordered[1] ? "sorted" : "unsorted")
                    Text(ordering == .orderedAscending ? "ascending" : "other")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// dateInterval(of:for:) with weekOfMonth + user `extension Calendar`
    /// members dispatching on the real-backed box.
    @Test func dateIntervalAndCalendarExtensions() throws {
        let source = """
        extension Calendar {
            var workingHours: [Int] {
                return [9, 12, 17]
            }
        }

        struct ContentView: View {
            var body: some View {
                let calendar = Calendar.current
                let week = calendar.dateInterval(of: .weekOfMonth, for: Date())
                let hours = Calendar.current.workingHours
                VStack {
                    Text(week != nil ? "has week" : "no week")
                    Text((week?.start ?? Date()).timeIntervalSince1970 > 0 ? "ok" : "bad")
                    Text("\\(hours.count) hours")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
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
