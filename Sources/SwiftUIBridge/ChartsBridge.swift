import Charts
import SwiftUI
import SwiftInterpreter

// Swift Charts magic is restricted to interface-inexpressible execution:
// result-builder evaluation and framework-supplied AxisValue inputs. Mark
// constructors, contextual factories, protocol members, and type erasure are
// generated from swiftinterface metadata by BridgeGen.

extension ViewRegistry {
    func registerChartViews() {
        constructors["Chart"] = HostFunction(name: "Chart") { args, ctx in
            guard let content = args.firstUnlabeledClosure else {
                throw RuntimeError(message: "Chart needs a content builder")
            }
            // Charts declares two initializer families: `Chart { marks }`,
            // whose builder takes nothing, and `Chart(_ data:content:)`, whose
            // builder Charts calls once per element. Which one a call site
            // means is carried by the closure's own arity together with an
            // unlabeled collection argument — the same evidence `ForEach`
            // dispatches on — so neither shape needs naming a chart type.
            let marks: [AnyChartContent]
            if content.parameters.count == 1,
               let data = args.positional(0)?.arrayValue {
                marks = try data.flatMap { element in
                    Self.chartContents(
                        try ctx.callBuilderClosure(
                            content, arguments: [element]),
                        recordDrops: true)
                }
            } else {
                marks = Self.chartContents(
                    try ctx.callBuilderClosure(content, arguments: []),
                    recordDrops: true)
            }
            return .native(AnyView(Chart { Self.composed(marks) }))
        }

        constructors["AxisMarks"] = HostFunction(name: "AxisMarks") { args, ctx in
            guard let interpreter = ctx as? Interpreter else {
                throw RuntimeError(message: "AxisMarks needs the interpreter")
            }
            let content = args.firstUnlabeledClosure
            var values: AxisMarkValues = .automatic
            if case .host(let any)? = args.labeled("values"), let call = any as? ImplicitMemberCall,
               call.name == "automatic" {
                if let stride = call.arguments.labeled("minimumStride")?.doubleValue {
                    values = .automatic(
                        minimumStride: stride,
                        desiredCount: call.arguments.labeled("desiredCount")?.intValue,
                        roundLowerBound: call.arguments.labeled("roundLowerBound")?.boolValue,
                        roundUpperBound: call.arguments.labeled("roundUpperBound")?.boolValue)
                } else {
                    values = .automatic(
                        desiredCount: call.arguments.labeled("desiredCount")?.intValue,
                        roundLowerBound: call.arguments.labeled("roundLowerBound")?.boolValue,
                        roundUpperBound: call.arguments.labeled("roundUpperBound")?.boolValue)
                }
            } else if let raw = args.labeled("values") {
                var dates: [Date] = []
                var numbers: [Double] = []
                for element in raw.arrayValue ?? [] {
                    if case .host(let any) = element, let date = any as? Date {
                        dates.append(date)
                    } else if let number = element.doubleValue {
                        numbers.append(number)
                    }
                }
                if !dates.isEmpty {
                    return .native(AxisMarksSpec(
                        dateValues: dates, automatic: nil, content: content, interpreter: interpreter))
                }
                if !numbers.isEmpty {
                    return .native(AxisMarksSpec(
                        numberValues: numbers, content: content, interpreter: interpreter))
                }
            }
            return .native(AxisMarksSpec(automatic: values, content: content, interpreter: interpreter))
        }

        // These three names each carry an interface-inexpressible overload
        // AND ordinary ones the generated tier already spells. Claim only the
        // inexpressible spelling; the rest fall through to that tier, which
        // reads the real signature. `.chartXAxis(.hidden)` is the case that
        // forced this: it has no builder, so the axis body below had nothing
        // to apply and handed the receiver straight back.
        let ownsAxisBuilder: @MainActor (CallArguments, EvalContext) -> Bool = {
            args, _ in args.firstUnlabeledClosure != nil
        }
        modifiers["chartXAxis"] = HostModifier(
            name: "chartXAxis", ownsCall: ownsAxisBuilder
        ) { value, args, ctx in
            try Self.applyAxis(value, args, ctx, isX: true)
        }
        modifiers["chartYAxis"] = HostModifier(
            name: "chartYAxis", ownsCall: ownsAxisBuilder
        ) { value, args, ctx in
            try Self.applyAxis(value, args, ctx, isX: false)
        }

    }

    static func applyAxis(
        _ value: RuntimeValue, _ args: CallArguments, _ ctx: EvalContext, isX: Bool
    ) throws -> RuntimeValue {
        let view = try Self.anyView(value)
        guard let closure = args.firstUnlabeledClosure,
              let interpreter = ctx as? Interpreter else {
            return .native(view)
        }
        let specs = try interpreter.callBuilderClosure(closure, arguments: [])
            .compactMap { collected -> AxisMarksSpec? in
                if case .host(let any) = collected { return any as? AxisMarksSpec }
                return nil
            }
        guard let spec = specs.first else {
            // No bridgeable AxisMarks in the builder — real default axes.
            if RenderDiagnostics.traceEnabled {
                FileHandle.standardError.write(Data(
                    "CHART axis builder produced no AxisMarks; default axes render\n".utf8))
            }
            return .native(view)
        }
        if isX {
            return .native(AnyView(view.chartXAxis { spec.marks() }))
        }
        return .native(AnyView(view.chartYAxis { spec.marks() }))
    }

    /// Builder output → real chart contents (ForEach fans splice like views).
    static func chartContents(
        _ values: [RuntimeValue], recordDrops: Bool = false
    ) -> [AnyChartContent] {
        var marks: [AnyChartContent] = []
        for value in values {
            var matched = false
            if case .host(let any) = value {
                if let mark = any as? AnyChartContent {
                    marks.append(mark)
                    matched = true
                } else if let nested = any as? [AnyChartContent] {
                    marks.append(contentsOf: nested)
                    matched = true
                }
            }
            if case .array(let elements) = value {
                // A builder statement that came back as a runtime array of
                // marks (nested builder results) — splice, don't drop.
                let inner = chartContents(elements)
                if !inner.isEmpty {
                    marks.append(contentsOf: inner)
                    matched = true
                }
            }
            var isVoid = false
            if case .void = value { isVoid = true }
            if !matched, !isVoid, recordDrops {
                RenderDiagnostics.record(
                    RuntimeError(message: "chart content dropped: \(String(describing: value).prefix(120))"),
                    in: "Chart")
            }
        }
        return marks
    }

    @ChartContentBuilder
    static func composed(_ marks: [AnyChartContent]) -> some ChartContent {
        // ChartContentBuilder has no buildArray over runtime lists; Plot of
        // erased children composes any count.
        ForEach(marks.indices, id: \.self) { index in
            marks[index]
        }
    }
}

/// AxisMarks carrier: builds the REAL AxisMarks whose per-value content
/// closure runs the interpreted builder (the InterpretedLayout pattern —
/// Charts calls it on the main thread during layout).
final class AxisMarksSpec: @unchecked Sendable {
    nonisolated(unsafe) private let dateValues: [Date]?
    nonisolated(unsafe) private let numberValues: [Double]?
    nonisolated(unsafe) private let automatic: AxisMarkValues?
    nonisolated(unsafe) private let content: ClosureValue?
    nonisolated(unsafe) private let interpreter: Interpreter

    @MainActor
    init(dateValues: [Date]? = nil, numberValues: [Double]? = nil,
         automatic: AxisMarkValues?, content: ClosureValue?, interpreter: Interpreter) {
        self.dateValues = dateValues
        self.numberValues = numberValues
        self.automatic = automatic
        self.content = content
        self.interpreter = interpreter
    }

    @MainActor
    convenience init(numberValues: [Double], content: ClosureValue?, interpreter: Interpreter) {
        self.init(dateValues: nil, numberValues: numberValues,
                  automatic: nil, content: content, interpreter: interpreter)
    }

    nonisolated func marks() -> AnyAxisContent {
        if let dateValues {
            return AnyAxisContent(erasing: AxisMarks(values: dateValues) { value in
                self.builtMarks(for: value)
            })
        }
        if let numberValues {
            return AnyAxisContent(erasing: AxisMarks(values: numberValues) { value in
                self.builtMarks(for: value)
            })
        }
        return AnyAxisContent(erasing: AxisMarks(values: automatic ?? .automatic) { value in
            self.builtMarks(for: value)
        })
    }

    private nonisolated func builtMarks(for value: AxisValue) -> AnyAxisMark {
        nonisolated(unsafe) let carried = value
        nonisolated(unsafe) var result = AnyAxisMark(erasing: AxisTick())
        MainActor.assumeIsolated {
            guard let content = self.content else { return }
            do {
                let values = try self.interpreter.callBuilderClosure(
                    content, arguments: [.native(carried)])
                let marks = values.compactMap { collected -> AnyAxisMark? in
                    if case .host(let any) = collected { return any as? AnyAxisMark }
                    return nil
                }
                switch marks.count {
                case 0: break
                case 1: result = marks[0]
                case 2: result = AnyAxisMark(erasing: AxisMarkBuilder.buildBlock(marks[0], marks[1]))
                default: result = AnyAxisMark(erasing: AxisMarkBuilder.buildBlock(marks[0], marks[1], marks[2]))
                }
            } catch let error as RuntimeError {
                RenderDiagnostics.record(error, in: "AxisMarks")
            } catch {
            }
        }
        return result
    }
}

/// AxisValue members: `value.as(Double.self)` in axis label closures.
@MainActor
func axisValueMember(_ name: String, on value: Any) -> RuntimeValue? {
    guard let axisValue = value as? AxisValue else { return nil }
    switch name {
    case "as":
        return .hostFunction(HostFunction(name: name) { args, _ in
            let typeName: String? = {
                if case .host(let any)? = args.positional(0),
                   let marker = any as? HostTypeMarker { return marker.name }
                if case .hostFunction(let function)? = args.positional(0) { return function.name }
                return nil
            }()
            if RenderDiagnostics.traceEnabled {
                FileHandle.standardError.write(Data(
                    "AXISVALUE .as arg=\(String(describing: args.positional(0)).prefix(80)) typeName=\(typeName ?? "nil") asDouble=\(String(describing: axisValue.as(Double.self)))\n".utf8))
            }
            switch typeName {
            case "Double", "CGFloat":
                return .optional(
                    axisValue.as(Double.self).map { RuntimeValue.native($0) },
                    wrappedTypeName: "Double")
            case "Int":
                return .optional(
                    axisValue.as(Int.self).map { RuntimeValue.native($0) },
                    wrappedTypeName: "Int")
            case "Date":
                return .optional(
                    axisValue.as(Date.self).map { RuntimeValue.native($0) },
                    wrappedTypeName: "Date")
            case "String":
                return .optional(
                    axisValue.as(String.self).map { RuntimeValue.native($0) },
                    wrappedTypeName: "String")
            default:
                return .optional(nil, wrappedTypeName: typeName ?? "Any")
            }
        })
    case "index": return .native(axisValue.index)
    case "count": return .native(axisValue.count)
    default: return nil
    }
}
