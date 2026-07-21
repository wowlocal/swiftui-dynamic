// Compiled-native expectation and pixel harness for LOOP-ICECUBES.md.
import Account
import AppAccount
import DesignSystem
import Env
import Foundation
import Models
import NetworkClient
import Nuke
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
    let requests: [String]
    let clockEpoch: Double
    let width: Int
    let height: Int
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

@MainActor
private struct PublicTimelineScreen: View {
    let fetcher: FixtureFetcher
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
    @State private var statuses: [Status] = []
    @State private var focusedMedia: [MediaAttachment]?
    @State private var started = false
    private let client = MastodonClient(server: "mstdn.social")
    private let routerPath = RouterPath()

    var body: some View {
        Group {
            if let focusedMedia {
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
                .appendingPathComponent("api_v1_statuses_116954929935729788.json"))
            let boostStatus = try detailDecoder.decode(Status.self, from: boostData)
            guard let imageAttachment = boostStatus.reblog?.mediaAttachments.first,
                  imageAttachment.supportedType == .image,
                  let imageURL = imageAttachment.url else {
                throw NSError(
                    domain: "IceCubesNativeTwin", code: 5,
                    userInfo: [NSLocalizedDescriptionKey:
                        "recorded boost fixture has no supported image attachment"])
            }
            let replayStatuses = decoded + [boostStatus]
            statuses = replayStatuses
            // Let SwiftUI install the List hierarchy and let deterministic
            // replay image requests settle before rasterizing the live view.
            try await Task.sleep(for: .seconds(1))
            try capturePNG(named: "timeline")

            focusedMedia = [imageAttachment]
            try await Task.sleep(for: .seconds(1))
            try capturePNG(named: "media")
            try captureMetadata(
                statuses: replayStatuses, detailStatus: detailStatus,
                focusedMediaURL: imageURL)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("IceCubesNativeTwin: \(error)\n".utf8))
            exit(2)
        }
    }

    private func capturePNG(named name: String) throws {
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
        let captureView = fixedSizeDescendant(in: rootView) ?? rootView

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: TwinConfiguration.size, format: format)
        let image = renderer.image { _ in
            captureView.drawHierarchy(
                in: CGRect(origin: .zero, size: TwinConfiguration.size),
                afterScreenUpdates: true)
        }
        guard let png = image.pngData() else {
            throw NSError(
                domain: "IceCubesNativeTwin", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "live hierarchy produced no PNG"])
        }

        try FileManager.default.createDirectory(
            atPath: TwinConfiguration.outputDirectory, withIntermediateDirectories: true)
        let imageURL = URL(fileURLWithPath: TwinConfiguration.outputDirectory)
            .appendingPathComponent("\(name).png")
        try png.write(to: imageURL, options: .atomic)

        print("\(name)\t\(imageURL.path)\t\(Int(TwinConfiguration.size.width))x\(Int(TwinConfiguration.size.height))")
    }

    private func captureMetadata(
        statuses: [Status], detailStatus: Status, focusedMediaURL: URL
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
            requests: ReplayURLProtocol.requests,
            clockEpoch: Date().timeIntervalSince1970,
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
