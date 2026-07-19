import Foundation

@MainActor
final class PhysicalNonisolatedURLSourceCallProbe {
    nonisolated private func loadPlayerItem(url: URL) {
        precondition(
            url.lastPathComponent == "first.mp4"
                || url.lastPathComponent == "second.mp4")
    }

    func run() async -> String {
        let firstURL = URL(fileURLWithPath: "/tmp/first.mp4")
        let secondURL = URL(fileURLWithPath: "/tmp/second.mp4")

        let first = Task.detached(priority: .userInitiated) {
            self.loadPlayerItem(url: firstURL)
        }
        let second = Task.detached(priority: .userInitiated) {
            self.loadPlayerItem(url: secondURL)
        }

        await first.value
        await second.value
        return "loaded:\(firstURL.lastPathComponent),\(secondURL.lastPathComponent)"
    }
}

@MainActor
func parallelDetachedNonisolatedURLSourceCallProbe() async -> String {
    await PhysicalNonisolatedURLSourceCallProbe().run()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelDetachedNonisolatedURLSourceCallProbe()
}
