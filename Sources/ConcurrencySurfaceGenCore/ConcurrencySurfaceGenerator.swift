import Foundation
import SwiftParser
import SwiftSyntax

public enum ConcurrencySurfaceGenerationError: Error,
    CustomStringConvertible, Equatable {
    case commandFailed(String)
    case interfaceNotFound(String)
    case missingIntrinsics([String])
    case missingFunctions([String])
    case missingTaskIntrinsics([String])

    public var description: String {
        switch self {
        case .commandFailed(let command):
            "command failed: \(command)"
        case .interfaceNotFound(let root):
            "could not locate _Concurrency.swiftinterface below \(root)"
        case .missingIntrinsics(let names):
            "active _Concurrency.swiftinterface is missing required task-group "
                + "members: \(names.joined(separator: ", "))"
        case .missingFunctions(let names):
            "active _Concurrency.swiftinterface is missing required task-group "
                + "functions: \(names.joined(separator: ", "))"
        case .missingTaskIntrinsics(let names):
            "active _Concurrency.swiftinterface is missing required Task "
                + "members: \(names.joined(separator: ", "))"
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
    public let taskStaticDispatch: [String: String]
    public let knownTaskStaticMembers: Set<String>
    public let taskStaticMemberDeclarations:
        [String: [ConcurrencySurfaceDeclaration]]
    public let taskGroupDispatch: [String: [String: String]]
    public let knownTaskGroupMembers: [String: Set<String>]
    public let taskGroupFunctions: Set<String>
    public let taskGroupMemberDeclarations:
        [String: [String: [ConcurrencySurfaceDeclaration]]]
    public let taskGroupFunctionDeclarations:
        [String: [ConcurrencySurfaceDeclaration]]
}

public enum ConcurrencySurfaceGenerator {
    public static let taskGroupTypes = [
        "DiscardingTaskGroup", "TaskGroup", "ThrowingDiscardingTaskGroup",
        "ThrowingTaskGroup",
    ]

    private static let supportedIntrinsics: Set<String> = [
        "addTask", "addTaskUnlessCancelled", "waitForAll", "next",
        "cancelAll", "isCancelled", "isEmpty",
    ]
    private static let supportedTaskStaticIntrinsics: Set<String> = [
        "checkCancellation", "currentPriority", "detached", "isCancelled",
        "sleep", "yield",
    ]
    private static let requiredIntrinsicsByType: [String: Set<String>] = [
        "DiscardingTaskGroup": [
            "addTask", "addTaskUnlessCancelled", "cancelAll", "isCancelled",
            "isEmpty",
        ],
        "TaskGroup": supportedIntrinsics,
        "ThrowingDiscardingTaskGroup": [
            "addTask", "addTaskUnlessCancelled", "cancelAll", "isCancelled",
            "isEmpty",
        ],
        "ThrowingTaskGroup": supportedIntrinsics,
    ]
    private static let requiredTaskGroupFunctions: Set<String> = [
        "withDiscardingTaskGroup", "withTaskGroup",
        "withThrowingDiscardingTaskGroup", "withThrowingTaskGroup",
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
        let syntax = Parser.parse(source: interfaceSource)
        let taskGroupTypeSet = Set(taskGroupTypes)
        let globalActorNames = globalActors(in: syntax)
        var knownNames = Dictionary(uniqueKeysWithValues:
            taskGroupTypes.map { ($0, Set<String>()) })
        var dispatch = Dictionary(uniqueKeysWithValues:
            taskGroupTypes.map { ($0, [String: String]()) })
        var memberDeclarations = Dictionary(uniqueKeysWithValues:
            taskGroupTypes.map {
                ($0, [String: [ConcurrencySurfaceDeclaration]]())
            })
        var knownFunctions: Set<String> = []
        var functionDeclarations: [String: [ConcurrencySurfaceDeclaration]] = [:]
        var knownTaskStaticMembers: Set<String> = []
        var taskStaticDispatch: [String: String] = [:]
        var taskStaticMemberDeclarations:
            [String: [ConcurrencySurfaceDeclaration]] = [:]

        for statement in syntax.statements {
            guard case .decl(let declaration) = statement.item else { continue }
            if let function = declaration.as(FunctionDeclSyntax.self),
               isPublic(function.modifiers) {
                let name = function.name.text
                knownFunctions.insert(name)
                if requiredTaskGroupFunctions.contains(name) {
                    appendUnique(
                        declarationMetadata(
                            function, globalActorNames: globalActorNames),
                        to: &functionDeclarations[name, default: []])
                }
                continue
            }

            let typeName: String?
            let members: MemberBlockItemListSyntax?
            if let structure = declaration.as(StructDeclSyntax.self) {
                typeName = structure.name.text
                members = structure.memberBlock.members
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
                inspectTaskStatics(
                    members,
                    globalActorNames: globalActorNames,
                    knownNames: &knownTaskStaticMembers,
                    dispatch: &taskStaticDispatch,
                    declarations: &taskStaticMemberDeclarations)
                continue
            }
            guard taskGroupTypeSet.contains(typeName) else { continue }
            inspect(
                members,
                globalActorNames: globalActorNames,
                knownNames: &knownNames[typeName, default: []],
                dispatch: &dispatch[typeName, default: [:]],
                declarations: &memberDeclarations[typeName, default: [:]])
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
        let missingFunctions = requiredTaskGroupFunctions
            .subtracting(knownFunctions).sorted()
        guard missingFunctions.isEmpty else {
            throw ConcurrencySurfaceGenerationError.missingFunctions(
                missingFunctions)
        }
        let missingTaskIntrinsics = supportedTaskStaticIntrinsics
            .subtracting(taskStaticDispatch.values).sorted()
        guard missingTaskIntrinsics.isEmpty else {
            throw ConcurrencySurfaceGenerationError.missingTaskIntrinsics(
                missingTaskIntrinsics)
        }

        for typeName in taskGroupTypes {
            for member in memberDeclarations[typeName, default: [:]].keys {
                memberDeclarations[typeName]?[member]?.sort {
                    $0.declaration < $1.declaration
                }
            }
        }
        for name in functionDeclarations.keys {
            functionDeclarations[name]?.sort {
                $0.declaration < $1.declaration
            }
        }
        for name in taskStaticMemberDeclarations.keys {
            taskStaticMemberDeclarations[name]?.sort {
                $0.declaration < $1.declaration
            }
        }
        return ConcurrencySurfaceInventory(
            taskStaticDispatch: taskStaticDispatch,
            knownTaskStaticMembers: knownTaskStaticMembers,
            taskStaticMemberDeclarations: taskStaticMemberDeclarations,
            taskGroupDispatch: dispatch,
            knownTaskGroupMembers: knownNames,
            taskGroupFunctions: requiredTaskGroupFunctions,
            taskGroupMemberDeclarations: memberDeclarations,
            taskGroupFunctionDeclarations: functionDeclarations)
    }

    public static func generatedSource(
        interfacePath: String,
        interfaceSource: String
    ) throws -> String {
        let inventory = try inventory(interfaceSource: interfaceSource)
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
        let functionLines = inventory.taskGroupFunctions.sorted().map {
            "        \"\(escaped($0))\","
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
        let functionDeclarationLines = inventory.taskGroupFunctions.sorted()
            .map { name in
                let declarations = inventory.taskGroupFunctionDeclarations[
                    name, default: []].map {
                        "            \(render($0)),"
                    }.joined(separator: "\n")
                return "        \"\(escaped(name))\": [\n"
                    + declarations + "\n        ],"
            }.joined(separator: "\n")
        let compilerVersion = interfaceSource.split(separator: "\n").first {
            $0.hasPrefix("// swift-compiler-version:")
        }.map(String.init) ?? "// swift-compiler-version: unknown"

        return """
        // GENERATED by ConcurrencySurfaceGen from the active _Concurrency.swiftinterface.
        // Do not edit. Regenerate: swift run ConcurrencySurfaceGen
        // Source: \(portableInterfaceLabel(interfacePath))
        \(compilerVersion)

        enum RuntimeTaskStaticIntrinsic: String, Sendable {
        \(taskStaticIntrinsicCaseLines)
        }

        enum RuntimeTaskGroupIntrinsic: String, Sendable {
            case addTask
            case addTaskUnlessCancelled
            case waitForAll
            case next
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

            static let taskGroupDispatch: [
                String: [String: RuntimeTaskGroupIntrinsic]
            ] = [
        \(dispatchBlocks)
            ]

            static let knownTaskGroupMembers: [String: Set<String>] = [
        \(knownBlocks)
            ]

            static let taskGroupFunctions: Set<String> = [
        \(functionLines)
            ]

            static let taskGroupMemberDeclarations: [
                String: [String: [GeneratedConcurrencyDeclaration]]
            ] = [
        \(memberDeclarationBlocks)
            ]

            static let taskGroupFunctionDeclarations: [
                String: [GeneratedConcurrencyDeclaration]
            ] = [
        \(functionDeclarationLines)
            ]

            static func intrinsic(
                typeName: String, memberName: String
            ) -> RuntimeTaskGroupIntrinsic? {
                taskGroupDispatch[typeName]?[memberName]
            }

            static func taskStaticIntrinsic(
                memberName: String
            ) -> RuntimeTaskStaticIntrinsic? {
                taskStaticDispatch[memberName]
            }

            static func knowsTaskStaticMember(_ memberName: String) -> Bool {
                knownTaskStaticMembers.contains(memberName)
            }

            static func knowsMember(
                typeName: String, memberName: String
            ) -> Bool {
                knownTaskGroupMembers[typeName]?.contains(memberName) == true
            }
        }
        """ + "\n"
    }

    private static func command(
        _ executable: String, _ arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConcurrencySurfaceGenerationError.commandFailed(
                ([executable] + arguments).joined(separator: " "))
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

    private static func inspectTaskStatics(
        _ members: MemberBlockItemListSyntax,
        globalActorNames: Set<String>,
        knownNames: inout Set<String>,
        dispatch: inout [String: String],
        declarations: inout [String: [ConcurrencySurfaceDeclaration]]
    ) {
        for item in members {
            if let function = item.decl.as(FunctionDeclSyntax.self),
               isPublic(function.modifiers),
               isStatic(function.modifiers) {
                let name = function.name.text
                knownNames.insert(name)
                appendUnique(
                    declarationMetadata(
                        function, globalActorNames: globalActorNames),
                    to: &declarations[name, default: []])
                if supportedTaskStaticIntrinsics.contains(name) {
                    dispatch[name] = name
                }
                continue
            }
            guard let variable = item.decl.as(VariableDeclSyntax.self),
                  isPublic(variable.modifiers),
                  isStatic(variable.modifiers) else { continue }
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
                if supportedTaskStaticIntrinsics.contains(name) {
                    dispatch[name] = name
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
}
