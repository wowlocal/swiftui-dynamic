import Darwin
import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Compiler-backed concurrency preflight", .serialized)
struct CompilerPreflightTests {
    @Test
    func requiredModeRejectsNativeDiagnosticBeforeInterpreterMutation()
        async throws {
        let engine = try Self.activePreflight()
        let interpreter = Interpreter(compilerPreflight: engine)
        let source = try Self.fixture("actor-isolation-diagnostic.swift")

        do {
            _ = try await interpreter.runAsync(source: source)
            Issue.record("actor-isolation violation unexpectedly executed")
        } catch let rejection as CompilerPreflightRejection {
            #expect(!rejection.result.succeeded)
            #expect(rejection.result.diagnostics.contains {
                $0.severity == .error
                    && $0.file == "input.swift"
                    && $0.line == 6
                    && $0.message.contains("actor-isolated property")
                    && $0.message.contains("nonisolated context")
            })
        }

        #expect(interpreter.lastCompilerPreflightResult?.succeeded == false)
        #expect(interpreter.globals.lookup("Counter") == nil)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func requiredModeRejectsExternalActorComputedSetterBeforeMutation()
        async throws
    {
        let engine = try Self.activePreflight()
        let interpreter = Interpreter(compilerPreflight: engine)
        let source = try Self.fixture(
            "actor-computed-setter-diagnostic.swift")

        do {
            _ = try await interpreter.runAsync(source: source)
            Issue.record(
                "external actor computed setter unexpectedly executed")
        } catch let rejection as CompilerPreflightRejection {
            #expect(!rejection.result.succeeded)
            #expect(rejection.result.diagnostics.contains {
                $0.severity == .error
                    && $0.file == "input.swift"
                    && $0.line == 9
                    && $0.message.contains("actor-isolated property")
                    && $0.message.contains(
                        "can not be mutated from a nonisolated context")
            })
        }

        #expect(interpreter.lastCompilerPreflightResult?.succeeded == false)
        #expect(interpreter.globals.lookup("ComputedSetterCounter") == nil)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func requiredModeRejectsExternalActorSubscriptSetterBeforeMutation()
        async throws
    {
        let engine = try Self.activePreflight()
        let interpreter = Interpreter(compilerPreflight: engine)
        let source = try Self.fixture(
            "actor-subscript-setter-diagnostic.swift")

        do {
            _ = try await interpreter.runAsync(source: source)
            Issue.record(
                "external actor subscript setter unexpectedly executed")
        } catch let rejection as CompilerPreflightRejection {
            #expect(!rejection.result.succeeded)
            #expect(rejection.result.diagnostics.contains {
                $0.severity == .error
                    && $0.file == "input.swift"
                    && $0.line == 9
                    && $0.message.contains("actor-isolated subscript")
                    && $0.message.contains(
                        "can not be mutated from a nonisolated context")
            })
        }

        #expect(interpreter.lastCompilerPreflightResult?.succeeded == false)
        #expect(interpreter.globals.lookup("SubscriptSetterCounter") == nil)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func diagnosticsOnlyModeRetainsErrorsAndAllowsEditorRecovery() throws {
        let engine = try Self.activePreflight()
        let interpreter = Interpreter(
            compilerPreflight: engine,
            compilerPreflightMode: .diagnosticsOnly)
        let source = try Self.fixture("actor-isolation-diagnostic.swift")

        _ = try interpreter.run(source: source)

        #expect(interpreter.lastCompilerPreflightResult?.succeeded == false)
        let retainedDiagnostic = interpreter.lastCompilerPreflightResult?
            .diagnostics.contains {
            $0.severity == .error && $0.line == 6
        }
        #expect(retainedDiagnostic == true)
        #expect(interpreter.globals.lookup("Counter") != nil)
    }

    @Test
    func throwingPropertyFixtureMatchesProductionPreflight() throws {
        let source = try Self.fixture(
            "throwing-property-missing-try-diagnostic.swift")
        let result = try Self.activePreflight().preflight(
            source: source,
            fileName: "throwing-property-missing-try-diagnostic.swift")

        #expect(!result.succeeded)
        #expect(result.diagnostics.contains {
            $0.file == "throwing-property-missing-try-diagnostic.swift"
                && $0.line == 8
                && $0.message.contains("property access can throw")
                && $0.message.contains("try")
        }, Comment(rawValue: result.standardError))
    }

    @Test
    func legalProgramExecutesAndRepeatedPreflightUsesCache() throws {
        let engine = try Self.activePreflight()
        let source = """
        func add(_ lhs: Int, _ rhs: Int) -> Int { lhs + rhs }
        add(20, 22)
        """

        let first = try engine.preflight(source: source)
        let second = try engine.preflight(source: source)
        #expect(first.succeeded)
        #expect(!first.wasCached)
        #expect(second.succeeded)
        #expect(second.wasCached)
        #expect(first.cacheKey == second.cacheKey)

        let interpreter = Interpreter(compilerPreflight: engine)
        let value = try interpreter.run(source: source)
        #expect(value.intValue == 42)
        #expect(interpreter.lastCompilerPreflightResult?.wasCached == true)
    }

    @Test
    func publicConcurrencyTestingJobHookTypechecksButRemainsDeferred() throws {
        let result = try Self.activePreflight().preflight(source: """
        import _Concurrency

        @available(macOS 26.4, *)
        func makeTestingJob() -> ExecutorJob {
            _swift_createJobForTestingOnly {}
        }
        """)

        #expect(result.succeeded, Comment(rawValue: result.standardError))
    }

    @Test
    func publicContinuationEntryPointsTypecheckForAuthoredRuntimeDisposition()
        throws {
        let source = try Self.fixture("continuation-entry-points.swift")
        let result = try Self.activePreflight().preflight(
            source: source,
            fileName: "continuation-entry-points.swift")

        #expect(result.succeeded, Comment(rawValue: result.standardError))
    }

    @Test
    func continuationVoidResumeConstraintRejectsNonVoidSuccess() throws {
        let result = try Self.activePreflight().preflight(source: """
        nonisolated func invalidContinuationVoidResume() async -> Int {
            await withCheckedContinuation(
                isolation: nil
            ) { (continuation: CheckedContinuation<Int, Never>) in
                continuation.resume()
            }
        }
        """)

        #expect(!result.succeeded)
        #expect(result.diagnostics.contains {
            $0.severity == .error
                && $0.message.contains(
                    "resume()' requires the types 'Int' and '()' be equivalent")
        }, Comment(rawValue: result.standardError))
    }

    @Test
    func continuationResultResumeRejectsNonResultArgument() throws {
        let result = try Self.activePreflight().preflight(source: """
        nonisolated func invalidContinuationResultResume() async throws -> Int {
            try await withCheckedThrowingContinuation(
                isolation: nil
            ) { (continuation: CheckedContinuation<Int, any Error>) in
                continuation.resume(with: 1)
            }
        }
        """)

        #expect(!result.succeeded)
        #expect(result.diagnostics.contains {
            $0.severity == .error
                && $0.message.contains(
                    "cannot convert value of type 'Int' to expected argument "
                        + "type 'Result<Int, any Error>'")
        }, Comment(rawValue: result.standardError))
    }

    @Test
    func continuationResultResumeSpellingsTypecheck() throws {
        let source = try Self.fixture(
            "checked-continuation-result-spellings.swift")
        let result = try Self.activePreflight().preflight(
            source: source,
            fileName: "checked-continuation-result-spellings.swift")

        #expect(result.succeeded, Comment(rawValue: result.standardError))
    }

    @Test
    func multiFilePreflightPreservesFileScopedPrivateDeclarations() throws {
        let engine = try Self.activePreflight()
        let sources = try [
            "MultiFilePrivateFirst.swift",
            "MultiFilePrivateSecond.swift",
            "MultiFilePrivateMain.swift",
        ].map {
            CompilerPreflightSource(
                fileName: $0,
                source: try Self.compilerPreflightFixture($0))
        }

        let incorrectlyMerged = try engine.preflight(
            source: sources.map(\.source).joined(separator: "\n"))
        #expect(!incorrectlyMerged.succeeded)
        #expect(incorrectlyMerged.diagnostics.contains {
            $0.severity == .error
                && $0.message.contains("invalid redeclaration")
        })

        let first = try engine.preflight(sources: sources)
        let repeated = try engine.preflight(sources: sources)
        let reordered = try engine.preflight(
            sources: Array(sources.reversed()))
        #expect(first.succeeded)
        #expect(!first.wasCached)
        #expect(repeated.succeeded)
        #expect(repeated.wasCached)
        #expect(first.cacheKey == repeated.cacheKey)
        #expect(reordered.succeeded)
        #expect(!reordered.wasCached)
        #expect(reordered.cacheKey != first.cacheKey)
    }

    @Test
    func multiFileDiagnosticsRetainTheirLogicalFile() throws {
        let engine = try Self.activePreflight()
        let result = try engine.preflight(sources: [
            CompilerPreflightSource(
                fileName: "Valid.swift",
                source: "func valid() {}"),
            CompilerPreflightSource(
                fileName: "Invalid.swift",
                source: """
                @MainActor func update() {}
                func invalidCall() {
                    update()
                }
                """),
        ])

        #expect(!result.succeeded)
        #expect(result.diagnostics.contains {
            $0.severity == .error
                && $0.file == "Invalid.swift"
                && $0.line == 3
                && $0.message.contains("main actor-isolated global function")
        })
    }

    @Test
    func generatedHostModuleParticipatesInIsolationChecking() throws {
        let source = try Self.upstreamFixture(
            "Concurrency/Inputs/GlobalActorIsolatedFunction.swift")
        let module = CompilerPreflightHostModule(
            moduleName: "GlobalActorIsolatedFunction",
            source: source)
        #expect(module.sourceSHA256
            == "5f40cc13f4a2b131698ef5e05b7245cb3425ac96985f232fbf05a429fa0d2d24")
        let engine = try SwiftCompilerPreflight.activeMacOS(
            hostModule: module)
        let result = try engine.preflight(
            source: try Self.upstreamClient(
                "host-module-mainactor-diagnostic.swift"),
            fileName: "host-module-mainactor-diagnostic.swift")

        #expect(!result.succeeded)
        #expect(result.diagnostics.contains {
            $0.file == "host-module-mainactor-diagnostic.swift"
                && $0.line == 4
                && $0.message.contains("main actor-isolated global function")
                && $0.message.contains("nonisolated context")
        })

        let legal = try engine.preflight(source: """
        @MainActor
        func validCrossModuleCall() {
            mainActorFunction()
        }
        """)
        #expect(legal.succeeded)

        let script = try engine.preflight(
            source: """
            #!/usr/bin/env swift
            @MainActor
            func validScriptCall() {
                mainActorFunction()
            }
            validScriptCall()
            """,
            fileName: "valid-script.swift")
        #expect(script.succeeded)
        #expect(engine.hostModuleCompilationCount == 1)
    }

    @Test
    func registryManifestAndRuntimeGatewayStayBoundEndToEnd() throws {
        let moduleSource = try Self.upstreamFixture(
            "Concurrency/Inputs/GlobalActorIsolatedFunction.swift")
        let registry = try PreflightHostRegistry(moduleSource: moduleSource)
        let interpreter = try Interpreter.withActiveCompilerPreflight(
            registry: registry)
        let value = try interpreter.run(source: """
        @MainActor
        func validCrossModuleCall() -> Int {
            mainActorFunction()
            return 42
        }
        validCrossModuleCall()
        """)

        #expect(value.intValue == 42)
        #expect(registry.invocationCount == 1)
        #expect(interpreter.compilerPreflight?.hostModule
            == registry.compilerPreflightHostModule)
        #expect(interpreter.compilerPreflight?.configuration
            .gatewayManifestSHA256
            == registry.compilerPreflightHostModule?.manifestSHA256)
    }

    @Test
    func typedSyntheticAsyncGatewayParticipatesInNativeCheckingAndExecution()
        async throws {
        let diagnosticSource = try Self.compilerPreflightFixture(
            "SyntheticAsyncHostMissingAwait.swift")
        let oracleModule = CompilerPreflightHostModule(
            moduleName: CompilerPreflightHostModule.defaultSyntheticModuleName,
            source: try Self.compilerPreflightFixture(
                "SyntheticAsyncHostModule.swift"))
        #expect(oracleModule.sourceSHA256
            == "8713f01522c861608a23268fa9dd2ffd85a7ddc15766f3c64d1ba2645f7b0857")
        let oracle = try SwiftCompilerPreflight.activeMacOS(
            hostModule: oracleModule)
        let nativeDiagnostic = try oracle.preflight(
            source: diagnosticSource,
            fileName: "SyntheticAsyncHostMissingAwait.swift")
        #expect(!nativeDiagnostic.succeeded)
        #expect(nativeDiagnostic.diagnostics.contains {
            $0.file == "SyntheticAsyncHostMissingAwait.swift"
                && $0.line == 4
                && $0.message.contains("async")
                && $0.message.contains("does not support concurrency")
        })

        let registry = try SyntheticAsyncHostRegistry()
        let interpreter = try Interpreter.withActiveCompilerPreflight(
            registry: registry)
        let diagnostic = try interpreter.preflight(
            source: diagnosticSource,
            fileName: "SyntheticAsyncHostMissingAwait.swift")

        #expect(!diagnostic.succeeded)
        #expect(diagnostic.diagnostics.contains {
            $0.file == "SyntheticAsyncHostMissingAwait.swift"
                && $0.line == 4
                && $0.message.contains("async")
                && !$0.message.contains("cannot find")
        })

        let value = try await interpreter.runAsync(source: """
        import DynamicSwiftHostSurface

        func readSyntheticHost() async -> Int {
            await syntheticAsyncValue()
        }
        await readSyntheticHost()
        """)
        #expect(value.intValue == 42)
        #expect(registry.invocationCount == 1)
        #expect(interpreter.compilerPreflight?.hostModule?.moduleName
            == CompilerPreflightHostModule.defaultSyntheticModuleName)
        #expect(interpreter.compilerPreflight?.hostModule?.source.contains(
            "public func syntheticAsyncValue() async -> Int") == true)
        #expect(interpreter.compilerPreflight?.configuration
            .gatewayManifestSHA256
            == interpreter.compilerPreflight?.hostModule?.manifestSHA256)
    }

    @Test
    func syntheticSignatureModuleCompositionIsDeterministicAndFailClosed()
        throws {
        let base = CompilerPreflightHostModule(
            moduleName: "ComposedHostSurface",
            source: "@_exported import Foundation\n",
            compilerArguments: ["-D", "COMPOSED_HOST"])
        let integer = try HostSignature(
            parsing: "func syntheticIdentity(_ value: Int) -> Int")
        let string = try HostSignature(
            parsing: "func syntheticIdentity(_ value: String) async throws -> String")

        let composed = try CompilerPreflightHostModule.composing(
            base: base,
            syntheticSignatures: [string, integer, integer])
        let reorderedComposition = try CompilerPreflightHostModule.composing(
            base: base,
            syntheticSignatures: [integer, string])
        let first = try #require(composed)
        let reordered = try #require(reorderedComposition)

        #expect(first == reordered)
        #expect(first.moduleName == base.moduleName)
        #expect(first.compilerArguments == base.compilerArguments)
        #expect(first.source.hasPrefix(base.source))
        #expect(first.source.components(separatedBy:
            "public func syntheticIdentity(_ value: Int) -> Int"
        ).count == 2)
        #expect(first.source.contains(
            "public func syntheticIdentity(_ value: String) async throws -> String"))

        let member = try HostSignature(
            parsing: "@MainActor func String.syntheticMember() -> Int")
        let memberCompositionResult = try CompilerPreflightHostModule.composing(
            base: base,
            syntheticSignatures: [member])
        let memberComposition = try #require(memberCompositionResult)
        #expect(memberComposition.source.contains("extension String"))
        #expect(memberComposition.source.contains(
            "@MainActor public func syntheticMember() -> Int"))

        let property = try HostSignature(parsing:
            "@MainActor static var String.syntheticValue: Int { get set }")
        let propertyCompositionResult = try CompilerPreflightHostModule.composing(
            base: base,
            syntheticSignatures: [property])
        let propertyComposition = try #require(propertyCompositionResult)
        #expect(propertyComposition.source.contains(
            "@MainActor static public var syntheticValue: Int"))
        #expect(propertyComposition.source.contains("get {"))
        #expect(propertyComposition.source.contains("set {"))

        let typedThrowingProperty = try HostSignature(parsing:
            "var String.typedThrowingValue: Int { get throws(SyntheticFailure) }")
        let typedThrowingBase = CompilerPreflightHostModule(
            moduleName: "TypedThrowingHostSurface",
            source: "public enum SyntheticFailure: Error { case failed }\n")
        let typedThrowingCompositionResult = try CompilerPreflightHostModule
            .composing(
                base: typedThrowingBase,
                syntheticSignatures: [typedThrowingProperty])
        let typedThrowingComposition = try #require(
            typedThrowingCompositionResult)
        #expect(typedThrowingComposition.source.contains(
            "get throws(SyntheticFailure) {"))
        let typedThrowingPreflight = try SwiftCompilerPreflight.activeMacOS(
            hostModule: typedThrowingComposition)
        let legalTypedThrowingRead = try typedThrowingPreflight.preflight(
            source: """
            func readTypedThrowingValue() throws(SyntheticFailure) -> Int {
                try "swift".typedThrowingValue
            }
            """,
            fileName: "TypedThrowingProperty.swift")
        #expect(legalTypedThrowingRead.succeeded,
            Comment(rawValue: legalTypedThrowingRead.standardError))

        let initializer = try HostSignature(
            parsing: "@MainActor init String(syntheticValue: Int)")
        let initializerCompositionResult = try CompilerPreflightHostModule
            .composing(
                base: base,
                syntheticSignatures: [initializer])
        let initializerComposition = try #require(initializerCompositionResult)
        #expect(initializerComposition.source.contains(
            "@MainActor public init(syntheticValue: Int)"))
        let initializerPreflight = try SwiftCompilerPreflight.activeMacOS(
            hostModule: initializerComposition)
        let legalInitializer = try initializerPreflight.preflight(source: """
        @MainActor
        func makeSyntheticString() {
            _ = String(syntheticValue: 1)
        }
        """, fileName: "SyntheticMemberInitializer.swift")
        #expect(legalInitializer.succeeded,
            Comment(rawValue: legalInitializer.standardError))

        let privateFunction = try HostSignature(
            parsing: "private func hiddenSyntheticValue() -> Int")
        #expect(throws: CompilerPreflightError.self) {
            _ = try CompilerPreflightHostModule.composing(
                base: base,
                syntheticSignatures: [privateFunction])
        }
        let privateMember = try HostSignature(
            parsing: "private func String.hiddenSyntheticValue() -> Int")
        #expect(throws: CompilerPreflightError.self) {
            _ = try CompilerPreflightHostModule.composing(
                base: base,
                syntheticSignatures: [privateMember])
        }
    }

    @Test
    func syntheticNominalTypeCompositionIsDeterministicAndFailClosed()
        throws {
        let base = CompilerPreflightHostModule(
            moduleName: "SyntheticNominalTypes",
            source: "@_exported import Foundation\n")
        let isolated = try CompilerPreflightHostType(
            parsing: "@MainActor struct ImportedStruct {}")
        let counter = try CompilerPreflightHostType(
            parsing: "@MainActor final class SyntheticCounterBox {}")
        let initializer = try HostSignature(
            parsing: "init SyntheticCounterBox()")
        let property = try HostSignature(
            parsing: "var SyntheticCounterBox.value: Int { get set }")

        let firstResult = try CompilerPreflightHostModule.composing(
            base: base,
            syntheticTypes: [counter, isolated, isolated],
            syntheticSignatures: [property, initializer, property])
        let reorderedResult = try CompilerPreflightHostModule.composing(
            base: base,
            syntheticTypes: [isolated, counter],
            syntheticSignatures: [initializer, property])
        let first = try #require(firstResult)
        let reordered = try #require(reorderedResult)

        #expect(first == reordered)
        #expect(isolated.kind == .structure)
        #expect(isolated.attributes == ["@MainActor"])
        #expect(counter.kind == .class)
        #expect(counter.modifiers == ["final"])
        #expect(first.source.contains(
            "@MainActor public struct ImportedStruct"))
        #expect(first.source.contains(
            "@MainActor public final class SyntheticCounterBox"))
        #expect(first.source.contains("public init()"))
        #expect(first.source.contains("public var value: Int"))
        #expect(!first.source.contains("extension SyntheticCounterBox"))

        let typeOnlyResult = try CompilerPreflightHostModule.composing(
            base: nil,
            syntheticTypes: [isolated],
            syntheticSignatures: [])
        let typeOnly = try #require(typeOnlyResult)
        #expect(typeOnly.moduleName
            == CompilerPreflightHostModule.defaultSyntheticModuleName)
        #expect(typeOnly.source.contains(
            "@MainActor public struct ImportedStruct"))

        let preflight = try SwiftCompilerPreflight.activeMacOS(
            hostModule: first)
        let legalClient = try preflight.preflight(source: """
        @MainActor
        func useSyntheticCounter() -> Int {
            let counter = SyntheticCounterBox()
            counter.value = 7
            return counter.value
        }
        """, fileName: "SyntheticNominalType.swift")
        #expect(legalClient.succeeded,
            Comment(rawValue: legalClient.standardError))

        let conflicting = try CompilerPreflightHostType(
            parsing: "struct ImportedStruct {}")
        #expect(throws: CompilerPreflightError.self) {
            _ = try CompilerPreflightHostModule.composing(
                base: base,
                syntheticTypes: [isolated, conflicting],
                syntheticSignatures: [])
        }

        #expect(throws: CompilerPreflightHostTypeError.self) {
            _ = try CompilerPreflightHostType(
                parsing: "actor UnsupportedActor {}")
        }
        #expect(throws: CompilerPreflightHostTypeError.self) {
            _ = try CompilerPreflightHostType(
                parsing: "protocol UnsupportedProtocol {}")
        }
        #expect(throws: CompilerPreflightHostTypeError.self) {
            _ = try CompilerPreflightHostType(
                parsing: "struct Generic<T> {}")
        }
        #expect(throws: CompilerPreflightHostTypeError.self) {
            _ = try CompilerPreflightHostType(
                parsing: "struct NonEmpty { var value: Int }")
        }
        #expect(throws: CompilerPreflightHostTypeError.self) {
            _ = try CompilerPreflightHostType(
                parsing: "private struct Hidden {}")
        }
    }

    @Test func typedSyntheticMainActorTypePreservesPinnedIsolation() throws {
        let registry = try SyntheticNominalHostRegistry()
        let interpreter = try Interpreter.withActiveCompilerPreflight(
            registry: registry)
        let clientName = "host-module-mainactor-type-diagnostic.swift"
        let diagnostic = try interpreter.preflight(
            source: try Self.upstreamClient(clientName),
            fileName: clientName)

        #expect(!diagnostic.succeeded)
        #expect(diagnostic.diagnostics.contains {
            $0.file == clientName
                && $0.line == 8
                && $0.message.contains(
                    "call to main actor-isolated instance method 'isolatedMember()'")
                && $0.message.contains("nonisolated context")
                && !$0.message.contains("cannot find")
        }, Comment(rawValue: diagnostic.standardError))
        #expect(interpreter.compilerPreflight?.hostModule?.source.contains(
            "@MainActor public struct ImportedStruct") == true)
    }

    @Test
    func typedSyntheticNominalMembersPassPreflightAndExecuteThroughRegistry()
        throws {
        let registry = try SyntheticNominalHostRegistry()
        let interpreter = try Interpreter.withActiveCompilerPreflight(
            registry: registry)
        let value = try interpreter.run(source: """
        @MainActor
        func exerciseSyntheticCounter() -> Int {
            let counter = SyntheticCounterBox()
            counter.value = 7
            return counter.value
        }
        exerciseSyntheticCounter()
        """)

        #expect(value.intValue == 7)
        #expect(registry.constructorInvocationCount == 1)
        #expect(registry.getInvocationCount == 1)
        #expect(registry.setInvocationCount == 1)
        let source = try #require(
            interpreter.compilerPreflight?.hostModule?.source)
        #expect(source.contains(
            "@MainActor public final class SyntheticCounterBox"))
        #expect(source.contains("public init()"))
        #expect(source.contains("public var value: Int"))
        #expect(!source.contains("extension SyntheticCounterBox"))
    }

    @Test
    func typedSyntheticMainActorGatewayPreservesPinnedIsolation() throws {
        let registry = try SyntheticMainActorHostRegistry()
        let interpreter = try Interpreter.withActiveCompilerPreflight(
            registry: registry)
        let client = try Self.upstreamClient(
            "host-module-mainactor-diagnostic.swift")
        let diagnostic = try interpreter.preflight(
            source: client,
            fileName: "host-module-mainactor-diagnostic.swift")

        #expect(!diagnostic.succeeded)
        #expect(diagnostic.diagnostics.contains {
            $0.file == "host-module-mainactor-diagnostic.swift"
                && $0.line == 4
                && $0.message.contains("main actor-isolated global function")
                && $0.message.contains("nonisolated context")
        }, Comment(rawValue: diagnostic.standardError))
        #expect(interpreter.compilerPreflight?.hostModule?.moduleName
            == "GlobalActorIsolatedFunction")
        #expect(interpreter.compilerPreflight?.hostModule?.source.contains(
            "@MainActor public func mainActorFunction()") == true)

        let value = try interpreter.run(source: """
        @MainActor
        func validSyntheticMainActorCall() -> Int {
            mainActorFunction()
            return 42
        }
        validSyntheticMainActorCall()
        """)
        #expect(value.intValue == 42)
        #expect(registry.invocationCount == 1)
    }

    @Test
    func typedSyntheticStaticPropertyPreservesPinnedIsolation() throws {
        let base = CompilerPreflightHostModule(
            moduleName: "GlobalVariables",
            source: "public enum Globals {}\n")
        let property = try HostSignature(parsing:
            "@MainActor static var Globals.actorInteger: Int { get set }")
        let moduleResult = try CompilerPreflightHostModule.composing(
            base: base,
            syntheticSignatures: [property])
        let module = try #require(moduleResult)
        let preflight = try SwiftCompilerPreflight.activeMacOS(
            hostModule: module)
        let clientName =
            "host-module-mainactor-static-property-diagnostic.swift"
        let client = try Self.upstreamClient(clientName)
        let result = try preflight.preflight(
            source: client,
            fileName: clientName)

        #expect(!result.succeeded)
        #expect(result.diagnostics.contains {
            $0.file == clientName
                && $0.line == 4
                && $0.message.contains(
                    "main actor-isolated static property 'actorInteger'")
                && $0.message.contains("nonisolated context")
        }, Comment(rawValue: result.standardError))
    }

    @Test
    func typedSyntheticMembersPassPreflightAndExecuteThroughRegistry() throws {
        let registry = try SyntheticStringMemberHostRegistry()
        let interpreter = try Interpreter.withActiveCompilerPreflight(
            registry: registry)
        let value = try interpreter.run(source: """
        @MainActor
        func readSyntheticMembers() -> Int {
            "swift".syntheticLength() + "host".syntheticCount
        }
        readSyntheticMembers()
        """)

        #expect(value.intValue == 9)
        #expect(registry.methodInvocationCount == 1)
        #expect(registry.propertyInvocationCount == 1)
        let source = try #require(interpreter.compilerPreflight?.hostModule?.source)
        #expect(source.contains(
            "@MainActor public func syntheticLength() -> Int"))
        #expect(source.contains(
            "@MainActor public var syntheticCount: Int"))
    }

    @Test
    func typedSyntheticThrowingPropertyPreservesEffectAndExecutes() throws {
        let registry = try SyntheticThrowingPropertyHostRegistry()
        let interpreter = try Interpreter.withActiveCompilerPreflight(
            registry: registry)
        let clientName =
            "host-module-throwing-property-diagnostic.swift"
        let diagnostic = try interpreter.preflight(
            source: try Self.upstreamClient(clientName),
            fileName: clientName)

        #expect(!diagnostic.succeeded)
        #expect(diagnostic.diagnostics.contains {
            $0.file == clientName
                && $0.line == 2
                && $0.message.contains("property access can throw")
                && $0.message.contains("try")
                && !$0.message.contains("cannot find")
        }, Comment(rawValue: diagnostic.standardError))

        let value = try interpreter.run(source: """
        func readSyntheticThrowingProperty() -> Int {
            let success = (try? "swift".syntheticThrowingCount) ?? -100
            do {
                _ = try "fail".syntheticThrowingCount
                return -200
            } catch {
                return success + 7
            }
        }
        readSyntheticThrowingProperty()
        """)
        #expect(value.intValue == 12)
        #expect(registry.invocationCount == 2)
        #expect(interpreter.compilerPreflight?.hostModule?.source.contains(
            "public var syntheticThrowingCount: Int") == true)
        #expect(interpreter.compilerPreflight?.hostModule?.source.contains(
            "get throws {") == true)
    }

    @Test
    func typedSyntheticAsyncPropertyPreservesEffectAndExecutes() async throws {
        let registry = try SyntheticAsyncPropertyHostRegistry()
        let interpreter = try Interpreter.withActiveCompilerPreflight(
            registry: registry)
        let clientName = "host-module-async-property-diagnostic.swift"
        let diagnostic = try interpreter.preflight(
            source: try Self.upstreamClient(clientName),
            fileName: clientName)

        #expect(!diagnostic.succeeded)
        #expect(diagnostic.diagnostics.contains {
            $0.file == clientName
                && $0.line == 2
                && $0.message.contains("expression is 'async'")
                && $0.message.contains("await")
                && !$0.message.contains("cannot find")
        }, Comment(rawValue: diagnostic.standardError))
        #expect(diagnostic.diagnostics.contains {
            $0.file == clientName
                && $0.line == 2
                && $0.message.contains("property access is 'async'")
        }, Comment(rawValue: diagnostic.standardError))

        let value = try await interpreter.runAsync(source: """
        func readSyntheticAsyncProperty() async -> Int {
            let success = (try? await "swift".syntheticAsyncCount) ?? -100
            do {
                _ = try await "fail".syntheticAsyncCount
                return -200
            } catch {
                return success + 7
            }
        }
        await readSyntheticAsyncProperty()
        """)
        #expect(value.intValue == 12)
        let staticValue = try await interpreter.runAsync(
            source: "await String.syntheticAsyncStaticCount")
        #expect(staticValue.intValue == 11)
        #expect(registry.invocationCount == 3)
        #expect(interpreter.compilerPreflight?.hostModule?.source.contains(
            "public var syntheticAsyncCount: Int") == true)
        #expect(interpreter.compilerPreflight?.hostModule?.source.contains(
            "get async throws {") == true)
        #expect(interpreter.compilerPreflight?.hostModule?.source.contains(
            "syntheticAsyncStaticCount: Int") == true)
    }

    @Test
    func hostModuleCompilerArgumentsDoNotLeakIntoSwift6Client() throws {
        let module = CompilerPreflightHostModule(
            moduleName: "LegacyHostSurface",
            source: """
            #if swift(>=6)
            #error("host declaration module must use its Swift 5 mode")
            #endif
            public func legacyHostValue() -> Int { 42 }
            """,
            compilerArguments: ["-swift-version", "5"])
        let defaultModeModule = CompilerPreflightHostModule(
            moduleName: module.moduleName,
            source: module.source)
        #expect(module.manifestSHA256 != defaultModeModule.manifestSHA256)

        let preflight = try SwiftCompilerPreflight.activeMacOS(
            hostModule: module)
        let result = try preflight.preflight(source: """
        import LegacyHostSurface
        #if swift(<6)
        #error("client preflight must remain in Swift 6 mode")
        #endif
        let value = legacyHostValue()
        """, fileName: "Swift6HostClient.swift")

        #expect(result.succeeded, Comment(rawValue: result.standardError))
        #expect(preflight.configuration.additionalCompilerArguments.isEmpty)
    }

    @Test
    func legacyAdditionalArgumentsStillApplyToHostAndClient() throws {
        let registry = try PreflightHostRegistry(moduleSource: """
        #if !LEGACY_HOST
        #error("legacy host compiler argument was lost")
        #endif
        public func mainActorFunction() {}
        """)
        let preflight = try SwiftCompilerPreflight.activeMacOS(
            registry: registry,
            additionalCompilerArguments: ["-D", "LEGACY_HOST"])
        let result = try preflight.preflight(source: """
        #if !LEGACY_HOST
        #error("legacy client compiler argument was lost")
        #endif
        mainActorFunction()
        """)

        #expect(result.succeeded, Comment(rawValue: result.standardError))
        #expect(preflight.configuration.additionalCompilerArguments
            == ["-D", "LEGACY_HOST"])
        #expect(preflight.hostModuleCompilationCount == 1)
    }

    @Test
    func structuredTargetArgumentsStayOutOfGeneratedHostModule() throws {
        let registry = try PreflightHostRegistry(moduleSource: """
        #if TARGET_DEBUG
        #error("target-only define leaked into the host module")
        #endif
        public func mainActorFunction() {}
        """)
        let target = try CompilerPreflightBuildTarget(
            moduleName: "TargetArgumentClient",
            sdk: .iOSSimulator,
            architecture: "arm64",
            deploymentTarget: "18.0",
            compilerVersion: CompilerPreflightVersion(6, 3, 3),
            swiftConditionalCompilationVersion:
                CompilerPreflightVersion(6, 3, 3),
            importableModules: [],
            defaultIsolation: .mainActor,
            activeCompilationConditions: ["TARGET_DEBUG"])
        let preflight = try SwiftCompilerPreflight.activeApple(
            buildTarget: target,
            registry: registry)
        let result = try preflight.preflight(source: """
        nonisolated func callHostDefaultIsolation() {
            mainActorFunction()
        }
        #if !TARGET_DEBUG
        #error("target-only define did not reach the client")
        #endif
        """)

        #expect(result.succeeded, Comment(rawValue: result.standardError))
        #expect(preflight.configuration.additionalCompilerArguments.isEmpty)
        #expect(preflight.configuration.clientCompilerArguments == [
            "-default-isolation", "MainActor", "-D", "TARGET_DEBUG",
        ])
        #expect(preflight.hostModuleCompilationCount == 1)
    }

    @Test
    func invalidHostModuleFailsBeforeCheckingUserSource() throws {
        let invalidName = CompilerPreflightHostModule(
            moduleName: "invalid-module",
            source: "public func value() {}")
        let invalidNameEngine = try SwiftCompilerPreflight.activeMacOS(
            hostModule: invalidName)
        do {
            _ = try invalidNameEngine.preflight(source: "let value = 1")
            Issue.record("invalid host module name unexpectedly compiled")
        } catch CompilerPreflightError.invalidConfiguration(let message) {
            #expect(message.contains("not a Swift identifier"))
        }
        #expect(invalidNameEngine.hostModuleCompilationCount == 0)

        let invalidSource = CompilerPreflightHostModule(
            moduleName: "InvalidHostSource",
            source: "public func broken(")
        let invalidSourceEngine = try SwiftCompilerPreflight.activeMacOS(
            hostModule: invalidSource)
        do {
            _ = try invalidSourceEngine.preflight(source: "let value = 1")
            Issue.record("invalid host module source unexpectedly compiled")
        } catch CompilerPreflightError.hostModuleCompilationFailed(
            let moduleName, let exitStatus, let diagnostics) {
            #expect(moduleName == "InvalidHostSource")
            #expect(exitStatus != 0)
            #expect(diagnostics.contains("expected parameter name"))
        }
        #expect(invalidSourceEngine.hostModuleCompilationCount == 1)
    }

    @Test
    func cacheKeyInvalidatesOnSourceToolchainSDKTargetAndManifest() throws {
        var invocationCount = 0
        let cache = CompilerPreflightCache(capacity: 16)
        func engine(
            compilerVersion: String = "Swift A",
            sdkVersion: String = "SDK A",
            target: String = "arm64-apple-macosx15.0",
            moduleName: String = "Fixture",
            languageVersion: CompilerPreflightSwiftLanguageVersion = .swift6,
            strictConcurrency: CompilerPreflightStrictConcurrency = .complete,
            clientArguments: [String] = [],
            clientValidationSource: String? = nil,
            manifest: String = String(repeating: "a", count: 64)
        ) -> SwiftCompilerPreflight {
            let configuration = CompilerPreflightConfiguration(
                swiftCompilerPath: "/toolchain/swiftc",
                compilerVersion: compilerVersion,
                sdkPath: "/SDK",
                sdkVersion: sdkVersion,
                targetTriple: target,
                deploymentTarget: target.split(separator: "x").last
                    .map(String.init) ?? "15.0",
                moduleName: moduleName,
                swiftLanguageVersion: languageVersion,
                strictConcurrency: strictConcurrency,
                gatewayManifestSHA256: manifest,
                clientCompilerArguments: clientArguments,
                clientValidationSource: clientValidationSource)
            return SwiftCompilerPreflight(
                configuration: configuration,
                cache: cache,
                executor: { _, sources, _ in
                    invocationCount += 1
                    return CompilerPreflightInvocationOutput(
                        exitStatus: 0,
                        standardOutput: "",
                        standardError: "",
                        logicalFileNamesByPath: Dictionary(
                            uniqueKeysWithValues: sources.map {
                                ($0.fileName, $0.fileName)
                            }))
                })
        }

        let baseline = engine()
        let first = try baseline.preflight(source: "let value = 1")
        let repeated = try baseline.preflight(source: "let value = 1")
        #expect(invocationCount == 1)
        #expect(!first.wasCached)
        #expect(repeated.wasCached)

        let sourceChanged = try baseline.preflight(source: "let value = 2")
        let compilerChanged = try engine(compilerVersion: "Swift B")
            .preflight(source: "let value = 1")
        let sdkChanged = try engine(sdkVersion: "SDK B")
            .preflight(source: "let value = 1")
        let targetChanged = try engine(target: "x86_64-apple-macosx15.0")
            .preflight(source: "let value = 1")
        let moduleChanged = try engine(moduleName: "OtherFixture")
            .preflight(source: "let value = 1")
        let languageChanged = try engine(languageVersion: .swift5)
            .preflight(source: "let value = 1")
        let strictChanged = try engine(strictConcurrency: .targeted)
            .preflight(source: "let value = 1")
        let clientArgumentsChanged = try engine(
            clientArguments: ["-D", "FEATURE"]
        ).preflight(source: "let value = 1")
        let clientValidationChanged = try engine(
            clientValidationSource: "let validation = true"
        ).preflight(source: "let value = 1")
        let manifestChanged = try engine(
            manifest: String(repeating: "b", count: 64)
        ).preflight(source: "let value = 1")

        #expect(invocationCount == 11)
        let keys = [
            first, sourceChanged, compilerChanged, sdkChanged, targetChanged,
            moduleChanged, languageChanged, strictChanged,
            clientArgumentsChanged, clientValidationChanged, manifestChanged,
        ].map(\.cacheKey)
        #expect(Set(keys).count == keys.count)
    }

    @Test
    func timeoutTerminatesCompilerDescendantProcessTree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "compiler-preflight-timeout-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-swiftc")
        let descendantPIDFile = directory.appendingPathComponent(
            "descendant-pid")
        try """
        #!/bin/sh
        trap '' TERM
        /bin/sh -c 'trap "" TERM; while :; do :; done' &
        echo $! > "\(descendantPIDFile.path)"
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        // macOS validates a freshly written executable on its FIRST exec:
        // measured here at 266ms against 5ms once warm — longer than the
        // timeout under test, so an unwarmed run times out before the fake
        // compiler ever reaches its own first line and the test measures
        // code-signing latency instead of descendant termination.
        try warmFirstExec(of: script, writing: descendantPIDFile)
        let configuration = CompilerPreflightConfiguration(
            swiftCompilerPath: script.path,
            compilerVersion: "fake compiler",
            sdkPath: "/fake-sdk",
            sdkVersion: "fake sdk",
            targetTriple: "arm64-apple-macosx15.0",
            deploymentTarget: "15.0",
            gatewayManifestSHA256: String(repeating: "a", count: 64),
            timeoutSeconds: 0.5)
        let engine = SwiftCompilerPreflight(configuration: configuration)

        do {
            _ = try engine.preflight(source: "let value = 1")
            Issue.record("stuck compiler unexpectedly completed")
        } catch CompilerPreflightError.timedOut(let timeout) {
            #expect(timeout == 0.5)
        }

        let rawPID = try String(
            contentsOf: descendantPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let descendantPID = try #require(pid_t(rawPID))
        for _ in 0..<100 where Darwin.kill(descendantPID, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(Darwin.kill(descendantPID, 0) == -1 && errno == ESRCH)
    }

    /// Run the stuck fake compiler once and kill the tree it made, so the
    /// one-time first-exec validation is paid outside the measured timeout.
    /// The script and its child both trap TERM, so both need SIGKILL.
    private func warmFirstExec(
        of script: URL, writing descendantPIDFile: URL
    ) throws {
        let warmup = Process()
        warmup.executableURL = script
        warmup.standardOutput = FileHandle.nullDevice
        warmup.standardError = FileHandle.nullDevice
        try warmup.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: descendantPIDFile.path),
              warmup.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if let raw = try? String(
            contentsOf: descendantPIDFile, encoding: .utf8),
            let warmed = pid_t(
                raw.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            Darwin.kill(warmed, SIGKILL)
        }
        Darwin.kill(warmup.processIdentifier, SIGKILL)
        warmup.waitUntilExit()
        try? FileManager.default.removeItem(at: descendantPIDFile)
    }

    private static func activePreflight() throws -> SwiftCompilerPreflight {
        try SwiftCompilerPreflight.activeMacOS(
            gatewayManifestSHA256:
                SwiftCompilerPreflight.emptyGatewayManifestSHA256)
    }

    private static func fixture(_ name: String) throws -> String {
        try String(
            contentsOf: packageRoot
                .appendingPathComponent("Tests/ConcurrencyParity/Fixtures")
                .appendingPathComponent(name),
            encoding: .utf8)
    }

    private static func upstreamFixture(_ path: String) throws -> String {
        try String(
            contentsOf: packageRoot
                .appendingPathComponent("Tests/SwiftUpstream/Fixtures")
                .appendingPathComponent(path),
            encoding: .utf8)
    }

    private static func upstreamClient(_ name: String) throws -> String {
        try String(
            contentsOf: packageRoot
                .appendingPathComponent("Tests/SwiftUpstream/Clients")
                .appendingPathComponent(name),
            encoding: .utf8)
    }

    private static func compilerPreflightFixture(_ name: String) throws -> String {
        try String(
            contentsOf: packageRoot
                .appendingPathComponent(
                    "Tests/CompilerPreflight/Fixtures")
                .appendingPathComponent(name),
            encoding: .utf8)
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private final class PreflightHostRegistry: HostRegistry {
    let compilerPreflightHostModule: CompilerPreflightHostModule?
    private let mainActorFunction: HostFunction
    private let counter: PreflightInvocationCounter
    var invocationCount: Int { counter.value }

    init(moduleSource: String) throws {
        let counter = PreflightInvocationCounter()
        self.counter = counter
        compilerPreflightHostModule = CompilerPreflightHostModule(
            moduleName: "GlobalActorIsolatedFunction",
            source: moduleSource)
        mainActorFunction = try HostFunction(
            declaration: "func mainActorFunction()"
        ) { _, _ in
            counter.value += 1
            return .void
        }
    }

    func cFunction(named name: String) -> HostFunction? {
        name == "mainActorFunction" ? mainActorFunction : nil
    }

    func absorbedCValue(named name: String) -> RuntimeValue? { nil }
    func storeBlob(_ value: RuntimeValue, at path: String) {}
    func constructor(named name: String) -> HostFunction? { nil }
    func modifier(named name: String) -> HostModifier? { nil }
    func isViewValue(_ value: RuntimeValue) -> Bool { false }
    func makeRenderable(
        instance: Instance, interpreter: Interpreter
    ) -> RuntimeValue { .void }
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue { .void }
}

private final class PreflightInvocationCounter {
    var value = 0
}

private final class SyntheticCounterBoxStorage {
    var value = 0
}

private final class SyntheticNominalHostRegistry: HostRegistry {
    let compilerPreflightHostModule: CompilerPreflightHostModule? =
        CompilerPreflightHostModule(
            moduleName: "TypeIsolationHost",
            source: "// Interpreter-synthetic nominal declarations follow.\n")
    private let syntheticTypes: [CompilerPreflightHostType]
    private let counterConstructor: HostFunction
    private let counterValue: HostProperty
    private let constructorCounter = PreflightInvocationCounter()
    private let getCounter = PreflightInvocationCounter()
    private let setCounter = PreflightInvocationCounter()

    var constructorInvocationCount: Int { constructorCounter.value }
    var getInvocationCount: Int { getCounter.value }
    var setInvocationCount: Int { setCounter.value }

    var compilerPreflightSyntheticTypes: [CompilerPreflightHostType] {
        syntheticTypes
    }

    var compilerPreflightSyntheticSignatures: [HostSignature] {
        counterConstructor.signatures + [counterValue.signature]
    }

    init() throws {
        syntheticTypes = [
            try CompilerPreflightHostType(
                parsing: "@MainActor struct ImportedStruct {}"),
            try CompilerPreflightHostType(
                parsing: "@MainActor final class SyntheticCounterBox {}"),
        ]
        let constructorCounter = constructorCounter
        counterConstructor = try HostFunction(
            declaration: "init SyntheticCounterBox()"
        ) { _, _ in
            constructorCounter.value += 1
            return .native(SyntheticCounterBoxStorage())
        }
        let getCounter = getCounter
        let setCounter = setCounter
        counterValue = try HostProperty(
            declaration: "var SyntheticCounterBox.value: Int { get set }",
            get: { receiver, _ in
                getCounter.value += 1
                guard case .host(let value) = receiver,
                      let counter = value as? SyntheticCounterBoxStorage else {
                    throw RuntimeError(message: "wrong synthetic counter receiver")
                }
                return .native(counter.value)
            },
            set: { receiver, value, _ in
                setCounter.value += 1
                guard case .host(let receiver) = receiver,
                      let counter = receiver as? SyntheticCounterBoxStorage,
                      let value = value.intValue else {
                    throw RuntimeError(message: "wrong synthetic counter setter")
                }
                counter.value = value
            })
    }

    func cFunction(named name: String) -> HostFunction? { nil }
    func absorbedCValue(named name: String) -> RuntimeValue? { nil }
    func storeBlob(_ value: RuntimeValue, at path: String) {}
    func constructor(named name: String) -> HostFunction? {
        name == "SyntheticCounterBox" ? counterConstructor : nil
    }
    func modifier(named name: String) -> HostModifier? { nil }
    func isViewValue(_ value: RuntimeValue) -> Bool { false }
    func makeRenderable(
        instance: Instance, interpreter: Interpreter
    ) -> RuntimeValue { .void }
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue { .void }
    func hostTypeName(of value: Any) -> String? {
        value is SyntheticCounterBoxStorage ? "SyntheticCounterBox" : nil
    }
    func hostProperty(named name: String, on value: Any) -> HostProperty? {
        name == "value" && value is SyntheticCounterBoxStorage
            ? counterValue : nil
    }
}

private final class SyntheticAsyncHostRegistry: HostRegistry {
    private let asyncValue: HostFunction
    private let counter = PreflightInvocationCounter()
    var invocationCount: Int { counter.value }
    var compilerPreflightSyntheticSignatures: [HostSignature] {
        asyncValue.signatures
    }

    init() throws {
        let counter = counter
        asyncValue = try HostFunction(
            declaration: "func syntheticAsyncValue() async -> Int",
            asyncInvoke: { _, _ in
                counter.value += 1
                return .native(42)
            })
    }

    func cFunction(named name: String) -> HostFunction? {
        name == "syntheticAsyncValue" ? asyncValue : nil
    }

    func absorbedCValue(named name: String) -> RuntimeValue? { nil }
    func storeBlob(_ value: RuntimeValue, at path: String) {}
    func constructor(named name: String) -> HostFunction? { nil }
    func modifier(named name: String) -> HostModifier? { nil }
    func isViewValue(_ value: RuntimeValue) -> Bool { false }
    func makeRenderable(
        instance: Instance, interpreter: Interpreter
    ) -> RuntimeValue { .void }
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue { .void }
}

private final class SyntheticMainActorHostRegistry: HostRegistry {
    let compilerPreflightHostModule: CompilerPreflightHostModule? =
        CompilerPreflightHostModule(
        moduleName: "GlobalActorIsolatedFunction",
        source: "// Interpreter-synthetic host declarations follow.\n")
    private let mainActorFunction: HostFunction
    private let counter = PreflightInvocationCounter()
    var invocationCount: Int { counter.value }
    var compilerPreflightSyntheticSignatures: [HostSignature] {
        mainActorFunction.signatures
    }

    init() throws {
        let counter = counter
        mainActorFunction = try HostFunction(
            declaration: "@MainActor func mainActorFunction()"
        ) { _, _ in
            counter.value += 1
            return .void
        }
    }

    func cFunction(named name: String) -> HostFunction? {
        name == "mainActorFunction" ? mainActorFunction : nil
    }

    func absorbedCValue(named name: String) -> RuntimeValue? { nil }
    func storeBlob(_ value: RuntimeValue, at path: String) {}
    func constructor(named name: String) -> HostFunction? { nil }
    func modifier(named name: String) -> HostModifier? { nil }
    func isViewValue(_ value: RuntimeValue) -> Bool { false }
    func makeRenderable(
        instance: Instance, interpreter: Interpreter
    ) -> RuntimeValue { .void }
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue { .void }
}

private final class SyntheticStringMemberHostRegistry: HostRegistry {
    private let methodSignature: HostSignature
    private let countProperty: HostProperty
    private let methodCounter = PreflightInvocationCounter()
    private let propertyCounter = PreflightInvocationCounter()
    var methodInvocationCount: Int { methodCounter.value }
    var propertyInvocationCount: Int { propertyCounter.value }

    var compilerPreflightSyntheticSignatures: [HostSignature] {
        [methodSignature, countProperty.signature]
    }

    init() throws {
        methodSignature = try HostSignature(parsing:
            "@MainActor func String.syntheticLength() -> Int")
        let propertyCounter = propertyCounter
        countProperty = try HostProperty(
            declaration: "@MainActor var String.syntheticCount: Int { get }",
            get: { receiver, _ in
                propertyCounter.value += 1
                guard let string = receiver.stringValue else {
                    throw RuntimeError(message: "expected String receiver")
                }
                return .native(string.count)
            })
    }

    func hostMethod(_ name: String, on value: Any) -> RuntimeValue? {
        syntheticMethod(name, on: value)
    }

    func hostMember(_ name: String, on value: Any) -> RuntimeValue? {
        syntheticMethod(name, on: value)
    }

    private func syntheticMethod(
        _ name: String, on value: Any
    ) -> RuntimeValue? {
        let methodCounter = methodCounter
        guard name == "syntheticLength", let string = value as? String,
              let function = try? HostFunction(
                signature: methodSignature,
                invoke: { _, _ in
                    methodCounter.value += 1
                    return .native(string.count)
                }) else { return nil }
        return .hostFunction(function)
    }

    func hostProperty(named name: String, on value: Any) -> HostProperty? {
        name == "syntheticCount" && value is String ? countProperty : nil
    }

    func cFunction(named name: String) -> HostFunction? { nil }
    func absorbedCValue(named name: String) -> RuntimeValue? { nil }
    func storeBlob(_ value: RuntimeValue, at path: String) {}
    func constructor(named name: String) -> HostFunction? { nil }
    func modifier(named name: String) -> HostModifier? { nil }
    func isViewValue(_ value: RuntimeValue) -> Bool { false }
    func makeRenderable(
        instance: Instance, interpreter: Interpreter
    ) -> RuntimeValue { .void }
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue { .void }
}

private enum SyntheticThrowingPropertyError: Error {
    case requested
}

private final class SyntheticThrowingPropertyHostRegistry: HostRegistry {
    private let property: HostProperty
    private let counter = PreflightInvocationCounter()
    var invocationCount: Int { counter.value }

    var compilerPreflightSyntheticSignatures: [HostSignature] {
        [property.signature]
    }

    init() throws {
        let counter = counter
        property = try HostProperty(
            declaration:
                "var String.syntheticThrowingCount: Int { get throws }",
            get: { receiver, _ in
                counter.value += 1
                guard let string = receiver.stringValue else {
                    throw RuntimeError(message: "expected String receiver")
                }
                if string == "fail" {
                    throw SyntheticThrowingPropertyError.requested
                }
                return .native(string.count)
            })
    }

    func hostProperty(named name: String, on value: Any) -> HostProperty? {
        name == "syntheticThrowingCount" && value is String ? property : nil
    }

    func cFunction(named name: String) -> HostFunction? { nil }
    func absorbedCValue(named name: String) -> RuntimeValue? { nil }
    func storeBlob(_ value: RuntimeValue, at path: String) {}
    func constructor(named name: String) -> HostFunction? { nil }
    func modifier(named name: String) -> HostModifier? { nil }
    func isViewValue(_ value: RuntimeValue) -> Bool { false }
    func makeRenderable(
        instance: Instance, interpreter: Interpreter
    ) -> RuntimeValue { .void }
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue { .void }
}

private enum SyntheticAsyncPropertyError: Error {
    case requested
}

private final class SyntheticAsyncPropertyHostRegistry: HostRegistry {
    private let property: HostProperty
    private let staticProperty: HostProperty
    private let counter = PreflightInvocationCounter()
    var invocationCount: Int { counter.value }

    var compilerPreflightSyntheticSignatures: [HostSignature] {
        [property.signature, staticProperty.signature]
    }

    init() throws {
        let counter = counter
        property = try HostProperty(
            declaration:
                "var String.syntheticAsyncCount: Int { get async throws }",
            asyncGet: { receiver, _ in
                counter.value += 1
                await Task.yield()
                guard let string = receiver.stringValue else {
                    throw RuntimeError(message: "expected String receiver")
                }
                if string == "fail" {
                    throw SyntheticAsyncPropertyError.requested
                }
                return .native(string.count)
            })
        staticProperty = try HostProperty(
            declaration:
                "static var String.syntheticAsyncStaticCount: Int { get async }",
            asyncGet: { _, _ in
                counter.value += 1
                await Task.yield()
                return .native(11)
            })
    }

    func hostProperty(named name: String, on value: Any) -> HostProperty? {
        if name == "syntheticAsyncCount", value is String {
            return property
        }
        if name == "syntheticAsyncStaticCount",
           let marker = value as? HostTypeMarker,
           marker.name == "String" {
            return staticProperty
        }
        return nil
    }

    func cFunction(named name: String) -> HostFunction? { nil }
    func absorbedCValue(named name: String) -> RuntimeValue? { nil }
    func storeBlob(_ value: RuntimeValue, at path: String) {}
    func constructor(named name: String) -> HostFunction? { nil }
    func modifier(named name: String) -> HostModifier? { nil }
    func isViewValue(_ value: RuntimeValue) -> Bool { false }
    func makeRenderable(
        instance: Instance, interpreter: Interpreter
    ) -> RuntimeValue { .void }
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue { .void }
}
