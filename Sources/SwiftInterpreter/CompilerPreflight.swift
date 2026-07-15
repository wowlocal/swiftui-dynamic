import CryptoKit
#if os(macOS)
import Darwin
#endif
import Foundation

public enum CompilerPreflightMode: String, Sendable {
    /// Preserve the interpreter's existing editor/runtime behavior.
    case disabled
    /// Retain native diagnostics but allow interpretation to continue.
    case diagnosticsOnly
    /// Reject source with native compiler errors before parsing or execution.
    case required
}

/// Immutable source for a generated declaration module imported by compiler
/// preflight. The module is compiled once per engine; only its serialized
/// public declarations participate in checking user source.
public struct CompilerPreflightHostModule: Sendable, Equatable {
    public let moduleName: String
    public let source: String
    public let sourceSHA256: String
    public let manifestSHA256: String

    public init(moduleName: String, source: String) {
        self.moduleName = moduleName
        self.source = source
        self.sourceSHA256 = SHA256.hash(data: Data(source.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        self.manifestSHA256 = compilerPreflightDigest([
            "compiler-preflight-host-module-v1",
            moduleName,
            sourceSHA256,
        ])
    }
}

/// One logical Swift source file participating in a compiler-preflight
/// module. Keeping files separate preserves Swift's file-scoped access rules
/// and lets diagnostics point back to the source that produced them.
public struct CompilerPreflightSource: Sendable, Equatable {
    public let fileName: String
    public let source: String

    public init(fileName: String, source: String) {
        self.fileName = fileName
        self.source = source
    }
}

public struct CompilerPreflightConfiguration: Sendable, Equatable {
    public let swiftCompilerPath: String
    public let compilerVersion: String
    public let sdkPath: String
    public let sdkVersion: String
    public let targetTriple: String
    public let deploymentTarget: String
    public let gatewayManifestSHA256: String
    public let additionalCompilerArguments: [String]
    public let timeoutSeconds: TimeInterval

    public init(
        swiftCompilerPath: String,
        compilerVersion: String,
        sdkPath: String,
        sdkVersion: String,
        targetTriple: String,
        deploymentTarget: String,
        gatewayManifestSHA256: String,
        additionalCompilerArguments: [String] = [],
        timeoutSeconds: TimeInterval = 10
    ) {
        self.swiftCompilerPath = swiftCompilerPath
        self.compilerVersion = compilerVersion
        self.sdkPath = sdkPath
        self.sdkVersion = sdkVersion
        self.targetTriple = targetTriple
        self.deploymentTarget = deploymentTarget
        self.gatewayManifestSHA256 = gatewayManifestSHA256
        self.additionalCompilerArguments = additionalCompilerArguments
        self.timeoutSeconds = timeoutSeconds
    }

    /// Stable identity for every input that can change native type checking.
    public var fingerprint: String {
        compilerPreflightDigest([
            "compiler-preflight-configuration-v1",
            swiftCompilerPath,
            compilerVersion,
            sdkPath,
            sdkVersion,
            targetTriple,
            deploymentTarget,
            gatewayManifestSHA256,
            additionalCompilerArguments.joined(separator: "\u{0}"),
        ])
    }
}

public struct CompilerPreflightDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable {
        case error
        case warning
        case note
        case remark
    }

    public let severity: Severity
    public let message: String
    public let file: String?
    public let line: Int?
    public let column: Int?
}

public struct CompilerPreflightResult: Sendable, Equatable {
    public let cacheKey: String
    public let configurationFingerprint: String
    public let exitStatus: Int32
    public let diagnostics: [CompilerPreflightDiagnostic]
    public let standardOutput: String
    public let standardError: String
    public let wasCached: Bool

    public var succeeded: Bool { exitStatus == 0 }

    fileprivate func markingCached() -> CompilerPreflightResult {
        CompilerPreflightResult(
            cacheKey: cacheKey,
            configurationFingerprint: configurationFingerprint,
            exitStatus: exitStatus,
            diagnostics: diagnostics,
            standardOutput: standardOutput,
            standardError: standardError,
            wasCached: true)
    }
}

public enum CompilerPreflightError: Error, CustomStringConvertible {
    case notConfigured
    case unsupportedPlatform
    case invalidConfiguration(String)
    case launchFailed(String)
    case commandFailed(String)
    case timedOut(TimeInterval)
    case invalidToolchainOutput(String)
    case hostModuleCompilationFailed(
        moduleName: String, exitStatus: Int32, diagnostics: String)

    public var description: String {
        switch self {
        case .notConfigured:
            "compiler preflight was requested without a configured engine"
        case .unsupportedPlatform:
            "native compiler preflight is available only in a macOS host process"
        case .invalidConfiguration(let message):
            "invalid compiler preflight configuration: \(message)"
        case .launchFailed(let message):
            "could not launch compiler preflight: \(message)"
        case .commandFailed(let message):
            "compiler preflight discovery failed: \(message)"
        case .timedOut(let seconds):
            "compiler preflight exceeded its \(seconds)-second deadline"
        case .invalidToolchainOutput(let message):
            "compiler preflight received invalid toolchain metadata: \(message)"
        case .hostModuleCompilationFailed(
            let moduleName, let exitStatus, let diagnostics):
            "compiler preflight could not compile host module '\(moduleName)' "
                + "(exit \(exitStatus)): \(diagnostics)"
        }
    }
}

public struct CompilerPreflightRejection: Error, CustomStringConvertible {
    public let result: CompilerPreflightResult

    public var description: String {
        let errors = result.diagnostics.filter { $0.severity == .error }
        if errors.isEmpty {
            return "native compiler rejected source:\n\(result.standardError)"
        }
        return errors.map { diagnostic in
            let location: String
            if let file = diagnostic.file,
               let line = diagnostic.line,
               let column = diagnostic.column {
                location = "\(file):\(line):\(column): "
            } else {
                location = ""
            }
            return location + "error: " + diagnostic.message
        }.joined(separator: "\n")
    }
}

struct CompilerPreflightInvocationOutput {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
    let logicalFileNamesByPath: [String: String]
}

struct CompilerPreflightModuleImport {
    let moduleName: String
    let searchPath: String
}

final class CompilerPreflightCache {
    private let capacity: Int
    private var values: [String: CompilerPreflightResult] = [:]
    private var recency: [String] = []

    init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    func value(for key: String) -> CompilerPreflightResult? {
        guard let value = values[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return value
    }

    func insert(_ value: CompilerPreflightResult, for key: String) {
        values[key] = value
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > capacity {
            values.removeValue(forKey: recency.removeFirst())
        }
    }
}

final class CompilerPreflightHostModuleBuild {
    let module: CompilerPreflightHostModule
    private var artifactDirectory: URL?
    private var preparedImport: CompilerPreflightModuleImport?
    private(set) var compilationCount = 0

    init(module: CompilerPreflightHostModule) {
        self.module = module
    }

    deinit {
        if let artifactDirectory {
            try? FileManager.default.removeItem(at: artifactDirectory)
        }
    }

    func prepare(
        configuration: CompilerPreflightConfiguration
    ) throws -> CompilerPreflightModuleImport {
        if let preparedImport { return preparedImport }
        guard isValidCompilerModuleName(module.moduleName) else {
            throw CompilerPreflightError.invalidConfiguration(
                "host module name '\(module.moduleName)' is not a Swift identifier")
        }
        guard !module.source.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw CompilerPreflightError.invalidConfiguration(
                "host module source is empty")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-host-module-\(UUID().uuidString)",
                isDirectory: true)
        do {
            let modules = directory.appendingPathComponent(
                "Modules", isDirectory: true)
            let moduleCache = directory.appendingPathComponent(
                "ModuleCache", isDirectory: true)
            try FileManager.default.createDirectory(
                at: modules, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: moduleCache, withIntermediateDirectories: true)
            let sourceURL = directory.appendingPathComponent(
                module.moduleName + ".swift")
            try module.source.write(
                to: sourceURL, atomically: true, encoding: .utf8)
            let moduleURL = modules.appendingPathComponent(
                module.moduleName + ".swiftmodule")
            let arguments = [
                "-swift-version", "6",
                "-strict-concurrency=complete",
                "-sdk", configuration.sdkPath,
                "-target", configuration.targetTriple,
                "-module-cache-path", moduleCache.path,
                "-parse-as-library",
                "-module-name", module.moduleName,
                "-emit-module",
                "-emit-module-path", moduleURL.path,
            ] + configuration.additionalCompilerArguments + [sourceURL.path]
            compilationCount += 1
            let output = try executeProcess(
                executable: configuration.swiftCompilerPath,
                arguments: arguments,
                timeoutSeconds: configuration.timeoutSeconds)
            guard output.exitStatus == 0 else {
                let diagnostics = (
                    output.standardError + "\n" + output.standardOutput
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                throw CompilerPreflightError.hostModuleCompilationFailed(
                    moduleName: module.moduleName,
                    exitStatus: output.exitStatus,
                    diagnostics: diagnostics)
            }
            let moduleImport = CompilerPreflightModuleImport(
                moduleName: module.moduleName,
                searchPath: modules.path)
            artifactDirectory = directory
            preparedImport = moduleImport
            return moduleImport
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

/// A bounded, compiler-backed semantic check. Compiler failures are returned
/// as data; only discovery, launch, and deadline failures throw.
public final class SwiftCompilerPreflight {
    public static let emptyGatewayManifestSHA256 =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public let configuration: CompilerPreflightConfiguration
    public let hostModule: CompilerPreflightHostModule?

    typealias Executor = (
        CompilerPreflightConfiguration, [CompilerPreflightSource],
        CompilerPreflightModuleImport?
    ) throws -> CompilerPreflightInvocationOutput

    private let cache: CompilerPreflightCache
    private let executor: Executor
    private let hostModuleBuild: CompilerPreflightHostModuleBuild?

    var hostModuleCompilationCount: Int {
        hostModuleBuild?.compilationCount ?? 0
    }

    public init(configuration: CompilerPreflightConfiguration) {
        self.configuration = configuration
        hostModule = nil
        cache = CompilerPreflightCache()
        executor = Self.invokeCompiler
        hostModuleBuild = nil
    }

    public init(
        configuration: CompilerPreflightConfiguration,
        hostModule: CompilerPreflightHostModule
    ) throws {
        guard configuration.gatewayManifestSHA256
                == hostModule.manifestSHA256 else {
            throw CompilerPreflightError.invalidConfiguration(
                "gateway manifest identity does not match host module source")
        }
        self.configuration = configuration
        self.hostModule = hostModule
        cache = CompilerPreflightCache()
        executor = Self.invokeCompiler
        hostModuleBuild = CompilerPreflightHostModuleBuild(module: hostModule)
    }

    init(
        configuration: CompilerPreflightConfiguration,
        cache: CompilerPreflightCache,
        executor: @escaping Executor
    ) {
        self.configuration = configuration
        hostModule = nil
        self.cache = cache
        self.executor = executor
        hostModuleBuild = nil
    }

    /// Discover the active Xcode compiler and macOS SDK. The target triple
    /// includes the compiler-selected deployment version and is passed back to
    /// every typecheck instead of relying on mutable process defaults.
    public static func activeMacOS(
        gatewayManifestSHA256: String,
        additionalCompilerArguments: [String] = [],
        timeoutSeconds: TimeInterval = 10
    ) throws -> SwiftCompilerPreflight {
        try activeMacOS(
            gatewayManifestSHA256: gatewayManifestSHA256,
            hostModule: nil,
            additionalCompilerArguments: additionalCompilerArguments,
            timeoutSeconds: timeoutSeconds)
    }

    /// Discover the active compiler and compile the generated host surface
    /// into an importable module before checking user source.
    public static func activeMacOS(
        hostModule: CompilerPreflightHostModule,
        additionalCompilerArguments: [String] = [],
        timeoutSeconds: TimeInterval = 10
    ) throws -> SwiftCompilerPreflight {
        try activeMacOS(
            gatewayManifestSHA256: hostModule.manifestSHA256,
            hostModule: hostModule,
            additionalCompilerArguments: additionalCompilerArguments,
            timeoutSeconds: timeoutSeconds)
    }

    /// Bind discovery to the same registry that will execute host calls. An
    /// empty registry preserves ordinary compiler checking without inventing
    /// gateway declarations.
    public static func activeMacOS(
        registry: HostRegistry?,
        additionalCompilerArguments: [String] = [],
        timeoutSeconds: TimeInterval = 10
    ) throws -> SwiftCompilerPreflight {
        if let hostModule = registry?.compilerPreflightHostModule {
            return try activeMacOS(
                hostModule: hostModule,
                additionalCompilerArguments: additionalCompilerArguments,
                timeoutSeconds: timeoutSeconds)
        }
        return try activeMacOS(
            gatewayManifestSHA256: emptyGatewayManifestSHA256,
            additionalCompilerArguments: additionalCompilerArguments,
            timeoutSeconds: timeoutSeconds)
    }

    private static func activeMacOS(
        gatewayManifestSHA256: String,
        hostModule: CompilerPreflightHostModule?,
        additionalCompilerArguments: [String],
        timeoutSeconds: TimeInterval
    ) throws -> SwiftCompilerPreflight {
        #if os(macOS)
        let xcrun = "/usr/bin/xcrun"
        let swiftc = try requiredOutput(
            executable: xcrun,
            arguments: ["--find", "swiftc"],
            timeoutSeconds: timeoutSeconds,
            operation: "locate swiftc")
        let version = try requiredOutput(
            executable: swiftc,
            arguments: ["--version"],
            timeoutSeconds: timeoutSeconds,
            operation: "read swiftc version")
        let sdkPath = try requiredOutput(
            executable: xcrun,
            arguments: ["--show-sdk-path", "--sdk", "macosx"],
            timeoutSeconds: timeoutSeconds,
            operation: "locate macOS SDK")
        let sdkVersion = try requiredOutput(
            executable: xcrun,
            arguments: ["--show-sdk-version", "--sdk", "macosx"],
            timeoutSeconds: timeoutSeconds,
            operation: "read macOS SDK version")
        let targetData = try requiredOutput(
            executable: swiftc,
            arguments: ["-print-target-info", "-sdk", sdkPath],
            timeoutSeconds: timeoutSeconds,
            operation: "read compiler target info")
        struct TargetInfo: Decodable {
            struct Target: Decodable { let triple: String }
            let target: Target
        }
        guard let data = targetData.data(using: .utf8),
              let target = try? JSONDecoder().decode(
                TargetInfo.self, from: data).target.triple else {
            throw CompilerPreflightError.invalidToolchainOutput(targetData)
        }
        let configuration = CompilerPreflightConfiguration(
            swiftCompilerPath: swiftc,
            compilerVersion: version.replacingOccurrences(of: "\n", with: " | "),
            sdkPath: sdkPath,
            sdkVersion: sdkVersion,
            targetTriple: target,
            deploymentTarget: deploymentTarget(in: target),
            gatewayManifestSHA256: gatewayManifestSHA256,
            additionalCompilerArguments: additionalCompilerArguments,
            timeoutSeconds: timeoutSeconds)
        if let hostModule {
            return try SwiftCompilerPreflight(
                configuration: configuration, hostModule: hostModule)
        }
        return SwiftCompilerPreflight(configuration: configuration)
        #else
        throw CompilerPreflightError.unsupportedPlatform
        #endif
    }

    public func preflight(
        source: String,
        fileName: String = "input.swift"
    ) throws -> CompilerPreflightResult {
        try preflight(sources: [CompilerPreflightSource(
            fileName: fileName,
            source: source,
        )])
    }

    /// Typecheck all inputs in one native Swift module while retaining their
    /// file boundaries. Source order and logical filenames are part of the
    /// cache identity because both can affect compiler behavior and evidence.
    public func preflight(
        sources: [CompilerPreflightSource]
    ) throws -> CompilerPreflightResult {
        guard !sources.isEmpty else {
            throw CompilerPreflightError.invalidConfiguration(
                "compiler preflight requires at least one source file")
        }
        let normalizedSources = sources.map {
            CompilerPreflightSource(
                fileName: sanitizedFileName($0.fileName),
                source: $0.source)
        }
        var keyComponents = [
            "compiler-preflight-result-v2",
            configuration.fingerprint,
            String(normalizedSources.count),
        ]
        for source in normalizedSources {
            keyComponents.append(source.fileName)
            keyComponents.append(source.source)
        }
        let key = compilerPreflightDigest(keyComponents)
        if let cached = cache.value(for: key) {
            return cached.markingCached()
        }

        let moduleImport = try hostModuleBuild?.prepare(
            configuration: configuration)
        let output = try executor(
            configuration, normalizedSources, moduleImport)
        let diagnostics = Self.parseDiagnostics(
            output.standardError + "\n" + output.standardOutput,
            logicalFileNamesByPath: output.logicalFileNamesByPath)
        let result = CompilerPreflightResult(
            cacheKey: key,
            configurationFingerprint: configuration.fingerprint,
            exitStatus: output.exitStatus,
            diagnostics: diagnostics,
            standardOutput: output.standardOutput,
            standardError: output.standardError,
            wasCached: false)
        cache.insert(result, for: key)
        return result
    }

    private static func invokeCompiler(
        configuration: CompilerPreflightConfiguration,
        sources: [CompilerPreflightSource],
        moduleImport: CompilerPreflightModuleImport?
    ) throws -> CompilerPreflightInvocationOutput {
        #if os(macOS)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-preflight-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let moduleCache = directory.appendingPathComponent(
            "ModuleCache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: moduleCache, withIntermediateDirectories: true)

        var usedPhysicalFileNames: Set<String> = []
        var sourceURLs: [URL] = []
        var logicalFileNamesByPath: [String: String] = [:]
        for (index, source) in sources.enumerated() {
            var physicalFileName = source.fileName
            var discriminator = index + 1
            while usedPhysicalFileNames.contains(physicalFileName) {
                physicalFileName = String(
                    format: "%04d-%@", discriminator, source.fileName)
                discriminator += 1
            }
            usedPhysicalFileNames.insert(physicalFileName)
            let sourceURL = directory.appendingPathComponent(physicalFileName)
            let compilerSource: String
            if let moduleImport {
                compilerSource = sourceByImportingHostModule(
                    moduleImport.moduleName,
                    into: source.source,
                    fileName: source.fileName)
            } else {
                compilerSource = source.source
            }
            try compilerSource.write(
                to: sourceURL, atomically: true, encoding: .utf8)
            sourceURLs.append(sourceURL)
            logicalFileNamesByPath[sourceURL.path] = source.fileName
        }

        var arguments = [
            "-swift-version", "6",
            "-strict-concurrency=complete",
            "-diagnostic-style", "llvm",
            "-sdk", configuration.sdkPath,
            "-target", configuration.targetTriple,
            "-module-cache-path", moduleCache.path,
            "-typecheck",
        ]
        if let moduleImport {
            arguments += ["-I", moduleImport.searchPath]
        }
        arguments += configuration.additionalCompilerArguments
        arguments += sourceURLs.map(\.path)
        let output = try executeProcess(
            executable: configuration.swiftCompilerPath,
            arguments: arguments,
            timeoutSeconds: configuration.timeoutSeconds)
        return CompilerPreflightInvocationOutput(
            exitStatus: output.exitStatus,
            standardOutput: output.standardOutput,
            standardError: output.standardError,
            logicalFileNamesByPath: logicalFileNamesByPath)
        #else
        throw CompilerPreflightError.unsupportedPlatform
        #endif
    }

    private static func parseDiagnostics(
        _ output: String,
        logicalFileNamesByPath: [String: String]
    ) -> [CompilerPreflightDiagnostic] {
        let standardizedLogicalFileNamesByPath = Dictionary(
            uniqueKeysWithValues: logicalFileNamesByPath.map {
                (URL(fileURLWithPath: $0.key).standardizedFileURL.path, $0.value)
            })
        let located = try? NSRegularExpression(pattern:
            #"^(.+):([0-9]+):([0-9]+): (error|warning|note|remark): (.+)$"#)
        let unlocated = try? NSRegularExpression(pattern:
            #"^(error|warning|note|remark): (.+)$"#)
        return output.split(
            separator: "\n", omittingEmptySubsequences: true
        ).compactMap { rawLine in
            let line = String(rawLine)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = located?.firstMatch(
                in: line, options: [], range: range),
               let file = capture(1, from: match, in: line),
               let rawLineNumber = capture(2, from: match, in: line),
               let rawColumn = capture(3, from: match, in: line),
               let rawSeverity = capture(4, from: match, in: line),
               let severity = CompilerPreflightDiagnostic.Severity(
                rawValue: rawSeverity),
               let message = capture(5, from: match, in: line) {
                let reportedFile = logicalFileNamesByPath[file]
                    ?? standardizedLogicalFileNamesByPath[
                        URL(fileURLWithPath: file).standardizedFileURL.path]
                    ?? file
                return CompilerPreflightDiagnostic(
                    severity: severity,
                    message: message,
                    file: reportedFile,
                    line: Int(rawLineNumber),
                    column: Int(rawColumn))
            }
            if let match = unlocated?.firstMatch(
                in: line, options: [], range: range),
               let rawSeverity = capture(1, from: match, in: line),
               let severity = CompilerPreflightDiagnostic.Severity(
                rawValue: rawSeverity),
               let message = capture(2, from: match, in: line) {
                return CompilerPreflightDiagnostic(
                    severity: severity,
                    message: message,
                    file: nil,
                    line: nil,
                    column: nil)
            }
            return nil
        }
    }

    private static func capture(
        _ index: Int,
        from match: NSTextCheckingResult,
        in source: String
    ) -> String? {
        guard let range = Range(match.range(at: index), in: source) else {
            return nil
        }
        return String(source[range])
    }
}

extension Interpreter {
    /// Construct an interpreter whose compiler environment and runtime host
    /// implementations come from one registry identity.
    public static func withActiveCompilerPreflight(
        registry: HostRegistry? = nil,
        mode: CompilerPreflightMode = .required,
        additionalCompilerArguments: [String] = [],
        timeoutSeconds: TimeInterval = 10
    ) throws -> Interpreter {
        let preflight = try SwiftCompilerPreflight.activeMacOS(
            registry: registry,
            additionalCompilerArguments: additionalCompilerArguments,
            timeoutSeconds: timeoutSeconds)
        return Interpreter(
            registry: registry,
            compilerPreflight: preflight,
            compilerPreflightMode: mode)
    }

    /// Run the configured engine directly regardless of execution mode.
    @discardableResult
    public func preflight(
        source: String,
        fileName: String = "input.swift"
    ) throws -> CompilerPreflightResult {
        guard let compilerPreflight else {
            throw CompilerPreflightError.notConfigured
        }
        let result = try compilerPreflight.preflight(
            source: source, fileName: fileName)
        lastCompilerPreflightResult = result
        return result
    }

    /// Run one native typecheck over a logical multi-file Swift module.
    @discardableResult
    public func preflight(
        sources: [CompilerPreflightSource]
    ) throws -> CompilerPreflightResult {
        guard let compilerPreflight else {
            throw CompilerPreflightError.notConfigured
        }
        let result = try compilerPreflight.preflight(sources: sources)
        lastCompilerPreflightResult = result
        return result
    }

    func performCompilerPreflightIfNeeded(
        source: String,
        sources: [CompilerPreflightSource]? = nil
    ) throws {
        switch compilerPreflightMode {
        case .disabled:
            return
        case .diagnosticsOnly, .required:
            let result: CompilerPreflightResult
            if let sources {
                result = try preflight(sources: sources)
            } else {
                result = try preflight(source: source)
            }
            guard compilerPreflightMode == .diagnosticsOnly
                    || result.succeeded else {
                throw CompilerPreflightRejection(result: result)
            }
        }
    }
}

private struct CompilerPreflightProcessOutput {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
}

#if os(macOS)
private struct CompilerPreflightProcessIdentity: Equatable {
    let identifier: pid_t
    let startToken: String
}
#endif

private func compilerPreflightDigest(_ components: [String]) -> String {
    var data = Data()
    for component in components {
        let bytes = Data(component.utf8)
        data.append(Data("\(bytes.count):".utf8))
        data.append(bytes)
    }
    return SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}

private func sanitizedFileName(_ fileName: String) -> String {
    let candidate = URL(fileURLWithPath: fileName).lastPathComponent
    return candidate.isEmpty ? "input.swift" : candidate
}

private func isValidCompilerModuleName(_ name: String) -> Bool {
    guard let first = name.first,
          first == "_" || first.isASCII && first.isLetter else {
        return false
    }
    return name.dropFirst().allSatisfy {
        $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber)
    }
}

private func swiftStringLiteral(_ value: String) -> String {
    "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t") + "\""
}

private func sourceByImportingHostModule(
    _ moduleName: String,
    into source: String,
    fileName: String
) -> String {
    let sourceLocation = "#sourceLocation(file: "
        + swiftStringLiteral(fileName)
    if source.hasPrefix("#!") {
        let newline = source.firstIndex(of: "\n") ?? source.endIndex
        let shebang = source[..<newline]
        let remainderStart = newline == source.endIndex
            ? newline : source.index(after: newline)
        return shebang + "\nimport \(moduleName)\n"
            + sourceLocation + ", line: 2)\n"
            + source[remainderStart...]
    }
    return "import \(moduleName)\n"
        + sourceLocation + ", line: 1)\n"
        + source
}

private func deploymentTarget(in triple: String) -> String {
    for marker in ["macosx", "ios", "tvos", "watchos", "xros"] {
        guard let range = triple.range(of: marker) else { continue }
        let suffix = triple[range.upperBound...]
        let version = suffix.prefix { $0.isNumber || $0 == "." }
        if !version.isEmpty { return String(version) }
    }
    return "unspecified"
}

#if os(macOS)
private func requiredOutput(
    executable: String,
    arguments: [String],
    timeoutSeconds: TimeInterval,
    operation: String
) throws -> String {
    let output = try executeProcess(
        executable: executable,
        arguments: arguments,
        timeoutSeconds: timeoutSeconds)
    guard output.exitStatus == 0 else {
        throw CompilerPreflightError.commandFailed(
            "\(operation) exited \(output.exitStatus): \(output.standardError)")
    }
    let value = output.standardOutput.trimmingCharacters(
        in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
        throw CompilerPreflightError.invalidToolchainOutput(
            "\(operation) returned no output")
    }
    return value
}

private func executeProcess(
    executable: String,
    arguments: [String],
    timeoutSeconds: TimeInterval
) throws -> CompilerPreflightProcessOutput {
    guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
        throw CompilerPreflightError.invalidConfiguration(
            "timeout must be a positive finite number")
    }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "dynamic-swift-preflight-process-\(UUID().uuidString)",
            isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let stdoutURL = directory.appendingPathComponent("stdout")
    let stderrURL = directory.appendingPathComponent("stderr")
    _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer {
        try? stdout.close()
        try? stderr.close()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    do {
        try process.run()
    } catch {
        throw CompilerPreflightError.launchFailed(String(describing: error))
    }

    let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
    while process.isRunning,
          ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
        // swiftc is a driver and may have live swift-frontend descendants.
        // Snapshot PID identities before TERM: a driver can exit and orphan a
        // frontend, while a bare PID can be reused before SIGKILL escalation.
        let identities = (compilerPreflightDescendantProcessIdentifiers(
            of: process.processIdentifier) + [process.processIdentifier])
            .compactMap { compilerPreflightProcessIdentity(for: $0) }
        for identity in identities {
            compilerPreflightSignal(SIGTERM, ifStill: identity)
        }
        let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.05
        while identities.contains(where: compilerPreflightProcessIsRunning),
              ProcessInfo.processInfo.systemUptime < graceDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        for identity in identities {
            compilerPreflightSignal(SIGKILL, ifStill: identity)
        }
        process.waitUntilExit()
        throw CompilerPreflightError.timedOut(timeoutSeconds)
    }
    process.waitUntilExit()
    try? stdout.synchronize()
    try? stderr.synchronize()

    return CompilerPreflightProcessOutput(
        exitStatus: process.terminationStatus,
        standardOutput: (try? String(
            contentsOf: stdoutURL, encoding: .utf8)) ?? "",
        standardError: (try? String(
            contentsOf: stderrURL, encoding: .utf8)) ?? "")
}

private func compilerPreflightDescendantProcessIdentifiers(
    of parent: pid_t
) -> [pid_t] {
    // `proc_listchildpids` returns a PID count, not a byte count.
    let estimatedCount = proc_listchildpids(parent, nil, 0)
    guard estimatedCount > 0 else { return [] }
    var children = [pid_t](
        repeating: 0,
        count: Int(estimatedCount) + 8)
    let returnedCount = children.withUnsafeMutableBytes { buffer in
        proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
    }
    guard returnedCount > 0 else { return [] }
    return children.prefix(min(children.count, Int(returnedCount)))
        .filter { $0 > 0 }
        .flatMap {
            compilerPreflightDescendantProcessIdentifiers(of: $0) + [$0]
        }
}

private func compilerPreflightProcessIdentity(
    for identifier: pid_t
) -> CompilerPreflightProcessIdentity? {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let actualSize = proc_pidinfo(
        identifier,
        PROC_PIDTBSDINFO,
        0,
        &info,
        expectedSize)
    guard actualSize == expectedSize else { return nil }
    return CompilerPreflightProcessIdentity(
        identifier: identifier,
        startToken: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)")
}

private func compilerPreflightProcessIsRunning(
    _ identity: CompilerPreflightProcessIdentity
) -> Bool {
    compilerPreflightProcessIdentity(for: identity.identifier) == identity
}

private func compilerPreflightSignal(
    _ signal: Int32,
    ifStill identity: CompilerPreflightProcessIdentity
) {
    guard compilerPreflightProcessIsRunning(identity) else { return }
    _ = Darwin.kill(identity.identifier, signal)
}
#endif
