import Foundation

func parallelDetachedFileManagerCreateDirectoryProbe() async -> String {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "detached-file-manager-create-directory-\(UUID().uuidString)",
        isDirectory: true)
    let urlDirectory = root.appendingPathComponent(
        "url/child", isDirectory: true)
    let pathDirectory = root.appendingPathComponent(
        "path/child", isDirectory: true)

    defer { try? manager.removeItem(at: root) }

    do {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: urlDirectory, withIntermediateDirectories: true)
        }.value
        let urlCreated = manager.fileExists(atPath: urlDirectory.path)

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                atPath: pathDirectory.path,
                withIntermediateDirectories: true)
        }.value
        let pathCreated = manager.fileExists(atPath: pathDirectory.path)

        return "url:\(urlCreated)|path:\(pathCreated)"
    } catch {
        return "setup-error"
    }
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedFileManagerCreateDirectoryProbe()
}
