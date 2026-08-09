import SwiftUI
import SwiftInterpreter

/// A REAL SwiftUI Layout whose sizeThatFits/placeSubviews delegate to the
/// interpreted methods — user `struct HeroSquareTilingLayout: Layout` runs
/// its actual placement math (the InterpretedShape pattern). SwiftUI calls
/// the protocol on the main thread during layout, so assumeIsolated holds.
private final class LayoutCarrier: @unchecked Sendable {
    let instance: Instance
    let interpreter: Interpreter

    nonisolated init(instance: Instance, interpreter: Interpreter) {
        self.instance = instance
        self.interpreter = interpreter
    }
}

/// Runtime counterpart of interpreted `LayoutValueKey` storage. Source key
/// types cannot instantiate native generic arguments, so one native trait
/// carries every source metatype identity and value. SwiftUI still owns
/// propagation from the child View into its LayoutSubview.
struct InterpretedLayoutValueStorage: @unchecked Sendable {
    var values: [ObjectIdentifier: RuntimeValue] = [:]

    func setting(
        _ value: RuntimeValue, for keyID: ObjectIdentifier
    ) -> InterpretedLayoutValueStorage {
        var copy = self
        copy.values[keyID] = value.copiedForValueSemantics()
        return copy
    }

    func merging(
        _ newer: InterpretedLayoutValueStorage
    ) -> InterpretedLayoutValueStorage {
        var copy = self
        copy.values.merge(newer.values) { _, new in new }
        return copy
    }
}

private struct InterpretedLayoutValueStorageKey: LayoutValueKey {
    static let defaultValue = InterpretedLayoutValueStorage()
}

/// Keeps source layout metadata alive across arbitrary modifier chains. Its
/// materialized View carries the complete map in one native trait; retaining
/// the runtime box lets another source `layoutValue` merge a different key.
@MainActor
final class InterpretedLayoutValueViewBox {
    let view: AnyView
    let storage: InterpretedLayoutValueStorage

    init(view: AnyView, storage: InterpretedLayoutValueStorage) {
        self.view = view
        self.storage = storage
    }

    var materializedView: AnyView {
        AnyView(view.layoutValue(
            key: InterpretedLayoutValueStorageKey.self,
            value: storage))
    }

    func replacingView(_ view: AnyView) -> InterpretedLayoutValueViewBox {
        InterpretedLayoutValueViewBox(view: view, storage: storage)
    }
}

@MainActor
func applyingInterpretedLayoutValue(
    _ receiver: RuntimeValue, key: RuntimeValue, value: RuntimeValue
) throws -> RuntimeValue {
    let keyID: ObjectIdentifier
    switch key {
    case .type(let symbol):
        keyID = ObjectIdentifier(symbol)
    case .enumType(let symbol):
        keyID = ObjectIdentifier(symbol)
    default:
        throw RuntimeError(message:
            "layoutValue(key:value:) needs a source LayoutValueKey metatype")
    }
    let existing = receiver.hostPayload as? InterpretedLayoutValueViewBox
    let view = try existing?.view ?? ViewRegistry.anyView(receiver)
    let storage = (existing?.storage ?? InterpretedLayoutValueStorage())
        .setting(value, for: keyID)
    return .native(InterpretedLayoutValueViewBox(
        view: view, storage: storage))
}

/// `subviews[i]` face for interpreted placement code: place/sizeThatFits.
final class LayoutSubviewBox {
    let place: (CGPoint, UnitPoint, ProposedViewSize) -> Void
    let sizeThatFits: (ProposedViewSize) -> CGSize
    let spacing: ViewSpacing
    private let layoutValues: InterpretedLayoutValueStorage
    private let interpreter: Interpreter

    init(place: @escaping (CGPoint, UnitPoint, ProposedViewSize) -> Void,
         sizeThatFits: @escaping (ProposedViewSize) -> CGSize,
         spacing: ViewSpacing,
         layoutValues: InterpretedLayoutValueStorage,
         interpreter: Interpreter) {
        self.place = place
        self.sizeThatFits = sizeThatFits
        self.spacing = spacing
        self.layoutValues = layoutValues
        self.interpreter = interpreter
    }

    func value(for key: RuntimeValue) -> RuntimeValue? {
        switch key {
        case .type(let symbol):
            if let value = layoutValues.values[ObjectIdentifier(symbol)] {
                return value.copiedForValueSemantics()
            }
            return interpreter.readStatic("defaultValue", of: symbol)
        case .enumType(let symbol):
            if let value = layoutValues.values[ObjectIdentifier(symbol)] {
                return value.copiedForValueSemantics()
            }
            return interpreter.readStatic("defaultValue", of: symbol)
        default:
            return nil
        }
    }
}

struct InterpretedLayout: Layout {
    private let carrier: LayoutCarrier

    init(instance: Instance, interpreter: Interpreter) {
        carrier = LayoutCarrier(instance: instance, interpreter: interpreter)
    }

    nonisolated func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        nonisolated(unsafe) let carried = (proposal, subviews)
        nonisolated(unsafe) var result = proposal.replacingUnspecifiedDimensions()
        MainActor.assumeIsolated {
            let carrier = self.carrier
            do {
                let value = try carrier.interpreter.callMethodLabeled(
                    named: "sizeThatFits", on: carrier.instance,
                    arguments: [
                        (label: "proposal", value: .native(carried.0)),
                        (label: "subviews", value: Self.subviewArray(
                            carried.1,
                            for: carrier.instance.symbol.name + ".sizeThatFits",
                            interpreter: carrier.interpreter)),
                        (label: "cache", value: .void),
                    ])
                if case .host(let any) = value, let size = any as? CGSize {
                    result = size
                }
            } catch let error as RuntimeError {
                RenderDiagnostics.record(error, in: carrier.instance.symbol.name)
            } catch {
            }
        }
        return result
    }

    nonisolated func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        nonisolated(unsafe) let carried = (bounds, proposal, subviews)
        MainActor.assumeIsolated {
            let carrier = self.carrier
            do {
                _ = try carrier.interpreter.callMethodLabeled(
                    named: "placeSubviews", on: carrier.instance,
                    arguments: [
                        (label: "in", value: .native(carried.0)),
                        (label: "proposal", value: .native(carried.1)),
                        (label: "subviews", value: Self.subviewArray(
                            carried.2,
                            for: carrier.instance.symbol.name + ".placeSubviews",
                            interpreter: carrier.interpreter)),
                        (label: "cache", value: .void),
                    ])
            } catch let error as RuntimeError {
                RenderDiagnostics.record(error, in: carrier.instance.symbol.name)
            } catch {
            }
        }
    }

    @MainActor
    private static func subviewArray(
        _ subviews: Subviews, for name: String,
        interpreter: Interpreter
    ) -> RuntimeValue {
        if RenderDiagnostics.traceEnabled {
            FileHandle.standardError.write(Data("LAYOUT \(name) subviews=\(subviews.count)\n".utf8))
        }
        let boxes: [RuntimeValue] = subviews.enumerated().map { index, subview in
            .native(LayoutSubviewBox(
                place: { point, anchor, proposal in
                    if RenderDiagnostics.traceEnabled {
                        FileHandle.standardError.write(Data(
                            "PLACE[\(name) #\(index)] at=\(point) anchor=(\(anchor.x),\(anchor.y))\n".utf8))
                    }
                    subview.place(at: point, anchor: anchor, proposal: proposal)
                },
                sizeThatFits: { proposal in
                    if RenderDiagnostics.traceEnabled {
                        FileHandle.standardError.write(Data(
                            "SIZEQ[\(name) #\(index)] -> \(subview.sizeThatFits(proposal))\n".utf8))
                    }
                    return subview.sizeThatFits(proposal)
                },
                spacing: subview.spacing,
                layoutValues:
                    subview[InterpretedLayoutValueStorageKey.self],
                interpreter: interpreter))
        }
        return .native(boxes)
    }
}

/// Host members for the layout faces.
@MainActor
func layoutHostMember(_ name: String, on value: Any) -> RuntimeValue? {
    if let proposal = value as? ProposedViewSize {
        switch name {
        case "width":
            return .optional(
                proposal.width.map { .native(Double($0)) },
                wrappedTypeName: "CGFloat")
        case "height":
            return .optional(
                proposal.height.map { .native(Double($0)) },
                wrappedTypeName: "CGFloat")
        case "replacingUnspecifiedDimensions":
            return .hostFunction(HostFunction(name: name) { args, _ in
                var fallback = CGSize(width: 10, height: 10)
                if case .host(let any)? = args.labeled("by"), let size = any as? CGSize {
                    fallback = size
                }
                return .native(proposal.replacingUnspecifiedDimensions(by: fallback))
            })
        default:
            return nil
        }
    }
    if let box = value as? LayoutSubviewBox {
        switch name {
        case "place":
            return .hostFunction(HostFunction(name: name) { args, _ in
                var point = CGPoint.zero
                if case .host(let any)? = args.labeled("at"), let real = any as? CGPoint {
                    point = real
                }
                let anchor = args.labeled("anchor").flatMap { try? Coerce.unitPoint($0) } ?? .topLeading
                var proposal = ProposedViewSize.unspecified
                if case .host(let any)? = args.labeled("proposal"), let real = any as? ProposedViewSize {
                    proposal = real
                }
                box.place(point, anchor, proposal)
                return .void
            })
        case "sizeThatFits":
            return .hostFunction(HostFunction(name: name) { args, _ in
                var proposal = ProposedViewSize.unspecified
                if case .host(let any)? = args.positional(0), let real = any as? ProposedViewSize {
                    proposal = real
                }
                return .native(box.sizeThatFits(proposal))
            })
        case "spacing":
            return .native(box.spacing)
        case "subscript":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let key = args.positional(0),
                      let value = box.value(for: key) else {
                    throw RuntimeError(message:
                        "LayoutSubview subscript needs a LayoutValueKey metatype")
                }
                return value
            })
        default:
            return nil
        }
    }
    if let spacing = value as? ViewSpacing {
        switch name {
        case "distance":
            // `spacing.distance(to: other, along: .horizontal)` — the
            // FlowLayout spacing math runs on REAL ViewSpacing.
            return .hostFunction(HostFunction(name: name) { args, _ in
                var other = ViewSpacing()
                if case .host(let any)? = args.labeled("to"), let real = any as? ViewSpacing {
                    other = real
                }
                var axis = Axis.horizontal
                if case .implicitMember("vertical")? = args.labeled("along") {
                    axis = .vertical
                }
                return .native(spacing.distance(to: other, along: axis))
            })
        default:
            return nil
        }
    }
    return nil
}
