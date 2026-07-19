import AppKit
import Darwin
import Foundation
import SwiftInterpreter
import SwiftUI
import SwiftUIBridge

// IceCubesCheck is the IceCubes mission instrument (LOOP-ICECUBES.md).
// Expectations below come from the recorded Mastodon response bytes. The
// native twin emits the same values after decoding them with IceCubes' real
// Models package; no author/content/count expectation is invented here.

private struct RungRecord: Codable {
    let name: String
    let passed: Bool
    let message: String
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
    let trendingStatuses: [FixtureStatus]

    init(directory: String) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        publicStatuses = try decoder.decode(
            [FixtureStatus].self,
            from: Data(contentsOf: URL(
                fileURLWithPath: directory + "/api_v1_timelines_public.json")))
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

    static func normalize(_ string: String) -> String {
        string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

@main
struct IceCubesCheckMain {
    private static let workerTimeout: TimeInterval = 85
    private static let screenSize = NSSize(width: 900, height: 700)

    static func main() throws {
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
        if let capture = option("--capture", in: arguments) {
            try captureTimeline(to: capture)
            return
        }
        if let worker = option("--worker", in: arguments),
           let result = option("--result", in: arguments)
        {
            let records: [RungRecord]
            do {
                records = try runWorker(worker)
            } catch {
                records = expectedRungs(for: worker).map {
                    RungRecord(name: $0, passed: false, message: "worker threw: \(error)")
                }
            }
            let data = try JSONEncoder().encode(records)
            try data.write(to: URL(fileURLWithPath: result), options: .atomic)
            return
        }

        let filter = option("--screen", in: arguments)
        let jobs = ["shell", "render"].filter { job in
            guard let filter else { return true }
            return expectedRungs(for: job).contains {
                $0.localizedCaseInsensitiveContains(filter)
            }
        }
        var records: [RungRecord] = []
        for job in jobs {
            records += runTimedWorker(job)
        }
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

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func expectedRungs(for worker: String) -> [String] {
        switch worker {
        case "shell":
            return ["R0-shell"]
        case "render":
            return [
                "R1-timeline", "R1-status-detail", "R1-account-header",
                "R1-boost-attribution", "R1-media-placeholder",
            ]
        default:
            return ["unknown-worker"]
        }
    }

    private static func runTimedWorker(_ worker: String) -> [RungRecord] {
        let resultURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icecubes-check-\(UUID().uuidString).json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--worker", worker, "--result", resultURL.path]
        process.environment = ProcessInfo.processInfo.environment
        do {
            try process.run()
        } catch {
            return expectedRungs(for: worker).map {
                RungRecord(name: $0, passed: false, message: "could not start worker: \(error)")
            }
        }

        let deadline = Date().addingTimeInterval(workerTimeout)
        while process.isRunning, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning, Date() < grace {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return expectedRungs(for: worker).map {
                RungRecord(
                    name: $0, passed: false,
                    message: "\(worker) screen worker exceeded \(Int(workerTimeout))s")
            }
        }

        defer { try? FileManager.default.removeItem(at: resultURL) }
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: resultURL),
              let records = try? JSONDecoder().decode([RungRecord].self, from: data)
        else {
            return expectedRungs(for: worker).map {
                RungRecord(
                    name: $0, passed: false,
                    message: "\(worker) worker exited \(process.terminationStatus) without a result")
            }
        }
        return records
    }

    private static func runWorker(_ worker: String) throws -> [RungRecord] {
        let paths = try paths()
        let oracle = try FixtureOracle(directory: paths.fixtures)
        Interpreter.interpretsAsPlatform = "iOS"
        NetworkBridge.policy = .replay(fixturesDirectory: paths.fixtures)
        NetworkBridge.requestLog = []
        defer { NetworkBridge.policy = .absorbed }

        switch worker {
        case "shell":
            return [try shellRung(paths: paths, oracle: oracle)]
        case "render":
            return try renderRungs(paths: paths, oracle: oracle)
        default:
            return [RungRecord(
                name: "unknown-worker", passed: false,
                message: "unknown worker '\(worker)'")]
        }
    }

    private struct Paths {
        let root: String
        let app: String
        let fixtures: String
        let appFiles: [String]
        let packageFiles: [String]
        let sourceModules: [String: String]
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
        let appFiles = ProjectMaterial.swiftFiles(under: app + "/IceCubesApp")
            + ProjectMaterial.swiftFiles(under: app + "/IceCubesAppIntents")
        guard !packageFiles.isEmpty, !appFiles.isEmpty else {
            throw RuntimeError(message: "IceCubes target source selection is empty")
        }
        return Paths(
            root: root, app: app, fixtures: fixtures,
            appFiles: appFiles.sorted(), packageFiles: packageFiles.sorted(),
            sourceModules: sourceModules)
    }

    private static func shellRung(paths: Paths, oracle: FixtureOracle) throws -> RungRecord {
        let source = ProjectMaterial.mergedSource(
            at: paths.app, files: paths.packageFiles + paths.appFiles,
            sourceModules: paths.sourceModules)
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        let normalized = strings.map(FixtureOracle.normalize)
        var problems: [String] = []
        if LiveCheckSupport.lastRootSymbol != "scene:IceCubesApp" {
            problems.append("root is \(LiveCheckSupport.lastRootSymbol), wanted scene:IceCubesApp")
        }
        let launchAccounts = oracle.trendingStatuses.map(\.visibleAccount.visibleName)
        let visible = launchAccounts.filter { marker in
            normalized.contains { $0.contains(marker) }
        }
        if visible.isEmpty {
            problems.append("no replay author reached the app shell")
        }
        if !NetworkBridge.requestLog.contains(where: {
            $0.hasPrefix("/api/v1/trends/statuses") && $0.hasSuffix("hit")
        }) {
            problems.append("app shell never hit the recorded trending endpoint")
        }
        return RungRecord(
            name: "R0-shell", passed: problems.isEmpty,
            message: problems.joined(separator: "; "))
    }

    private static func renderRungs(
        paths: Paths, oracle: FixtureOracle
    ) throws -> [RungRecord] {
        let source = ProjectMaterial.mergedSource(
            at: paths.app, files: paths.packageFiles,
            sourceModules: paths.sourceModules)
            + renderProbeSource(includeDetailAndAccount: true)
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        let normalized = strings.map(FixtureOracle.normalize)
        if ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1" {
            print("@@icecubes-root \(LiveCheckSupport.lastRootSymbol)")
            print("@@icecubes-lifecycle \(LiveCheckSupport.lastLifecycleFired)")
            for (name, count) in LiveCheckSupport.lastAbsorbedHostMembers
                .sorted(by: { $0.value > $1.value }).prefix(20)
            {
                print("@@icecubes-absorbed \(name) x\(count)")
            }
            for string in normalized where !string.isEmpty {
                print("@@icecubes-string \(string)")
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
            let marker = FixtureOracle.marker(detail.visibleContent)
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
        if let boost = oracle.publicStatuses.first(where: { $0.reblog != nil }) {
            if !contains(boost.account.visibleName) {
                boostProblems.append("missing booster attribution '\(boost.account.visibleName)'")
            }
            if !contains(boost.visibleAccount.visibleName) {
                boostProblems.append("missing boosted author '\(boost.visibleAccount.visibleName)'")
            }
        } else {
            boostProblems.append("recorded public fixture contains no boost; capture a real boosted status")
        }

        var mediaProblems: [String] = []
        if let media = oracle.publicStatuses.lazy.flatMap(\.visibleMedia).first,
           let url = media.previewUrl ?? media.url
        {
            let marker = url.lastPathComponent
            if !contains(marker) {
                mediaProblems.append("missing deterministic media placeholder for '\(marker)'")
            }
        } else {
            mediaProblems.append("recorded public fixture contains no media")
        }

        return [
            record("R1-timeline", timelineProblems),
            record("R1-status-detail", detailProblems),
            record("R1-account-header", accountProblems),
            record("R1-boost-attribution", boostProblems),
            record("R1-media-placeholder", mediaProblems),
        ]
    }

    private static func renderProbeSource(includeDetailAndAccount: Bool) -> String {
        let extraViews = includeDetailAndAccount ? """
                    StatusDetailView(status: __iceTrendingStatuses[0])
                    AccountDetailView(account: __iceTrendingStatuses[0].account)
            """ : ""
        return """

        let __iceDecoder = JSONDecoder()
        __iceDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let __icePublicStatuses = try! __iceDecoder.decode(
            [Status].self, from: __fixtureData("api_v1_timelines_public"))
        let __iceTrendingStatuses = try! __iceDecoder.decode(
            [Status].self, from: __fixtureData("api_v1_trends_statuses"))
        let __iceClient = MastodonClient(server: "mstdn.social")
        let __iceRouter = RouterPath()

        @MainActor
        final class __IceFixtureFetcher: StatusesFetcher {
            var statusesState: StatusesState
            init(statuses: [Status]) {
                statusesState = .display(statuses: statuses, nextPageState: .hasNextPage)
            }
            func fetchNewestStatuses(pullToRefresh: Bool) async {}
            func fetchNextPage() async throws {}
            func statusDidAppear(status: Status) {}
            func statusDidDisappear(status: Status) {}
        }

        let __iceFetcher = __IceFixtureFetcher(statuses: __icePublicStatuses)

        @\u{6D}ain
        struct __IceCubesR1Probe: App {
            var body: some Scene {
                WindowGroup {
                    VStack {
                        SwiftUI.List {
                            StatusesListView(
                                fetcher: __iceFetcher,
                                client: __iceClient,
                                routerPath: __iceRouter,
                                filterContext: .pub)
                        }
                        \(extraViews)
                    }
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

    private static func captureTimeline(to directory: String) throws {
        let paths = try paths()
        Interpreter.interpretsAsPlatform = "iOS"
        NetworkBridge.policy = .replay(fixturesDirectory: paths.fixtures)
        defer { NetworkBridge.policy = .absorbed }
        let source = ProjectMaterial.mergedSource(
            at: paths.app, files: paths.packageFiles,
            sourceModules: paths.sourceModules)
            + renderProbeSource(includeDetailAndAccount: false)

        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let value = try InterpreterHost().render(source: source, lazyTopLevelGlobals: true).get()
        let hosting = NSHostingView(rootView: value.frame(
            width: screenSize.width, height: screenSize.height))
        hosting.frame = NSRect(origin: .zero, size: screenSize)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(screenSize.width), pixelsHigh: Int(screenSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { throw RuntimeError(message: "could not allocate timeline bitmap") }
        rep.size = screenSize
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RuntimeError(message: "could not encode timeline PNG")
        }
        let output = URL(fileURLWithPath: directory).appendingPathComponent("timeline.png")
        try png.write(to: output, options: .atomic)
        print("timeline\t\(output.path)\t\(Int(screenSize.width))x\(Int(screenSize.height))")
    }
}
