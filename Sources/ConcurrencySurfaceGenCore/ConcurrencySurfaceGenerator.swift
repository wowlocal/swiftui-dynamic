import CryptoKit
import Foundation
import SwiftIfConfig
import SwiftParser
import SwiftSyntax

public enum ConcurrencySurfaceGenerationError: Error,
    CustomStringConvertible, Equatable {
    case commandFailed(String)
    case conditionalCompilationDiagnostics([String])
    case interfaceNotFound(String)
    case missingIntrinsics([String])
    case missingFunctions([String])
    case missingTaskIntrinsics([String])
    case missingTaskInstanceIntrinsics([String])
    case missingNominalMemberIntrinsics([String])
    case missingTaskGroupIteratorIntrinsics([String])

    public var description: String {
        switch self {
        case .commandFailed(let command):
            "command failed: \(command)"
        case .conditionalCompilationDiagnostics(let diagnostics):
            "could not determine active conditional-compilation regions: "
                + diagnostics.joined(separator: "; ")
        case .interfaceNotFound(let root):
            "could not locate _Concurrency.swiftinterface below \(root)"
        case .missingIntrinsics(let names):
            "active _Concurrency.swiftinterface is missing required task-group "
                + "members: \(names.joined(separator: ", "))"
        case .missingFunctions(let names):
            "active _Concurrency.swiftinterface is missing required top-level "
                + "functions: \(names.joined(separator: ", "))"
        case .missingTaskIntrinsics(let names):
            "active _Concurrency.swiftinterface is missing required Task "
                + "members: \(names.joined(separator: ", "))"
        case .missingTaskInstanceIntrinsics(let names):
            "active _Concurrency.swiftinterface is missing required Task "
                + "instance members: \(names.joined(separator: ", "))"
        case .missingNominalMemberIntrinsics(let names):
            "active _Concurrency.swiftinterface is missing required selected "
                + "nominal members: \(names.joined(separator: ", "))"
        case .missingTaskGroupIteratorIntrinsics(let names):
            "active _Concurrency.swiftinterface is missing required task-group "
                + "iterator members: \(names.joined(separator: ", "))"
        }
    }
}
public enum ConcurrencySurfaceDeclarationKind: String, Sendable, Hashable {
    case function
    case variable
}

public enum ConcurrencySurfaceThrowsKind: String, Sendable, Hashable {
    case nonThrowing
    case throwing
    case rethrowing
}

public struct ConcurrencySurfaceParameter: Sendable, Hashable {
    public let label: String?
    public let name: String
    public let type: String
    public let defaultValue: String?
    public let attributes: [String]
    public let modifiers: [String]

    public var isIsolated: Bool {
        modifiers.contains { $0 == "isolated" }
            || type.hasPrefix("isolated ")
    }

    public var inheritsActorContext: Bool {
        attributes.contains {
            $0.hasPrefix("@_inheritActorContext")
        }
    }

    public var hasIsolatedFunctionType: Bool {
        type.contains("@isolated(")
    }

    public var isSendableFunction: Bool {
        type.contains("@Sendable")
    }
}

public struct ConcurrencySurfaceDeclaration: Sendable, Hashable {
    public let declaration: String
    public let kind: ConcurrencySurfaceDeclarationKind
    public let parameters: [ConcurrencySurfaceParameter]
    public let returnType: String?
    public let isAsync: Bool
    public let throwsKind: ConcurrencySurfaceThrowsKind
    public let thrownErrorType: String?
    public let attributes: [String]
    public let modifiers: [String]
    public let globalActor: String?

    public var isThrowing: Bool { throwsKind != .nonThrowing }
    public var isMutating: Bool {
        modifiers.contains { $0 == "mutating" }
    }
    public var isNonisolated: Bool {
        modifiers.contains { $0.hasPrefix("nonisolated") }
    }
}

public struct ConcurrencySurfaceInventory: Sendable, Equatable {
    public let topLevelFunctionDispatch: [String: String]
    public let knownTopLevelFunctions: Set<String>
    public let topLevelFunctionDeclarations:
        [String: [ConcurrencySurfaceDeclaration]]
    public let taskStaticDispatch: [String: String]
    public let knownTaskStaticMembers: Set<String>
    public let taskStaticMemberDeclarations:
        [String: [ConcurrencySurfaceDeclaration]]
    public let taskInstanceDispatch: [String: String]
    public let knownTaskInstanceMembers: Set<String>
    public let taskInstanceMemberDeclarations:
        [String: [ConcurrencySurfaceDeclaration]]
    public let nominalMemberDispatch: [String: [String: String]]
    public let knownNominalMembers: [String: Set<String>]
    public let nominalMemberDeclarations:
        [String: [String: [ConcurrencySurfaceDeclaration]]]
    public let taskGroupDispatch: [String: [String: String]]
    public let knownTaskGroupMembers: [String: Set<String>]
    public let taskGroupMemberDeclarations:
        [String: [String: [ConcurrencySurfaceDeclaration]]]
    public let taskGroupIteratorDispatch: [String: [String: String]]
    public let knownTaskGroupIteratorMembers: [String: Set<String>]
    public let taskGroupIteratorMemberDeclarations:
        [String: [String: [ConcurrencySurfaceDeclaration]]]
}

private struct GeneratedCapabilityInventory: Encodable {
    let schemaVersion: Int
    let kind: String
    let generator: String
    let source: GeneratedCapabilitySource
    let scope: GeneratedCapabilityScope
    let summary: GeneratedCapabilitySummary
    let declarations: [GeneratedCapabilityDeclaration]
}

private struct GeneratedCapabilitySource: Encodable {
    let module: String
    let interface: String
    let interfaceSHA256: String
    let interfaceFormatVersion: String
    let compilerVersion: String
    let targetTriple: String
}

private struct GeneratedCapabilityScope: Encodable {
    let id: String
    let complete: Bool
    let accountingUnit: String
    let included: [String]
    let excluded: [String]
    let adapterRouteIsSupportEvidence: Bool
}

private struct GeneratedCapabilitySummary: Encodable {
    let declarationCount: Int
    let adapterRoutedDeclarationCount: Int
    let declarationsByDomain: [String: Int]
}

private struct GeneratedCapabilityDeclaration: Encodable {
    let id: String
    let domain: String
    let container: String
    let name: String
    let kind: String
    let declaration: String
    let adapterIntrinsic: String?
    let parameters: [GeneratedCapabilityParameter]
    let returnType: String?
    let effects: GeneratedCapabilityEffects
    let isolation: GeneratedCapabilityIsolation
    let attributes: [String]
    let modifiers: [String]
}

private struct GeneratedCapabilityParameter: Encodable {
    let label: String?
    let name: String
    let type: String
    let defaultValue: String?
    let attributes: [String]
    let modifiers: [String]
    let isolated: Bool
    let inheritsActorContext: Bool
    let isolatedFunctionType: Bool
    let sendableFunction: Bool
}

private struct GeneratedCapabilityEffects: Encodable {
    let async: Bool
    let throwsKind: String
    let thrownErrorType: String?
}

private struct GeneratedCapabilityIsolation: Encodable {
    let globalActor: String?
    let mutating: Bool
    let nonisolated: Bool
}

public enum ConcurrencySurfaceGenerator {
    public static let taskGroupTypes = [
        "DiscardingTaskGroup", "TaskGroup", "ThrowingDiscardingTaskGroup",
        "ThrowingTaskGroup",
    ]
    public static let taskGroupIteratorTypes = [
        "TaskGroup", "ThrowingTaskGroup",
    ]

    private static let supportedIntrinsics: Set<String> = [
        "addImmediateTask", "addImmediateTaskUnlessCancelled", "addTask",
        "addTaskUnlessCancelled", "waitForAll", "next", "nextResult",
        "makeAsyncIterator", "cancelAll", "isCancelled", "isEmpty",
    ]
    private static let supportedTaskStaticIntrinsics: Set<String> = [
        "checkCancellation", "currentPriority", "detached", "isCancelled",
        "immediate", "immediateDetached", "name", "sleep", "yield",
    ]
    /// Conditional/availability-gated API may legitimately be absent from an
    /// older active toolchain. Core routes remain a generator invariant; an
    /// optional route is emitted whenever the configured interface exposes it.
    private static let requiredTaskStaticIntrinsics =
        supportedTaskStaticIntrinsics.subtracting([
            "immediate", "immediateDetached",
        ])
    private static let supportedTaskInstanceIntrinsics: Set<String> = [
        "cancel", "isCancelled", "result", "value",
    ]
    /// Selected public nominal families use the same data-driven walker and
    /// generated fail-closed dispatch. Adding another family changes this
    /// declaration map, not parser control flow or hand-authored output code.
    private static let selectedNominalMemberIntrinsics:
        [String: [String: String]] = [
        "MainActor": [
            "run": "mainActorRun",
        ],
        "UnsafeCurrentTask": [
            "==": "currentTaskIdentityEquals",
            "basePriority": "currentTaskBasePriority",
            "cancel": "currentTaskCancel",
            "hashValue": "currentTaskHashValue",
            "isCancelled": "currentTaskIsCancelled",
            "priority": "currentTaskPriority",
        ],
    ]
    private static let optionalNominalMemberIntrinsics: Set<String> = [
        "currentTaskBasePriority",
    ]
    private static let supportedTaskGroupIteratorIntrinsics: Set<String> = [
        "cancel", "next",
    ]

    /// Answers conditional-compilation questions with the compiler that will
    /// consume the interface. The interface emitter's version is metadata,
    /// but `$Feature`, `hasFeature`, target, and import checks are properties
    /// of the active consumer compiler and its module flags.
    private final class ActiveCompilerBuildConfiguration: BuildConfiguration {
        let languageVersion: VersionTuple
        let compilerVersion: VersionTuple
        let targetPointerBitWidth: Int
        let targetAtomicBitWidths: [Int]
        let endianness: Endianness

        private let compilerArguments: [String]
        private var conditionCache: [String: Bool] = [:]

        init(interfaceSource: String) throws {
            let moduleFlags = ConcurrencySurfaceGenerator.interfaceHeaderValue(
                "swift-module-flags", in: interfaceSource)
                .split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let consumerVersion = try ConcurrencySurfaceGenerator.command(
                "/usr/bin/xcrun", ["swiftc", "--version"])
            guard let compilerVersion = Self.version(
                matching: #"(?:Apple )?Swift version ([0-9]+(?:\.[0-9]+)*)"#,
                in: consumerVersion)
            else {
                throw ConcurrencySurfaceGenerationError.commandFailed(
                    "could not parse xcrun swiftc --version: "
                        + consumerVersion)
            }
            self.compilerVersion = compilerVersion

            let swiftMode = Self.value(after: "-swift-version", in: moduleFlags)
                ?? "5"
            let emitterDescription =
                ConcurrencySurfaceGenerator.interfaceHeaderValue(
                    "swift-compiler-version", in: interfaceSource)
            self.languageVersion = Self.version(
                matching: #"effective-([0-9]+(?:\.[0-9]+)*)"#,
                in: emitterDescription)
                ?? VersionTuple(parsing: swiftMode)
                ?? VersionTuple(5)

            let target = Self.value(after: "-target", in: moduleFlags) ?? ""
            let architecture = target.split(separator: "-").first.map(String.init)
                ?? ""
            self.targetPointerBitWidth = [
                "arm64", "arm64e", "x86_64", "powerpc64", "s390x",
            ].contains(architecture) ? 64 : 32
            self.targetAtomicBitWidths = targetPointerBitWidth == 64
                ? [8, 16, 32, 64, 128] : [8, 16, 32, 64]
            self.endianness = ["powerpc", "powerpc64", "s390x"]
                .contains(architecture) ? .big : .little

            var arguments = [
                "swiftc", "-frontend", "-typecheck", "-dump-ast",
            ]
            let pairedFlags = Set([
                "-D", "-disable-upcoming-feature",
                "-enable-experimental-feature", "-enable-upcoming-feature",
                "-swift-version", "-target", "-target-variant",
            ])
            var index = moduleFlags.startIndex
            while index < moduleFlags.endIndex {
                let flag = moduleFlags[index]
                if pairedFlags.contains(flag),
                   moduleFlags.indices.contains(index + 1) {
                    arguments.append(flag)
                    arguments.append(moduleFlags[index + 1])
                    index += 2
                    continue
                }
                if [
                    "-disable-objc-interop", "-enable-objc-interop",
                    "-parse-stdlib",
                ].contains(flag) {
                    arguments.append(flag)
                }
                index += 1
            }
            let sdk = try ConcurrencySurfaceGenerator.command(
                "/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "macosx"])
            arguments.append(contentsOf: ["-sdk", sdk, "-"])
            self.compilerArguments = arguments
        }

        func isCustomConditionSet(name: String) throws -> Bool {
            try evaluate(name)
        }

        func hasFeature(name: String) throws -> Bool {
            try evaluate("hasFeature(\(name))")
        }

        func hasAttribute(name: String) throws -> Bool {
            try evaluate("hasAttribute(\(name))")
        }

        func canImport(
            importPath: [(TokenSyntax, String)],
            version: CanImportVersion
        ) throws -> Bool {
            let path = importPath.map(\.1).joined(separator: ".")
            let suffix: String
            switch version {
            case .unversioned:
                suffix = ""
            case .version(let version):
                suffix = ", _version: \(version)"
            case .underlyingVersion(let version):
                suffix = ", _underlyingVersion: \(version)"
            }
            return try evaluate("canImport(\(path)\(suffix))")
        }

        func isActiveTargetOS(name: String) throws -> Bool {
            try evaluate("os(\(name))")
        }

        func isActiveTargetArchitecture(name: String) throws -> Bool {
            try evaluate("arch(\(name))")
        }

        func isActiveTargetEnvironment(name: String) throws -> Bool {
            try evaluate("targetEnvironment(\(name))")
        }

        func isActiveTargetRuntime(name: String) throws -> Bool {
            try evaluate("_runtime(\(name))")
        }

        func isActiveTargetPointerAuthentication(name: String) throws -> Bool {
            try evaluate("_ptrauth(\(name))")
        }

        func isActiveTargetObjectFormat(name: String) throws -> Bool {
            try evaluate("objectFormat(\(name))")
        }

        private func evaluate(_ condition: String) throws -> Bool {
            if let cached = conditionCache[condition] { return cached }
            let marker = "__ConcurrencySurfaceConditionalProbe"
            let source = """
                #if \(condition)
                struct \(marker) {}
                #endif
                """
            let output = try Self.compilerOutput(
                arguments: compilerArguments, source: source)
            let active = output.contains("\"\(marker)\"")
            conditionCache[condition] = active
            return active
        }

        private static func compilerOutput(
            arguments: [String], source: String
        ) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            try process.run()
            input.fileHandleForWriting.write(Data(source.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = error.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ConcurrencySurfaceGenerationError.commandFailed(
                    (["/usr/bin/xcrun"] + arguments).joined(separator: " ")
                        + (detail.isEmpty ? "" : ": \(detail)"))
            }
            return String(decoding: stdout, as: UTF8.self)
        }

        private static func value(
            after flag: String, in arguments: [String]
        ) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        private static func version(
            matching pattern: String, in text: String
        ) -> VersionTuple? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return VersionTuple(parsing: String(text[range]))
        }
    }
    /// Maps interface-owned source names onto reusable runtime semantics.
    /// Several deprecated spellings can deliberately share one intrinsic;
    /// generated dispatch must not turn each spelling into a new runtime path.
    private static let supportedTopLevelFunctionIntrinsics: [String: String] = [
        "_isolatedParameter_withTaskPriorityEscalationHandler":
            "withTaskPriorityEscalationHandler",
        "async": "unstructuredTask",
        "asyncDetached": "detachedTask",
        "detach": "detachedTask",
        "extractIsolation": "extractIsolation",
        "withDiscardingTaskGroup": "withDiscardingTaskGroup",
        "withTaskCancellationHandler": "withTaskCancellationHandler",
        "withTaskExecutorPreference": "withTaskExecutorPreference",
        "withTaskGroup": "withTaskGroup",
        "withTaskPriorityEscalationHandler":
            "withTaskPriorityEscalationHandler",
        "withThrowingDiscardingTaskGroup":
            "withThrowingDiscardingTaskGroup",
        "withThrowingTaskGroup": "withThrowingTaskGroup",
        "withUnsafeCurrentTask": "withCurrentTaskCapability",
    ]
    private static let requiredContinuationFunctionNames: Set<String> = [
        "withCheckedContinuation",
        "withCheckedThrowingContinuation",
        "withUnsafeContinuation",
        "withUnsafeThrowingContinuation",
    ]
    /// SDK-gated declarations may be absent when this package is generated by
    /// an older toolchain. When present they still receive the canonical
    /// intrinsic and participate in the generated capability inventory.
    private static let optionalTopLevelFunctionIntrinsicNames: Set<String> = [
        "_isolatedParameter_withTaskPriorityEscalationHandler",
        "withTaskPriorityEscalationHandler",
    ]
    private static let requiredIntrinsicsByType: [String: Set<String>] = [
        "DiscardingTaskGroup": [
            "addImmediateTask", "addImmediateTaskUnlessCancelled", "addTask",
            "addTaskUnlessCancelled", "cancelAll", "isCancelled", "isEmpty",
        ],
        "TaskGroup": supportedIntrinsics.subtracting(["nextResult"]),
        "ThrowingDiscardingTaskGroup": [
            "addImmediateTask", "addImmediateTaskUnlessCancelled", "addTask",
            "addTaskUnlessCancelled", "cancelAll", "isCancelled", "isEmpty",
        ],
        "ThrowingTaskGroup": supportedIntrinsics,
    ]
    public static func activeInterfacePath() throws -> String {
        let sdk = try command(
            "/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "macosx"])
        let architecture = try command("/usr/bin/uname", ["-m"])
        let directory = sdk + "/usr/lib/swift/_Concurrency.swiftmodule"
        let candidates = try FileManager.default.contentsOfDirectory(
            atPath: directory
        ).filter {
            $0.hasSuffix("-apple-macos.swiftinterface")
        }.sorted()
        let prefix = architecture == "arm64" ? "arm64" : architecture
        guard let file = candidates.first(where: { $0.hasPrefix(prefix) })
                ?? candidates.first else {
            throw ConcurrencySurfaceGenerationError.interfaceNotFound(directory)
        }
        return directory + "/" + file
    }

    public static func inventory(
        interfaceSource: String
    ) throws -> ConcurrencySurfaceInventory {
        try inventory(
            interfaceSource: interfaceSource,
            configuration: ActiveCompilerBuildConfiguration(
                interfaceSource: interfaceSource))
    }

    /// Inventories only declarations selected by the supplied compiler build
    /// configuration. Keeping this overload injectable makes branch selection
    /// deterministic in tests while production delegates every atomic `#if`
    /// query to the active Swift compiler.
    public static func inventory(
        interfaceSource: String,
        configuration: some BuildConfiguration
    ) throws -> ConcurrencySurfaceInventory {
        let parsed = Parser.parse(source: interfaceSource)
        let configured = parsed.removingInactive(in: configuration)
        guard configured.diagnostics.isEmpty else {
            throw ConcurrencySurfaceGenerationError
                .conditionalCompilationDiagnostics(
                    configured.diagnostics.map(\.debugDescription))
        }
        guard let syntax = configured.result.as(SourceFileSyntax.self) else {
            throw ConcurrencySurfaceGenerationError
                .conditionalCompilationDiagnostics([
                    "configured syntax root is not a source file",
                ])
        }
        let taskGroupTypeSet = Set(taskGroupTypes)
        let taskGroupIteratorTypeSet = Set(taskGroupIteratorTypes)
        let globalActorNames = globalActors(in: syntax)
        var knownNames = Dictionary(uniqueKeysWithValues:
            taskGroupTypes.map { ($0, Set<String>()) })
        var dispatch = Dictionary(uniqueKeysWithValues:
            taskGroupTypes.map { ($0, [String: String]()) })
        var memberDeclarations = Dictionary(uniqueKeysWithValues:
            taskGroupTypes.map {
                ($0, [String: [ConcurrencySurfaceDeclaration]]())
            })
        var knownIteratorNames = Dictionary(uniqueKeysWithValues:
            taskGroupIteratorTypes.map { ($0, Set<String>()) })
        var iteratorDispatch = Dictionary(uniqueKeysWithValues:
            taskGroupIteratorTypes.map { ($0, [String: String]()) })
        var iteratorMemberDeclarations = Dictionary(uniqueKeysWithValues:
            taskGroupIteratorTypes.map {
                ($0, [String: [ConcurrencySurfaceDeclaration]]())
            })
        var knownTopLevelFunctions: Set<String> = []
        var topLevelFunctionDispatch: [String: String] = [:]
        var topLevelFunctionDeclarations:
            [String: [ConcurrencySurfaceDeclaration]] = [:]
        var knownTaskStaticMembers: Set<String> = []
        var taskStaticDispatch: [String: String] = [:]
        var taskStaticMemberDeclarations:
            [String: [ConcurrencySurfaceDeclaration]] = [:]
        var knownTaskInstanceMembers: Set<String> = []
        var taskInstanceDispatch: [String: String] = [:]
        var taskInstanceMemberDeclarations:
            [String: [ConcurrencySurfaceDeclaration]] = [:]
        var nominalMemberDispatch = Dictionary(uniqueKeysWithValues:
            selectedNominalMemberIntrinsics.keys.map { ($0, [String: String]()) })
        var knownNominalMembers = Dictionary(uniqueKeysWithValues:
            selectedNominalMemberIntrinsics.keys.map { ($0, Set<String>()) })
        var nominalMemberDeclarations = Dictionary(uniqueKeysWithValues:
            selectedNominalMemberIntrinsics.keys.map {
                ($0, [String: [ConcurrencySurfaceDeclaration]]())
            })

        for statement in syntax.statements {
            guard case .decl(let declaration) = statement.item else { continue }
            if let function = declaration.as(FunctionDeclSyntax.self),
               isPublic(function.modifiers) {
                let name = function.name.text
                knownTopLevelFunctions.insert(name)
                let metadata = declarationMetadata(
                    function, globalActorNames: globalActorNames)
                appendUnique(
                    metadata,
                    to: &topLevelFunctionDeclarations[name, default: []])
                if let intrinsic = continuationIntrinsic(for: metadata)
                        ?? supportedTopLevelFunctionIntrinsics[name] {
                    topLevelFunctionDispatch[name] = intrinsic
                }
                continue
            }

            let typeName: String?
            let members: MemberBlockItemListSyntax?
            if let structure = declaration.as(StructDeclSyntax.self) {
                typeName = structure.name.text
                members = structure.memberBlock.members
            } else if let actor = declaration.as(ActorDeclSyntax.self) {
                typeName = actor.name.text
                members = actor.memberBlock.members
            } else if let extensionDeclaration = declaration.as(
                ExtensionDeclSyntax.self
            ) {
                let extendedType = normalizedTypeName(
                    extensionDeclaration.extendedType.trimmedDescription)
                typeName = extendedType
                members = extensionDeclaration.memberBlock.members
            } else {
                typeName = nil
                members = nil
            }
            guard let typeName, let members else { continue }
            if typeName == "Task" {
                inspectTaskMembers(
                    members,
                    globalActorNames: globalActorNames,
                    knownStaticNames: &knownTaskStaticMembers,
                    staticDispatch: &taskStaticDispatch,
                    staticDeclarations: &taskStaticMemberDeclarations,
                    knownInstanceNames: &knownTaskInstanceMembers,
                    instanceDispatch: &taskInstanceDispatch,
                    instanceDeclarations: &taskInstanceMemberDeclarations)
                continue
            }
            if let intrinsicMap = selectedNominalMemberIntrinsics[typeName] {
                inspectNominalMembers(
                    members,
                    globalActorNames: globalActorNames,
                    intrinsicMap: intrinsicMap,
                    knownNames: &knownNominalMembers[typeName, default: []],
                    dispatch: &nominalMemberDispatch[typeName, default: [:]],
                    declarations:
                        &nominalMemberDeclarations[typeName, default: [:]])
                continue
            }
            guard taskGroupTypeSet.contains(typeName) else { continue }
            inspect(
                members,
                globalActorNames: globalActorNames,
                knownNames: &knownNames[typeName, default: []],
                dispatch: &dispatch[typeName, default: [:]],
                declarations: &memberDeclarations[typeName, default: [:]])
            if taskGroupIteratorTypeSet.contains(typeName) {
                inspectNestedTaskGroupIterator(
                    members,
                    globalActorNames: globalActorNames,
                    knownNames: &knownIteratorNames[typeName, default: []],
                    dispatch: &iteratorDispatch[typeName, default: [:]],
                    declarations:
                    &iteratorMemberDeclarations[typeName, default: [:]])
            }
        }

        var missingMembers: [String] = []
        for typeName in taskGroupTypes {
            let implemented = Set(dispatch[typeName, default: [:]].values)
            let required = requiredIntrinsicsByType[typeName, default: []]
            missingMembers.append(contentsOf: required.subtracting(implemented)
                .sorted().map { "\(typeName).\($0)" })
        }
        guard missingMembers.isEmpty else {
            throw ConcurrencySurfaceGenerationError.missingIntrinsics(
                missingMembers)
        }
        let requiredFunctionNames = Set(supportedTopLevelFunctionIntrinsics.keys)
            .union(requiredContinuationFunctionNames)
        let missingFunctions = requiredFunctionNames
            .subtracting(optionalTopLevelFunctionIntrinsicNames)
            .subtracting(topLevelFunctionDispatch.keys).sorted()
        guard missingFunctions.isEmpty else {
            throw ConcurrencySurfaceGenerationError.missingFunctions(
                missingFunctions)
        }
        let missingTaskIntrinsics = requiredTaskStaticIntrinsics
            .subtracting(taskStaticDispatch.values).sorted()
        guard missingTaskIntrinsics.isEmpty else {
            throw ConcurrencySurfaceGenerationError.missingTaskIntrinsics(
                missingTaskIntrinsics)
        }
        let missingTaskInstanceIntrinsics = supportedTaskInstanceIntrinsics
            .subtracting(taskInstanceDispatch.values).sorted()
        guard missingTaskInstanceIntrinsics.isEmpty else {
            throw ConcurrencySurfaceGenerationError
                .missingTaskInstanceIntrinsics(missingTaskInstanceIntrinsics)
        }
        var missingNominalMemberIntrinsics: [String] = []
        for typeName in selectedNominalMemberIntrinsics.keys.sorted() {
            let expected = Set(selectedNominalMemberIntrinsics[
                typeName, default: [:]].values)
                .subtracting(optionalNominalMemberIntrinsics)
            let implemented = Set(
                nominalMemberDispatch[typeName, default: [:]].values)
            missingNominalMemberIntrinsics.append(contentsOf:
                expected.subtracting(implemented).sorted().map {
                    "\(typeName).\($0)"
                })
            if knownNominalMembers[typeName, default: []].isEmpty {
                missingNominalMemberIntrinsics.append(typeName + ".<type>")
            }
        }
        guard missingNominalMemberIntrinsics.isEmpty else {
            throw ConcurrencySurfaceGenerationError
                .missingNominalMemberIntrinsics(
                    missingNominalMemberIntrinsics.sorted())
        }
        var missingTaskGroupIteratorIntrinsics: [String] = []
        for typeName in taskGroupIteratorTypes {
            let implemented = Set(
                iteratorDispatch[typeName, default: [:]].values)
            missingTaskGroupIteratorIntrinsics.append(contentsOf:
                supportedTaskGroupIteratorIntrinsics
                    .subtracting(implemented).sorted().map {
                        "\(typeName).Iterator.\($0)"
                    })
        }
        guard missingTaskGroupIteratorIntrinsics.isEmpty else {
            throw ConcurrencySurfaceGenerationError
                .missingTaskGroupIteratorIntrinsics(
                    missingTaskGroupIteratorIntrinsics)
        }

        for typeName in taskGroupTypes {
            for member in memberDeclarations[typeName, default: [:]].keys {
                memberDeclarations[typeName]?[member]?.sort {
                    $0.declaration < $1.declaration
                }
            }
        }
        for typeName in taskGroupIteratorTypes {
            for member in iteratorMemberDeclarations[
                typeName, default: [:]
            ].keys {
                iteratorMemberDeclarations[typeName]?[member]?.sort {
                    $0.declaration < $1.declaration
                }
            }
        }
        for name in topLevelFunctionDeclarations.keys {
            topLevelFunctionDeclarations[name]?.sort {
                $0.declaration < $1.declaration
            }
        }
        for name in taskStaticMemberDeclarations.keys {
            taskStaticMemberDeclarations[name]?.sort {
                $0.declaration < $1.declaration
            }
        }
        for name in taskInstanceMemberDeclarations.keys {
            taskInstanceMemberDeclarations[name]?.sort {
                $0.declaration < $1.declaration
            }
        }
        for typeName in nominalMemberDeclarations.keys {
            for name in nominalMemberDeclarations[typeName, default: [:]].keys {
                nominalMemberDeclarations[typeName]?[name]?.sort {
                    $0.declaration < $1.declaration
                }
            }
        }
        return ConcurrencySurfaceInventory(
            topLevelFunctionDispatch: topLevelFunctionDispatch,
            knownTopLevelFunctions: knownTopLevelFunctions,
            topLevelFunctionDeclarations: topLevelFunctionDeclarations,
            taskStaticDispatch: taskStaticDispatch,
            knownTaskStaticMembers: knownTaskStaticMembers,
            taskStaticMemberDeclarations: taskStaticMemberDeclarations,
            taskInstanceDispatch: taskInstanceDispatch,
            knownTaskInstanceMembers: knownTaskInstanceMembers,
            taskInstanceMemberDeclarations: taskInstanceMemberDeclarations,
            nominalMemberDispatch: nominalMemberDispatch,
            knownNominalMembers: knownNominalMembers,
            nominalMemberDeclarations: nominalMemberDeclarations,
            taskGroupDispatch: dispatch,
            knownTaskGroupMembers: knownNames,
            taskGroupMemberDeclarations: memberDeclarations,
            taskGroupIteratorDispatch: iteratorDispatch,
            knownTaskGroupIteratorMembers: knownIteratorNames,
            taskGroupIteratorMemberDeclarations: iteratorMemberDeclarations)
    }

    /// Continuation entry points are selected by their interface shape rather
    /// than by one branch per source spelling. Checked and unsafe carriers use
    /// distinct ownership policies; the declaration's throwing effect remains
    /// available to the runtime through generated metadata.
    private static func continuationIntrinsic(
        for declaration: ConcurrencySurfaceDeclaration
    ) -> String? {
        guard declaration.isAsync,
              let isolation = declaration.parameters.first,
              isolation.label == "isolation",
              isolation.isIsolated,
              isolation.defaultValue == "#isolation",
              let body = declaration.parameters.last,
              body.type.hasSuffix("-> Swift.Void")
                || body.type.hasSuffix("-> Void") else { return nil }
        if body.type.contains("CheckedContinuation<") {
            return declaration.isThrowing
                ? "withCheckedThrowingContinuation"
                : "withCheckedContinuation"
        }
        if body.type.contains("UnsafeContinuation<") {
            return "unsafeContinuation"
        }
        return nil
    }

    public static func generatedSource(
        interfacePath: String,
        interfaceSource: String
    ) throws -> String {
        let inventory = try inventory(interfaceSource: interfaceSource)
        let topLevelFunctionDispatchLines = inventory
            .topLevelFunctionDispatch.keys.sorted().map { sourceName in
                "        \"\(escaped(sourceName))\": ."
                    + "\(inventory.topLevelFunctionDispatch[sourceName]!),"
            }.joined(separator: "\n")
        let topLevelFunctionIntrinsicCaseLines =
            Set(inventory.topLevelFunctionDispatch.values).sorted()
                .map { "    case \($0)" }.joined(separator: "\n")
        let topLevelFunctionKnownLines = inventory.knownTopLevelFunctions
            .sorted().map { "        \"\(escaped($0))\"," }
            .joined(separator: "\n")
        let topLevelFunctionDeclarationLines = inventory
            .topLevelFunctionDeclarations.keys.sorted().map { name in
                let declarations = inventory.topLevelFunctionDeclarations[
                    name, default: []].map {
                        "            \(render($0)),"
                    }.joined(separator: "\n")
                return "        \"\(escaped(name))\": [\n"
                    + declarations + "\n        ],"
            }.joined(separator: "\n")
        let taskStaticDispatchLines = inventory.taskStaticDispatch.keys
            .sorted().map { sourceName in
                "        \"\(escaped(sourceName))\": ."
                    + "\(inventory.taskStaticDispatch[sourceName]!),"
            }.joined(separator: "\n")
        let taskStaticIntrinsicCaseLines = supportedTaskStaticIntrinsics
            .sorted().map { "    case \($0)" }.joined(separator: "\n")
        let taskStaticKnownLines = inventory.knownTaskStaticMembers.sorted()
            .map { "        \"\(escaped($0))\"," }
            .joined(separator: "\n")
        let taskStaticDeclarationLines = inventory
            .taskStaticMemberDeclarations.keys.sorted().map { memberName in
                let declarations = inventory.taskStaticMemberDeclarations[
                    memberName, default: []].map {
                        "            \(render($0)),"
                    }.joined(separator: "\n")
                return "        \"\(escaped(memberName))\": [\n"
                    + declarations + "\n        ],"
            }.joined(separator: "\n")
        let taskInstanceDispatchLines = inventory.taskInstanceDispatch.keys
            .sorted().map { sourceName in
                "        \"\(escaped(sourceName))\": ."
                    + "\(inventory.taskInstanceDispatch[sourceName]!),"
            }.joined(separator: "\n")
        let taskInstanceIntrinsicCaseLines = supportedTaskInstanceIntrinsics
            .sorted().map { "    case \($0)" }.joined(separator: "\n")
        let taskInstanceKnownLines = inventory.knownTaskInstanceMembers.sorted()
            .map { "        \"\(escaped($0))\"," }
            .joined(separator: "\n")
        let taskInstanceDeclarationLines = inventory
            .taskInstanceMemberDeclarations.keys.sorted().map { memberName in
                let declarations = inventory.taskInstanceMemberDeclarations[
                    memberName, default: []].map {
                        "            \(render($0)),"
                    }.joined(separator: "\n")
                return "        \"\(escaped(memberName))\": [\n"
                    + declarations + "\n        ],"
            }.joined(separator: "\n")
        let nominalMemberIntrinsicCaseLines = Set(
            selectedNominalMemberIntrinsics.values.flatMap(\.values)
        ).sorted().map { "    case \($0)" }.joined(separator: "\n")
        let nominalMemberDispatchBlocks = selectedNominalMemberIntrinsics
            .keys.sorted().map { typeName in
                let entries = inventory.nominalMemberDispatch[
                    typeName, default: [:]]
                let lines = entries.keys.sorted().map { sourceName in
                    "            \"\(escaped(sourceName))\": ."
                        + "\(entries[sourceName]!),"
                }.joined(separator: "\n")
                return "        \"\(escaped(typeName))\": [\n\(lines)\n        ],"
            }.joined(separator: "\n")
        let nominalMemberKnownBlocks = selectedNominalMemberIntrinsics.keys
            .sorted().map { typeName in
                let lines = inventory.knownNominalMembers[
                    typeName, default: []].sorted().map {
                        "            \"\(escaped($0))\","
                    }.joined(separator: "\n")
                return "        \"\(escaped(typeName))\": [\n\(lines)\n        ],"
            }.joined(separator: "\n")
        let nominalMemberDeclarationBlocks = selectedNominalMemberIntrinsics
            .keys.sorted().map { typeName in
                let members = inventory.nominalMemberDeclarations[
                    typeName, default: [:]]
                let lines = members.keys.sorted().map { memberName in
                    let declarations = members[memberName, default: []].map {
                        "                \(render($0)),"
                    }.joined(separator: "\n")
                    return "            \"\(escaped(memberName))\": [\n"
                        + declarations + "\n            ],"
                }.joined(separator: "\n")
                return "        \"\(escaped(typeName))\": [\n\(lines)\n        ],"
            }.joined(separator: "\n")
        let dispatchBlocks = taskGroupTypes.map { typeName in
            let entries = inventory.taskGroupDispatch[typeName, default: [:]]
            let lines = entries.keys.sorted().map { sourceName in
                "            \"\(escaped(sourceName))\": ."
                    + "\(entries[sourceName]!),"
            }.joined(separator: "\n")
            return "        \"\(typeName)\": [\n\(lines)\n        ],"
        }.joined(separator: "\n")
        let knownBlocks = taskGroupTypes.map { typeName in
            let lines = inventory.knownTaskGroupMembers[
                typeName, default: []
            ].sorted().map {
                "            \"\(escaped($0))\","
            }.joined(separator: "\n")
            return "        \"\(typeName)\": [\n\(lines)\n        ],"
        }.joined(separator: "\n")
        let memberDeclarationBlocks = taskGroupTypes.map { typeName in
            let members = inventory.taskGroupMemberDeclarations[
                typeName, default: [:]]
            let memberLines = members.keys.sorted().map { memberName in
                let declarations = members[memberName, default: []].map {
                    "                \(render($0)),"
                }.joined(separator: "\n")
                return "            \"\(escaped(memberName))\": [\n"
                    + declarations + "\n            ],"
            }.joined(separator: "\n")
            return "        \"\(typeName)\": [\n\(memberLines)\n        ],"
        }.joined(separator: "\n")
        let iteratorIntrinsicCaseLines =
            supportedTaskGroupIteratorIntrinsics.sorted()
                .map { "    case \($0)" }.joined(separator: "\n")
        let iteratorDispatchBlocks = taskGroupIteratorTypes.map { typeName in
            let entries = inventory.taskGroupIteratorDispatch[
                typeName, default: [:]]
            let lines = entries.keys.sorted().map { sourceName in
                "            \"\(escaped(sourceName))\": ."
                    + "\(entries[sourceName]!),"
            }.joined(separator: "\n")
            return "        \"\(typeName)\": [\n\(lines)\n        ],"
        }.joined(separator: "\n")
        let iteratorKnownBlocks = taskGroupIteratorTypes.map { typeName in
            let lines = inventory.knownTaskGroupIteratorMembers[
                typeName, default: []
            ].sorted().map {
                "            \"\(escaped($0))\","
            }.joined(separator: "\n")
            return "        \"\(typeName)\": [\n\(lines)\n        ],"
        }.joined(separator: "\n")
        let iteratorDeclarationBlocks = taskGroupIteratorTypes.map { typeName in
            let members = inventory.taskGroupIteratorMemberDeclarations[
                typeName, default: [:]]
            let memberLines = members.keys.sorted().map { memberName in
                let declarations = members[memberName, default: []].map {
                    "                \(render($0)),"
                }.joined(separator: "\n")
                return "            \"\(escaped(memberName))\": [\n"
                    + declarations + "\n            ],"
            }.joined(separator: "\n")
            return "        \"\(typeName)\": [\n\(memberLines)\n        ],"
        }.joined(separator: "\n")
        let compilerVersion = interfaceSource.split(separator: "\n").first {
            $0.hasPrefix("// swift-compiler-version:")
        }.map(String.init) ?? "// swift-compiler-version: unknown"

        return """
        // GENERATED by ConcurrencySurfaceGen from the active _Concurrency.swiftinterface.
        // Do not edit. Regenerate: swift run ConcurrencySurfaceGen
        // Source: \(portableInterfaceLabel(interfacePath))
        \(compilerVersion)

        enum RuntimeConcurrencyFunctionIntrinsic: String, Sendable {
        \(topLevelFunctionIntrinsicCaseLines)
        }

        enum RuntimeTaskStaticIntrinsic: String, Sendable {
        \(taskStaticIntrinsicCaseLines)
        }

        enum RuntimeTaskInstanceIntrinsic: String, Sendable {
        \(taskInstanceIntrinsicCaseLines)
        }

        enum RuntimeConcurrencyNominalMemberIntrinsic: String, Sendable {
        \(nominalMemberIntrinsicCaseLines)
        }

        enum RuntimeTaskGroupIteratorIntrinsic: String, Sendable {
        \(iteratorIntrinsicCaseLines)
        }

        enum RuntimeTaskGroupIntrinsic: String, Sendable {
            case addImmediateTask
            case addImmediateTaskUnlessCancelled
            case addTask
            case addTaskUnlessCancelled
            case waitForAll
            case next
            case nextResult
            case makeAsyncIterator
            case cancelAll
            case isCancelled
            case isEmpty
        }

        enum GeneratedConcurrencyDeclarationKind: String, Sendable {
            case function
            case variable
        }

        enum GeneratedConcurrencyThrowsKind: String, Sendable {
            case nonThrowing
            case throwing
            case rethrowing
        }

        struct GeneratedConcurrencyParameter: Sendable {
            let label: String?
            let name: String
            let type: String
            let defaultValue: String?
            let attributes: [String]
            let modifiers: [String]

            var isIsolated: Bool {
                modifiers.contains("isolated") || type.hasPrefix("isolated ")
            }
            var inheritsActorContext: Bool {
                attributes.contains { $0.hasPrefix("@_inheritActorContext") }
            }
            var hasIsolatedFunctionType: Bool { type.contains("@isolated(") }
            var isSendableFunction: Bool { type.contains("@Sendable") }
        }

        struct GeneratedConcurrencyDeclaration: Sendable {
            let declaration: String
            let kind: GeneratedConcurrencyDeclarationKind
            let parameters: [GeneratedConcurrencyParameter]
            let returnType: String?
            let isAsync: Bool
            let throwsKind: GeneratedConcurrencyThrowsKind
            let thrownErrorType: String?
            let attributes: [String]
            let modifiers: [String]
            let globalActor: String?

            var isThrowing: Bool { throwsKind != .nonThrowing }
            var isMutating: Bool { modifiers.contains("mutating") }
            var isNonisolated: Bool {
                modifiers.contains { $0.hasPrefix("nonisolated") }
            }
        }

        enum GeneratedConcurrencySurface {
            static let topLevelFunctionDispatch: [
                String: RuntimeConcurrencyFunctionIntrinsic
            ] = [
        \(topLevelFunctionDispatchLines)
            ]

            static let knownTopLevelFunctions: Set<String> = [
        \(topLevelFunctionKnownLines)
            ]

            static let topLevelFunctionDeclarations: [
                String: [GeneratedConcurrencyDeclaration]
            ] = [
        \(topLevelFunctionDeclarationLines)
            ]

            static let taskStaticDispatch: [
                String: RuntimeTaskStaticIntrinsic
            ] = [
        \(taskStaticDispatchLines)
            ]

            static let knownTaskStaticMembers: Set<String> = [
        \(taskStaticKnownLines)
            ]

            static let taskStaticMemberDeclarations: [
                String: [GeneratedConcurrencyDeclaration]
            ] = [
        \(taskStaticDeclarationLines)
            ]

            static let taskInstanceDispatch: [
                String: RuntimeTaskInstanceIntrinsic
            ] = [
        \(taskInstanceDispatchLines)
            ]

            static let knownTaskInstanceMembers: Set<String> = [
        \(taskInstanceKnownLines)
            ]

            static let taskInstanceMemberDeclarations: [
                String: [GeneratedConcurrencyDeclaration]
            ] = [
        \(taskInstanceDeclarationLines)
            ]

            static let nominalMemberDispatch: [
                String: [String: RuntimeConcurrencyNominalMemberIntrinsic]
            ] = [
        \(nominalMemberDispatchBlocks)
            ]

            static let knownNominalMembers: [String: Set<String>] = [
        \(nominalMemberKnownBlocks)
            ]

            static let nominalMemberDeclarations: [
                String: [String: [GeneratedConcurrencyDeclaration]]
            ] = [
        \(nominalMemberDeclarationBlocks)
            ]

            static let taskGroupDispatch: [
                String: [String: RuntimeTaskGroupIntrinsic]
            ] = [
        \(dispatchBlocks)
            ]

            static let knownTaskGroupMembers: [String: Set<String>] = [
        \(knownBlocks)
            ]

            static let taskGroupMemberDeclarations: [
                String: [String: [GeneratedConcurrencyDeclaration]]
            ] = [
        \(memberDeclarationBlocks)
            ]

            static let taskGroupIteratorDispatch: [
                String: [String: RuntimeTaskGroupIteratorIntrinsic]
            ] = [
        \(iteratorDispatchBlocks)
            ]

            static let knownTaskGroupIteratorMembers: [String: Set<String>] = [
        \(iteratorKnownBlocks)
            ]

            static let taskGroupIteratorMemberDeclarations: [
                String: [String: [GeneratedConcurrencyDeclaration]]
            ] = [
        \(iteratorDeclarationBlocks)
            ]

            static func intrinsic(
                typeName: String, memberName: String
            ) -> RuntimeTaskGroupIntrinsic? {
                taskGroupDispatch[typeName]?[memberName]
            }

            static func taskGroupIteratorIntrinsic(
                typeName: String, memberName: String
            ) -> RuntimeTaskGroupIteratorIntrinsic? {
                taskGroupIteratorDispatch[typeName]?[memberName]
            }

            static func knowsTaskGroupIteratorMember(
                typeName: String, memberName: String
            ) -> Bool {
                knownTaskGroupIteratorMembers[typeName]?
                    .contains(memberName) == true
            }

            static func topLevelFunctionIntrinsic(
                named functionName: String
            ) -> RuntimeConcurrencyFunctionIntrinsic? {
                topLevelFunctionDispatch[functionName]
            }

            static func taskStaticIntrinsic(
                memberName: String
            ) -> RuntimeTaskStaticIntrinsic? {
                taskStaticDispatch[memberName]
            }

            static func knowsTaskStaticMember(_ memberName: String) -> Bool {
                knownTaskStaticMembers.contains(memberName)
            }

            static func taskInstanceIntrinsic(
                memberName: String
            ) -> RuntimeTaskInstanceIntrinsic? {
                taskInstanceDispatch[memberName]
            }

            static func knowsTaskInstanceMember(_ memberName: String) -> Bool {
                knownTaskInstanceMembers.contains(memberName)
            }

            static func nominalMemberIntrinsic(
                typeName: String, memberName: String
            ) -> RuntimeConcurrencyNominalMemberIntrinsic? {
                nominalMemberDispatch[typeName]?[memberName]
            }

            static func knowsNominalMember(
                typeName: String, memberName: String
            ) -> Bool {
                knownNominalMembers[typeName]?.contains(memberName) == true
            }

            static func knowsMember(
                typeName: String, memberName: String
            ) -> Bool {
                knownTaskGroupMembers[typeName]?.contains(memberName) == true
            }
        }
        """ + "\n"
    }

    /// Produces the checked-in, SDK-derived denominator used by the external
    /// completeness ledger. This deliberately describes only the declaration
    /// families parsed by `inventory(interfaceSource:)`; `scope.complete` must
    /// remain false until the parser covers the complete public module.
    public static func generatedCapabilityInventory(
        interfacePath: String,
        interfaceSource: String,
    ) throws -> String {
        let inventory = try inventory(interfaceSource: interfaceSource)
        var declarations: [GeneratedCapabilityDeclaration] = []

        func append(
            domain: String,
            container: String,
            name: String,
            declaration: ConcurrencySurfaceDeclaration,
            adapterIntrinsic: String?,
        ) {
            let identity = [
                "swift-concurrency-api-v1", domain, container,
                declaration.kind.rawValue, declaration.declaration,
            ].joined(separator: "\u{0}")
            declarations.append(GeneratedCapabilityDeclaration(
                id: "swift-concurrency-api-v1:" + sha256(identity),
                domain: domain,
                container: container,
                name: name,
                kind: declaration.kind.rawValue,
                declaration: declaration.declaration,
                adapterIntrinsic: adapterIntrinsic,
                parameters: declaration.parameters.map { parameter in
                    GeneratedCapabilityParameter(
                        label: parameter.label,
                        name: parameter.name,
                        type: parameter.type,
                        defaultValue: parameter.defaultValue,
                        attributes: parameter.attributes,
                        modifiers: parameter.modifiers,
                        isolated: parameter.isIsolated,
                        inheritsActorContext: parameter.inheritsActorContext,
                        isolatedFunctionType:
                        parameter.hasIsolatedFunctionType,
                        sendableFunction: parameter.isSendableFunction,
                    )
                },
                returnType: declaration.returnType,
                effects: GeneratedCapabilityEffects(
                    async: declaration.isAsync,
                    throwsKind: declaration.throwsKind.rawValue,
                    thrownErrorType: declaration.thrownErrorType,
                ),
                isolation: GeneratedCapabilityIsolation(
                    globalActor: declaration.globalActor,
                    mutating: declaration.isMutating,
                    nonisolated: declaration.isNonisolated,
                ),
                attributes: declaration.attributes,
                modifiers: declaration.modifiers,
            ))
        }

        for name in inventory.topLevelFunctionDeclarations.keys.sorted() {
            for declaration in inventory.topLevelFunctionDeclarations[
                name, default: [],
            ] {
                append(
                    domain: "top-level-function",
                    container: "_Concurrency",
                    name: name,
                    declaration: declaration,
                    adapterIntrinsic:
                    inventory.topLevelFunctionDispatch[name],
                )
            }
        }
        for name in inventory.taskStaticMemberDeclarations.keys.sorted() {
            for declaration in inventory.taskStaticMemberDeclarations[
                name, default: [],
            ] {
                append(
                    domain: "task-static-member",
                    container: "Task",
                    name: name,
                    declaration: declaration,
                    adapterIntrinsic: inventory.taskStaticDispatch[name],
                )
            }
        }
        for name in inventory.taskInstanceMemberDeclarations.keys.sorted() {
            for declaration in inventory.taskInstanceMemberDeclarations[
                name, default: [],
            ] {
                append(
                    domain: "task-instance-member",
                    container: "Task",
                    name: name,
                    declaration: declaration,
                    adapterIntrinsic: inventory.taskInstanceDispatch[name],
                )
            }
        }
        for typeName in inventory.nominalMemberDeclarations.keys.sorted() {
            for name in inventory.nominalMemberDeclarations[
                typeName, default: [:]].keys.sorted() {
                for declaration in inventory.nominalMemberDeclarations[
                    typeName, default: [:]][name, default: []] {
                    append(
                        domain: "selected-nominal-member",
                        container: typeName,
                        name: name,
                        declaration: declaration,
                        adapterIntrinsic:
                            inventory.nominalMemberDispatch[typeName]?[name],
                    )
                }
            }
        }
        for typeName in taskGroupTypes.sorted() {
            let members = inventory.taskGroupMemberDeclarations[
                typeName, default: [:],
            ]
            for name in members.keys.sorted() {
                for declaration in members[name, default: []] {
                    append(
                        domain: "task-group-member",
                        container: typeName,
                        name: name,
                        declaration: declaration,
                        adapterIntrinsic:
                        inventory.taskGroupDispatch[typeName]?[name],
                    )
                }
            }
        }
        for typeName in taskGroupIteratorTypes.sorted() {
            let members = inventory.taskGroupIteratorMemberDeclarations[
                typeName, default: [:],
            ]
            for name in members.keys.sorted() {
                for declaration in members[name, default: []] {
                    append(
                        domain: "task-group-iterator-member",
                        container: typeName + ".Iterator",
                        name: name,
                        declaration: declaration,
                        adapterIntrinsic:
                        inventory.taskGroupIteratorDispatch[typeName]?[name],
                    )
                }
            }
        }

        declarations.sort {
            ($0.domain, $0.container, $0.name, $0.declaration, $0.id)
                < ($1.domain, $1.container, $1.name, $1.declaration, $1.id)
        }
        var declarationsByDomain: [String: Int] = [:]
        for declaration in declarations {
            declarationsByDomain[declaration.domain, default: 0] += 1
        }
        let moduleFlags = interfaceHeaderValue(
            "swift-module-flags", in: interfaceSource,
        )
        let moduleFlagParts = moduleFlags.split(separator: " ").map(String.init)
        let targetTriple = moduleFlagParts.firstIndex(of: "-target").flatMap {
            moduleFlagParts.indices.contains($0 + 1) ? moduleFlagParts[$0 + 1] : nil
        } ?? "unknown"
        let document = GeneratedCapabilityInventory(
            schemaVersion: 1,
            kind: "swift-concurrency-api-inventory",
            generator: "ConcurrencySurfaceGen",
            source: GeneratedCapabilitySource(
                module: "_Concurrency",
                interface: portableInterfaceLabel(interfacePath),
                interfaceSHA256: sha256(interfaceSource),
                interfaceFormatVersion: interfaceHeaderValue(
                    "swift-interface-format-version", in: interfaceSource,
                ),
                compilerVersion: interfaceHeaderValue(
                    "swift-compiler-version", in: interfaceSource,
                ),
                targetTriple: targetTriple,
            ),
            scope: GeneratedCapabilityScope(
                id: "top-level-functions-and-task-family-members-v5",
                complete: false,
                accountingUnit:
                "public declaration row after canonical-text deduplication",
                included: [
                    "public top-level function overloads",
                    "public static and instance Task function/variable declarations",
                    "public function/variable declarations on selected nominal concurrency families (currently MainActor and UnsafeCurrentTask)",
                    "declarations selected by active compiler conditional-compilation regions",
                    "public function/variable declarations on DiscardingTaskGroup, TaskGroup, ThrowingDiscardingTaskGroup, and ThrowingTaskGroup",
                    "public function/variable declarations on directly nested TaskGroup.Iterator and ThrowingTaskGroup.Iterator types",
                ],
                excluded: [
                    "public nominal types and members outside the selected Task/task-group/selected-nominal families",
                    "Task and other public initializers",
                    "protocol requirements, type aliases, subscripts, and associated types",
                    "nested declarations outside the selected task-group iterators",
                    "availability evaluation and non-identifier variable bindings",
                    "enclosing extension attributes, conformances, generic constraints, and duplicate declarations collapsed by canonical declaration text",
                ],
                adapterRouteIsSupportEvidence: false,
            ),
            summary: GeneratedCapabilitySummary(
                declarationCount: declarations.count,
                adapterRoutedDeclarationCount: declarations.count {
                    $0.adapterIntrinsic != nil
                },
                declarationsByDomain: declarationsByDomain,
            ),
            declarations: declarations,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        return try String(decoding: encoder.encode(document), as: UTF8.self)
            + "\n"
    }

    private static func command(
        _ executable: String, _ arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConcurrencySurfaceGenerationError.commandFailed(
                ([executable] + arguments).joined(separator: " ")
                    + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func globalActors(
        in syntax: SourceFileSyntax
    ) -> Set<String> {
        var names: Set<String> = []
        for statement in syntax.statements {
            guard case .decl(let declaration) = statement.item,
                  let actor = declaration.as(ActorDeclSyntax.self),
                  actor.attributes.contains(where: {
                      $0.as(AttributeSyntax.self)?.attributeName
                        .trimmedDescription == "globalActor"
                  }) else { continue }
            names.insert(actor.name.text)
        }
        return names
    }

    private static func inspect(
        _ members: MemberBlockItemListSyntax,
        globalActorNames: Set<String>,
        knownNames: inout Set<String>,
        dispatch: inout [String: String],
        declarations: inout [String: [ConcurrencySurfaceDeclaration]]
    ) {
        for item in members {
            if let function = item.decl.as(FunctionDeclSyntax.self),
               isPublic(function.modifiers) {
                let name = function.name.text
                knownNames.insert(name)
                appendUnique(
                    declarationMetadata(
                        function, globalActorNames: globalActorNames),
                    to: &declarations[name, default: []])
                if supportedIntrinsics.contains(name) {
                    dispatch[name] = name
                } else if let intrinsic = aliasedIntrinsic(in: function) {
                    dispatch[name] = intrinsic
                }
                continue
            }
            guard let variable = item.decl.as(VariableDeclSyntax.self),
                  isPublic(variable.modifiers) else { continue }
            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(
                    IdentifierPatternSyntax.self
                ) else { continue }
                let name = identifier.identifier.text
                knownNames.insert(name)
                appendUnique(
                    declarationMetadata(
                        variable, binding: binding,
                        globalActorNames: globalActorNames),
                    to: &declarations[name, default: []])
                if supportedIntrinsics.contains(name) {
                    dispatch[name] = name
                }
            }
        }
    }

    /// Reads the iterator declaration nested directly in the selected task-
    /// group extension/nominal. The outer type remains the dispatch key so the
    /// generated runtime does not have to reconstruct generic iterator names.
    private static func inspectNestedTaskGroupIterator(
        _ members: MemberBlockItemListSyntax,
        globalActorNames: Set<String>,
        knownNames: inout Set<String>,
        dispatch: inout [String: String],
        declarations: inout [String: [ConcurrencySurfaceDeclaration]]
    ) {
        for item in members {
            guard let structure = item.decl.as(StructDeclSyntax.self),
                  structure.name.text == "Iterator",
                  isPublic(structure.modifiers) else { continue }
            for iteratorItem in structure.memberBlock.members {
                if let function = iteratorItem.decl.as(
                    FunctionDeclSyntax.self),
                   isPublic(function.modifiers) {
                    let name = function.name.text
                    knownNames.insert(name)
                    appendUnique(
                        declarationMetadata(
                            function, globalActorNames: globalActorNames),
                        to: &declarations[name, default: []])
                    if supportedTaskGroupIteratorIntrinsics.contains(name) {
                        dispatch[name] = name
                    }
                    continue
                }
                guard let variable = iteratorItem.decl.as(
                    VariableDeclSyntax.self),
                      isPublic(variable.modifiers) else { continue }
                for binding in variable.bindings {
                    guard let identifier = binding.pattern.as(
                        IdentifierPatternSyntax.self) else { continue }
                    let name = identifier.identifier.text
                    knownNames.insert(name)
                    appendUnique(
                        declarationMetadata(
                            variable, binding: binding,
                            globalActorNames: globalActorNames),
                        to: &declarations[name, default: []])
                    if supportedTaskGroupIteratorIntrinsics.contains(name) {
                        dispatch[name] = name
                    }
                }
            }
        }
    }

    private static func inspectTaskMembers(
        _ members: MemberBlockItemListSyntax,
        globalActorNames: Set<String>,
        knownStaticNames: inout Set<String>,
        staticDispatch: inout [String: String],
        staticDeclarations:
            inout [String: [ConcurrencySurfaceDeclaration]],
        knownInstanceNames: inout Set<String>,
        instanceDispatch: inout [String: String],
        instanceDeclarations:
            inout [String: [ConcurrencySurfaceDeclaration]]
    ) {
        for item in members {
            if let function = item.decl.as(FunctionDeclSyntax.self),
               isPublic(function.modifiers) {
                let name = function.name.text
                let metadata = declarationMetadata(
                    function, globalActorNames: globalActorNames)
                if isStatic(function.modifiers) {
                    knownStaticNames.insert(name)
                    appendUnique(
                        metadata,
                        to: &staticDeclarations[name, default: []])
                    if supportedTaskStaticIntrinsics.contains(name) {
                        staticDispatch[name] = name
                    }
                } else {
                    knownInstanceNames.insert(name)
                    appendUnique(
                        metadata,
                        to: &instanceDeclarations[name, default: []])
                    if supportedTaskInstanceIntrinsics.contains(name) {
                        instanceDispatch[name] = name
                    }
                }
                continue
            }
            guard let variable = item.decl.as(VariableDeclSyntax.self),
                  isPublic(variable.modifiers) else { continue }
            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(
                    IdentifierPatternSyntax.self
                ) else { continue }
                let name = identifier.identifier.text
                let metadata = declarationMetadata(
                    variable, binding: binding,
                    globalActorNames: globalActorNames)
                if isStatic(variable.modifiers) {
                    knownStaticNames.insert(name)
                    appendUnique(
                        metadata,
                        to: &staticDeclarations[name, default: []])
                    if supportedTaskStaticIntrinsics.contains(name) {
                        staticDispatch[name] = name
                    }
                } else {
                    knownInstanceNames.insert(name)
                    appendUnique(
                        metadata,
                        to: &instanceDeclarations[name, default: []])
                    if supportedTaskInstanceIntrinsics.contains(name) {
                        instanceDispatch[name] = name
                    }
                }
            }
        }
    }

    /// Inventories a selected nominal's complete public function/property
    /// surface. Dispatch remains a separate, deliberately smaller map:
    /// generated knowledge makes unsupported SDK members fail closed without
    /// pretending that every inventoried declaration works.
    private static func inspectNominalMembers(
        _ members: MemberBlockItemListSyntax,
        globalActorNames: Set<String>,
        intrinsicMap: [String: String],
        knownNames: inout Set<String>,
        dispatch: inout [String: String],
        declarations: inout [String: [ConcurrencySurfaceDeclaration]]
    ) {
        for item in members {
            if let function = item.decl.as(FunctionDeclSyntax.self),
               isPublic(function.modifiers) {
                let name = function.name.text
                knownNames.insert(name)
                appendUnique(
                    declarationMetadata(
                        function, globalActorNames: globalActorNames),
                    to: &declarations[name, default: []])
                if let intrinsic = intrinsicMap[name] {
                    dispatch[name] = intrinsic
                }
                continue
            }
            guard let variable = item.decl.as(VariableDeclSyntax.self),
                  isPublic(variable.modifiers) else { continue }
            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(
                    IdentifierPatternSyntax.self
                ) else { continue }
                let name = identifier.identifier.text
                knownNames.insert(name)
                appendUnique(
                    declarationMetadata(
                        variable, binding: binding,
                        globalActorNames: globalActorNames),
                    to: &declarations[name, default: []])
                if let intrinsic = intrinsicMap[name] {
                    dispatch[name] = intrinsic
                }
            }
        }
    }

    private static func declarationMetadata(
        _ function: FunctionDeclSyntax,
        globalActorNames: Set<String>
    ) -> ConcurrencySurfaceDeclaration {
        let effectSpecifiers = function.signature.effectSpecifiers
        let throwsClause = effectSpecifiers?.throwsClause
        return ConcurrencySurfaceDeclaration(
            declaration: function.with(\.body, nil).trimmedDescription,
            kind: .function,
            parameters: function.signature.parameterClause.parameters.map {
                parameterMetadata($0)
            },
            returnType: function.signature.returnClause?.type
                .trimmedDescription,
            isAsync: effectSpecifiers?.asyncSpecifier != nil,
            throwsKind: throwsKind(throwsClause),
            thrownErrorType: throwsClause?.type?.trimmedDescription,
            attributes: attributes(function.attributes),
            modifiers: modifiers(function.modifiers),
            globalActor: globalActor(
                in: function.attributes, knownNames: globalActorNames))
    }

    private static func declarationMetadata(
        _ variable: VariableDeclSyntax,
        binding: PatternBindingSyntax,
        globalActorNames: Set<String>
    ) -> ConcurrencySurfaceDeclaration {
        var isAsync = false
        var propertyThrowsKind = ConcurrencySurfaceThrowsKind.nonThrowing
        var thrownErrorType: String?
        if let accessorBlock = binding.accessorBlock,
           case .accessors(let accessors) = accessorBlock.accessors {
            for accessor in accessors {
                let effects = accessor.effectSpecifiers
                isAsync = isAsync || effects?.asyncSpecifier != nil
                let accessorThrows = throwsKind(effects?.throwsClause)
                if accessorThrows == .rethrowing {
                    propertyThrowsKind = .rethrowing
                } else if accessorThrows == .throwing,
                          propertyThrowsKind == .nonThrowing {
                    propertyThrowsKind = .throwing
                }
                thrownErrorType = thrownErrorType
                    ?? effects?.throwsClause?.type?.trimmedDescription
            }
        }
        return ConcurrencySurfaceDeclaration(
            declaration: variable.trimmedDescription,
            kind: .variable,
            parameters: [],
            returnType: binding.typeAnnotation?.type.trimmedDescription,
            isAsync: isAsync,
            throwsKind: propertyThrowsKind,
            thrownErrorType: thrownErrorType,
            attributes: attributes(variable.attributes),
            modifiers: modifiers(variable.modifiers),
            globalActor: globalActor(
                in: variable.attributes, knownNames: globalActorNames))
    }

    private static func parameterMetadata(
        _ parameter: FunctionParameterSyntax
    ) -> ConcurrencySurfaceParameter {
        let firstName = parameter.firstName.text
        return ConcurrencySurfaceParameter(
            label: firstName == "_" ? nil : firstName,
            name: parameter.secondName?.text ?? firstName,
            type: parameter.type.trimmedDescription,
            defaultValue: parameter.defaultValue?.value.trimmedDescription,
            attributes: attributes(parameter.attributes),
            modifiers: modifiers(parameter.modifiers))
    }

    private static func throwsKind(
        _ clause: ThrowsClauseSyntax?
    ) -> ConcurrencySurfaceThrowsKind {
        guard let clause else { return .nonThrowing }
        return clause.throwsSpecifier.text == "rethrows"
            ? .rethrowing : .throwing
    }

    private static func attributes(
        _ attributes: AttributeListSyntax
    ) -> [String] {
        attributes.map(\.trimmedDescription)
    }

    private static func modifiers(
        _ modifiers: DeclModifierListSyntax
    ) -> [String] {
        modifiers.map(\.trimmedDescription)
    }

    private static func globalActor(
        in attributes: AttributeListSyntax,
        knownNames: Set<String>
    ) -> String? {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self) else {
                continue
            }
            let qualified = attribute.attributeName.trimmedDescription
            let name = qualified.split(separator: ".").last.map(String.init)
                ?? qualified
            if knownNames.contains(name) { return name }
        }
        return nil
    }

    private static func appendUnique<T: Equatable>(
        _ value: T, to values: inout [T]
    ) {
        if !values.contains(value) { values.append(value) }
    }

    private static func isPublic(
        _ modifiers: DeclModifierListSyntax
    ) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.public) }
    }

    private static func isStatic(
        _ modifiers: DeclModifierListSyntax
    ) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.static) }
    }

    private static func aliasedIntrinsic(
        in function: FunctionDeclSyntax
    ) -> String? {
        let body = function.body?.trimmedDescription ?? ""
        for intrinsic in ["addTaskUnlessCancelled", "addTask"] {
            if body.range(
                of: #"\b"# + intrinsic + #"\s*\("#,
                options: .regularExpression
            ) != nil {
                return intrinsic
            }
        }
        return nil
    }

    private static func normalizedTypeName(_ text: String) -> String {
        let withoutModule = text.replacingOccurrences(
            of: "_Concurrency.", with: "")
        return withoutModule.split(
            separator: "<", maxSplits: 1
        ).first.map(String.init) ?? withoutModule
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func optional(_ value: String?) -> String {
        value.map { "\"\(escaped($0))\"" } ?? "nil"
    }

    private static func stringArray(_ values: [String]) -> String {
        "[" + values.map { "\"\(escaped($0))\"" }
            .joined(separator: ", ") + "]"
    }

    private static func render(
        _ parameter: ConcurrencySurfaceParameter
    ) -> String {
        ".init(label: \(optional(parameter.label)), name: "
            + "\"\(escaped(parameter.name))\", type: "
            + "\"\(escaped(parameter.type))\", defaultValue: "
            + "\(optional(parameter.defaultValue)), attributes: "
            + "\(stringArray(parameter.attributes)), modifiers: "
            + "\(stringArray(parameter.modifiers)))"
    }

    private static func render(
        _ declaration: ConcurrencySurfaceDeclaration
    ) -> String {
        let parameters = "[" + declaration.parameters.map(render)
            .joined(separator: ", ") + "]"
        return ".init(declaration: \"\(escaped(declaration.declaration))\", "
            + "kind: .\(declaration.kind.rawValue), parameters: \(parameters), "
            + "returnType: \(optional(declaration.returnType)), isAsync: "
            + "\(declaration.isAsync), throwsKind: ."
            + "\(declaration.throwsKind.rawValue), thrownErrorType: "
            + "\(optional(declaration.thrownErrorType)), attributes: "
            + "\(stringArray(declaration.attributes)), modifiers: "
            + "\(stringArray(declaration.modifiers)), globalActor: "
            + "\(optional(declaration.globalActor)))"
    }

    private static func portableInterfaceLabel(_ path: String) -> String {
        guard let range = path.range(of: "/usr/lib/swift/") else {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "<macOS SDK>" + path[range.lowerBound...]
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func interfaceHeaderValue(
        _ name: String, in source: String,
    ) -> String {
        let prefix = "// \(name):"
        return source.split(separator: "\n").first {
            $0.hasPrefix(prefix)
        }.map {
            String($0.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
        } ?? "unknown"
    }
}
