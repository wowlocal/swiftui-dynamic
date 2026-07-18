import Foundation
import SwiftInterpreter

/// Fresh-store doctrine v2 (M3): the per-run in-memory model store. What the
/// interpreted UI inserts, its fetches read back — every run still starts
/// empty, so determinism holds, but todo/notes-genre apps become functional
/// instead of write-to-void. Keyed per Interpreter (weak), so parallel
/// tests and successive probe runs never share state.
public final class LiveModelStore {
    private static let stores = NSMapTable<AnyObject, LiveModelStore>.weakToStrongObjects()

    static func `for`(_ context: EvalContext) -> LiveModelStore {
        if let existing = stores.object(forKey: context) {
            return existing
        }
        let fresh = LiveModelStore()
        stores.setObject(fresh, forKey: context)
        return fresh
    }

    /// Instances by their model type name, in insertion order.
    private(set) var instances: [(typeName: String, value: RuntimeValue)] = []

    /// Store writes publish here — @Query views subscribe (the model
    /// changeSignal pattern) so an insert re-renders the querying view,
    /// completing the M3 doctrine: what the UI writes, its queries read
    /// back AND SHOW without external triggers.
    public let changeSignal = ChangeSignal()

    func insert(_ value: RuntimeValue) {
        instances.append((Self.typeName(of: value), value))
        changeSignal.fire()
    }

    func delete(_ value: RuntimeValue) {
        guard case .instance(let target) = value else { return }
        let index = instances.firstIndex { entry in
            guard case .instance(let stored) = entry.value,
                  stored.symbol.name == target.symbol.name else { return false }
            if stored.symbol.isClass || target.symbol.isClass {
                return stored === target
            }
            // Test/dynamic sources sometimes model a SwiftData row as a
            // struct even though PersistentModel is class-bound natively.
            // Fetch necessarily returns a value copy, so use its complete
            // stored-value shape as the fallback row identity.
            return Self.structuralKey(stored) == Self.structuralKey(target)
        }
        if let index {
            instances.remove(at: index)
            changeSignal.fire()
        }
    }

    func fetch(typeName: String?) -> [RuntimeValue] {
        guard let typeName, !typeName.isEmpty else {
            return instances.map(\.value)
        }
        return instances.filter { $0.typeName == typeName }.map(\.value)
    }

    /// Fill @Query/@FetchRequest boxes from the live store — called at the
    /// same points as environment injection, so every body evaluation sees
    /// the store's current rows (insertion order; sort descriptors and
    /// predicates are documented divergences until the histogram demands
    /// them).
    public static func refreshQueries(into instance: Instance, interpreter: Interpreter) {
        for property in instance.symbol.storedProperties where property.wrapper == .query {
            var element = property.typeAnnotation?.trimmedDescription ?? ""
            if element.hasPrefix("["), element.hasSuffix("]") {
                element = String(element.dropFirst().dropLast())
            }
            if let angle = element.firstIndex(of: "<") { element = String(element[..<angle]) }
            let rows = LiveModelStore.for(interpreter).fetch(typeName: element)
            instance.box(for: property.name)?.value = .native(rows)
        }
    }

    private static func typeName(of value: RuntimeValue) -> String {
        if case .instance(let instance) = value {
            return instance.symbol.name
        }
        return "?"
    }

    private static func structuralKey(_ instance: Instance) -> String {
        let values = instance.symbol.storedProperties.map { property in
            "\(property.name)=\(instance.box(for: property.name)?.value.stringified ?? "nil")"
        }
        return "\(instance.symbol.name){\(values.joined(separator: ";"))}"
    }
}
