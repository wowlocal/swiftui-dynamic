import SwiftSyntax

/// Public Foundation typealiases whose resolved target is a concrete runtime
/// carrier. Source extensions may be written against either spelling (for
/// example a collection's `Element` alias), so host member lookup must offer
/// both names for the same native value.
func foundationRuntimeTypeAliases(
    in file: SourceFileSyntax?,
    canonicalTypes: Set<String>
) -> [String: [String]] {
    guard let file else { return [:] }

    var rawTargets: [String: String] = [:]

    func collect(_ declaration: DeclSyntax, path: [String]) {
        if let alias = declaration.as(TypeAliasDeclSyntax.self) {
            guard isPublicSDKDecl(alias.modifiers),
                  isUniversallyUsable(alias.attributes),
                  !needsAvailabilityGuard(alias.attributes) else { return }
            let aliasName = (path + [alias.name.text]).joined(separator: ".")
            rawTargets[aliasName] = normalize(
                alias.initializer.value.trimmedDescription)
            return
        }

        func collectMembers(
            _ members: MemberBlockItemListSyntax,
            under nestedPath: [String]
        ) {
            for member in members {
                collect(member.decl, path: nestedPath)
            }
        }

        if let nominal = declaration.as(StructDeclSyntax.self) {
            collectMembers(
                nominal.memberBlock.members,
                under: path + [nominal.name.text])
        } else if let nominal = declaration.as(EnumDeclSyntax.self) {
            collectMembers(
                nominal.memberBlock.members,
                under: path + [nominal.name.text])
        } else if let nominal = declaration.as(ClassDeclSyntax.self) {
            collectMembers(
                nominal.memberBlock.members,
                under: path + [nominal.name.text])
        } else if let nominal = declaration.as(ProtocolDeclSyntax.self) {
            collectMembers(
                nominal.memberBlock.members,
                under: path + [nominal.name.text])
        } else if let ext = declaration.as(ExtensionDeclSyntax.self),
                  isUniversallyUsable(ext.attributes) {
            let extendedPath = normalize(
                ext.extendedType.trimmedDescription)
                .split(separator: ".").map(String.init)
            collectMembers(ext.memberBlock.members, under: extendedPath)
        }
    }

    for statement in file.statements {
        guard case .decl(let declaration) = statement.item else { continue }
        collect(declaration, path: [])
    }

    func candidates(for target: String, alias: String) -> [String] {
        guard !target.contains(".") else { return [target] }
        var result = [target]
        var scope = alias.split(separator: ".").dropLast().map(String.init)
        while !scope.isEmpty {
            result.append((scope + [target]).joined(separator: "."))
            scope.removeLast()
        }
        return result
    }

    func resolve(
        _ alias: String,
        seen: inout Set<String>
    ) -> String? {
        guard seen.insert(alias).inserted,
              let target = rawTargets[alias] else { return nil }
        for candidate in candidates(for: target, alias: alias) {
            if canonicalTypes.contains(candidate) { return candidate }
            if rawTargets[candidate] != nil,
               let resolved = resolve(candidate, seen: &seen) {
                return resolved
            }
        }
        return nil
    }

    var aliasesByCanonicalName: [String: [String]] = [:]
    for alias in rawTargets.keys.sorted() {
        var seen: Set<String> = []
        guard let canonical = resolve(alias, seen: &seen),
              alias != canonical else { continue }
        aliasesByCanonicalName[canonical, default: []].append(alias)
    }
    return aliasesByCanonicalName.mapValues { Array(Set($0)).sorted() }
}
