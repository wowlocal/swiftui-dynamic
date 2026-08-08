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

/// Fail-closed diagnostics for projecting the source membership SwiftPM
/// already resolved. The build description is compiler evidence: callers do
/// not infer products, targets, checkout identities, or source layouts.
public enum SwiftPMBuildDescriptionMaterialError: Error, Equatable,
    CustomStringConvertible
{
    case unreadableDescription(String)
    case invalidDescription(String)
    case noSwiftCommands(String)
    case missingCompilerInput(String)
    case unreadableCompilerInput(String)
    case ambiguousCompilerInputModule(String)

    public var description: String {
        switch self {
        case let .unreadableDescription(path):
            "SwiftPM build description could not be read: '\(path)'"
        case let .invalidDescription(path):
            "SwiftPM build description is invalid: '\(path)'"
        case let .noSwiftCommands(path):
            "SwiftPM build description has no Swift commands: '\(path)'"
        case let .missingCompilerInput(path):
            "SwiftPM build description names a missing source: '\(path)'"
        case let .unreadableCompilerInput(path):
            "SwiftPM compiler input could not be read: '\(path)'"
        case let .ambiguousCompilerInputModule(path):
            "SwiftPM build description compiles one source into multiple "
                + "modules: '\(path)'"
        }
    }
}

private struct SwiftPMBuildDescriptionMaterial: Decodable {
    struct Command: Decodable {
        let moduleName: String
        let sources: [String]
        let otherArguments: [String]?
    }

    let swiftCommands: [String: Command]
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

    /// A compiler input's identity is its CANONICAL path, never the spelling
    /// the caller happened to reach it by. Every path this type reads out of
    /// a SwiftPM build description is already resolved this way, so a path
    /// walked off the filesystem has to be resolved too or the two halves of
    /// one merge stop comparing — and stop SORTING — against each other.
    ///
    /// macOS makes this unavoidable rather than theoretical: `/tmp` and
    /// `/var` are symlinks into `/private`, `getcwd()` hands back the
    /// physical spelling, and Foundation's `resolvingSymlinksInPath()` maps
    /// both to the `/private`-STRIPPED form. A checkout under `/tmp` is
    /// therefore routinely named two ways inside one process.
    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func swiftFiles(under directory: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
        // Resolved ONCE for the whole walk, not per file: the enumerator
        // yields directory-relative paths, so the spelling can only enter
        // through this prefix.
        let root = canonicalPath(directory)
        var files: [String] = []
        for case let path as String in enumerator {
            guard path.hasSuffix(".swift") else { continue }
            guard !excludedPathComponents.contains(where: { path.contains($0) }) else { continue }
            files.append(root + "/" + path)
        }
        return files.sorted()
    }

    /// Read the exact Swift compiler inputs from SwiftPM's build description.
    /// This is the reusable external-dependency adapter for merged projects:
    /// SwiftPM remains responsible for package resolution and target
    /// membership, while the interpreter consumes the same source files.
    public static func swiftFiles(
        inSwiftPMBuildDescriptionAt path: String
    ) throws -> [String] {
        let files = try swiftPMBuildModules(at: path).flatMap(\.sources)
        return Array(Set(files)).sorted()
    }

    /// Authoritative source-file ownership from SwiftPM's resolved build
    /// plan. Runtime module qualification uses this provenance to distinguish
    /// `Dependency.Model` from an unrelated same-named app declaration.
    public static func sourceModuleNames(
        inSwiftPMBuildDescriptionAt path: String
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for module in try swiftPMBuildModules(at: path) {
            for source in module.sources {
                if let existing = result[source], existing != module.name {
                    throw SwiftPMBuildDescriptionMaterialError
                        .ambiguousCompilerInputModule(source)
                }
                result[source] = module.name
            }
        }
        return result
    }

    /// Load the transitive source-module slice needed by `rootFiles`. An
    /// imported module joins when a qualified free-global reference or an
    /// unqualified nominal reference matches one of its top-level
    /// declarations. Selecting the compiler module brings its complete source
    /// set, including extension-only sibling files, without flattening every
    /// resolved checkout into one artificial module.
    public static func swiftFiles(
        inSwiftPMBuildDescriptionAt path: String,
        requiredBy rootFiles: [String]
    ) throws -> [String] {
        let modules = try swiftPMBuildModules(at: path)
        let clangModuleNames = clangModuleNames(in: modules)
        var sourcesByModule: [String: Set<String>] = [:]
        for module in modules {
            sourcesByModule[module.name, default: []]
                .formUnion(module.sources)
        }

        let roots = Set(rootFiles.map {
            URL(fileURLWithPath: $0).standardizedFileURL
                .resolvingSymlinksInPath().path
        })
        var pending = Array(roots).sorted()
        var scanned: Set<String> = []
        var selectedModules: Set<String> = []
        var selectedFiles: Set<String> = []
        var declarationsByModule: [String: Set<String>] = [:]
        var directlyClangBackedByModule: [String: Bool] = [:]
        var sourceByPath: [String: String] = [:]
        var analysisByPath: [String: SourceModuleAnalysis] = [:]

        func source(at sourcePath: String) throws -> String {
            if let cached = sourceByPath[sourcePath] { return cached }
            guard let source = try? String(
                contentsOfFile: sourcePath, encoding: .utf8
            ) else {
                throw SwiftPMBuildDescriptionMaterialError
                    .unreadableCompilerInput(sourcePath)
            }
            sourceByPath[sourcePath] = source
            return source
        }

        func analysis(
            at sourcePath: String
        ) throws -> SourceModuleAnalysis {
            if let cached = analysisByPath[sourcePath] { return cached }
            let discovered = Interpreter.sourceModuleAnalysis(
                in: try source(at: sourcePath))
            analysisByPath[sourcePath] = discovered
            return discovered
        }

        func declarations(
            in moduleName: String,
            sources moduleSources: Set<String>
        ) throws -> Set<String> {
            if let cached = declarationsByModule[moduleName] {
                return cached
            }
            var discovered: Set<String> = []
            for moduleSource in moduleSources.sorted() {
                discovered.formUnion(try analysis(
                    at: moduleSource).topLevelDeclarationNames)
            }
            declarationsByModule[moduleName] = discovered
            return discovered
        }

        func isDirectlyClangBacked(
            _ moduleName: String,
            sources moduleSources: Set<String>
        ) throws -> Bool {
            if let cached = directlyClangBackedByModule[moduleName] {
                return cached
            }
            let backed = try moduleSources.contains { moduleSource in
                let imports = try analysis(at: moduleSource).usage
                    .importedModuleNames
                return !imports.isDisjoint(with: clangModuleNames)
            }
            directlyClangBackedByModule[moduleName] = backed
            return backed
        }

        func select(
            moduleName: String,
            sources moduleSources: Set<String>
        ) {
            guard selectedModules.insert(moduleName).inserted else { return }
            selectedFiles.formUnion(moduleSources)
            pending.append(contentsOf: moduleSources.sorted())
        }

        while let sourcePath = pending.first {
            pending.removeFirst()
            guard scanned.insert(sourcePath).inserted else { continue }
            let usage = try analysis(at: sourcePath).usage
            for reference in usage.qualifiedReferences.sorted(by: {
                ($0.moduleName, $0.memberName)
                    < ($1.moduleName, $1.memberName)
            }) {
                guard let moduleSources = sourcesByModule[reference.moduleName]
                else { continue }
                guard try !isDirectlyClangBacked(
                    reference.moduleName, sources: moduleSources)
                else { continue }
                guard try declarations(
                    in: reference.moduleName,
                    sources: moduleSources
                ).contains(reference.memberName) else { continue }
                select(
                    moduleName: reference.moduleName,
                    sources: moduleSources)
            }
            for moduleName in usage.importedModuleNames.sorted() {
                guard let moduleSources = sourcesByModule[moduleName],
                      try !isDirectlyClangBacked(
                        moduleName, sources: moduleSources),
                      !usage.unqualifiedReferences.isDisjoint(with:
                        try declarations(
                            in: moduleName,
                            sources: moduleSources))
                else { continue }
                select(moduleName: moduleName, sources: moduleSources)
            }
        }
        return selectedFiles.subtracting(roots).sorted()
    }

    private struct SwiftPMBuildModule {
        let name: String
        let sources: [String]
        let moduleMapPaths: [String]
    }

    /// A Swift target that directly imports a Clang module is not a
    /// self-contained interpreter input. SwiftPM's module-map arguments are
    /// compiler evidence for that boundary: leave the target as an opaque
    /// compiled import instead of executing only its Swift half with inert C
    /// functions and fabricating scalar results.
    private static func clangModuleNames(
        in modules: [SwiftPMBuildModule]
    ) -> Set<String> {
        var names: Set<String> = []
        for path in Set(modules.flatMap(\.moduleMapPaths)).sorted() {
            guard let contents = try? String(
                contentsOfFile: path, encoding: .utf8)
            else { continue }
            for line in contents.split(separator: "\n") {
                let words = line.split(whereSeparator: { $0.isWhitespace })
                let candidate: Substring?
                if words.first == "module", words.count >= 2 {
                    candidate = words[1]
                } else if words.count >= 3,
                          words[0] == "framework", words[1] == "module" {
                    candidate = words[2]
                } else {
                    candidate = nil
                }
                guard let candidate else { continue }
                let name = candidate.prefix {
                    $0.isLetter || $0.isNumber || $0 == "_"
                }
                if !name.isEmpty { names.insert(String(name)) }
            }
        }
        return names
    }

    private static func swiftPMBuildModules(
        at path: String
    ) throws -> [SwiftPMBuildModule] {
        let descriptionURL = URL(fileURLWithPath: path)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: descriptionURL) else {
            throw SwiftPMBuildDescriptionMaterialError
                .unreadableDescription(descriptionURL.path)
        }
        let description: SwiftPMBuildDescriptionMaterial
        do {
            description = try JSONDecoder().decode(
                SwiftPMBuildDescriptionMaterial.self, from: data)
        } catch {
            throw SwiftPMBuildDescriptionMaterialError
                .invalidDescription(descriptionURL.path)
        }
        guard !description.swiftCommands.isEmpty else {
            throw SwiftPMBuildDescriptionMaterialError
                .noSwiftCommands(descriptionURL.path)
        }

        var modules: [SwiftPMBuildModule] = []
        for command in description.swiftCommands.values.sorted(by: {
            if $0.moduleName != $1.moduleName {
                return $0.moduleName < $1.moduleName
            }
            return $0.sources.joined(separator: "\u{0}")
                < $1.sources.joined(separator: "\u{0}")
        }) {
            var files: Set<String> = []
            for source in command.sources where source.hasSuffix(".swift") {
                let sourceURL = URL(fileURLWithPath: source)
                    .standardizedFileURL.resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    throw SwiftPMBuildDescriptionMaterialError
                        .missingCompilerInput(sourceURL.path)
                }
                files.insert(sourceURL.path)
            }
            var moduleMapPaths: Set<String> = []
            let arguments = command.otherArguments ?? []
            var expectsModuleMapPath = false
            for argument in arguments {
                if expectsModuleMapPath {
                    moduleMapPaths.insert(URL(fileURLWithPath: argument)
                        .standardizedFileURL.resolvingSymlinksInPath().path)
                    expectsModuleMapPath = false
                } else if argument == "-fmodule-map-file" {
                    expectsModuleMapPath = true
                } else if argument.hasPrefix("-fmodule-map-file=") {
                    let path = String(argument.dropFirst(
                        "-fmodule-map-file=".count))
                    moduleMapPaths.insert(URL(fileURLWithPath: path)
                        .standardizedFileURL.resolvingSymlinksInPath().path)
                }
            }
            modules.append(SwiftPMBuildModule(
                name: command.moduleName, sources: files.sorted(),
                moduleMapPaths: moduleMapPaths.sorted()))
        }
        return modules
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
            var sourceImports: Set<String> = []
            let stripped = interpreterProjection(
                of: source.source,
                recordingImportsIn: &sourceImports
            )
            imports.formUnion(sourceImports)
            merged += sourceRegionStart(
                moduleName: manifest.buildTarget.moduleName,
                imports: sourceImports)
                + "\n// FILE: \(source.fileName)\n" + stripped + "\n"
                + sourceModuleEnd
        }
        merged += moduleProvenance(for: imports)
        merged += LibraryShims.shims(importedIn: imports, mergedSource: merged)
        return merged
    }

    /// Imports are stripped (the merge holds all the app's own Swift; the
    /// interpreter absorbs what a compiled import would provide).
    public static func mergedSource(
        at root: String,
        files: [String],
        sourceModules: [String: String] = [:],
        entryPoint: EntryPoint = .declared
    ) -> String {
        BundleBox.projectResourceRoot = root
        return mergedSource(
            files: files, sourceModules: sourceModules,
            entryPoint: entryPoint)
    }

    public static func mergedSource(
        files: [String],
        sourceModules: [String: String] = [:],
        entryPoint: EntryPoint = .declared
    ) -> String {
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
            var sourceImports: Set<String> = []
            let stripped = interpreterProjection(
                of: content,
                recordingImportsIn: &sourceImports,
                entryPoint: entryPoint
            )
            imports.formUnion(sourceImports)
            let canonicalPath = URL(fileURLWithPath: path)
                .standardizedFileURL.resolvingSymlinksInPath().path
            let moduleName = sourceModules[canonicalPath]
                ?? sourceModules[path]
            merged += sourceRegionStart(
                moduleName: moduleName, imports: sourceImports)
            merged += "\n// FILE: \(URL(fileURLWithPath: path).lastPathComponent)\n"
                + stripped + "\n"
            merged += sourceModuleEnd
        }
        merged += moduleProvenance(for: imports)
        // Source-distributed state libraries the app imports but doesn't
        // vendor get their distilled core appended (LibraryShims).
        merged += LibraryShims.shims(importedIn: imports, mergedSource: merged)
        return merged
    }

    /// Project one in-memory Swift file with the same import and module
    /// provenance as disk-backed compiler inputs. Instruments can append the
    /// result to a larger merge without placing the inline file in the
    /// lexical scope of whichever source happened to precede it.
    public static func mergedSource(
        source: String,
        moduleName: String? = nil
    ) -> String {
        var imports: Set<String> = []
        let stripped = interpreterProjection(
            of: source,
            recordingImportsIn: &imports)
        var merged = sourceRegionStart(
            moduleName: moduleName, imports: imports)
        merged += "\n// FILE: <inline>.swift\n" + stripped + "\n"
        merged += sourceModuleEnd
        merged += moduleProvenance(for: imports)
        merged += LibraryShims.shims(
            importedIn: imports, mergedSource: merged)
        return merged
    }

    /// Imports cannot remain as executable declarations in the flattened
    /// projection, but their module-lookup semantics must. These inert,
    /// deterministic directives are consumed by ParsedProgramMetadata.
    private static func moduleProvenance(for imports: Set<String>) -> String {
        guard !imports.isEmpty else { return "" }
        return "\n" + imports.sorted().map {
            "// swift-interpreter-module \($0)"
        }.joined(separator: "\n") + "\n"
    }

    private static let sourceModuleEnd =
        "\n// swift-interpreter-source-module-end\n"

    private static func sourceRegionStart(
        moduleName: String?,
        imports: Set<String>
    ) -> String {
        let provenance = imports.sorted().map {
            "// swift-interpreter-source-import \($0)"
        }.joined(separator: "\n")
        let start = moduleName.map {
            "// swift-interpreter-source-module \($0)"
        } ?? "// swift-interpreter-source-file"
        return "\n" + start
            + (provenance.isEmpty ? "" : "\n" + provenance)
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

    /// Whether a merge keeps the entry point its sources declare. Hosting an
    /// app's sources under a different scene is the arrangement SwiftPM
    /// expresses by compiling them as a library target: every type stays, the
    /// entry point does not, and two `@main` types never compete for it.
    public enum EntryPoint: Sendable {
        case declared
        case suppliedByCaller
    }

    private static func interpreterProjection(
        of source: String,
        recordingImportsIn imports: inout Set<String>,
        entryPoint: EntryPoint = .declared
    ) -> String {
        let lines = source.split(
            separator: "\n", omittingEmptySubsequences: false)
        // The ordinary merge keeps every line as it stands; only a hosted
        // merge inspects them, so the corpus-wide path allocates nothing.
        let hosted = entryPoint == .declared ? lines : lines.map { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed == "@main" { return trimmed.prefix(0) }
            if trimmed.hasPrefix("@main ") {
                return trimmed.dropFirst("@main ".count)
            }
            return line
        }
        return hosted.filter { line in
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
        let sourceRegionMarker = "// swift-interpreter-source-"
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
                let prefix = $0.trimmingCharacters(in: .whitespaces)
                return !prefix.isEmpty
                    && !prefix.hasPrefix(sourceRegionMarker)
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
