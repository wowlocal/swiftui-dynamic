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

    @Test func parsedProgramOwnsSendablePropertyMetadataIndex() async throws {
        let program = try ParsedProgram(source: """
        final class Delegate {}

        struct IndexedStorage {
            let immutable = 1
            weak var delegate: Delegate?
            lazy var cached = 2
            nonisolated(unsafe) static var shared = 3

            var observed = 0 {
                willSet(next) {}
                didSet(previous) {}
            }

            var computed: Int {
                get { 4 }
                set(replacement) {}
            }

            @TaskLocal static var token: Int?
            let (left, right): (Int, String) = (1, "right")

            #if os(iOS)
            unowned var selectedOwner: Delegate
            #else
            var selected = 9
            #endif
        }

        func localStorage() {
            var local = 0
            local += 1
        }
        """)
        let expected = ParsedPropertyMetadataIndex.Summary(
            variableDeclarationCount: 11,
            bindingCount: 11,
            storedBindingCount: 10,
            computedBindingCount: 1,
            observedStoredBindingCount: 1,
            mutableBindingCount: 9,
            staticBindingCount: 2,
            lazyBindingCount: 1,
            explicitlyNonisolatedBindingCount: 1,
            taskLocalBindingCount: 1,
            referenceManagedBindingCount: 2)

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(program.propertyMetadataIndex)
        #expect(program.propertyMetadataIndex.summary == expected)
        #expect(program.metadata.propertyMetadataIndex.summary == expected)

        let readers = (0..<8).map { _ in
            Task.detached { program.propertyMetadataIndex.summary }
        }
        var observations: [ParsedPropertyMetadataIndex.Summary] = []
        for reader in readers {
            observations.append(await reader.value)
        }
        #expect(observations == Array(repeating: expected, count: 8))

        let structures: [StructDeclSyntax] = program.syntax.statements.compactMap {
            guard case .decl(let declaration) = $0.item else { return nil }
            return declaration.as(StructDeclSyntax.self)
        }
        let structure = try #require(structures.first)
        let variables = structure.memberBlock.members.compactMap {
            $0.decl.as(VariableDeclSyntax.self)
        }
        let observed = try #require(variables.first {
            $0.bindings.first?.pattern.trimmedDescription == "observed"
        })
        let observedMetadata = try #require(
            program.propertyMetadataIndex.metadata(for: observed))
        #expect(observedMetadata.isMutable)
        #expect(!observedMetadata.isStatic)
        #expect(!observedMetadata.isLazy)
        #expect(!observedMetadata.isNonisolated)
        let observedBinding = try #require(observed.bindings.first)
        let observedBindingMetadata = try #require(
            program.propertyMetadataIndex.metadata(for: observedBinding))
        #expect(!observedBindingMetadata.isComputed)
        #expect(observedBindingMetadata.willSet?.parameterName == "next")
        #expect(observedBindingMetadata.didSet?.parameterName == "previous")

        let tuple = try #require(variables.first {
            $0.bindings.first?.pattern.is(TuplePatternSyntax.self) == true
        })
        let tupleBinding = try #require(tuple.bindings.first)
        let tupleMetadata = try #require(
            program.propertyMetadataIndex.metadata(for: tupleBinding))
        #expect(tupleMetadata.patternKind == .tuple)
        #expect(tupleMetadata.tupleElements.map { $0.name }
            == ["left", "right"])
        #expect(tupleMetadata.tupleElements.map {
            $0.typeAnnotation?.trimmedDescription
        } == ["Int", "String"])

        let interpreter = Interpreter()
        let session = interpreter.makeSession(program: program)
        #expect(session.runtimeEntry.programMetadata?.propertyMetadataIndex
            .summary == expected)
    }

    @Test func propertyMetadataHasPureForeignSyntaxFallback() throws {
        let foreignProgram = try ParsedProgram(source: """
        weak var foreign: NSObject? {
            willSet(next) {}
            didSet(previous) {}
        }
        """)
        let declaration = try #require(
            foreignProgram.syntax.statements.first?.item
                .as(DeclSyntax.self)?.as(VariableDeclSyntax.self))
        let binding = try #require(declaration.bindings.first)
        let interpreter = Interpreter()

        let declarationMetadata = interpreter.propertyMetadata(
            for: declaration)
        let bindingMetadata = interpreter.propertyMetadata(for: binding)
        #expect(declarationMetadata.isMutable)
        #expect(!declarationMetadata.isLazy)
        #expect(declarationMetadata.referenceOwnership == .weak)
        #expect(bindingMetadata.identifierName == "foreign")
        #expect(!bindingMetadata.isComputed)
        #expect(bindingMetadata.willSet?.parameterName == "next")
        #expect(bindingMetadata.didSet?.parameterName == "previous")
    }

    @Test func parsedProgramOwnsSendableEnumCaseMetadataIndex() async throws {
        let program = try ParsedProgram(source: """
        enum User {
            case `default`
            case authenticated(username: String)
            case city(City.ID)

            #if os(iOS)
            case account
            #else
            case orders
            #endif
        }

        enum HeaderSize: Double {
            case standard = 1.0
            case reduced = 0.5
        }

        func localEnum() {
            enum Local { case item(Int) }
        }
        """)
        let expected = ParsedEnumCaseMetadataIndex.Summary(
            enumCaseDeclarationCount: 8,
            caseElementCount: 8,
            associatedValueCaseCount: 3,
            associatedValueCount: 3,
            labeledAssociatedValueCount: 1,
            explicitRawValueCount: 2,
            backtickedNameCount: 1)

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(program.enumCaseMetadataIndex)
        #expect(program.enumCaseMetadataIndex.summary == expected)
        #expect(program.metadata.enumCaseMetadataIndex.summary == expected)

        let readers = (0..<8).map { _ in
            Task.detached { program.enumCaseMetadataIndex.summary }
        }
        var observations: [ParsedEnumCaseMetadataIndex.Summary] = []
        for reader in readers {
            observations.append(await reader.value)
        }
        #expect(observations == Array(repeating: expected, count: 8))

        let enumerations: [EnumDeclSyntax] =
            program.syntax.statements.compactMap {
                guard case .decl(let declaration) = $0.item else {
                    return nil
                }
                return declaration.as(EnumDeclSyntax.self)
            }
        let user = try #require(enumerations.first)
        let userCases = user.memberBlock.members.compactMap {
            $0.decl.as(EnumCaseDeclSyntax.self)?.elements.first
        }
        let defaultCase = try #require(userCases.first)
        let defaultMetadata = try #require(
            program.enumCaseMetadataIndex.metadata(for: defaultCase))
        #expect(defaultMetadata.name == "default")
        #expect(defaultMetadata.wasBackticked)
        #expect(defaultMetadata.associatedValues.isEmpty)
        #expect(defaultMetadata.rawValue == nil)

        let authenticated = try #require(userCases.dropFirst().first)
        let authenticatedMetadata = try #require(
            program.enumCaseMetadataIndex.metadata(for: authenticated))
        #expect(authenticatedMetadata.name == "authenticated")
        #expect(authenticatedMetadata.associatedValues.map(\.label)
            == ["username"])
        #expect(authenticatedMetadata.associatedValues.map(\.typeName)
            == ["String"])

        let city = try #require(userCases.dropFirst(2).first)
        let cityMetadata = try #require(
            program.enumCaseMetadataIndex.metadata(for: city))
        #expect(cityMetadata.associatedValues.map(\.label) == [nil])
        #expect(cityMetadata.associatedValues.map(\.typeName) == ["City.ID"])

        let header = try #require(enumerations.last)
        let headerCases = header.memberBlock.members.compactMap {
            $0.decl.as(EnumCaseDeclSyntax.self)?.elements.first
        }
        let standard = try #require(headerCases.first)
        let standardMetadata = try #require(
            program.enumCaseMetadataIndex.metadata(for: standard))
        #expect(standardMetadata.rawValue?.trimmedDescription == "1.0")

        let interpreter = Interpreter()
        let session = interpreter.makeSession(program: program)
        #expect(session.runtimeEntry.programMetadata?.enumCaseMetadataIndex
            .summary == expected)
    }

    @Test func enumCaseMetadataHasPureForeignSyntaxFallback() throws {
        let foreignProgram = try ParsedProgram(source: """
        enum Foreign: Double {
            case `default` = 0.5
            case value(label: String)
        }
        """)
        let enumeration = try #require(
            foreignProgram.syntax.statements.first?.item
                .as(DeclSyntax.self)?.as(EnumDeclSyntax.self))
        let elements = enumeration.memberBlock.members.compactMap {
            $0.decl.as(EnumCaseDeclSyntax.self)?.elements.first
        }
        let defaultCase = try #require(elements.first)
        let valueCase = try #require(elements.last)
        let interpreter = Interpreter()

        let defaultMetadata = interpreter.enumCaseMetadata(for: defaultCase)
        #expect(defaultMetadata.name == "default")
        #expect(defaultMetadata.wasBackticked)
        #expect(defaultMetadata.rawValue?.trimmedDescription == "0.5")
        let valueMetadata = interpreter.enumCaseMetadata(for: valueCase)
        #expect(valueMetadata.associatedValues.map(\.label) == ["label"])
        #expect(valueMetadata.associatedValues.map(\.typeName) == ["String"])
    }

    @Test func parsedProgramOwnsSendableExtensionMetadataIndex() async throws {
        let program = try ParsedProgram(source: """
        struct Truck {}

        @available(macOS 10, *)
        public extension Truck: Sendable {}

        struct Donut { struct Topping {} }
        private extension Donut.Topping {}

        public extension ClosedRange where Bound: BinaryFloatingPoint {}
        extension LabelStyle where Self == FoodTruckStyle {}

        #if os(iOS)
        extension Truck: Codable {}
        #else
        extension Truck: Hashable, Equatable {}
        #endif
        """)
        let expected = ParsedExtensionMetadataIndex.Summary(
            extensionCount: 6,
            dottedExtendedTypeCount: 1,
            inheritedTypeCount: 4,
            constrainedExtensionCount: 2,
            genericRequirementCount: 2,
            attributedExtensionCount: 1,
            modifiedExtensionCount: 3)

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(program.extensionMetadataIndex)
        #expect(program.extensionMetadataIndex.summary == expected)
        #expect(program.metadata.extensionMetadataIndex.summary == expected)

        let readers = (0..<8).map { _ in
            Task.detached { program.extensionMetadataIndex.summary }
        }
        var observations: [ParsedExtensionMetadataIndex.Summary] = []
        for reader in readers {
            observations.append(await reader.value)
        }
        #expect(observations == Array(repeating: expected, count: 8))

        let extensions: [ExtensionDeclSyntax] =
            program.syntax.statements.compactMap {
                guard case .decl(let declaration) = $0.item else {
                    return nil
                }
                return declaration.as(ExtensionDeclSyntax.self)
            }
        let truck = try #require(extensions.first)
        let truckMetadata = try #require(
            program.extensionMetadataIndex.metadata(for: truck))
        #expect(truckMetadata.extendedTypeName == "Truck")
        #expect(truckMetadata.inheritedTypeNames == ["Sendable"])
        #expect(truckMetadata.attributeNames == ["available"])
        #expect(truckMetadata.modifierNames == ["public"])
        #expect(truckMetadata.genericRequirements.isEmpty)

        let topping = try #require(extensions.dropFirst().first)
        let toppingMetadata = try #require(
            program.extensionMetadataIndex.metadata(for: topping))
        #expect(toppingMetadata.extendedTypeName == "Donut.Topping")
        #expect(toppingMetadata.modifierNames == ["private"])

        let closedRange = try #require(extensions.dropFirst(2).first)
        let rangeMetadata = try #require(
            program.extensionMetadataIndex.metadata(for: closedRange))
        #expect(rangeMetadata.extendedTypeName == "ClosedRange")
        #expect(rangeMetadata.genericRequirements
            == ["Bound: BinaryFloatingPoint"])

        let interpreter = Interpreter()
        let session = interpreter.makeSession(program: program)
        #expect(session.runtimeEntry.programMetadata?.extensionMetadataIndex
            .summary == expected)
    }

    @Test func extensionMetadataHasPureForeignSyntaxFallback() throws {
        let foreignProgram = try ParsedProgram(source: """
        @available(macOS 10, *)
        public extension Foreign.Value: Sendable
        where Element == Int, State: Equatable {}
        """)
        let declaration = try #require(
            foreignProgram.syntax.statements.first?.item
                .as(DeclSyntax.self)?.as(ExtensionDeclSyntax.self))
        let interpreter = Interpreter()

        let metadata = interpreter.extensionMetadata(for: declaration)
        #expect(metadata.extendedTypeName == "Foreign.Value")
        #expect(metadata.inheritedTypeNames == ["Sendable"])
        #expect(metadata.attributeNames == ["available"])
        #expect(metadata.modifierNames == ["public"])
        #expect(metadata.genericRequirements
            == ["Element == Int", "State: Equatable"])
    }

    @Test func parsedProgramOwnsSendableTypeAliasMetadataIndex() async throws {
        let program = try ParsedProgram(source: """
        struct Box<Value> {}

        @available(macOS 10, *)
        public typealias PublicAlias<T> = Module.Box<T> where T: Sendable
        typealias Pair = (Int, Int)

        struct Owner {
            #if os(iOS)
            private typealias Active = Box<Int>
            #else
            fileprivate typealias Active = Box<String>
            #endif
        }

        func local() {
            typealias Local = Box<Double>
        }
        """)
        let expected = ParsedTypeAliasMetadataIndex.Summary(
            typeAliasCount: 5,
            genericTypeAliasCount: 1,
            genericParameterCount: 1,
            genericRequirementCount: 1,
            attributedTypeAliasCount: 1,
            modifiedTypeAliasCount: 3,
            nominalTargetCount: 4,
            dottedTargetCount: 1)

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(program.typeAliasMetadataIndex)
        #expect(program.typeAliasMetadataIndex.summary == expected)
        #expect(program.metadata.typeAliasMetadataIndex.summary == expected)

        let readers = (0..<8).map { _ in
            Task.detached { program.typeAliasMetadataIndex.summary }
        }
        var observations: [ParsedTypeAliasMetadataIndex.Summary] = []
        for reader in readers {
            observations.append(await reader.value)
        }
        #expect(observations == Array(repeating: expected, count: 8))

        let aliases: [TypeAliasDeclSyntax] =
            program.syntax.statements.compactMap {
                guard case .decl(let declaration) = $0.item else {
                    return nil
                }
                return declaration.as(TypeAliasDeclSyntax.self)
            }
        let publicAlias = try #require(aliases.first)
        let metadata = try #require(
            program.typeAliasMetadataIndex.metadata(for: publicAlias))
        #expect(metadata.name == "PublicAlias")
        #expect(metadata.targetTypeName == "Module.Box<T>")
        #expect(metadata.lookupTargetName == "Module.Box")
        #expect(metadata.genericParameters.map(\.name) == ["T"])
        #expect(metadata.genericRequirements == ["T: Sendable"])
        #expect(metadata.attributeNames == ["available"])
        #expect(metadata.modifierNames == ["public"])
        #expect(metadata.isNominalTarget)

        let pair = try #require(aliases.dropFirst().first)
        let pairMetadata = try #require(
            program.typeAliasMetadataIndex.metadata(for: pair))
        #expect(pairMetadata.targetTypeName == "(Int, Int)")
        #expect(!pairMetadata.isNominalTarget)

        let interpreter = Interpreter()
        let session = interpreter.makeSession(program: program)
        #expect(session.runtimeEntry.programMetadata?.typeAliasMetadataIndex
            .summary == expected)
    }

    @Test func typeAliasMetadataHasPureForeignSyntaxFallback() throws {
        let foreignProgram = try ParsedProgram(source: """
        @available(macOS 10, *)
        public typealias Foreign<T: Hashable> = Module.Box<T>
        where T: Sendable
        """)
        let declaration = try #require(
            foreignProgram.syntax.statements.first?.item
                .as(DeclSyntax.self)?.as(TypeAliasDeclSyntax.self))
        let interpreter = Interpreter()

        let metadata = interpreter.typeAliasMetadata(for: declaration)
        #expect(metadata.name == "Foreign")
        #expect(metadata.targetTypeName == "Module.Box<T>")
        #expect(metadata.lookupTargetName == "Module.Box")
        #expect(metadata.genericParameters.map(\.name) == ["T"])
        #expect(metadata.genericParameters.map(\.inheritedTypeName)
            == ["Hashable"])
        #expect(metadata.genericRequirements == ["T: Sendable"])
        #expect(metadata.attributeNames == ["available"])
        #expect(metadata.modifierNames == ["public"])
        #expect(metadata.isNominalTarget)
    }

    @Test func parsedProgramMetadataIsOneSendableRuntimeCapability()
    async throws {
        let program = try ParsedProgram(source: """
        struct Marker {}
        enum Phase { case ready }
        extension Phase {}
        typealias MarkerAlias = Marker
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
        #expect(program.metadata.propertyMetadataIndex.summary
            == program.propertyMetadataIndex.summary)
        #expect(program.metadata.enumCaseMetadataIndex.summary
            == program.enumCaseMetadataIndex.summary)
        #expect(program.metadata.extensionMetadataIndex.summary
            == program.extensionMetadataIndex.summary)
        #expect(program.metadata.typeAliasMetadataIndex.summary
            == program.typeAliasMetadataIndex.summary)

        let readers = (0..<8).map { _ in
            Task.detached {
                [
                    program.metadata.declarationIndex.summary
                        .possiblePrimaryDeclarationCount,
                    program.metadata.callableMetadataIndex.summary.functionCount,
                    program.metadata.nominalMetadataIndex.summary.structureCount,
                    program.metadata.propertyMetadataIndex.summary.bindingCount,
                    program.metadata.enumCaseMetadataIndex.summary.caseElementCount,
                    program.metadata.extensionMetadataIndex.summary.extensionCount,
                    program.metadata.typeAliasMetadataIndex.summary.typeAliasCount
                ]
            }
        }
        var observations: [[Int]] = []
        for reader in readers {
            observations.append(await reader.value)
        }
        #expect(observations.allSatisfy { $0 == [3, 1, 1, 0, 1, 1, 1] })

        let interpreter = Interpreter()
        let session = interpreter.makeSession(program: program)
        #expect(session.runtimeEntry.programMetadata?.callableMetadataIndex
            .summary == program.callableMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.nominalMetadataIndex
            .summary == program.nominalMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.propertyMetadataIndex
            .summary == program.propertyMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.enumCaseMetadataIndex
            .summary == program.enumCaseMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.extensionMetadataIndex
            .summary == program.extensionMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.typeAliasMetadataIndex
            .summary == program.typeAliasMetadataIndex.summary)
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
