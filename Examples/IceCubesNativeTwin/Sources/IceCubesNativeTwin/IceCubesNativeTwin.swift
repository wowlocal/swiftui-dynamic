// Compiled-native expectation and pixel harness for LOOP-ICECUBES.md.
import Account
import AppAccount
import DesignSystem
import Env
import Explore
import Foundation
import IceCubesAppTarget
import MediaUI
import Models
import NetworkClient
import Nuke
import Observation
import StatusKit
import SwiftUI
import Timeline
import UIKit

private struct TwinMetadata: Codable {
    let fixture: String
    let statusCount: Int
    let displayNames: [String]
    let rawContent: [String]
    let detailMarkdown: String
    let mediaCount: Int
    let focusedMediaURL: String
    let screenFixtures: ScreenFixtureNames
    let requests: [String]
    let clockEpoch: Double
    /// `Date().timeIntervalSinceNow`, which the board requires to be exactly 0.
    ///
    /// `clockEpoch` alone cannot see this: it reads `Date()`, and `Date()` was
    /// frozen while `timeIntervalSinceNow` — which computes its own "now"
    /// inside Foundation — still read the real clock, so the epoch check was
    /// green for weeks over a screen that drew an hourly-ticking timestamp.
    /// One frozen source of wall time is not a frozen clock; every source the
    /// app reaches has to be pinned, and the ones that are not have to be
    /// visible to an exit code rather than to a reviewer.
    let relativeClockDrift: Double
    let width: Int
    let height: Int
}

private struct ScreenFixtureNames: Codable {
    let status: String
    let statusContext: String
    let account: String
    let featuredTags: String
    let accountStatuses: String
    let familiarFollowers: String

    var all: [String] {
        [
            status, statusContext, account, featuredTags,
            accountStatuses, familiarFollowers,
        ]
    }
}

private struct PaginationMetadata: Codable {
    let initialVisibleStatusIDs: [String]
    let initialPageLoads: Int
    let finalPageLoads: Int
    let finalStatusCount: Int
    let appendedStatusID: String
    let appendedStatusBecameVisible: Bool
    let normalizedFixtureNames: [String]
    let interactionFixtureNames: [String]
}

private enum FixtureName {
    static let publicTimeline = "api_v1_timelines_public.json"
    static let trendingStatuses = "api_v1_trends_statuses.json"
    static let trendingTags = "api_v1_trends_tags.json"
    static let boostStatus = "api_v1_statuses_116954929935729788.json"
    static let trendingLinks = "api_v1_trends_links.json"
    static let instance = "api_v2_instance.json"
}

private enum TwinCaptureScreen: String {
    case timeline
    case statusDetail = "status-detail"
    case accountHeader = "account-header"
    case media
    case tagsList = "tags-list"
    case mediaBrowser = "media-browser"
    /// The one scored screen that renders through the app's OWN timeline
    /// machinery. Every other timeline pixel on this board comes from a
    /// harness-supplied `StatusesFetcher` handed a decoded fixture, so
    /// `TimelineView` + `TimelineViewModel` — the real fetch, state and
    /// datasource path a user actually scrolls — were never compared. The
    /// trending filter is the only one the unauthenticated app can drive:
    /// `TimelineFilter.trending`'s endpoint is public (`Trends.statuses`) and
    /// its `isCacheEnabled` is false on all three of its terms, so the screen
    /// reaches the network exactly once and keeps nothing on disk.
    case trendingTimeline = "trending-timeline"
    /// The one scored screen whose rows are not statuses. Every other row on
    /// this board is a `StatusRowView` or an account/tag row; this is the app's
    /// `StatusRowCardView` — a link preview with its own image, title,
    /// description and provider line — which had no pixels on the board at all.
    /// `RouterDestination.trendingLinks` is the route, `Trends.links` is public
    /// and unauthenticated, and the recorded response carries ten cards.
    case trendingLinks = "trending-links"
    /// The first scored screen declared in the app TARGET rather than in one
    /// of its packages. Every other screen on this board comes from
    /// `Packages/*`, because that is all the twin could compile; the app's own
    /// 36 files were unreachable to it and so unscorable forever. `Settings`
    /// pushes `InstanceInfoView` for the current instance, and the screen is a
    /// pure function of the `Instance` it is handed — no fetch, no clock, no
    /// namespace — so the recorded `/api/v2/instance` response drives every
    /// branch of it identically on both sides.
    case instanceInfo = "instance-info"
}

@MainActor
private struct FocusedMediaScreen: View {
    let attachments: [MediaAttachment]

    @Namespace private var namespace
    @State private var namespaceInstalled = false

    var body: some View {
        Group {
            if namespaceInstalled {
                StatusRowMediaPreviewView(
                    attachments: attachments, sensitive: false)
            } else {
                Color.white
            }
        }
            .frame(width: 420, height: 560)
            .environment(Theme.shared)
            .environment(UserPreferences.shared)
            .environment(QuickLook.shared)
            .environment(ToastCenter.shared)
            .background(Color.white)
            .task {
                // The real app dependency graph installs this namespace before
                // media rows are usable. Mirror that interface-inexpressible
                // SwiftUI state in the native harness rather than bypassing it.
                QuickLook.shared.namespace = namespace
                namespaceInstalled = true
            }
    }
}

private enum TwinConfiguration {
    static let size = CGSize(width: 900, height: 700)

    static func option(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static let outputDirectory = option("--out") ?? "/tmp/icecubes-native-twin"
    static let fixtureDirectory = option("--fixtures")
        ?? "../../Fixtures/mastodon-public-timeline"
    static let captureScreen = option("--screen").flatMap(TwinCaptureScreen.init)
    static let capturesNavigationChrome = CommandLine.arguments.contains(
        "--navigation-chrome-probe")
    static let capturesListRowGeometry = CommandLine.arguments.contains(
        "--list-row-geometry-probe")
    static let capturesListSeparatorGeometry = CommandLine.arguments.contains(
        "--list-separator-geometry-probe")
    static let capturesRepeatedRowGeometry = CommandLine.arguments.contains(
        "--repeated-row-geometry-probe")
    static let capturesTargetControlRowGeometry = CommandLine.arguments.contains(
        "--target-control-row-geometry-probe")
    static let capturesSmallBorderedControl = CommandLine.arguments.contains(
        "--small-bordered-control-probe")
    static let capturesPagination = CommandLine.arguments.contains(
        "--pagination-probe")
}

@MainActor
private final class TwinAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = SceneDelegate.self
        }
        return configuration
    }
}

@MainActor
private final class FixtureFetcher: StatusesFetcher {
    let statusesState: StatusesState

    init(statuses: [Status]) {
        statusesState = .display(statuses: statuses, nextPageState: .hasNextPage)
    }

    func fetchNewestStatuses(pullToRefresh: Bool) async {}
    func fetchNextPage() async throws {}
    func statusDidAppear(status: Status) {}
    func statusDidDisappear(status: Status) {}
}

@Observable
@MainActor
private final class PaginationFixtureFetcher: StatusesFetcher {
    var statusesState: StatusesState
    private var nextPage: [Status]
    private(set) var pageLoads = 0
    private(set) var appearedStatusIDs: Set<String> = []

    init(statuses: [Status], nextPage: [Status]) {
        statusesState = .display(
            statuses: statuses, nextPageState: .hasNextPage)
        self.nextPage = nextPage
    }

    func fetchNewestStatuses(pullToRefresh: Bool) async {}

    func fetchNextPage() async throws {
        guard !nextPage.isEmpty,
              case .display(let statuses, _) = statusesState
        else { return }
        let appended = nextPage
        nextPage = []
        pageLoads += 1
        statusesState = .display(
            statuses: statuses + appended, nextPageState: .none)
    }

    func statusDidAppear(status: Status) {
        appearedStatusIDs.insert(status.id)
    }

    func statusDidDisappear(status: Status) {}
}

@MainActor
private struct PublicTimelineScreen<Fetcher: StatusesFetcher>: View {
    let fetcher: Fetcher
    let client: MastodonClient
    let routerPath: RouterPath

    var body: some View {
        NavigationStack {
            List {
                StatusesListView(
                    fetcher: fetcher,
                    client: client,
                    routerPath: routerPath,
                    filterContext: .pub
                )
            }
            .listStyle(.plain)
            .navigationTitle(TimelineFilter.federated.title)
        }
        .twinAppEnvironment(client: client, routerPath: routerPath)
    }
}

@MainActor
private struct TwinNavigationScreen<Content: View>: View {
    let client: MastodonClient
    let routerPath: RouterPath
    let content: Content

    init(
        client: MastodonClient,
        routerPath: RouterPath,
        @ViewBuilder content: () -> Content
    ) {
        self.client = client
        self.routerPath = routerPath
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
        }
        .twinAppEnvironment(client: client, routerPath: routerPath)
    }
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

    @MainActor
    func twinAppEnvironment(
        client: MastodonClient,
        routerPath: RouterPath
    ) -> some View {
        self
        .environment(Theme.shared)
        .environment(CurrentAccount.shared)
        .environment(CurrentInstance.shared)
        .environment(UserPreferences.shared)
        .environment(StreamWatcher.shared)
        .environment(AppAccountsManager.shared)
        .environment(QuickLook.shared)
        .environment(ToastCenter.shared)
        .environment(client)
        .environment(routerPath)
        .environment(\.colorScheme, .light)
    }
}

@MainActor
private struct TwinDriverView: View {
    private enum CapturedScreen {
        case statusDetail(Status)
        case accountHeader(Account)
        case tagsList([Tag])
        case mediaBrowser(MediaAttachment, [MediaAttachment])
        /// Carries no payload: the app's own view model does the fetching, so
        /// the screen is defined by the filter alone and its statuses arrive
        /// through the replayed endpoint rather than from this driver.
        case trendingTimeline
        /// Carries its cards the way the app's own route does:
        /// `RouterDestination.trendingLinks(cards:)` is pushed with an
        /// already-fetched `[Card]`, so the driver hands them in rather than
        /// letting the view fetch its own first page.
        case trendingLinks([Card])
        /// Carries the decoded `/api/v2/instance` response the way
        /// `SettingsTab` hands it over: an already-fetched `Instance`. The
        /// view itself never fetches.
        case instanceInfo(Instance)
    }

    @State private var statuses: [Status] = []
    @State private var paginationFetcher: PaginationFixtureFetcher?
    @State private var focusedMedia: [MediaAttachment]?
    @State private var capturedScreen: CapturedScreen?
    @State private var capturedScreenIdentity = UUID()
    @State private var started = false
    private let client = MastodonClient(server: "mstdn.social")
    private let routerPath = RouterPath()

    var body: some View {
        Group {
            if TwinConfiguration.capturesNavigationChrome {
                NavigationChromeProbe()
            } else if TwinConfiguration.capturesListRowGeometry {
                ListRowGeometryProbe()
            } else if TwinConfiguration.capturesListSeparatorGeometry {
                ListSeparatorGeometryProbe()
            } else if TwinConfiguration.capturesRepeatedRowGeometry {
                RepeatedRowGeometryProbe()
            } else if TwinConfiguration.capturesTargetControlRowGeometry {
                TargetControlRowGeometryProbe()
            } else if TwinConfiguration.capturesSmallBorderedControl {
                SmallBorderedControlProbe()
            } else if let paginationFetcher {
                PublicTimelineScreen(
                    fetcher: paginationFetcher,
                    client: client,
                    routerPath: routerPath)
            } else if let capturedScreen {
                switch capturedScreen {
                case .statusDetail(let status):
                    TwinNavigationScreen(
                        client: client, routerPath: routerPath
                    ) {
                        StatusDetailView(status: status)
                    }
                    .id(capturedScreenIdentity)
                case .accountHeader(let account):
                    TwinNavigationScreen(
                        client: client, routerPath: routerPath
                    ) {
                        AccountDetailView(account: account)
                    }
                    .id(capturedScreenIdentity)
                case .tagsList(let tags):
                    TwinNavigationScreen(
                        client: client, routerPath: routerPath
                    ) {
                        TagsListView(tags: tags)
                    }
                    .id(capturedScreenIdentity)
                case .trendingLinks(let cards):
                    TwinNavigationScreen(
                        client: client, routerPath: routerPath
                    ) {
                        // Exactly what `RouterDestination.trendingLinks`
                        // builds (AppRegistry.swift:124). Nothing about the
                        // rows is restated here — `StatusRowCardView` and the
                        // `\.isCompact` environment it reads come from the
                        // merged Explore and StatusKit packages.
                        TrendingLinksListView(cards: cards)
                    }
                    .id(capturedScreenIdentity)
                case .instanceInfo(let instance):
                    TwinNavigationScreen(
                        client: client, routerPath: routerPath
                    ) {
                        // The app's own `InstanceInfoView`, compiled from
                        // `IceCubesApp/App/Tabs/Settings/InstanceInfoView.swift`
                        // itself. It is `internal` to the app, so it arrives
                        // through the one public accessor in
                        // `IceCubesAppTarget` rather than being restated here
                        // — the Form, the section layout and the rules list
                        // are the app's, not the harness's.
                        AppTargetScreen.instanceInfo(instance: instance)
                    }
                    .id(capturedScreenIdentity)
                case .trendingTimeline:
                    TwinNavigationScreen(
                        client: client, routerPath: routerPath
                    ) {
                        // Exactly what `RouterDestination.trendingTimeline`
                        // builds (AppRegistry.swift:118) — constant bindings
                        // and `canFilterTimeline: false` are the app's own
                        // arguments, not a harness simplification.
                        TimelineView(
                            timeline: .constant(.trending),
                            pinnedFilters: .constant([]),
                            selectedTagGroup: .constant(nil),
                            canFilterTimeline: false)
                    }
                    .id(capturedScreenIdentity)
                case .mediaBrowser(let selected, let attachments):
                    // `MediaUIView` brings its OWN NavigationStack (its toolbar
                    // lives in it), so it is hosted through the app environment
                    // directly rather than through `TwinNavigationScreen` —
                    // nesting a second stack would put chrome on the screen
                    // that the app never shows.
                    MediaUIView(
                        selectedAttachment: selected,
                        attachments: attachments
                    )
                    .twinAppEnvironment(
                        client: client, routerPath: routerPath)
                    .id(capturedScreenIdentity)
                }
            } else if let focusedMedia {
                FocusedMediaScreen(attachments: focusedMedia)
            } else if statuses.isEmpty {
                ProgressView("Loading recorded public timeline")
            } else {
                PublicTimelineScreen(
                    fetcher: FixtureFetcher(statuses: statuses),
                    client: client,
                    routerPath: routerPath)
            }
        }
        .hidingCaptureScrollEdgeEffects()
        .frame(width: TwinConfiguration.size.width, height: TwinConfiguration.size.height)
        .background(Color.white)
        .task {
            guard !started else { return }
            started = true
            await driveCapture()
        }
    }

    private func driveCapture() async {
        do {
            // What `IceCubesApp.init()` installs before any scene exists
            // (IceCubesApp.swift:94). `TimelineViewModel` signals telemetry
            // from its own datasource path, and TelemetryDeck traps on an
            // uninitialized shared manager — so a harness that skips this
            // cannot host the app's real timeline at all. Mirroring the app's
            // launch is the same rule the QuickLook namespace already follows;
            // the signals themselves reach the fail-closed replay transport.
            Telemetry.setup()
            // Pin the geometry BEFORE any screen settles so every screen lays
            // out once, at the size it is scored at — the interpreted harness
            // pins at the same point.
            try await pinCaptureGeometry()
            if TwinConfiguration.capturesNavigationChrome {
                try await Task.sleep(for: .seconds(1))
                try await capturePNG(named: "navigation-chrome")
                exit(0)
            }
            if TwinConfiguration.capturesListRowGeometry {
                try await Task.sleep(for: .seconds(1))
                try await capturePNG(named: "list-row-geometry")
                exit(0)
            }
            if TwinConfiguration.capturesListSeparatorGeometry {
                try await Task.sleep(for: .seconds(1))
                try await capturePNG(named: "list-separator-geometry")
                exit(0)
            }
            if TwinConfiguration.capturesRepeatedRowGeometry {
                try await Task.sleep(for: .seconds(1))
                try await capturePNG(named: "repeated-row-geometry")
                exit(0)
            }
            if TwinConfiguration.capturesTargetControlRowGeometry {
                try await Task.sleep(for: .seconds(1))
                try await capturePNG(named: "target-control-row-geometry")
                exit(0)
            }
            if TwinConfiguration.capturesSmallBorderedControl {
                try await Task.sleep(for: .seconds(1))
                try await capturePNG(named: "small-bordered-control")
                exit(0)
            }
            if TwinConfiguration.capturesPagination {
                try await drivePagination()
                exit(0)
            }
            let decoded: [Status] = try await client.get(
                endpoint: Timelines.pub(
                    sinceId: nil, maxId: nil, minId: nil,
                    local: false, limit: 50))
            let detailData = try Data(contentsOf: URL(
                fileURLWithPath: TwinConfiguration.fixtureDirectory)
                .appendingPathComponent("api_v1_trends_statuses.json"))
            let detailDecoder = JSONDecoder()
            detailDecoder.keyDecodingStrategy = .convertFromSnakeCase
            let detailStatuses = try detailDecoder.decode(
                [Status].self, from: detailData)
            guard let detailStatus = detailStatuses.first else {
                throw NSError(
                    domain: "IceCubesNativeTwin", code: 4,
                    userInfo: [NSLocalizedDescriptionKey:
                        "recorded trending fixture has no detail status"])
            }
            let boostData = try Data(contentsOf: URL(
                fileURLWithPath: TwinConfiguration.fixtureDirectory)
                .appendingPathComponent(FixtureName.boostStatus))
            let boostStatus = try detailDecoder.decode(Status.self, from: boostData)
            guard let imageAttachment = boostStatus.reblog?.mediaAttachments.first,
                  imageAttachment.supportedType == .image,
                  let imageURL = imageAttachment.url else {
                throw NSError(
                    domain: "IceCubesNativeTwin", code: 5,
                    userInfo: [NSLocalizedDescriptionKey:
                        "recorded boost fixture has no supported image attachment"])
            }
            let tagsData = try Data(contentsOf: URL(
                fileURLWithPath: TwinConfiguration.fixtureDirectory)
                .appendingPathComponent(FixtureName.trendingTags))
            let trendingTags = try detailDecoder.decode(
                [Tag].self, from: tagsData)
            guard !trendingTags.isEmpty else {
                throw NSError(
                    domain: "IceCubesNativeTwin", code: 7,
                    userInfo: [NSLocalizedDescriptionKey:
                        "recorded trending-tags fixture has no tags"])
            }
            let linksData = try Data(contentsOf: URL(
                fileURLWithPath: TwinConfiguration.fixtureDirectory)
                .appendingPathComponent(FixtureName.trendingLinks))
            let trendingLinks = try detailDecoder.decode(
                [Card].self, from: linksData)
            guard !trendingLinks.isEmpty else {
                throw NSError(
                    domain: "IceCubesNativeTwin", code: 8,
                    userInfo: [NSLocalizedDescriptionKey:
                        "recorded trending-links fixture has no cards"])
            }
            let instanceData = try Data(contentsOf: URL(
                fileURLWithPath: TwinConfiguration.fixtureDirectory)
                .appendingPathComponent(FixtureName.instance))
            let instance = try detailDecoder.decode(
                Instance.self, from: instanceData)
            guard let instanceRules = instance.rules, !instanceRules.isEmpty,
                  instance.contact.account != nil else {
                throw NSError(
                    domain: "IceCubesNativeTwin", code: 9,
                    userInfo: [NSLocalizedDescriptionKey:
                        "recorded instance fixture has no rules or contact "
                        + "account, so the screen would score empty sections"])
            }
            let replayStatuses = decoded + [boostStatus]
            let screenFixtures = try prepareScreenFixtures(
                detailStatus: detailStatus)
            ReplayURLProtocol.prependFixtures(
                TwinConfiguration.outputDirectory)
            switch TwinConfiguration.captureScreen {
            case .timeline:
                try await captureTimeline(statuses: replayStatuses)
                try captureMetadata(
                    statuses: replayStatuses,
                    detailStatus: detailStatus,
                    focusedMediaURL: imageURL,
                    screenFixtures: screenFixtures.names)
            case .statusDetail:
                try await captureStatusDetail(
                    detailStatus, endpoints: screenFixtures.detailEndpoints)
            case .accountHeader:
                try await captureAccountHeader(
                    detailStatus.account,
                    endpoints: screenFixtures.accountEndpoints)
            case .media:
                try await captureMedia([imageAttachment])
            case .tagsList:
                try await captureTagsList(trendingTags)
            case .mediaBrowser:
                try await captureMediaBrowser(
                    selected: imageAttachment,
                    attachments: [imageAttachment])
            case .trendingTimeline:
                try await captureTrendingTimeline()
            case .trendingLinks:
                try await captureTrendingLinks(trendingLinks)
            case .instanceInfo:
                try await captureInstanceInfo(instance)
            case nil:
                try await captureTimeline(statuses: replayStatuses)
                try await captureStatusDetail(
                    detailStatus, endpoints: screenFixtures.detailEndpoints)
                try await captureAccountHeader(
                    detailStatus.account,
                    endpoints: screenFixtures.accountEndpoints)
                try await captureMedia([imageAttachment])
                try await captureTagsList(trendingTags)
                try await captureMediaBrowser(
                    selected: imageAttachment,
                    attachments: [imageAttachment])
                try await captureTrendingTimeline()
                try await captureTrendingLinks(trendingLinks)
                try await captureInstanceInfo(instance)
                try captureMetadata(
                    statuses: replayStatuses,
                    detailStatus: detailStatus,
                    focusedMediaURL: imageURL,
                    screenFixtures: screenFixtures.names)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("IceCubesNativeTwin: \(error)\n".utf8))
            exit(2)
        }
    }

    private func captureTimeline(
        statuses replayStatuses: [Status]
    ) async throws {
        statuses = replayStatuses
        // Let SwiftUI install the List hierarchy and let deterministic replay
        // image requests settle before rasterizing the live view.
        try await Task.sleep(for: .seconds(1))
        try await capturePNG(named: TwinCaptureScreen.timeline.rawValue)
    }

    private func captureStatusDetail(
        _ status: Status,
        endpoints: [any Endpoint]
    ) async throws {
        statuses = []
        capturedScreen = .statusDetail(status)
        capturedScreenIdentity = UUID()
        try await waitForRequests(endpoints)
        try await waitForScreenTransition()
        try await capturePNG(named: TwinCaptureScreen.statusDetail.rawValue)
    }

    private func captureAccountHeader(
        _ account: Account,
        endpoints: [any Endpoint]
    ) async throws {
        statuses = []
        capturedScreen = .accountHeader(account)
        capturedScreenIdentity = UUID()
        try await waitForRequests(endpoints)
        try await waitForScreenTransition()
        try await capturePNG(named: TwinCaptureScreen.accountHeader.rawValue)
    }

    /// The trending-tags list, scored as its own screen. It is the app's own
    /// public `TagsListView` — the screen `RouterDestination.tagsList` pushes —
    /// driven by the recorded `/api/v1/trends/tags` bytes. Those bytes carry no
    /// `following` key, so decoding them runs `Tag.init(from:)`'s
    /// `catch DecodingError.keyNotFound` fallback rather than a synthesized
    /// memberwise decode, and each row draws a Swift Charts `AreaMark` sparkline.
    /// The app's own `TimelineView`, fetching through its own view model. No
    /// statuses are handed in: waiting on the endpoint the app's filter chose
    /// is what proves the fetch actually ran, so a screen that rendered its
    /// loading state forever fails loudly instead of being captured empty.
    private func captureTrendingTimeline() async throws {
        statuses = []
        capturedScreen = .trendingTimeline
        capturedScreenIdentity = UUID()
        try await waitForRequests([Trends.statuses(offset: nil)])
        try await waitForScreenTransition()
        try await capturePNG(
            named: TwinCaptureScreen.trendingTimeline.rawValue)
    }

    private func captureTagsList(_ tags: [Tag]) async throws {
        statuses = []
        capturedScreen = .tagsList(tags)
        capturedScreenIdentity = UUID()
        try await waitForScreenTransition()
        try await capturePNG(named: TwinCaptureScreen.tagsList.rawValue)
    }

    /// The trending-links list, scored as its own screen. Its rows are the
    /// app's `StatusRowCardView` — the only row type on this board that is not
    /// a status, an account or a tag. Each card's `image` is a remote URL the
    /// replay protocol answers with its one deterministic solid PNG, so what
    /// this screen measures is the app's own CARD layout — the image frame it
    /// reserves, the title/description line breaking, and the provider line —
    /// rather than image bytes. The cards are handed in exactly as
    /// `RouterDestination.trendingLinks(cards:)` receives them, so the view's
    /// own `NextPageView` footer is the only request this screen makes.
    private func captureTrendingLinks(_ cards: [Card]) async throws {
        statuses = []
        capturedScreen = .trendingLinks(cards)
        capturedScreenIdentity = UUID()
        try await waitForScreenTransition()
        try await capturePNG(named: TwinCaptureScreen.trendingLinks.rawValue)
    }

    /// The app's instance-info screen, and the first scored screen whose code
    /// lives in the app TARGET rather than in one of its packages. What it
    /// measures that no package screen could is the app's own `Form` — its
    /// `LabeledContent` rows, its section headers, its monospaced version
    /// fields and its numbered rules list — plus one `AccountsListRow` for the
    /// contact account, whose avatar resolves to the replay protocol's
    /// deterministic PNG.
    ///
    /// It is the most trivially deterministic screen on the board: no fetch,
    /// no clock, no namespace and no animation. The `Instance` is decoded from
    /// the recorded `/api/v2/instance` response and handed in, exactly as
    /// `SettingsTab` hands over the instance it already holds.
    private func captureInstanceInfo(_ instance: Instance) async throws {
        statuses = []
        capturedScreen = .instanceInfo(instance)
        capturedScreenIdentity = UUID()
        try await waitForScreenTransition()
        try await capturePNG(named: TwinCaptureScreen.instanceInfo.rawValue)
    }

    /// The media preview surface, scored as its own screen. Every attachment
    /// URL resolves to the replay protocol's one deterministic solid PNG, so
    /// what this screen measures is the app's own media LAYOUT — aspect ratio,
    /// corner radius, and the frame it reserves — rather than image bytes.
    private func captureMedia(
        _ attachments: [MediaAttachment]
    ) async throws {
        statuses = []
        capturedScreen = nil
        focusedMedia = attachments
        try await Task.sleep(for: .seconds(1))
        try await capturePNG(named: TwinCaptureScreen.media.rawValue)
    }

    /// The full-screen media browser, scored as its own screen: the app's own
    /// public `MediaUIView` — what tapping an attachment opens. It is the first
    /// scored screen that is not a `List`, and it is the only one whose body
    /// reaches the modern scroll API (`containerRelativeFrame`,
    /// `scrollTargetLayout`, `scrollTargetBehavior(.viewAligned)`,
    /// `scrollPosition(id:)`) and a `ToolbarContent` type of its own.
    ///
    /// `MediaUIView` reveals its toolbar from a `DispatchQueue.main.asyncAfter`
    /// 0.15s after `onAppear` — the toolbar is bound to `scrolledItem`, which is
    /// nil until then. The settle below is longer than that delay on BOTH
    /// sides, so what is scored is the settled screen rather than whichever
    /// side won a race; the board's reproducibility gate is what proves it.
    private func captureMediaBrowser(
        selected: MediaAttachment,
        attachments: [MediaAttachment]
    ) async throws {
        statuses = []
        focusedMedia = nil
        capturedScreen = .mediaBrowser(selected, attachments)
        capturedScreenIdentity = UUID()
        try await waitForScreenTransition()
        try await Task.sleep(for: .seconds(1))
        try await capturePNG(named: TwinCaptureScreen.mediaBrowser.rawValue)
    }

    private func drivePagination() async throws {
        let fixtureRoot = URL(
            fileURLWithPath: TwinConfiguration.fixtureDirectory)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let publicStatuses = try decoder.decode(
            [Status].self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent(
                FixtureName.publicTimeline)))
        let trendingStatuses = try decoder.decode(
            [Status].self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent(
                FixtureName.trendingStatuses)))
        let boostStatus = try decoder.decode(
            Status.self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent(
                FixtureName.boostStatus)))
        guard let appendedStatus = trendingStatuses.first else {
            throw NSError(
                domain: "IceCubesNativeTwin", code: 6,
                userInfo: [NSLocalizedDescriptionKey:
                    "recorded trending fixture has no pagination status"])
        }

        let fetcher = PaginationFixtureFetcher(
            statuses: publicStatuses, nextPage: [appendedStatus])
        paginationFetcher = fetcher

        let viewportDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        var scrollView: UIScrollView?
        repeat {
            await Task.yield()
            scrollView = deepestScrollableView()
            if !fetcher.appearedStatusIDs.isEmpty, scrollView != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < viewportDeadline

        guard let scrollView else {
            throw NSError(
                domain: "IceCubesNativeTwin", code: 7,
                userInfo: [NSLocalizedDescriptionKey:
                    "native timeline never produced a scrollable viewport"])
        }
        let initiallyVisible = fetcher.appearedStatusIDs.sorted()
        guard !initiallyVisible.isEmpty, fetcher.pageLoads == 0 else {
            throw NSError(
                domain: "IceCubesNativeTwin", code: 8,
                userInfo: [NSLocalizedDescriptionKey:
                    "pagination footer loaded before the native scroll"])
        }

        let paginationDeadline =
            ContinuousClock.now.advanced(by: .seconds(10))
        repeat {
            scrollToEnd(scrollView)
            try await Task.sleep(for: .milliseconds(25))
        } while (fetcher.pageLoads != 1
                    || !fetcher.appearedStatusIDs.contains(appendedStatus.id))
            && ContinuousClock.now < paginationDeadline

        let finalCount: Int
        if case .display(let finalStatuses, _) = fetcher.statusesState {
            finalCount = finalStatuses.count
        } else {
            finalCount = 0
        }
        let interactionEndpoints: [any Endpoint] = [
            Statuses.status(id: appendedStatus.id),
            Statuses.context(id: appendedStatus.id),
        ]
        let interactionFixtureNames = interactionEndpoints.map(
            replayFixtureName)
        let normalizedFixtureNames = [
            FixtureName.publicTimeline,
            FixtureName.trendingStatuses,
            FixtureName.boostStatus,
        ]
        let metadata = PaginationMetadata(
            initialVisibleStatusIDs: initiallyVisible,
            initialPageLoads: 0,
            finalPageLoads: fetcher.pageLoads,
            finalStatusCount: finalCount,
            appendedStatusID: appendedStatus.id,
            appendedStatusBecameVisible:
                fetcher.appearedStatusIDs.contains(appendedStatus.id),
            normalizedFixtureNames: normalizedFixtureNames,
            interactionFixtureNames: interactionFixtureNames)
        guard metadata.finalPageLoads == 1,
              metadata.finalStatusCount == publicStatuses.count + 1,
              metadata.appendedStatusBecameVisible
        else {
            throw NSError(
                domain: "IceCubesNativeTwin", code: 9,
                userInfo: [NSLocalizedDescriptionKey:
                    "native pagination interaction did not reach its final state"])
        }

        try FileManager.default.createDirectory(
            atPath: TwinConfiguration.outputDirectory,
            withIntermediateDirectories: true)
        let outputDirectory = URL(
            fileURLWithPath: TwinConfiguration.outputDirectory)
        let encoder = JSONEncoder()
        try encoder.encode(publicStatuses).write(
            to: outputDirectory.appendingPathComponent(
                FixtureName.publicTimeline),
            options: .atomic)
        try encoder.encode(trendingStatuses).write(
            to: outputDirectory.appendingPathComponent(
                FixtureName.trendingStatuses),
            options: .atomic)
        try encoder.encode(boostStatus).write(
            to: outputDirectory.appendingPathComponent(
                FixtureName.boostStatus),
            options: .atomic)
        try encoder.encode(appendedStatus).write(
            to: outputDirectory.appendingPathComponent(
                interactionFixtureNames[0]),
            options: .atomic)
        try encodeEmptyCollectionRecord(StatusContext.empty()).write(
            to: outputDirectory.appendingPathComponent(
                interactionFixtureNames[1]),
            options: .atomic)
        let output = outputDirectory.appendingPathComponent(
            "pagination.json")
        try encoder.encode(metadata).write(
            to: output, options: .atomic)
        print(
            "pagination\t\(output.path)"
                + "\tvisible=\(metadata.initialVisibleStatusIDs.count)"
                + " loads=\(metadata.finalPageLoads)"
                + " statuses=\(metadata.finalStatusCount)")
    }

    private func replayFixtureName(_ endpoint: any Endpoint) -> String {
        ["api", MastodonClient.Version.v1.rawValue, endpoint.path()]
            .joined(separator: "/")
            .split(separator: "/")
            .joined(separator: "_")
            + ".json"
    }

    private struct ScreenFixtures {
        let names: ScreenFixtureNames
        let detailEndpoints: [any Endpoint]
        let accountEndpoints: [any Endpoint]
    }

    private func prepareScreenFixtures(
        detailStatus: Status
    ) throws -> ScreenFixtures {
        let account = detailStatus.account
        let detailEndpoints: [any Endpoint] = [
            Statuses.status(id: detailStatus.id),
            Statuses.context(id: detailStatus.id),
        ]
        let accountEndpoints: [any Endpoint] = [
            Accounts.accounts(id: account.id),
            Accounts.featuredTags(id: account.id),
            Accounts.statuses(
                id: account.id, sinceId: nil, tag: nil,
                onlyMedia: false, excludeReplies: false,
                excludeReblogs: false, pinned: nil),
            Accounts.familiarFollowers(withAccount: account.id),
        ]
        let outputDirectory = URL(
            fileURLWithPath: TwinConfiguration.outputDirectory)
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let payloads: [(any Endpoint, Data)] = [
            (detailEndpoints[0], try encoder.encode(detailStatus)),
            (
                detailEndpoints[1],
                try encodeEmptyCollectionRecord(StatusContext.empty())
            ),
            (accountEndpoints[0], try encoder.encode(account)),
            (accountEndpoints[1], try encoder.encode([FeaturedTag]())),
            (accountEndpoints[2], try encoder.encode([detailStatus])),
            (
                accountEndpoints[3],
                try JSONSerialization.data(withJSONObject: [])
            ),
        ]
        for (endpoint, data) in payloads {
            try data.write(
                to: outputDirectory.appendingPathComponent(
                    replayFixtureName(endpoint)),
                options: .atomic)
        }
        let fixtureNames = payloads.map { replayFixtureName($0.0) }
        return ScreenFixtures(
            names: ScreenFixtureNames(
                status: fixtureNames[0],
                statusContext: fixtureNames[1],
                account: fixtureNames[2],
                featuredTags: fixtureNames[3],
                accountStatuses: fixtureNames[4],
                familiarFollowers: fixtureNames[5]),
            detailEndpoints: detailEndpoints,
            accountEndpoints: accountEndpoints)
    }

    private func waitForRequests(
        _ endpoints: [any Endpoint]
    ) async throws {
        let expected = Set(endpoints.map {
            "/api/\(MastodonClient.Version.v1.rawValue)/\($0.path())"
        })
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !expected.isSubset(of: Set(ReplayURLProtocol.requests)),
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(25))
        }
        let missing = expected.subtracting(ReplayURLProtocol.requests)
        guard missing.isEmpty else {
            throw NSError(
                domain: "IceCubesNativeTwin", code: 12,
                userInfo: [NSLocalizedDescriptionKey:
                    "native screen omitted requests \(missing.sorted())"])
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    /// Screen roots are replaced in-place by the capture driver. Give native
    /// navigation/layout transactions time to complete after replay reaches
    /// its final request state so the oracle never samples a transition frame.
    private func waitForScreenTransition() async throws {
        try await Task.sleep(for: .seconds(1))
    }

    /// Some target interactions need a native value whose interface exposes
    /// Decodable but not Encodable. Derive an empty-collection record from
    /// compiled storage labels instead of transcribing its response fields.
    private func encodeEmptyCollectionRecord(_ value: Any) throws -> Data {
        var object: [String: Any] = [:]
        for child in Mirror(reflecting: value).children {
            guard let label = child.label else {
                throw NSError(
                    domain: "IceCubesNativeTwin", code: 10,
                    userInfo: [NSLocalizedDescriptionKey:
                        "native record storage has an unlabeled field"])
            }
            let field = Mirror(reflecting: child.value)
            guard field.displayStyle == .collection,
                  field.children.isEmpty else {
                throw NSError(
                    domain: "IceCubesNativeTwin", code: 11,
                    userInfo: [NSLocalizedDescriptionKey:
                        "native record field \(label) is not empty collection storage"])
            }
            object[label] = []
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func deepestScrollableView() -> UIScrollView? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let root = (
            windows.first(where: \.isKeyWindow) ?? windows.first
        )?.rootViewController?.view else {
            return nil
        }
        root.setNeedsLayout()
        root.layoutIfNeeded()
        return scrollViews(in: root)
            .filter {
                $0.contentSize.height > $0.bounds.height
                    && !$0.isHidden && $0.alpha > 0
            }
            .max {
                ($0.contentSize.height - $0.bounds.height)
                    < ($1.contentSize.height - $1.bounds.height)
            }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews(in:))
    }

    private func scrollToEnd(_ scrollView: UIScrollView) {
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        let bottom = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom)
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: bottom),
            animated: false)
        scrollView.layoutIfNeeded()
    }

    /// The one view every capture is taken from. Resolved through a single
    /// function so the geometry dump and the rasterization can never describe
    /// different views — a dump of a view the PNG did not come from would be
    /// worse than no dump at all.
    private func currentCaptureView() throws -> UIView {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              let rootView = window.rootViewController?.view else {
            throw NSError(
                domain: "IceCubesNativeTwin", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Catalyst app has no live window"])
        }
        rootView.setNeedsLayout()
        rootView.layoutIfNeeded()
        guard let captureView = fixedSizeDescendant(in: rootView) else {
            throw NSError(
                domain: "IceCubesNativeTwin", code: 14,
                userInfo: [NSLocalizedDescriptionKey:
                    "no view at the scored size \(TwinConfiguration.size);"
                    + " the window root is \(rootView.bounds.size)."
                    + " Capturing anything else rescales the screen — fix the"
                    + " capture, not the floor."])
        }
        return captureView
    }

    private func rasterizeHierarchyPNG() throws -> Data {
        let captureView = try currentCaptureView()
        removeAnimations(from: captureView.layer)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        // Pinned for the same reason as the interpreted harness: left
        // `.automatic`, this process resolved to Display P3 16-bit while
        // IceCubesCheck resolved to sRGB 8-bit, and the board scored that
        // format gap as interpreter fidelity. Both sides must name the range.
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: TwinConfiguration.size, format: format)
        // `drawHierarchy` is the only capture that materializes Catalyst
        // hosting-layer contents (an in-process `layer.render(in:)` draws
        // hosted SwiftUI content blank). Its window-server round trip is why
        // captures must stay serialized and animation-free — see the R2
        // determinism gate in Scripts/icecubes-r2.sh.
        let image = renderer.image { _ in
            captureView.drawHierarchy(
                in: CGRect(origin: .zero, size: TwinConfiguration.size),
                afterScreenUpdates: true)
        }
        CaptureGeometryDump.record(format: format, product: image)
        guard let png = image.pngData() else {
            throw NSError(
                domain: "IceCubesNativeTwin", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "live hierarchy produced no PNG"])
        }
        return png
    }

    /// A capture is written only once two consecutive rasterizations of the
    /// hierarchy are byte-identical, so the oracle can never sample a
    /// transition or mid-decode frame — the R2 twin divergence of 2026-07-30
    /// (71k AE between two same-state runs) was exactly such a frame slipping
    /// past a wall-clock settle sleep.
    /// `drawHierarchy(in:)` SCALES whatever view it is handed into the
    /// destination rect, so a capture view that is not exactly the scored size
    /// yields a resampled picture rather than the app's own pixels — silently,
    /// because the result still looks like the screen. Measured 2026-08-04:
    /// `media` hosts no scroll view, so it had no descendant at the scored
    /// size and the capture fell back to the whole 1330x990 Catalyst window,
    /// squashed 0.677x0.707. Pinning the SCENE to the scored size makes the
    /// window root itself an exact-size capture view on every screen, whatever
    /// that screen hosts, so the match can be required instead of hoped for.
    private func pinCaptureGeometry() async throws {
        let target = TwinConfiguration.size
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var lastObserved: CGSize?
        while true {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            if let window = windows.first(where: \.isKeyWindow) ?? windows.first,
               let rootView = window.rootViewController?.view {
                if let restrictions = window.windowScene?.sizeRestrictions {
                    restrictions.minimumSize = target
                    restrictions.maximumSize = target
                }
                // Pinning the SIZE is not enough to pin the picture: every
                // UIKit-backed dynamic colour resolves against the window's
                // TRAIT COLLECTION, which is inherited from the host's macOS
                // appearance. The harness already declares light intent with
                // `.environment(\.colorScheme, .light)`, but that sets a
                // SwiftUI environment value and does not drive the UIKit
                // traits, so on a Mac in Dark Mode `Color.gray` resolved dark
                // here and light in the interpreter — a real 3410 AE on the
                // media screen that belonged to a system preference. Stated in
                // the traits, the declaration becomes effective and the twin
                // stops being a function of who is running it.
                window.overrideUserInterfaceStyle = .light
                rootView.setNeedsLayout()
                rootView.layoutIfNeeded()
                lastObserved = rootView.bounds.size
                if abs(rootView.bounds.width - target.width) < 0.5,
                   abs(rootView.bounds.height - target.height) < 0.5 {
                    return
                }
            }
            guard ContinuousClock.now < deadline else {
                throw NSError(
                    domain: "IceCubesNativeTwin", code: 15,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Catalyst window never reached the scored size"
                        + " \(target); last observed"
                        + " \(lastObserved.map(String.init(describing:)) ?? "no window")"])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func capturePNG(named name: String) async throws {
        try await pinCaptureGeometry()
        var previous: Data?
        var png: Data?
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            let current = try rasterizeHierarchyPNG()
            if previous == current {
                png = current
                break
            }
            previous = current
        }
        guard let png else {
            throw NSError(
                domain: "IceCubesNativeTwin", code: 13,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(name) hierarchy never produced two identical rasterizations"])
        }

        try FileManager.default.createDirectory(
            atPath: TwinConfiguration.outputDirectory, withIntermediateDirectories: true)
        // Written from the settled hierarchy the accepted PNG came from, so
        // the geometry and the pixels describe the same moment.
        CaptureGeometryDump.write(
            captureView: try currentCaptureView(),
            screen: name,
            directory: TwinConfiguration.outputDirectory)
        let imageURL = URL(fileURLWithPath: TwinConfiguration.outputDirectory)
            .appendingPathComponent("\(name).png")
        try png.write(to: imageURL, options: .atomic)

        print("\(name)\t\(imageURL.path)\t\(Int(TwinConfiguration.size.width))x\(Int(TwinConfiguration.size.height))")
    }

    /// Native progress indicators and transition layers use wall-clock Core
    /// Animation even when model time is frozen. Snapshot the model-layer
    /// presentation so repeated captures of the same semantic state are exact.
    private func removeAnimations(from layer: CALayer) {
        layer.removeAllAnimations()
        layer.sublayers?.forEach(removeAnimations(from:))
    }

    private func captureMetadata(
        statuses: [Status],
        detailStatus: Status,
        focusedMediaURL: URL,
        screenFixtures: ScreenFixtureNames
    ) throws {
        let metadata = TwinMetadata(
            fixture: "api_v1_timelines_public.json",
            statusCount: statuses.count,
            displayNames: statuses.map { status in
                let visible = status.reblog?.account ?? status.account
                return visible.safeDisplayName
            },
            rawContent: statuses.map { status in
                let visible = status.reblog?.content ?? status.content
                return visible.asRawText
            },
            detailMarkdown: detailStatus.content.asMarkdown,
            mediaCount: statuses.reduce(into: 0) { count, status in
                count += (status.reblog?.mediaAttachments ?? status.mediaAttachments).count
            },
            focusedMediaURL: focusedMediaURL.absoluteString,
            screenFixtures: screenFixtures,
            requests: ReplayURLProtocol.requests,
            clockEpoch: Date().timeIntervalSince1970,
            relativeClockDrift: Date().timeIntervalSinceNow,
            width: Int(TwinConfiguration.size.width),
            height: Int(TwinConfiguration.size.height))
        let metadataURL = URL(fileURLWithPath: TwinConfiguration.outputDirectory)
            .appendingPathComponent("timeline.json")
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)

        print("metadata\t\(metadataURL.path)\tstatuses=\(metadata.statusCount) media=\(metadata.mediaCount)")
    }

    private func fixedSizeDescendant(in view: UIView) -> UIView? {
        let delta = CGSize(
            width: abs(view.bounds.width - TwinConfiguration.size.width),
            height: abs(view.bounds.height - TwinConfiguration.size.height))
        if delta.width < 0.5, delta.height < 0.5 {
            return view
        }
        for child in view.subviews {
            if let match = fixedSizeDescendant(in: child) { return match }
        }
        return nil
    }
}

@main
private struct IceCubesNativeTwinApp: App {
    @UIApplicationDelegateAdaptor(TwinAppDelegate.self) private var appDelegate

    init() {
        ReplayURLProtocol.configure(fixtures: TwinConfiguration.fixtureDirectory)
        guard URLProtocol.registerClass(ReplayURLProtocol.self) else {
            fatalError("could not register frozen replay URLProtocol")
        }
        let imageSession = URLSessionConfiguration.ephemeral
        imageSession.protocolClasses = [ReplayURLProtocol.self]
        imageSession.urlCache = nil
        ImagePipeline.shared = ImagePipeline {
            $0.dataLoader = DataLoader(configuration: imageSession)
            $0.imageCache = nil
            $0.dataCache = nil
            $0.isResumableDataEnabled = false
        }
    }

    var body: some Scene {
        WindowGroup {
            TwinDriverView()
        }
    }
}
