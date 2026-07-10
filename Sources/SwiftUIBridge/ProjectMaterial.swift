import Foundation
import SwiftInterpreter

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
        // Test-SUPPORT infrastructure is test-target source too:
        // apple-browsers ships a `tests-server` web-server tool (its
        // top-level RunLoop.main.run() script is not app code) and
        // `TestUtilities` packages whose RunLoop wrappers self-recurse.
        "tests-server", "TestUtilities",
        // Repo tooling in scripts/ dirs (apple-browsers' db-decrypt CLI
        // runs a REPL loop at top level) — never compiled into apps.
        "scripts/", "Scripts/",
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
    public static func mergedSource(at root: String, files: [String]) -> String {
        BundleBox.projectResourceRoot = root
        return mergedSource(files: files)
    }

    public static func mergedSource(files: [String]) -> String {
        var merged = ""
        var imports: Set<String> = []
        for path in files {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            // Hard parse errors prove a file isn't a member of any
            // compiling target: Sourcery inline-scratch fragments,
            // abandoned files with editor placeholders and half-written
            // expressions (iTorrent ships one). The standalone parse is
            // ~1ms/file — gated on the two signatures so 30k-file corpora
            // don't pay it everywhere (a universal check measured 14.5min
            // for the full corpus vs ~2).
            if content.contains("sourcery:inline:") || content.contains("<#")
                || path.hasSuffix("Dangerfile.swift"),
               Interpreter.sourceHasHardErrors(content) {
                continue
            }
            let stripped = content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("import ") {
                        let module = trimmed.dropFirst("import ".count)
                            .split(separator: " ").last.map(String.init) ?? ""
                        imports.insert(module.split(separator: ".").first.map(String.init) ?? module)
                    }
                    // Shebangs (build-phase scripts run as `swift file.swift`)
                    // are meaningless in module compilation — strip like
                    // imports so the script's Swift still merges.
                    return !(trimmed.hasPrefix("import ") || trimmed.hasPrefix("@testable import ")
                        || trimmed.hasPrefix("#!"))
                }
                .joined(separator: "\n")
            merged += "\n// FILE: \(URL(fileURLWithPath: path).lastPathComponent)\n" + stripped + "\n"
        }
        // Source-distributed state libraries the app imports but doesn't
        // vendor get their distilled core appended (LibraryShims).
        merged += LibraryShims.shims(importedIn: imports, mergedSource: merged)
        return merged
    }

    public static func mergedSource(at root: String) -> String {
        mergedSource(at: root, files: swiftFiles(under: root))
    }

    /// Per-TARGET merge: a compiler never merges sibling app targets
    /// (MovieSwiftTV with the iOS app — duplicate @main/HomeView/etc.).
    /// Callers exclude the sibling-target directories the built product
    /// wouldn't contain.
    public static func mergedSource(at root: String, excludingTargets targets: [String]) -> String {
        let files = swiftFiles(under: root).filter { path in
            !targets.contains { path.contains("/\($0)/") }
        }
        return mergedSource(files: files)
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
