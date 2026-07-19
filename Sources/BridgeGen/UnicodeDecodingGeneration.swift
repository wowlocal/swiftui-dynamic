import SwiftSyntax

struct UnicodeDecodingInitializerSurface: Hashable {
    let typeName: String
    let codeUnitsLabel: String
    let encodingLabel: String
}

struct UnicodeEncodingSurface: Hashable {
    let typeName: String
    let sourceSpellings: [String]
    let codeUnitTypeName: String
}

struct UnicodeDecodingSurface {
    let initializers: [UnicodeDecodingInitializerSurface]
    let encodings: [UnicodeEncodingSurface]
}

/// Discovers string-protocol initializers whose generic contract is:
///
///     Collection<Element == Encoding.CodeUnit>, Encoding: _UnicodeEncoding
///
/// Runtime execution needs a semantic adapter because an interface declaration
/// cannot carry executable generic code into RuntimeValue. Eligibility, labels,
/// concrete encoding conformers, aliases, and CodeUnit relationships all stay
/// derived from the active standard-library interface.
func unicodeDecodingSurface(
    in file: SourceFileSyntax?
) -> UnicodeDecodingSurface {
    guard let file else {
        return UnicodeDecodingSurface(initializers: [], encodings: [])
    }

    func canonical(_ raw: String) -> String {
        normalize(raw)
            .replacingOccurrences(of: "@unchecked ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isPublic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "public" }
    }

    func inheritedTypes(
        _ clause: InheritanceClauseSyntax?
    ) -> Set<String> {
        Set(clause?.inheritedTypes.map {
            canonical($0.type.trimmedDescription)
        } ?? [])
    }

    var aliases: [String: String] = [:]
    var protocolParents: [String: Set<String>] = [:]
    var conformances: [String: Set<String>] = [:]
    var codeUnitTypes: [String: String] = [:]
    var publicNominals = Set<String>()
    var ownedInitializers: [
        (owner: String, declaration: InitializerDeclSyntax)
    ] = []

    func collectMembers(
        _ members: MemberBlockItemListSyntax,
        owner: String
    ) {
        for member in members {
            if let alias = member.decl.as(TypeAliasDeclSyntax.self) {
                let name = owner + "." + alias.name.text
                aliases[name] = canonical(
                    alias.initializer.value.trimmedDescription)
                if alias.name.text == "CodeUnit",
                   isPublic(alias.modifiers) {
                    codeUnitTypes[owner] = canonical(
                        alias.initializer.value.trimmedDescription)
                }
                continue
            }
            if let initializer = member.decl.as(
                InitializerDeclSyntax.self
            ) {
                ownedInitializers.append((owner, initializer))
                continue
            }
            if let nominal = member.decl.as(StructDeclSyntax.self) {
                let name = owner + "." + nominal.name.text
                if isPublic(nominal.modifiers) {
                    publicNominals.insert(name)
                }
                conformances[name, default: []].formUnion(
                    inheritedTypes(nominal.inheritanceClause))
                collectMembers(nominal.memberBlock.members, owner: name)
                continue
            }
            if let nominal = member.decl.as(EnumDeclSyntax.self) {
                let name = owner + "." + nominal.name.text
                if isPublic(nominal.modifiers) {
                    publicNominals.insert(name)
                }
                conformances[name, default: []].formUnion(
                    inheritedTypes(nominal.inheritanceClause))
                collectMembers(nominal.memberBlock.members, owner: name)
                continue
            }
            if let nominal = member.decl.as(ClassDeclSyntax.self) {
                let name = owner + "." + nominal.name.text
                if isPublic(nominal.modifiers) {
                    publicNominals.insert(name)
                }
                conformances[name, default: []].formUnion(
                    inheritedTypes(nominal.inheritanceClause))
                collectMembers(nominal.memberBlock.members, owner: name)
            }
        }
    }

    for item in file.statements {
        guard case .decl(let declaration) = item.item else { continue }
        if let alias = declaration.as(TypeAliasDeclSyntax.self) {
            aliases[alias.name.text] = canonical(
                alias.initializer.value.trimmedDescription)
        } else if let protocolDeclaration = declaration.as(
            ProtocolDeclSyntax.self
        ) {
            protocolParents[protocolDeclaration.name.text] = inheritedTypes(
                protocolDeclaration.inheritanceClause)
        } else if let nominal = declaration.as(StructDeclSyntax.self) {
            let name = nominal.name.text
            if isPublic(nominal.modifiers) {
                publicNominals.insert(name)
            }
            conformances[name, default: []].formUnion(
                inheritedTypes(nominal.inheritanceClause))
            collectMembers(nominal.memberBlock.members, owner: name)
        } else if let nominal = declaration.as(EnumDeclSyntax.self) {
            let name = nominal.name.text
            if isPublic(nominal.modifiers) {
                publicNominals.insert(name)
            }
            conformances[name, default: []].formUnion(
                inheritedTypes(nominal.inheritanceClause))
            collectMembers(nominal.memberBlock.members, owner: name)
        } else if let nominal = declaration.as(ClassDeclSyntax.self) {
            let name = nominal.name.text
            if isPublic(nominal.modifiers) {
                publicNominals.insert(name)
            }
            conformances[name, default: []].formUnion(
                inheritedTypes(nominal.inheritanceClause))
            collectMembers(nominal.memberBlock.members, owner: name)
        } else if let extensionDeclaration = declaration.as(
            ExtensionDeclSyntax.self
        ) {
            let owner = canonical(
                extensionDeclaration.extendedType.trimmedDescription)
            conformances[owner, default: []].formUnion(
                inheritedTypes(extensionDeclaration.inheritanceClause))
            collectMembers(
                extensionDeclaration.memberBlock.members,
                owner: owner)
        }
    }

    func resolvedAlias(_ raw: String) -> String {
        var current = canonical(raw)
        var visited = Set<String>()
        while visited.insert(current).inserted,
              let next = aliases[current] {
            current = canonical(next)
        }
        return current
    }

    func protocolRefines(
        _ candidate: String,
        _ target: String,
        visited: inout Set<String>
    ) -> Bool {
        let candidate = resolvedAlias(candidate)
        let target = resolvedAlias(target)
        if candidate == target { return true }
        guard visited.insert(candidate).inserted else { return false }
        return protocolParents[candidate]?.contains {
            protocolRefines($0, target, visited: &visited)
        } == true
    }

    func protocolRefines(_ candidate: String, _ target: String) -> Bool {
        var visited = Set<String>()
        return protocolRefines(candidate, target, visited: &visited)
    }

    func ownerConforms(_ owner: String, to protocolName: String) -> Bool {
        conformances[owner]?.contains {
            protocolRefines($0, protocolName)
        } == true
    }

    func initializerSurface(
        owner: String,
        declaration: InitializerDeclSyntax
    ) -> UnicodeDecodingInitializerSurface? {
        guard publicNominals.contains(owner),
              ownerConforms(owner, to: "StringProtocol"),
              isPublic(declaration.modifiers),
              declaration.optionalMark == nil,
              declaration.signature.effectSpecifiers == nil,
              let genericClause = declaration.genericParameterClause
        else { return nil }

        let genericNames = Set(genericClause.parameters.map {
            canonical($0.name.text)
        })
        let parameters = declaration.signature.parameterClause.parameters
        guard parameters.count == 2 else { return nil }
        let first = parameters[parameters.startIndex]
        let second = parameters[parameters.index(after: parameters.startIndex)]
        let collectionName = canonical(first.type.trimmedDescription)
        var encodingMetatype = canonical(second.type.trimmedDescription)
        guard encodingMetatype.hasSuffix(".Type") else { return nil }
        encodingMetatype.removeLast(".Type".count)
        guard genericNames.contains(collectionName),
              genericNames.contains(encodingMetatype)
        else { return nil }

        var genericConstraints: [String: Set<String>] = [:]
        for parameter in genericClause.parameters {
            if let inherited = parameter.inheritedType {
                genericConstraints[canonical(parameter.name.text), default: []]
                    .insert(canonical(inherited.trimmedDescription))
            }
        }
        var sameTypes = Set<Set<String>>()
        if let whereClause = declaration.genericWhereClause {
            for requirement in whereClause.requirements {
                if let conformance = requirement.requirement.as(
                    ConformanceRequirementSyntax.self
                ) {
                    genericConstraints[
                        canonical(conformance.leftType.trimmedDescription),
                        default: []
                    ].insert(canonical(
                        conformance.rightType.trimmedDescription))
                } else if let sameType = requirement.requirement.as(
                    SameTypeRequirementSyntax.self
                ) {
                    sameTypes.insert(Set([
                        canonical(sameType.leftType.trimmedDescription),
                        canonical(sameType.rightType.trimmedDescription),
                    ]))
                }
            }
        }
        guard genericConstraints[collectionName]?.contains(where: {
                  protocolRefines($0, "Collection")
              }) == true,
              genericConstraints[encodingMetatype]?.contains(where: {
                  protocolRefines($0, "_UnicodeEncoding")
              }) == true,
              sameTypes.contains(Set([
                  collectionName + ".Element",
                  encodingMetatype + ".CodeUnit",
              ]))
        else { return nil }

        let firstLabel = first.firstName.text
        let secondLabel = second.firstName.text
        guard firstLabel != "_", secondLabel != "_" else { return nil }
        return UnicodeDecodingInitializerSurface(
            typeName: owner,
            codeUnitsLabel: firstLabel,
            encodingLabel: secondLabel)
    }

    let initializers = Set(ownedInitializers.compactMap {
        initializerSurface(owner: $0.owner, declaration: $0.declaration)
    }).sorted {
        ($0.typeName, $0.codeUnitsLabel, $0.encodingLabel)
            < ($1.typeName, $1.codeUnitsLabel, $1.encodingLabel)
    }

    let encodingTypes = conformances.keys.filter { owner in
        publicNominals.contains(owner)
            && codeUnitTypes[owner] != nil
            && ownerConforms(owner, to: "_UnicodeEncoding")
    }
    let encodings = encodingTypes.compactMap {
        owner -> UnicodeEncodingSurface? in
        guard let codeUnitTypeName = codeUnitTypes[owner] else { return nil }
        var spellings: Set<String> = [owner]
        for alias in aliases.keys where resolvedAlias(alias) == owner {
            spellings.insert(alias)
        }
        return UnicodeEncodingSurface(
            typeName: owner,
            sourceSpellings: spellings.sorted(),
            codeUnitTypeName: codeUnitTypeName)
    }.sorted { $0.typeName < $1.typeName }

    return UnicodeDecodingSurface(
        initializers: initializers,
        encodings: encodings)
}
