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
    /// Declaration attributes retained for compiler-preflight serialization.
    /// Runtime dispatch does not reinterpret global-actor or availability
    /// attributes; the native compiler consumes their original spelling.
    public let attributes: [String]
    /// Source declaration modifiers such as `public` or `nonisolated`.
    public let modifiers: [String]
    /// `nil` is a `Void` return for functions and methods.
    public let returnType: String?
    public let isAsync: Bool
    public let isThrowing: Bool
    public let isFailable: Bool
    public let isSettable: Bool
    /// Native declaration spelling used by compiler preflight. Top-level
    /// functions retain their source spelling; qualified host DSL members
    /// (`func String.member`) retain a Swift-valid member spelling with the
    /// receiver qualifier removed (`func member`).
    let compilerPreflightDeclaration: String?
    /// UTF-8 offset of `func`, `init`, `var`, or `let` in
    /// `compilerPreflightDeclaration`, used to export otherwise access-neutral
    /// runtime contracts without reprinting their syntax.
    let compilerPreflightAccessInsertionUTF8Offset: Int?
    /// Exact getter effect spelling retained from SwiftSyntax (`throws`,
    /// `throws(Failure)`, or `async throws`). Compiler preflight uses this
    /// rather than reducing typed throws to the runtime Boolean flags.
    let compilerPreflightGetterEffects: String?

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
        isSettable: Bool,
        attributes: [String] = [],
        modifiers: [String] = [],
        compilerPreflightDeclaration: String? = nil,
        compilerPreflightAccessInsertionUTF8Offset: Int? = nil,
        compilerPreflightGetterEffects: String? = nil
    ) {
        self.declaration = declaration
        self.kind = kind
        self.receiverType = receiverType
        self.name = name
        self.parameters = parameters
        self.genericParameters = genericParameters
        self.attributes = attributes
        self.modifiers = modifiers
        self.returnType = returnType
        self.isAsync = isAsync
        self.isThrowing = isThrowing
        self.isFailable = isFailable
        self.isSettable = isSettable
        self.compilerPreflightDeclaration = compilerPreflightDeclaration
        self.compilerPreflightAccessInsertionUTF8Offset =
            compilerPreflightAccessInsertionUTF8Offset
        self.compilerPreflightGetterEffects = compilerPreflightGetterEffects
    }

    public static func parse(_ rawDeclaration: String) throws -> HostSignature {
        let declaration = rawDeclaration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !declaration.isEmpty else {
            throw HostSignatureError.invalidDeclaration(
                declaration: rawDeclaration, reason: "declaration is empty")
        }

        if let qualifiedMember = try parseQualifiedMemberIfPresent(
            declaration
        ) {
            return qualifiedMember
        }

        if let nativeTopLevel = try parseNativeTopLevelFunctionIfPresent(
            declaration
        ) {
            return nativeTopLevel
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

    enum QualifiedMemberIntroducer: String {
        case function = "func "
        case initializer = "init "
        case failableInitializer = "init? "
        case implicitlyUnwrappedInitializer = "init! "
        case variable = "var "
        case constant = "let "
    }

    struct QualifiedMemberIntroducerMatch {
        let kind: QualifiedMemberIntroducer
        let range: Range<String.Index>
    }

    /// Parses the established receiver-qualified host DSL through a
    /// Swift-valid synthetic member declaration. This keeps runtime lookup
    /// (`func String.member`) compact while retaining the exact attributes,
    /// modifiers, effects, and defaults that the compiler must see in an
    /// `extension String { func member ... }` declaration.
    static func parseQualifiedMemberIfPresent(
        _ declaration: String
    ) throws -> HostSignature? {
        guard let match = firstQualifiedMemberIntroducer(in: declaration)
        else { return nil }

        let leading = String(declaration[..<match.range.lowerBound])
        let suffix = String(declaration[match.range.upperBound...])
        switch match.kind {
        case .function:
            guard let parameterStart = firstTopLevelIndex(of: "(", in: suffix)
            else { return nil }
            let qualifiedAndGenerics = String(suffix[..<parameterStart])
            guard let dot = lastTopLevelIndex(of: ".", in: qualifiedAndGenerics)
            else { return nil }
            let receiver = String(qualifiedAndGenerics[..<dot])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let memberAndGenerics = String(qualifiedAndGenerics[
                qualifiedAndGenerics.index(after: dot)...])
            guard !receiver.isEmpty,
                  !memberAndGenerics.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty else {
                throw HostSignatureError.invalidDeclaration(
                    declaration: declaration,
                    reason: "incomplete qualified function name")
            }

            let nativeMember = normalizedCompilerDeclaration(
                leading + "func " + memberAndGenerics
                    + String(suffix[parameterStart...]))
            let tree = Parser.parse(source:
                "extension \(receiver) {\n\(nativeMember) {}\n}")
            try rejectParseErrors(in: tree, original: declaration)
            guard let extensionDeclaration = tree.statements.first?.item.as(
                    ExtensionDeclSyntax.self),
                  extensionDeclaration.memberBlock.members.count == 1,
                  let function = extensionDeclaration.memberBlock.members.first?
                    .decl.as(FunctionDeclSyntax.self) else {
                throw HostSignatureError.invalidDeclaration(
                    declaration: declaration,
                    reason: "expected one receiver-qualified function")
            }

            let genericStart = firstTopLevelIndex(
                of: "<", in: memberAndGenerics)
            let genericClause = genericStart.map {
                String(memberAndGenerics[$0...])
            } ?? ""
            let parsed = try parseSyntheticFunction(
                "func __host\(genericClause)\(suffix[parameterStart...]) {}",
                original: declaration)
            let modifiers = function.modifiers.map(\.trimmedDescription)
            let isStatic = modifiers.contains("static")
                || modifiers.contains("class")
            return HostSignature(
                declaration: declaration,
                kind: isStatic ? .staticMethod : .method,
                receiverType: receiver,
                name: function.name.text,
                parameters: parsed.parameters,
                genericParameters: parsed.generics,
                returnType: parsed.returnType,
                isAsync: parsed.isAsync,
                isThrowing: parsed.isThrowing,
                isFailable: false,
                isSettable: false,
                attributes: function.attributes.map(\.trimmedDescription),
                modifiers: modifiers,
                compilerPreflightDeclaration: nativeMember,
                compilerPreflightAccessInsertionUTF8Offset:
                    introducerUTF8Offset(
                        .function, in: nativeMember, original: declaration))

        case .variable, .constant:
            guard let colon = firstTopLevelIndex(of: ":", in: suffix) else {
                return nil
            }
            let qualifiedName = String(suffix[..<colon])
            guard let dot = lastTopLevelIndex(of: ".", in: qualifiedName)
            else { return nil }
            let receiver = String(qualifiedName[..<dot])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let memberName = String(qualifiedName[
                qualifiedName.index(after: dot)...])
            guard !receiver.isEmpty,
                  !memberName.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty else {
                throw HostSignatureError.invalidDeclaration(
                    declaration: declaration,
                    reason: "incomplete qualified property name")
            }

            let nativeMember = normalizedCompilerDeclaration(
                leading + match.kind.rawValue + memberName
                    + String(suffix[colon...]))
            let tree = Parser.parse(source:
                "protocol __HostProperty {\n\(nativeMember)\n}")
            try rejectParseErrors(in: tree, original: declaration)
            guard let protocolDeclaration = tree.statements.first?.item.as(
                    ProtocolDeclSyntax.self),
                  protocolDeclaration.memberBlock.members.count == 1,
                  let variable = protocolDeclaration.memberBlock.members.first?
                    .decl.as(VariableDeclSyntax.self) else {
                throw HostSignatureError.invalidDeclaration(
                    declaration: declaration,
                    reason: "expected one receiver-qualified property")
            }
            let modifiers = variable.modifiers.map(\.trimmedDescription)
            let isStatic = modifiers.contains("static")
                || modifiers.contains("class")
            let isVariable = match.kind == .variable
            let prefix = (isStatic ? "static " : "")
                + (isVariable ? "var " : "let ")
            let parsed = try parseProperty(
                prefix + suffix,
                prefix: prefix,
                isStatic: isStatic,
                isVariable: isVariable)
            return HostSignature(
                declaration: declaration,
                kind: parsed.kind,
                receiverType: parsed.receiverType,
                name: parsed.name,
                parameters: parsed.parameters,
                genericParameters: parsed.genericParameters,
                returnType: parsed.returnType,
                isAsync: parsed.isAsync,
                isThrowing: parsed.isThrowing,
                isFailable: parsed.isFailable,
                isSettable: parsed.isSettable,
                attributes: variable.attributes.map(\.trimmedDescription),
                modifiers: modifiers,
                compilerPreflightDeclaration: nativeMember,
                compilerPreflightAccessInsertionUTF8Offset:
                    introducerUTF8Offset(
                        match.kind, in: nativeMember,
                        original: declaration),
                compilerPreflightGetterEffects:
                    getterEffectSpecifiers(in: variable))

        case .initializer, .failableInitializer,
             .implicitlyUnwrappedInitializer:
            guard let parameterStart = firstTopLevelIndex(of: "(", in: suffix)
            else { return nil }
            var receiver = String(suffix[..<parameterStart])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var optionalMark: Character?
            if match.kind == .failableInitializer {
                optionalMark = "?"
            } else if match.kind == .implicitlyUnwrappedInitializer {
                optionalMark = "!"
            }
            if receiver.last == "?" || receiver.last == "!" {
                optionalMark = receiver.removeLast()
                receiver = receiver.trimmingCharacters(
                    in: .whitespacesAndNewlines)
            }
            guard !receiver.isEmpty else {
                throw HostSignatureError.invalidDeclaration(
                    declaration: declaration,
                    reason: "missing initialized type")
            }

            let nativeIntroducer: QualifiedMemberIntroducer
            switch optionalMark {
            case "?": nativeIntroducer = .failableInitializer
            case "!": nativeIntroducer = .implicitlyUnwrappedInitializer
            default: nativeIntroducer = .initializer
            }
            let nativeMember = normalizedCompilerDeclaration(
                leading + "init" + (optionalMark.map(String.init) ?? "")
                    + String(suffix[parameterStart...]))
            let tree = Parser.parse(source:
                "extension \(receiver) {\n\(nativeMember) { fatalError() }\n}")
            try rejectParseErrors(in: tree, original: declaration)
            guard let extensionDeclaration = tree.statements.first?.item.as(
                    ExtensionDeclSyntax.self),
                  extensionDeclaration.memberBlock.members.count == 1,
                  let initializer = extensionDeclaration.memberBlock.members
                    .first?.decl.as(InitializerDeclSyntax.self) else {
                throw HostSignatureError.invalidDeclaration(
                    declaration: declaration,
                    reason: "expected one receiver-qualified initializer")
            }
            let legacyPrefix = optionalMark == nil ? "init " : "init? "
            let parsed = try parseInitializer(
                legacyPrefix + receiver + suffix[parameterStart...],
                prefix: legacyPrefix,
                prefixIsFailable: optionalMark != nil)
            return HostSignature(
                declaration: declaration,
                kind: parsed.kind,
                receiverType: parsed.receiverType,
                name: parsed.name,
                parameters: parsed.parameters,
                genericParameters: parsed.genericParameters,
                returnType: parsed.returnType,
                isAsync: parsed.isAsync,
                isThrowing: parsed.isThrowing,
                isFailable: parsed.isFailable,
                isSettable: parsed.isSettable,
                attributes: initializer.attributes.map(\.trimmedDescription),
                modifiers: initializer.modifiers.map(\.trimmedDescription),
                compilerPreflightDeclaration: nativeMember,
                compilerPreflightAccessInsertionUTF8Offset:
                    introducerUTF8Offset(
                        nativeIntroducer, in: nativeMember,
                        original: declaration))
        }
    }

    static func firstQualifiedMemberIntroducer(
        in declaration: String
    ) -> QualifiedMemberIntroducerMatch? {
        let candidates: [QualifiedMemberIntroducer] = [
            .function, .failableInitializer,
            .implicitlyUnwrappedInitializer, .initializer,
            .variable, .constant,
        ]
        return candidates.compactMap { kind in
            topLevelKeywordRange(of: kind.rawValue, in: declaration).map {
                QualifiedMemberIntroducerMatch(kind: kind, range: $0)
            }
        }.min { lhs, rhs in
            lhs.range.lowerBound < rhs.range.lowerBound
        }
    }

    static func topLevelKeywordRange(
        of keyword: String, in text: String
    ) -> Range<String.Index>? {
        var search = text.startIndex
        while search < text.endIndex,
              let range = text.range(
                of: keyword, range: search..<text.endIndex) {
            let prefix = String(text[..<range.lowerBound])
            let atBoundary = range.lowerBound == text.startIndex
                || text[text.index(before: range.lowerBound)].isWhitespace
            if atBoundary, nestingDepth(of: prefix) == (0, 0, 0) {
                return range
            }
            search = range.upperBound
        }
        return nil
    }

    static func normalizedCompilerDeclaration(_ declaration: String) -> String {
        declaration.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func getterEffectSpecifiers(
        in variable: VariableDeclSyntax
    ) -> String {
        guard let accessorBlock = variable.bindings.first?.accessorBlock,
              let accessors = accessorBlock.accessors.as(
                AccessorDeclListSyntax.self),
              let getter = accessors.first(where: {
                $0.accessorSpecifier.text == "get"
              }) else { return "" }
        return getter.effectSpecifiers?.trimmedDescription ?? ""
    }

    static func introducerUTF8Offset(
        _ introducer: QualifiedMemberIntroducer,
        in declaration: String,
        original: String
    ) -> Int {
        let token = introducer.rawValue.trimmingCharacters(in: .whitespaces)
        var search = declaration.startIndex
        var found: Range<String.Index>?
        while search < declaration.endIndex,
              let range = declaration.range(
                of: token, range: search..<declaration.endIndex) {
            let prefix = String(declaration[..<range.lowerBound])
            let beforeIsBoundary = range.lowerBound == declaration.startIndex
                || declaration[declaration.index(before: range.lowerBound)]
                    .isWhitespace
            let afterIsBoundary = range.upperBound == declaration.endIndex
                || declaration[range.upperBound].isWhitespace
                || declaration[range.upperBound] == "?"
                || declaration[range.upperBound] == "!"
                || declaration[range.upperBound] == "("
            if beforeIsBoundary, afterIsBoundary,
               nestingDepth(of: prefix) == (0, 0, 0) {
                found = range
                break
            }
            search = range.upperBound
        }
        guard let range = found else {
            preconditionFailure(
                "validated host declaration lost its introducer: \(original)")
        }
        return declaration[..<range.lowerBound].utf8.count
    }

    static func parseNativeTopLevelFunctionIfPresent(
        _ declaration: String
    ) throws -> HostSignature? {
        if declaration.hasPrefix("func ") {
            let body = String(declaration.dropFirst("func ".count))
            guard let parameterStart = firstTopLevelIndex(of: "(", in: body)
            else {
                let tree = Parser.parse(source: declaration + " {}")
                try rejectParseErrors(in: tree, original: declaration)
                throw HostSignatureError.invalidDeclaration(
                    declaration: declaration, reason: "missing parameter clause")
            }
            let qualifiedAndGenerics = String(body[..<parameterStart])
            if lastTopLevelIndex(of: ".", in: qualifiedAndGenerics) != nil {
                return nil
            }
        } else {
            let nativePrefixes = [
                "@", "public ", "internal ", "private ", "fileprivate ",
                "package ", "nonisolated ", "borrowing ", "consuming ",
            ]
            guard nativePrefixes.contains(where: declaration.hasPrefix) else {
                return nil
            }
        }

        let source = declaration + " {}"
        let tree = Parser.parse(source: source)
        try rejectParseErrors(in: tree, original: declaration)
        guard tree.statements.count == 1,
              let function = tree.statements.first?.item.as(
                FunctionDeclSyntax.self
              ) else {
            throw HostSignatureError.invalidDeclaration(
                declaration: declaration,
                reason: "expected one body-free top-level function declaration")
        }
        let parsed = try parseSyntheticFunction(source, original: declaration)
        return HostSignature(
            declaration: declaration,
            kind: .function,
            receiverType: nil,
            name: function.name.text,
            parameters: parsed.parameters,
            genericParameters: parsed.generics,
            returnType: parsed.returnType,
            isAsync: parsed.isAsync,
            isThrowing: parsed.isThrowing,
            isFailable: false,
            isSettable: false,
            attributes: function.attributes.map(\.trimmedDescription),
            modifiers: function.modifiers.map(\.trimmedDescription),
            compilerPreflightDeclaration: declaration,
            compilerPreflightAccessInsertionUTF8Offset:
                function.funcKeyword.positionAfterSkippingLeadingTrivia
                    .utf8Offset)
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
