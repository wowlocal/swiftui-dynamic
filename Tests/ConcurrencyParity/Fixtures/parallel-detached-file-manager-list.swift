import Foundation

func parallelDetachedFileManagerListProbe() async -> String {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "detached-file-manager-list-\(UUID().uuidString)",
        isDirectory: true)

    defer { try? manager.removeItem(at: root) }

    do {
        for name in ["alpha", "beta", "gamma"] {
            try manager.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let listed = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        }.value
        let names = listed.map { $0.lastPathComponent }.sorted()

        return names.joined(separator: "|")
    } catch {
        return "setup-error"
    }
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedFileManagerListProbe()
}
