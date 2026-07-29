import Foundation
import UIKit

/// A frozen-network transport for the native twin. Every HTTP(S) request is
/// intercepted: known Mastodon endpoints receive their recorded bytes, image
/// requests receive one deterministic solid PNG, and everything else fails
/// closed. This is harness infrastructure, not an IceCubes source change.
final class ReplayURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtureDirectories: [String] = []
    nonisolated(unsafe) private static var recordedRequests: [String] = []

    static func configure(fixtures: String) {
        lock.withLock {
            fixtureDirectories = [fixtures]
            recordedRequests = []
        }
    }

    static func prependFixtures(_ fixtures: String) {
        lock.withLock {
            fixtureDirectories.removeAll { $0 == fixtures }
            fixtureDirectories.insert(fixtures, at: 0)
        }
    }

    static var requests: [String] {
        lock.withLock { recordedRequests }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            fail("request has no URL")
            return
        }
        Self.lock.withLock { Self.recordedRequests.append(url.path) }

        let response: (Data, String, Int)
        if let recorded = fixture(for: url) {
            response = recorded
        } else if isImageRequest(url) {
            response = (Self.placeholderPNG, "image/png", 200)
        } else {
            response = (Data(#"{"error":"unrecorded replay request"}"#.utf8),
                        "application/json", 404)
        }

        guard let http = HTTPURLResponse(
            url: url, statusCode: response.2, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": response.1,
                "Content-Length": String(response.0.count),
            ])
        else {
            fail("could not create replay response")
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.0)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func fixture(for url: URL) -> (Data, String, Int)? {
        let name = url.path
            .split(separator: "/")
            .joined(separator: "_")
            + ".json"
        let directories = Self.lock.withLock { Self.fixtureDirectories }
        for directory in directories {
            let fixtureURL = URL(fileURLWithPath: directory)
                .appendingPathComponent(name)
            if let data = try? Data(contentsOf: fixtureURL) {
                return (data, "application/json", 200)
            }
        }
        return nil
    }

    private func isImageRequest(_ url: URL) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "avif"].contains(extensionName) {
            return true
        }
        let accept = request.value(forHTTPHeaderField: "Accept") ?? ""
        return accept.contains("image/")
    }

    private func fail(_ message: String) {
        client?.urlProtocol(
            self, didFailWithError: NSError(
                domain: "IceCubesNativeTwin.Replay", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private static let placeholderPNG: Data = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 8, height: 8), format: format)
        let image = renderer.image { context in
            UIColor(red: 0.30, green: 0.50, blue: 0.72, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return image.pngData() ?? Data()
    }()
}
