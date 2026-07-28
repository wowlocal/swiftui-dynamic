import BoundaryABI
import CryptoKit
import Foundation
import SwiftInterpreter

/// EXPERIMENT (not wired on by default). Services an SDK member call by
/// emitting a Swift shim for its already-parsed `HostSignature`, compiling it
/// against the real SDK, and calling it through a C entry point.
///
/// The point: this file contains no knowledge of any SDK type, member or
/// family. It reads receiver type, parameter labels/types and return type off
/// the signature BridgeGen already produced, and lets the real compiler do
/// overload resolution, generic instantiation, default arguments and builder
/// transforms — the work `Sources/BridgeGen` currently models by hand, one
/// per-API-family module at a time.
@MainActor
final class CompiledBoundary {
    static let shared = CompiledBoundary()

    /// Opt-in so the default dispatch path is untouched.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["BOUNDARY_JIT"] == "1"
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private var loaded: [String: BoundaryEntry] = [:]
    private var rejected: Set<String> = []

    /// Coverage telemetry: which declarations the mechanical emitter actually
    /// serviced, and which it handed back to the existing path and why.
    private(set) static var serviced: Set<String> = []
    private(set) static var fellBack: [String: String] = [:]

    static func note(declaration: String, error: Error) {
        fellBack[declaration] = "\(error)"
    }

    static func resetTelemetry() {
        serviced = []
        fellBack = [:]
    }

    // MARK: - Emission (signature-driven, no per-API knowledge)

    /// `nil` when the signature carries something the mechanical emitter does
    /// not model yet (generic parameters, variadics, async). Those fall back
    /// to the existing path rather than guessing.
    static func shimSource(
        for signature: HostSignature, symbol: String
    ) -> String? {
        guard signature.kind == .method,
              let receiverType = signature.receiverType,
              signature.genericParameters.isEmpty,
              !signature.isAsync,
              !signature.parameters.contains(where: \.isVariadic) else {
            return nil
        }

        var lines: [String] = []
        lines.append("""
            @_cdecl("\(symbol)")
            public func \(symbol)(_ raw: UnsafeMutableRawPointer) {
                let call = Unmanaged<BoundaryCall>
                    .fromOpaque(raw).takeUnretainedValue()
                guard let receiver = call.receiver as? \(receiverType) else {
                    call.failure = "receiver is not \(receiverType)"
                    return
                }
                guard call.arguments.count == \(signature.parameters.count)
                else {
                    call.failure = "expected \(signature.parameters.count) args"
                    return
                }
            """)

        for (index, parameter) in signature.parameters.enumerated() {
            lines.append("""
                    guard let p\(index) = call.arguments[\(index)]
                        as? \(parameter.type) else {
                        call.failure =
                            "argument \(index) is not \(parameter.type)"
                        return
                    }
                """)
        }

        let arguments = signature.parameters.enumerated().map { index, parameter in
            if let label = parameter.label {
                return "\(label): p\(index)"
            }
            return "p\(index)"
        }.joined(separator: ", ")

        let callExpression = "receiver.\(signature.name)(\(arguments))"
        let returnsVoid = signature.returnType == nil
            || signature.returnType == "Void" || signature.returnType == "()"
        let body = returnsVoid
            ? "\(callExpression)\n        call.result = ()"
            : "call.result = \(callExpression)"

        if signature.isThrowing {
            lines.append("""
                    do {
                        \(body.replacingOccurrences(
                            of: "call.result", with: "call.result"))
                    } catch {
                        call.failure = "threw \\(error)"
                    }
                }
                """)
        } else {
            lines.append("""
                    \(body)
                }
                """)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Compile, load, cache

    private static let cacheDirectory: URL = {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-dynamic-boundary-jit")
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Directory holding the package's built products, needed for the
    /// BoundaryABI swiftmodule and dylib. Experiment-grade discovery.
    private static func buildDirectory() -> URL? {
        if let override = ProcessInfo.processInfo
            .environment["BOUNDARY_JIT_BUILD_DIR"] {
            return URL(fileURLWithPath: override)
        }
        var candidate = URL(fileURLWithPath: #filePath)
        while candidate.pathComponents.count > 1 {
            candidate = candidate.deletingLastPathComponent()
            let build = candidate.appendingPathComponent(".build")
            guard FileManager.default.fileExists(atPath: build.path) else {
                continue
            }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: build, includingPropertiesForKeys: nil)) ?? []
            for entry in contents where entry.lastPathComponent.contains("apple") {
                let debug = entry.appendingPathComponent("debug")
                if FileManager.default.fileExists(
                    atPath: debug.appendingPathComponent("Modules")
                        .appendingPathComponent("BoundaryABI.swiftmodule")
                        .path) {
                    return debug
                }
            }
        }
        return nil
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }

    /// Returns a native invoker for this signature, compiling on first use and
    /// reusing the cached dylib afterwards.
    func entry(for signature: HostSignature) throws -> BoundaryEntry {
        let key = signature.declaration
        if let existing = loaded[key] { return existing }
        if rejected.contains(key) {
            throw Failure(description: "previously rejected: \(key)")
        }

        let symbol = "cb_" + Self.digest(key)
        guard let shim = Self.shimSource(for: signature, symbol: symbol) else {
            rejected.insert(key)
            throw Failure(description: "not mechanically expressible: \(key)")
        }
        guard let build = Self.buildDirectory() else {
            rejected.insert(key)
            throw Failure(description: "no build directory for BoundaryABI")
        }

        // The SDK modules BridgeGen sweeps. A receiver type resolves because
        // its module is imported, not because anything here knows the type.
        let source = """
            import BoundaryABI
            import Charts
            import Foundation
            import SwiftUI

            \(shim)
            """
        let name = Self.digest(source)
        let sourceURL = Self.cacheDirectory
            .appendingPathComponent("\(name).swift")
        let dylibURL = Self.cacheDirectory
            .appendingPathComponent("lib\(name).dylib")

        if !FileManager.default.fileExists(atPath: dylibURL.path) {
            try source.write(to: sourceURL, atomically: true, encoding: .utf8)
            let sdk = try Self.run(
                "/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "macosx"])
            let output = try Self.run("/usr/bin/xcrun", [
                "swiftc", "-emit-library", "-O",
                "-o", dylibURL.path,
                "-sdk", sdk,
                "-target", "arm64-apple-macosx15.0",
                "-I", build.appendingPathComponent("Modules").path,
                "-I", build.path,
                // Bind BoundaryCall to the copy ALREADY loaded in the host
                // process instead of linking a second one — two copies of the
                // class would be an ABI hazard, not a shared frame.
                "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
                sourceURL.path,
            ])
            guard FileManager.default.fileExists(atPath: dylibURL.path) else {
                rejected.insert(key)
                throw Failure(
                    description: "compile failed for \(key):\n\(output)")
            }
        }

        guard let handle = dlopen(dylibURL.path, RTLD_NOW) else {
            let message = String(cString: dlerror())
            rejected.insert(key)
            throw Failure(description: "dlopen failed for \(key): \(message)")
        }
        guard let raw = dlsym(handle, symbol) else {
            rejected.insert(key)
            throw Failure(description: "missing symbol \(symbol) for \(key)")
        }
        let entry = unsafeBitCast(raw, to: BoundaryEntry.self)
        loaded[key] = entry
        return entry
    }

    /// The drop-in replacement for a generated overload's `invoke` closure.
    func invoke(
        signature: HostSignature, receiver: Any, arguments: [Any]
    ) throws -> RuntimeValue {
        let entry = try entry(for: signature)
        let call = BoundaryCall(receiver: receiver, arguments: arguments)
        entry(Unmanaged.passUnretained(call).toOpaque())
        if let failure = call.failure {
            throw Failure(description: failure)
        }
        Self.serviced.insert(signature.declaration)
        let returnType = signature.returnType
        if returnType == nil || returnType == "Void" || returnType == "()" {
            return .void
        }
        // `call.result` is `Any?`; handing that to `.native` would select the
        // generic `native<Wrapped>(_: Wrapped?)` overload and wrap every result
        // in a spurious Optional named "Any". Normalize the erased payload
        // instead, which preserves a genuine SDK Optional (`Date?`) correctly.
        guard let result = call.result else { return .nilValue }
        return .nativePreservingOptional(result)
    }

    private static func run(
        _ tool: String, _ arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
