#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Darwin
import Foundation
import QuartzCore
import SwiftInterpreter
import SwiftUI
import SwiftUIBridge

/// Native progress indicators and transition layers use wall-clock Core
/// Animation even when model time is frozen. Snapshot the model-layer
/// presentation — exactly as the native twin does — so repeated captures of
/// the same semantic state are exact on both sides of the R2 board.
private func removeAnimations(from layer: CALayer) {
    layer.removeAllAnimations()
    layer.sublayers?.forEach(removeAnimations(from:))
}

private extension View {
    @ViewBuilder
    func hidingCaptureScrollEdgeEffects() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            scrollEdgeEffectHidden()
        } else {
            self
        }
    }
}

// IceCubesCheck is the IceCubes mission instrument (LOOP-ICECUBES.md).
// Expectations below come from the recorded Mastodon response bytes. The
// native twin emits the same values after decoding them with IceCubes' real
// Models package; no author/content/count expectation is invented here.

private struct RungRecord: Codable {
    let name: String
    let passed: Bool
    let message: String
}

private struct NativePaginationRecord: Codable {
    let initialVisibleStatusIDs: [String]
    let initialPageLoads: Int
    let finalPageLoads: Int
    let finalStatusCount: Int
    let appendedStatusID: String
    let appendedStatusBecameVisible: Bool
    let normalizedFixtureNames: [String]
    let interactionFixtureNames: [String]
}

private struct NativePaginationObservation {
    let record: NativePaginationRecord
    let normalizedFixtureDirectory: URL
}

private enum IceCubesCaptureScreen: String {
    case timeline
    case statusDetail = "status-detail"
    case accountHeader = "account-header"
    case media
    case tagsList = "tags-list"

    /// `status-detail` and `account-header` are driven from a status the TWIN
    /// picked and the endpoints it prepared, so they read the twin's output
    /// directory. `timeline`, `media` and `tags-list` are built from the
    /// checked-in replay fixtures alone — media attachments resolve to the
    /// replay protocol's one deterministic PNG, which no fixture directory
    /// supplies, and the trending tags are a recorded public response that
    /// needs nothing the twin prepares.
    var needsNativeFixtures: Bool {
        switch self {
        case .timeline, .media, .tagsList: false
        case .statusDetail, .accountHeader: true
        }
    }
}

private struct NativeScreenFixtureNames: Codable {
    let status: String
    let statusContext: String
    let account: String
    let featuredTags: String
    let accountStatuses: String
    let familiarFollowers: String
}

private struct NativeTwinScreenMetadata: Codable {
    let screenFixtures: NativeScreenFixtureNames
}

#if targetEnvironment(macCatalyst)
@MainActor
private final class IceCubesCheckAppDelegate:
    UIResponder, UIApplicationDelegate
{
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role)
    }
}

@MainActor
private struct IceCubesCatalystCaptureRoot: View {
    let directory: String
    let screen: IceCubesCaptureScreen
    let nativeFixtureDirectory: String?

    @State private var session: InterpreterRenderSession?
    @State private var started = false

    var body: some View {
        Group {
            if let session {
                session.view
            } else {
                Color.white
            }
        }
        .hidingCaptureScrollEdgeEffects()
        .frame(
            width: IceCubesCheckMain.screenSize.width,
            height: IceCubesCheckMain.screenSize.height)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .task {
            guard !started else { return }
            started = true
            await capture()
        }
    }

    private func capture() async {
        defer { NetworkBridge.policy = .absorbed }
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            // Pin the geometry BEFORE the content settles so the screen lays
            // out once, at the size it is scored at.
            _ = try await Self.captureRootView()
            let session = try IceCubesCheckMain.renderSession(
                for: screen,
                nativeFixtureDirectory: nativeFixtureDirectory)
            self.session = session

            let initialRenderRevision =
                session.renderActivity.bodyEvaluationCount
            var readiness = InterpreterCaptureReadiness(
                initialRenderRevision: initialRenderRevision)
            let settleDeadline =
                ContinuousClock.now.advanced(by: .seconds(1))
            repeat {
                try await Task.sleep(for: .milliseconds(50))
                readiness.observe(
                    runtimeActivity: session.interpreter.runtimeActivity,
                    renderActivity: session.renderActivity)
            } while ContinuousClock.now < settleDeadline

            let readinessDeadline =
                ContinuousClock.now.advanced(by: .seconds(30))
            while !readiness.isReadyForCapture
                && ContinuousClock.now < readinessDeadline
            {
                try await Task.sleep(for: .milliseconds(50))
                readiness.observe(
                    runtimeActivity: session.interpreter.runtimeActivity,
                    renderActivity: session.renderActivity)
            }
            guard readiness.isReadyForCapture else {
                throw RuntimeError(
                    message:
                        "Catalyst capture did not reach presentation readiness")
            }
            if ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1" {
                let activity = session.interpreter.runtimeActivity
                print(
                    "@@icecubes-capture-activity"
                        + " observedActive="
                        + "\(readiness.firstActiveRenderRevision != nil)"
                        + " initialRevision=\(initialRenderRevision)"
                        + " firstActiveRevision="
                        + "\(readiness.firstActiveRenderRevision.map(String.init) ?? "none")"
                        + " lastActiveRevision="
                        + "\(readiness.lastActiveRenderRevision.map(String.init) ?? "none")"
                        + " finalRevision="
                        + "\(session.renderActivity.bodyEvaluationCount)"
                        + " finalQuiescent=\(activity.isQuiescent)"
                        + " activeTasks=\(activity.activeTaskCount)"
                        + " scheduledTasks=\(activity.scheduledTaskCount)"
                        + " hostOperations="
                        + "\(activity.activeHostOperationCount)"
                        + " continuations="
                        + "\(activity.activeContinuationCount)")
                for request in NetworkBridge.requestLog {
                    print("@@icecubes-network \(request)")
                }
            }
            for entry in RenderDiagnostics.errors.prefix(20) {
                print("diagnostic\t\(entry.view)\t\(entry.error.message)")
            }

            let rootView = try await Self.captureRootView()
            guard let captureView = fixedSizeDescendant(in: rootView) else {
                throw RuntimeError(
                    message: "\(screen.rawValue) has no view at the scored"
                        + " size \(IceCubesCheckMain.screenSize); the window"
                        + " root is \(rootView.bounds.size). Capturing"
                        + " anything else rescales the screen — fix the"
                        + " capture, not the floor.")
            }
            removeAnimations(from: captureView.layer)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(
                size: IceCubesCheckMain.screenSize, format: format)
            // `drawHierarchy` is the only capture that materializes Catalyst
            // hosting-layer contents (an in-process `layer.render(in:)` draws
            // hosted SwiftUI content blank); serialization and animation
            // stripping keep its window-server round trip reproducible.
            let image = renderer.image { _ in
                captureView.drawHierarchy(
                    in: CGRect(
                        origin: .zero,
                        size: IceCubesCheckMain.screenSize),
                    afterScreenUpdates: true)
            }
            CaptureGeometryDump.record(format: format, product: image)
            // Dumped from the hierarchy the accepted PNG came from, matching
            // the twin: `drawHierarchy(afterScreenUpdates: true)` forces a
            // screen update, so geometry read before it is not necessarily
            // the geometry that was rasterized.
            CaptureGeometryDump.write(
                captureView: captureView,
                screen: screen.rawValue,
                directory: directory)
            guard let png = image.pngData() else {
                throw RuntimeError(
                    message: "Catalyst hierarchy produced no PNG")
            }
            let output = URL(fileURLWithPath: directory)
                .appendingPathComponent("\(screen.rawValue).png")
            try png.write(to: output, options: .atomic)
            print(
                "\(screen.rawValue)\t\(output.path)\t"
                    + "\(Int(IceCubesCheckMain.screenSize.width))x"
                    + "\(Int(IceCubesCheckMain.screenSize.height))")

            guard screen == .timeline else {
                exit(0)
            }
            guard let interpretedClockEpoch = session.interpreter.globals
                .lookup("__iceInterpretedClockEpoch")?.doubleValue
            else {
                throw RuntimeError(
                    message:
                        "interpreted capture clock did not materialize")
            }
            let metadata = CaptureMetadata(
                hostClockEpoch: Date().timeIntervalSince1970,
                interpretedClockEpoch: interpretedClockEpoch)
            let metadataOutput = URL(fileURLWithPath: directory)
                .appendingPathComponent("timeline.json")
            try JSONEncoder().encode(metadata).write(
                to: metadataOutput, options: .atomic)
            print("metadata\t\(metadataOutput.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("IceCubesCheck Catalyst: \(error)\n".utf8))
            exit(2)
        }
    }

    /// `drawHierarchy(in:)` SCALES whatever view it is handed into the
    /// destination rect, so a capture view that is not exactly the scored size
    /// yields a resampled picture rather than the app's own pixels — silently,
    /// because the result still looks like the screen. Measured 2026-08-04:
    /// `media` hosts no scroll view, so it had no descendant at the scored
    /// size and the capture fell back to the whole 1330x990 Catalyst window,
    /// squashed 0.677x0.707. Every pixel on that screen was an interpolation,
    /// which is why its residue sat entirely on antialiased edges and no
    /// in-process micro-twin could reproduce it.
    ///
    /// Pinning the SCENE to the scored size makes the window root itself an
    /// exact-size capture view on every screen, whatever that screen hosts,
    /// so the match below can be required instead of hoped for.
    private static func captureRootView() async throws -> UIView {
        let target = IceCubesCheckMain.screenSize
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var lastObserved: CGSize?
        while true {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            if let window =
                windows.first(where: \.isKeyWindow) ?? windows.first,
                let rootView = window.rootViewController?.view
            {
                if let restrictions = window.windowScene?.sizeRestrictions {
                    restrictions.minimumSize = target
                    restrictions.maximumSize = target
                }
                // The same appearance pin the twin applies, for the same
                // reason and in the same place — see the comment there. Both
                // sides must state it: pinning only one would trade a
                // divergence that depends on the host's Dark Mode setting for
                // one that is merely constant.
                window.overrideUserInterfaceStyle = .light
                rootView.setNeedsLayout()
                rootView.layoutIfNeeded()
                lastObserved = rootView.bounds.size
                if abs(rootView.bounds.width - target.width) < 0.5,
                    abs(rootView.bounds.height - target.height) < 0.5
                {
                    return rootView
                }
            }
            guard ContinuousClock.now < deadline else {
                throw RuntimeError(
                    message: "Catalyst window never reached the scored size"
                        + " \(target); last observed"
                        + " \(lastObserved.map(String.init(describing:)) ?? "no window")")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func fixedSizeDescendant(in view: UIView) -> UIView? {
        let delta = CGSize(
            width: abs(
                view.bounds.width - IceCubesCheckMain.screenSize.width),
            height: abs(
                view.bounds.height - IceCubesCheckMain.screenSize.height))
        if delta.width < 0.5, delta.height < 0.5 {
            return view
        }
        for child in view.subviews {
            if let match = fixedSizeDescendant(in: child) {
                return match
            }
        }
        return nil
    }
}

/// Interactive live run (`--run`): the interpreted IceCubesApp hosted in a
/// real resizable Catalyst window with `NetworkPolicy.live` — the "real HTTP
/// for interactive demo runs" case the policy documents. No capture, no
/// frozen clock, no exit; close the window to quit. Content is whatever the
/// live instance serves right now, so nothing here ever feeds a metric.
@MainActor
private struct IceCubesCatalystLiveRunRoot: View {
    var mini = false
    @State private var session: InterpreterRenderSession?
    @State private var failure: String?
    @State private var started = false

    var body: some View {
        Group {
            if let session {
                session.view
            } else if let failure {
                ScrollView {
                    Text(failure)
                        .font(.system(.footnote, design: .monospaced))
                        .padding()
                }
            } else {
                ProgressView("Interpreting IceCubesApp against live Mastodon…")
            }
        }
        .frame(
            width: IceCubesCheckMain.screenSize.width,
            height: IceCubesCheckMain.screenSize.height)
        .environment(\.colorScheme, .light)
        .background(Color.white)
        .task {
            guard !started else { return }
            started = true
            // Let the loading frame commit before the synchronous
            // interpretation occupies the main actor.
            try? await Task.sleep(for: .milliseconds(80))
            do {
                let arguments = Array(CommandLine.arguments.dropFirst())
                // mstdn.social (the twin's instance) still serves the public
                // timeline unauthenticated; mastodon.social answers 422.
                let miniSource = """
                import SwiftUI
                let __miniGreeting = "interpreted hello lazy"
                Text(__miniGreeting)
                    .font(.largeTitle)
                    .padding()
                    .background(Color.orange)
                """
                let miniWrapped = ProcessInfo.processInfo
                    .environment["ICECUBES_MINI_MODULE"] == "1"
                let session = mini
                    ? try InterpreterHost().renderSession(
                        source: miniWrapped
                            ? ProjectMaterial.mergedSource(
                                source: miniSource,
                                moduleName: "IceCubesCheckProbe")
                            : miniSource,
                        buildConfiguration: .init(
                            platformName: "iOS",
                            targetEnvironment: "macCatalyst"),
                        lazyTopLevelGlobals: ProcessInfo.processInfo
                            .environment["ICECUBES_MINI_LAZY"] == "1").get()
                    : try IceCubesCheckMain.liveAppRenderSession(
                        instance: IceCubesCheckMain.option(
                            "--instance", in: arguments) ?? "mstdn.social")
                self.session = session
                liveRunTrace("ready")
                for entry in RenderDiagnostics.errors.prefix(10) {
                    liveRunTrace(
                        "diagnostic \(entry.view): \(entry.error.message)")
                }
            } catch {
                failure = String(describing: error)
                liveRunTrace("FAILED: \(error)")
            }
            await writeDebugSnapshots()
        }
    }

    /// The process never exits, so stdout buffering would swallow evidence —
    /// trace through unbuffered stderr instead.
    private func liveRunTrace(_ message: String) {
        FileHandle.standardError.write(
            Data("@@icecubes-live-run \(message)\n".utf8))
    }

    /// Headless self-verification for driving the live window from a harness:
    /// with ICECUBES_RUN_SNAPSHOT=<path-prefix> set, periodically write the
    /// hosted hierarchy to <prefix>-<n>[-content].png and trace the UIKit
    /// tree, so "content exists but does not composite" and "content never
    /// materialized" are distinguishable. Demo-only — never a metric.
    private func writeDebugSnapshots() async {
        guard let prefix = ProcessInfo.processInfo
            .environment["ICECUBES_RUN_SNAPSHOT"] else { return }
        for index in 1...8 {
            try? await Task.sleep(for: .seconds(10))
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            guard let window =
                    windows.first(where: \.isKeyWindow) ?? windows.first,
                  let rootView = window.rootViewController?.view else {
                liveRunTrace("snapshot \(index): no live window")
                continue
            }
            let contentView = fixedSizeLiveDescendant(in: rootView)
            for (label, view) in [("", rootView), ("-content", contentView)] {
                guard let view else { continue }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let renderer = UIGraphicsImageRenderer(
                    size: view.bounds.size, format: format)
                let image = renderer.image { _ in
                    view.drawHierarchy(
                        in: view.bounds, afterScreenUpdates: true)
                }
                if let png = image.pngData() {
                    let path = "\(prefix)-\(index)\(label).png"
                    try? png.write(to: URL(fileURLWithPath: path))
                    liveRunTrace("snapshot \(index)\(label): \(path)")
                }
            }
            var lines: [String] = []
            traceHierarchy(rootView, depth: 0, lines: &lines)
            for line in lines.prefix(45) {
                liveRunTrace("tree[\(index)] \(line)")
            }
            for entry in RenderDiagnostics.errors.suffix(8) {
                liveRunTrace(
                    "renderError[\(index)] \(entry.view): "
                        + entry.error.message)
            }
        }
    }

    private func fixedSizeLiveDescendant(in view: UIView) -> UIView? {
        let target = IceCubesCheckMain.screenSize
        if abs(view.bounds.width - target.width) < 0.5,
           abs(view.bounds.height - target.height) < 0.5 {
            return view
        }
        for child in view.subviews {
            if let match = fixedSizeLiveDescendant(in: child) { return match }
        }
        return nil
    }

    private func traceHierarchy(
        _ view: UIView, depth: Int, lines: inout [String]
    ) {
        guard lines.count < 60, depth < 7 else { return }
        let name = String(describing: type(of: view))
        let f = view.frame
        lines.append(
            String(repeating: "  ", count: depth)
                + "\(name) frame=(\(Int(f.origin.x)),\(Int(f.origin.y)),"
                + "\(Int(f.width))x\(Int(f.height)))"
                + (view.isHidden ? " HIDDEN" : "")
                + (view.alpha < 0.99 ? " alpha=\(view.alpha)" : ""))
        for child in view.subviews {
            traceHierarchy(child, depth: depth + 1, lines: &lines)
        }
    }
}

@main
private struct IceCubesCheckCatalystApp: App {
    @UIApplicationDelegateAdaptor(IceCubesCheckAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        WindowGroup {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.contains("--run-mini") {
                // Minimal interpreted-content compositing probe: interprets
                // in under a second, so the windowed-hosting question is
                // answerable in one glance instead of a ten-minute cycle.
                IceCubesCatalystLiveRunRoot(mini: true)
            } else if arguments.contains("--run-native") {
                // Native-only compositing probe: if THIS does not paint, the
                // bundle's on-screen render path is broken and no interpreted
                // content can ever appear — fix the packaging first.
                VStack(spacing: 12) {
                    Text("native compositing OK")
                        .font(.largeTitle)
                    ProgressView()
                }
                .frame(width: 400, height: 300)
                .background(Color.yellow)
            } else if arguments.contains("--run") {
                IceCubesCatalystLiveRunRoot()
            } else {
                IceCubesCatalystCaptureRoot(
                    directory: IceCubesCheckMain.option(
                        "--capture", in: arguments)
                        ?? "/tmp/icecubes-interpreted",
                    screen: IceCubesCheckMain.captureScreen(in: arguments),
                    nativeFixtureDirectory: IceCubesCheckMain.option(
                        "--native-fixtures", in: arguments))
            }
        }
    }
}
#endif

private struct CaptureMetadata: Codable {
    let hostClockEpoch: TimeInterval
    let interpretedClockEpoch: TimeInterval
}

private struct FixtureAccount: Decodable {
    let username: String
    let displayName: String?
    let note: String

    var visibleName: String {
        guard let displayName, !displayName.isEmpty else { return username }
        return displayName
    }
}

private struct FixtureMedia: Decodable {
    let type: String
    let url: URL?
    let previewUrl: URL?
}

private struct FixtureReblog: Decodable {
    let content: String
    let account: FixtureAccount
    let mediaAttachments: [FixtureMedia]
}

private struct FixtureStatus: Decodable {
    let id: String
    let content: String
    let account: FixtureAccount
    let reblog: FixtureReblog?
    let mediaAttachments: [FixtureMedia]

    var visibleContent: String { reblog?.content ?? content }
    var visibleAccount: FixtureAccount { reblog?.account ?? account }
    var visibleMedia: [FixtureMedia] { reblog?.mediaAttachments ?? mediaAttachments }
}

private struct FixtureOracle {
    let publicStatuses: [FixtureStatus]
    let boostStatus: FixtureStatus
    let trendingStatuses: [FixtureStatus]

    init(directory: String) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        publicStatuses = try decoder.decode(
            [FixtureStatus].self,
            from: Data(contentsOf: URL(
                fileURLWithPath: directory + "/api_v1_timelines_public.json")))
        boostStatus = try decoder.decode(
            FixtureStatus.self,
            from: Data(contentsOf: URL(
                fileURLWithPath: directory
                    + "/api_v1_statuses_116954929935729788.json")))
        trendingStatuses = try decoder.decode(
            [FixtureStatus].self,
            from: Data(contentsOf: URL(
                fileURLWithPath: directory + "/api_v1_trends_statuses.json")))
    }

    static func rawText(_ html: String) -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        let rendered = try? NSAttributedString(
            data: Data(html.utf8), options: options,
            documentAttributes: nil).string
        return normalize(rendered ?? html.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression))
    }

    static func marker(_ html: String, words: Int = 8) -> String {
        rawText(html).split(whereSeparator: { $0.isWhitespace })
            .prefix(words).joined(separator: " ")
    }

    /// Native IceCubes renders Mastodon HTML through `HTMLString.asMarkdown`,
    /// which omits accessibility-hidden URL spans while preserving the text
    /// before the first link. Keep the detail oracle on that shared visible
    /// prefix instead of flattening hidden HTML into a string the view never
    /// displays.
    static func leadingTextMarker(_ html: String) -> String {
        let end = html.range(of: "<a", options: .caseInsensitive)?.lowerBound
            ?? html.endIndex
        return marker(String(html[..<end]))
    }

    static func normalize(_ string: String) -> String {
        string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

#if !targetEnvironment(macCatalyst)
@main
#endif
struct IceCubesCheckMain {
    // Keep the hard stop below the three-minute instrument contract while
    // leaving realistic headroom for the full-app shell under board load.
    private static let workerTimeout: TimeInterval = 175
    fileprivate static let screenSize = CGSize(width: 900, height: 700)

#if !targetEnvironment(macCatalyst)
    static func main() async throws {
        if ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] == nil {
            var environment = ProcessInfo.processInfo.environment
            environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = Array(CommandLine.arguments.dropFirst())
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        }

        let arguments = Array(CommandLine.arguments.dropFirst())
        if let captureDirectory = option("--capture", in: arguments) {
            try capture(
                captureScreen(in: arguments),
                to: captureDirectory,
                nativeFixtureDirectory:
                    option("--native-fixtures", in: arguments))
            return
        }
        if let worker = option("--worker", in: arguments),
           let result = option("--result", in: arguments)
        {
            let records: [RungRecord]
            do {
                records = try await runWorker(
                    worker,
                    nativeFixtureDirectory:
                        option("--native-fixtures", in: arguments))
            } catch {
                records = expectedRungs(for: worker).map {
                    RungRecord(name: $0, passed: false, message: "worker threw: \(error)")
                }
            }
            let data = try JSONEncoder().encode(records)
            try data.write(to: URL(fileURLWithPath: result), options: .atomic)
            return
        }

        if arguments.contains("--live") {
            try await runLiveBoard(
                instance: option("--instance", in: arguments)
                    ?? "mastodon.social")
            return
        }

        let filter = option("--screen", in: arguments)
        let jobs = [
            "shell", "timeline", "detail-account", "pagination", "row-tap",
            "tab-switch",
        ].filter { job in
            guard let filter else { return true }
            return expectedRungs(for: job).contains {
                $0.localizedCaseInsensitiveContains(filter)
            }
        }
        let nativePaths = try paths()
        let nativeOracle = try FixtureOracle(
            directory: nativePaths.fixtures)
        let native = try nativePaginationObservation(
            paths: nativePaths, oracle: nativeOracle)
        defer {
            try? FileManager.default.removeItem(
                at: native.normalizedFixtureDirectory)
        }
        var records: [RungRecord] = []
        records += runTimedWorkers(
            jobs,
            nativeFixtureDirectory:
                native.normalizedFixtureDirectory.path)
        if let filter {
            records = records.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }

        for record in records {
            if record.passed {
                print("✅ \(record.name)")
            } else {
                print("❌ \(record.name)  \(record.message)")
            }
        }
        let passed = records.filter(\.passed).count
        print("═══ IceCubesCheck: \(passed)/\(records.count) rungs ═══")
        let failures = records.filter { !$0.passed }
        if !failures.isEmpty {
            print("\nfailure classes (fix the biggest first):")
            for failure in failures {
                print("   \(failure.name): \(failure.message.prefix(240))")
            }
            // The north star reports its own health through its exit status,
            // exactly as the LIVE board already does — a red rung must be
            // able to fail a gate rather than scroll past in a log.
            exit(1)
        }
    }
#endif

    fileprivate static func option(
        _ name: String, in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    fileprivate static func captureScreen(
        in arguments: [String]
    ) -> IceCubesCaptureScreen {
        option("--screen", in: arguments)
            .flatMap(IceCubesCaptureScreen.init(rawValue:))
            ?? .timeline
    }

    private static func expectedRungs(for worker: String) -> [String] {
        switch worker {
        case "shell":
            return ["R0-shell"]
        case "timeline":
            return [
                "R1-timeline", "R1-boost-attribution",
                "R1-media-placeholder",
            ]
        case "detail-account":
            return ["R1-status-detail", "R1-account-header"]
        case "pagination":
            return ["R3-pagination"]
        case "row-tap":
            return ["R3-row-tap-detail"]
        case "tab-switch":
            return ["R3-tab-switch"]
        default:
            return ["unknown-worker"]
        }
    }

#if !targetEnvironment(macCatalyst)
    private struct TimedWorker {
        let name: String
        let process: Process
        let resultURL: URL
        let deadline: Date
    }

    /// Each screen remains process-isolated, but independent screens run
    /// concurrently so deeper real lifecycle coverage does not make the
    /// complete deterministic board exceed its three-minute contract.
    private static func runTimedWorkers(
        _ workers: [String],
        nativeFixtureDirectory: String
    ) -> [RungRecord] {
        var launched: [TimedWorker] = []
        var recordsByWorker: [String: [RungRecord]] = [:]
        for worker in workers {
            let resultURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(
                    "icecubes-check-\(UUID().uuidString).json")
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [
                "--worker", worker, "--result", resultURL.path,
                "--native-fixtures", nativeFixtureDirectory,
            ]
            process.environment = ProcessInfo.processInfo.environment
            do {
                try process.run()
                launched.append(TimedWorker(
                    name: worker,
                    process: process,
                    resultURL: resultURL,
                    deadline: Date().addingTimeInterval(workerTimeout)))
            } catch {
                recordsByWorker[worker] = expectedRungs(for: worker).map {
                    RungRecord(
                        name: $0, passed: false,
                        message: "could not start worker: \(error)")
                }
            }
        }

        while launched.contains(where: {
            $0.process.isRunning && Date() < $0.deadline
        }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        for worker in launched {
            let process = worker.process
            defer { try? FileManager.default.removeItem(at: worker.resultURL) }
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning, Date() < grace {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                recordsByWorker[worker.name] = expectedRungs(
                    for: worker.name).map {
                    RungRecord(
                        name: $0, passed: false,
                        message: "\(worker.name) screen worker exceeded \(Int(workerTimeout))s")
                }
                continue
            }

            guard process.terminationStatus == 0,
                  let data = try? Data(contentsOf: worker.resultURL),
                  let records = try? JSONDecoder().decode(
                    [RungRecord].self, from: data)
            else {
                recordsByWorker[worker.name] = expectedRungs(
                    for: worker.name).map {
                    RungRecord(
                        name: $0, passed: false,
                        message: "\(worker.name) worker exited \(process.terminationStatus) without a result")
                }
                continue
            }
            recordsByWorker[worker.name] = records
        }
        return workers.flatMap { recordsByWorker[$0] ?? [] }
    }
    private static func runWorker(
        _ worker: String,
        nativeFixtureDirectory: String?
    ) async throws -> [RungRecord] {
        let paths = try paths()
        let oracle = try FixtureOracle(directory: paths.fixtures)
        let native: NativePaginationObservation
        let ownsNativeFixtures: Bool
        if let nativeFixtureDirectory {
            native = try loadNativePaginationObservation(
                at: URL(
                    fileURLWithPath: nativeFixtureDirectory,
                    isDirectory: true),
                oracle: oracle)
            ownsNativeFixtures = false
        } else {
            native = try nativePaginationObservation(
                paths: paths, oracle: oracle)
            ownsNativeFixtures = true
        }
        defer {
            if ownsNativeFixtures {
                try? FileManager.default.removeItem(
                    at: native.normalizedFixtureDirectory)
            }
        }
        Interpreter.interpretsAsPlatform = "iOS"
        LiveCheckSupport.traceLifecycle =
            ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1"
        NetworkBridge.policy = .replay(
            fixturesDirectory:
                native.normalizedFixtureDirectory.path)
        NetworkBridge.requestLog = []
        defer { NetworkBridge.policy = .absorbed }

        switch worker {
        case "shell":
            return [try await shellRung(paths: paths, oracle: oracle)]
        case "timeline":
            return try await renderRungs(
                paths: paths, oracle: oracle, scope: .timeline)
        case "detail-account":
            return try await renderRungs(
                paths: paths, oracle: oracle, scope: .detailAndAccount)
        case "pagination":
            return [
                try await paginationRung(
                    paths: paths, oracle: oracle, native: native),
            ]
        case "row-tap":
            return [try await rowTapRung(paths: paths, oracle: oracle)]
        case "tab-switch":
            return [try await tabSwitchRung(paths: paths, oracle: oracle)]
        default:
            return [RungRecord(
                name: "unknown-worker", passed: false,
                message: "unknown worker '\(worker)'")]
        }
    }
#endif

    private struct Paths {
        let root: String
        let app: String
        let fixtures: String
        let appFiles: [String]
        let packageFiles: [String]
        let sourceModules: [String: String]
        let nativeTwinExecutable: String
    }

    private static func paths() throws -> Paths {
        // `--root` frees the interactive run from cwd: a Catalyst app must
        // launch through LaunchServices (`open`) to get an on-screen render
        // connection, and `open` does not preserve the caller's directory.
        let root = option(
            "--root", in: Array(CommandLine.arguments.dropFirst()))
            ?? FileManager.default.currentDirectoryPath
        let app = root + "/External/oss/IceCubesApp"
        let fixtures = root + "/Fixtures/mastodon-public-timeline"
        let packages = app + "/Packages"
        let twinBuild = root + "/Examples/IceCubesNativeTwin/.build"
        let buildDescription = twinBuild
            + "/arm64-apple-ios-macabi/debug/description.json"
        guard FileManager.default.fileExists(atPath: app),
              FileManager.default.fileExists(atPath: fixtures),
              let packageNames = try? FileManager.default.contentsOfDirectory(atPath: packages)
        else {
            throw RuntimeError(message: "IceCubes sources or fixtures are missing under \(root)")
        }
        let localPackageFiles = packageNames.sorted().flatMap {
            ProjectMaterial.swiftFiles(under: packages + "/\($0)/Sources")
        }
        // SwiftPM's native build plan is the source-of-truth for remote
        // dependency target membership. The shared adapter follows imported
        // Module.freeGlobal references and verifies each member against that
        // module's compiled source inventory; no package/API identity lives
        // in this instrument.
        let externalPackageFiles: [String]
        let sourceModules: [String: String]
        if FileManager.default.fileExists(atPath: buildDescription) {
            externalPackageFiles = try ProjectMaterial.swiftFiles(
                inSwiftPMBuildDescriptionAt: buildDescription,
                requiredBy: localPackageFiles)
            sourceModules = try ProjectMaterial.sourceModuleNames(
                inSwiftPMBuildDescriptionAt: buildDescription)
        } else {
            externalPackageFiles = []
            sourceModules = [:]
        }
        let packageFiles = Array(Set(
            localPackageFiles + externalPackageFiles)).sorted()
        // A native build compiles the app and AppIntents extension as separate
        // targets. Keep the interpreter's app product on the same target
        // boundary; extension products are explicitly outside this board.
        let appFiles = ProjectMaterial.swiftFiles(under: app + "/IceCubesApp")
        guard !packageFiles.isEmpty, !appFiles.isEmpty else {
            throw RuntimeError(message: "IceCubes target source selection is empty")
        }
        return Paths(
            root: root, app: app, fixtures: fixtures,
            appFiles: appFiles.sorted(), packageFiles: packageFiles.sorted(),
            sourceModules: sourceModules,
            nativeTwinExecutable: twinBuild
                + "/arm64-apple-ios-macabi/debug"
                + "/IceCubesNativeTwin.app/Contents/MacOS"
                + "/IceCubesNativeTwin")
    }

    private static func shellRung(
        paths: Paths,
        oracle: FixtureOracle
    ) async throws -> RungRecord {
        let source = ProjectMaterial.mergedSource(
            at: paths.app, files: paths.packageFiles + paths.appFiles,
            sourceModules: paths.sourceModules)
        let render = try await LiveCheckSupport.render(source: source)
        let strings = render.strings
        let normalized = strings.map(FixtureOracle.normalize)
        var problems: [String] = []
        if render.rootSymbol != "scene:IceCubesApp" {
            problems.append("root is \(render.rootSymbol), wanted scene:IceCubesApp")
        }
        let launchAccounts = oracle.trendingStatuses.map(\.visibleAccount.visibleName)
        let visible = launchAccounts.filter { marker in
            normalized.contains { $0.contains(marker) }
        }
        if visible.isEmpty {
            problems.append("no replay author reached the app shell")
        }
        if !render.networkRequests.contains(where: {
            $0.hasPrefix("/api/v1/trends/statuses") && $0.hasSuffix("hit")
        }) {
            problems.append("app shell never hit the recorded trending endpoint")
        }
        return RungRecord(
            name: "R0-shell", passed: problems.isEmpty,
            message: problems.joined(separator: "; "))
    }

#if !targetEnvironment(macCatalyst)
    /// The LIVE board (LOOP-ICECUBES real-endpoint tier 1): the same
    /// interpreted app shell, real HTTP against the app's own default
    /// instance, invariant assertions instead of pixels. Expectations come
    /// from bytes fetched moments earlier from the same endpoint the app
    /// hits — real responses, never hand-written. Semantics: transport
    /// failure reaching the instance is UNSTABLE (exit 0 with a marker — the
    /// internet is not a finding); a decode failure on live bytes (schema
    /// drift) or a broken render invariant is RED (exit 1). This board is
    /// never a monotonic metric: content changes run to run by design.
    private static func runLiveBoard(instance: String) async throws {
        let paths = try paths()
        let trendsPath = "/api/v1/trends/statuses"
        guard let trendsURL = URL(
            string: "https://\(instance)\(trendsPath)") else {
            throw RuntimeError(message: "invalid live instance '\(instance)'")
        }
        let fetched: Data
        do {
            let (data, response) = try await URLSession.shared.data(
                for: URLRequest(url: trendsURL, timeoutInterval: 20))
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("⚠️ LIVE board UNSTABLE: \(instance)\(trendsPath) answered HTTP \(code)")
                return
            }
            fetched = data
        } catch {
            print("⚠️ LIVE board UNSTABLE: could not reach \(instance): \(error.localizedDescription)")
            return
        }

        var records: [RungRecord] = []
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let liveTrending: [FixtureStatus]
        do {
            liveTrending = try decoder.decode(
                [FixtureStatus].self, from: fetched)
            records.append(RungRecord(
                name: "LIVE-schema-decode", passed: true,
                message: "\(liveTrending.count) live trending statuses decoded"))
        } catch {
            records.append(RungRecord(
                name: "LIVE-schema-decode", passed: false,
                message: "live \(trendsPath) bytes no longer decode: \(error)"))
            reportLiveBoard(records, instance: instance)
            return
        }

        Interpreter.interpretsAsPlatform = "iOS"
        LiveCheckSupport.traceLifecycle =
            ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1"
        NetworkBridge.policy = .live
        NetworkBridge.requestLog = []
        defer { NetworkBridge.policy = .absorbed }

        let source = ProjectMaterial.mergedSource(
            at: paths.app, files: paths.packageFiles + paths.appFiles,
            sourceModules: paths.sourceModules)
        let render = try await LiveCheckSupport.render(source: source)
        let normalized = render.strings.map(FixtureOracle.normalize)

        records.append(RungRecord(
            name: "LIVE-shell-root",
            passed: render.rootSymbol == "scene:IceCubesApp",
            message: render.rootSymbol == "scene:IceCubesApp"
                ? "" : "root is \(render.rootSymbol), wanted scene:IceCubesApp"))

        let liveTrendingHits = render.networkRequests.filter {
            $0.hasPrefix(trendsPath) && $0.hasSuffix("HTTP 200")
        }
        records.append(RungRecord(
            name: "LIVE-shell-network",
            passed: !liveTrendingHits.isEmpty,
            message: liveTrendingHits.isEmpty
                ? "app shell never completed a live \(trendsPath) request; log: "
                    + render.networkRequests.prefix(6).joined(separator: " | ")
                : ""))

        let liveAuthors = liveTrending.map(\.visibleAccount.visibleName)
            .map(FixtureOracle.normalize)
            .filter { !$0.isEmpty }
        let renderedAuthors = liveAuthors.filter { author in
            normalized.contains { $0.contains(author) }
        }
        records.append(RungRecord(
            name: "LIVE-shell-content",
            passed: !renderedAuthors.isEmpty,
            message: liveAuthors.isEmpty
                ? "live trends carried no visible author names"
                : "\(renderedAuthors.count)/\(liveAuthors.count) live trending authors rendered"))

        records.append(RungRecord(
            name: "LIVE-shell-lifecycle",
            passed: render.lifecycleErrors.isEmpty,
            message: render.lifecycleErrors.prefix(3)
                .joined(separator: " | ")))

        reportLiveBoard(records, instance: instance)
    }

    private static func reportLiveBoard(
        _ records: [RungRecord], instance: String
    ) {
        for record in records {
            if record.passed {
                let detail = record.message.isEmpty
                    ? "" : "  \(record.message)"
                print("✅ \(record.name)\(detail)")
            } else {
                print("❌ \(record.name)  \(record.message)")
            }
        }
        let passed = records.filter(\.passed).count
        print("═══ IceCubesCheck LIVE (\(instance)): \(passed)/\(records.count) rungs ═══")
        if passed != records.count {
            exit(1)
        }
    }
#endif

    private enum RenderScope: Equatable {
        case timeline
        case detailAndAccount
    }

    private enum RenderProbePresentation {
        case diagnostics
        case nativeTimeline
        case nativeStatusDetail
        case nativeAccountHeader
        case nativeMedia
        case nativeTagsList
        /// The real navigation shape every IceCubes tab is built from:
        /// `NavigationStack(path: $routerPath.path) { content.withAppRouter() }`
        /// (NavigationTab.swift:25 + AppRegistry.swift:65). Nothing about the
        /// screen is restated here — the rung taps the app's own rows.
        case rowTapNavigation
    }

#if !targetEnvironment(macCatalyst)
    private static func paginationRung(
        paths: Paths, oracle: FixtureOracle,
        native: NativePaginationObservation
    ) async throws -> RungRecord {
        let source = ProjectMaterial.mergedSource(
            at: paths.app, files: paths.packageFiles,
            sourceModules: paths.sourceModules)
            + ProjectMaterial.mergedSource(
                source: renderProbeSource(
                    includeTimeline: true,
                    includeDetailAndAccount: false,
                    includePagination: true,
                    presentation: .diagnostics),
                moduleName: "IceCubesCheckProbe")
        if let dumpPath = ProcessInfo.processInfo.environment[
            "ICECUBES_DUMP_MERGE"
        ] {
            try source.write(
                toFile: dumpPath, atomically: true, encoding: .utf8)
        }
        let render = try await LiveCheckSupport.render(
            source: source, viewportTraversal: .throughEnd,
            initialViewportRowCapacity:
                native.record.initialVisibleStatusIDs.count)
        let expectedCount = native.record.finalStatusCount
        let normalized = render.strings.map(FixtureOracle.normalize)
        var problems: [String] = []
        if !normalized.contains("__ice-page-loads-1") {
            problems.append("scroll did not invoke the real footer task exactly once")
        }
        if !normalized.contains("__ice-page-count-\(expectedCount)") {
            problems.append(
                "scroll did not append the recorded next page to \(expectedCount) statuses")
        }
        if let appended = oracle.trendingStatuses.first,
           !normalized.contains(where: {
               $0.contains(appended.visibleAccount.visibleName)
           })
        {
            problems.append(
                "appended fixture status '\(appended.id)' never reached the rendered rows")
        }
        if !render.lifecycleErrors.isEmpty {
            problems.append(
                "lifecycle errors: \(render.lifecycleErrors.prefix(3).joined(separator: " | "))")
        }
        return RungRecord(
            name: "R3-pagination", passed: problems.isEmpty,
            message: problems.joined(separator: "; "))
    }

    /// Which recorded row the tap aims at, and what makes "that row's detail"
    /// falsifiable. Everything here is read off the recorded bytes.
    private struct RowTapTarget {
        /// A whole word only this row's text renders, so aiming at the row
        /// cannot accidentally aim at a different one.
        let aimWord: String
        /// The row's visible text and author, both of which its detail screen
        /// must still show once pushed.
        let contentMarker: String
        let authorName: String
        /// Authors only the OTHER rows render: a pushed detail covers the
        /// timeline, so none of these may survive the tap.
        let coveredAuthorNames: [String]
        let index: Int
    }

    /// The row is chosen, not written: the first status past the head whose
    /// text carries a word no other recorded row uses and whose author is
    /// likewise unique. Aiming by a whole word keeps the target free of the
    /// whitespace normalization the rendered HTML goes through.
    private static func rowTapTarget(
        in oracle: FixtureOracle
    ) -> RowTapTarget? {
        let statuses = oracle.publicStatuses
        let names = statuses.map(\.visibleAccount.visibleName)
        let texts = statuses.map { FixtureOracle.rawText($0.visibleContent) }
        func words(_ text: String) -> Set<String> {
            Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { $0.lowercased() }
                .filter { $0.count >= 7 })
        }
        let wordSets = texts.map(words)
        for index in statuses.indices where index > 0 {
            let name = names[index]
            guard names.filter({ $0 == name }).count == 1 else { continue }
            let elsewhere = wordSets.enumerated()
                .filter { $0.offset != index }
                .reduce(into: Set<String>()) { $0.formUnion($1.element) }
            let marker = FixtureOracle.leadingTextMarker(
                statuses[index].visibleContent)
            guard marker.split(separator: " ").count >= 3 else { continue }
            // Tie the aim word to the marker the assertion uses, so the rung
            // cannot pass by rendering some other part of the same status.
            let markerWords = words(marker)
            guard let aim = markerWords.subtracting(elsewhere).min(),
                  !name.lowercased().contains(aim)
            else { continue }
            let covered = statuses.indices.filter { $0 != index }
                .map { names[$0] }
                .filter { other in
                    other != name
                        && !marker.localizedCaseInsensitiveContains(other)
                        && !name.localizedCaseInsensitiveContains(other)
                        && other.count >= 3
                }
            guard !covered.isEmpty else { continue }
            return RowTapTarget(
                aimWord: aim, contentMarker: marker, authorName: name,
                coveredAuthorNames: Array(Set(covered)).sorted(),
                index: index)
        }
        return nil
    }

    /// R3 interaction two of three: tapping a row pushes THAT row's status
    /// detail. IceCubes reaches it through StatusRowContentView's
    /// `.onTapGesture` -> `StatusRowViewModel.navigateToDetail()` ->
    /// `RouterPath.navigate(to: .statusDetailWithStatus(status:))` ->
    /// the enclosing `NavigationStack(path:)`, so the rung drives the app's
    /// own path and never calls the view model itself.
    private static func rowTapRung(
        paths: Paths, oracle: FixtureOracle
    ) async throws -> RungRecord {
        func record(_ problems: [String]) -> RungRecord {
            RungRecord(
                name: "R3-row-tap-detail", passed: problems.isEmpty,
                message: problems.joined(separator: "; "))
        }
        guard let target = rowTapTarget(in: oracle) else {
            return record([
                "no recorded row carries text and an author unique enough "
                    + "to identify its own detail screen",
            ])
        }
        // The destination map is the app's own `withAppRouter()`
        // (AppRegistry.swift:65), so the app target is merged too — hosted
        // under the probe's scene rather than its own.
        let source = ProjectMaterial.mergedSource(
            at: paths.app, files: paths.packageFiles + paths.appFiles,
            sourceModules: paths.sourceModules,
            entryPoint: .suppliedByCaller)
            + ProjectMaterial.mergedSource(
                source: renderProbeSource(
                    includeTimeline: true,
                    includeDetailAndAccount: false,
                    presentation: .rowTapNavigation),
                moduleName: "IceCubesCheckProbe")
        let before = try await LiveCheckSupport.render(source: source)
        let after = try await LiveCheckSupport.render(
            source: source, afterActions: 1,
            targeting: .renderingText(target.aimWord))
        if ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1" {
            print("@@icecubes-row-tap aim=\(target.aimWord) "
                + "row=\(target.index) author=\(target.authorName)")
            for (name, count) in after.absorbedHostMembers
                .sorted(by: { $0.value > $1.value }).prefix(25)
            {
                print("@@icecubes-row-tap-absorbed \(name) x\(count)")
            }
            for candidate in after.actionTargets
                where candidate.localizedCaseInsensitiveContains(
                    target.aimWord)
            {
                print("@@icecubes-row-tap-target \(candidate.prefix(220))")
            }
            for string in after.strings.map(FixtureOracle.normalize).prefix(60)
            where !string.isEmpty {
                print("@@icecubes-row-tap-string \(string.prefix(120))")
            }
        }
        func shows(_ render: LiveCheckRenderResult, _ text: String) -> Bool {
            !text.isEmpty && render.strings
                .map(FixtureOracle.normalize)
                .contains { $0.contains(text) }
        }

        var problems: [String] = []
        // The transition is only measurable if the timeline was there first.
        let coveredBefore = target.coveredAuthorNames.filter {
            shows(before, $0)
        }
        if !shows(before, target.contentMarker) {
            problems.append(
                "row \(target.index) never rendered its recorded text "
                    + "'\(target.contentMarker)' before the tap")
        }
        if coveredBefore.isEmpty {
            problems.append(
                "no other recorded row rendered before the tap, so a push "
                    + "cannot be told from a no-op")
        }
        guard problems.isEmpty else { return record(problems) }

        // Separate the two ways this can fail: the tap not reaching the
        // app's router at all, and the stack not showing what was pushed.
        if !shows(after, "__ice-path-count-1") {
            problems.append(
                "the tap did not append exactly one destination to the "
                    + "app's RouterPath")
        }
        if !shows(after, target.contentMarker) {
            problems.append(
                "the pushed detail does not show the tapped row's text "
                    + "'\(target.contentMarker)'")
        }
        if !shows(after, target.authorName) {
            problems.append(
                "the pushed detail does not show the tapped row's author "
                    + "'\(target.authorName)'")
        }
        let stillCovered = coveredBefore.filter { shows(after, $0) }
        if !stillCovered.isEmpty {
            problems.append(
                "the timeline is still on screen after the tap: "
                    + stillCovered.prefix(3).joined(separator: ", ")
                    + " remain visible")
        }
        if !after.lifecycleErrors.isEmpty {
            problems.append(
                "lifecycle errors: "
                    + after.lifecycleErrors.prefix(3)
                        .joined(separator: " | "))
        }
        if !problems.isEmpty {
            problems.append(
                "aimed at '\(target.aimWord)' among "
                    + "\(after.actionTargets.count) tappable elements")
        }
        return record(problems)
    }

    /// The app's OWN string catalog. Every tab label and screen marker the
    /// tab-switch rung aims at or asserts is a `LocalizedStringKey` the app
    /// resolves through this file at runtime, so the rung reads the same
    /// bytes rather than restating what they say — the localization rule the
    /// fixtures already follow for the network.
    private struct AppStringCatalog {
        private let values: [String: String]

        init(appRoot: String) throws {
            let path = appRoot
                + "/IceCubesApp/Resources/Localization/Localizable.xcstrings"
            guard let data = FileManager.default.contents(atPath: path) else {
                throw RuntimeError(
                    message: "app string catalog is missing at \(path)")
            }
            let root = try JSONSerialization.jsonObject(with: data)
            guard let object = root as? [String: Any],
                  let strings = object["strings"] as? [String: Any]
            else {
                throw RuntimeError(
                    message: "app string catalog at \(path) has no strings")
            }
            var values: [String: String] = [:]
            for (key, entry) in strings {
                guard let entry = entry as? [String: Any],
                      let localizations =
                        entry["localizations"] as? [String: Any],
                      let english = localizations["en"] as? [String: Any],
                      let unit = english["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String
                else { continue }
                values[key] = value
            }
            self.values = values
        }

        /// The trace tree records the KEY a `Text(_: LocalizedStringKey)` was
        /// given rather than the localized value — the real render localizes,
        /// which is why the pixel board sits at AE 0 over screens full of
        /// localized chrome. So the rung aims at and asserts on the app's own
        /// keys, and the catalog's job is to confirm each one IS a string the
        /// app defines: a typo would otherwise be a marker that can never
        /// match, i.e. a rung that fails for the wrong reason.
        func confirmedKey(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else {
                throw RuntimeError(
                    message: "'\(key)' is not a string the app's own catalog "
                        + "defines, so no screen can be identified by it")
            }
            return key
        }
    }

    /// R3 interaction three of three: switching tab lands the right screen.
    /// The shell drives this through AppView.swift:77 — a `TabView` whose
    /// selection is a COMPUTED binding routing every write through the app's
    /// own `updateTab(with:)`, with the items nested in `TabSection`/`ForEach`
    /// and each carrying a separate `label:` builder. Signed out (the board's
    /// standing quarantine) `availableSections` is `[.loggedOutTabs]`, whose
    /// tabs are `[.timeline, .settings]` (Tabs.swift:359) — so the switch this
    /// rung drives is the only one the unauthenticated app offers.
    ///
    /// Nothing about either screen is restated: the rung renders the app's own
    /// `@main` scene, aims at the label the app puts on the settings tab, and
    /// identifies the two screens by the recorded fixture authors (timeline)
    /// and the app's own settings section headers.
    private static func tabSwitchRung(
        paths: Paths, oracle: FixtureOracle
    ) async throws -> RungRecord {
        func record(_ problems: [String]) -> RungRecord {
            RungRecord(
                name: "R3-tab-switch", passed: problems.isEmpty,
                message: problems.joined(separator: "; "))
        }
        let catalog = try AppStringCatalog(appRoot: paths.app)
        let settingsTabLabel = try catalog.confirmedKey("tab.settings")
        // Markers only the settings CONTENT renders. The tab's own label is
        // on screen either way — a tab bar shows every tab — so asserting the
        // label would pass without the screen ever landing.
        let settingsMarkers = try ["settings.section.app", "settings.app.source"]
            .map { try catalog.confirmedKey($0) }
        // The timeline's presence is read off the recorded bytes, exactly as
        // every other rung reads it.
        let timelineAuthors = oracle.trendingStatuses
            .map(\.visibleAccount.visibleName)
            .filter { $0.count >= 3 }

        let source = ProjectMaterial.mergedSource(
            at: paths.app, files: paths.packageFiles + paths.appFiles,
            sourceModules: paths.sourceModules)
        let before = try await LiveCheckSupport.render(source: source)
        func shows(_ render: LiveCheckRenderResult, _ text: String) -> Bool {
            !text.isEmpty && render.strings
                .map(FixtureOracle.normalize)
                .contains { $0.contains(text) }
        }
        // Kept small on purpose: the worker's stdout is a pipe the parent
        // drains only at exit, so dumping every rendered string deadlocks the
        // worker into its own timeout.
        if ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1" {
            print("@@icecubes-tab-switch aim=\(settingsTabLabel) "
                + "markers=\(settingsMarkers) "
                + "strings=\(before.strings.count)")
            for string in before.strings.map(FixtureOracle.normalize)
            where string.hasPrefix("tab.") || string.hasPrefix("settings.") {
                print("@@icecubes-tab-switch-string \(string.prefix(120))")
            }
        }

        var problems: [String] = []
        // The switch is only measurable if the timeline was there first.
        let authorsBefore = timelineAuthors.filter { shows(before, $0) }
        if authorsBefore.isEmpty {
            problems.append(
                "no replay author reached the timeline tab before the "
                    + "switch, so landing on settings cannot be told from a "
                    + "shell that never rendered a tab at all")
        }
        let leakedBefore = settingsMarkers.filter { shows(before, $0) }
        if !leakedBefore.isEmpty {
            problems.append(
                "the settings screen is already on screen before the switch: "
                    + leakedBefore.joined(separator: ", ")
                    + " — only the selected tab's content may render")
        }
        guard problems.isEmpty else { return record(problems) }

        let after = try await LiveCheckSupport.render(
            source: source, afterActions: 1,
            targeting: .renderingText(settingsTabLabel))
        let landed = settingsMarkers.filter { shows(after, $0) }
        if landed.isEmpty {
            problems.append(
                "selecting the '\(settingsTabLabel)' tab did not land its "
                    + "screen: none of \(settingsMarkers) rendered")
        }
        let stillVisible = authorsBefore.filter { shows(after, $0) }
        if !stillVisible.isEmpty {
            problems.append(
                "the timeline tab is still on screen after the switch: "
                    + stillVisible.prefix(3).joined(separator: ", ")
                    + " remain visible")
        }
        if !after.lifecycleErrors.isEmpty {
            problems.append(
                "lifecycle errors: "
                    + after.lifecycleErrors.prefix(3)
                        .joined(separator: " | "))
        }
        if !problems.isEmpty {
            problems.append(
                "aimed at '\(settingsTabLabel)' among "
                    + "\(after.actionTargets.count) tappable elements")
        }
        return record(problems)
    }

    private static func nativePaginationObservation(
        paths: Paths, oracle: FixtureOracle
    ) throws -> NativePaginationObservation {
        guard FileManager.default.isExecutableFile(
            atPath: paths.nativeTwinExecutable)
        else {
            throw RuntimeError(
                message:
                    "native pagination twin is missing; run "
                    + "Examples/IceCubesNativeTwin/build.sh")
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "icecubes-pagination-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.copyItem(
            at: URL(
                fileURLWithPath: paths.fixtures,
                isDirectory: true),
            to: output)
        do {
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath: paths.nativeTwinExecutable)
            process.arguments = [
                "--pagination-probe",
                "--out", output.path,
                "--fixtures", paths.fixtures,
            ]
            let diagnostics = Pipe()
            process.standardOutput = diagnostics
            process.standardError = diagnostics
            try process.run()
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning, Date() < deadline {
                RunLoop.main.run(
                    until: Date().addingTimeInterval(0.025))
            }
            if process.isRunning {
                process.terminate()
                kill(process.processIdentifier, SIGKILL)
                throw RuntimeError(
                    message: "native pagination twin exceeded 20s")
            }
            let log = String(
                decoding:
                    diagnostics.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw RuntimeError(
                    message:
                        "native pagination twin exited "
                        + "\(process.terminationStatus): \(log)")
            }
            return try loadNativePaginationObservation(
                at: output, oracle: oracle, diagnostics: log)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func loadNativePaginationObservation(
        at output: URL,
        oracle: FixtureOracle,
        diagnostics: String = ""
    ) throws -> NativePaginationObservation {
        let record = try JSONDecoder().decode(
            NativePaginationRecord.self,
            from: Data(contentsOf: output.appendingPathComponent(
                "pagination.json")))
        guard record.initialPageLoads == 0,
              record.finalPageLoads == 1,
              !record.initialVisibleStatusIDs.isEmpty,
              record.initialVisibleStatusIDs.count
                < oracle.publicStatuses.count,
              record.finalStatusCount
                == oracle.publicStatuses.count + 1,
              record.appendedStatusID
                == oracle.trendingStatuses.first?.id,
              record.appendedStatusBecameVisible,
              !record.normalizedFixtureNames.isEmpty,
              !record.interactionFixtureNames.isEmpty
        else {
            throw RuntimeError(
                message:
                    "native pagination receipt failed validation: "
                    + diagnostics)
        }
        guard (record.normalizedFixtureNames
            + record.interactionFixtureNames)
            .allSatisfy({
            FileManager.default.fileExists(
                atPath: output.appendingPathComponent($0).path)
        }) else {
            throw RuntimeError(
                message:
                    "native pagination twin omitted normalized fixtures")
        }
        return NativePaginationObservation(
            record: record,
            normalizedFixtureDirectory: output)
    }
#endif

    private static func renderRungs(
        paths: Paths, oracle: FixtureOracle, scope: RenderScope
    ) async throws -> [RungRecord] {
        let source = ProjectMaterial.mergedSource(
            at: paths.app, files: paths.packageFiles,
            sourceModules: paths.sourceModules)
            + ProjectMaterial.mergedSource(
                source: renderProbeSource(
                    includeTimeline: scope == .timeline,
                    includeDetailAndAccount: scope == .detailAndAccount,
                    presentation: .diagnostics),
                moduleName: "IceCubesCheckProbe")
        let render = try await LiveCheckSupport.render(source: source)
        let strings = render.strings
        let normalized = strings.map(FixtureOracle.normalize)
        if ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1" {
            print("@@icecubes-root \(render.rootSymbol)")
            print("@@icecubes-lifecycle \(render.lifecycleFired)")
            for (name, count) in render.absorbedHostMembers
                .sorted(by: { $0.value > $1.value }).prefix(20)
            {
                print("@@icecubes-absorbed \(name) x\(count)")
            }
            for string in normalized where !string.isEmpty {
                print("@@icecubes-string \(string)")
            }
            for request in render.networkRequests {
                print("@@icecubes-network \(request)")
            }
        }
        func contains(_ marker: String) -> Bool {
            !marker.isEmpty && normalized.contains { $0.contains(marker) }
        }
        func record(_ name: String, _ problems: [String]) -> RungRecord {
            RungRecord(
                name: name, passed: problems.isEmpty,
                message: problems.joined(separator: "; "))
        }

        var timelineProblems: [String] = []
        let publicNames = oracle.publicStatuses.map(\.visibleAccount.visibleName)
        let foundNames = publicNames.filter(contains)
        if foundNames.count < 3 {
            timelineProblems.append("only \(foundNames.count) public-timeline display names rendered")
        }
        let publicContent = oracle.publicStatuses.prefix(4)
            .map { FixtureOracle.marker($0.visibleContent) }
        let foundContent = publicContent.filter(contains)
        if foundContent.count < 2 {
            timelineProblems.append("only \(foundContent.count) HTML-derived status texts rendered")
        }

        var detailProblems: [String] = []
        if let detail = oracle.trendingStatuses.first {
            let marker = FixtureOracle.leadingTextMarker(detail.visibleContent)
            if !contains(marker) { detailProblems.append("missing detail content '\(marker)'") }
            if !contains(detail.visibleAccount.visibleName) {
                detailProblems.append("missing detail author '\(detail.visibleAccount.visibleName)'")
            }
        } else {
            detailProblems.append("trending fixture has no status for detail")
        }

        var accountProblems: [String] = []
        if let account = oracle.trendingStatuses.first?.account {
            let note = FixtureOracle.marker(account.note)
            if !contains(account.visibleName) {
                accountProblems.append("missing account display name '\(account.visibleName)'")
            }
            if !contains(note) { accountProblems.append("missing account HTML note '\(note)'") }
        } else {
            accountProblems.append("trending fixture has no account")
        }

        var boostProblems: [String] = []
        let boost = oracle.boostStatus
        if boost.reblog != nil {
            if !contains(boost.account.visibleName) {
                boostProblems.append("missing booster attribution '\(boost.account.visibleName)'")
            }
            if !contains(boost.visibleAccount.visibleName) {
                boostProblems.append("missing boosted author '\(boost.visibleAccount.visibleName)'")
            }
        } else {
            boostProblems.append("recorded boost fixture contains no boost")
        }

        var mediaProblems: [String] = []
        if let media = oracle.boostStatus.visibleMedia.first(where: {
            $0.type == "image"
        }), let url = media.url
        {
            if !render.networkRequests.contains(where: {
                $0.contains(url.path) && $0.hasSuffix(" hit")
            }) {
                mediaProblems.append(
                    "missing deterministic media request for '\(url.lastPathComponent)'")
            }
        } else {
            mediaProblems.append("recorded boost fixture contains no image media")
        }

        switch scope {
        case .timeline:
            return [
                record("R1-timeline", timelineProblems),
                record("R1-boost-attribution", boostProblems),
                record("R1-media-placeholder", mediaProblems),
            ]
        case .detailAndAccount:
            return [
                record("R1-status-detail", detailProblems),
                record("R1-account-header", accountProblems),
            ]
        }
    }

    private static func renderProbeSource(
        includeTimeline: Bool,
        includeDetailAndAccount: Bool,
        includePagination: Bool = false,
        presentation: RenderProbePresentation,
        screenStatusFixture: String? = nil
    ) -> String {
        let fixtureDecodes = [
            includeTimeline ? """
        let __icePublicStatuses = try! __iceDecoder.decode(
            [Status].self, from: __fixtureData("api_v1_timelines_public"))
        """ : "",
            // The media screen is built from this status' attachment alone, so
            // it needs the boost fixture without any of the timeline globals.
            (includeTimeline && !includePagination)
                || presentation == .nativeMedia ? """
        let __iceBoostStatus = try! __iceDecoder.decode(
            Status.self,
            from: __fixtureData("api_v1_statuses_116954929935729788"))
        """ : "",
            includeDetailAndAccount || includePagination ? """
        let __iceTrendingStatuses = try! __iceDecoder.decode(
            [Status].self, from: __fixtureData("api_v1_trends_statuses"))
        """ : "",
            screenStatusFixture.map { fixture in """
        let __iceScreenStatus = try! __iceDecoder.decode(
            Status.self, from: __fixtureData("\(fixture)"))
        """ } ?? "",
            // The recorded trending-tags bytes carry no `following` key, so
            // this decode runs `Tag.init(from:)`'s own
            // `catch DecodingError.keyNotFound` fallback rather than a
            // synthesized memberwise decode.
            //
            // `Models.Tag` is spelled module-qualified because this probe
            // imports both Models and SwiftSoup, and BOTH declare a top-level
            // `Tag`. Bare `Tag` here is ambiguous to the real compiler too, so
            // qualifying is what swiftc requires — not a workaround. The app's
            // own `TagsListView` needs no qualifier: module Explore imports
            // Models without SwiftSoup, so its `Tag` is unambiguous.
            presentation == .nativeTagsList ? """
        let __iceTrendingTags = try! __iceDecoder.decode(
            [Models.Tag].self, from: __fixtureData("api_v1_trends_tags"))
        """ : "",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        let initialStatuses = includePagination
            ? "__icePublicStatuses"
            : "__icePublicStatuses + [__iceBoostStatus]"
        let timelineGlobals = includeTimeline ? """
        let __iceFetcher = __IceFixtureFetcher(
            statuses: \(initialStatuses),
            nextPage: \(includePagination ? "[__iceTrendingStatuses[0]]" : "[]"))
        let __iceFirstRowModel = StatusRowViewModel(
            status: __icePublicStatuses[0],
            client: __iceClient,
            routerPath: __iceRouter,
            filterContext: .pub)
        """ : ""
        let timelineDiagnostics = includePagination ? """
                        __IcePaginationProbe(fetcher: __iceFetcher)
        """ : """
                        switch __iceFetcher.statusesState {
                        case .loading:
                            Text("__ice-direct-state-loading")
                        case .display:
                            Text("__ice-direct-state-display")
                        case .displayWithGaps:
                            Text("__ice-direct-state-gaps")
                        case .error:
                            Text("__ice-direct-state-error")
                        }
                        __IceFetcherStateProbe(fetcher: __iceFetcher)
                        __IceFetcherRowsProbe(fetcher: __iceFetcher)
                        __IcePaginationProbe(fetcher: __iceFetcher)
                        __IceRowModelProbe(viewModel: __iceFirstRowModel)
                        __IceMediaProbe(
                            attachments: __iceBoostStatus.reblog?.mediaAttachments
                                ?? __iceBoostStatus.mediaAttachments)
                        StatusRowHeaderView(viewModel: __iceFirstRowModel)
                        StatusRowContentView(viewModel: __iceFirstRowModel)
        """
        let timelineViews = includeTimeline ? """
                        \(timelineDiagnostics)
                        SwiftUI.List {
                            StatusesListView(
                                fetcher: __iceFetcher,
                                client: __iceClient,
                                routerPath: __iceRouter,
                                filterContext: .pub)
                        }
            """ : ""
        let extraViews = includeDetailAndAccount ? """
                    StatusDetailView(status: __iceTrendingStatuses[0])
                    AccountDetailView(account: __iceTrendingStatuses[0].account)
            """ : ""
        let rootView = switch presentation {
        case .diagnostics:
            """
                    VStack {
                        \(timelineViews)
                        \(extraViews)
                    }
            """
        case .nativeTimeline:
            """
                    NavigationStack {
                        List {
                            StatusesListView(
                                fetcher: __iceFetcher,
                                client: __iceClient,
                                routerPath: __iceRouter,
                                filterContext: .pub)
                        }
                        .listStyle(.plain)
                        .navigationTitle(TimelineFilter.federated.title)
                    }
            """
        case .nativeStatusDetail:
            """
                    NavigationStack {
                        StatusDetailView(status: __iceScreenStatus)
                    }
            """
        case .nativeAccountHeader:
            """
                    NavigationStack {
                        AccountDetailView(account: __iceScreenStatus.account)
                    }
            """
        case .nativeMedia:
            // The twin's FocusedMediaScreen frames the preview at 420x560
            // inside the 900x700 capture, so the interpreter must nest the two
            // frames the same way — the inner one is what the media layout is
            // actually measured against. Only the INNER frame belongs here;
            // the scored canvas is the harness's, as it is on the twin.
            """
                    __IceMediaProbe(
                        attachments: __iceBoostStatus.reblog?.mediaAttachments
                            ?? __iceBoostStatus.mediaAttachments)
                    .frame(width: 420, height: 560)
                    .background(Color.white)
            """
        case .nativeTagsList:
            // The screen `RouterDestination.tagsList` pushes, in the twin's own
            // shape: the app's public `TagsListView` inside a NavigationStack.
            // Nothing about the rows is restated here — `TagRowView` and its
            // Swift Charts sparkline come from the merged Explore package.
            """
                    NavigationStack {
                        TagsListView(tags: __iceTrendingTags)
                    }
            """
        case .rowTapNavigation:
            """
                    __IceRowTapProbe()
            """
        }
        // Only the navigation rung hosts the router shape: the diagnostics
        // probes render their views directly, and an unused stack would put a
        // second RouterPath in a tree that already carries one.
        let rowTapProbe = presentation == .rowTapNavigation ? """

        @MainActor
        struct __IceRowTapProbe: View {
            @State private var router = RouterPath()

            var body: some View {
                // Separates "the tap never reached the router" from "the
                // stack did not show what was pushed" when the rung is RED.
                Text("__ice-path-count-" + String(router.path.count))
                NavigationStack(path: $router.path) {
                    SwiftUI.List {
                        StatusesListView(
                            fetcher: __iceFetcher,
                            client: __iceClient,
                            routerPath: router,
                            filterContext: .pub)
                    }
                    .withAppRouter()
                }
                .environment(router)
            }
        }
        """ : ""
        return """

        import Account
        import AppAccount
        import DesignSystem
        import Env
        import Explore
        import Foundation
        import Models
        import NetworkClient
        import StatusKit
        import SwiftSoup
        import SwiftUI
        import Timeline

        let __iceInterpretedClockEpoch = Date().timeIntervalSince1970
        let __iceDecoder = JSONDecoder()
        __iceDecoder.keyDecodingStrategy = .convertFromSnakeCase
        \(fixtureDecodes)
        let __iceClient = MastodonClient(server: "mstdn.social")
        let __iceRouter = RouterPath()

        @MainActor
        final class __IceFixtureFetcher: StatusesFetcher {
            var statusesState: StatusesState
            var nextPage: [Status]
            var pageLoads = 0

            init(statuses: [Status], nextPage: [Status]) {
                statusesState = .display(statuses: statuses, nextPageState: .hasNextPage)
                self.nextPage = nextPage
            }
            func fetchNewestStatuses(pullToRefresh: Bool) async {}
            func fetchNextPage() async throws {
                guard !nextPage.isEmpty else { return }
                guard case .display(let statuses, _) = statusesState else {
                    return
                }
                statusesState = .display(
                    statuses: statuses + nextPage, nextPageState: .none)
                nextPage = []
                pageLoads += 1
            }
            func statusDidAppear(status: Status) {}
            func statusDidDisappear(status: Status) {}
        }

        \(timelineGlobals)

        func __iceSoupPipeline(_ htmlValue: String) -> String {
            var stage = "parse"
            do {
                let document = try SwiftSoup.parse(htmlValue)
                stage = "settings"
                document.outputSettings(
                    OutputSettings().prettyPrint(pretty: false))
                stage = "select-quote"
                try document.select("p.quote-inline").remove()
                stage = "select-br"
                try document.select("br").after("\\n")
                stage = "select-p"
                try document.select("p").after("\\n\\n")
                stage = "html"
                let html = try document.html()
                stage = "clean"
                let text = try SwiftSoup.clean(
                    html, "", Whitelist.none(),
                    OutputSettings().prettyPrint(pretty: false)) ?? ""
                stage = "unescape"
                return (try? Entities.unescape(text)) ?? text
            } catch {
                return "__ice-pipeline-failed-" + stage + "-" + String(describing: error)
            }
        }

        @MainActor
        struct __IceRowModelProbe: View {
            @State var viewModel: StatusRowViewModel

            var body: some View {
                Text("__ice-row-model-" + viewModel.finalStatus.account.username)
                Text("__ice-row-name-" + viewModel.finalStatus.account.safeDisplayName)
                Text("__ice-row-raw-" + viewModel.finalStatus.content.asRawText)
                Text("__ice-row-markdown-" + viewModel.finalStatus.content.asMarkdown)
                Text(__iceSoupPipeline(viewModel.finalStatus.content.htmlValue))
            }
        }

        @MainActor
        struct __IceFetcherStateProbe<Fetcher>: View where Fetcher: StatusesFetcher {
            @State private var fetcher: Fetcher

            init(fetcher: Fetcher) {
                _fetcher = .init(initialValue: fetcher)
            }

            var body: some View {
                switch fetcher.statusesState {
                case .loading:
                    Text("__ice-generic-state-loading")
                case .display:
                    Text("__ice-generic-state-display")
                case .displayWithGaps:
                    Text("__ice-generic-state-gaps")
                case .error:
                    Text("__ice-generic-state-error")
                }
            }
        }

        @MainActor
        struct __IceFetcherRowsProbe<Fetcher>: View where Fetcher: StatusesFetcher {
            @State private var fetcher: Fetcher

            init(fetcher: Fetcher) {
                _fetcher = .init(initialValue: fetcher)
            }

            var body: some View {
                switch fetcher.statusesState {
                case .loading:
                    Text("__ice-rows-loading")
                case .display(let statuses, _):
                    Text("__ice-rows-display")
                    ForEach(statuses) { status in
                        Text("__ice-row-" + status.account.username)
                    }
                case .displayWithGaps:
                    Text("__ice-rows-gaps")
                case .error:
                    Text("__ice-rows-error")
                }
            }
        }

        @MainActor
        struct __IcePaginationProbe: View {
            @State private var fetcher: __IceFixtureFetcher

            init(fetcher: __IceFixtureFetcher) {
                _fetcher = .init(initialValue: fetcher)
            }

            var body: some View {
                Text("__ice-page-loads-" + String(fetcher.pageLoads))
                switch fetcher.statusesState {
                case .display(let statuses, _):
                    Text("__ice-page-count-" + String(statuses.count))
                default:
                    Text("__ice-page-count-unavailable")
                }
            }
        }

        @MainActor
        struct __IceMediaProbe: View {
            let attachments: [MediaAttachment]

            @Namespace private var namespace

            var body: some View {
                let _ = {
                    // IceCubes' real app dependency graph installs this
                    // framework-supplied namespace before media is usable.
                    QuickLook.shared.namespace = namespace
                }()
                StatusRowMediaPreviewView(
                    attachments: attachments, sensitive: false)
            }
        }
        \(rowTapProbe)

        @\u{6D}ain
        struct __IceCubesR1Probe: App {
            var body: some Scene {
                WindowGroup {
                    \(rootView)
                    .accessibilityLabel(
                        Text(String(__iceInterpretedClockEpoch)))
                    .environment(Theme.shared)
                    .environment(CurrentAccount.shared)
                    .environment(CurrentInstance.shared)
                    .environment(UserPreferences.shared)
                    .environment(StreamWatcher.shared)
                    .environment(AppAccountsManager.shared)
                    .environment(QuickLook.shared)
                    .environment(ToastCenter.shared)
                    .environment(__iceClient)
                    .environment(__iceRouter)
                }
            }
        }
        """
    }

    /// The interactive `--run` session: the same native timeline screen the
    /// R2 board renders, but the statuses come from a real
    /// `MastodonClient.get` executed at interpretation time over
    /// `NetworkPolicy.live`. The full-app composition root is NOT hosted
    /// here yet: under the windowed host the app's own data-loading
    /// lifecycle never fires (measured 2026-07-31 — zero bridge requests,
    /// empty themed surface), which is LOOP-LIVE lifecycle territory, not a
    /// demo patch.
    fileprivate static func liveAppRenderSession(
        instance: String
    ) throws -> InterpreterRenderSession {
        let paths = try paths()
        Interpreter.interpretsAsPlatform = "iOS"
        // Record-at-the-boundary: fetch the live public timeline ONCE in the
        // host, hand the exact bytes to the proven replay render path. A
        // top-level `await client.get` global evaluates lazily inside render
        // bodies, where inline-await work is absorbed — measured 2026-07-31
        // as one fresh HTTP request per body evaluation and no rows.
        guard let liveURL = URL(
            string: "https://\(instance)/api/v1/timelines/public"
                + "?local=false&limit=40") else {
            throw RuntimeError(message: "invalid live instance '\(instance)'")
        }
        nonisolated final class Holder: @unchecked Sendable {
            var result: Result<Data, Error>?
        }
        let holder = Holder()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: liveURL) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let data, status == 200 {
                holder.result = .success(data)
            } else {
                holder.result = .failure(error ?? RuntimeError(
                    message: "\(liveURL.host ?? "?") answered HTTP \(status)"))
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        guard let fetched = holder.result else {
            throw RuntimeError(
                message: "live timeline request timed out for \(instance)")
        }
        let liveBytes = try fetched.get()
        let recordingDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "icecubes-live-run-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(
            at: recordingDirectory, withIntermediateDirectories: true)
        try liveBytes.write(
            to: recordingDirectory.appendingPathComponent(
                "api_v1_timelines_public.json"),
            options: .atomic)
        NetworkBridge.policy = .replay(
            fixturesDirectory: recordingDirectory.path)
        NetworkBridge.requestLog = []
        // Bisection ladder for the windowed empty-tree gap: level 2 renders a
        // trivial root over the full merged package source, level 3 decodes
        // the live bytes and shows one real status row, unset = full List.
        let miniLevel = ProcessInfo.processInfo
            .environment["ICECUBES_MINI_LEVEL"]
        let rootExpression: String
        switch miniLevel {
        case "2":
            rootExpression = """
            Text("merged hello")
                .font(.largeTitle)
                .padding()
                .background(Color.orange)
            """
        case "3":
            rootExpression = """
            VStack(alignment: .leading) {
                StatusRowHeaderView(viewModel: StatusRowViewModel(
                    status: __iceLiveStatuses[0],
                    client: __iceClient,
                    routerPath: __iceRouter,
                    filterContext: .pub))
                StatusRowContentView(viewModel: StatusRowViewModel(
                    status: __iceLiveStatuses[0],
                    client: __iceClient,
                    routerPath: __iceRouter,
                    filterContext: .pub))
            }
            """
        default:
            rootExpression = """
            NavigationStack {
                List {
                    StatusesListView(
                        fetcher: __IceLiveFetcher(statuses: __iceLiveStatuses),
                        client: __iceClient,
                        routerPath: __iceRouter,
                        filterContext: .pub)
                }
                .listStyle(.plain)
                .navigationTitle(TimelineFilter.federated.title)
            }
            """
        }
        // ICECUBES_RUN_PACKAGES bisects the merged corpus: a comma list of
        // local package names to include ("@none" = only externals,
        // "@nolocal-noext" = nothing). Level-2 roots need no app imports.
        let packageFilter = ProcessInfo.processInfo
            .environment["ICECUBES_RUN_PACKAGES"]
        let selectedPackageFiles: [String]
        if let packageFilter {
            let entries = packageFilter.split(separator: ",").map(String.init)
            let localNames = entries.filter {
                !$0.hasPrefix("x:") && !$0.hasPrefix("e:")
            }
            let externalNames = entries.filter { $0.hasPrefix("x:") }
                .map { String($0.dropFirst(2)) }
            let excludedFragments = entries.filter { $0.hasPrefix("e:") }
                .map { String($0.dropFirst(2)) }
            selectedPackageFiles = paths.packageFiles.filter { file in
                if excludedFragments.contains(where: file.contains) {
                    return false
                }
                if file.contains("/Packages/") {
                    return localNames.contains {
                        file.contains("/Packages/\($0)/")
                    }
                }
                if externalNames.contains("*") { return true }
                return externalNames.contains {
                    file.contains("/checkouts/\($0)/")
                }
            }
        } else {
            selectedPackageFiles = paths.packageFiles
        }
        let probeImports = miniLevel == "2"
            ? "import SwiftUI"
            : """
            import Account
            import AppAccount
            import DesignSystem
            import Env
            import Foundation
            import Models
            import NetworkClient
            import StatusKit
            import SwiftSoup
            import SwiftUI
            import Timeline
            """
        let probe = """

        \(probeImports)

        \(miniLevel == "2" ? "" : """
        let __iceClient = MastodonClient(server: "\(instance)")
        let __iceRouter = RouterPath()
        let __iceDecoder = JSONDecoder()
        __iceDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let __iceLiveStatuses = try! __iceDecoder.decode(
            [Status].self, from: __fixtureData("api_v1_timelines_public"))

        @MainActor
        final class __IceLiveFetcher: StatusesFetcher {
            var statusesState: StatusesState
            init(statuses: [Status]) {
                statusesState = .display(
                    statuses: statuses, nextPageState: .hasNextPage)
            }
            func fetchNewestStatuses(pullToRefresh: Bool) async {}
            func fetchNextPage() async throws {}
            func statusDidAppear(status: Status) {}
            func statusDidDisappear(status: Status) {}
        }
        """)

        \(rootExpression)
        .frame(
            width: \(screenSize.width), height: \(screenSize.height))
        .background(Color.white)
        \(miniLevel == "2" ? "" : """
        .environment(Theme.shared)
        .environment(CurrentAccount.shared)
        .environment(CurrentInstance.shared)
        .environment(UserPreferences.shared)
        .environment(StreamWatcher.shared)
        .environment(AppAccountsManager.shared)
        .environment(QuickLook.shared)
        .environment(ToastCenter.shared)
        .environment(__iceClient)
        .environment(__iceRouter)
        """)
        """
        let source = ProjectMaterial.mergedSource(
            at: paths.app, files: selectedPackageFiles,
            sourceModules: paths.sourceModules)
            + ProjectMaterial.mergedSource(
                source: probe, moduleName: "IceCubesCheckProbe")
        return try InterpreterHost().renderSession(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS",
                targetEnvironment: "macCatalyst"),
            projectResourceRoot: paths.app,
            lazyTopLevelGlobals: true
        ).get()
    }

    fileprivate static func renderSession(
        for screen: IceCubesCaptureScreen,
        nativeFixtureDirectory: String?
    ) throws -> InterpreterRenderSession {
        let paths = try paths()
        Interpreter.interpretsAsPlatform = "iOS"
        // Which fixtures a screen reads is the screen's own declared fact, not
        // a shape the switch below happens to have: reading it here is what
        // makes a screen added without deciding the question fail loudly.
        let fixtureDirectory: String
        if screen.needsNativeFixtures {
            guard let nativeFixtureDirectory else {
                throw RuntimeError(
                    message:
                        "\(screen.rawValue) capture requires native fixtures")
            }
            fixtureDirectory = nativeFixtureDirectory
        } else {
            fixtureDirectory = paths.fixtures
        }
        let presentation: RenderProbePresentation
        let screenStatusFixture: String?
        switch screen {
        case .timeline:
            presentation = .nativeTimeline
            screenStatusFixture = nil
        case .media:
            presentation = .nativeMedia
            screenStatusFixture = nil
        case .tagsList:
            presentation = .nativeTagsList
            screenStatusFixture = nil
        case .statusDetail, .accountHeader:
            let metadata = try JSONDecoder().decode(
                NativeTwinScreenMetadata.self,
                from: Data(contentsOf: URL(
                    fileURLWithPath: fixtureDirectory)
                    .appendingPathComponent("timeline.json")))
            presentation = screen == .statusDetail
                ? .nativeStatusDetail
                : .nativeAccountHeader
            screenStatusFixture = URL(
                fileURLWithPath: metadata.screenFixtures.status)
                .deletingPathExtension().lastPathComponent
        }
        let source = ProjectMaterial.mergedSource(
            at: paths.app, files: paths.packageFiles,
            sourceModules: paths.sourceModules)
            + ProjectMaterial.mergedSource(
                source: renderProbeSource(
                    includeTimeline: screen == .timeline,
                    includeDetailAndAccount: false,
                    presentation: presentation,
                    screenStatusFixture: screenStatusFixture),
                moduleName: "IceCubesCheckProbe")
        if let dumpPath = ProcessInfo.processInfo.environment[
            "ICECUBES_DUMP_MERGE"
        ] {
            try source.write(toFile: dumpPath, atomically: true, encoding: .utf8)
        }
        NetworkBridge.policy = .replay(
            fixturesDirectory: fixtureDirectory)
        NetworkBridge.requestLog = []
        return try InterpreterHost().renderSession(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS",
                targetEnvironment: "macCatalyst"),
            projectResourceRoot: paths.app,
            lazyTopLevelGlobals: true
        ).get()
    }

#if !targetEnvironment(macCatalyst)
    private static func capture(
        _ screen: IceCubesCaptureScreen,
        to directory: String,
        nativeFixtureDirectory: String?
    ) throws {
        defer { NetworkBridge.policy = .absorbed }
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let session = try renderSession(
            for: screen,
            nativeFixtureDirectory: nativeFixtureDirectory)
        // The scored canvas belongs to the capture harness, never to the probe
        // source: the twin supplies its size and its backing exactly once, at
        // its own root, so a second copy in the interpreted source is a layer
        // the twin does not have. Both interpreted capture paths therefore
        // apply it here, the way `IceCubesCatalystCaptureRoot` does.
        let hosting = NSHostingView(rootView: session.view.frame(
            width: screenSize.width, height: screenSize.height)
            .background(Color.white))
        hosting.frame = NSRect(origin: .zero, size: screenSize)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let initialRenderRevision =
            session.renderActivity.bodyEvaluationCount
        var captureReadiness = InterpreterCaptureReadiness(
            initialRenderRevision: initialRenderRevision)
        func observeCaptureActivity() {
            captureReadiness.observe(
                runtimeActivity: session.interpreter.runtimeActivity,
                renderActivity: session.renderActivity)
        }
        observeCaptureActivity()
        let settleDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat {
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            observeCaptureActivity()
        } while ContinuousClock.now < settleDeadline
        let traceReadiness =
            ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1"
                && ProcessInfo.processInfo.environment[
                    "ICECUBES_TRACE_READINESS"
                ] == "1"
        let readinessDeadline =
            ContinuousClock.now.advanced(by: .seconds(30))
        var previousActivity =
            session.interpreter.runtimeActivity
        var previousRevision =
            session.renderActivity.bodyEvaluationCount
        func printReadinessSample(
            _ activity: InterpreterRuntimeActivity,
            revision: UInt64
        ) {
            print(
                "@@icecubes-readiness-sample"
                    + " revision=\(revision)"
                    + " quiescent=\(activity.isQuiescent)"
                    + " activeTasks=\(activity.activeTaskCount)"
                    + " scheduledTasks=\(activity.scheduledTaskCount)"
                    + " hostOperations="
                    + "\(activity.activeHostOperationCount)"
                    + " continuations="
                    + "\(activity.activeContinuationCount)")
        }
        if traceReadiness {
            printReadinessSample(
                previousActivity, revision: previousRevision)
        }
        while !captureReadiness.isReadyForCapture
            && ContinuousClock.now < readinessDeadline
        {
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            observeCaptureActivity()
            let activity = session.interpreter.runtimeActivity
            let revision =
                session.renderActivity.bodyEvaluationCount
            if traceReadiness
                && (activity != previousActivity
                    || revision != previousRevision)
            {
                printReadinessSample(activity, revision: revision)
                previousActivity = activity
                previousRevision = revision
            }
        }
        let readinessDeadlineReached =
            !captureReadiness.isReadyForCapture
        if traceReadiness {
            print(
                "@@icecubes-capture-readiness"
                    + " ready=\(captureReadiness.isReadyForCapture)"
                    + " deadline=\(readinessDeadlineReached)"
                    + " firstQuiescentRevision="
                    + "\(captureReadiness.firstQuiescentRenderRevision.map(String.init) ?? "none")"
                    + " readyRevision="
                    + "\(captureReadiness.readyRenderRevision.map(String.init) ?? "none")")
        }
        guard captureReadiness.isReadyForCapture else {
            throw RuntimeError(
                message: "capture did not reach owned presentation readiness")
        }
        if ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1" {
            let finalRuntimeActivity = session.interpreter.runtimeActivity
            let finalRenderRevision =
                session.renderActivity.bodyEvaluationCount
            print(
                "@@icecubes-capture-activity"
                    + " observedActive="
                    + "\(captureReadiness.firstActiveRenderRevision != nil)"
                    + " initialRevision=\(initialRenderRevision)"
                    + " firstActiveRevision="
                    + "\(captureReadiness.firstActiveRenderRevision.map(String.init) ?? "none")"
                    + " lastActiveRevision="
                    + "\(captureReadiness.lastActiveRenderRevision.map(String.init) ?? "none")"
                    + " finalRevision=\(finalRenderRevision)"
                    + " finalQuiescent=\(finalRuntimeActivity.isQuiescent)"
                    + " activeTasks=\(finalRuntimeActivity.activeTaskCount)"
                    + " scheduledTasks="
                    + "\(finalRuntimeActivity.scheduledTaskCount)"
                    + " hostOperations="
                    + "\(finalRuntimeActivity.activeHostOperationCount)"
                    + " continuations="
                    + "\(finalRuntimeActivity.activeContinuationCount)")
        }
        for entry in RenderDiagnostics.errors.prefix(20) {
            print("diagnostic\t\(entry.view)\t\(entry.error.message)")
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(screenSize.width), pixelsHigh: Int(screenSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else {
            throw RuntimeError(
                message:
                    "could not allocate \(screen.rawValue) bitmap")
        }
        rep.size = screenSize
        if let hostingLayer = hosting.layer {
            removeAnimations(from: hostingLayer)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RuntimeError(
                message:
                    "could not encode \(screen.rawValue) PNG")
        }
        let output = URL(fileURLWithPath: directory)
            .appendingPathComponent("\(screen.rawValue).png")
        try png.write(to: output, options: .atomic)
        print(
            "\(screen.rawValue)\t\(output.path)\t"
                + "\(Int(screenSize.width))x\(Int(screenSize.height))")

        guard screen == .timeline else { return }
        guard let interpretedClockEpoch = session.interpreter.globals
            .lookup("__iceInterpretedClockEpoch")?.doubleValue
        else {
            throw RuntimeError(
                message: "interpreted capture clock did not materialize")
        }
        let metadata = CaptureMetadata(
            hostClockEpoch: Date().timeIntervalSince1970,
            interpretedClockEpoch: interpretedClockEpoch)
        let metadataOutput = URL(fileURLWithPath: directory)
            .appendingPathComponent("timeline.json")
        try JSONEncoder().encode(metadata).write(
            to: metadataOutput, options: .atomic)
        print("metadata\t\(metadataOutput.path)")
    }
#endif
}
