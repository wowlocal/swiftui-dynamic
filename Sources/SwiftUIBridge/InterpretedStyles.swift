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

/// Shared runtime state for every interface-discovered protocol whose body is
/// invoked with a framework-supplied Configuration. BridgeGen emits the native
/// protocol conformers; this carrier owns only the interface-inexpressible
/// handoff from SwiftUI back into the interpreted requirement.
final class InterpretedFrameworkConfigurationCarrier: @unchecked Sendable {
    let instance: Instance
    let interpreter: Interpreter
    let bodyMethod: String
    let configurationLabel: String?

    nonisolated init(
        instance: Instance,
        interpreter: Interpreter,
        bodyMethod: String,
        configurationLabel: String?
    ) {
        self.instance = instance
        self.interpreter = interpreter
        self.bodyMethod = bodyMethod
        self.configurationLabel = configurationLabel
    }
}

@MainActor
func interpretedFrameworkConfigurationConformer(
    _ value: RuntimeValue,
    protocolType: String,
    descriptor: GeneratedSDKFrameworkConfigurationProtocol,
    context: EvalContext
) -> InterpretedFrameworkConfigurationCarrier? {
    guard let interpreter = context as? Interpreter else { return nil }
    let sourceProtocol = protocolType.split(separator: ".").last
        .map(String.init) ?? protocolType
    let resolved = interpreter.resolveForBridge(
        value, typeName: sourceProtocol)
    guard case .instance(let instance) = resolved,
          interpreter.hostValue(resolved, conformsTo: sourceProtocol),
          instance.symbol.methods[descriptor.bodyMethod] != nil else {
        return nil
    }
    return .init(
        instance: instance,
        interpreter: interpreter,
        bodyMethod: descriptor.bodyMethod,
        configurationLabel: descriptor.configurationLabel)
}

@MainActor
func interpretedFrameworkConfigurationBody(
    carrier: InterpretedFrameworkConfigurationCarrier,
    configuration: Any,
    fallback: AnyView
) -> AnyView {
    do {
        let value = try carrier.interpreter.callMethodLabeled(
            named: carrier.bodyMethod,
            on: carrier.instance,
            arguments: [(
                label: carrier.configurationLabel,
                value: .native(configuration)
            )])
        return (try? ViewRegistry.anyView(value)) ?? fallback
    } catch let error as RuntimeError {
        RenderDiagnostics.record(error, in: carrier.instance.symbol.name)
        return fallback
    } catch {
        return fallback
    }
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
