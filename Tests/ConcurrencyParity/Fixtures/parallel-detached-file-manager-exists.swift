import Foundation

func parallelDetachedFileManagerExistsProbe() async -> String {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "detached-file-manager-exists-\(UUID().uuidString)",
        isDirectory: true)
    let present = root.appendingPathComponent(
        "present", isDirectory: true)
    let missing = root.appendingPathComponent(
        "missing", isDirectory: true)

    defer { try? manager.removeItem(at: root) }

    do {
        try manager.createDirectory(
            at: present, withIntermediateDirectories: true)

        let presentResult = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: present.path)
        }.value
        let missingResult = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: missing.path)
        }.value

        return "present:\(presentResult)|missing:\(missingResult)"
    } catch {
        return "setup-error"
    }
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedFileManagerExistsProbe()
}
