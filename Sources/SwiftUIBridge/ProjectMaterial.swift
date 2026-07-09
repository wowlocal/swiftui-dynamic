import Foundation

/// Shared source discovery + merge for whole projects (ProjectCheck and the
/// demo's `--project` mode). Mirrors what the build system itself treats as
/// compile sources: test targets, preview assets, build products, and DocC
/// catalogs are not app source. `.docc` bundles in particular hold TUTORIAL
/// SNIPPETS (intentionally elided, non-compiling code — swift-composable-
/// architecture ships 475 of them) that SwiftPM registers as documentation
/// resources, never as sources.
public enum ProjectMaterial {
    static let excludedPathComponents = [
        "Tests", "UITests", "Preview Content", "__MACOSX", ".build",
        "DerivedData", ".docc",
    ]

    public static func swiftFiles(under directory: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
        var files: [String] = []
        for case let path as String in enumerator {
            guard path.hasSuffix(".swift") else { continue }
            guard !excludedPathComponents.contains(where: { path.contains($0) }) else { continue }
            files.append(directory + "/" + path)
        }
        return files.sorted()
    }

    /// Imports are stripped (the merge holds all the app's own Swift; the
    /// interpreter absorbs what a compiled import would provide).
    public static func mergedSource(files: [String]) -> String {
        var merged = ""
        for path in files {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let stripped = content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Shebangs (build-phase scripts run as `swift file.swift`)
                    // are meaningless in module compilation — strip like
                    // imports so the script's Swift still merges.
                    return !(trimmed.hasPrefix("import ") || trimmed.hasPrefix("@testable import ")
                        || trimmed.hasPrefix("#!"))
                }
                .joined(separator: "\n")
            merged += "\n// FILE: \(URL(fileURLWithPath: path).lastPathComponent)\n" + stripped + "\n"
        }
        return merged
    }

    public static func mergedSource(at root: String) -> String {
        mergedSource(files: swiftFiles(under: root))
    }

    /// TestCheck's merge: app sources PLUS unit-test sources (UITests stay
    /// out — XCUITest drives a real process we don't have).
    public static func testMergedSource(at root: String) -> String {
        let excluded = ["UITests", "Preview Content", "__MACOSX", ".build", "DerivedData", ".docc"]
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return "" }
        var files: [String] = []
        for case let path as String in enumerator {
            guard path.hasSuffix(".swift") else { continue }
            guard !excluded.contains(where: { path.contains($0) }) else { continue }
            files.append(root + "/" + path)
        }
        return mergedSource(files: files.sorted())
    }
}
