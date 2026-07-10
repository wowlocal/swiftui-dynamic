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

    func insert(_ value: RuntimeValue) {
        instances.append((Self.typeName(of: value), value))
    }

    func delete(_ value: RuntimeValue) {
        guard case .instance(let target) = value else { return }
        instances.removeAll {
            if case .instance(let stored) = $0.value {
                return stored === target
            }
            return false
        }
    }

    func fetch(typeName: String?) -> [RuntimeValue] {
        guard let typeName, !typeName.isEmpty else {
            return instances.map(\.value)
        }
        return instances.filter { $0.typeName == typeName }.map(\.value)
    }

    private static func typeName(of value: RuntimeValue) -> String {
        if case .instance(let instance) = value {
            return instance.symbol.name
        }
        return "?"
    }
}
