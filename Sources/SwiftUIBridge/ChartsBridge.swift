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
        // Custom axis builders (AxisMarks DSL) are not bridged yet: the
        // DEFAULT axes render (real Charts), and the gap is recorded so the
        // residual is visible instead of silent.
        for name in ["chartXAxis", "chartYAxis"] {
            modifiers[name] = HostModifier(name: name) { value, _, _ in
                RenderDiagnostics.record(
                    RuntimeError(message: "custom \(name) builder not bridged; default axes render"),
                    in: "Chart")
                return .native(try Self.anyView(value))
            }
        }
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
