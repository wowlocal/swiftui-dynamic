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

            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            guard let window =
                    windows.first(where: \.isKeyWindow) ?? windows.first,
                  let rootView = window.rootViewController?.view else {
                throw RuntimeError(
                    message: "Catalyst interpreter has no live window")
            }
            rootView.setNeedsLayout()
            rootView.layoutIfNeeded()
            let captureView =
                fixedSizeDescendant(in: rootView) ?? rootView
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

@main
private struct IceCubesCheckCatalystApp: App {
    @UIApplicationDelegateAdaptor(IceCubesCheckAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        WindowGroup {
            let arguments = Array(CommandLine.arguments.dropFirst())
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
            "shell", "timeline", "detail-account", "pagination",
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
        let root = FileManager.default.currentDirectoryPath
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
            includeTimeline && !includePagination ? """
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
                    .frame(width: \(screenSize.width), height: \(screenSize.height))
                    .background(Color.white)
            """
        case .nativeStatusDetail:
            """
                    NavigationStack {
                        StatusDetailView(status: __iceScreenStatus)
                    }
                    .frame(width: \(screenSize.width), height: \(screenSize.height))
                    .background(Color.white)
            """
        case .nativeAccountHeader:
            """
                    NavigationStack {
                        AccountDetailView(account: __iceScreenStatus.account)
                    }
                    .frame(width: \(screenSize.width), height: \(screenSize.height))
                    .background(Color.white)
            """
        }
        return """

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

    fileprivate static func renderSession(
        for screen: IceCubesCaptureScreen,
        nativeFixtureDirectory: String?
    ) throws -> InterpreterRenderSession {
        let paths = try paths()
        Interpreter.interpretsAsPlatform = "iOS"
        let presentation: RenderProbePresentation
        let fixtureDirectory: String
        let screenStatusFixture: String?
        switch screen {
        case .timeline:
            presentation = .nativeTimeline
            fixtureDirectory = paths.fixtures
            screenStatusFixture = nil
        case .statusDetail, .accountHeader:
            guard let nativeFixtureDirectory else {
                throw RuntimeError(
                    message:
                        "\(screen.rawValue) capture requires native fixtures")
            }
            let metadata = try JSONDecoder().decode(
                NativeTwinScreenMetadata.self,
                from: Data(contentsOf: URL(
                    fileURLWithPath: nativeFixtureDirectory)
                    .appendingPathComponent("timeline.json")))
            presentation = screen == .statusDetail
                ? .nativeStatusDetail
                : .nativeAccountHeader
            fixtureDirectory = nativeFixtureDirectory
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
        let hosting = NSHostingView(rootView: session.view.frame(
            width: screenSize.width, height: screenSize.height))
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
