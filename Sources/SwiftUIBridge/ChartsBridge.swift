import Charts
import SwiftUI
import SwiftInterpreter

// Swift Charts gateway — a documented SwiftUI-magic allowlist entry
// (AGENTS.md): the Chart/ChartContent result builders and the
// `.value("Label", v)` PlottableValue factory are interface-inexpressible
// DSL glue. Marks build as REAL Charts marks erased to AnyChartContent;
// everything downstream (layout, axes, scales, gradients) is the real
// framework. Unsupported surface records a RenderDiagnostics entry and
// degrades to an empty mark set, never a blank absorb.

/// `.value("Label", v)` — the typed plottable carrier.
private struct PlottableSpec {
    let label: String
    let value: RuntimeValue

    var date: Date? {
        if case .host(let any) = value, let date = any as? Date { return date }
        return nil
    }
    var double: Double? { value.doubleValue }
    var string: String? { value.stringValue }
}

private func plottable(_ raw: RuntimeValue?) -> PlottableSpec? {
    guard case .host(let any)? = raw, let call = any as? ImplicitMemberCall,
          call.name == "value",
          let label = call.arguments.positional(0)?.stringValue else { return nil }
    let payload = call.arguments.positional(1) ?? .void
    return PlottableSpec(label: label, value: payload)
}

/// `width: .fixed(4)` — MarkDimension positions.
private func markDimension(_ raw: RuntimeValue?) -> MarkDimension? {
    guard let raw else { return nil }
    if let number = raw.doubleValue { return .fixed(number) }
    if case .host(let any) = raw, let call = any as? ImplicitMemberCall,
       let amount = call.arguments.positional(0)?.doubleValue {
        switch call.name {
        case "fixed": return .fixed(amount)
        case "ratio": return .ratio(amount)
        case "inset": return .inset(amount)
        default: return nil
        }
    }
    return nil
}

extension ViewRegistry {
    func registerChartViews() {
        constructors["Chart"] = HostFunction(name: "Chart") { args, ctx in
            guard let content = args.firstUnlabeledClosure else {
                throw RuntimeError(message: "Chart needs a content builder")
            }
            let values = try ctx.callBuilderClosure(content, arguments: [])
            let marks = Self.chartContents(values, recordDrops: true)
            return .native(AnyView(Chart { Self.composed(marks) }))
        }

        constructors["AreaMark"] = HostFunction(name: "AreaMark") { args, _ in
            guard let x = plottable(args.labeled("x")) else {
                throw RuntimeError(message: "AreaMark needs x: .value(…)")
            }
            // Date-x + Double-y is the forecast shape; Double-x mirrors it.
            if let yStart = plottable(args.labeled("yStart")), let yEnd = plottable(args.labeled("yEnd")) {
                let series = plottable(args.labeled("series"))
                guard let yStartValue = yStart.double, let yEndValue = yEnd.double else {
                    throw RuntimeError(message: "AreaMark yStart/yEnd need numeric plottables")
                }
                if let date = x.date {
                    if let series, let seriesValue = series.double {
                        return .native(AnyChartContent(AreaMark(
                            x: .value(x.label, date),
                            yStart: .value(yStart.label, yStartValue),
                            yEnd: .value(yEnd.label, yEndValue),
                            series: .value(series.label, seriesValue))))
                    }
                    return .native(AnyChartContent(AreaMark(
                        x: .value(x.label, date),
                        yStart: .value(yStart.label, yStartValue),
                        yEnd: .value(yEnd.label, yEndValue))))
                }
                if let xValue = x.double {
                    return .native(AnyChartContent(AreaMark(
                        x: .value(x.label, xValue),
                        yStart: .value(yStart.label, yStartValue),
                        yEnd: .value(yEnd.label, yEndValue))))
                }
            }
            if let y = plottable(args.labeled("y")), let yValue = y.double {
                if let date = x.date {
                    return .native(AnyChartContent(AreaMark(
                        x: .value(x.label, date), y: .value(y.label, yValue))))
                }
                if let xValue = x.double {
                    return .native(AnyChartContent(AreaMark(
                        x: .value(x.label, xValue), y: .value(y.label, yValue))))
                }
                if let xString = x.string {
                    return .native(AnyChartContent(AreaMark(
                        x: .value(x.label, xString), y: .value(y.label, yValue))))
                }
            }
            throw RuntimeError(message: "AreaMark argument shape not bridged yet")
        }

        constructors["RectangleMark"] = HostFunction(name: "RectangleMark") { args, _ in
            // Band form: xStart/xEnd (the forecast's night ranges).
            if let xStart = plottable(args.labeled("xStart")), let xEnd = plottable(args.labeled("xEnd")) {
                if let startDate = xStart.date, let endDate = xEnd.date {
                    return .native(AnyChartContent(RectangleMark(
                        xStart: .value(xStart.label, startDate),
                        xEnd: .value(xEnd.label, endDate))))
                }
                if let startValue = xStart.double, let endValue = xEnd.double {
                    return .native(AnyChartContent(RectangleMark(
                        xStart: .value(xStart.label, startValue),
                        xEnd: .value(xEnd.label, endValue))))
                }
            }
            // Pillar form: x + yStart/yEnd (+ width).
            if let x = plottable(args.labeled("x")),
               let yStart = plottable(args.labeled("yStart")), let yEnd = plottable(args.labeled("yEnd")),
               let yStartValue = yStart.double, let yEndValue = yEnd.double {
                let width = markDimension(args.labeled("width")) ?? .automatic
                if let date = x.date {
                    return .native(AnyChartContent(RectangleMark(
                        x: .value(x.label, date),
                        yStart: .value(yStart.label, yStartValue),
                        yEnd: .value(yEnd.label, yEndValue),
                        width: width)))
                }
                if let xValue = x.double {
                    return .native(AnyChartContent(RectangleMark(
                        x: .value(x.label, xValue),
                        yStart: .value(yStart.label, yStartValue),
                        yEnd: .value(yEnd.label, yEndValue),
                        width: width)))
                }
            }
            throw RuntimeError(message: "RectangleMark argument shape not bridged yet")
        }

        constructors["LineMark"] = HostFunction(name: "LineMark") { args, _ in
            guard let x = plottable(args.labeled("x")),
                  let y = plottable(args.labeled("y")), let yValue = y.double else {
                throw RuntimeError(message: "LineMark needs x:/y: .value(…)")
            }
            if let date = x.date {
                return .native(AnyChartContent(LineMark(
                    x: .value(x.label, date), y: .value(y.label, yValue))))
            }
            if let xValue = x.double {
                return .native(AnyChartContent(LineMark(
                    x: .value(x.label, xValue), y: .value(y.label, yValue))))
            }
            if let xString = x.string {
                return .native(AnyChartContent(LineMark(
                    x: .value(x.label, xString), y: .value(y.label, yValue))))
            }
            throw RuntimeError(message: "LineMark argument shape not bridged yet")
        }

        constructors["BarMark"] = HostFunction(name: "BarMark") { args, _ in
            guard let x = plottable(args.labeled("x")),
                  let y = plottable(args.labeled("y")), let yValue = y.double else {
                throw RuntimeError(message: "BarMark needs x:/y: .value(…)")
            }
            if let xString = x.string {
                return .native(AnyChartContent(BarMark(
                    x: .value(x.label, xString), y: .value(y.label, yValue))))
            }
            if let date = x.date {
                return .native(AnyChartContent(BarMark(
                    x: .value(x.label, date), y: .value(y.label, yValue))))
            }
            if let xValue = x.double {
                return .native(AnyChartContent(BarMark(
                    x: .value(x.label, xValue), y: .value(y.label, yValue))))
            }
            throw RuntimeError(message: "BarMark argument shape not bridged yet")
        }

        constructors["DateBins"] = HostFunction(name: "DateBins") { args, _ in
            var unit = Calendar.Component.hour
            if case .implicitMember(let name)? = args.labeled("unit") {
                switch name {
                case "hour": unit = .hour
                case "day": unit = .day
                case "minute": unit = .minute
                case "month": unit = .month
                default: break
                }
            }
            let stride = args.labeled("by")?.intValue ?? 1
            guard let rawRange = args.labeled("range"),
                  case .range(let range) = rawRange,
                  case .host(let lowerAny)? = range.lowerBound, let lower = lowerAny as? Date,
                  case .host(let upperAny)? = range.upperBound, let upper = upperAny as? Date else {
                throw RuntimeError(message: "DateBins needs unit:by:range: with a Date range")
            }
            return .native(DateBins(unit: unit, by: stride, range: lower...upper))
        }

        constructors["AxisTick"] = HostFunction(name: "AxisTick") { _, _ in
            .native(AnyAxisMark(erasing: AxisTick()))
        }
        constructors["AxisGridLine"] = HostFunction(name: "AxisGridLine") { _, _ in
            .native(AnyAxisMark(erasing: AxisGridLine()))
        }
        constructors["AxisValueLabel"] = HostFunction(name: "AxisValueLabel") { args, _ in
            if let format = args.labeled("format") {
                if let style = dateFormatStyle(format) {
                    return .native(AnyAxisMark(erasing: AxisValueLabel(format: style)))
                }
                throw RuntimeError(message: "AxisValueLabel format shape not bridged yet")
            }
            let label = args.positional(0)?.stringValue ?? ""
            return .native(AnyAxisMark(erasing: AxisValueLabel(label)))
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
                        roundLowerBound: call.arguments.labeled("roundLowerBound")?.boolValue)
                } else {
                    values = .automatic(
                        desiredCount: call.arguments.labeled("desiredCount")?.intValue,
                        roundLowerBound: call.arguments.labeled("roundLowerBound")?.boolValue)
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

        modifiers["chartXAxis"] = HostModifier(name: "chartXAxis") { value, args, ctx in
            try Self.applyAxis(value, args, ctx, isX: true)
        }
        modifiers["chartYAxis"] = HostModifier(name: "chartYAxis") { value, args, ctx in
            try Self.applyAxis(value, args, ctx, isX: false)
        }

        modifiers["chartYScale"] = HostModifier(name: "chartYScale") { value, args, _ in
            let view = try Self.anyView(value)
            if case .host(let any)? = args.labeled("domain"), let call = any as? ImplicitMemberCall,
               call.name == "automatic" {
                let includesZero = call.arguments.labeled("includesZero")?.boolValue ?? true
                return .native(AnyView(view.chartYScale(
                    domain: .automatic(includesZero: includesZero))))
            }
            return .native(view)
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
            if ProcessInfo.processInfo.environment["FTCHECK_TRACE"] != nil {
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

/// Mark modifiers — ChartContent protocol members on the erased mark.
/// Arrays (a @ChartContentBuilder helper's multi-mark return, or a chart
/// ForEach) compose first: modifying the group IS the builder semantics.
@MainActor
func chartContentMember(_ name: String, on value: Any) -> RuntimeValue? {
    if ProcessInfo.processInfo.environment["FTCHECK_TRACE"] != nil,
       name == "foregroundStyle" {
        var detail = String(describing: type(of: value))
        if let chain = value as? ChainedImplicitCall {
            detail += " member=\(chain.member) base=\(String(describing: chain.base).prefix(120))"
        }
        FileHandle.standardError.write(Data(
            "CHARTMEMBER .\(name) on \(detail)\n".utf8))
    }
    var composed: AnyChartContent?
    if let mark = value as? AnyChartContent {
        composed = mark
    } else if let marks = value as? [AnyChartContent] {
        // Empty is a legal builder result (a pass with no data yet) — the
        // modifier still applies to chart content, never a view retry.
        composed = AnyChartContent(ViewRegistry.composed(marks))
    }
    guard let mark = composed else { return nil }
    switch name {
    case "foregroundStyle":
        return .hostFunction(HostFunction(name: name) { args, _ in
            guard let first = args.positional(0),
                  let style = try? Coerce.shapeStyle(first) else {
                // Unbridged style shapes (`.indigo.shadow(.drop(…))`) keep
                // the mark painting in its default style, visibly logged.
                RenderDiagnostics.record(
                    RuntimeError(message: "mark foregroundStyle shape not bridged; default style renders"),
                    in: "ChartContent")
                return .native(mark)
            }
            return .native(AnyChartContent(mark.foregroundStyle(style)))
        })
    case "opacity":
        return .hostFunction(HostFunction(name: name) { args, _ in
            let amount = args.positional(0)?.doubleValue ?? 1
            return .native(AnyChartContent(mark.opacity(amount)))
        })
    case "interpolationMethod":
        return .hostFunction(HostFunction(name: name) { args, _ in
            guard case .implicitMember(let method)? = args.positional(0) else {
                return .native(mark)
            }
            let interpolation: InterpolationMethod = switch method {
            case "catmullRom": .catmullRom
            case "monotone": .monotone
            case "stepStart": .stepStart
            case "stepEnd": .stepEnd
            case "stepCenter": .stepCenter
            case "cardinal": .cardinal
            default: .linear
            }
            return .native(AnyChartContent(mark.interpolationMethod(interpolation)))
        })
    case "cornerRadius":
        return .hostFunction(HostFunction(name: name) { args, _ in
            let radius = args.positional(0)?.doubleValue ?? 0
            return .native(AnyChartContent(mark.cornerRadius(radius)))
        })
    case "mask":
        return .hostFunction(HostFunction(name: name) { args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return .native(mark) }
            let inner = ViewRegistry.chartContents(
                try ctx.callBuilderClosure(closure, arguments: []), recordDrops: true)
            return .native(AnyChartContent(mark.mask {
                ViewRegistry.composed(inner)
            }))
        })
    case "annotation":
        return .hostFunction(HostFunction(name: name) { args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return .native(mark) }
            let views = try ctx.callBuilderClosure(closure, arguments: [])
                .compactMap { try? ViewRegistry.anyView($0) }
            let position: AnnotationPosition = switch args.labeled("position") {
            case .implicitMember("top"): .top
            case .implicitMember("bottom"): .bottom
            case .implicitMember("leading"): .leading
            case .implicitMember("trailing"): .trailing
            case .implicitMember("overlay"): .overlay
            default: .automatic
            }
            let spacing = args.labeled("spacing")?.doubleValue.map { CGFloat($0) }
            guard let view = views.first else { return .native(mark) }
            return .native(AnyChartContent(mark.annotation(
                position: position, spacing: spacing) { view }))
        })
    default:
        return nil
    }
}


/// `.dateTime.hour()`-style Date.FormatStyle chains for AxisValueLabel.
private func dateFormatStyle(_ value: RuntimeValue) -> Date.FormatStyle? {
    if case .implicitMember("dateTime") = value { return Date.FormatStyle() }
    if case .host(let any) = value, let chained = any as? ChainedImplicitCall,
       let base = dateFormatStyle(chained.base) {
        switch chained.member {
        case "hour": return base.hour()
        case "minute": return base.minute()
        case "day": return base.day()
        case "month": return base.month()
        case "year": return base.year()
        default: return nil
        }
    }
    return nil
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
            if ProcessInfo.processInfo.environment["FTCHECK_TRACE"] != nil {
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
