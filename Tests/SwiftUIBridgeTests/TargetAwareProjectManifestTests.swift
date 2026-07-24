import CryptoKit
import Foundation
import SwiftInterpreter
@testable import SwiftUIBridge
import Testing

@Suite("Target-aware project manifests", .serialized)
struct TargetAwareProjectManifestTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// A live merged-source render must retain the complete selected target,
    /// not collapse macCatalyst into its shared iOS platform spelling. SDK
    /// sources use this property to choose branches before any API dispatch.
    @Test
    func liveRenderUsesCapturedTargetEnvironment() async throws {
        let target = try CompilerPreflightBuildTarget(
            moduleName: "LiveCatalystFixture",
            sdk: .macCatalyst,
            architecture: "arm64",
            deploymentTarget: "18.0",
            compilerVersion: CompilerPreflightVersion(6, 3, 3),
            swiftConditionalCompilationVersion:
                CompilerPreflightVersion(6, 3, 3),
            importableModules: ["SwiftUI"])
        let environment = LiveCheckEnvironment(
            networkPolicy: .absorbed,
            projectResourceRoot: nil,
            buildConfiguration: InterpreterBuildConfiguration(
                buildTarget: target))
        let source = """
        struct ConditionalRoot: View {
            var body: some View {
                #if targetEnvironment(macCatalyst)
                Text("selected-catalyst-environment")
                #else
                Text("selected-non-catalyst-environment")
                #endif
            }
        }
        """

        let result = try await LiveCheckSupport.render(
            source: source,
            environment: environment)

        #expect(result.strings.contains("selected-catalyst-environment"))
        #expect(!result.strings.contains("selected-non-catalyst-environment"))
    }

    /// A direct source render can carry the same immutable target projection
    /// when there is no compiler manifest. This is intentionally distinct from
    /// the legacy mutable platform canvas used by editor callers.
    @Test
    func hostRenderUsesExplicitTargetEnvironment() throws {
        let configuration = InterpreterBuildConfiguration(
            platformName: "iOS",
            targetEnvironment: "macCatalyst")
        let source = """
        struct ConditionalRoot: View {
            var body: some View {
                #if targetEnvironment(macCatalyst)
                Text("selected-catalyst-environment")
                #else
                MissingNonCatalystRoot()
                #endif
            }
        }
        ConditionalRoot()
        """

        _ = try InterpreterHost().render(
            source: source,
            buildConfiguration: configuration,
            lazyTopLevelGlobals: true).get()
    }

    @Test
    func explicitIOSSimulatorTargetSelectsConditionsAndMembership() throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try copyFixture(
            "ContentView.swift",
            to: "Sources/App/ContentView.swift",
            under: root)
        try copyFixture(
            "BuildConditions.swift",
            to: "Sources/App/BuildConditions.swift",
            under: root)
        try copyFixture(
            "SiblingInvalid.swift",
            to: "Sources/Sibling/Invalid.swift",
            under: root)
        try write(
            """
            import Foundation

            let targetResourceURL = Bundle.main.url(
                forResource: "TargetScope", withExtension: "txt")
            let targetResourceData = try! Data(contentsOf: targetResourceURL!)
            let targetResourceText = String(
                decoding: targetResourceData, as: UTF8.self)
            """,
            to: "Sources/App/ResourceProbe.swift",
            under: root)
        try write(
            "scoped-project-resource",
            to: "Resources/TargetScope.txt",
            under: root)

        let target = try CompilerPreflightBuildTarget(
            moduleName: "TargetAwareFixture",
            sdk: .iOSSimulator,
            architecture: "arm64",
            deploymentTarget: "18.0",
            compilerVersion: CompilerPreflightVersion(6, 3, 3),
            swiftConditionalCompilationVersion:
                CompilerPreflightVersion(6, 3, 3),
            importableModules: ["SwiftUI"],
            versionedImportQueries: [
                try CompilerPreflightVersionedImportQuery(
                    moduleName: "SwiftUI",
                    versionKind: .user,
                    version: "9999.0",
                    isImportable: true),
                try CompilerPreflightVersionedImportQuery(
                    moduleName: "DefinitelyMissingModule",
                    versionKind: .user,
                    version: "1.0",
                    isImportable: false),
            ],
            conditionalCompilationQueries: [
                try CompilerPreflightConditionalCompilationQuery(
                    predicate: .hasFeature,
                    argument: "StrictConcurrency",
                    isActive: true),
                try CompilerPreflightConditionalCompilationQuery(
                    predicate: .hasAttribute,
                    argument: "preconcurrency",
                    isActive: true),
                try CompilerPreflightConditionalCompilationQuery(
                    predicate: .objectFormat,
                    argument: "MachO",
                    isActive: true),
                try CompilerPreflightConditionalCompilationQuery(
                    predicate: .endian,
                    argument: "little",
                    isActive: true),
                try CompilerPreflightConditionalCompilationQuery(
                    predicate: .runtime,
                    argument: "_ObjC",
                    isActive: true),
            ],
            defaultIsolation: .mainActor,
            activeCompilationConditions: ["DEBUG"])
        #expect(target.targetTriple == "arm64-apple-ios18.0-simulator")
        #expect(target.swiftConditionalCompilationVersion
            == CompilerPreflightVersion(6, 3, 3))
        #expect(target.clientCompilerArguments == [
            "-default-isolation", "MainActor", "-D", "DEBUG",
        ])
        let previousLegacyPlatform = Interpreter.interpretsAsPlatform
        Interpreter.interpretsAsPlatform = "macOS"
        let targetEnvironmentValues = InterpretedEnvironment.defaults(
            platformName:
                InterpreterBuildConfiguration(buildTarget: target).platformName)
        Interpreter.interpretsAsPlatform = previousLegacyPlatform
        guard case .implicitMember(let targetSizeClass)? =
                targetEnvironmentValues["horizontalSizeClass"]
        else {
            Issue.record("target-aware environment omitted horizontal size")
            return
        }
        #expect(targetSizeClass == "compact")
        let project = try ProjectMaterial.buildManifest(
            at: root.path,
            files: [
                "Sources/App/ContentView.swift",
                "Sources/App/BuildConditions.swift",
                "Sources/App/ResourceProbe.swift",
            ],
            buildTarget: target)

        #expect(project.buildTarget == target)
        #expect(project.sources.map(\.fileName) == [
            "Sources/App/ContentView.swift",
            "Sources/App/BuildConditions.swift",
            "Sources/App/ResourceProbe.swift",
        ])
        #expect(project.sources[0].source.contains("import SwiftUI"))
        #expect(!project.sources.contains {
            $0.fileName == "Sources/Sibling/Invalid.swift"
        })
        let runtimeSource = ProjectMaterial.mergedSource(for: project)
        #expect(runtimeSource.contains(
            "// FILE: Sources/App/ContentView.swift"))
        #expect(runtimeSource.contains(
            "// FILE: Sources/App/BuildConditions.swift"))
        #expect(runtimeSource.contains(
            "// FILE: Sources/App/ResourceProbe.swift"))
        #expect(!runtimeSource.contains("\nimport SwiftUI\n"))
        #expect(!runtimeSource.contains("invalid sibling target"))
        #expect(project.fingerprint.count == 64)

        // This is the behavioral RED that existed before the manifest entry:
        // the public source facade checks the exact same projection as macOS,
        // selecting the wrong os/environment branches.
        let targetBlindOutcome = InterpreterHost(
            compilerPreflightMode: .required
        ).render(source: runtimeSource, lazyTopLevelGlobals: true)
        guard case .failure(let targetBlindError) = targetBlindOutcome else {
            Issue.record("target-blind project path unexpectedly checked as iOS")
            return
        }
        #expect(targetBlindError.message.contains("BuildConditions.swift"))
        #expect(targetBlindError.message.contains(
            "cannot convert value of type 'String' to specified type 'Int'"))

        let registry = ViewRegistry()
        let preflight = try SwiftCompilerPreflight.activeApple(
            buildTarget: target,
            registry: registry)
        #expect(preflight.configuration.targetTriple
            == "arm64-apple-ios18.0-simulator")
        #expect(preflight.configuration.deploymentTarget == "18.0")
        #expect(preflight.configuration.moduleName == "TargetAwareFixture")
        #expect(preflight.configuration.clientCompilerArguments
            == ["-default-isolation", "MainActor", "-D", "DEBUG"])
        #expect(preflight.configuration.additionalCompilerArguments.isEmpty)
        let preflightResult = try preflight.preflight(sources: project.sources)
        #expect(preflightResult.succeeded,
            Comment(rawValue: preflightResult.standardError))

        let compatibilityRoot = BundleBox.projectResourceRoot
        let outcome = InterpreterHost(compilerPreflightMode: .required)
            .render(project: project, lazyTopLevelGlobals: false)
        if case .failure(let error) = outcome {
            Issue.record("target-aware positive project failed: \(error)")
        }
        #expect(InterpreterHost.lastInterpreter?.globals
            .lookup("targetResourceText")?.stringValue
            == "scoped-project-resource")
        #expect(BundleBox.projectResourceRoot == compatibilityRoot)
    }

    @Test
    func unrecordedCompilerConditionalFailsClosedBeforeMutation() throws {
        let target = try CompilerPreflightBuildTarget(
            moduleName: "MissingConditionalAnswerFixture",
            sdk: .iOSSimulator,
            architecture: "arm64",
            deploymentTarget: "18.0",
            compilerVersion: CompilerPreflightVersion(6, 3, 3),
            swiftConditionalCompilationVersion:
                CompilerPreflightVersion(6, 3, 3),
            importableModules: [])
        let project = try ProjectBuildManifest(
            projectRoot: "/MissingConditionalAnswerFixture",
            buildTarget: target,
            sources: [CompilerPreflightSource(
                fileName: "Sources/Conditional.swift",
                source: """
                #if hasFeature(StrictConcurrency)
                let selectedFeatureBranch = 1
                #else
                let selectedFeatureBranch: Int = "native-inactive branch"
                #endif

                func markConditionalMutation() -> Int {
                    fatalError("CONDITIONAL_MUTATION_EXECUTED")
                }
                let conditionalMutation = markConditionalMutation()
                """)])

        let outcome = InterpreterHost(compilerPreflightMode: .required)
            .render(project: project, lazyTopLevelGlobals: false)
        guard case .failure(let error) = outcome else {
            Issue.record("unrecorded compiler-owned condition was guessed")
            return
        }
        #expect(error.message.contains(
            "target manifest has no authoritative answer for "
                + "hasFeature(StrictConcurrency)"))
        #expect(!error.message.contains("CONDITIONAL_MUTATION_EXECUTED"))
    }

    @Test
    func requiredRenderRejectsPinnedTaskGroupEscapeBeforeTopLevelMutation()
        throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let pinnedFixture = Self.packageRoot.appendingPathComponent(
            "Tests/SwiftUpstream/Fixtures/Concurrency/"
                + "taskgroup_cancelAll_from_child.swift")
        let pinnedData = try Data(contentsOf: pinnedFixture)
        let pinnedSHA256 = SHA256.hash(data: pinnedData).map {
            String(format: "%02x", $0)
        }.joined()
        #expect(pinnedSHA256
            == "a358a89ab3623a36034a1c6c89a3ad33d13c100ba7c49cb4ce7edca7c757fb2a")
        try write(
            pinnedData,
            to: "Sources/App/Concurrency/TaskGroupEscape.swift",
            under: root)
        try write(
            """
            func markSourceTopLevelMutation() -> Int {
                fatalError("SOURCE_TOP_LEVEL_MUTATION_EXECUTED")
            }

            let sourceTopLevelMutation = markSourceTopLevelMutation()
            """,
            to: "Sources/App/MutationSentinel.swift",
            under: root)

        let target = try CompilerPreflightBuildTarget(
            moduleName: "TaskGroupEscapeFixture",
            sdk: .iOSSimulator,
            architecture: "arm64",
            deploymentTarget: "18.0",
            compilerVersion: CompilerPreflightVersion(6, 3, 3),
            swiftConditionalCompilationVersion:
                CompilerPreflightVersion(6, 3, 3),
            importableModules: [],
            activeCompilationConditions: ["DEBUG"])
        let project = try ProjectMaterial.buildManifest(
            at: root.path,
            files: [
                "Sources/App/Concurrency/TaskGroupEscape.swift",
                "Sources/App/MutationSentinel.swift",
            ],
            buildTarget: target)

        let outcome = InterpreterHost(compilerPreflightMode: .required)
            .render(project: project, lazyTopLevelGlobals: false)
        guard case .failure(let error) = outcome else {
            Issue.record("required project render accepted an escaping TaskGroup")
            return
        }

        #expect(error.message.contains(
            "Sources/App/Concurrency/TaskGroupEscape.swift:18:10"))
        #expect(error.message.contains(
            "Sources/App/Concurrency/TaskGroupEscape.swift:25:10"))
        #expect(error.message.contains(
            "capture of 'group' with non-Sendable type 'TaskGroup<Int>' "
                + "in a '@Sendable' closure"))
        #expect(error.message.contains(
            "mutable capture of 'inout' parameter 'group' is not allowed "
                + "in concurrently-executing code"))
        #expect(!error.message.contains("SOURCE_TOP_LEVEL_MUTATION_EXECUTED"))
    }

    @Test
    func manifestFingerprintBindsTargetPathsAndExactSourceBytes() throws {
        let baseTarget = try CompilerPreflightBuildTarget(
            moduleName: "FingerprintFixture",
            sdk: .iOSSimulator,
            architecture: "arm64",
            deploymentTarget: "18.0",
            compilerVersion: CompilerPreflightVersion(6, 3, 3),
            swiftConditionalCompilationVersion:
                CompilerPreflightVersion(6, 3, 3),
            importableModules: [],
            activeCompilationConditions: ["DEBUG"],
            importSearchPaths: ["/tmp/TargetAwareModules"])
        let changedTarget = try CompilerPreflightBuildTarget(
            moduleName: "FingerprintFixture",
            sdk: .iOSSimulator,
            architecture: "arm64",
            deploymentTarget: "18.1",
            compilerVersion: CompilerPreflightVersion(6, 3, 3),
            swiftConditionalCompilationVersion:
                CompilerPreflightVersion(6, 3, 3),
            importableModules: [],
            activeCompilationConditions: ["DEBUG"],
            importSearchPaths: ["/tmp/TargetAwareModules"])
        let changedConditionalAnswerTarget = try CompilerPreflightBuildTarget(
            moduleName: "FingerprintFixture",
            sdk: .iOSSimulator,
            architecture: "arm64",
            deploymentTarget: "18.0",
            compilerVersion: CompilerPreflightVersion(6, 3, 3),
            swiftConditionalCompilationVersion:
                CompilerPreflightVersion(6, 3, 3),
            importableModules: [],
            conditionalCompilationQueries: [
                try CompilerPreflightConditionalCompilationQuery(
                    predicate: .hasFeature,
                    argument: "StrictConcurrency",
                    isActive: true),
            ],
            activeCompilationConditions: ["DEBUG"],
            importSearchPaths: ["/tmp/TargetAwareModules"])
        let first = try ProjectBuildManifest(
            projectRoot: "/TargetAwareProject",
            buildTarget: baseTarget,
            sources: [
                CompilerPreflightSource(
                    fileName: "Sources/A.swift", source: "let a = 1"),
                CompilerPreflightSource(
                    fileName: "Sources/B.swift", source: "let b = 2"),
            ])
        let identical = try ProjectBuildManifest(
            projectRoot: "/TargetAwareProject",
            buildTarget: baseTarget,
            sources: first.sources)
        let reordered = try ProjectBuildManifest(
            projectRoot: "/TargetAwareProject",
            buildTarget: baseTarget,
            sources: Array(first.sources.reversed()))
        let changedSource = try ProjectBuildManifest(
            projectRoot: "/TargetAwareProject",
            buildTarget: baseTarget,
            sources: [
                first.sources[0],
                CompilerPreflightSource(
                    fileName: "Sources/B.swift", source: "let b = 3"),
            ])
        let changedBuildTarget = try ProjectBuildManifest(
            projectRoot: "/TargetAwareProject",
            buildTarget: changedTarget,
            sources: first.sources)
        let changedConditionalAnswer = try ProjectBuildManifest(
            projectRoot: "/TargetAwareProject",
            buildTarget: changedConditionalAnswerTarget,
            sources: first.sources)
        let changedProjectRoot = try ProjectBuildManifest(
            projectRoot: "/OtherTargetAwareProject",
            buildTarget: baseTarget,
            sources: first.sources)

        #expect(first.fingerprint == identical.fingerprint)
        #expect(first.fingerprint != reordered.fingerprint)
        #expect(first.fingerprint != changedSource.fingerprint)
        #expect(first.fingerprint != changedBuildTarget.fingerprint)
        #expect(first.fingerprint != changedConditionalAnswer.fingerprint)
        #expect(first.fingerprint != changedProjectRoot.fingerprint)

        do {
            _ = try ProjectBuildManifest(
                projectRoot: "/TargetAwareProject",
                buildTarget: baseTarget,
                sources: [CompilerPreflightSource(
                    fileName: "../Escaped.swift", source: "let value = 1")])
            Issue.record("unsafe project-relative source path was accepted")
        } catch ProjectBuildManifestError.invalidLogicalPath(let path) {
            #expect(path == "../Escaped.swift")
        }

        do {
            _ = try ProjectBuildManifest(
                projectRoot: "/TargetAwareProject",
                buildTarget: baseTarget,
                sources: [
                    CompilerPreflightSource(
                        fileName: "Sources/Value.swift", source: "let a = 1"),
                    CompilerPreflightSource(
                        fileName: "sources/value.swift", source: "let b = 2"),
                ])
            Issue.record("case-colliding logical source paths were accepted")
        } catch ProjectBuildManifestError.duplicateLogicalPath(let path) {
            #expect(path == "sources/value.swift")
        }

        #expect(throws: ProjectBuildManifestError.self) {
            _ = try ProjectBuildManifest(
                projectRoot: "relative/project",
                buildTarget: baseTarget,
                sources: first.sources)
        }
        let canonicalRoot = try temporaryProjectRoot()
        let symlinkRoot = canonicalRoot.deletingLastPathComponent()
            .appendingPathComponent(
                "target-aware-project-link-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: symlinkRoot)
            try? FileManager.default.removeItem(at: canonicalRoot)
        }
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot, withDestinationURL: canonicalRoot)
        #expect(throws: ProjectBuildManifestError.self) {
            _ = try ProjectBuildManifest(
                projectRoot: symlinkRoot.path,
                buildTarget: baseTarget,
                sources: first.sources)
        }
        #expect(throws: CompilerPreflightError.self) {
            _ = try CompilerPreflightBuildTarget(
                moduleName: "RelativeSearchPath",
                sdk: .iOSSimulator,
                architecture: "arm64",
                deploymentTarget: "18.0",
                compilerVersion: CompilerPreflightVersion(6, 3, 3),
                swiftConditionalCompilationVersion:
                    CompilerPreflightVersion(6, 3, 3),
                importableModules: [],
                importSearchPaths: [".build/modules"])
        }
        #expect(throws: CompilerPreflightError.self) {
            _ = try CompilerPreflightVersion(parsing: "６.3.3")
        }
        #expect(throws: CompilerPreflightError.self) {
            _ = try CompilerPreflightVersion(
                parsing: "999999999999999999999999999999.0")
        }
        #expect(throws: CompilerPreflightError.self) {
            _ = try CompilerPreflightBuildTarget(
                moduleName: "InconsistentImportFixture",
                sdk: .iOSSimulator,
                architecture: "arm64",
                deploymentTarget: "18.0",
                compilerVersion: CompilerPreflightVersion(6, 3, 3),
                swiftConditionalCompilationVersion:
                    CompilerPreflightVersion(6, 3, 3),
                importableModules: [],
                versionedImportQueries: [
                    try CompilerPreflightVersionedImportQuery(
                        moduleName: "SwiftUI",
                        versionKind: .user,
                        version: "1.0",
                        isImportable: true),
                ])
        }

        let catalyst = try CompilerPreflightBuildTarget(
            moduleName: "CatalystFixture",
            sdk: .macCatalyst,
            architecture: "arm64",
            deploymentTarget: "18.0",
            compilerVersion: CompilerPreflightVersion(6, 3, 3),
            swiftConditionalCompilationVersion:
                CompilerPreflightVersion(6, 3, 3),
            importableModules: ["SwiftUI", "UIKit"])
        #expect(catalyst.targetTriple == "arm64-apple-ios18.0-macabi")
        #expect(catalyst.sdk.xcrunIdentifier == "macosx")
        #expect(catalyst.sdk.platformName == "iOS")
        #expect(catalyst.sdk.targetEnvironment == "macCatalyst")
    }

    private func temporaryProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "target-aware-project-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(
        _ source: String,
        to relativePath: String,
        under root: URL
    ) throws {
        try write(Data(source.utf8), to: relativePath, under: root)
    }

    private func write(
        _ data: Data,
        to relativePath: String,
        under root: URL
    ) throws {
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: destination)
    }

    private func copyFixture(
        _ name: String,
        to relativePath: String,
        under root: URL
    ) throws {
        let fixture = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/TargetAwareProject/\(name)")
        let data = try Data(contentsOf: fixture)
        let expectedSHA256 = [
            "BuildConditions.swift":
                "60d7327f6b650ffb4bf4f4cab031973e89000d229a02dfe472f68edc958264bf",
            "ContentView.swift":
                "4a2cbb270a631e5192b786677a4a6126ab3f241c182284424f2f23041cfee68b",
            "SiblingInvalid.swift":
                "408eb3adbe5132742feea527be1a973eece6024d479b4af06a453af40f073ea5",
        ]
        let actualSHA256 = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        #expect(actualSHA256 == expectedSHA256[name])
        try write(data, to: relativePath, under: root)
    }
}
