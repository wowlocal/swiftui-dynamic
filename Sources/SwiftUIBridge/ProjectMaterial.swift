import CryptoKit
import Foundation
import SwiftInterpreter

/// One explicitly selected Swift build target and the original source files
/// that belong to it. Compiler preflight consumes `sources` unchanged; the
/// interpreter derives its merged, import-stripped projection separately.
public struct ProjectBuildManifest: Sendable, Equatable {
    /// Canonical project root used by runtime resource lookup. Compiler source
    /// membership remains explicit and cannot be inferred by walking it.
    public let projectRoot: String
    public let buildTarget: CompilerPreflightBuildTarget
    public let sources: [CompilerPreflightSource]
    /// Stable evidence/cache identity for the exact target and ordered source
    /// inputs. Length-prefixing prevents component-boundary collisions.
    public let fingerprint: String

    public init(
        projectRoot: String,
        buildTarget: CompilerPreflightBuildTarget,
        sources: [CompilerPreflightSource]
    ) throws {
        guard ProjectMaterial.isAbsoluteNormalizedProjectRoot(projectRoot)
        else {
            throw ProjectBuildManifestError.invalidProjectRoot(projectRoot)
        }
        guard !sources.isEmpty else {
            throw ProjectBuildManifestError.emptySources
        }

        var logicalPaths: Set<String> = []
        for source in sources {
            guard ProjectMaterial.isSafeProjectRelativeSwiftPath(
                source.fileName
            ) else {
                throw ProjectBuildManifestError.invalidLogicalPath(
                    source.fileName)
            }
            let identity = source.fileName
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard logicalPaths.insert(identity).inserted else {
                throw ProjectBuildManifestError.duplicateLogicalPath(
                    source.fileName)
            }
        }

        self.projectRoot = projectRoot
        self.buildTarget = buildTarget
        self.sources = sources
        var components = [
            "project-build-manifest-v2",
            projectRoot,
            buildTarget.fingerprint,
            String(sources.count),
        ]
        for source in sources {
            components.append(source.fileName)
            components.append(source.source)
        }
        var bytes = Data()
        for component in components {
            let data = Data(component.utf8)
            bytes.append(Data("\(data.count):".utf8))
            bytes.append(data)
        }
        fingerprint = SHA256.hash(data: bytes).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

public enum ProjectBuildManifestError: Error, Equatable,
    CustomStringConvertible
{
    case emptySources
    case invalidProjectRoot(String)
    case invalidLogicalPath(String)
    case duplicateLogicalPath(String)
    case sourceOutsideProjectRoot(String)
    case unreadableSource(String)

    public var description: String {
        switch self {
        case .emptySources:
            "project build manifest requires at least one Swift source"
        case let .invalidProjectRoot(path):
            "project root must be an absolute canonical path: '\(path)'"
        case let .invalidLogicalPath(path):
            "project source has an unsafe logical path: '\(path)'"
        case let .duplicateLogicalPath(path):
            "project source logical path is duplicated: '\(path)'"
        case let .sourceOutsideProjectRoot(path):
            "project source is outside the project root: '\(path)'"
        case let .unreadableSource(path):
            "project source could not be read: '\(path)'"
        }
    }
}

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

    /// Build a manifest from source membership supplied by the caller. This
    /// deliberately does not walk the project or infer sibling targets: a
    /// build-system adapter must select the target's files before calling it.
    public static func buildManifest(
        at root: String,
        files: [String],
        buildTarget: CompilerPreflightBuildTarget
    ) throws -> ProjectBuildManifest {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = rootURL.path.hasSuffix("/")
            ? rootURL.path : rootURL.path + "/"
        let manager = FileManager.default
        let sources = try files.map { path -> CompilerPreflightSource in
            let directURL = URL(fileURLWithPath: path)
                .standardizedFileURL.resolvingSymlinksInPath()
            let rootRelativeURL = rootURL.appendingPathComponent(path)
                .standardizedFileURL.resolvingSymlinksInPath()
            let sourceURL: URL
            if path.hasPrefix("/") {
                sourceURL = directURL
            } else if directURL.path.hasPrefix(rootPrefix),
                      manager.fileExists(atPath: directURL.path)
            {
                sourceURL = directURL
            } else {
                sourceURL = rootRelativeURL
            }
            guard sourceURL.path.hasPrefix(rootPrefix) else {
                throw ProjectBuildManifestError.sourceOutsideProjectRoot(path)
            }
            let logicalPath = String(sourceURL.path.dropFirst(rootPrefix.count))
            guard let source = try? String(
                contentsOf: sourceURL, encoding: .utf8
            ) else {
                throw ProjectBuildManifestError.unreadableSource(path)
            }
            return CompilerPreflightSource(
                fileName: logicalPath,
                source: source
            )
        }
        return try ProjectBuildManifest(
            projectRoot: rootURL.path,
            buildTarget: buildTarget,
            sources: sources
        )
    }

    /// Deterministic runtime projection of one explicit build target. Imports
    /// and shebangs are removed only here; the manifest retains the original
    /// compiler inputs byte-for-byte.
    public static func mergedSource(for manifest: ProjectBuildManifest) -> String {
        var merged = ""
        var imports: Set<String> = []
        for source in manifest.sources {
            let stripped = interpreterProjection(
                of: source.source,
                recordingImportsIn: &imports
            )
            merged += "\n// FILE: \(source.fileName)\n" + stripped + "\n"
        }
        merged += LibraryShims.shims(importedIn: imports, mergedSource: merged)
        return merged
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
                Interpreter.sourceHasHardErrors(content)
            {
                continue
            }
            let stripped = interpreterProjection(
                of: content,
                recordingImportsIn: &imports
            )
            merged += "\n// FILE: \(URL(fileURLWithPath: path).lastPathComponent)\n" + stripped + "\n"
        }
        // Source-distributed state libraries the app imports but doesn't
        // vendor get their distilled core appended (LibraryShims).
        merged += LibraryShims.shims(importedIn: imports, mergedSource: merged)
        return merged
    }

    fileprivate static func isSafeProjectRelativeSwiftPath(
        _ path: String
    ) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\r"),
              path.hasSuffix(".swift")
        else {
            return false
        }
        let components = path.split(
            separator: "/", omittingEmptySubsequences: false
        )
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    fileprivate static func isAbsoluteNormalizedProjectRoot(
        _ path: String
    ) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/"), !path.utf8.contains(0)
        else { return false }
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path == path
    }

    private static func interpreterProjection(
        of source: String,
        recordingImportsIn imports: inout Set<String>
    ) -> String {
        source.split(
            separator: "\n", omittingEmptySubsequences: false
        ).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let importPrefixes = [
                "import ", "@testable import ", "@_exported import ",
                "@_implementationOnly import ", "public import ",
                "package import ", "internal import ", "private import ",
                "fileprivate import ", "@preconcurrency import ",
            ]
            if let prefix = importPrefixes.first(where: {
                trimmed.hasPrefix($0)
            }) {
                let importParts = trimmed.dropFirst(prefix.count)
                    .split(whereSeparator: { $0.isWhitespace })
                let scopedImportKinds: Set<Substring> = [
                    "typealias", "struct", "class", "enum", "protocol",
                    "let", "var", "func",
                ]
                let imported = importParts.first.flatMap { first in
                    scopedImportKinds.contains(first)
                        ? importParts.dropFirst().first : first
                }.map(String.init) ?? ""
                let module = imported.split(separator: ".").first
                    .map(String.init) ?? imported
                if !module.isEmpty { imports.insert(module) }
                return false
            }
            // Build-phase scripts can contain a shebang. It is not Swift
            // module syntax and therefore belongs only to the original input.
            return !trimmed.hasPrefix("#!")
        }.joined(separator: "\n")
    }

    public static func mergedSource(at root: String) -> String {
        mergedSource(at: root, files: swiftFiles(under: root))
    }

    /// Recover the logical files embedded by `mergedSource`. The interpreter
    /// still consumes one merged syntax tree, while native compiler preflight
    /// receives the original file boundaries needed for `private` scope and
    /// file-specific diagnostics. Unmarked source returns nil so ordinary
    /// snippets keep their single-file behavior.
    public static func compilerPreflightSources(
        from mergedSource: String
    ) -> [CompilerPreflightSource]? {
        let marker = "// FILE: "
        var sections: [(fileName: String, lines: [Substring])] = []
        var currentFileName: String?
        var currentLines: [Substring] = []

        for line in mergedSource.split(
            separator: "\n", omittingEmptySubsequences: false
        ) {
            guard line.hasPrefix(marker) else {
                currentLines.append(line)
                continue
            }

            if let currentFileName {
                sections.append((currentFileName, currentLines))
            } else if currentLines.contains(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }) {
                return nil
            }
            currentFileName = String(line.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespaces)
            currentLines = []
        }

        guard let currentFileName else { return nil }
        sections.append((currentFileName, currentLines))

        let baseNames = sections.map {
            let candidate = URL(fileURLWithPath: $0.fileName)
                .lastPathComponent
            return candidate.isEmpty ? "input.swift" : candidate
        }
        let counts = Dictionary(grouping: baseNames, by: { $0 })
            .mapValues(\.count)
        var occurrences: [String: Int] = [:]

        return zip(sections, baseNames).map { section, baseName in
            occurrences[baseName, default: 0] += 1
            let logicalFileName: String
            if counts[baseName] == 1 {
                logicalFileName = baseName
            } else {
                logicalFileName = String(
                    format: "%04d-%@",
                    occurrences[baseName, default: 0],
                    baseName
                )
            }
            return CompilerPreflightSource(
                fileName: logicalFileName,
                source: section.lines.joined(separator: "\n")
            )
        }
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
