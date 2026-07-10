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

    /// AsyncImage verifies BOTH phases headlessly: the content closure
    /// receives a stub image (so `$0.resizable()` shorthand chains), and
    /// the placeholder renders — the phase a fresh launch shows.
    @Test func asyncImageContentAndPlaceholder() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                AsyncImage(
                    url: URL(string: "https://example.com/hero.png")
                ) {
                    $0
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                } placeholder: {
                    ProgressView()
                        .frame(width: 100, height: 100)
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// ForEach over an unknowable host collection (GraphQL fragment
    /// chains) renders ZERO rows — the fresh-store reading, matching the
    /// for-in doctrine; sibling views still render.
    @Test func forEachOverUnknowableChains() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let character = GraphQLStore.current.character
                VStack {
                    Text("Episodes")
                    ForEach(character.fragments.characterFull.episode.compactMap { $0 }, id: \\.self) { episode in
                        Text(episode.name ?? "")
                    }
                    Text("footer")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Import declarations in any form (@_exported, @preconcurrency,
    /// inside #if) are no-ops; host-member function reads in sequence
    /// position iterate empty (for-in and ForEach alike).
    @Test func importsAreNoOpsAndFunctionSequencesAreEmpty() throws {
        let source = """
        #if canImport(UIKit)
        @_exported import UIKit
        @preconcurrency import Foundation
        #endif

        struct ContentView: View {
            var body: some View {
                let store = KeyValueStore()
                var visited = 0
                let _ = {
                    for _ in store.allKeys {
                        visited += 1
                    }
                }()
                VStack {
                    Text("visited \\(visited)")
                    ForEach(store.allKeys, id: \\.self) { key in
                        Text("\\(key)")
                    }
                    Text("done")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Protocol-extension members apply to conforming natives:
    /// `extension Collection { var isNotEmpty }` works on arrays,
    /// strings, and dictionaries; BinaryInteger extensions on Int.
    @Test func protocolExtensionsOnNatives() throws {
        let source = """
        extension Collection {
            var isNotEmpty: Bool { isEmpty == false }
        }

        extension BinaryInteger {
            var isPositive: Bool { self > 0 }
        }

        struct ContentView: View {
            var body: some View {
                let names = ["a", "b"]
                let ages = ["ann": 3]
                VStack {
                    Text(names.isNotEmpty ? "have names" : "none")
                    Text("word".isNotEmpty ? "have word" : "none")
                    Text(ages.isNotEmpty ? "have ages" : "none")
                    Text(7.isPositive ? "positive" : "negative")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 5)
    }

    /// Custom inits assign wrapper STORAGE directly: `self._name =
    /// binding` and `self._viewModel = StateObject(wrappedValue: …)` —
    /// the storage is the value, and `$viewModel.field` projects off it.
    @Test func wrapperStorageInits() throws {
        let source = """
        class EditViewModel: ObservableObject {
            @Published var name: String

            init(name: String) {
                self.name = name
            }

            var isModified: Bool { name != "Ada" }
        }

        struct EditView: View {
            @Binding var name: String
            @StateObject var viewModel: EditViewModel

            init(name: Binding<String>) {
                self._name = name
                self._viewModel = StateObject(wrappedValue: EditViewModel(name: name.wrappedValue))
            }

            var body: some View {
                Form {
                    TextField("Enter your name", text: $viewModel.name)
                    Text(viewModel.isModified ? "modified" : "fresh")
                }
            }
        }

        struct ContentView: View {
            @State private var name = "Ada"

            var body: some View {
                EditView(name: $name)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Standalone roots synthesize @Binding parameters (fresh inner
    /// value), missing env models instantiate with FRESH init arguments,
    /// and unqualified modifiers inside View extensions bind implicit
    /// self (`sheet(item:)`/`navigationDestination` without a receiver).
    @Test func rootBindingsFreshModelsAndImplicitModifiers() throws {
        let source = """
        enum AppTab {
            case timeline, explore
        }

        class Client: ObservableObject {
            let server: String

            init(server: String) {
                self.server = server
            }
        }

        extension View {
            func withAppRouter() -> some View {
                navigationDestination(for: String.self) { _ in
                    Text("route")
                }
            }
        }

        struct AppView: View {
            @Binding var selectedTab: AppTab
            @EnvironmentObject var client: Client

            var body: some View {
                VStack {
                    Text(selectedTab == .timeline ? "timeline" : "other")
                    Text("server '\\(client.server)'")
                }
                .withAppRouter()
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Five capabilities from the IceCubes climb: ToolbarContent
    /// instances render (body duck-typing), a type's own nested types
    /// shadow same-named globals, wrapper-storage `.init(initialValue:)`
    /// markers dispatch members onto the wrapped value, and Date
    /// arithmetic (Date ± TimeInterval, Date − Date).
    @Test func toolbarContentNestedShadowingAndDateMath() throws {
        let source = """
        struct TitleToolbar: ToolbarContent {
            let title: String

            var body: some ToolbarContent {
                ToolbarItem(placement: .principal) {
                    Text(title)
                }
            }
        }

        enum Constants {
            static let label = "global"
        }

        class Model: ObservableObject {
            var state: String = "loaded"
        }

        struct Host {
            var storage: CustomStorage = .init(initialValue: Model())
        }

        struct ContentView: View {
            enum Constants {
                static let spacing: CGFloat = 12
            }

            var body: some View {
                let seconds = Date() - (Date() - 100)
                VStack(spacing: Constants.spacing) {
                    Text(Host().storage.state)
                    Text(seconds >= 99 ? "minute-ish" : "off")
                    Text(Date() - 100 < Date() ? "past" : "future")
                }
                .toolbar {
                    TitleToolbar(title: "Feed")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// Nested CLASSES register like nested structs (UserPreferences.
    /// Storage), and bound host-member functions absorb to fresh
    /// identities: 0 in arithmetic, false in Bool positions.
    @Test func nestedClassesAndFunctionAbsorption() throws {
        let source = """
        class Preferences {
            class Storage {
                var useSettings: Bool = true
            }

            private let storage = Storage()
            var useSettings: Bool

            init() {
                useSettings = storage.useSettings
            }
        }

        struct ContentView: View {
            var body: some View {
                let prefs = Preferences()
                let device = HapticEngine()
                let luminance = 0.299 * device.red + 0.587 * device.green
                VStack {
                    Text(prefs.useSettings ? "instance settings" : "app settings")
                    Text(luminance == 0 ? "dark" : "lit")
                    Text(device.isReady ? "ready" : "fresh")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// Custom environment keys read their @Entry defaults (undeclared
    /// ones read fresh identities); bare static markers adopt the other
    /// operand's type in arithmetic; unknowable range bounds read zero;
    /// String.unicodeScalars counts real scalars.
    @Test func customEnvKeysStaticAdoptionAndScalars() throws {
        let source = """
        extension EnvironmentValues {
            @Entry var indentationLevel: UInt = 2
        }

        extension CGFloat {
            static let statusColumnsSpacing: CGFloat = 8
        }

        struct ContentView: View {
            @Environment(\\.indentationLevel) private var indentationLevel
            @Environment(\\.isCompactRow) private var isCompact: Bool

            var body: some View {
                VStack {
                    if !isCompact {
                        ForEach(0..<indentationLevel, id: \\.self) { level in
                            Text("indent \\(level)")
                        }
                    }
                    Text("pad \\(40 + .statusColumnsSpacing)")
                    Text("scalars \\("héllo".unicodeScalars.count)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 5)
    }

    /// The map family accepts closures, KEY PATHS (\\.emojis), and
    /// unapplied function references (URL.init(string:)); Optional-style
    /// flatMap on strings; Locale.language chains.
    @Test func mapFamilyArgumentShapes() throws {
        let source = """
        struct Account {
            var emojis: [String]
        }

        struct ContentView: View {
            var body: some View {
                let accounts = [Account(emojis: ["a", "b"]), Account(emojis: ["c"])]
                let merged = accounts.flatMap(\\.emojis)
                let name: String? = "ice cubes"
                let url = name.flatMap(URL.init(string:))
                let upper = name.flatMap { $0.uppercased() }
                VStack {
                    Text("emojis \\(merged.count)")
                    Text(url == nil ? "no url" : "url")
                    Text(upper ?? "none")
                    Text(Locale.current.language.languageCode?.identifier ?? "und")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 5)
    }

    /// Enum custom inits run with a writable self (`self = .primary`,
    /// `self = .init(rawValue:)!`), Icon(rawValue:) works directly,
    /// unknowable subscripts read nil (Bundle info lookups), and
    /// SDK member views render opaquely.
    @Test func enumInitsUnknowableSubscriptsAndSDKViews() throws {
        let source = """
        enum Icon: Int, CaseIterable {
            case primary = 0
            case alt1, alt2

            init(string: String) {
                if string == "AppIcon" {
                    self = .primary
                } else {
                    self = .init(rawValue: Int(String(string.replacing("AppIconAlternate", with: "")))!)!
                }
            }
        }

        struct ContentView: View {
            var body: some View {
                let current = Icon(string: "AppIconAlternate2")
                let missing = Icon(rawValue: 99)
                let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                VStack {
                    Text("icon \\(current.rawValue)")
                    Text(missing == nil ? "no icon" : "found")
                    Text(version ?? "Unknown")
                    WishKit.FeedbackListView()
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 5)
    }

    /// Point-Free ecosystem operators: user-DECLARED operators fold and
    /// evaluate; EXTERNAL ones (Overture) recover with default precedence
    /// and get their universal semantics — |> / <| pipes, >>> / <<<
    /// composition. Plus bitwise ops, reduce(into:), and String HOFs.
    @Test func ecosystemOperatorsAndCollectionBreadth() throws {
        let source = """
        precedencegroup ForwardApplication {
            associativity: left
        }

        infix operator |>: ForwardApplication

        func |> <A, B>(a: A, f: (A) -> B) -> B {
            f(a)
        }

        struct ContentView: View {
            var body: some View {
                let doubled = 21 |> { $0 * 2 }
                let piped = { (n: Int) in n + 1 } <| 9
                let composed = { $0 + 1 } >>> { $0 * 10 }
                let masked = 0b1100 & 0b1010
                let counts = ["ab", "a"].reduce(into: [:]) { acc, word in
                    acc[word] = word.count
                }
                let score = "abc".reduce(0) { $0 + $1.count }
                VStack {
                    Text("doubled \\(doubled) piped \\(piped)")
                    Text("composed \\(composed(3))")
                    Text("masked \\(masked) score \\(score)")
                    Text("counts \\(counts.count)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 5)
    }

    /// C-interop reads as inert absorbers (snake_case / _dyld / malloc —
    /// the merge holds all the app's own Swift); delegating inits run on
    /// the same instance; utf8 views count; Data(bytes) is real; string
    /// ranges key dictionaries.
    @Test func cInteropDelegatingInitsAndByteViews() throws {
        let source = """
        final class Note {
            var content: String
            var kind: Int

            init(content: String, kind: Int) {
                self.content = content
                self.kind = kind
            }

            convenience init(content: String) {
                self.init(content: content, kind: 1)
            }
        }

        func hex_decode_id(_ str: String) -> Data? {
            guard str.utf8.count == 4 else { return nil }
            return Data([1, 2, 3, 4])
        }

        struct ContentView: View {
            var body: some View {
                let note = Note(content: "gm")
                let builder = ndb_builder_new()
                let buf = malloc(1024)
                let letters = ["A"..<"H": "warm", "H"..<"O": "cool"]
                VStack {
                    Text("kind \\(note.kind) \\(note.content)")
                    Text(hex_decode_id("abcd")?.count == 4 ? "decoded" : "no")
                    Text(builder.isReady ? "ready" : "fresh")
                    Text(buf == nil ? "nil buf" : "buf")
                    Text(letters["A"..<"H"] ?? "none")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 6)
    }

    /// Failable inits returning nil yield NIL (not a half-built
    /// instance); struct inits may reassign self; root synthesis prefers
    /// non-failable inits; Data(repeating:count:) is real.
    @Test func failableInitsAndSelfReassignment() throws {
        let source = """
        struct Pubkey {
            let id: Data

            init(_ data: Data) {
                self.id = data
            }

            init?(hex: String) {
                guard hex.count == 4 else { return nil }
                self = Pubkey(Data(repeating: 7, count: 2))
            }
        }

        struct RowView: View {
            let author: Pubkey

            var body: some View {
                let missing = Pubkey(hex: "")
                let reassigned = Pubkey(hex: "abcd")
                VStack {
                    Text("author bytes \\(author.id.count)")
                    Text(missing == nil ? "nil pubkey" : "have")
                    Text("reassigned \\(reassigned?.id.count ?? -1)")
                    Text("blob \\(Data(repeating: 0, count: 32).count)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 5)
    }

    /// The bech32-decoder machinery, self-contained: data(using:),
    /// Data(repeating:)/copy/subscript reads+writes/append, partial-range
    /// slices, scalar .value, compound ^=, annotation-labeled tuples, and
    /// shape-aware initializer choice (positional args never pick
    /// init?(hex:)).
    @Test func byteDecoderMachinery() throws {
        let source = """
        struct Wrapper {
            let id: Data

            init(_ data: Data) {
                self.id = data
            }

            init?(hex: String) {
                return nil
            }
        }

        func expand(_ s: String) -> Data {
            var left: [UInt8] = []
            for x in Array(s) {
                let scalars = String(x).unicodeScalars
                left.append(UInt8(scalars[scalars.startIndex].value) >> 5)
            }
            return Data(left)
        }

        func decode(_ str: String) -> (hrp: String, data: Data)? {
            guard let strBytes = str.data(using: .utf8) else { return nil }
            var values = Data(repeating: 0, count: 4)
            var chk = 1
            for i in 0..<4 {
                values[i] = UInt8(strBytes[i + 2])
                chk ^= Int(values[i])
            }
            var out = expand(String(str[..<str.index(str.startIndex, offsetBy: 2)]))
            out.append(Data(values[..<3]))
            return (String(str.prefix(2)), out)
        }

        struct ContentView: View {
            var body: some View {
                let decoded = decode("np1abcd")
                let wrapped = Wrapper(decoded!.data)
                VStack {
                    Text("hrp \\(decoded!.hrp)")
                    Text("bytes \\(decoded!.data.count) id \\(wrapped.id.count)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Delegated failable inits fail the WHOLE init (`self.init(…)`
    /// returning nil unwinds), and multi-file merges treat top-level
    /// globals as LAZY library globals (fixtures that force-unwrap
    /// device-only constructions never run unless referenced).
    @Test func delegatedInitFailureAndLazyLibraryGlobals() throws {
        let source = """
        final class Event {
            var content: String
            var signature: Data

            init?(content: String, sign: Bool) {
                guard sign else { return nil }
                self.content = content
                self.signature = Data(repeating: 1, count: 4)
            }

            convenience init?(content: String) {
                self.init(content: content, sign: false)
            }
        }

        let fixture = Event(content: "gm")!

        struct ContentView: View {
            var body: some View {
                let direct = Event(content: "hello", sign: true)
                let delegated = Event(content: "hello")
                VStack {
                    Text(direct == nil ? "no direct" : "signed \\(direct!.signature.count)")
                    Text(delegated == nil ? "delegated failed honestly" : "half-built!")
                }
            }
        }
        """
        // Merged-unit semantics: the force-unwrapping fixture is a lazy
        // library global — never referenced, never run.
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 3)
    }

    /// Custom property wrappers carry defaults in attribute arguments
    /// (@Setting(default_value:)); Task bodies swallow unhandled throws;
    /// property defaults that throw read unknowable; UUID members.
    @Test func wrapperDefaultsTaskThrowsAndUUIDs() throws {
        let source = """
        @propertyWrapper struct Setting<T> {
            var wrappedValue: T

            init(key: String, default_value: T) {
                self.wrappedValue = default_value
            }
        }

        enum Backend {
            case staging, production

            func url() -> String {
                self == .production ? "https://api.example.com" : "https://staging.example.com"
            }
        }

        class Settings {
            @Setting(key: "backend", default_value: Backend.production)
            var backend: Backend
        }

        struct SignedBlob {
            init() throws {
                throw CryptoError.needsDevice
            }
        }

        struct ContentView: View {
            let session = UUID()

            var body: some View {
                let settings = Settings()
                VStack {
                    Text(settings.backend.url())
                    Text("session \\(session.uuidString.count)")
                }
                .onAppear {
                    Task {
                        let blob = try SignedBlob()
                        _ = blob
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 3)
    }

    /// Properties typed by GENERIC PARAMETERS never synthesize as
    /// same-named concrete types (View-constrained params become fresh
    /// empty views); external-model projections absorb; CGFloat(marker)
    /// reads zero.
    @Test func genericParameterSynthesis() throws {
        let source = """
        struct Content: Codable {
            var pages: Int
        }

        struct AlertHost<Content: View>: View {
            let content: Content
            @StateObject var manager: ExternalAlertManager

            var body: some View {
                content
                    .opacity(manager.isPresented ? 0.5 : 1)
                    .offset(y: CGFloat(manager.offset))
            }
        }

        struct ContentView: View {
            var body: some View {
                AlertHost(content: Text("hosted"), manager: ExternalAlertManager())
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 2)
    }

    /// Default-less switches over unknowable subjects take the FIRST
    /// case (payload bindings read fresh chains); nil reads false in Bool
    /// positions; DI-container wrappers (@InjectedObservable) synthesize
    /// like environment objects, typed by annotation or keypath.
    @Test func unknowableSwitchesAndDIWrappers() throws {
        let source = """
        class NavigationManager: ObservableObject {
            var openedScreen: String = "home"
        }

        struct SidebarView: View {
            @InjectedObservable(\\.navigationManager) var navigationManager

            var body: some View {
                let phase = ExternalService.current.phase
                VStack {
                    switch phase {
                    case .loading(let progress):
                        Text("loading \\(progress)")
                    case .done:
                        Text("done")
                    }
                    Text(Bindable(navigationManager).openedScreen)
                    if ExternalService.current.maybeFlag {
                        Text("flagged")
                    } else {
                        Text("fresh flag")
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 3)
    }

    /// FileManager home/tmp map into the sandbox; URL.appending(path:)
    /// is the modern appendingPathComponent.
    @Test func sandboxHomeAndModernURLAppending() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let bottle = home.appending(path: "Bottles/win10")
                VStack {
                    Text(bottle.lastPathComponent)
                    Text(FileManager.default.fileExists(atPath: bottle.path) ? "exists" : "fresh")
                    Text(FileManager.default.temporaryDirectory.lastPathComponent)
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }

    /// objectWillChange.send() fires the change signal; generic-typed
    /// env objects strip generics; lazy members defer with self bound
    /// (sibling references); backticked enum cases normalize; .localized
    /// falls back to the key.
    @Test func observableLazyAndBacktickBreadth() throws {
        let source = """
        enum FontDesign: String {
            case `default`
            case serif

            var label: String {
                switch self {
                case .default: return "standard"
                case .serif: return "serif"
                }
            }
        }

        class Store<Item>: ObservableObject {
            var items: [String] = []

            func refresh() {
                items.append("refreshed")
                objectWillChange.send()
            }
        }

        class VaultManager {
            private let service = "com.example.vault"
            private lazy var vault = ExternalVault(service: service)

            func describe() -> String {
                "\\(vault)"
            }
        }

        struct ContentView: View {
            @EnvironmentObject var store: Store<String>

            var body: some View {
                let _ = store.refresh()
                let manager = VaultManager()
                VStack {
                    Text(FontDesign.default.label)
                    Text("ui.launch_at_login".localized())
                    Text("items \\(store.items.count)")
                    Text(manager.describe().isEmpty ? "no vault" : "vault made")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 5)
    }

    /// Global computed vars evaluate per read; static initializers and
    /// host-extension static methods see bare sibling statics;
    /// Thread.isMainThread is true; array allSatisfy + keypath filter.
    @Test func computedGlobalsAndStaticContexts() throws {
        let source = """
        var launchCount = 0

        var uptimeLabel: String {
            launchCount += 1
            return "run \\(launchCount)"
        }

        extension Logger {
            static let subsystem = "com.example.app"

            static func custom(category: String) -> Logger {
                return Logger(subsystem: subsystem, category: category)
            }

            static let network = custom(category: "network")
        }

        struct Game {
            var isInstalled: Bool
        }

        struct ContentView: View {
            var body: some View {
                let games = [Game(isInstalled: true), Game(isInstalled: false)]
                let installed = games.filter(\\.isInstalled)
                VStack {
                    Text(uptimeLabel)
                    Text(uptimeLabel)
                    Text(Thread.isMainThread ? "main" : "off-main")
                    Text(installed.allSatisfy(\\.isInstalled) ? "all installed" : "mixed")
                    Text("count \\(installed.count)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 6)
    }

    /// Delegation to inherited (host-superclass) designated inits binds
    /// labeled args as properties instead of self-delegating forever;
    /// bare statics assign inside static methods; unknowable bindings
    /// project detached members; chain-vs-concrete equality is false.
    @Test func inheritedDelegationAndStaticAssignment() throws {
        let source = """
        class SupportWindowController: NSWindowController {
            static var shared: SupportWindowController!

            convenience init() {
                let window = NSWindow()
                self.init(window: window)
            }

            static func show() {
                if shared == nil {
                    shared = SupportWindowController()
                }
            }
        }

        struct ContentView: View {
            @State private var viewModel: PlayAppVM?

            var body: some View {
                let _ = SupportWindowController.show()
                let settings = ExternalSDK.current.settings
                VStack {
                    Text(SupportWindowController.shared == nil ? "no window" : "window kept")
                    Text(settings.resolution == 0 ? "fresh res" : "custom res")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 3)
    }

    /// METHOD OVERLOADS pick by call shape — the Log idiom where
    /// `error(localized:)` forwards to `error(_ msg:)` must not
    /// self-recurse through a last-wins method table.
    @Test func methodOverloadDispatch() throws {
        let source = """
        class Log {
            static let shared = Log()
            var lines: [String] = []

            func error(_ msg: String) {
                lines.append("plain: \\(msg)")
            }

            func error(localized str: String, args: [String] = []) {
                error(String(format: str, arguments: args))
            }

            func error(code: Int) {
                error("code \\(code)")
            }
        }

        struct ContentView: View {
            var body: some View {
                let _ = {
                    Log.shared.error(localized: "boom %@", args: ["now"])
                    Log.shared.error(code: 7)
                }()
                VStack {
                    Text("lines \\(Log.shared.lines.count)")
                    Text(Log.shared.lines.first ?? "none")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 3)
    }

    /// Bodyless extern declarations absorb; marker member writes are
    /// accepted; typed-array ctors take repeating/count; @Default is
    /// state-like with fresh-identity values; sysctl family absorbs.
    @Test func externDeclsTypedArraysAndDefaults() throws {
        let source = """
        func GetProcessForPID(_ pid: Int, _ psn: Int) -> Int

        struct UpdaterView: View {
            @Default(.includeDevelopmentVersions) var includeDevelopmentVersions

            var body: some View {
                var size = 0
                let _ = sysctlbyname("kern.osproductversion", nil, &size, nil, 0)
                let buffer = [CChar](repeating: 0, count: 8)
                let _ = { NSWorkspace.shared.presentationOptions.someFlag = true }()
                let status = GetProcessForPID(1, 2)
                VStack {
                    Toggle("dev versions", isOn: $includeDevelopmentVersions)
                    Text("buf \\(buffer.count)")
                    Text(status == 0 ? "ok" : "fresh status")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 4)
    }

    /// Compiled-source mode (merged units): unresolved identifiers are
    /// unmerged imports and absorb; observer-only globals are stored;
    /// shadowing enum names fall through to registry constructors.
    @Test func compiledImportsObserverGlobalsAndShadowedState() throws {
        let source = """
        enum State {
            case downloaded, downloading
        }

        var hoveredID: String? = nil {
            didSet {
                scheduleHoverEffect(ms: 200)
            }
        }

        struct ContentView: View {
            @State private var fileInfo = State(initialValue: "manga.cbz")

            var body: some View {
                let _ = { hoveredID = "opt-1" }()
                let item = mainAsyncAfter(ms: 100) { }
                VStack {
                    Text(hoveredID ?? "none")
                    Text(fileInfo)
                    Text(item == nil ? "nil item" : "scheduled")
                    Text(State.downloaded == .downloaded ? "enum intact" : "clobbered")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 5)
    }

    /// Interpreted-superclass storage merges (BaseApp.url on PlayApp)
    /// and the in-run persistence round-trip: encode → write → read →
    /// decode returns the ORIGINAL value (config-reset loops terminate).
    @Test func inheritanceStorageAndPersistenceRoundTrip() throws {
        let source = """
        class BaseApp {
            let url: URL
            var name: String { url.lastPathComponent }

            init(url: URL) {
                self.url = url
            }
        }

        class PlayApp: BaseApp {
            var starred = false
        }

        struct Config: Codable {
            var order: [String]
        }

        class Store {
            let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("config.plist")

            var config: Config {
                get {
                    do {
                        let data = try Data(contentsOf: configURL)
                        return try PropertyListDecoder().decode(Config.self, from: data)
                    } catch {
                        return reset()
                    }
                }
                set {
                    if let data = try? PropertyListEncoder().encode(newValue) {
                        try? data.write(to: configURL)
                    }
                }
            }

            func reset() -> Config {
                config = Config(order: ["default"])
                return config
            }
        }

        struct ContentView: View {
            var body: some View {
                let app = PlayApp(url: URL(fileURLWithPath: "/apps/Genshin.app"))
                let store = Store()
                VStack {
                    Text(app.name)
                    Text(app.starred ? "starred" : "plain")
                    Text("order \\(store.config.order.count)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 4)
    }

    /// AppKit-shell top-level programs: NSApp.delegate writes accepted,
    /// NSApp.run() no-ops (the render pipeline is the run loop), and
    /// `_ = expr` discard assignments evaluate for effect.
    @Test func appKitShellTopLevel() throws {
        let source = """
        class AppDelegate: NSObject {
            var launched = false
        }

        let delegate = AppDelegate()
        let _ = NSApplication.shared

        struct ContentView: View {
            var body: some View {
                let _ = {
                    NSApplication.shared.delegate = delegate
                    NSApplication.shared.run()
                    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
                }()
                Text(delegate.launched ? "launched" : "shell ready")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// Host-superclass instance properties write/read (NSPanel.title);
    /// owner-scoped annotations pick the OWN nested enum over same-named
    /// globals; compiled-mode unknown members absorb after all dispatch.
    @Test func hostSuperclassPropsAndOwnerScopedAnnotations() throws {
        let source = """
        class EventTap {
            enum Location {
                case hidEventTap, sessionEventTap
            }
        }

        class IceBarPanel: NSPanel {
            func configure() {
                title = "Ice Bar"
                level = 3
            }

            var label: String {
                "\\(title)"
            }
        }

        struct EditorView: View {
            enum Location {
                case settings
                case popover
            }

            let location: Location

            var body: some View {
                let panel = IceBarPanel()
                let _ = panel.configure()
                VStack {
                    switch location {
                    case .settings: Text("settings pane")
                    case .popover: Text("popover pane")
                    }
                    Text(panel.label)
                    Text(panel.appearanceProxy.isDark ? "dark" : "fresh look")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 4)
    }

    /// Codable inits are decoder-only (never picked for construction or
    /// synthesis; enum positional args try raw-value matching);
    /// gateway numeric coercions absorb unresolved markers to zero.
    @Test func codableInitExclusionAndMarkerCoercion() throws {
        let source = """
        enum Kind: String, Codable {
            case logitechControl

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                self = Kind(rawValue: try container.decode(String.self)) ?? .logitechControl
            }
        }

        struct Mapping: Codable {
            var kind: Kind

            init(kind: Kind) {
                self.kind = kind
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.kind = try container.decode(Kind.self, forKey: .kind)
            }
        }

        struct SettingsView: View {
            let mapping: Mapping

            var body: some View {
                let window = ExternalWindow.shared
                let origin = CGPoint(x: window.frame.maxX - 10, y: window.frame.minY)
                VStack {
                    Text(mapping.kind == .logitechControl ? "logi" : "other")
                    Text("origin \\(origin.y)")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 3)
    }

    /// Overload selection promises only what binding can deliver: missing
    /// required labels are covered by UNLABELED trailing closures alone
    /// (IceSection's 4-param delegation must not pick the 5-param
    /// designated init); both-unknowable equality compares names.
    @Test func trailingClosureSelectionAndUnknowableEquality() throws {
        let source = """
        struct Section2<Header: View, Content: View, Footer: View>: View {
            let header: Header
            let content: Content
            let footer: Footer
            let spacing: CGFloat

            init(
                spacing: CGFloat = 10,
                @ViewBuilder header: () -> Header,
                @ViewBuilder content: () -> Content,
                @ViewBuilder footer: () -> Footer
            ) {
                self.spacing = spacing
                self.header = header()
                self.content = content()
                self.footer = footer()
            }

            init(
                _ title: String,
                spacing: CGFloat = 10,
                @ViewBuilder content: () -> Content
            ) where Header == Text, Footer == EmptyView {
                self.init(spacing: spacing) {
                    Text(title)
                } content: {
                    content()
                } footer: {
                    EmptyView()
                }
            }

            var body: some View {
                VStack(spacing: spacing) {
                    header
                    content
                    footer
                }
            }
        }

        struct ContentView: View {
            var body: some View {
                let probe = ExternalService.current
                VStack {
                    Section2("Permissions") {
                        Text("row")
                    }
                    Text(probe.shapeKind == .none ? "matched none" : "differs")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 5)
    }

    /// AttributedString attribute transforms carry text through;
    /// $binding.animation() returns the binding unchanged.
    @Test func attributeTransformsAndBindingAnimation() throws {
        let source = """
        struct ContentView: View {
            @State private var expanded = false

            var body: some View {
                var styled = AttributedString("hello world")
                let plain = styled.replacingAttributes(AttributeContainer(), with: AttributeContainer())
                VStack {
                    Toggle("Expand", isOn: $expanded.animation())
                    Text(plain)
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
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

    /// AlDente-Charge-Limiter (iteration 140): C interop inside a host-type
    /// extension body. Bare `uname(&info)` with self = a host object must
    /// reach the REAL registry cFunction (host hardware is real), not the
    /// trace registry's catch-all modifier table; EXIT_SUCCESS/_SYS_NAMELEN
    /// resolve as absorbing C constants; Data(bytes:count:) +
    /// String(bytes:encoding:) round-trip the filled struct field. The app
    /// delegate's launch hook seeds the singleton BEFORE the root renders,
    /// so the view's force-unwrap sees a non-nil platform key.
    @Test func cInteropInsideHostExtensionSeedsPlatformKey() throws {
        let source = """
        import AppKit

        extension ProcessInfo {
            var machineHardwareName: String? {
                var sysinfo = utsname()
                let result = uname(&sysinfo)
                guard result == EXIT_SUCCESS else { return nil }
                let data = Data(bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN))
                guard let identifier = String(bytes: data, encoding: .ascii) else { return nil }
                return identifier.trimmingCharacters(in: .controlCharacters)
            }
        }

        class Helper {
            static let instance = Helper()
            var platformKey: String?
            var appleSilicon: Bool?

            func setPlatformKey() {
                let s: String! = ProcessInfo.init().machineHardwareName
                if s != nil {
                    if s.elementsEqual("x86_64") {
                        platformKey = "intel"
                        appleSilicon = false
                    } else if s.elementsEqual("arm64") {
                        platformKey = "apple"
                        appleSilicon = true
                    }
                }
            }
        }

        class AppDelegate: NSObject, NSApplicationDelegate {
            func applicationDidFinishLaunching(_ notification: Notification) {
                Helper.instance.setPlatformKey()
            }
        }

        struct ContentView: View {
            var body: some View {
                Text(Helper.instance.appleSilicon! ? "AS" : "Intel")
                    .accessibilityLabel(Helper.instance.platformKey!)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// swift-composable-architecture (iteration 143): enums are namespaces
    /// as often as value types — `TestCase.Cases` is an enum NESTED inside
    /// an enum (the Integration app iterates
    /// `ForEach(TestCase.Cases.allCases)`). Nested types now collect into
    /// EnumSymbol and resolve as static members, qualified or bare.
    @Test func enumNestedTypesResolveAsStaticMembers() throws {
        let source = """
        public enum TestCase {
            case cases(Cases)
            case legacy(Legacy)

            public enum Cases: String, CaseIterable, Identifiable {
                case multipleAlerts = "Multiple alerts"
                public var id: Self { self }
            }

            public enum Legacy: String, CaseIterable, Identifiable {
                case ifLetStore = "IfLetStore"
                case navigationStack = "NavigationStack"
                public var id: Self { self }
            }

            static func firstCase() -> Cases { Cases.allCases.first! }
        }

        struct ContentView: View {
            var body: some View {
                List {
                    ForEach(TestCase.Cases.allCases) { test in
                        switch test {
                        case .multipleAlerts:
                            Text(test.rawValue)
                        }
                    }
                    ForEach(TestCase.Legacy.allCases) { test in
                        Text(test.rawValue)
                    }
                    Text(TestCase.firstCase().rawValue)
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 5)
    }

    /// isowords de-quarantined (iteration 184): Point-Free's `>=>`
    /// Kleisli composition — headlessly the monadic layer absorbs, so it
    /// composes like `>>>`.
    @Test func kleisliCompositionComposes() throws {
        let source = """
        func parse(_ raw: String) -> Int? { Int(raw) }
        func validate(_ n: Int?) -> String { (n ?? 0) > 0 ? "valid" : "invalid" }

        struct ContentView: View {
            var body: some View {
                let pipeline = parse >=> validate
                let checks = [
                    pipeline("42") == "valid",
                    pipeline("nope") == "invalid",
                ]
                if checks.contains(false) { fatalError("kleisli broke") }
                return Text(pipeline("7"))
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// session-ios (iteration 187): merged tooling SCRIPTS whose
    /// top-level statements throw or trap fail alone (their crash is the
    /// script's, not the app's); Double INTERVAL patterns match by
    /// containment (`case oneGigabyte...Double.greatestFiniteMagnitude:`);
    /// and `String.appending` is a real native so the optional-taking
    /// extension overload delegates instead of recursing.
    @Test func sessionScriptToleranceIntervalsAndAppending() throws {
        let source = """
        let doomed = try Data(contentsOf: URL(fileURLWithPath: "/definitely/missing/Package.resolved"))
        fatalError("Source file had no content")

        extension String {
            func appending(_ other: String?) -> String {
                guard let value: String = other else { return self }
                return self.appending(value)
            }
        }

        func fileSize(_ size: Double) -> String {
            switch size {
            case 1_073_741_824...Double.greatestFiniteMagnitude: return "GB"
            case 1_048_576...Double.greatestFiniteMagnitude: return "MB"
            default: return "B"
            }
        }

        struct ContentView: View {
            var body: some View {
                let checks = [
                    fileSize(2_000_000_000) == "GB",
                    fileSize(5_000_000) == "MB",
                    fileSize(12) == "B",
                    "session".appending(nil) == "session",
                    "file".appending(".txt") == "file.txt",
                ]
                if checks.contains(false) { fatalError("session classes broken") }
                return Text("ok")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// iTorrent (iteration 186): `(@MainActor() async -> Void)?` with no
    /// space is a formatting recovery Xcode accepts; and a file with HARD
    /// parse errors (editor placeholders, half-written members) can't be
    /// in any compiling target — the merge now drops such files
    /// universally, mirroring Xcode's target membership.
    @Test func attributeParenRecoveryAndHardErrorExclusion() throws {
        let root = NSTemporaryDirectory() + "hard-error-probe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try """
        class Overlay {
            var clickEvent: (@MainActor() async -> Void)?
            func fire() -> String { clickEvent == nil ? "idle" : "armed" }
        }

        struct ContentView: View {
            var body: some View { Text(Overlay().fire()) }
        }
        """.write(toFile: root + "/Overlay.swift", atomically: true, encoding: .utf8)
        try """
        class Abandoned {
            func f() {
                UserDefaults.standard.publisher(for: <#T##KeyPath<UserDefaults, Value>#>)
                notification.
            }
        }
        """.write(toFile: root + "/Abandoned.swift", atomically: true, encoding: .utf8)

        let merged = ProjectMaterial.mergedSource(at: root)
        #expect(!merged.contains("Abandoned"))
        #expect(merged.contains("clickEvent"))
        let report = try HeadlessVerifier.verify(source: merged, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// kiwix-apple (iteration 183): `super` in STATIC contexts — an
    /// NSManagedObject subclass's `static func fetchRequest()` delegates to
    /// `super.fetchRequest()`; the host superclass's statics absorb through
    /// a type marker, interpreted superclasses dispatch their real statics.
    @Test func staticContextSuper() throws {
        let source = """
        class Entity {
            static func fetchRequest() -> String { "entity request" }
        }

        class ZimFile: Entity {
            static func fetchRequest(predicate: String? = nil) -> String {
                let request = super.fetchRequest()
                return request + (predicate.map { "+\\($0)" } ?? "")
            }
        }

        class ManagedThing: NSManagedObject {
            static func fetchRequest(sorted: Bool) -> String {
                let request = super.fetchRequest()
                return request == nil ? "absorbed-nil" : "absorbed"
            }
        }

        struct ContentView: View {
            var body: some View {
                let checks = [
                    ZimFile.fetchRequest(predicate: "opened") == "entity request+opened",
                    ManagedThing.fetchRequest(sorted: true) == "absorbed",
                ]
                if checks.contains(false) { fatalError("static super broken") }
                return Text("ok")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// firefox-ios (iteration 182): LOCAL type declarations collect into
    /// the current scope (Danger scripts declare `struct FileCheck` inside
    /// a function); and BOTH-unknowable arithmetic yields a CHAIN for any
    /// operator — the domain is unknowable (array concat vs signal math),
    /// and a chain absorbs correctly downstream (for-in reads empty).
    @Test func localTypesAndBothMarkerChains() throws {
        let source = """
        func checkForCodeUsage() -> Int {
            struct FileCheck {
                let message: String
                var foundMatches: [String] = []
            }

            let check = FileCheck(message: "careful")
            let edited = danger.git.modifiedFiles + danger.git.createdFiles
            var seen = check.foundMatches.count
            for _ in edited { seen += 1 }
            return seen
        }

        struct ContentView: View {
            var body: some View {
                if checkForCodeUsage() != 0 { fatalError("both-marker chain broke") }
                return Text("dangerfile ok")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// apple-browsers (iteration 181): generated preview fixtures nest
    /// literals past SwiftParser's default ceiling — parsing gets 2048
    /// levels (evaluation has its own stack probe); and an interpreted
    /// throw ESCAPING the launch hook is an absorbed-environment failure
    /// (didFinishLaunching can't throw in compiled Swift).
    @Test func deepLiteralNestingAndHookThrowTolerance() throws {
        var literal = "Folder(children: ["
        for _ in 0..<120 { literal = "Folder(children: [" + literal }
        literal += "])"
        for _ in 0..<120 { literal += "])" }
        let source = """
        struct Folder { var children: [Folder] = [] }

        class AppDelegate: NSObject, NSApplicationDelegate {
            func applicationDidFinishLaunching(_ notification: Notification) {
                throw unmergedEnvironment.failure
            }
        }

        let fixture = \(literal)

        struct ContentView: View {
            var body: some View {
                Text("depth ok \\(fixture.children.count)")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// Planet at its honest root (iteration 180): GLOBAL function
    /// overloads pick by call shape with the running-declaration exclusion
    /// (L10n's variadic form delegates to its single-argument sibling —
    /// globals hold one closure per name, so a side table carries the
    /// set); and `Self.member = value` assigns statics from INSTANCE
    /// contexts (Self is the instance's type).
    @Test func globalOverloadsAndInstanceSelfStatics() throws {
        let source = """
        func L10n(_ key: String) -> String {
            key.uppercased()
        }

        func L10n(_ key: String, _ arguments: CVarArg...) -> String {
            String(format: L10n(key), arguments: arguments)
        }

        class PlanetStore {
            static var isSharedReady = false

            func setup() {
                Self.isSharedReady = true
            }
        }

        struct ContentView: View {
            var body: some View {
                PlanetStore().setup()
                let checks = [
                    L10n("hello") == "HELLO",
                    L10n("count %d", 3) == "COUNT %D" || L10n("count %d", 3).hasPrefix("COUNT"),
                    PlanetStore.isSharedReady == true,
                ]
                if checks.contains(false) { fatalError("global overloads broken") }
                return Text(L10n("done"))
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// Pearcleaner at its honest root (iteration 179): [RuntimeValue]
    /// bridges to NSObject and would smuggle interpreter boxes into
    /// Foundation — trampoline marshaling converts arrays ELEMENT-WISE
    /// first, so UserDefaults.set(stringArray, forKey:) genuinely
    /// round-trips; and UNMERGED environment-object types absorb (a bag
    /// stands in for the App shell's real injection).
    @Test func trampolineArraysAndUnmergedEnvModels() throws {
        let source = """
        struct SettingsView: View {
            @EnvironmentObject var updater: ExternalPackageUpdater

            var body: some View {
                let paths = ["/Applications", "/Users/me/Applications"]
                UserDefaults.standard.set(paths, forKey: "settings.folders.apps")
                let restored = UserDefaults.standard.stringArray(forKey: "settings.folders.apps") ?? []
                if restored.count != 2 { fatalError("plist round-trip broken: \\(restored.count)") }
                return Text("paths \\(restored.count)")
            }
        }

        struct ContentView: View {
            var body: some View { SettingsView() }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 2)
    }

    /// Rayon at its honest root (iteration 178): bare sibling STATICS are
    /// visible from any member context (an init parameter defaulting to
    /// `defaultBlurRadius`, a static let); and sibling app targets in a
    /// monorepo declaring the SAME namespace enum union their members
    /// (Rayon + mRayon both ship `enum UIBridge` — separate targets never
    /// collide on device).
    @Test func siblingStaticsAndNamespaceUnions() throws {
        let source = """
        enum UIBridge {
            static func open(url: URL) -> String { "opened" }
        }

        enum UIBridge {
            static func toggleSidebar() -> String { "toggled" }
        }

        struct GradientView: View {
            static let defaultBlurRadius: CGFloat = 64
            let blurRadius: CGFloat

            init(blurRadius: CGFloat = defaultBlurRadius) {
                assert(blurRadius > 0)
                self.blurRadius = blurRadius
            }

            var body: some View {
                Text("blur \\(blurRadius)")
            }
        }

        struct ContentView: View {
            var body: some View {
                let checks = [
                    UIBridge.toggleSidebar() == "toggled",
                    UIBridge.open(url: URL(string: "https://a.b")!) == "opened",
                ]
                if checks.contains(false) { fatalError("namespace union broken") }
                return GradientView()
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 2)
    }

    /// Basic-Car-Maintenance at its honest root (iteration 177): a
    /// PROPERTY/METHOD name collision — `var filteredReadings` beside
    /// `func filteredReadings(for:)`. A bare reference is the property
    /// when every method overload requires arguments; the labeled call
    /// still dispatches the method.
    @Test func propertyMethodCollisionsPreferPropertyBare() throws {
        let source = """
        struct Reading: Identifiable { let id: Int; let vehicleID: Int }

        struct OdometerView: View {
            let readings = [Reading(id: 1, vehicleID: 7), Reading(id: 2, vehicleID: 8)]

            private var filteredReadings: [Reading] { readings }

            private func filteredReadings(for vehicleID: Int) -> [Reading] {
                readings.filter { $0.vehicleID == vehicleID }
            }

            var body: some View {
                let scoped = filteredReadings(for: 7)
                if scoped.count != 1 { fatalError("method call broke") }
                return List {
                    ForEach(filteredReadings) { reading in
                        Text("reading \\(reading.id)")
                    }
                }
            }
        }

        struct ContentView: View {
            var body: some View { OdometerView() }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// EhPanda at its honest root (iteration 176): annotation-less
    /// bindings in a multi-binding declaration share the NEXT annotation
    /// in their run (`var igneous, memberID, passHash: String?` — all
    /// three are String?, nil until assigned); initializers break the run.
    @Test func multiBindingSharedAnnotations() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                var igneous, memberID, passHash: String?
                memberID = "123"

                var count = 1, label: String
                label = "ok"

                let checks = [
                    igneous == nil,
                    memberID == "123",
                    passHash == nil,
                    count == 1,
                    label == "ok",
                ]
                if checks.contains(false) { fatalError("shared annotations broken") }
                return Text(label)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// home-assistant at its honest root (iteration 175): the Section
    /// shadow's retry surfaced a seven-class chain — STATIC overloads pick
    /// by call shape; keypaths compare by components; `.map(Type.init)`
    /// constructs per element; TYPE-declared operator functions run with
    /// Comparable derivation (<= from <); tuples compare lexicographically;
    /// Info.plist loads REAL from a seeded sandbox file via real
    /// NSDictionary(contentsOf:); and NSRegularExpression is the REAL
    /// Foundation regex.
    @Test func homeAssistantHonestRootChain() throws {
        let source = """
        struct KioskRow {
            static func label(_ title: String, icon: String) -> String { "icon:" + title }
            static func label(_ title: String, systemSymbol: String) -> String { "symbol:" + title }
        }

        struct Version: Comparable {
            let major: Int, minor: Int, patch: Int
            static func < (lhs: Version, rhs: Version) -> Bool {
                (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
            }
        }

        struct Item { let name: String; init(_ name: String) { self.name = name } }

        struct ContentView: View {
            var body: some View {
                let picked = KioskRow.label("Preview", systemSymbol: "eye")
                let older = Version(major: 15, minor: 0, patch: 0)
                let newer = Version(major: 16, minor: 3, patch: 9)
                let items = ["a", "b"].map(Item.init)

                let url = Bundle.main.url(forResource: "Info.plist", withExtension: nil)
                let info = url.flatMap { NSDictionary(contentsOf: $0) as? [String: Any] }
                let version = (info?["CFBundleShortVersionString"] as? String) ?? "missing"

                let regex = NSRegularExpression(pattern: "([0-9]+)\\\\.([0-9]+)\\\\.([0-9]+)")
                let match = regex.firstMatch(in: version, range: NSRange(version.startIndex..., in: version))

                let checks = [
                    picked == "symbol:Preview",
                    older <= newer,
                    !(newer <= older),
                    (\\Version.major == \\Version.major),
                    items.count == 2 && items[0].name == "a",
                    version == "1.0.0",
                    match != nil,
                ]
                if checks.contains(false) { fatalError("honest-root chain broken") }
                return Text(version)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// SwiftBar + pocket-casts (iteration 174): DateFormatter.string(from:)
    /// with an UNKNOWABLE operand formats as the fresh string ("" — every
    /// string context's absorption); numeric intervals format as real
    /// epoch dates; real Dates format really.
    @Test func formatterAbsorbsUnknowableDates() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy"
                let fresh = formatter.string(from: unmergedClock.lastSyncDate)
                let real = formatter.string(from: Date(timeIntervalSince1970: 0))
                let checks = [
                    fresh == "",
                    real == "1970",
                ]
                if checks.contains(false) { fatalError("formatter absorption broken: \\(fresh)/\\(real)") }
                return Text(real)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// winston at its honest root (iteration 173): KEYED subscript
    /// assignment auto-vivifies the dictionary when the store is deferred,
    /// nil, or an absorbed marker (`self.routers[tab] = router` where
    /// `var routers: [Tab: Router]` initializes in an init the synthesis
    /// skipped) — and the caching-subscript idiom round-trips.
    @Test func keyedSubscriptAssignmentAutoVivifies() throws {
        let source = """
        enum Tab: String { case posts, inbox }

        class Router { var id = "router" }

        class Nav {
            private var routers: [Tab: Router]

            init() {
                routers = unmergedRestore.decode()
            }

            subscript(tab: Tab) -> Router {
                let router = self.routers[tab] ?? Router()
                if self.routers[tab] == nil { self.routers[tab] = router }
                return router
            }
        }

        struct ContentView: View {
            var body: some View {
                let nav = Nav()
                let first = nav[.posts]
                let second = nav[.posts]
                if first !== second { fatalError("cached router must round-trip") }
                return Text(first.id)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// swift-composable-architecture at its honest root (iteration 172):
    /// @Reducer on an enum GENERATES nested State/Action at compile time —
    /// macro artifacts the merge can't see. Uppercase misses on enum
    /// namespaces absorb as type markers (so State() builds a bag);
    /// lowercase misses chain.
    @Test func macroGeneratedNestedTypesAbsorb() throws {
        let source = """
        @Reducer
        public enum TicTacToe {
            case login(String)
            case newGame(Int)

            public static var body: Int { 0 }
        }

        struct ContentView: View {
            var body: some View {
                let initial = TicTacToe.State()
                let store = Store(initialState: initial) { TicTacToe.body }
                if store == nil { fatalError("absorbed store must be present") }
                return Text("game on")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// NetNewsWire at its honest root (iteration 171): `value is Type`
    /// really checks checkable shapes (primitives, interpreted symbols,
    /// host natives) and reads FALSE for unknowables (fresh
    /// UserDefaults.object is nothing yet); bare static COMPUTED setters
    /// assign under a type self (`firstRunDate = Date()` inside a
    /// property-initializer closure, the setter in a private extension).
    @Test func isExpressionsAndBareStaticSetters() throws {
        let source = """
        struct AppDefaults {
            static var stored: [String: Date] = [:]

            let isFirstRun: Bool = {
                if UserDefaults.standard.object(forKey: "firstRunDate") is Date {
                    return false
                }
                firstRunDate = Date()
                return true
            }()

            static var firstRunDate: Date? {
                get { stored["firstRunDate"] }
                set { stored["firstRunDate"] = newValue }
            }
        }

        struct ContentView: View {
            var body: some View {
                let defaults = AppDefaults()
                let checks = [
                    defaults.isFirstRun == true,
                    AppDefaults.firstRunDate != nil,
                    ("text" is String) == true,
                    (42 is Date) == false,
                    (Date() is Date) == true,
                ]
                if checks.contains(false) { fatalError("is/static-setter broken") }
                return Text("ok")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// MakeItSo + Mythic (iteration 170): enum-case ORDERED comparisons —
    /// synthesized Comparable orders by DECLARATION position (ignoring raw
    /// values); a bare unresolved `.member` on either side names a case of
    /// the other side's own symbol; numeric raws compare through numbers;
    /// anything else reads FALSE (fresh-state ordering).
    @Test func enumCaseOrderedComparisons() throws {
        let source = """
        enum Stage: String, Comparable {
            case welcome, onboarding, finished

            static func < (lhs: Stage, rhs: Stage) -> Bool {
                allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
            }
        }

        enum Priority: Int { case none = 0, low, high }

        struct ContentView: View {
            var body: some View {
                let stage = Stage.onboarding
                let checks = [
                    stage > Stage.welcome,
                    stage < .finished,
                    !(Stage.welcome > Stage.welcome),
                    Priority.high.rawValue > 0,
                ]
                if checks.contains(false) { fatalError("enum ordering broken") }
                return Text("ok")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// anytype-swift (iteration 169): generated NAMESPACE enums claim
    /// ubiquitous bare names (SwiftGen's Loc.Text) — when nothing
    /// enum-shaped fits the call, real overload resolution crosses the
    /// module boundary to SwiftUI's constructor. Void bases from absorbed
    /// chains accept member writes (the marker-write doctrine).
    @Test func namespaceEnumShadowsAndVoidWrites() throws {
        let source = """
        public enum Loc {
            public enum Text {
                public static var placeholder: String { "Untitled" }
            }
        }

        struct ContentView: View {
            var body: some View {
                var absorbedTrack = unmergedSequencer.tracks
                absorbedTrack.length = 4.0

                return VStack {
                    Text(verbatim: Loc.Text.placeholder)
                    Text("plain shadowed text")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 3)
    }

    /// home-assistant-ios (iteration 168): top-level `defer` runs at
    /// process exit on device — invisible to rendering, honestly skipped;
    /// an interpreted enum SHADOWING a host type crosses the module
    /// boundary for statics it doesn't declare (design-token `Color` vs
    /// SwiftUI.Color); and the protocol-defaults walk never re-enters the
    /// running overload (IconDrawable's image(ofSize:color:) delegating to
    /// the edgeInsets form).
    @Test func homeAssistantClasses() throws {
        let source = """
        defer { print("process exit cleanup") }

        enum Color {
            case brand
            static var tokens: [String] { ["brand"] }
        }

        protocol IconDrawable {}

        extension IconDrawable {
            func image(size: Int) -> Int {
                image(size: size, inset: 0)
            }

            func image(size: Int, inset: Int) -> Int {
                size + inset
            }
        }

        struct Icon: IconDrawable {}

        struct ContentView: View {
            var body: some View {
                let rendered = Icon().image(size: 24)
                let checks = [
                    rendered == 24,
                    Color.tokens.count == 1,
                ]
                if checks.contains(false) { fatalError("home-assistant classes broken") }
                return Text("ok").foregroundStyle(Color.secondary)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// iina (iteration 166): a guard-else ending in an ABSORBED
    /// Never-return (`exit(1)` in a merged helper tool) exits the scope as
    /// the compiler proved; STATIC-method overload sets never re-enter the
    /// running declaration (Logger.log's autoclosure convenience delegates
    /// to its closure-taking sibling).
    @Test func absorbedNeverReturnGuardsAndStaticDelegation() throws {
        let source = """
        struct Logger {
            static var lines: [String] = []

            static func log(_ message: @autoclosure () -> String, level: Int = 0) {
                log(message, level: level)
            }

            static func log(_ message: () -> String, level: Int) {
                lines.append(message())
            }
        }

        var launched = false
        func launcherMain() {
            guard FileManager.default.fileExists(atPath: "/nonexistent/iina") else {
                print("Cannot find IINA binary.")
                exit(1)
            }
            launched = true
        }

        struct ContentView: View {
            var body: some View {
                launcherMain()
                Logger.log("hello iina")
                let checks = [
                    launched == false,
                    Logger.lines.isEmpty == false,
                ]
                if checks.contains(false) { fatalError("iina classes broken") }
                return Text("ok")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// mastodon-ios (iteration 165): Sourcery inline-SCRATCH files hold
    /// bare method fragments meant for inlining elsewhere — hard parse
    /// errors prove a file is not a member of any compiling target, so the
    /// merge skips it (destination files with the same markers still merge:
    /// their inline blocks are real code inside extensions).
    @Test func sourceryScratchFragmentsAreNotProjectSource() throws {
        let root = NSTemporaryDirectory() + "sourcery-probe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try """
        // Generated using Sourcery — DO NOT EDIT
        // sourcery:inline:SomeDelegate.AutoGenerateProtocolDelegate
        notificationView(_ notificationView: NotificationView, menuButton button: UIButton)
        // sourcery:end
        """.write(toFile: root + "/AutoGenerate.generated.swift", atomically: true, encoding: .utf8)
        try """
        struct RealView: View {
            // sourcery:inline:RealView.Inlined
            var inlined: String { "compiled destination" }
            // sourcery:end
            var body: some View { Text(inlined) }
        }
        struct ContentView: View {
            var body: some View { RealView() }
        }
        """.write(toFile: root + "/RealView.swift", atomically: true, encoding: .utf8)

        let merged = ProjectMaterial.mergedSource(at: root)
        #expect(!merged.contains("menuButton"))
        #expect(merged.contains("compiled destination"))
        let report = try HeadlessVerifier.verify(source: merged, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// NetNewsWire + Cookbook (iteration 164): shebang lines strip in the
    /// merge (build-phase scripts are legal Swift after `#!`); marker
    /// ARITHMETIC reads unknowable operation-DSL sides as zero (AudioKit's
    /// `.phasor(f) * .randomNumberPulse(…)`, one- and two-sided); member
    /// WRITES through a nil base absorb in compiled mode
    /// (`sequencer.tracks[1].length = …` on a fresh store).
    @Test func shebangMarkerArithmeticAndNilWrites() throws {
        let root = NSTemporaryDirectory() + "shebang-probe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try """
        #!/usr/bin/swift
        let scriptConstant = 42
        """.write(toFile: root + "/BuildScript.swift", atomically: true, encoding: .utf8)
        try """
        struct ContentView: View {
            var body: some View {
                let signal = OperationDSL.phasor(frequency: 0.5) * OperationDSL.randomNumberPulse(minimum: 0.9)
                let offset = 0.0 + OperationDSL.jitter(amplitude: 300)
                var track = sequencerTracks.first
                track.length = 4.0
                if signal != 0 || offset != 0 { fatalError("marker arithmetic broke") }
                return Text("\\(scriptConstant)")
            }
        }
        """.write(toFile: root + "/ContentView.swift", atomically: true, encoding: .utf8)

        let merged = ProjectMaterial.mergedSource(at: root)
        #expect(!merged.contains("#!"))
        let report = try HeadlessVerifier.verify(source: merged, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// Gifski (iteration 163): TUPLE-pattern stored properties —
    /// `let (first, second, third): (A, B, C)` declares each element with
    /// its split annotation (Gifski's @dynamicMemberLookup Tuple3).
    @Test func tuplePatternStoredProperties() throws {
        let source = """
        struct Tuple3 {
            let (first, second, third): (Int, String, Bool)

            init(_ first: Int, _ second: String, _ third: Bool) {
                (self.first, self.second, self.third) = (first, second, third)
            }
        }

        struct ContentView: View {
            var body: some View {
                let triple = Tuple3(7, "seven", true)
                let checks = [
                    triple.first == 7,
                    triple.second == "seven",
                    triple.third == true,
                ]
                if checks.contains(false) { fatalError("tuple properties broken") }
                return Text(triple.second)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// IceCubesApp + Meshtastic (iteration 162): an ObjC-trampoline method
    /// whose encoding RETURNS an object but hands back nil IS nil — fresh
    /// UserDefaults has nothing persisted, so `object(forKey:) as? Bool`
    /// takes the else branch instead of binding ().
    @Test func trampolineNilObjectReturnsAreNil() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let sharedDefault = UserDefaults.standard
                var branch = "unset"
                if let alwaysUseDeepl = (sharedDefault.object(forKey: "always_use_deepl") as? Bool) {
                    branch = alwaysUseDeepl ? "deepl" : "api"
                } else {
                    branch = "fresh"
                }
                if branch != "fresh" { fatalError("fresh defaults must read nil, got \\(branch)") }
                return Text(branch)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// winston + OpenArtemis (iteration 161): formatting recoveries parse
    /// to a correct tree and are tolerated (`@Environment (\.colorScheme)`
    /// with a stray space builds in Xcode); unlabeled trailing closures
    /// bind by SE-0286 FORWARD scan — the first unbound function-typed
    /// parameter, not the last slot (`getNavigationView { … }` fills
    /// `content:` even when defaulted Bools follow).
    @Test func whitespaceRecoveryAndForwardScanTrailing() throws {
        let source = """
        struct ContentView: View {
            @Environment (\\.colorScheme) var colorScheme: ColorScheme

            func getNavigationView(
                content: () -> some View,
                shouldRespondToGlobalLinking: Bool = false,
                forceNonSplitStack: Bool = false
            ) -> some View {
                NavigationStack {
                    content()
                }
            }

            var body: some View {
                getNavigationView {
                    Text("feed")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// ACHNBrowserUI (iteration 159): `fallthrough` runs the NEXT case's
    /// body without re-matching — in plain statements and in view-builder
    /// switches (chained cases collect all their views).
    @Test func fallthroughRunsNextCase() throws {
        let source = """
        enum Effect { case lift, highlight, automatic }

        struct ContentView: View {
            var body: some View {
                let type = Effect.automatic
                var effect = ""
                switch type {
                case .lift:
                    effect = "lift"
                case .automatic:
                    fallthrough
                default:
                    effect = "default"
                }
                if effect != "default" { fatalError("fallthrough broke: \\(effect)") }

                return VStack {
                    switch type {
                    case .automatic:
                        Text("automatic")
                        fallthrough
                    default:
                        Text("shared footer")
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Sidekick (iteration 158): three classes — BACKTICKED statics on
    /// enums normalize (`static var \`default\``); static COMPUTED setters
    /// are assignable via Self./TypeName. (the UserDefaults-backed settings
    /// idiom); and protocol-extension members dispatch on enum cases
    /// (`extension RawRepresentable where Self: NotificationName`).
    @Test func sidekickClasses() throws {
        let source = """
        protocol NotificationName {
            var name: Notification.Name { get }
        }

        extension RawRepresentable where RawValue == String, Self: NotificationName {
            var name: Notification.Name {
                Notification.Name(self.rawValue)
            }
        }

        public enum Notifications: String, NotificationName {
            case changedInferenceConfig
        }

        enum ExpertManager {
            static var storage: [String] = []
            public static var `default`: String? { storage.first ?? "fresh" }

            public static var useServer: Bool {
                get {
                    if storage.isEmpty {
                        Self.useServer = false
                    }
                    return storage.contains("on")
                }
                set {
                    storage.append(newValue ? "on" : "off")
                }
            }
        }

        struct ContentView: View {
            var body: some View {
                let name = Notifications.changedInferenceConfig.name
                // Statics persist across the verifier's re-renders: only
                // the FIRST body evaluation asserts the fresh sequence.
                if ExpertManager.storage.isEmpty {
                    if ExpertManager.default != "fresh" { fatalError("default broke") }
                    if ExpertManager.useServer != false { fatalError("useServer broke") }
                    if ExpertManager.storage.count != 1 { fatalError("static write lost") }
                }
                return Text("\\(name)")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// Swiftfin (iteration 157): four classes from the 817-file Jellyfin
    /// client — `for case let x as T` patterns; `[keyPath:]` subscripts
    /// read AND write; same-labeled overloads disambiguate by the
    /// argument's array-ness/closure-ness; and a running init never
    /// re-enters itself (extension convenience inits delegate to the
    /// memberwise form — extension inits don't suppress it).
    @Test func swiftfinClasses() throws {
        let source = """
        struct ImageSource {
            var url: String? = nil
        }

        struct SeparatorHStack: View {
            var content: AnyView?
            var separator: AnyView?

            var body: some View {
                Text("stack")
            }
        }

        extension SeparatorHStack {
            init(
                @ViewBuilder separator: @escaping () -> some View,
                @ViewBuilder content: @escaping () -> some View
            ) {
                self.init(content: AnyView(content()), separator: AnyView(separator()))
            }
        }

        struct ContentView: View {
            var body: some View {
                var element = ImageSource()
                element[keyPath: \\.url] = element[keyPath: \\.url] ?? "https://jellyfin.org"
                let sources = [ImageSource(url: "a"), ImageSource(), element]
                    .filter { $0[keyPath: \\.url] != nil }

                let mixed: [Any] = ["one", 2, "three"]
                var strings: [String] = []
                for case let text as String in mixed {
                    strings.append(text)
                }

                let checks = [
                    sources.count == 2,
                    strings.count == 2,
                    element.url == "https://jellyfin.org",
                ]
                if checks.contains(false) { fatalError("swiftfin classes broken") }
                return VStack {
                    SeparatorHStack {
                        Divider()
                    } content: {
                        Text("row")
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// Pearcleaner + Applite (iteration 156): bitwise operators absorb
    /// unknowable flags to zero (kFSEventStreamCreateFlag… C constants
    /// from unmerged frameworks), and creating a directory at an
    /// UNKNOWABLE location is accepted inertly (fresh-sandbox analog) so
    /// DB-bootstrap chains don't fatalError where the device succeeds.
    @Test func bitwiseAbsorbAndInertDirectoryCreation() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
                if flags != 0 { fatalError("unknowable flags must read zero") }

                do {
                    let dbDir = LibraryPaths.databaseDirectory
                    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
                } catch {
                    fatalError("Failed to open database: \\(error)")
                }
                return Text("booted")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// Meshtastic-Apple (iteration 155): three classes — a protobuf
    /// `struct Link` shadows SwiftUI's Link, but no init fits
    /// `Link(destination:label:)`, so overload resolution crosses the
    /// module boundary to the registry constructor; overflow operators
    /// (`&*`, `&+`, `&-`) wrap like real Swift; and CYCLIC object graphs
    /// (protobuf parent/child links) describe with elision instead of
    /// recursing to death.
    @Test func crossModuleLinkOverflowOpsAndCyclicDescribe() throws {
        let source = """
        struct Link {
            var uid: String = ""
            var callsign: String = ""
            var next: [Link] = []
        }

        struct ContentView: View {
            var body: some View {
                var hash = 1_469_598_103_934_665_603
                hash = (hash &* 1_099_511_628_211) &+ 7
                if hash == 0 { fatalError("wrapping arithmetic broke") }

                var a = Link(uid: "a")
                let b = Link(uid: "b", next: [a])
                a.next = [b]
                let text = "\\(a)"
                if text.isEmpty { fatalError("describe broke") }

                return VStack {
                    Link(destination: URL(string: "meshtastic:///settings/about")!) {
                        Text("About")
                    }
                    Text(String(hash))
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// nos (iteration 154): two classes — a () in member position under
    /// compiled imports is a SYNTHESIS gap (a `@Dependency(\.analytics)`
    /// property on a non-view class that nothing injected) and absorbs;
    /// and modifier chains hanging off an unresolved root (an unmerged
    /// asset extension's `.atSymbol` with view modifiers) render as
    /// opaque leaf nodes named for the root.
    @Test func voidMembersAbsorbAndMarkerChainsRenderOpaque() throws {
        let source = """
        @Observable class AppController {
            @ObservationIgnored @Dependency(\\.analytics) private var analytics

            init() {
                analytics.trackInstallationSourceIfNeeded()
            }
        }

        struct ContentView: View {
            let controller = AppController()

            var body: some View {
                VStack {
                    Image.atSymbol
                        .aspectRatio(2, contentMode: .fit)
                        .blendMode(.softLight)
                    Text("nos")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 3)
    }

    /// Harbour (iteration 153): two classes — an unknown member on a
    /// NATIVE in compiled mode is an UNMERGED-package extension
    /// (`query.isReallyEmpty` from a utility dependency) and absorbs like
    /// the interpreted-instance rule; and LOCAL computed vars evaluate
    /// their getter once at declaration, in the current scope.
    @Test func nativeMemberAbsorbAndLocalComputedVars() throws {
        let source = """
        struct StacksView: View {
            var query = "portainer"

            var body: some View {
                var placement: String {
                    #if os(iOS)
                    "navigation"
                    #else
                    "primaryAction"
                    #endif
                }
                let filtered = query.isReallyEmpty ? "all" : query
                return VStack {
                    Text(placement)
                    Text(filtered)
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 3)
    }

    /// reminders-menubar (iteration 152): five classes — VARIADIC
    /// parameters (`arguments: CVarArg...` binds present-or-empty);
    /// force-unwrap LVALUES (`components.hour! += 1`); a nil STORED
    /// closure property sharing a modifier's name can't be called, so the
    /// registry modifier applies (`.onSubmit { }` on a Representable);
    /// mutating `replaceSubrange`; `Range(_:in:)` real conversion where
    /// marker NSRanges honestly fail.
    @Test func remindersMenubarClasses() throws {
        let source = """
        func localized(_ key: String, arguments: CVarArg...) -> String {
            if arguments.isEmpty {
                return key
            }
            return key + "+\\(arguments.count)"
        }

        struct FieldView: NSViewRepresentable {
            var onSubmit: (() -> Void)?

            func makeNSView(context: Context) -> NSTextField { NSTextField() }
            func updateNSView(_ view: NSTextField, context: Context) {}
        }

        struct ContentView: View {
            var body: some View {
                var components = Calendar.current.dateComponents([.hour], from: Date())
                components.hour! += 1

                var title = "high priority task"
                if let range = title.range(of: "high ") {
                    title.replaceSubrange(range, with: "")
                }

                let parsed: Range<String.Index>? = Range(NSRange(location: 99, length: 99), in: "ab")

                let checks = [
                    localized("plain") == "plain",
                    localized("fmt", arguments: 1, 2) == "fmt+2",
                    title == "priority task",
                    parsed == nil,
                    components.hour != nil,
                ]
                if checks.contains(false) { fatalError("reminders classes broken") }
                return VStack {
                    FieldView()
                        .onSubmit { }
                    Text(title)
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Maccy (iteration 151): library key-value stores with DECLARED key
    /// defaults (sindresorhus/Defaults). A fresh store answers the key's
    /// `default:` argument — `Defaults[.windowSize]` is NSSize(450, 800),
    /// and labeled ctor args round-trip through the catch-all bags so
    /// `.width` reads 450. Writes remember within the run. Int promotes
    /// for `.rounded()`.
    @Test func declaredDefaultStoresReadAndWrite() throws {
        let source = """
        extension Defaults.Keys {
            static let windowSize = Key<NSSize>("windowSize", default: NSSize(width: 450, height: 800))
            static let previewWidth = Key<CGFloat>("previewWidth", default: 290)
        }

        struct ContentView: View {
            var body: some View {
                let width = Defaults[.windowSize].width
                Defaults[.previewWidth] = 333
                let readBack = Defaults[.previewWidth]
                let rounded = max(200, width).rounded()
        let additions = (Bundle.main.mystery ?? []) + ["added"]
                let checks = [
                    width == 450,
                    readBack == 333,
                    rounded == 450,
                    additions == ["added"],
                ]
                if checks.contains(false) { fatalError("declared-default store broken") }
                return Text("ok")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// CopilotForXcode (iteration 150): local DI-wrapper declarations
    /// (`@Dependency(\.pool) var pool` in an init) resolve a fresh shared
    /// instance of the keypath'd type; Bundle.main is the REAL process
    /// bundle so path-climbing idioms terminate; Optional flatMap accepts
    /// function references.
    @Test func localDependencyRealBundleAndFunctionRefTransforms() throws {
        let source = """
        class WorkspacePool {
            var name = "pool"
        }

        func locateHostBundleURL(url: URL) -> URL? {
            var nextURL = url
            while nextURL.path != "/" {
                nextURL = nextURL.deletingLastPathComponent()
                if nextURL.lastPathComponent.hasSuffix(".app") {
                    return nextURL
                }
            }
            return nil
        }

        struct ContentView: View {
            var body: some View {
                @Dependency(\\.workspacePool) var workspacePool
                let hostBundle = locateHostBundleURL(url: Bundle.main.bundleURL)
                    .flatMap(Bundle.init(url:))
                let label = workspacePool.name
                return Text(label)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// Iteration 150's crash class: CYCLIC lazy-global initializers
    /// (`let a = b.tail; let b = a.head` in a merged unit) used to
    /// overflow the native stack through marker-graph resolution — they
    /// must surface as a LOCATED error, never a crash.
    @Test func lazyGlobalCyclesErrorInsteadOfCrashing() throws {
        let source = """
        let alpha = beta.tail
        let beta = alpha.head

        struct ContentView: View {
            var body: some View {
                Text("\\(alpha) \\(beta)")
            }
        }
        """
        do {
            _ = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        } catch {
            // An error is acceptable; crashing the process is not.
        }
    }

    /// Pulse (iteration 149): four classes from kean's logging framework —
    /// LOCAL typealias statements bind the target type in scope; clock
    /// idioms absorb numerically (`.now + .milliseconds(500)` = 0.5 — time
    /// anchors read the fresh epoch, durations read their seconds); Set
    /// algebra on the array-backed model; Optional.map applies the closure
    /// to a non-nil native (`url.map { … }`).
    @Test func typealiasClockSetAlgebraAndOptionalMap() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                typealias Numbers = Array
                let evens = [2, 4, 6]
                let odds = [1, 3]

                let deadline = .now + .milliseconds(500)
                let url = URL(string: "https://kean.blog/pulse")!
                let doubled = 21.map { $0 * 2 }
                let mapped = url.map { _ in "mapped" }

                let checks = [
                    evens.subtracting([4]).count == 2,
                    evens.union(odds).count == 5,
                    evens.intersection([4, 6, 8]).count == 2,
                    evens.symmetricDifference([6, 8]).count == 3,
                    deadline == 0.5,
                    doubled == 42,
                    mapped == "mapped",
                ]
                if checks.contains(false) { fatalError("pulse classes broken") }
                return Text("ok")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// MochiDiffusion (iteration 148): three URL/Observation classes —
    /// mutating `url.append(path:directoryHint:)` writes through the lvalue;
    /// `url.path(percentEncoded:)` (METHOD) collides with the legacy `path`
    /// property and resolves by call shape; `$store.computed` binds through
    /// the accessors (Observation's access/withMutation idiom) and writes
    /// reach the backing storage.
    @Test func urlMutationAndComputedModelBindings() throws {
        let source = """
        @Observable
        final class Gallery {
            var _sort: String = "oldest"
            var sortType: String {
                get { _sort }
                set { _sort = newValue }
            }
        }

        struct ContentView: View {
            @Bindable var store = Gallery()

            var body: some View {
                var url = FileManager.default.homeDirectoryForCurrentUser
                url.append(path: "mochi/images", directoryHint: .isDirectory)
                let raw = url.path(percentEncoded: false)
                if !raw.hasSuffix("mochi/images") { fatalError("append/path broken: \\(raw)") }

                let binding = $store.sortType
                binding.wrappedValue = "newest"
                if store._sort != "newest" { fatalError("computed binding write lost") }

                return Text(store.sortType)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// UTM (iteration 147): a user View-extension OVERLOAD of a SwiftUI
    /// modifier delegates to the framework form — `onReceive(_ name:
    /// Notification.Name…)` calling `self.onReceive(publisher…)`. Real
    /// overload resolution picks SwiftUI's; ours re-entered the user method
    /// forever. Re-entrant same-name dispatch now prefers the registry
    /// gateway — while helpers with NO gateway alternative still recurse.
    @Test func modifierOverloadDelegatesToGatewayNotItself() throws {
        let source = """
        extension View {
            func onReceive(_ name: Notification.Name,
                           center: NotificationCenter = .default,
                           object: AnyObject? = nil,
                           perform action: @escaping (Notification) -> Void) -> some View {
                self.onReceive(
                    center.publisher(for: name, object: object), perform: action
                )
            }
        }

        extension Int {
            func fib() -> Int {
                self < 2 ? self : ((self - 1).fib() + (self - 2).fib())
            }
        }

        struct ContentView: View {
            var body: some View {
                if 10.fib() != 55 { fatalError("recursive extension helper broken") }
                return Text("listening")
                    .onReceive(Notification.Name("UTMDidChange")) { _ in }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// swift-composable-architecture (iteration 146): TCA's IfLetStore shim
    /// calls the compiler-reserved builder statics AS API —
    /// `ViewBuilder.buildEither(first:)`/`(second:)` wrap _ConditionalContent
    /// that is invisible to rendering; the argument IS the view.
    @Test func explicitViewBuilderStaticsPassThrough() throws {
        let source = """
        struct ContentView: View {
            var showFirst = true

            var content: AnyView {
                if showFirst {
                    return ViewBuilder.buildEither(first: Text("first branch"))
                } else {
                    return ViewBuilder.buildEither(second: Text("second branch"))
                }
            }

            var body: some View {
                VStack {
                    content
                    ViewBuilder.buildBlock(Text("block"))
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// swift-composable-architecture (iteration 145): `@Perception.Bindable
    /// var store` — @Bindable (module-qualified or bare) wraps an observable
    /// reference type; `$store.field` projects a binding into the model's
    /// own box, and writes through it notify.
    @Test func bindableProjectsModelBindings() throws {
        let source = """
        @Observable
        class CounterModel {
            var count = 0
            var name = "counter"
        }

        struct ContentView: View {
            @Perception.Bindable var model = CounterModel()

            var body: some View {
                VStack {
                    Text("\\(model.count)")
                    TextField("Name", text: $model.name)
                    Button("Bump") { model.count += 1 }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
        #expect(report.actionsInvoked >= 1)
    }

    /// swift-composable-architecture (iteration 144): `store.count
    /// .description` — CustomStringConvertible is universal; every stdlib
    /// value prints (Int, Double, Bool). String's own member still wins.
    @Test func descriptionIsUniversal() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let checks = [
                    (5).description == "5",
                    (2.5).description == "2.5",
                    true.description == "true",
                    "text".description == "text",
                ]
                if checks.contains(false) { fatalError("description broken") }
                return Text(42.description)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// Rayon + OnlySwitch (iteration 143): registering enum nested types
    /// un-absorbed real code paths and exposed three adjacent gaps —
    /// operator-function references (`reduce(0, +)`, `sorted(by: >)`),
    /// `localizedDescription` on interpreted Error enums (LocalizedError's
    /// errorDescription wins, NSError boilerplate otherwise), and the
    /// `exactly:`-labeled numeric constructors.
    @Test func unabsorbedAdjacents() throws {
        let source = """
        enum ImportError: LocalizedError {
            case invalidURL
            case tooBig

            var errorDescription: String? {
                switch self {
                case .invalidURL: return "Invalid QR scan result"
                case .tooBig: return nil
                }
            }
        }

        enum PlainError: Error { case oops }

        struct ContentView: View {
            var body: some View {
                let weights: [Double] = [1, 2, 3.5]
                let total = weights.reduce(0, +)
                let top = weights.sorted(by: >).first!
                let scaled = (CGFloat(exactly: total) ?? 0) * 2
                let whole = Int(exactly: 6.5)
                let checks = [
                    total == 6.5,
                    top == 3.5,
                    scaled == 13,
                    whole == nil,
                    ImportError.invalidURL.localizedDescription == "Invalid QR scan result",
                    !PlainError.oops.localizedDescription.isEmpty,
                ]
                if checks.contains(false) { fatalError("unabsorbed adjacents broken") }
                return Text("ok")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// swift-composable-architecture (iteration 142): `macro` declarations
    /// (freestanding and attached, TCA declares both) are compile-time
    /// constructs — the runtime image holds no entity, so the interpreter
    /// treats the declarations as no-ops instead of "unsupported
    /// declaration (macroDecl)".
    @Test func macroDeclarationsAreCompileTimeNoOps() throws {
        let source = """
        @freestanding(expression)
        public macro exampleURL(_ stringLiteral: String) -> String =
            #externalMacro(module: "Macros", type: "URLMacro")

        @attached(member, names: arbitrary)
        @attached(extension, conformances: Reducer)
        public macro Reducer() =
            #externalMacro(module: "ComposableArchitectureMacros", type: "ReducerMacro")

        struct ContentView: View {
            var body: some View {
                Text("macros are inert")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// swift-composable-architecture (iteration 141): DocC catalogs hold
    /// tutorial SNIPPETS — intentionally elided, non-compiling code
    /// (`store.send(\\.addSyncUp…)` with a literal ellipsis). SwiftPM
    /// registers `.docc` bundles as documentation resources, never compile
    /// sources, so the project merge must skip them too.
    @Test func doccCatalogSnippetsAreNotProjectSource() throws {
        let root = NSTemporaryDirectory() + "docc-merge-probe-\(UUID().uuidString)"
        let docc = root + "/Sources/App/Documentation.docc/Tutorials"
        try FileManager.default.createDirectory(atPath: docc, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "struct RealView: View { var body: some View { Text(\"real\") } }"
            .write(toFile: root + "/Sources/App/RealView.swift", atomically: true, encoding: .utf8)
        try "await store.send(\\.addSyncUp…)"
            .write(toFile: docc + "/Snippet-code-0009.swift", atomically: true, encoding: .utf8)

        let files = ProjectMaterial.swiftFiles(under: root)
        #expect(files.count == 1)
        #expect(files.first?.hasSuffix("RealView.swift") == true)
        let merged = ProjectMaterial.mergedSource(at: root)
        #expect(merged.contains("RealView"))
        #expect(!merged.contains("addSyncUp"))
        try HeadlessVerifier.verify(source: merged)
    }

    /// Mythic (iteration 140): a launch hook spawning an INTENTIONALLY
    /// infinite background cycle — `Task { while true { poll(); try? await
    /// Task.sleep } }` — is legitimate on device (it suspends concurrently).
    /// The synchronous harness parks the task after its slice; the main
    /// flow's budget must be untouched, so root init and rendering proceed.
    @Test func infiniteBackgroundTaskParksWithoutDrainingBudget() throws {
        let source = """
        import AppKit

        class Poller {
            static let shared = Poller()
            var polls = 0
            func poll() { polls += 1 }
        }

        class AppDelegate: NSObject, NSApplicationDelegate {
            func applicationDidFinishLaunching(_ notification: Notification) {
                Task(priority: .utility) {
                    while true {
                        Poller.shared.poll()
                        try? await Task.sleep(for: .seconds(300))
                    }
                }
            }
        }

        struct ContentView: View {
            var body: some View {
                Text(Poller.shared.polls > 0 ? "polled" : "never ran")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }

    /// String/Array `elementsEqual` are real members (AlDente branches on
    /// them) — absorbing them to chains would read false on BOTH platform
    /// comparisons and leave the key nil.
    @Test func elementsEqualComparesContents() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let checks = [
                    "arm64".elementsEqual("arm64"),
                    !"arm64".elementsEqual("x86_64"),
                    [1, 2, 3].elementsEqual([1, 2, 3]),
                    ![1, 2, 3].elementsEqual([1, 2]),
                ]
                if checks.contains(false) { fatalError("elementsEqual broken") }
                return Text("ok")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
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
