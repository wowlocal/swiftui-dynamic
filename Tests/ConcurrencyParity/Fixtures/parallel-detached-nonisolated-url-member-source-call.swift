import Foundation

@MainActor
final class PhysicalNonisolatedURLMemberSourceCallProbe {
    let firstURL = URL(fileURLWithPath: "/tmp/first-member.mp4")
    let secondURL = URL(fileURLWithPath: "/tmp/second-member.mp4")

    nonisolated private func loadPlayerItem(url: URL) {
        precondition(
            url.lastPathComponent == "first-member.mp4"
                || url.lastPathComponent == "second-member.mp4")
    }

    func run() async -> String {
        let first = Task.detached(priority: .userInitiated) {
            self.loadPlayerItem(url: self.firstURL)
        }
        let second = Task.detached(priority: .userInitiated) {
            self.loadPlayerItem(url: self.secondURL)
        }

        await first.value
        await second.value
        return "loaded:\(firstURL.lastPathComponent),\(secondURL.lastPathComponent)"
    }
}

@MainActor
func parallelDetachedNonisolatedURLMemberSourceCallProbe() async -> String {
    await PhysicalNonisolatedURLMemberSourceCallProbe().run()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelDetachedNonisolatedURLMemberSourceCallProbe()
}
