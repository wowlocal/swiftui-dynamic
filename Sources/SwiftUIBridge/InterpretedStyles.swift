import SwiftUI
import SwiftInterpreter

/// A REAL LabelStyle whose makeBody delegates to the interpreted
/// `makeBody(configuration:)` — user `struct X: LabelStyle` runs its actual
/// body (the InterpretedShape/InterpretedLayout carrier pattern). SwiftUI
/// resolves styles on the main thread during render, so assumeIsolated holds.
private final class StyleCarrier: @unchecked Sendable {
    let instance: Instance
    let interpreter: Interpreter

    nonisolated init(instance: Instance, interpreter: Interpreter) {
        self.instance = instance
        self.interpreter = interpreter
    }
}

/// Resolve user-defined styles by their protocol conformance and makeBody
/// shape. This keeps style coverage proportional to semantic protocols rather
/// than growing one branch per style factory or concrete SDK/app type.
@MainActor
func interpretedStyleConformer(
    _ value: RuntimeValue,
    protocolName: String,
    context: EvalContext
) -> (instance: Instance, interpreter: Interpreter)? {
    guard let interpreter = context as? Interpreter else { return nil }
    let resolved = interpreter.resolveForBridge(value, typeName: protocolName)
    guard case .instance(let instance) = resolved,
          instance.symbol.conformances.contains(protocolName),
          instance.symbol.methods["makeBody"] != nil
    else {
        return nil
    }
    return (instance, interpreter)
}

struct InterpretedLabelStyle: LabelStyle {
    private let carrier: StyleCarrier

    init(instance: Instance, interpreter: Interpreter) {
        carrier = StyleCarrier(instance: instance, interpreter: interpreter)
    }

    nonisolated func makeBody(configuration: Configuration) -> some View {
        nonisolated(unsafe) let carried = configuration
        nonisolated(unsafe) var result = AnyView(EmptyView())
        MainActor.assumeIsolated {
            let carrier = self.carrier
            do {
                let value = try carrier.interpreter.callMethodLabeled(
                    named: "makeBody", on: carrier.instance,
                    arguments: [(label: "configuration", value: .native(carried))])
                if let view = try? ViewRegistry.anyView(value) {
                    result = view
                } else {
                    // Styles must never LOSE the label: fall back to the
                    // unstyled title+icon rather than a blank.
                    result = AnyView(SwiftUI.Label {
                        carried.title
                    } icon: {
                        carried.icon
                    })
                }
            } catch let error as RuntimeError {
                RenderDiagnostics.record(error, in: carrier.instance.symbol.name)
                result = AnyView(SwiftUI.Label {
                    carried.title
                } icon: {
                    carried.icon
                })
            } catch {
            }
        }
        return result
    }
}

struct InterpretedButtonStyle: ButtonStyle {
    private let carrier: StyleCarrier

    init(instance: Instance, interpreter: Interpreter) {
        carrier = StyleCarrier(instance: instance, interpreter: interpreter)
    }

    nonisolated func makeBody(configuration: Configuration) -> some View {
        nonisolated(unsafe) let carried = configuration
        nonisolated(unsafe) var result = AnyView(configuration.label)
        MainActor.assumeIsolated {
            let carrier = self.carrier
            do {
                let value = try carrier.interpreter.callMethodLabeled(
                    named: "makeBody", on: carrier.instance,
                    arguments: [(label: "configuration", value: .native(carried))])
                if let view = try? ViewRegistry.anyView(value) {
                    result = view
                }
            } catch let error as RuntimeError {
                RenderDiagnostics.record(error, in: carrier.instance.symbol.name)
            } catch {
            }
        }
        return result
    }
}

/// Host members for style configurations the interpreted makeBody reads.
@MainActor
func styleHostMember(_ name: String, on value: Any) -> RuntimeValue? {
    if let configuration = value as? LabelStyleConfiguration {
        switch name {
        case "icon": return .native(AnyView(configuration.icon))
        case "title": return .native(AnyView(configuration.title))
        default: return nil
        }
    }
    if let configuration = value as? ButtonStyleConfiguration {
        switch name {
        case "label": return .native(AnyView(configuration.label))
        case "isPressed": return .native(configuration.isPressed)
        default: return nil
        }
    }
    return nil
}
