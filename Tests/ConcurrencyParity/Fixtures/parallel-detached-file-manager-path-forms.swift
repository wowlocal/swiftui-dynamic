import Foundation

func parallelDetachedFileManagerPathFormsProbe() async -> String {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "detached-file-manager-path-forms-\(UUID().uuidString)",
        isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let copied = root.appendingPathComponent("copied", isDirectory: true)
    let moved = root.appendingPathComponent("moved", isDirectory: true)

    defer { try? manager.removeItem(at: root) }

    do {
        try manager.createDirectory(
            at: source.appendingPathComponent("inner", isDirectory: true),
            withIntermediateDirectories: true)

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(
                atPath: source.path, toPath: copied.path)
        }.value
        let copiedExists = manager.fileExists(atPath: copied.path)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.moveItem(
                atPath: copied.path, toPath: moved.path)
        }.value
        let movedExists = manager.fileExists(atPath: moved.path)
        let names = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.contentsOfDirectory(atPath: moved.path)
        }.value

        let joined = names.sorted().joined(separator: ",")
        return "copied:\(copiedExists)|moved:\(movedExists)|names:\(joined)"
    } catch {
        return "setup-error"
    }
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedFileManagerPathFormsProbe()
}
