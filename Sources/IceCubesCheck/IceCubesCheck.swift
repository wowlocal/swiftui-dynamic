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

@main
struct IceCubesCheckMain {
    // Keep the hard stop below the three-minute instrument contract while
    // leaving realistic headroom for the full-app shell under board load.
    private static let workerTimeout: TimeInterval = 175
    private static let screenSize = NSSize(width: 900, height: 700)

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
        if let capture = option("--capture", in: arguments) {
            try captureTimeline(to: capture)
            return
        }
        if let worker = option("--worker", in: arguments),
           let result = option("--result", in: arguments)
        {
            let records: [RungRecord]
            do {
                records = try await runWorker(worker)
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
        let jobs = ["shell", "timeline", "detail-account"].filter { job in
            guard let filter else { return true }
            return expectedRungs(for: job).contains {
                $0.localizedCaseInsensitiveContains(filter)
            }
        }
        var records: [RungRecord] = []
        records += runTimedWorkers(jobs)
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
        case "timeline":
            return [
                "R1-timeline", "R1-boost-attribution",
                "R1-media-placeholder",
            ]
        case "detail-account":
            return ["R1-status-detail", "R1-account-header"]
        default:
            return ["unknown-worker"]
        }
    }

    private struct TimedWorker {
        let name: String
        let process: Process
        let resultURL: URL
        let deadline: Date
    }

    /// Each screen remains process-isolated, but independent screens run
    /// concurrently so deeper real lifecycle coverage does not make the
    /// complete deterministic board exceed its three-minute contract.
    private static func runTimedWorkers(_ workers: [String]) -> [RungRecord] {
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

    private static func runWorker(_ worker: String) async throws -> [RungRecord] {
        let paths = try paths()
        let oracle = try FixtureOracle(directory: paths.fixtures)
        Interpreter.interpretsAsPlatform = "iOS"
        LiveCheckSupport.traceLifecycle =
            ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1"
        NetworkBridge.policy = .replay(fixturesDirectory: paths.fixtures)
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

    private enum RenderScope: Equatable {
        case timeline
        case detailAndAccount
    }

    private enum RenderProbePresentation {
        case diagnostics
        case nativeTimeline
    }

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
        presentation: RenderProbePresentation
    ) -> String {
        let fixtureDecodes = (includeTimeline ? """
        let __icePublicStatuses = try! __iceDecoder.decode(
            [Status].self, from: __fixtureData("api_v1_timelines_public"))
        let __iceBoostStatus = try! __iceDecoder.decode(
            Status.self,
            from: __fixtureData("api_v1_statuses_116954929935729788"))
        """ : "") + (includeDetailAndAccount ? """
        let __iceTrendingStatuses = try! __iceDecoder.decode(
            [Status].self, from: __fixtureData("api_v1_trends_statuses"))
        """ : "")
        let timelineGlobals = includeTimeline ? """
        let __iceFetcher = __IceFixtureFetcher(
            statuses: __icePublicStatuses + [__iceBoostStatus])
        let __iceFirstRowModel = StatusRowViewModel(
            status: __icePublicStatuses[0],
            client: __iceClient,
            routerPath: __iceRouter,
            filterContext: .pub)
        """ : ""
        let timelineViews = includeTimeline ? """
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
                        __IceRowModelProbe(viewModel: __iceFirstRowModel)
                        __IceMediaProbe(
                            attachments: __iceBoostStatus.reblog?.mediaAttachments
                                ?? __iceBoostStatus.mediaAttachments)
                        StatusRowHeaderView(viewModel: __iceFirstRowModel)
                        StatusRowContentView(viewModel: __iceFirstRowModel)
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

        let __iceDecoder = JSONDecoder()
        __iceDecoder.keyDecodingStrategy = .convertFromSnakeCase
        \(fixtureDecodes)
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
            + ProjectMaterial.mergedSource(
                source: renderProbeSource(
                    includeTimeline: true,
                    includeDetailAndAccount: false,
                    presentation: .nativeTimeline),
                moduleName: "IceCubesCheckProbe")
        if let dumpPath = ProcessInfo.processInfo.environment[
            "ICECUBES_DUMP_MERGE"
        ] {
            try source.write(toFile: dumpPath, atomically: true, encoding: .utf8)
        }

        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let session = try InterpreterHost().renderSession(
            source: source,
            projectResourceRoot: paths.app,
            lazyTopLevelGlobals: true
        ).get()
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
        var firstActiveRenderRevision: UInt64?
        var lastActiveRenderRevision: UInt64?
        func observeCaptureActivity() {
            let runtimeActivity = session.interpreter.runtimeActivity
            guard !runtimeActivity.isQuiescent else { return }
            let revision = session.renderActivity.bodyEvaluationCount
            firstActiveRenderRevision = firstActiveRenderRevision
                ?? revision
            lastActiveRenderRevision = revision
        }
        observeCaptureActivity()
        let settleDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat {
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
            observeCaptureActivity()
        } while ContinuousClock.now < settleDeadline
        var firstQuiescentRenderRevision: UInt64?
        var readyRenderRevision: UInt64?
        var readinessDeadlineReached = false
        let traceReadiness =
            ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1"
                && ProcessInfo.processInfo.environment[
                    "ICECUBES_TRACE_READINESS"
                ] == "1"
        if traceReadiness {
            // This opt-in diagnostic extends only traced captures. The normal
            // R2 path above keeps its exact one-second boundary.
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
            printReadinessSample(
                previousActivity, revision: previousRevision)
            while ContinuousClock.now < readinessDeadline {
                _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let activity = session.interpreter.runtimeActivity
                let revision =
                    session.renderActivity.bodyEvaluationCount
                if activity != previousActivity
                    || revision != previousRevision
                {
                    printReadinessSample(activity, revision: revision)
                    previousActivity = activity
                    previousRevision = revision
                }
                if activity.isQuiescent {
                    firstQuiescentRenderRevision =
                        firstQuiescentRenderRevision ?? revision
                    if let firstActiveRenderRevision,
                       revision > firstActiveRenderRevision
                    {
                        readyRenderRevision = revision
                        break
                    }
                } else {
                    firstQuiescentRenderRevision = nil
                    lastActiveRenderRevision = revision
                }
            }
            // The deadline is a failure guard for the probe, never a second
            // way to declare capture eligibility.
            readinessDeadlineReached = readyRenderRevision == nil
            print(
                "@@icecubes-capture-readiness"
                    + " ready=\(readyRenderRevision != nil)"
                    + " deadline=\(readinessDeadlineReached)"
                    + " firstQuiescentRevision="
                    + "\(firstQuiescentRenderRevision.map(String.init) ?? "none")"
                    + " readyRevision="
                    + "\(readyRenderRevision.map(String.init) ?? "none")")
        }
        if ProcessInfo.processInfo.environment["ICECUBES_TRACE"] == "1" {
            let finalRuntimeActivity = session.interpreter.runtimeActivity
            let finalRenderRevision =
                session.renderActivity.bodyEvaluationCount
            print(
                "@@icecubes-capture-activity"
                    + " observedActive=\(firstActiveRenderRevision != nil)"
                    + " initialRevision=\(initialRenderRevision)"
                    + " firstActiveRevision="
                    + "\(firstActiveRenderRevision.map(String.init) ?? "none")"
                    + " lastActiveRevision="
                    + "\(lastActiveRenderRevision.map(String.init) ?? "none")"
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
