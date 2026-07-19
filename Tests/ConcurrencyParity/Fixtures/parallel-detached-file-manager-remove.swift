import Foundation

func parallelDetachedFileManagerRemoveProbe() async -> String {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "detached-file-manager-remove-\(UUID().uuidString)",
        isDirectory: true)
    let item = root.appendingPathComponent("item", isDirectory: true)
    let pathItem = root.appendingPathComponent(
        "path-item", isDirectory: true)

    defer { try? manager.removeItem(at: root) }

    do {
        try manager.createDirectory(
            at: item, withIntermediateDirectories: true)
        try manager.createDirectory(
            at: pathItem, withIntermediateDirectories: true)

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.removeItem(at: item)
        }.value
        let removed = !manager.fileExists(atPath: item.path)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.removeItem(atPath: pathItem.path)
        }.value
        let pathRemoved = !manager.fileExists(atPath: pathItem.path)

        let missingResult: String
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.removeItem(at: item)
            }.value
            missingResult = "accepted"
        } catch {
            missingResult = "error"
        }

        return "url:\(removed)|path:\(pathRemoved)|missing:\(missingResult)"
    } catch {
        return "setup-error"
    }
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedFileManagerRemoveProbe()
}
