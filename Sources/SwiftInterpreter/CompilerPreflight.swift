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
    let sourcePath: String
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

/// A bounded, compiler-backed semantic check. Compiler failures are returned
/// as data; only discovery, launch, and deadline failures throw.
public final class SwiftCompilerPreflight {
    public static let emptyGatewayManifestSHA256 =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public let configuration: CompilerPreflightConfiguration

    typealias Executor = (
        CompilerPreflightConfiguration, String, String
    ) throws -> CompilerPreflightInvocationOutput

    private let cache: CompilerPreflightCache
    private let executor: Executor

    public init(configuration: CompilerPreflightConfiguration) {
        self.configuration = configuration
        cache = CompilerPreflightCache()
        executor = Self.invokeCompiler
    }

    init(
        configuration: CompilerPreflightConfiguration,
        cache: CompilerPreflightCache,
        executor: @escaping Executor
    ) {
        self.configuration = configuration
        self.cache = cache
        self.executor = executor
    }

    /// Discover the active Xcode compiler and macOS SDK. The target triple
    /// includes the compiler-selected deployment version and is passed back to
    /// every typecheck instead of relying on mutable process defaults.
    public static func activeMacOS(
        gatewayManifestSHA256: String,
        additionalCompilerArguments: [String] = [],
        timeoutSeconds: TimeInterval = 10
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
        return SwiftCompilerPreflight(configuration: configuration)
        #else
        throw CompilerPreflightError.unsupportedPlatform
        #endif
    }

    public func preflight(
        source: String,
        fileName: String = "input.swift"
    ) throws -> CompilerPreflightResult {
        let logicalFileName = sanitizedFileName(fileName)
        let key = compilerPreflightDigest([
            "compiler-preflight-result-v1",
            configuration.fingerprint,
            logicalFileName,
            source,
        ])
        if let cached = cache.value(for: key) {
            return cached.markingCached()
        }

        let output = try executor(configuration, source, logicalFileName)
        let diagnostics = Self.parseDiagnostics(
            output.standardError + "\n" + output.standardOutput,
            sourcePath: output.sourcePath,
            logicalFileName: logicalFileName)
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
        source: String,
        fileName: String
    ) throws -> CompilerPreflightInvocationOutput {
        #if os(macOS)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-preflight-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent(fileName)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let moduleCache = directory.appendingPathComponent(
            "ModuleCache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: moduleCache, withIntermediateDirectories: true)

        let arguments = [
            "-swift-version", "6",
            "-strict-concurrency=complete",
            "-diagnostic-style", "llvm",
            "-sdk", configuration.sdkPath,
            "-target", configuration.targetTriple,
            "-module-cache-path", moduleCache.path,
            "-typecheck",
        ] + configuration.additionalCompilerArguments + [sourceURL.path]
        let output = try executeProcess(
            executable: configuration.swiftCompilerPath,
            arguments: arguments,
            timeoutSeconds: configuration.timeoutSeconds)
        return CompilerPreflightInvocationOutput(
            exitStatus: output.exitStatus,
            standardOutput: output.standardOutput,
            standardError: output.standardError,
            sourcePath: sourceURL.path)
        #else
        throw CompilerPreflightError.unsupportedPlatform
        #endif
    }

    private static func parseDiagnostics(
        _ output: String,
        sourcePath: String,
        logicalFileName: String
    ) -> [CompilerPreflightDiagnostic] {
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
                let reportedFile = file == sourcePath
                    ? logicalFileName : file
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

    func performCompilerPreflightIfNeeded(source: String) throws {
        switch compilerPreflightMode {
        case .disabled:
            return
        case .diagnosticsOnly:
            _ = try preflight(source: source)
        case .required:
            let result = try preflight(source: source)
            guard result.succeeded else {
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
