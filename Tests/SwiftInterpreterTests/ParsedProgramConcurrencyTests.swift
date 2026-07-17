import Testing
import SwiftSyntax
@testable import SwiftInterpreter

@Suite("Parsed program concurrency boundary")
struct ParsedProgramConcurrencyTests {
    @Test nonisolated func parsedProgramOwnsSendableDeclarationIndex()
    async throws {
        let program = try ParsedProgram(source: """
        struct Box {}
        func value() -> Int { 1 }
        let global = value()
        typealias Alias = Box
        extension Box {}
        #if os(iOS)
        actor Worker {}
        #else
        enum Worker {}
        #endif
        """)

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(program.declarationIndex)
        let expected = ParsedDeclarationIndex.Summary(
            possiblePrimaryDeclarationCount: 5,
            possibleTypeAliasCount: 1,
            possibleExtensionCount: 1,
            conditionalRegionCount: 1)
        #expect(program.declarationIndex.summary == expected)

        let observations = await withTaskGroup(
            of: ParsedDeclarationIndex.Summary.self,
            returning: [ParsedDeclarationIndex.Summary].self
        ) { group in
            for _ in 0..<8 {
                group.addTask { program.declarationIndex.summary }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(observations.count == 8)
        #expect(observations.allSatisfy { $0 == expected })
    }

    @Test nonisolated func parsedProgramIsSendableAcrossDetachedReaders()
    async throws {
        let program = try ParsedProgram(source: """
        func answer() -> Int { 42 }
        answer()
        """)

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(program)

        let observations = await withTaskGroup(
            of: (Int, String).self,
            returning: [(Int, String)].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    (
                        program.syntax.statements.count,
                        program.syntax.trimmedDescription
                    )
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(observations.count == 8)
        #expect(observations.allSatisfy { $0.0 == 2 })
        #expect(Set(observations.map(\.1)).count == 1)
    }

    @Test func oneParsedProgramBacksIndependentAsyncSessions() async throws {
        let program = try ParsedProgram(source: """
        func yielding(_ value: Int) async -> Int {
            await Task.yield()
            return value
        }
        func combined() async -> Int {
            async let left = yielding(20)
            async let right = yielding(22)
            return await left + right
        }
        await combined()
        """)
        let first = Interpreter()
        let second = Interpreter()

        async let firstValue = first.runAsync(program: program)
        async let secondValue = second.runAsync(program: program)
        let values = try await [firstValue, secondValue]

        #expect(values.map(\.intValue) == [42, 42])
        #expect(first.concurrencyRuntime.activeRecordCount == 0)
        #expect(second.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func sessionsBindBuildResolvedDeclarationPlans() async throws {
        let program = try ParsedProgram(source: """
        #if os(iOS)
        struct Selected { let base = 40 }
        typealias Alias = Selected
        extension Selected { var answer: Int { base + 2 } }
        #else
        struct Selected { let base = 20 }
        typealias Alias = Selected
        extension Selected { var answer: Int { base + 1 } }
        #endif
        Alias().answer
        """)
        let ios = Interpreter(buildConfiguration: .init(
            platformName: "iOS", activeCompilationConditions: []))
        let mac = Interpreter(buildConfiguration: .init(
            platformName: "macOS", activeCompilationConditions: []))
        let iosSession = ios.makeSession(program: program)
        let macSession = mac.makeSession(program: program)

        #expect(program.declarationIndex.summary
            .possiblePrimaryDeclarationCount == 2)
        #expect(program.declarationIndex.summary
            .possibleTypeAliasCount == 2)
        #expect(program.declarationIndex.summary
            .possibleExtensionCount == 2)
        #expect(iosSession.executionPlan.primaryDeclarations.count == 1)
        #expect(macSession.executionPlan.primaryDeclarations.count == 1)
        #expect(iosSession.executionPlan.typeAliases.count == 1)
        #expect(macSession.executionPlan.typeAliases.count == 1)
        #expect(iosSession.executionPlan.extensionDeclarations.count == 1)
        #expect(macSession.executionPlan.extensionDeclarations.count == 1)
        #expect(iosSession.executionPlan.topLevelItems.count == 4)
        #expect(macSession.executionPlan.topLevelItems.count == 4)

        let iosValue = try await ios.runAsync(session: iosSession)
        let macValue = try await mac.runAsync(session: macSession)
        #expect(iosValue.intValue == 42)
        #expect(macValue.intValue == 21)
    }

    @Test func parsedProgramOwnsSendableCallableMetadataIndex() async throws {
        let program = try ParsedProgram(source: """
        @MainActor
        func mainActorValue(_ input: Int = 1) async -> Int { input }

        struct Worker {
            init(seed: Int) {}

            nonisolated func plain(label: String) async throws -> Int {
                1
            }

            var state: Int {
                get { 1 }
                set {}
            }

            subscript(_ index: Int) -> Int {
                get async throws { index }
            }

            #if os(iOS)
            @concurrent func selected() async {}
            #else
            func selected() {}
            #endif
        }

        await mainActorValue(42)
        """)
        let expected = ParsedCallableMetadataIndex.Summary(
            functionCount: 4,
            initializerCount: 1,
            asyncFunctionCount: 3,
            throwingFunctionCount: 1,
            explicitlyNonisolatedFunctionCount: 1,
            mainActorFunctionCount: 1,
            concurrentFunctionCount: 1,
            readableAccessorCount: 2,
            subscriptCount: 1,
            asyncGetterCount: 1,
            throwingGetterCount: 1,
            setterCount: 1)

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(program.callableMetadataIndex)
        #expect(program.callableMetadataIndex.summary == expected)
        let readers = (0..<8).map { _ in
            Task.detached { program.callableMetadataIndex.summary }
        }
        var observations: [ParsedCallableMetadataIndex.Summary] = []
        for reader in readers {
            observations.append(await reader.value)
        }
        #expect(observations == Array(repeating: expected, count: 8))

        let interpreter = Interpreter()
        let session = interpreter.makeSession(program: program)
        #expect(session.runtimeEntry.callableMetadataIndex?.summary == expected)
        let result = try await interpreter.runAsync(session: session)
        #expect(result.intValue == 42)
    }

    @Test nonisolated func parsedProgramIndexesAccessorAndSubscriptMetadata()
    throws {
        let program = try ParsedProgram(source: """
        struct Indexed {
            var plain: Int {
                get { 1 }
                set(replacement) {}
            }

            var effectful: Int {
                get async throws { 2 }
            }

            var observed = 0 {
                willSet {}
                didSet {}
            }

            subscript(_ index: Int) -> Int {
                get async throws { index }
            }

            subscript(label label: String) -> String {
                get { label }
                set(replacement) {}
            }
        }
        """)
        let summary = program.callableMetadataIndex.summary
        #expect(summary.readableAccessorCount == 4)
        #expect(summary.subscriptCount == 2)
        #expect(summary.asyncGetterCount == 2)
        #expect(summary.throwingGetterCount == 2)
        #expect(summary.setterCount == 2)

        let structures: [StructDeclSyntax] = program.syntax.statements.compactMap {
            guard case .decl(let declaration) = $0.item else { return nil }
            return declaration.as(StructDeclSyntax.self)
        }
        let indexed = try #require(structures.first)
        let subscripts: [SubscriptDeclSyntax] =
            indexed.memberBlock.members.compactMap {
                $0.decl.as(SubscriptDeclSyntax.self)
            }
        let asyncSubscript = try #require(subscripts.first)
        let asyncMetadata = try #require(
            program.callableMetadataIndex.metadata(for: asyncSubscript))
        #expect(asyncMetadata.parameters.map(\.name) == ["index"])
        #expect(asyncMetadata.parameters.map(\.label) == [nil])
        #expect(asyncMetadata.resultTypeName == "Int")
        #expect(!asyncMetadata.isNonisolated)

        let asyncAccessorBlock = try #require(asyncSubscript.accessorBlock)
        let asyncAccessor = try #require(
            program.callableMetadataIndex.metadata(for: asyncAccessorBlock))
        #expect(asyncAccessor.isAsync)
        #expect(asyncAccessor.isThrowing)
        #expect(asyncAccessor.setter == nil)

        let syncSubscript = try #require(subscripts.last)
        let syncAccessorBlock = try #require(syncSubscript.accessorBlock)
        let syncAccessor = try #require(
            program.callableMetadataIndex.metadata(for: syncAccessorBlock))
        #expect(!syncAccessor.isAsync)
        #expect(!syncAccessor.isThrowing)
        #expect(syncAccessor.setter?.parameterName == "replacement")
    }

    @Test func parsedProgramOwnsSendableNominalMetadataIndex() async throws {
        let program = try ParsedProgram(source: """
        @globalActor
        struct UIRealm {
            actor Storage {}
            static let shared = Storage()
        }

        @Observable
        final class Model: NSObject, ObservableObject {}
        actor Worker: Sendable {}
        enum Outcome<Value>: Sendable { case value(Value) }
        protocol Service: Sendable {}

        #if os(iOS)
        struct Selected: View {}
        #else
        class Selected: NSObject {}
        #endif
        """)
        let expected = ParsedNominalMetadataIndex.Summary(
            structureCount: 2,
            classCount: 2,
            actorCount: 2,
            enumerationCount: 1,
            protocolCount: 1,
            attributedNominalCount: 2,
            genericNominalCount: 1,
            inheritedTypeCount: 7)

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(program.nominalMetadataIndex)
        #expect(program.nominalMetadataIndex.summary == expected)
        #expect(program.metadata.nominalMetadataIndex.summary == expected)

        let readers = (0..<8).map { _ in
            Task.detached { program.nominalMetadataIndex.summary }
        }
        var observations: [ParsedNominalMetadataIndex.Summary] = []
        for reader in readers {
            observations.append(await reader.value)
        }
        #expect(observations == Array(repeating: expected, count: 8))

        let structures: [StructDeclSyntax] = program.syntax.statements.compactMap {
            guard case .decl(let declaration) = $0.item else { return nil }
            return declaration.as(StructDeclSyntax.self)
        }
        let uiRealm = try #require(structures.first)
        let metadata = try #require(
            program.nominalMetadataIndex.metadata(for: uiRealm))
        #expect(metadata.kind == .structure)
        #expect(metadata.name == "UIRealm")
        #expect(metadata.attributeNames == ["globalActor"])
        #expect(metadata.inheritedTypeNames.isEmpty)
        #expect(metadata.genericParameters.isEmpty)

        let classes: [ClassDeclSyntax] = program.syntax.statements.compactMap {
            guard case .decl(let declaration) = $0.item else { return nil }
            return declaration.as(ClassDeclSyntax.self)
        }
        let model = try #require(classes.first)
        let modelMetadata = try #require(
            program.nominalMetadataIndex.metadata(for: model))
        #expect(modelMetadata.kind == .classType)
        #expect(modelMetadata.attributeNames == ["Observable"])
        #expect(modelMetadata.inheritedTypeNames
            == ["NSObject", "ObservableObject"])

        let actors: [ActorDeclSyntax] = program.syntax.statements.compactMap {
            guard case .decl(let declaration) = $0.item else { return nil }
            return declaration.as(ActorDeclSyntax.self)
        }
        let worker = try #require(actors.first)
        let workerMetadata = try #require(
            program.nominalMetadataIndex.metadata(for: worker))
        #expect(workerMetadata.kind == .actor)
        #expect(workerMetadata.inheritedTypeNames == ["Sendable"])

        let enumerations: [EnumDeclSyntax] = program.syntax.statements.compactMap {
            guard case .decl(let declaration) = $0.item else { return nil }
            return declaration.as(EnumDeclSyntax.self)
        }
        let outcome = try #require(enumerations.first)
        let outcomeMetadata = try #require(
            program.nominalMetadataIndex.metadata(for: outcome))
        #expect(outcomeMetadata.kind == .enumeration)
        #expect(outcomeMetadata.genericParameters.map(\.name) == ["Value"])
        #expect(outcomeMetadata.genericParameters.map(\.inheritedTypeName)
            == [nil])

        let protocols: [ProtocolDeclSyntax] =
            program.syntax.statements.compactMap {
                guard case .decl(let declaration) = $0.item else { return nil }
                return declaration.as(ProtocolDeclSyntax.self)
            }
        let service = try #require(protocols.first)
        let serviceMetadata = try #require(
            program.nominalMetadataIndex.metadata(for: service))
        #expect(serviceMetadata.kind == .protocolType)
        #expect(serviceMetadata.inheritedTypeNames == ["Sendable"])

        let interpreter = Interpreter()
        let session = interpreter.makeSession(program: program)
        #expect(session.runtimeEntry.programMetadata?.nominalMetadataIndex
            .summary == expected)
    }

    @Test func parsedProgramMetadataIsOneSendableRuntimeCapability()
    async throws {
        let program = try ParsedProgram(source: """
        struct Marker {}
        func makeValue() -> Int { 42 }
        makeValue()
        """)
        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(program.metadata)
        #expect(program.metadata.declarationIndex.summary
            == program.declarationIndex.summary)
        #expect(program.metadata.callableMetadataIndex.summary
            == program.callableMetadataIndex.summary)
        #expect(program.metadata.nominalMetadataIndex.summary
            == program.nominalMetadataIndex.summary)

        let readers = (0..<8).map { _ in
            Task.detached {
                (
                    program.metadata.declarationIndex.summary
                        .possiblePrimaryDeclarationCount,
                    program.metadata.callableMetadataIndex.summary.functionCount,
                    program.metadata.nominalMetadataIndex.summary.structureCount
                )
            }
        }
        var observations: [(Int, Int, Int)] = []
        for reader in readers {
            observations.append(await reader.value)
        }
        #expect(observations.allSatisfy { $0 == (2, 1, 1) })

        let interpreter = Interpreter()
        let session = interpreter.makeSession(program: program)
        #expect(session.runtimeEntry.programMetadata?.callableMetadataIndex
            .summary == program.callableMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.nominalMetadataIndex
            .summary == program.nominalMetadataIndex.summary)
        #expect(try await interpreter.runAsync(session: session).intValue == 42)
    }

    @Test func sourceEntryStillReturnsLocatedRuntimeParseError() throws {
        do {
            _ = try Interpreter().run(source: "let value = \"")
            Issue.record("expected a parse error")
        } catch let error as RuntimeError {
            #expect(error.line == 1)
            #expect(!error.message.isEmpty)
        }
    }
}
