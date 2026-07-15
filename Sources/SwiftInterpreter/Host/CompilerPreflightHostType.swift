import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// A compiler-only nominal declaration for a type implemented by a
/// `HostRegistry` rather than by the interpreted source or an imported SDK.
///
/// Runtime construction and member dispatch remain ordinary typed host
/// contracts. This value only supplies the missing nominal boundary so native
/// compiler preflight can serialize type attributes and check clients against
/// the same enclosing type as the interpreter.
public struct CompilerPreflightHostType: Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable, Equatable {
        case structure = "struct"
        case `class` = "class"
        case enumeration = "enum"
    }

    public let declaration: String
    public let name: String
    public let kind: Kind
    public let attributes: [String]
    public let modifiers: [String]

    let compilerPreflightDeclaration: String
    private let closingBraceUTF8Offset: Int

    public var description: String { declaration }

    public init(parsing rawDeclaration: String) throws {
        let declaration = rawDeclaration.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !declaration.isEmpty else {
            throw CompilerPreflightHostTypeError.invalidDeclaration(
                declaration: rawDeclaration, reason: "declaration is empty")
        }

        let tree = Parser.parse(source: declaration)
        if let diagnostic = ParseDiagnosticsGenerator.diagnostics(for: tree)
            .first(where: { $0.diagMessage.severity == .error }) {
            throw CompilerPreflightHostTypeError.invalidDeclaration(
                declaration: declaration, reason: diagnostic.message)
        }
        guard tree.statements.count == 1,
              let item = tree.statements.first?.item else {
            throw CompilerPreflightHostTypeError.invalidDeclaration(
                declaration: declaration,
                reason: "expected exactly one nominal type declaration")
        }

        let parsed: ParsedNominal
        if let syntax = item.as(StructDeclSyntax.self) {
            parsed = ParsedNominal(
                kind: .structure,
                name: syntax.name.text,
                attributes: syntax.attributes.map(\.trimmedDescription),
                modifiers: syntax.modifiers.map(\.trimmedDescription),
                genericParameterClause: syntax.genericParameterClause,
                genericWhereClause: syntax.genericWhereClause,
                inheritanceClause: syntax.inheritanceClause,
                members: syntax.memberBlock.members,
                accessInsertionUTF8Offset: Self.accessInsertionUTF8Offset(
                    modifiers: syntax.modifiers,
                    keyword: syntax.structKeyword),
                closingBraceUTF8Offset: syntax.memberBlock.rightBrace
                    .positionAfterSkippingLeadingTrivia.utf8Offset)
        } else if let syntax = item.as(ClassDeclSyntax.self) {
            parsed = ParsedNominal(
                kind: .class,
                name: syntax.name.text,
                attributes: syntax.attributes.map(\.trimmedDescription),
                modifiers: syntax.modifiers.map(\.trimmedDescription),
                genericParameterClause: syntax.genericParameterClause,
                genericWhereClause: syntax.genericWhereClause,
                inheritanceClause: syntax.inheritanceClause,
                members: syntax.memberBlock.members,
                accessInsertionUTF8Offset: Self.accessInsertionUTF8Offset(
                    modifiers: syntax.modifiers,
                    keyword: syntax.classKeyword),
                closingBraceUTF8Offset: syntax.memberBlock.rightBrace
                    .positionAfterSkippingLeadingTrivia.utf8Offset)
        } else if let syntax = item.as(EnumDeclSyntax.self) {
            parsed = ParsedNominal(
                kind: .enumeration,
                name: syntax.name.text,
                attributes: syntax.attributes.map(\.trimmedDescription),
                modifiers: syntax.modifiers.map(\.trimmedDescription),
                genericParameterClause: syntax.genericParameterClause,
                genericWhereClause: syntax.genericWhereClause,
                inheritanceClause: syntax.inheritanceClause,
                members: syntax.memberBlock.members,
                accessInsertionUTF8Offset: Self.accessInsertionUTF8Offset(
                    modifiers: syntax.modifiers,
                    keyword: syntax.enumKeyword),
                closingBraceUTF8Offset: syntax.memberBlock.rightBrace
                    .positionAfterSkippingLeadingTrivia.utf8Offset)
        } else {
            throw CompilerPreflightHostTypeError.unsupportedDeclaration(
                declaration)
        }

        guard parsed.genericParameterClause == nil,
              parsed.genericWhereClause == nil else {
            throw CompilerPreflightHostTypeError.invalidDeclaration(
                declaration: declaration,
                reason: "generic synthetic nominal types are not supported")
        }
        guard parsed.inheritanceClause == nil else {
            throw CompilerPreflightHostTypeError.invalidDeclaration(
                declaration: declaration,
                reason: "synthetic nominal inheritance is not supported")
        }
        guard parsed.members.isEmpty else {
            throw CompilerPreflightHostTypeError.invalidDeclaration(
                declaration: declaration,
                reason: "members must be supplied as typed HostSignature contracts")
        }

        let accessModifiers = Set([
            "private", "fileprivate", "internal", "package", "public", "open",
        ])
        let declaredAccess = parsed.modifiers.lazy.map {
            $0.split(separator: "(", maxSplits: 1).first.map(String.init) ?? $0
        }.first(where: accessModifiers.contains)
        if let declaredAccess,
           declaredAccess != "public" && declaredAccess != "open" {
            throw CompilerPreflightHostTypeError.invalidDeclaration(
                declaration: declaration,
                reason: "synthetic nominal type has non-public access '\(declaredAccess)'")
        }
        if declaredAccess == "open", parsed.kind != .class {
            throw CompilerPreflightHostTypeError.invalidDeclaration(
                declaration: declaration,
                reason: "only a synthetic class may use open access")
        }

        var exportedBytes = Array(declaration.utf8)
        var closingBraceOffset = parsed.closingBraceUTF8Offset
        if declaredAccess == nil {
            let exportedAccess = Array("public ".utf8)
            guard parsed.accessInsertionUTF8Offset <= exportedBytes.count else {
                throw CompilerPreflightHostTypeError.invalidDeclaration(
                    declaration: declaration,
                    reason: "invalid export insertion point")
            }
            exportedBytes.insert(
                contentsOf: exportedAccess,
                at: parsed.accessInsertionUTF8Offset)
            if parsed.accessInsertionUTF8Offset <= closingBraceOffset {
                closingBraceOffset += exportedAccess.count
            }
        }
        guard closingBraceOffset < exportedBytes.count,
              exportedBytes[closingBraceOffset] == Character("}").asciiValue
        else {
            throw CompilerPreflightHostTypeError.invalidDeclaration(
                declaration: declaration,
                reason: "invalid nominal member block")
        }

        self.declaration = declaration
        self.name = parsed.name
        self.kind = parsed.kind
        self.attributes = parsed.attributes
        self.modifiers = parsed.modifiers
        self.compilerPreflightDeclaration = String(
            decoding: exportedBytes, as: UTF8.self)
        self.closingBraceUTF8Offset = closingBraceOffset
    }

    func compilerPreflightStub(members: [String]) -> String {
        guard !members.isEmpty else { return compilerPreflightDeclaration }
        let body = "\n" + members.map(Self.indented)
            .joined(separator: "\n\n") + "\n"
        var bytes = Array(compilerPreflightDeclaration.utf8)
        bytes.insert(
            contentsOf: Array(body.utf8), at: closingBraceUTF8Offset)
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func == (
        lhs: CompilerPreflightHostType,
        rhs: CompilerPreflightHostType
    ) -> Bool {
        lhs.name == rhs.name
            && lhs.kind == rhs.kind
            && lhs.compilerPreflightDeclaration
                == rhs.compilerPreflightDeclaration
    }
}

extension CompilerPreflightHostType: Equatable {}

public enum CompilerPreflightHostTypeError:
    Error, CustomStringConvertible, Equatable
{
    case unsupportedDeclaration(String)
    case invalidDeclaration(declaration: String, reason: String)

    public var description: String {
        switch self {
        case .unsupportedDeclaration(let declaration):
            return "unsupported synthetic host type declaration '\(declaration)'"
        case .invalidDeclaration(let declaration, let reason):
            return "invalid synthetic host type declaration '\(declaration)': \(reason)"
        }
    }
}

private extension CompilerPreflightHostType {
    struct ParsedNominal {
        let kind: Kind
        let name: String
        let attributes: [String]
        let modifiers: [String]
        let genericParameterClause: GenericParameterClauseSyntax?
        let genericWhereClause: GenericWhereClauseSyntax?
        let inheritanceClause: InheritanceClauseSyntax?
        let members: MemberBlockItemListSyntax
        let accessInsertionUTF8Offset: Int
        let closingBraceUTF8Offset: Int
    }

    static func accessInsertionUTF8Offset(
        modifiers: DeclModifierListSyntax,
        keyword: TokenSyntax
    ) -> Int {
        modifiers.first?.positionAfterSkippingLeadingTrivia.utf8Offset
            ?? keyword.positionAfterSkippingLeadingTrivia.utf8Offset
    }

    static func indented(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0 }
            .joined(separator: "\n")
    }
}
