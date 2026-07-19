import Foundation
import SwiftInterpreter

/// The declarative face of `FileManagerBox`'s forwarded file operations.
///
/// One row per member states the box's sandbox-analog semantics — argument
/// lenience, sandbox admission, failure treatment — next to a compiler-checked
/// native kernel. ONE engine builds both execution faces from a row: the
/// confined implementation and the checked physical-worker operation. The two
/// faces share the same prepared kernel and the same result materialization,
/// so they cannot disagree, and no member ever hand-writes concurrency
/// machinery (routing, Sendable checking, fallback) again.
///
/// Interface authority: `FileManager` is ObjC-imported, so it does not appear
/// in the Foundation `swiftinterface` that BridgeGen sweeps. The compiler
/// itself verifies each row against the real SDK surface instead — a kernel
/// that names a nonexistent member, wrong label, or wrong type does not
/// compile — and the native-parity fixtures verify the source-visible labels
/// against the compiled twin. What stays hand-written here is exactly the
/// interface-inexpressible part: the box's per-run sandbox policy.
///
/// Sandbox policy (stated once, applied by rows): throwing filesystem verbs
/// must stay inside the per-run sandbox container; non-throwing queries pass
/// through unrestricted. Lenience outcomes (`.immediate`) reproduce the
/// pre-migration hand behavior and always execute confined.
@MainActor
enum FileServiceOperations {
    /// What `prepare` decided on the owning actor. `run` carries the only
    /// value that may cross a physical-worker boundary: a compiler-checked
    /// `@Sendable` kernel over value snapshots resolved during preparation.
    enum Plan {
        case immediate(RuntimeValue)
        case run(HostWorkerOperation.Body)
    }

    /// `prepare` reads interpreter values, applies lenience, and admits URL
    /// or path arguments against the sandbox. It must be effect-free: the
    /// worker face may decline after preparation and the confined face will
    /// prepare again.
    struct Operation {
        let member: String
        let prepare: @MainActor (CallArguments, FileManagerBox) throws -> Plan
    }

    /// Both faces from one row. The confined face runs the same checked
    /// kernel on the owning actor and materializes through the same worker
    /// snapshot path, so physical and cooperative execution return identical
    /// runtime shapes. `.immediate` lenience declines the worker face; the
    /// ordinary implementation re-prepares and serves it.
    static func hostFunction(named name: String, on box: FileManagerBox) -> HostFunction? {
        guard let operation = table[name] else { return nil }
        return HostFunction(
            name: operation.member,
            invoke: { args, _ in
                switch try operation.prepare(args, box) {
                case .immediate(let value):
                    return value
                case .run(let kernel):
                    return try HostWorkerOperation(kernel)
                        .confinedRuntimeValue()
                }
            },
            workerOperationIfSupported: { args, _ in
                switch try operation.prepare(args, box) {
                case .immediate:
                    return nil
                case .run(let kernel):
                    return HostWorkerOperation(kernel)
                }
            })
    }

    static let table: [String: Operation] = {
        var t: [String: Operation] = [:]
        for operation in all { t[operation.member] = operation }
        return t
    }()

    static let all: [Operation] = [
        Operation(member: "fileExists") { args, _ in
            guard let path = args.labeled("atPath")?.stringValue else {
                return .immediate(.bool(false))
            }
            return .run { .bool(FileManager.default.fileExists(atPath: path)) }
        },
        Operation(member: "removeItem") { args, box in
            let url = urlArgument(args.labeled("at"))
                ?? args.labeled("atPath")?.stringValue.map { URL(fileURLWithPath: $0) }
            guard let url else { throw RuntimeError(message: "removeItem needs a URL") }
            try box.requireSandboxed(url)
            return .run {
                do { try FileManager.default.removeItem(at: url) } catch {
                    throw RuntimeError(message: "removeItem: \(error.localizedDescription)")
                }
                return .void
            }
        },
        Operation(member: "copyItem") { args, box in
            try transferPlan(named: "copyItem", move: false, args, box)
        },
        Operation(member: "moveItem") { args, box in
            try transferPlan(named: "moveItem", move: true, args, box)
        },
        Operation(member: "createDirectory") { args, box in
            let url = urlArgument(args.labeled("at"))
                ?? args.labeled("atPath")?.stringValue.map { URL(fileURLWithPath: $0) }
            guard let url else {
                // An UNKNOWABLE location (a path built from unmerged APIs):
                // creating it is accepted inertly — the fresh sandbox analog,
                // so DB-bootstrap chains don't fatalError where the device
                // succeeds.
                return .immediate(.void)
            }
            try box.requireSandboxed(url)
            return .run {
                try? FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true)
                return .void
            }
        },
        Operation(member: "contentsOfDirectory") { args, box in
            if let url = urlArgument(args.labeled("at")) {
                try box.requireSandboxed(url)
                return .run {
                    let contents = (try? FileManager.default
                        .contentsOfDirectory(
                            at: url, includingPropertiesForKeys: nil)) ?? []
                    return .array(contents.map { .url($0) })
                }
            }
            // The atPath overload returns child NAMES, not URLs — the
            // native shape difference is part of the row (blink,
            // CopilotForXcode, and Pearcleaner cite it).
            if let path = args.labeled("atPath")?.stringValue {
                try box.requireSandboxed(URL(fileURLWithPath: path))
                return .run {
                    let names = (try? FileManager.default
                        .contentsOfDirectory(atPath: path)) ?? []
                    return .array(names.map { .string($0) })
                }
            }
            throw RuntimeError(message: "contentsOfDirectory needs a URL")
        },
    ]

    private static func transferPlan(
        named name: String,
        move: Bool,
        _ args: CallArguments,
        _ box: FileManagerBox
    ) throws -> Plan {
        // ControlRoom and CodeEdit cite the atPath:/toPath: String
        // spellings; both forms merge onto one URL kernel like removeItem.
        let from = urlArgument(args.labeled("at"))
            ?? args.labeled("atPath")?.stringValue
                .map { URL(fileURLWithPath: $0) }
        let to = urlArgument(args.labeled("to"))
            ?? args.labeled("toPath")?.stringValue
                .map { URL(fileURLWithPath: $0) }
        guard let from, let to else {
            // Sources that never materialized (URLSession temp markers)
            // can't be copied — the honest throw lands in the app's own
            // catch.
            throw RuntimeError(message: "\(name) needs source and destination URLs")
        }
        try box.requireSandboxed(to)
        try box.requireSandboxed(from)
        return .run {
            do {
                if move { try FileManager.default.moveItem(at: from, to: to) }
                else { try FileManager.default.copyItem(at: from, to: to) }
            } catch {
                throw RuntimeError(message: "\(name): \(error.localizedDescription)")
            }
            return .void
        }
    }

    private static func urlArgument(_ value: RuntimeValue?) -> URL? {
        guard case .host(let any)? = value else { return nil }
        return any as? URL
    }
}

/// Pure route metadata for the async evaluator's pre-evaluation check. It
/// mirrors `FileServiceOperations` — the service identity and member set are
/// declared once as table data, never as scattered registry branches, and
/// `ParallelFileServiceGatewayTests/routeMetadataMirrorsTheOperationTable`
/// pins the mirror — and stays nonisolated so registry route queries never
/// touch actor state.
nonisolated enum FileServiceRouting {
    static let serviceTypeName = "FileManager"
    static let serviceAccessor = "default"
    static let workerRoutedMembers: Set<String> = [
        "fileExists", "removeItem", "copyItem", "moveItem",
        "createDirectory", "contentsOfDirectory",
    ]
}
