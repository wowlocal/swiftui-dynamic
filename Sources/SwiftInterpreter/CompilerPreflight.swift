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

/// An Apple SDK selected by a target build manifest. The raw value is its
/// stable manifest identity; use `xcrunIdentifier` for tool invocation.
public enum CompilerPreflightAppleSDK: String, Sendable, CaseIterable {
    case macOS = "macosx"
    case iOS = "iphoneos"
    case iOSSimulator = "iphonesimulator"
    /// Mac Catalyst is an iOS destination compiled against the macOS SDK.
    case macCatalyst = "maccatalyst"
    case tvOS = "appletvos"
    case tvOSSimulator = "appletvsimulator"
    case watchOS = "watchos"
    case watchOSSimulator = "watchsimulator"
    case visionOS = "xros"
    case visionOSSimulator = "xrsimulator"

    /// Spelling accepted by Swift's `#if os(...)` predicate.
    public var platformName: String {
        switch self {
        case .macOS: "macOS"
        case .iOS, .iOSSimulator, .macCatalyst: "iOS"
        case .tvOS, .tvOSSimulator: "tvOS"
        case .watchOS, .watchOSSimulator: "watchOS"
        case .visionOS, .visionOSSimulator: "visionOS"
        }
    }

    /// Spelling embedded in an Apple target triple.
    var targetPlatformName: String {
        switch self {
        case .macOS: "macosx"
        case .iOS, .iOSSimulator, .macCatalyst: "ios"
        case .tvOS, .tvOSSimulator: "tvos"
        case .watchOS, .watchOSSimulator: "watchos"
        case .visionOS, .visionOSSimulator: "xros"
        }
    }

    /// Spelling accepted by Swift's `#if targetEnvironment(...)` predicate.
    public var targetEnvironment: String? {
        switch self {
        case .iOSSimulator, .tvOSSimulator, .watchOSSimulator,
             .visionOSSimulator:
            "simulator"
        case .macCatalyst:
            "macCatalyst"
        case .macOS, .iOS, .tvOS, .watchOS, .visionOS:
            nil
        }
    }

    /// SDK identifier accepted by `xcrun --sdk`. Catalyst intentionally uses
    /// the macOS SDK while retaining an iOS/macabi destination triple.
    public var xcrunIdentifier: String {
        self == .macCatalyst ? "macosx" : rawValue
    }

    var targetTripleSuffix: String {
        switch self {
        case .iOSSimulator, .tvOSSimulator, .watchOSSimulator,
             .visionOSSimulator:
            "-simulator"
        case .macCatalyst:
            "-macabi"
        case .macOS, .iOS, .tvOS, .watchOS, .visionOS:
            ""
        }
    }
}

public struct CompilerPreflightVersion: Sendable, Equatable, Comparable,
    CustomStringConvertible
{
    public let major: UInt
    public let minor: UInt
    public let patch: UInt

    /// Integer components cannot represent a malformed negative version, so
    /// callers constructing manifests from decoded input do not cross a
    /// process-crashing precondition boundary.
    public init(_ major: UInt, _ minor: UInt = 0, _ patch: UInt = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(parsing value: String) throws {
        let components = value.split(
            separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else {
            throw CompilerPreflightError.invalidConfiguration(
                "compiler version '\(value)' is invalid")
        }
        var numbers: [UInt] = []
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = UInt(component)
            else {
                throw CompilerPreflightError.invalidConfiguration(
                    "compiler version '\(value)' is invalid")
            }
            numbers.append(number)
        }
        self.init(
            numbers[0],
            numbers.count > 1 ? numbers[1] : 0,
            numbers.count > 2 ? numbers[2] : 0)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (
        lhs: CompilerPreflightVersion,
        rhs: CompilerPreflightVersion
    ) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    func satisfies(_ rawPredicate: String) -> Bool {
        let predicate = rawPredicate.replacingOccurrences(of: " ", with: "")
        // Swift conditional-compilation version predicates support only these
        // two operators. Native preflight diagnoses every other spelling.
        let operators = [">=", "<"]
        guard let operation = operators.first(where: predicate.hasPrefix),
              let required = try? CompilerPreflightVersion(
                  parsing: String(predicate.dropFirst(operation.count)))
        else { return false }
        switch operation {
        case ">=": return self >= required
        case "<": return self < required
        default: return false
        }
    }

    var nextPatch: CompilerPreflightVersion? {
        guard patch < UInt.max else { return nil }
        return CompilerPreflightVersion(major, minor, patch + 1)
    }
}

public enum CompilerPreflightSwiftLanguageVersion: String, Sendable {
    case swift4 = "4"
    case swift4_2 = "4.2"
    case swift5 = "5"
    case swift6 = "6"
}

public enum CompilerPreflightStrictConcurrency: String, Sendable {
    case minimal
    case targeted
    case complete
}

public enum CompilerPreflightDefaultIsolation: String, Sendable {
    case nonisolated
    case mainActor = "MainActor"
}

/// One version-qualified `canImport` answer established by the selected real
/// compiler. Module version comparison has compiler-specific behavior (for
/// example, an absent user version can make `_version:` advisory), so the
/// manifest records the result and the client-module preflight verifies it in
/// the same source/import context instead of reimplementing that policy in the
/// interpreter.
public struct CompilerPreflightVersionedImportQuery: Sendable, Equatable,
    Hashable
{
    public enum VersionKind: String, Sendable {
        case user = "_version"
        case underlying = "_underlyingVersion"
    }

    public let moduleName: String
    public let versionKind: VersionKind
    public let version: String
    public let isImportable: Bool

    public init(
        moduleName: String,
        versionKind: VersionKind,
        version: String,
        isImportable: Bool
    ) throws {
        guard isValidCompilerModulePath(moduleName) else {
            throw CompilerPreflightError.invalidConfiguration(
                "versioned import module '\(moduleName)' is invalid")
        }
        guard isValidCompilerImportVersion(version) else {
            throw CompilerPreflightError.invalidConfiguration(
                "versioned import value '\(version)' is invalid")
        }
        self.moduleName = moduleName
        self.versionKind = versionKind
        self.version = version
        self.isImportable = isImportable
    }

    var identity: String {
        moduleName + "\u{0}" + versionKind.rawValue + "\u{0}" + version
    }

    var sourceCondition: String {
        "canImport(\(moduleName), \(versionKind.rawValue): \(version))"
    }
}

/// One single-identifier conditional-compilation predicate whose answer is
/// owned by the selected compiler rather than reimplemented by the
/// interpreter. The client-module preflight verifies every recorded answer in
/// the same target context before interpretation starts.
public struct CompilerPreflightConditionalCompilationQuery: Sendable,
    Equatable, Hashable
{
    public enum Predicate: String, Sendable, CaseIterable {
        case hasFeature
        case hasAttribute
        case objectFormat
        case endian = "_endian"
        case runtime = "_runtime"
    }

    public let predicate: Predicate
    public let argument: String
    public let isActive: Bool

    public init(
        predicate: Predicate,
        argument: String,
        isActive: Bool
    ) throws {
        guard isValidCompilerIdentifier(argument) else {
            throw CompilerPreflightError.invalidConfiguration(
                "conditional-compilation argument '\(argument)' is invalid")
        }
        self.predicate = predicate
        self.argument = argument
        self.isActive = isActive
    }

    var identity: String {
        predicate.rawValue + "\u{0}" + argument
    }

    var sourceCondition: String {
        "\(predicate.rawValue)(\(argument))"
    }
}

/// The concurrency-preflight and conditional-compilation identity for one
/// Swift target. Driver actions, output/source paths, package access policy,
/// and resource rules remain build-system/project-manifest responsibilities.
public struct CompilerPreflightBuildTarget: Sendable, Equatable {
    public let moduleName: String
    public let sdk: CompilerPreflightAppleSDK
    public let architecture: String
    public let deploymentTarget: String
    public let compilerVersion: CompilerPreflightVersion
    /// Effective version observed by source `#if swift(...)`. This is
    /// intentionally distinct from `-swift-version`: Swift 6.3 in Swift 5
    /// mode reports 5.10, not 5.0. `activeApple` verifies this boundary with
    /// the selected real compiler before accepting the target.
    public let swiftConditionalCompilationVersion: CompilerPreflightVersion
    public let swiftLanguageVersion: CompilerPreflightSwiftLanguageVersion
    public let strictConcurrency: CompilerPreflightStrictConcurrency
    public let defaultIsolation: CompilerPreflightDefaultIsolation
    /// Complete module set used to answer source `#if canImport(...)` while
    /// interpreting this target. Build-system adapters must include both SDK
    /// modules and dependency products; this is authoritative, not a hint.
    public let importableModules: [String]
    /// Complete set of version-qualified `canImport` predicates used by this
    /// target's sources. An unrecorded query fails closed before execution.
    public let versionedImportQueries:
        [CompilerPreflightVersionedImportQuery]
    /// Exact compiler-owned answers for conditional predicates that cannot be
    /// derived safely from the manifest fields above. Source that uses one of
    /// these predicate families without a recorded answer fails closed before
    /// interpreter mutation.
    public let conditionalCompilationQueries:
        [CompilerPreflightConditionalCompilationQuery]
    public let activeCompilationConditions: [String]
    public let importSearchPaths: [String]
    public let frameworkSearchPaths: [String]
    public let upcomingFeatures: [String]
    public let experimentalFeatures: [String]

    public init(
        moduleName: String,
        sdk: CompilerPreflightAppleSDK,
        architecture: String,
        deploymentTarget: String,
        compilerVersion: CompilerPreflightVersion,
        swiftConditionalCompilationVersion: CompilerPreflightVersion,
        importableModules: [String],
        versionedImportQueries:
            [CompilerPreflightVersionedImportQuery] = [],
        conditionalCompilationQueries:
            [CompilerPreflightConditionalCompilationQuery] = [],
        swiftLanguageVersion: CompilerPreflightSwiftLanguageVersion = .swift6,
        strictConcurrency: CompilerPreflightStrictConcurrency = .complete,
        defaultIsolation: CompilerPreflightDefaultIsolation = .nonisolated,
        activeCompilationConditions: [String] = [],
        importSearchPaths: [String] = [],
        frameworkSearchPaths: [String] = [],
        upcomingFeatures: [String] = [],
        experimentalFeatures: [String] = []
    ) throws {
        guard isValidCompilerModuleName(moduleName) else {
            throw CompilerPreflightError.invalidConfiguration(
                "target module name '\(moduleName)' is not a Swift identifier")
        }
        guard isValidTargetArchitecture(architecture) else {
            throw CompilerPreflightError.invalidConfiguration(
                "target architecture '\(architecture)' is invalid")
        }
        guard isValidDeploymentTarget(deploymentTarget) else {
            throw CompilerPreflightError.invalidConfiguration(
                "deployment target '\(deploymentTarget)' is invalid")
        }
        for condition in activeCompilationConditions {
            guard isValidCompilerIdentifier(condition) else {
                throw CompilerPreflightError.invalidConfiguration(
                    "active compilation condition '\(condition)' is invalid")
            }
        }
        for module in importableModules {
            guard isValidCompilerModulePath(module) else {
                throw CompilerPreflightError.invalidConfiguration(
                    "importable module '\(module)' is invalid")
            }
        }
        let importableModuleSet = Set(importableModules)
        var versionedImportIdentities: Set<String> = []
        for query in versionedImportQueries {
            guard versionedImportIdentities.insert(query.identity).inserted
            else {
                throw CompilerPreflightError.invalidConfiguration(
                    "versioned import query '\(query.sourceCondition)' is "
                        + "duplicated")
            }
            guard !query.isImportable
                    || importableModuleSet.contains(query.moduleName)
            else {
                throw CompilerPreflightError.invalidConfiguration(
                    "true versioned import query '\(query.sourceCondition)' "
                        + "requires unversioned module membership")
            }
        }
        var conditionalQueryIdentities: Set<String> = []
        for query in conditionalCompilationQueries {
            guard conditionalQueryIdentities.insert(query.identity).inserted
            else {
                throw CompilerPreflightError.invalidConfiguration(
                    "conditional-compilation query "
                        + "'\(query.sourceCondition)' is duplicated")
            }
        }
        for feature in upcomingFeatures + experimentalFeatures {
            guard isValidCompilerIdentifier(feature) else {
                throw CompilerPreflightError.invalidConfiguration(
                    "compiler feature '\(feature)' is invalid")
            }
        }
        for path in importSearchPaths + frameworkSearchPaths {
            guard isAbsoluteNormalizedCompilerSearchPath(path) else {
                throw CompilerPreflightError.invalidConfiguration(
                    "compiler search path '\(path)' must be absolute and "
                        + "lexically normalized")
            }
        }

        self.moduleName = moduleName
        self.sdk = sdk
        self.architecture = architecture
        self.deploymentTarget = deploymentTarget
        self.compilerVersion = compilerVersion
        self.swiftConditionalCompilationVersion =
            swiftConditionalCompilationVersion
        self.swiftLanguageVersion = swiftLanguageVersion
        self.strictConcurrency = strictConcurrency
        self.defaultIsolation = defaultIsolation
        self.importableModules = Array(Set(importableModules)).sorted()
        self.versionedImportQueries = versionedImportQueries.sorted {
            $0.identity < $1.identity
        }
        self.conditionalCompilationQueries =
            conditionalCompilationQueries.sorted {
                $0.identity < $1.identity
            }
        self.activeCompilationConditions = Array(
            Set(activeCompilationConditions)
        ).sorted()
        self.importSearchPaths = importSearchPaths
        self.frameworkSearchPaths = frameworkSearchPaths
        self.upcomingFeatures = upcomingFeatures
        self.experimentalFeatures = experimentalFeatures
    }

    /// Exact target passed to both the generated host-module build and client
    /// typecheck. Simulator identity is part of the triple rather than an
    /// unrelated compiler define.
    public var targetTriple: String {
        "\(architecture)-apple-" + sdk.targetPlatformName
            + deploymentTarget + sdk.targetTripleSuffix
    }

    /// Validated target-only arguments. Common language, concurrency, SDK,
    /// and target flags are emitted separately so these never leak into the
    /// generated host declaration module.
    public var clientCompilerArguments: [String] {
        var arguments = ["-default-isolation", defaultIsolation.rawValue]
        for condition in activeCompilationConditions {
            arguments += ["-D", condition]
        }
        for path in importSearchPaths {
            arguments += ["-I", path]
        }
        for path in frameworkSearchPaths {
            arguments += ["-F", path]
        }
        for feature in upcomingFeatures {
            arguments += ["-enable-upcoming-feature", feature]
        }
        for feature in experimentalFeatures {
            arguments += ["-enable-experimental-feature", feature]
        }
        return arguments
    }

    var clientConditionalCompilationValidationSource: String? {
        guard !versionedImportQueries.isEmpty
                || !conditionalCompilationQueries.isEmpty
        else { return nil }
        var source = "// Generated build-target conditional validation.\n"
        for (index, query) in versionedImportQueries.enumerated() {
            source += "#if \(query.sourceCondition)\n"
            if !query.isImportable {
                source += "#error(\"manifest versioned import query \(index) "
                    + "was unexpectedly true\")\n"
            }
            source += "#else\n"
            if query.isImportable {
                source += "#error(\"manifest versioned import query \(index) "
                    + "was unexpectedly false\")\n"
            }
            source += "#endif\n"
        }
        for (index, query) in conditionalCompilationQueries.enumerated() {
            source += "#if \(query.sourceCondition)\n"
            if !query.isActive {
                source += "#error(\"manifest conditional query \(index) "
                    + "was unexpectedly true\")\n"
            }
            source += "#else\n"
            if query.isActive {
                source += "#error(\"manifest conditional query \(index) "
                    + "was unexpectedly false\")\n"
            }
            source += "#endif\n"
        }
        return source
    }

    /// Stable semantic identity used by project manifests and compiler-result
    /// caches. Search-path order is retained because it changes module lookup.
    public var fingerprint: String {
        compilerPreflightDigest([
            "compiler-preflight-build-target-v2",
            moduleName,
            sdk.rawValue,
            architecture,
            deploymentTarget,
            compilerVersion.description,
            swiftConditionalCompilationVersion.description,
            swiftLanguageVersion.rawValue,
            strictConcurrency.rawValue,
            defaultIsolation.rawValue,
            importableModules.joined(separator: "\u{0}"),
            versionedImportQueries.map {
                $0.identity + "\u{0}" + String($0.isImportable)
            }.joined(separator: "\u{1}"),
            conditionalCompilationQueries.map {
                $0.identity + "\u{0}" + String($0.isActive)
            }.joined(separator: "\u{1}"),
            activeCompilationConditions.joined(separator: "\u{0}"),
            importSearchPaths.joined(separator: "\u{0}"),
            frameworkSearchPaths.joined(separator: "\u{0}"),
            upcomingFeatures.joined(separator: "\u{0}"),
            experimentalFeatures.joined(separator: "\u{0}"),
        ])
    }
}

/// Immutable source for a generated declaration module imported by compiler
/// preflight. The module is compiled once per engine; only its serialized
/// public declarations participate in checking user source.
public struct CompilerPreflightHostModule: Sendable, Equatable {
    public static let defaultSyntheticModuleName = "DynamicSwiftHostSurface"

    public let moduleName: String
    public let source: String
    /// Arguments used only while compiling this declaration module. They are
    /// intentionally separate from user-source preflight arguments so a
    /// compatibility module can be serialized in its native language mode
    /// while clients remain checked under Swift 6 strict concurrency.
    public let compilerArguments: [String]
    public let sourceSHA256: String
    public let manifestSHA256: String

    public init(
        moduleName: String,
        source: String,
        compilerArguments: [String] = []
    ) {
        self.moduleName = moduleName
        self.source = source
        self.compilerArguments = compilerArguments
        self.sourceSHA256 = SHA256.hash(data: Data(source.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        self.manifestSHA256 = compilerPreflightDigest([
            "compiler-preflight-host-module-v2",
            moduleName,
            sourceSHA256,
            compilerArguments.joined(separator: "\u{0}"),
        ])
    }

    static func composing(
        base: CompilerPreflightHostModule?,
        syntheticTypes: [CompilerPreflightHostType] = [],
        syntheticSignatures: [HostSignature]
    ) throws -> CompilerPreflightHostModule? {
        guard !syntheticTypes.isEmpty || !syntheticSignatures.isEmpty else {
            return base
        }

        var typesByName: [String: CompilerPreflightHostType] = [:]
        for type in syntheticTypes {
            if let existing = typesByName[type.name], existing != type {
                throw CompilerPreflightError.invalidConfiguration(
                    "conflicting synthetic nominal declarations for "
                        + "'\(type.name)': '\(existing.declaration)' and "
                        + "'\(type.declaration)'")
            }
            typesByName[type.name] = type
        }

        var standaloneDeclarations: [String: String] = [:]
        var membersByType: [String: [String: String]] = [:]
        for signature in syntheticSignatures {
            if let receiverType = signature.receiverType,
               typesByName[receiverType] != nil {
                if membersByType[receiverType]?[signature.declaration] == nil {
                    membersByType[receiverType, default: [:]][
                        signature.declaration
                    ] = try signature.compilerPreflightStub(
                        embeddedInReceiver: true)
                }
            } else if standaloneDeclarations[signature.declaration] == nil {
                standaloneDeclarations[signature.declaration] =
                    try signature.compilerPreflightStub()
            }
        }

        let typeDeclarations = typesByName.values.sorted {
            $0.compilerPreflightDeclaration < $1.compilerPreflightDeclaration
        }.map { type in
            type.compilerPreflightStub(
                members: membersByType[type.name]?.values.sorted() ?? [])
        }
        let declarations = typeDeclarations
            + standaloneDeclarations.values.sorted()
        let generatedSource = ([
            "// Generated from typed interpreter-synthetic host contracts.",
        ] + declarations).joined(separator: "\n\n") + "\n"
        let source: String
        if let base {
            source = base.source
                + (base.source.hasSuffix("\n") ? "" : "\n")
                + generatedSource
        } else {
            source = generatedSource
        }
        return CompilerPreflightHostModule(
            moduleName: base?.moduleName ?? defaultSyntheticModuleName,
            source: source,
            compilerArguments: base?.compilerArguments ?? [])
    }
}

private extension HostSignature {
    func compilerPreflightStub(
        embeddedInReceiver: Bool = false
    ) throws -> String {
        guard var nativeDeclaration = compilerPreflightDeclaration,
              let accessOffset =
                compilerPreflightAccessInsertionUTF8Offset else {
            throw CompilerPreflightError.invalidConfiguration(
                "synthetic compiler declaration '\(declaration)' cannot be "
                    + "serialized as native Swift")
        }
        nativeDeclaration = nativeDeclaration.trimmingCharacters(
            in: .whitespacesAndNewlines)

        if kind == .property || kind == .staticProperty {
            guard !((isAsync || isThrowing) && isSettable) else {
                throw CompilerPreflightError.invalidConfiguration(
                    "synthetic compiler property '\(declaration)' combines "
                        + "an effectful getter with a setter")
            }
            nativeDeclaration = replacingReadOnlyLetWithComputedVar(
                in: nativeDeclaration, at: accessOffset)
        }
        let exportedDeclaration = try exportedCompilerDeclaration(
            nativeDeclaration, accessOffset: accessOffset)

        switch kind {
        case .function:
            guard receiverType == nil else {
                throw CompilerPreflightError.invalidConfiguration(
                    "synthetic compiler function '\(declaration)' has an "
                        + "unexpected receiver")
            }
            return callableStub(for: exportedDeclaration)

        case .method, .staticMethod, .initializer:
            guard let receiverType else {
                throw CompilerPreflightError.invalidConfiguration(
                    "synthetic compiler member '\(declaration)' has no "
                        + "receiver type")
            }
            let member = callableStub(for: exportedDeclaration)
            return embeddedInReceiver
                ? member
                : extensionStub(receiverType: receiverType, member: member)

        case .property, .staticProperty:
            guard let receiverType else {
                throw CompilerPreflightError.invalidConfiguration(
                    "synthetic compiler property '\(declaration)' has no "
                        + "receiver type")
            }
            let head: String
            if let accessorStart = firstTopLevelIndex(
                of: "{", in: exportedDeclaration) {
                head = String(exportedDeclaration[..<accessorStart])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                head = exportedDeclaration
            }
            let failure =
                "fatalError(\"compiler-preflight declaration only\")"
            var accessors = "get"
            let getterEffects = compilerPreflightGetterEffects
                ?? (isThrowing ? "throws" : "")
            if !getterEffects.isEmpty {
                accessors += " " + getterEffects
            }
            accessors += " {\n    \(failure)\n}"
            if isSettable {
                accessors += "\nset {\n    \(failure)\n}"
            }
            let member = "\(head) {\n\(indented(accessors))\n}"
            return embeddedInReceiver
                ? member
                : extensionStub(receiverType: receiverType, member: member)
        }
    }

    func exportedCompilerDeclaration(
        _ nativeDeclaration: String, accessOffset: Int
    ) throws -> String {
        let accessModifiers = Set([
            "private", "fileprivate", "internal", "package", "public", "open",
        ])
        let declaredAccess = modifiers.lazy.map {
            $0.split(separator: "(", maxSplits: 1).first.map(String.init) ?? $0
        }.first(where: accessModifiers.contains)
        if let declaredAccess, declaredAccess != "public" {
            throw CompilerPreflightError.invalidConfiguration(
                "synthetic compiler declaration '\(declaration)' has "
                    + "non-public access '\(declaredAccess)'")
        }
        if declaredAccess == "public" {
            return nativeDeclaration
        }
        var bytes = Array(nativeDeclaration.utf8)
        guard accessOffset <= bytes.count else {
            throw CompilerPreflightError.invalidConfiguration(
                "synthetic compiler declaration '\(declaration)' has an "
                    + "invalid export insertion point")
        }
        bytes.insert(contentsOf: Array("public ".utf8), at: accessOffset)
        return String(decoding: bytes, as: UTF8.self)
    }

    func replacingReadOnlyLetWithComputedVar(
        in nativeDeclaration: String, at accessOffset: Int
    ) -> String {
        var bytes = Array(nativeDeclaration.utf8)
        let letBytes = Array("let".utf8)
        guard accessOffset + letBytes.count <= bytes.count,
              Array(bytes[accessOffset..<(accessOffset + letBytes.count)])
                == letBytes else {
            return nativeDeclaration
        }
        bytes.replaceSubrange(
            accessOffset..<(accessOffset + letBytes.count),
            with: Array("var".utf8))
        return String(decoding: bytes, as: UTF8.self)
    }

    func callableStub(for exportedDeclaration: String) -> String {
        "\(exportedDeclaration) {\n"
            + "    fatalError(\"compiler-preflight declaration only\")\n"
            + "}"
    }

    func extensionStub(receiverType: String, member: String) -> String {
        "extension \(receiverType) {\n\(indented(member))\n}"
    }

    func indented(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0 }
            .joined(separator: "\n")
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
    public let moduleName: String
    public let swiftLanguageVersion: CompilerPreflightSwiftLanguageVersion
    public let strictConcurrency: CompilerPreflightStrictConcurrency
    public let gatewayManifestSHA256: String
    /// Effective arguments applied only to the user target typecheck. Driver
    /// actions and the common SDK/target/language policy are not represented
    /// here.
    public let clientCompilerArguments: [String]
    /// Optional generated source compiled only with the user module. Target
    /// manifests use it to prove conditional answers that depend on the
    /// module's complete source/import set.
    public let clientValidationSource: String?
    /// Source-compatible view of caller-supplied arguments from the legacy
    /// macOS factory. New build-target callers use validated structured fields.
    public let additionalCompilerArguments: [String]
    public let timeoutSeconds: TimeInterval

    public init(
        swiftCompilerPath: String,
        compilerVersion: String,
        sdkPath: String,
        sdkVersion: String,
        targetTriple: String,
        deploymentTarget: String,
        moduleName: String = "main",
        swiftLanguageVersion: CompilerPreflightSwiftLanguageVersion = .swift6,
        strictConcurrency: CompilerPreflightStrictConcurrency = .complete,
        gatewayManifestSHA256: String,
        clientCompilerArguments: [String] = [],
        clientValidationSource: String? = nil,
        additionalCompilerArguments: [String] = [],
        timeoutSeconds: TimeInterval = 10
    ) {
        self.swiftCompilerPath = swiftCompilerPath
        self.compilerVersion = compilerVersion
        self.sdkPath = sdkPath
        self.sdkVersion = sdkVersion
        self.targetTriple = targetTriple
        self.deploymentTarget = deploymentTarget
        self.moduleName = moduleName
        self.swiftLanguageVersion = swiftLanguageVersion
        self.strictConcurrency = strictConcurrency
        self.gatewayManifestSHA256 = gatewayManifestSHA256
        self.clientCompilerArguments = clientCompilerArguments
            + additionalCompilerArguments
        self.clientValidationSource = clientValidationSource
        self.additionalCompilerArguments = additionalCompilerArguments
        self.timeoutSeconds = timeoutSeconds
    }

    /// Stable identity for every input that can change native type checking.
    public var fingerprint: String {
        compilerPreflightDigest([
            "compiler-preflight-configuration-v2",
            swiftCompilerPath,
            compilerVersion,
            sdkPath,
            sdkVersion,
            targetTriple,
            deploymentTarget,
            moduleName,
            swiftLanguageVersion.rawValue,
            strictConcurrency.rawValue,
            gatewayManifestSHA256,
            clientCompilerArguments.joined(separator: "\u{0}"),
            clientValidationSource ?? "",
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
                "-swift-version",
                configuration.swiftLanguageVersion.rawValue,
                "-strict-concurrency="
                    + configuration.strictConcurrency.rawValue,
                "-sdk", configuration.sdkPath,
                "-target", configuration.targetTriple,
                "-module-cache-path", moduleCache.path,
                "-parse-as-library",
                "-module-name", module.moduleName,
                "-emit-module",
                "-emit-module-path", moduleURL.path,
            ] + configuration.additionalCompilerArguments
                + module.compilerArguments + [sourceURL.path]
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
        let hostModule = try CompilerPreflightHostModule.composing(
            base: registry?.compilerPreflightHostModule,
            syntheticTypes:
                registry?.compilerPreflightSyntheticTypes ?? [],
            syntheticSignatures:
                registry?.compilerPreflightSyntheticSignatures ?? [])
        if let hostModule {
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

    /// Discover the active Apple toolchain and the SDK selected by one build
    /// target. Compiler declarations and runtime gateways are composed from
    /// the same registry identity.
    public static func activeApple(
        buildTarget: CompilerPreflightBuildTarget,
        registry: HostRegistry? = nil,
        timeoutSeconds: TimeInterval = 10
    ) throws -> SwiftCompilerPreflight {
        let hostModule = try CompilerPreflightHostModule.composing(
            base: registry?.compilerPreflightHostModule,
            syntheticTypes:
                registry?.compilerPreflightSyntheticTypes ?? [],
            syntheticSignatures:
                registry?.compilerPreflightSyntheticSignatures ?? [])
        if hostModule?.moduleName == buildTarget.moduleName {
            throw CompilerPreflightError.invalidConfiguration(
                "target module '\(buildTarget.moduleName)' conflicts with "
                    + "the compiler-preflight host module")
        }
        return try activeApple(
            buildTarget: buildTarget,
            gatewayManifestSHA256: hostModule?.manifestSHA256
                ?? emptyGatewayManifestSHA256,
            hostModule: hostModule,
            timeoutSeconds: timeoutSeconds)
    }

    private static func activeApple(
        buildTarget: CompilerPreflightBuildTarget,
        gatewayManifestSHA256: String,
        hostModule: CompilerPreflightHostModule?,
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
        guard let discoveredCompilerVersion = compilerPreflightSwiftVersion(
            in: version
        ) else {
            throw CompilerPreflightError.invalidToolchainOutput(version)
        }
        guard discoveredCompilerVersion == buildTarget.compilerVersion else {
            throw CompilerPreflightError.invalidConfiguration(
                "target requires Swift \(buildTarget.compilerVersion), but "
                    + "the active compiler is Swift "
                    + discoveredCompilerVersion.description)
        }
        let sdkPath = try requiredOutput(
            executable: xcrun,
            arguments: [
                "--show-sdk-path", "--sdk", buildTarget.sdk.xcrunIdentifier,
            ],
            timeoutSeconds: timeoutSeconds,
            operation: "locate \(buildTarget.sdk.xcrunIdentifier) SDK")
        let sdkVersion = try requiredOutput(
            executable: xcrun,
            arguments: [
                "--show-sdk-version", "--sdk",
                buildTarget.sdk.xcrunIdentifier,
            ],
            timeoutSeconds: timeoutSeconds,
            operation: "read \(buildTarget.sdk.xcrunIdentifier) SDK version")
        let targetData = try requiredOutput(
            executable: swiftc,
            arguments: [
                "-print-target-info",
                "-sdk", sdkPath,
                "-target", buildTarget.targetTriple,
            ],
            timeoutSeconds: timeoutSeconds,
            operation: "validate compiler target \(buildTarget.targetTriple)")
        struct TargetInfo: Decodable {
            struct Target: Decodable { let triple: String }
            let target: Target
        }
        guard let targetInfoData = targetData.data(using: .utf8),
              let resolvedTarget = try? JSONDecoder().decode(
                TargetInfo.self, from: targetInfoData).target.triple,
              resolvedTarget == buildTarget.targetTriple else {
            throw CompilerPreflightError.invalidToolchainOutput(targetData)
        }
        try validateSwiftConditionalCompilationVersion(
            swiftCompilerPath: swiftc,
            sdkPath: sdkPath,
            buildTarget: buildTarget,
            timeoutSeconds: timeoutSeconds)
        let configuration = CompilerPreflightConfiguration(
            swiftCompilerPath: swiftc,
            compilerVersion: version.replacingOccurrences(
                of: "\n", with: " | "),
            sdkPath: sdkPath,
            sdkVersion: sdkVersion,
            targetTriple: buildTarget.targetTriple,
            deploymentTarget: buildTarget.deploymentTarget,
            moduleName: buildTarget.moduleName,
            swiftLanguageVersion: buildTarget.swiftLanguageVersion,
            strictConcurrency: buildTarget.strictConcurrency,
            gatewayManifestSHA256: gatewayManifestSHA256,
            clientCompilerArguments:
                buildTarget.clientCompilerArguments,
            clientValidationSource:
                buildTarget.clientConditionalCompilationValidationSource,
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

    private static func validateSwiftConditionalCompilationVersion(
        swiftCompilerPath: String,
        sdkPath: String,
        buildTarget: CompilerPreflightBuildTarget,
        timeoutSeconds: TimeInterval
    ) throws {
        #if os(macOS)
        guard let upperBound =
            buildTarget.swiftConditionalCompilationVersion.nextPatch
        else {
            throw CompilerPreflightError.invalidConfiguration(
                "Swift conditional-compilation version cannot be bounded")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-version-probe-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("VersionProbe.swift")
        let expected = buildTarget.swiftConditionalCompilationVersion
        let source = """
        #if swift(>=\(expected)) && swift(<\(upperBound))
        #else
        #error("manifest Swift conditional-compilation version mismatch")
        #endif
        """
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        var arguments = [
            "-swift-version", buildTarget.swiftLanguageVersion.rawValue,
            "-sdk", sdkPath,
            "-target", buildTarget.targetTriple,
            "-module-name", buildTarget.moduleName,
            "-typecheck",
        ]
        arguments += buildTarget.clientCompilerArguments
        arguments.append(sourceURL.path)
        let output = try executeProcess(
            executable: swiftCompilerPath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds)
        guard output.exitStatus == 0 else {
            let diagnostics = (output.standardError + "\n"
                + output.standardOutput).trimmingCharacters(
                    in: .whitespacesAndNewlines)
            throw CompilerPreflightError.invalidConfiguration(
                "target records #if swift as \(expected), but the selected "
                    + "compiler/language mode disagrees: \(diagnostics)")
        }
        #else
        throw CompilerPreflightError.unsupportedPlatform
        #endif
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
            moduleName: "main",
            swiftLanguageVersion: .swift6,
            strictConcurrency: .complete,
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
        var normalizedSources = try sources.map {
            CompilerPreflightSource(
                fileName: try validatedLogicalFileName($0.fileName),
                source: $0.source)
        }
        if let validationSource = configuration.clientValidationSource {
            normalizedSources.append(CompilerPreflightSource(
                fileName: "__DynamicSwiftBuildTargetValidation.swift",
                source: validationSource))
        }
        var keyComponents = [
            "compiler-preflight-result-v3",
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
            var physicalFileName = safePhysicalFileName(source.fileName)
            var discriminator = index + 1
            while usedPhysicalFileNames.contains(physicalFileName) {
                physicalFileName = String(
                    format: "%04d-%@", discriminator, physicalFileName)
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
            "-swift-version", configuration.swiftLanguageVersion.rawValue,
            "-strict-concurrency=" + configuration.strictConcurrency.rawValue,
            "-diagnostic-style", "llvm",
            "-sdk", configuration.sdkPath,
            "-target", configuration.targetTriple,
            "-module-cache-path", moduleCache.path,
            "-typecheck",
        ]
        if let moduleImport {
            arguments += ["-I", moduleImport.searchPath]
        }
        arguments += ["-module-name", configuration.moduleName]
        arguments += configuration.clientCompilerArguments
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

    /// Construct a target-aware interpreter whose native compiler identity,
    /// runtime gateways, and interpreted conditional compilation all come
    /// from the same build target and registry.
    public static func withActiveCompilerPreflight(
        registry: HostRegistry? = nil,
        buildTarget: CompilerPreflightBuildTarget,
        mode: CompilerPreflightMode = .required,
        timeoutSeconds: TimeInterval = 10
    ) throws -> Interpreter {
        let preflight = try SwiftCompilerPreflight.activeApple(
            buildTarget: buildTarget,
            registry: registry,
            timeoutSeconds: timeoutSeconds)
        return Interpreter(
            registry: registry,
            compilerPreflight: preflight,
            compilerPreflightMode: mode,
            buildConfiguration:
                InterpreterBuildConfiguration(buildTarget: buildTarget))
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

private func validatedLogicalFileName(_ fileName: String) throws -> String {
    if fileName.isEmpty { return "input.swift" }
    guard !fileName.hasPrefix("/"), !fileName.contains("\\"),
          !fileName.utf8.contains(0) else {
        throw CompilerPreflightError.invalidConfiguration(
            "source filename '\(fileName)' must be a safe relative path")
    }
    let components = fileName.split(
        separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
        throw CompilerPreflightError.invalidConfiguration(
            "source filename '\(fileName)' must be a safe relative path")
    }
    return fileName
}

private func safePhysicalFileName(_ fileName: String) -> String {
    let candidate = URL(fileURLWithPath: fileName).lastPathComponent
    return candidate.isEmpty ? "input.swift" : candidate
}

private func isValidCompilerIdentifier(_ name: String) -> Bool {
    guard let first = name.first,
          first == "_" || first.isASCII && first.isLetter else {
        return false
    }
    return name.dropFirst().allSatisfy {
        $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber)
    }
}

private func isValidCompilerModuleName(_ name: String) -> Bool {
    isValidCompilerIdentifier(name)
}

private func isValidCompilerModulePath(_ name: String) -> Bool {
    let components = name.split(
        separator: ".", omittingEmptySubsequences: false)
    return !components.isEmpty && components.allSatisfy {
        isValidCompilerIdentifier(String($0))
    }
}

private func isValidCompilerImportVersion(_ version: String) -> Bool {
    let components = version.split(
        separator: ".", omittingEmptySubsequences: false)
    return (1...5).contains(components.count)
        && components.allSatisfy {
            !$0.isEmpty
                && $0.allSatisfy { $0.isASCII && $0.isNumber }
                && UInt($0) != nil
        }
}

private func isAbsoluteNormalizedCompilerSearchPath(_ path: String) -> Bool {
    guard !path.isEmpty, path.hasPrefix("/"), !path.utf8.contains(0) else {
        return false
    }
    return URL(fileURLWithPath: path).standardizedFileURL.path == path
}

private func compilerPreflightSwiftVersion(
    in output: String
) -> CompilerPreflightVersion? {
    guard let markerRange = output.range(of: "Swift version ") else {
        return nil
    }
    let suffix = output[markerRange.upperBound...]
    let token = suffix.prefix { character in
        character.isASCII && (character.isNumber || character == ".")
    }
    return try? CompilerPreflightVersion(parsing: String(token))
}

private func isValidTargetArchitecture(_ architecture: String) -> Bool {
    !architecture.isEmpty && architecture.allSatisfy {
        $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber)
    }
}

private func isValidDeploymentTarget(_ deploymentTarget: String) -> Bool {
    let components = deploymentTarget.split(
        separator: ".", omittingEmptySubsequences: false)
    return (1...3).contains(components.count)
        && components.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
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
