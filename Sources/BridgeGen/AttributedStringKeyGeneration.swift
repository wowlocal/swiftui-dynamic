import SwiftSyntax

struct AttributedStringKeySurface {
    let keyTypeNames: [String]
    let receiverTypeNames: [String]
}

/// Discovers the concrete attributed-string key metatypes and the concrete
/// SDK values whose public interface exposes `subscript<K>(_: K.Type) ->
/// K.Value?`. Runtime dispatch can therefore open the generated key metatype
/// and call the native generic subscript without maintaining a key- or
/// receiver-name allowlist by hand.
func attributedStringKeySurface(
    in file: SourceFileSyntax?
) -> AttributedStringKeySurface {
    guard let file else {
        return AttributedStringKeySurface(
            keyTypeNames: [], receiverTypeNames: [])
    }

    func canonical(_ raw: String) -> String {
        normalize(raw)
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func nominalNames(in raw: String) -> Set<String> {
        Set(canonical(raw).split(separator: "&").compactMap { component in
            var name = String(component)
            if let generic = name.firstIndex(of: "<") {
                name = String(name[..<generic])
            }
            return name.split(separator: ".").last.map(String.init)
        })
    }

    func inheritedNames(
        _ clause: InheritanceClauseSyntax?
    ) -> Set<String> {
        Set(clause?.inheritedTypes.flatMap {
            nominalNames(in: $0.type.trimmedDescription)
        } ?? [])
    }

    var protocolParents: [String: Set<String>] = [:]
    var aliases: [String: Set<String>] = [:]
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item else { continue }
        if let protocolDeclaration = declaration.as(
            ProtocolDeclSyntax.self
        ) {
            protocolParents[protocolDeclaration.name.text, default: []]
                .formUnion(inheritedNames(
                    protocolDeclaration.inheritanceClause))
        } else if let alias = declaration.as(TypeAliasDeclSyntax.self) {
            aliases[alias.name.text] = nominalNames(
                in: alias.initializer.value.trimmedDescription)
        }
    }

    // Protocol refinements and protocol-composition aliases are both
    // interface facts. `CodableAttributedStringKey`, for example, is a
    // typealias composition rather than a ProtocolDecl.
    var keyProtocolNames: Set<String> = ["AttributedStringKey"]
    var changed = true
    while changed {
        changed = false
        for (name, parents) in protocolParents
        where !parents.isDisjoint(with: keyProtocolNames) {
            changed = keyProtocolNames.insert(name).inserted || changed
        }
        for (name, components) in aliases
        where !components.isDisjoint(with: keyProtocolNames) {
            changed = keyProtocolNames.insert(name).inserted || changed
        }
    }

    func conformsToAttributedStringKey(
        _ clause: InheritanceClauseSyntax?
    ) -> Bool {
        !inheritedNames(clause).isDisjoint(with: keyProtocolNames)
    }

    func isKeyValueMetatypeSubscript(
        _ declaration: SubscriptDeclSyntax,
        guarded: Bool
    ) -> Bool {
        guard !guarded,
              isPublicSDKDecl(declaration.modifiers),
              isUniversallyUsable(declaration.attributes),
              !needsAvailabilityGuard(declaration.attributes)
        else { return false }
        let parameters = Array(declaration.parameterClause.parameters)
        guard parameters.count == 1,
              parameters[0].firstName.text == "_",
              let genericName = declaration.genericParameterClause?
                .parameters.first?.name.text,
              canonical(parameters[0].type.trimmedDescription)
                == "\(genericName).Type",
              canonical(declaration.returnClause.type.trimmedDescription)
                == "\(genericName).Value?"
        else { return false }

        let inlineConstraint = declaration.genericParameterClause?
            .parameters.first?.inheritedType.map {
                nominalNames(in: $0.trimmedDescription)
            } ?? []
        if !inlineConstraint.isDisjoint(with: keyProtocolNames) {
            return true
        }
        let whereClause = canonical(
            declaration.genericWhereClause?.trimmedDescription ?? "")
        return keyProtocolNames.contains { protocolName in
            whereClause.contains("\(genericName):\(protocolName)")
        }
    }

    var keyTypes = Set<String>()
    var receiverTypes = Set<String>()

    func collect(
        _ declaration: DeclSyntax,
        path: [String],
        guarded inheritedGuarded: Bool
    ) {
        if let nominal = declaration.as(StructDeclSyntax.self) {
            guard isPublicSDKDecl(nominal.modifiers),
                  isUniversallyUsable(nominal.attributes),
                  !nominal.name.text.hasPrefix("_") else { return }
            let nominalPath = path + [nominal.name.text]
            let guarded = inheritedGuarded
                || needsAvailabilityGuard(nominal.attributes)
            if !guarded,
               conformsToAttributedStringKey(nominal.inheritanceClause) {
                keyTypes.insert(nominalPath.joined(separator: "."))
            }
            for member in nominal.memberBlock.members {
                if let subscriptDeclaration = member.decl.as(
                    SubscriptDeclSyntax.self
                ), isKeyValueMetatypeSubscript(
                    subscriptDeclaration, guarded: guarded) {
                    receiverTypes.insert(nominalPath.joined(separator: "."))
                }
                collect(
                    member.decl, path: nominalPath, guarded: guarded)
            }
            return
        }

        if let nominal = declaration.as(EnumDeclSyntax.self) {
            guard isPublicSDKDecl(nominal.modifiers),
                  isUniversallyUsable(nominal.attributes),
                  !nominal.name.text.hasPrefix("_") else { return }
            let nominalPath = path + [nominal.name.text]
            let guarded = inheritedGuarded
                || needsAvailabilityGuard(nominal.attributes)
            if !guarded,
               conformsToAttributedStringKey(nominal.inheritanceClause) {
                keyTypes.insert(nominalPath.joined(separator: "."))
            }
            for member in nominal.memberBlock.members {
                collect(
                    member.decl, path: nominalPath, guarded: guarded)
            }
            return
        }

        if let nominal = declaration.as(ClassDeclSyntax.self) {
            guard isPublicSDKDecl(nominal.modifiers),
                  isUniversallyUsable(nominal.attributes),
                  !nominal.name.text.hasPrefix("_") else { return }
            let nominalPath = path + [nominal.name.text]
            let guarded = inheritedGuarded
                || needsAvailabilityGuard(nominal.attributes)
            if !guarded,
               conformsToAttributedStringKey(nominal.inheritanceClause) {
                keyTypes.insert(nominalPath.joined(separator: "."))
            }
            for member in nominal.memberBlock.members {
                collect(
                    member.decl, path: nominalPath, guarded: guarded)
            }
            return
        }

        guard let extensionDeclaration = declaration.as(
            ExtensionDeclSyntax.self
        ), isUniversallyUsable(extensionDeclaration.attributes) else {
            return
        }
        let extendedPath = normalize(
            extensionDeclaration.extendedType.trimmedDescription)
            .split(separator: ".").map(String.init)
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(extensionDeclaration.attributes)
        if !guarded,
           conformsToAttributedStringKey(
               extensionDeclaration.inheritanceClause) {
            keyTypes.insert(extendedPath.joined(separator: "."))
        }
        for member in extensionDeclaration.memberBlock.members {
            if let subscriptDeclaration = member.decl.as(
                SubscriptDeclSyntax.self
            ), isKeyValueMetatypeSubscript(
                subscriptDeclaration, guarded: guarded) {
                receiverTypes.insert(extendedPath.joined(separator: "."))
            }
            collect(member.decl, path: extendedPath, guarded: guarded)
        }
    }

    for statement in file.statements {
        guard case .decl(let declaration) = statement.item else { continue }
        collect(declaration, path: [], guarded: false)
    }
    return AttributedStringKeySurface(
        keyTypeNames: keyTypes.sorted(),
        receiverTypeNames: receiverTypes.sorted())
}
