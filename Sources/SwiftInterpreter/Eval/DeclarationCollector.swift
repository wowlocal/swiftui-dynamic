import SwiftSyntax

/// Pass 1: hoist struct and function declarations from a parsed file into the
/// global environment. Top-level `let`/`var` and expressions are executed in
/// source order by `Interpreter.run` afterwards.
extension Interpreter {
    func collectDeclarations(from file: SourceFileSyntax) throws {
        for item in file.statements {
            guard case .decl(let decl) = item.item else { continue }
            if let structDecl = decl.as(StructDeclSyntax.self) {
                try collectStruct(structDecl)
            } else if let funcDecl = decl.as(FunctionDeclSyntax.self) {
                try defineFunction(funcDecl, in: globals)
            }
        }
    }

    private func collectStruct(_ node: StructDeclSyntax) throws {
        let conformsToView = node.inheritanceClause?.inheritedTypes.contains {
            $0.type.trimmedDescription == "View"
        } ?? false
        let symbol = StructSymbol(name: node.name.text, conformsToView: conformsToView)

        for member in node.memberBlock.members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self) {
                try collectProperties(varDecl, into: symbol)
            } else if let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
                symbol.methods[funcDecl.name.text] = funcDecl
            }
            // Other members (custom inits, nested types, …) are ignored in v1.
        }

        structSymbols.append(symbol)
        globals.define(symbol.name, .type(symbol))
    }

    private func collectProperties(_ varDecl: VariableDeclSyntax, into symbol: StructSymbol) throws {
        let isState = varDecl.attributes.contains {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "State"
        }
        for binding in varDecl.bindings {
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                throw error(binding, "unsupported property pattern")
            }
            let name = ident.identifier.text
            if let accessorBlock = binding.accessorBlock {
                switch accessorBlock.accessors {
                case .getter(let items):
                    symbol.computedProperties[name] = items
                case .accessors(let list):
                    guard let getter = list.first(where: { $0.accessorSpecifier.tokenKind == .keyword(.get) })?.body?.statements else {
                        throw error(accessorBlock, "only get-only computed properties are supported")
                    }
                    symbol.computedProperties[name] = getter
                }
            } else {
                symbol.storedProperties.append(
                    .init(name: name, isState: isState, initializer: binding.initializer?.value)
                )
            }
        }
    }

    func defineFunction(_ node: FunctionDeclSyntax, in env: Environment) throws {
        guard let body = node.body else {
            throw error(node, "function '\(node.name.text)' has no body")
        }
        env.define(node.name.text, .closure(makeFunctionClosure(node, body: body, captured: env)))
    }

    func makeFunctionClosure(_ node: FunctionDeclSyntax, body: CodeBlockSyntax, captured: Environment) -> ClosureValue {
        let parameters = node.signature.parameterClause.parameters.map { param in
            ClosureValue.Parameter(
                name: (param.secondName ?? param.firstName).text,
                defaultValue: param.defaultValue?.value
            )
        }
        return ClosureValue(parameters: parameters, body: body.statements, captured: captured)
    }
}
