import Foundation

// MARK: - Type matching

extension HostSignature {
    static func matchType(
        _ value: RuntimeValue,
        against rawType: String,
        genericNames: Set<String>,
        bindings: inout [String: String],
        representatives: inout [String: RuntimeValue],
        context: EvalContext,
        mayBind: Bool
    ) -> Int? {
        var type = normalizedType(rawType)

        if type.hasSuffix("?") || type.hasSuffix("!") {
            type.removeLast()
            if value.isNil { return 18 }
            return matchType(
                value, against: type, genericNames: genericNames,
                bindings: &bindings, representatives: &representatives,
                context: context, mayBind: mayBind).map { $0 - 1 }
        }
        if value.isNil { return type == "Any" ? 1 : nil }

        if genericNames.contains(type) {
            if let bound = bindings[type] {
                return matchType(
                    value, against: bound, genericNames: [],
                    bindings: &bindings, representatives: &representatives,
                    context: context, mayBind: false)
            }
            guard mayBind else { return nil }
            let observed = context.hostTypeName(of: value)
            bindings[type] = observed
            representatives[type] = value
            return 16
        }

        if type.hasSuffix(".Type") {
            let instanceType = String(type.dropLast(".Type".count))
            guard let observed = metatypeName(of: value) else { return nil }
            if genericNames.contains(instanceType) {
                if let bound = bindings[instanceType] {
                    return equivalentTypeName(bound, observed) ? 28 : nil
                }
                guard mayBind else { return nil }
                bindings[instanceType] = observed
                return 24
            }
            return equivalentTypeName(instanceType, observed) ? 30 : nil
        }

        if type == "Any" { return 1 }
        if type == "AnyObject" {
            switch value {
            case .host, .instance: return 8
            default: return nil
            }
        }
        if type == "Void" || type == "()" {
            if case .void = value { return 30 }
            return nil
        }
        if isFunctionType(type) {
            switch value {
            case .closure, .hostFunction: return 25
            default: return nil
            }
        }

        if type.hasPrefix("[") && type.hasSuffix("]"),
           let inner = outerContents(type, opening: "[", closing: "]") {
            let parts = splitTopLevel(inner, separator: ":")
            if parts.count == 2, let dictionary = value.dictValue {
                var score = 22
                for key in dictionary.keys {
                    guard let item = matchType(
                        key, against: parts[0], genericNames: genericNames,
                        bindings: &bindings, representatives: &representatives,
                        context: context, mayBind: mayBind) else { return nil }
                    score += item
                }
                for itemValue in dictionary.values {
                    guard let item = matchType(
                        itemValue, against: parts[1], genericNames: genericNames,
                        bindings: &bindings, representatives: &representatives,
                        context: context, mayBind: mayBind) else { return nil }
                    score += item
                }
                return score
            }
            if parts.count == 1, let array = value.arrayValue {
                var score = 22
                for element in array {
                    guard let item = matchType(
                        element, against: parts[0], genericNames: genericNames,
                        bindings: &bindings, representatives: &representatives,
                        context: context, mayBind: mayBind) else { return nil }
                    score += item
                }
                return score
            }
            return nil
        }

        if let application = genericApplication(type) {
            switch application.name {
            case "Optional" where application.arguments.count == 1:
                if value.isNil { return 18 }
                return matchType(
                    value, against: application.arguments[0],
                    genericNames: genericNames,
                    bindings: &bindings, representatives: &representatives,
                    context: context, mayBind: mayBind)
            case let container
                where ["Array", "ContiguousArray"].contains(container)
                    && application.arguments.count == 1:
                guard let array = value.arrayValue else { return nil }
                var score = 22
                for element in array {
                    guard let item = matchType(
                        element, against: application.arguments[0],
                        genericNames: genericNames,
                        bindings: &bindings, representatives: &representatives,
                        context: context, mayBind: mayBind) else { return nil }
                    score += item
                }
                return score
            case "Set" where application.arguments.count == 1:
                guard let set = value.setValue else { return nil }
                var score = 22
                if set.elements.isEmpty, let observed = set.elementTypeName {
                    let expected = normalizedType(application.arguments[0])
                    if genericNames.contains(expected) {
                        if let bound = bindings[expected] {
                            guard equivalentTypeName(bound, observed) else {
                                return nil
                            }
                        } else {
                            guard mayBind else { return nil }
                            bindings[expected] = observed
                        }
                        score += 16
                    } else {
                        guard equivalentTypeName(observed, expected) else {
                            return nil
                        }
                        score += 28
                    }
                }
                for element in set.elements {
                    guard let item = matchType(
                        element, against: application.arguments[0],
                        genericNames: genericNames,
                        bindings: &bindings, representatives: &representatives,
                        context: context, mayBind: mayBind) else { return nil }
                    score += item
                }
                return score
            case "Dictionary" where application.arguments.count == 2:
                guard let dictionary = value.dictValue else { return nil }
                var score = 22
                for key in dictionary.keys {
                    guard let item = matchType(
                        key, against: application.arguments[0],
                        genericNames: genericNames,
                        bindings: &bindings, representatives: &representatives,
                        context: context, mayBind: mayBind) else { return nil }
                    score += item
                }
                for itemValue in dictionary.values {
                    guard let item = matchType(
                        itemValue, against: application.arguments[1],
                        genericNames: genericNames,
                        bindings: &bindings, representatives: &representatives,
                        context: context, mayBind: mayBind) else { return nil }
                    score += item
                }
                return score
            case let rangeName
                where ["Range", "ClosedRange", "PartialRangeFrom",
                       "PartialRangeUpTo", "PartialRangeThrough"].contains(rangeName)
                    && application.arguments.count == 1:
                guard let range = value.rangeValue else { return nil }
                var score = 22
                for bound in [range.lowerBound, range.upperBound].compactMap({ $0 }) {
                    guard let item = matchType(
                        bound, against: application.arguments[0],
                        genericNames: genericNames,
                        bindings: &bindings, representatives: &representatives,
                        context: context, mayBind: mayBind) else { return nil }
                    score += item
                }
                return score
            default:
                break
            }
        }

        if type.hasPrefix("(") && type.hasSuffix(")"),
           let tuple = value.tupleValue,
           let inner = outerContents(type, opening: "(", closing: ")") {
            let components = splitTopLevel(inner, separator: ",")
            guard components.count == tuple.values.count else { return nil }
            var score = 20
            for (component, element) in zip(components, tuple.values) {
                let componentType = tupleComponentType(component)
                guard let item = matchType(
                    element, against: componentType,
                    genericNames: genericNames,
                    bindings: &bindings, representatives: &representatives,
                    context: context, mayBind: mayBind) else { return nil }
                score += item
            }
            return score
        }

        if type.hasPrefix("some ") || type.hasPrefix("any ") {
            let protocolName = String(type.dropFirst(4))
            return context.hostValue(value, conformsTo: protocolName) ? 10 : nil
        }

        guard context.hostValue(value, matchesType: type) else {
            // Protocol existential spellings without an explicit `any`
            // still occur throughout SDK interfaces and older source.
            return context.hostValue(value, conformsTo: type) ? 10 : nil
        }
        let observed = context.hostTypeName(of: value)
        if equivalentTypeName(observed, type) { return 30 }
        if observed == "Int",
           ["Double", "Float", "CGFloat", "TimeInterval", "NSNumber"]
            .contains(unqualified(type)) {
            return 20
        }
        return 14
    }

    static func normalizedType(_ raw: String) -> String {
        var type = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "@escaping ", "@autoclosure ", "@Sendable ",
            "inout ", "borrowing ", "consuming ", "isolated ",
        ]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where type.hasPrefix(prefix) {
                type = String(type.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return type
    }

    static func substitutingGenerics(
        in type: String, bindings: [String: String]
    ) -> String {
        var result = ""
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            result += bindings[token] ?? token
            token = ""
        }
        for character in type {
            if character.isLetter || character.isNumber || character == "_" {
                token.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    static func metatypeName(of value: RuntimeValue) -> String? {
        switch value {
        case .type(let symbol): return symbol.name
        case .enumType(let symbol): return symbol.name
        case .host(let any):
            if let marker = any as? HostTypeMarker { return marker.name }
            if let application = any as? GenericApplication { return application.text }
            return nil
        default: return nil
        }
    }

    static func equivalentTypeName(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.replacingOccurrences(of: " ", with: "")
        let right = rhs.replacingOccurrences(of: " ", with: "")
        return left == right
            || unqualified(left) == unqualified(right)
            || left.hasSuffix("." + right)
            || right.hasSuffix("." + left)
    }

    static func unqualified(_ type: String) -> String {
        guard !type.contains("<"), let dot = type.lastIndex(of: ".") else {
            return type
        }
        return String(type[type.index(after: dot)...])
    }

    static func genericApplication(
        _ type: String
    ) -> (name: String, arguments: [String])? {
        guard let open = firstTopLevelIndex(of: "<", in: type),
              type.hasSuffix(">") else { return nil }
        let name = String(type[..<open]).trimmingCharacters(in: .whitespaces)
        let inner = String(type[type.index(after: open)..<type.index(before: type.endIndex)])
        return (name, splitTopLevel(inner, separator: ","))
    }

    static func tupleComponentType(_ component: String) -> String {
        let parts = splitTopLevel(component, separator: ":")
        return (parts.count == 2 ? parts[1] : component)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Default type services used by custom `EvalContext` implementations. The
/// concrete `Interpreter` augments named-type checks with interpreted symbols
/// and `HostRegistry.hostTypeName`, but test embedders do not need to implement
/// those hooks merely to use typed primitive gateways.
enum HostRuntimeTypeSystem {
    static func typeName(of value: RuntimeValue) -> String {
        switch value {
        case .void: return "Void"
        case .nilValue: return "nil"
        case .int: return "Int"
        case .double: return "Double"
        case .bool: return "Bool"
        case .string: return "String"
        case .array(let values):
            let names = Set(values.map(typeName))
            return "[\(names.count == 1 ? names.first! : "Any")]"
        case .set(let set):
            if let elementType = set.elementTypeName {
                return "Set<\(elementType)>"
            }
            let names = Set(set.elements.map(typeName))
            return "Set<\(names.count == 1 ? names.first! : "Any")>"
        case .dictionary(let dictionary):
            let keys = Set(dictionary.keys.map(typeName))
            let values = Set(dictionary.values.map(typeName))
            return "[\(keys.count == 1 ? keys.first! : "Any"): \(values.count == 1 ? values.first! : "Any")]"
        case .tuple(let tuple):
            return "(" + tuple.values.map(typeName).joined(separator: ", ") + ")"
        case .range(let range):
            let bound = range.lowerBound ?? range.upperBound
            let nominal: String
            switch (range.lowerBound, range.upperBound, range.includesUpperBound) {
            case (_?, _?, false): nominal = "Range"
            case (_?, _?, true): nominal = "ClosedRange"
            case (_?, nil, _): nominal = "PartialRangeFrom"
            case (nil, _?, false): nominal = "PartialRangeUpTo"
            case (nil, _?, true): nominal = "PartialRangeThrough"
            case (nil, nil, _): nominal = "Range"
            }
            return "\(nominal)<\(bound.map(typeName) ?? "Any")>"
        case .host(let any):
            if let marker = any as? HostTypeMarker { return marker.name + ".Type" }
            return String(describing: Swift.type(of: any))
        case .instance(let instance): return instance.symbol.name
        case .closure, .hostFunction: return "Function"
        case .type(let symbol): return symbol.name + ".Type"
        case .enumType(let symbol): return symbol.name + ".Type"
        case .enumCase(let value): return value.symbol.name
        case .implicitMember: return "ImplicitMember"
        }
    }

    static func matches(_ value: RuntimeValue, type rawType: String) -> Bool {
        var type = rawType.trimmingCharacters(in: .whitespaces)
        if type.hasSuffix("?") || type.hasSuffix("!") {
            type.removeLast()
            if value.isNil { return true }
        }
        if type == "Any" { return true }
        if type == "Void" || type == "()" {
            if case .void = value { return true }
            return false
        }
        if type.contains("->") {
            if case .closure = value { return true }
            if case .hostFunction = value { return true }
            return false
        }
        switch value {
        case .int:
            return ["Int", "Double", "Float", "CGFloat", "TimeInterval", "NSNumber"]
                .contains(HostSignature.unqualified(type))
        case .double:
            return ["Double", "Float", "CGFloat", "TimeInterval", "NSNumber"]
                .contains(HostSignature.unqualified(type))
        case .bool:
            return ["Bool", "NSNumber"].contains(HostSignature.unqualified(type))
        case .string:
            return ["String", "Substring", "NSString"]
                .contains(HostSignature.unqualified(type))
        case .array:
            return type.hasPrefix("[") || type.hasPrefix("Array<")
                || type == "Array" || type == "NSArray"
        case .set:
            return type.hasPrefix("Set<") || type == "Set"
        case .dictionary:
            return type.hasPrefix("[") || type.hasPrefix("Dictionary<")
                || type == "Dictionary" || type == "NSDictionary"
        case .tuple:
            return type.hasPrefix("(") || type == "Tuple"
        case .range:
            return ["Range", "ClosedRange", "PartialRangeFrom",
                    "PartialRangeUpTo", "PartialRangeThrough", "RangeExpression"]
                .contains { type == $0 || type.hasPrefix($0 + "<") }
        case .instance(let instance):
            return HostSignature.equivalentTypeName(instance.symbol.name, type)
        case .enumCase(let value):
            return HostSignature.equivalentTypeName(value.symbol.name, type)
        case .host(let any):
            if let marker = any as? HostTypeMarker {
                return HostSignature.equivalentTypeName(marker.name, type)
                    || HostSignature.equivalentTypeName(marker.name + ".Type", type)
            }
            return HostSignature.equivalentTypeName(
                String(describing: Swift.type(of: any)), type)
        case .closure, .hostFunction:
            return type == "Function" || type.contains("->")
        case .type(let symbol):
            return HostSignature.equivalentTypeName(symbol.name + ".Type", type)
        case .enumType(let symbol):
            return HostSignature.equivalentTypeName(symbol.name + ".Type", type)
        default:
            return false
        }
    }

    static func conforms(_ value: RuntimeValue, to protocolName: String) -> Bool {
        switch protocolName {
        case "Sendable", "Copyable", "Escapable": return true
        case "Equatable", "Hashable":
            switch value {
            case .int, .double, .bool, .string, .set, .enumCase: return true
            default: return false
            }
        case "Comparable":
            switch value {
            case .int, .double, .string: return true
            default: return false
            }
        case "Numeric", "AdditiveArithmetic":
            return value.intValue != nil || value.doubleValue != nil
        case "BinaryInteger", "FixedWidthInteger", "SignedInteger",
             "UnsignedInteger":
            return value.intValue != nil
        case "BinaryFloatingPoint":
            if case .double = value { return true }
            return false
        case "Sequence", "Collection":
            switch value {
            case .array, .set, .dictionary, .range, .string: return true
            default: return false
            }
        case "SetAlgebra":
            if case .set = value { return true }
            return false
        case "StringProtocol": return value.stringValue != nil
        default: return false
        }
    }
}
