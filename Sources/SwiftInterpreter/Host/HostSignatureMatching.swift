import Foundation

// MARK: - Argument and return contracts

@MainActor
extension HostSignature {
    /// Returns `nil` when this declaration cannot accept the evaluated call.
    /// This non-throwing form is used to rank overload candidates.
    public func match(
        arguments: CallArguments, in context: EvalContext
    ) -> HostCallMatch? {
        guard isCallable else { return nil }
        return bestMatch(arguments: arguments, context: context)
    }

    /// Whether labels, arity, defaults, and trailing-closure placement fit
    /// this declaration, without considering runtime argument types. Generated
    /// adapters use this to decide whether an interface declaration owns a
    /// legacy gateway call before asking the full typed matcher to validate it.
    public func matchesArgumentShape(_ arguments: CallArguments) -> Bool {
        isCallable && !shapeMatches(arguments).isEmpty
    }

    /// Expected types for a call's actual arguments when every legal
    /// default/variadic mapping agrees. This is deliberately shape-only:
    /// overload sets can apply contextual typing once when all surviving
    /// declarations name the same type, before asking the ordinary matcher to
    /// rank the resulting concrete values.
    func unambiguousContextualParameterTypes(
        for arguments: CallArguments
    ) -> [String?]? {
        let shapes = shapeMatches(arguments)
        guard !shapes.isEmpty else { return nil }
        return arguments.arguments.indices.map { argumentIndex in
            let types = Set(shapes.map {
                parameters[$0.parameterIndices[argumentIndex]].type
            })
            return types.count == 1 ? types.first : nil
        }
    }

    func resolvingContextualArguments(
        _ arguments: CallArguments, in context: EvalContext
    ) -> CallArguments {
        guard let parameterTypes = unambiguousContextualParameterTypes(
            for: arguments) else { return arguments }
        return arguments.resolvingContextualValues(
            parameterTypes: parameterTypes, in: context)
    }

    /// Validates labels, arity, runtime argument types, generic consistency,
    /// and generic constraints. The returned bindings must be supplied to
    /// `validateReturn`.
    @discardableResult
    public func validate(
        arguments: CallArguments, in context: EvalContext
    ) throws -> HostCallMatch {
        guard isCallable else {
            throw RuntimeError(message:
                "host property '\(declaration)' cannot be invoked as a function")
        }
        if let match = bestMatch(arguments: arguments, context: context) {
            return match
        }
        throw validationError(arguments: arguments, context: context)
    }

    /// Validates a gateway result against the declaration's return type,
    /// including generic bindings established by the arguments.
    public func validateReturn(
        _ value: RuntimeValue, match: HostCallMatch,
        in context: EvalContext
    ) throws {
        let expected = returnType ?? "Void"
        if expected == "Never" {
            throw RuntimeError(message:
                "host contract violation: '\(declaration)' returned, but its return type is Never")
        }
        var bindings = match.genericBindings
        var representatives: [String: RuntimeValue] = [:]
        guard Self.matchType(
            value, against: expected,
            genericNames: Set(genericParameters.map(\.name)),
            bindings: &bindings, representatives: &representatives,
            context: context, mayBind: false) != nil else {
            let resolvedExpected = Self.substitutingGenerics(
                in: expected, bindings: match.genericBindings)
            throw RuntimeError(message:
                "host contract violation: '\(declaration)' returned '\(context.hostTypeName(of: value))', expected '\(resolvedExpected)'")
        }
    }

    /// Receiver and value validation used by `HostProperty`.
    func validateReceiver(
        _ receiver: RuntimeValue, in context: EvalContext
    ) throws {
        guard let receiverType else { return }
        var bindings: [String: String] = [:]
        var representatives: [String: RuntimeValue] = [:]
        guard Self.matchType(
            receiver, against: receiverType, genericNames: [],
            bindings: &bindings, representatives: &representatives,
            context: context, mayBind: false) != nil else {
            throw RuntimeError(message:
                "host contract violation: property '\(declaration)' received '\(context.hostTypeName(of: receiver))', expected receiver '\(receiverType)'")
        }
    }

    func validatePropertyValue(
        _ value: RuntimeValue, in context: EvalContext,
        operation: String = "produced"
    ) throws {
        let expected = returnType ?? "Void"
        var bindings: [String: String] = [:]
        var representatives: [String: RuntimeValue] = [:]
        guard Self.matchType(
            value, against: expected, genericNames: [],
            bindings: &bindings, representatives: &representatives,
            context: context, mayBind: false) != nil else {
            throw RuntimeError(message:
                "host contract violation: property '\(declaration)' \(operation) '\(context.hostTypeName(of: value))', expected '\(expected)'")
        }
    }
}

@MainActor
extension CallArguments {
    func resolvingContextualValues(
        parameterTypes: [String?], in context: EvalContext
    ) -> CallArguments {
        guard parameterTypes.count == arguments.count else { return self }
        var resolved = self
        for index in arguments.indices {
            let argument = arguments[index]
            guard let typeName = parameterTypes[index],
                  argument.value.containsUnresolvedContextualMember else {
                continue
            }
            resolved.arguments[index] = Argument(
                label: argument.label,
                value: context.resolveForBridge(
                    argument.value, typeName: typeName),
                isTrailing: argument.isTrailing,
                sourceProvenance: argument.sourceProvenance,
                localizedLiteral: argument.localizedLiteral)
        }
        return resolved
    }
}

@MainActor
private extension HostSignature {
    struct ShapeMatch {
        let parameterIndices: [Int]
        let skippedDefaults: Int
        let usedVariadic: Bool
    }

    func shapeMatches(_ arguments: CallArguments) -> [ShapeMatch] {
        let args = arguments.arguments
        var matches: [ShapeMatch] = []
        let resultLimit = 256

        func walk(
            parameterIndex: Int, argumentIndex: Int,
            mapping: [Int], skippedDefaults: Int, usedVariadic: Bool
        ) {
            guard matches.count < resultLimit else { return }
            if parameterIndex == parameters.count {
                if argumentIndex == args.count {
                    matches.append(ShapeMatch(
                        parameterIndices: mapping,
                        skippedDefaults: skippedDefaults,
                        usedVariadic: usedVariadic))
                }
                return
            }

            let parameter = parameters[parameterIndex]
            if parameter.isVariadic {
                // Zero elements is always a legal variadic binding.
                walk(
                    parameterIndex: parameterIndex + 1,
                    argumentIndex: argumentIndex,
                    mapping: mapping,
                    skippedDefaults: skippedDefaults,
                    usedVariadic: usedVariadic)

                var nextArgument = argumentIndex
                var nextMapping = mapping
                var first = true
                while nextArgument < args.count {
                    let expectedLabel = first ? parameter.label : nil
                    guard Self.labelMatches(
                        args[nextArgument], expected: expectedLabel,
                        parameterType: parameter.type) else { break }
                    nextMapping.append(parameterIndex)
                    nextArgument += 1
                    first = false
                    walk(
                        parameterIndex: parameterIndex + 1,
                        argumentIndex: nextArgument,
                        mapping: nextMapping,
                        skippedDefaults: skippedDefaults,
                        usedVariadic: true)
                }
                return
            }

            if parameter.hasDefault {
                walk(
                    parameterIndex: parameterIndex + 1,
                    argumentIndex: argumentIndex,
                    mapping: mapping,
                    skippedDefaults: skippedDefaults + 1,
                    usedVariadic: usedVariadic)
            }
            guard argumentIndex < args.count,
                  Self.labelMatches(
                    args[argumentIndex], expected: parameter.label,
                    parameterType: parameter.type) else { return }
            walk(
                parameterIndex: parameterIndex + 1,
                argumentIndex: argumentIndex + 1,
                mapping: mapping + [parameterIndex],
                skippedDefaults: skippedDefaults,
                usedVariadic: usedVariadic)
        }

        walk(
            parameterIndex: 0, argumentIndex: 0, mapping: [],
            skippedDefaults: 0, usedVariadic: false)
        return matches
    }

    static func labelMatches(
        _ argument: CallArguments.Argument,
        expected: String?, parameterType: String
    ) -> Bool {
        if argument.label == expected { return true }
        // Swift permits the first trailing closure to omit its parameter
        // label. Additional trailing closures retain their explicit labels.
        return argument.isTrailing && argument.label == nil
            && isFunctionType(parameterType)
            && argument.value.closureValue != nil
    }

    func bestMatch(
        arguments: CallArguments, context: EvalContext
    ) -> HostCallMatch? {
        let genericNames = Set(genericParameters.map(\.name))
        var best: HostCallMatch?
        for shape in shapeMatches(arguments) {
            var bindings: [String: String] = [:]
            var representatives: [String: RuntimeValue] = [:]
            var score = 1_000 - shape.skippedDefaults * 8
                - (shape.usedVariadic ? 2 : 0)
            var valid = true
            for (argument, parameterIndex) in zip(
                arguments.arguments, shape.parameterIndices
            ) {
                guard let typeScore = Self.matchType(
                    argument.value,
                    against: parameters[parameterIndex].type,
                    genericNames: genericNames,
                    bindings: &bindings,
                    representatives: &representatives,
                    context: context,
                    mayBind: true) else {
                    valid = false
                    break
                }
                score += typeScore
            }
            guard valid, constraintsMatch(
                bindings: bindings,
                representatives: representatives,
                context: context) else { continue }
            let candidate = HostCallMatch(
                genericBindings: bindings,
                score: score,
                parameterIndices: shape.parameterIndices)
            if best == nil || candidate.score > best!.score {
                best = candidate
            }
        }
        return best
    }

    func constraintsMatch(
        bindings: [String: String],
        representatives: [String: RuntimeValue],
        context: EvalContext
    ) -> Bool {
        for generic in genericParameters where bindings[generic.name] != nil {
            guard let representative = representatives[generic.name] else {
                // A metatype binds its named type without materializing an
                // instance. The interpreter cannot prove that conformance at
                // this boundary, so defer it to the statically-compiled body.
                continue
            }
            for constraint in generic.constraints {
                if !context.hostValue(representative, conformsTo: constraint) {
                    return false
                }
            }
        }
        return true
    }

    func validationError(
        arguments: CallArguments, context: EvalContext
    ) -> RuntimeError {
        let args = arguments.arguments
        if parameters.isEmpty, !args.isEmpty {
            return RuntimeError(message:
                "argument passed to host call '\(callableName)' that takes no arguments")
        }
        let required = parameters.filter { !$0.hasDefault && !$0.isVariadic }
        if args.count < required.count,
           let missing = firstMissingParameter(for: arguments) {
            return RuntimeError(message:
                "missing argument for parameter '\(missing.name)' in host call '\(callableName)'")
        }
        if !parameters.contains(where: \.isVariadic),
           args.count > parameters.count {
            let extra = args[parameters.count]
            let suffix = extra.label.map { " '\($0)'" } ?? ""
            return RuntimeError(message:
                "extra argument\(suffix) in host call '\(callableName)'")
        }

        let shapes = shapeMatches(arguments)
        if shapes.isEmpty {
            let have = args.map { ($0.label ?? "_") + ":" }.joined()
            let expected = parameters.map { ($0.label ?? "_") + ":" }.joined()
            return RuntimeError(message:
                "incorrect argument labels in host call '\(callableName)' (have '\(have)', expected '\(expected)')")
        }

        let genericNames = Set(genericParameters.map(\.name))
        let shape = shapes[0]
        var bindings: [String: String] = [:]
        var representatives: [String: RuntimeValue] = [:]
        for (argument, parameterIndex) in zip(args, shape.parameterIndices) {
            let parameter = parameters[parameterIndex]
            if Self.matchType(
                argument.value, against: parameter.type,
                genericNames: genericNames,
                bindings: &bindings, representatives: &representatives,
                context: context, mayBind: true) == nil {
                return RuntimeError(message:
                    "cannot convert host argument '\(parameter.name)' of type '\(context.hostTypeName(of: argument.value))' to expected type '\(parameter.type)'")
            }
        }
        return RuntimeError(message:
            "generic constraints do not match host declaration '\(declaration)'")
    }

    func firstMissingParameter(for arguments: CallArguments) -> Parameter? {
        var argumentIndex = 0
        for parameter in parameters {
            if parameter.isVariadic { continue }
            if argumentIndex < arguments.arguments.count,
               Self.labelMatches(
                arguments.arguments[argumentIndex], expected: parameter.label,
                parameterType: parameter.type) {
                argumentIndex += 1
            } else if !parameter.hasDefault {
                return parameter
            }
        }
        return parameters.first { !$0.hasDefault && !$0.isVariadic }
    }
}
