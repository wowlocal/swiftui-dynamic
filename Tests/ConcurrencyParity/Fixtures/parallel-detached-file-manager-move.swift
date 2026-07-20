import Foundation

nonisolated func parallelFileManagerPhysicalLane() -> String {
    Thread.isMainThread ? "main" : "worker"
}

func parallelDetachedFileManagerMoveProbe() async -> String {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "utm-detached-file-manager-\(ProcessInfo.processInfo.processIdentifier)",
        isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let destination = root.appendingPathComponent(
        "destination", isDirectory: true)
    let copy = root.appendingPathComponent("copy", isDirectory: true)

    try? manager.removeItem(at: root)
    defer { try? manager.removeItem(at: root) }

    do {
        try manager.createDirectory(
            at: source, withIntermediateDirectories: true)

        let lane = try await Task.detached {
            let lane = parallelFileManagerPhysicalLane()
            try FileManager.default.moveItem(at: source, to: destination)
            return lane
        }.value

        let sourceExists = manager.fileExists(atPath: source.path)
        let destinationExists = manager.fileExists(atPath: destination.path)
        try await Task.detached {
            try FileManager.default.copyItem(at: destination, to: copy)
        }.value
        let copyExists = manager.fileExists(atPath: copy.path)
        let missingResult: String
        do {
            try await Task.detached {
                try FileManager.default.moveItem(
                    at: source, to: destination)
            }.value
            missingResult = "accepted"
        } catch {
            missingResult = "error"
        }

        return "\(lane)|source:\(sourceExists)"
            + "|destination:\(destinationExists)|copy:\(copyExists)"
            + "|missing:\(missingResult)"
    } catch {
        return "setup-error"
    }
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedFileManagerMoveProbe()
}
