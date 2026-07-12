import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// A cached, executable contract for one declaration exposed by an embedder.
///
/// The declaration is deliberately Swift-shaped and framework-independent:
///
/// ```swift
/// func distance(_ lhs: Double, _ rhs: Double) -> Double
/// init URL?(string: String)
/// func URL.appendingPathComponent(_ component: String) -> URL
/// static func Int.random(in range: Range<Int>) -> Int
/// var DateFormatter.dateFormat: String
/// static let Int.max: Int
/// ```
///
/// SwiftParser owns the grammar. `HostSignature` retains only the metadata
/// needed at runtime, so a declaration is parsed once when its gateway is
/// registered rather than reparsed at every call.
public struct HostSignature: Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case function
        case initializer
        case method
        case staticMethod
        case property
        case staticProperty
    }

    public struct Parameter: Sendable, Equatable {
        /// External label at the source call site. `nil` represents `_`.
        public let label: String?
        /// Internal parameter name, used in diagnostics.
        public let name: String
        /// Swift type spelling, with attributes but without a variadic `...`.
        public let type: String
        public let defaultValue: String?
        public let isVariadic: Bool

        public var hasDefault: Bool { defaultValue != nil }
    }

    public struct GenericParameter: Sendable, Equatable {
        public let name: String
        public let constraints: [String]
    }

    public let declaration: String
    public let kind: Kind
    public let receiverType: String?
    public let name: String
    public let parameters: [Parameter]
    public let genericParameters: [GenericParameter]
    /// `nil` is a `Void` return for functions and methods.
    public let returnType: String?
    public let isAsync: Bool
    public let isThrowing: Bool
    public let isFailable: Bool
    public let isSettable: Bool

    public var description: String { declaration }

    /// The lookup name used by `HostFunction` and `HostRegistry`.
    public var callableName: String {
        kind == .initializer ? (receiverType ?? name) : name
    }

    public var isCallable: Bool {
        switch kind {
        case .function, .initializer, .method, .staticMethod: true
        case .property, .staticProperty: false
        }
    }

    public init(parsing declaration: String) throws {
        self = try Self.parse(declaration)
    }

    private init(
        declaration: String,
        kind: Kind,
        receiverType: String?,
        name: String,
        parameters: [Parameter],
        genericParameters: [GenericParameter],
        returnType: String?,
        isAsync: Bool,
        isThrowing: Bool,
        isFailable: Bool,
        isSettable: Bool
    ) {
        self.declaration = declaration
        self.kind = kind
        self.receiverType = receiverType
        self.name = name
        self.parameters = parameters
        self.genericParameters = genericParameters
        self.returnType = returnType
        self.isAsync = isAsync
        self.isThrowing = isThrowing
        self.isFailable = isFailable
        self.isSettable = isSettable
    }

    public static func parse(_ rawDeclaration: String) throws -> HostSignature {
        let declaration = rawDeclaration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !declaration.isEmpty else {
            throw HostSignatureError.invalidDeclaration(
                declaration: rawDeclaration, reason: "declaration is empty")
        }

        if declaration.hasPrefix("static func ") {
            return try parseFunction(
                declaration, prefix: "static func ", isStatic: true)
        }
        if declaration.hasPrefix("func ") {
            return try parseFunction(
                declaration, prefix: "func ", isStatic: false)
        }
        if declaration.hasPrefix("init? ") {
            return try parseInitializer(
                declaration, prefix: "init? ", prefixIsFailable: true)
        }
        if declaration.hasPrefix("init! ") {
            return try parseInitializer(
                declaration, prefix: "init! ", prefixIsFailable: true)
        }
        if declaration.hasPrefix("init ") {
            return try parseInitializer(
                declaration, prefix: "init ", prefixIsFailable: false)
        }
        for (prefix, isStatic, isVariable) in [
            ("static var ", true, true),
            ("static let ", true, false),
            ("var ", false, true),
            ("let ", false, false),
        ] {
            if declaration.hasPrefix(prefix) {
                return try parseProperty(
                    declaration, prefix: prefix,
                    isStatic: isStatic, isVariable: isVariable)
            }
        }

        throw HostSignatureError.unsupportedDeclaration(declaration)
    }
}

public enum HostSignatureError: Error, CustomStringConvertible, Equatable {
    case unsupportedDeclaration(String)
    case invalidDeclaration(declaration: String, reason: String)
    case invalidRegistration(declaration: String, reason: String)

    public var description: String {
        switch self {
        case .unsupportedDeclaration(let declaration):
            return "unsupported host declaration '\(declaration)'"
        case .invalidDeclaration(let declaration, let reason):
            return "invalid host declaration '\(declaration)': \(reason)"
        case .invalidRegistration(let declaration, let reason):
            return "invalid host registration for '\(declaration)': \(reason)"
        }
    }
}

/// The successful result of matching evaluated arguments against a host
/// declaration. Generic bindings are retained for validating the return value
/// (`identity<T>(_: T) -> T`) and score drives deterministic overload choice.
public struct HostCallMatch: Sendable, Equatable {
    public let genericBindings: [String: String]
    public let score: Int

    let parameterIndices: [Int]

    init(
        genericBindings: [String: String], score: Int,
        parameterIndices: [Int]
    ) {
        self.genericBindings = genericBindings
        self.score = score
        self.parameterIndices = parameterIndices
    }
}

// MARK: - Parsing

private extension HostSignature {
    struct ParsedFunction {
        let parameters: [Parameter]
        let generics: [GenericParameter]
        let returnType: String?
        let isAsync: Bool
        let isThrowing: Bool
    }

    static func parseFunction(
        _ declaration: String, prefix: String, isStatic: Bool
    ) throws -> HostSignature {
        let body = String(declaration.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard let parameterStart = firstTopLevelIndex(of: "(", in: body) else {
            throw HostSignatureError.invalidDeclaration(
                declaration: declaration, reason: "missing parameter clause")
        }

        let qualifiedAndGenerics = String(body[..<parameterStart])
        let dot = lastTopLevelIndex(of: ".", in: qualifiedAndGenerics)
        let receiver: String?
        let memberAndGenerics: String
        if let dot {
            receiver = String(qualifiedAndGenerics[..<dot])
                .trimmingCharacters(in: .whitespaces)
            memberAndGenerics = String(qualifiedAndGenerics[
                qualifiedAndGenerics.index(after: dot)...])
        } else {
            receiver = nil
            memberAndGenerics = qualifiedAndGenerics
        }

        if isStatic, receiver == nil {
            throw HostSignatureError.invalidDeclaration(
                declaration: declaration,
                reason: "a static method must name its receiver type")
        }

        let genericStart = firstTopLevelIndex(of: "<", in: memberAndGenerics)
        let memberName: String
        let genericClause: String
        if let genericStart {
            memberName = String(memberAndGenerics[..<genericStart])
                .trimmingCharacters(in: .whitespaces)
            genericClause = String(memberAndGenerics[genericStart...])
        } else {
            memberName = memberAndGenerics.trimmingCharacters(in: .whitespaces)
            genericClause = ""
        }
        guard !memberName.isEmpty else {
            throw HostSignatureError.invalidDeclaration(
                declaration: declaration, reason: "missing function name")
        }

        let tail = genericClause + body[parameterStart...]
        let parsed = try parseSyntheticFunction(
            "func __host\(tail) {}", original: declaration)
        return HostSignature(
            declaration: declaration,
            kind: receiver == nil ? .function : (isStatic ? .staticMethod : .method),
            receiverType: receiver,
            name: memberName,
            parameters: parsed.parameters,
            genericParameters: parsed.generics,
            returnType: parsed.returnType,
            isAsync: parsed.isAsync,
            isThrowing: parsed.isThrowing,
            isFailable: false,
            isSettable: false)
    }

    static func parseInitializer(
        _ declaration: String, prefix: String, prefixIsFailable: Bool
    ) throws -> HostSignature {
        let body = String(declaration.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard let parameterStart = firstTopLevelIndex(of: "(", in: body) else {
            throw HostSignatureError.invalidDeclaration(
                declaration: declaration, reason: "missing parameter clause")
        }
        var receiver = String(body[..<parameterStart])
            .trimmingCharacters(in: .whitespaces)
        var isFailable = prefixIsFailable
        if receiver.hasSuffix("?") || receiver.hasSuffix("!") {
            receiver.removeLast()
            receiver = receiver.trimmingCharacters(in: .whitespaces)
            isFailable = true
        }
        guard !receiver.isEmpty else {
            throw HostSignatureError.invalidDeclaration(
                declaration: declaration, reason: "missing initialized type")
        }

        let tail = String(body[parameterStart...])
        let split = splitTopLevelWhereClause(tail)
        let returnType = receiver + (isFailable ? "?" : "")
        let synthetic = "func __host\(split.head) -> \(returnType)\(split.whereClause) {}"
        let parsed = try parseSyntheticFunction(synthetic, original: declaration)
        return HostSignature(
            declaration: declaration,
            kind: .initializer,
            receiverType: receiver,
            name: receiver,
            parameters: parsed.parameters,
            genericParameters: parsed.generics,
            returnType: returnType,
            isAsync: parsed.isAsync,
            isThrowing: parsed.isThrowing,
            isFailable: isFailable,
            isSettable: false)
    }

    static func parseProperty(
        _ declaration: String, prefix: String,
        isStatic: Bool, isVariable: Bool
    ) throws -> HostSignature {
        let body = String(declaration.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard let colon = firstTopLevelIndex(of: ":", in: body) else {
            throw HostSignatureError.invalidDeclaration(
                declaration: declaration, reason: "missing property type")
        }
        let qualifiedName = String(body[..<colon])
            .trimmingCharacters(in: .whitespaces)
        guard let dot = lastTopLevelIndex(of: ".", in: qualifiedName) else {
            throw HostSignatureError.invalidDeclaration(
                declaration: declaration,
                reason: "a property must name its receiver type")
        }
        let receiver = String(qualifiedName[..<dot])
            .trimmingCharacters(in: .whitespaces)
        let name = String(qualifiedName[qualifiedName.index(after: dot)...])
            .trimmingCharacters(in: .whitespaces)
        guard !receiver.isEmpty, !name.isEmpty else {
            throw HostSignatureError.invalidDeclaration(
                declaration: declaration, reason: "incomplete property name")
        }

        let typeAndAccessors = String(body[body.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        let accessorStart = firstTopLevelIndex(of: "{", in: typeAndAccessors)
        let type: String
        let accessors: String?
        if let accessorStart {
            type = String(typeAndAccessors[..<accessorStart])
                .trimmingCharacters(in: .whitespaces)
            accessors = String(typeAndAccessors[accessorStart...])
        } else {
            type = typeAndAccessors
            accessors = nil
        }
        guard !type.isEmpty else {
            throw HostSignatureError.invalidDeclaration(
                declaration: declaration, reason: "property type is empty")
        }

        // Validate both the type and accessor grammar using a protocol member;
        // unlike a concrete stored property this permits `{ get set }`.
        let tree = Parser.parse(source:
            "protocol __HostProperty { var __value: \(typeAndAccessors) }")
        try rejectParseErrors(in: tree, original: declaration)

        let accessorWords = Set((accessors ?? "")
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init))
        let isSettable = isVariable
            && (accessors == nil || accessorWords.contains("set"))
        return HostSignature(
            declaration: declaration,
            kind: isStatic ? .staticProperty : .property,
            receiverType: receiver,
            name: name,
            parameters: [],
            genericParameters: [],
            returnType: type,
            isAsync: accessorWords.contains("async"),
            isThrowing: accessorWords.contains("throws")
                || accessorWords.contains("rethrows"),
            isFailable: false,
            isSettable: isSettable)
    }

    static func parseSyntheticFunction(
        _ source: String, original: String
    ) throws -> ParsedFunction {
        let tree = Parser.parse(source: source)
        try rejectParseErrors(in: tree, original: original)
        guard let function = tree.statements.first?.item.as(FunctionDeclSyntax.self) else {
            throw HostSignatureError.invalidDeclaration(
                declaration: original, reason: "not a function declaration")
        }

        let parameters = function.signature.parameterClause.parameters.map { parameter in
            let first = parameter.firstName.text
            let label = first == "_" ? nil : first
            let name = parameter.secondName?.text ?? first
            let attributes = parameter.attributes.description
                .trimmingCharacters(in: .whitespaces)
            let modifiers = parameter.modifiers.description
                .trimmingCharacters(in: .whitespaces)
            let type = [attributes, modifiers, parameter.type.trimmedDescription]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return Parameter(
                label: label,
                name: name == "_" ? "argument" : name,
                type: type,
                defaultValue: parameter.defaultValue?.value.trimmedDescription,
                isVariadic: parameter.ellipsis != nil)
        }

        var generics: [GenericParameter] = []
        if let genericClause = function.genericParameterClause {
            for parameter in genericClause.parameters {
                let inherited = parameter.inheritedType?.trimmedDescription ?? ""
                generics.append(GenericParameter(
                    name: parameter.name.text,
                    constraints: splitComposition(inherited)))
            }
        }
        if let whereClause = function.genericWhereClause {
            for requirement in whereClause.requirements {
                guard let conformance = requirement.requirement
                    .as(ConformanceRequirementSyntax.self) else { continue }
                let name = conformance.leftType.trimmedDescription
                guard let index = generics.firstIndex(where: { $0.name == name }) else {
                    continue
                }
                let constraints = splitComposition(
                    conformance.rightType.trimmedDescription)
                generics[index] = GenericParameter(
                    name: generics[index].name,
                    constraints: generics[index].constraints + constraints)
            }
        }

        return ParsedFunction(
            parameters: parameters,
            generics: generics,
            returnType: function.signature.returnClause?.type.trimmedDescription,
            isAsync: function.signature.effectSpecifiers?.asyncSpecifier != nil,
            isThrowing: function.signature.effectSpecifiers?.throwsClause != nil)
    }

    static func rejectParseErrors(
        in tree: SourceFileSyntax, original: String
    ) throws {
        if let diagnostic = ParseDiagnosticsGenerator.diagnostics(for: tree)
            .first(where: { $0.diagMessage.severity == .error }) {
            throw HostSignatureError.invalidDeclaration(
                declaration: original, reason: diagnostic.message)
        }
    }

    static func splitComposition(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return splitTopLevel(text, separator: "&")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func splitTopLevelWhereClause(
        _ text: String
    ) -> (head: String, whereClause: String) {
        guard let range = topLevelRange(of: " where ", in: text) else {
            return (text, "")
        }
        return (String(text[..<range.lowerBound]), String(text[range.lowerBound...]))
    }
}



// MARK: - Text scanning helpers

func firstTopLevelIndex(of character: Character, in text: String) -> String.Index? {
    var angle = 0
    var square = 0
    var paren = 0
    for index in text.indices {
        let current = text[index]
        if current == character, angle == 0, square == 0, paren == 0 {
            return index
        }
        switch current {
        case "<": angle += 1
        case ">": angle = max(0, angle - 1)
        case "[": square += 1
        case "]": square = max(0, square - 1)
        case "(": paren += 1
        case ")": paren = max(0, paren - 1)
        default: break
        }
    }
    return nil
}

func lastTopLevelIndex(of character: Character, in text: String) -> String.Index? {
    var result: String.Index?
    var angle = 0
    var square = 0
    var paren = 0
    for index in text.indices {
        let current = text[index]
        if current == character, angle == 0, square == 0, paren == 0 {
            result = index
        }
        switch current {
        case "<": angle += 1
        case ">": angle = max(0, angle - 1)
        case "[": square += 1
        case "]": square = max(0, square - 1)
        case "(": paren += 1
        case ")": paren = max(0, paren - 1)
        default: break
        }
    }
    return result
}

func topLevelRange(of needle: String, in text: String) -> Range<String.Index>? {
    var search = text.startIndex
    while search < text.endIndex,
          let range = text.range(of: needle, range: search..<text.endIndex) {
        let prefix = String(text[..<range.lowerBound])
        if nestingDepth(of: prefix) == (0, 0, 0) { return range }
        search = range.upperBound
    }
    return nil
}

func nestingDepth(of text: String) -> (Int, Int, Int) {
    var angle = 0
    var square = 0
    var paren = 0
    for character in text {
        switch character {
        case "<": angle += 1
        case ">": angle = max(0, angle - 1)
        case "[": square += 1
        case "]": square = max(0, square - 1)
        case "(": paren += 1
        case ")": paren = max(0, paren - 1)
        default: break
        }
    }
    return (angle, square, paren)
}

func splitTopLevel(_ text: String, separator: Character) -> [String] {
    var pieces: [String] = []
    var start = text.startIndex
    var angle = 0
    var square = 0
    var paren = 0
    for index in text.indices {
        let current = text[index]
        if current == separator, angle == 0, square == 0, paren == 0 {
            pieces.append(String(text[start..<index]))
            start = text.index(after: index)
            continue
        }
        switch current {
        case "<": angle += 1
        case ">": angle = max(0, angle - 1)
        case "[": square += 1
        case "]": square = max(0, square - 1)
        case "(": paren += 1
        case ")": paren = max(0, paren - 1)
        default: break
        }
    }
    pieces.append(String(text[start...]))
    return pieces.map { $0.trimmingCharacters(in: .whitespaces) }
}

func outerContents(
    _ text: String, opening: Character, closing: Character
) -> String? {
    guard text.first == opening, text.last == closing else { return nil }
    return String(text.dropFirst().dropLast())
}

func isFunctionType(_ rawType: String) -> Bool {
    let type = rawType.trimmingCharacters(in: .whitespaces)
    return topLevelRange(of: "->", in: type) != nil || type.contains("->")
}
