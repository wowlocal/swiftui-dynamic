/// Eager member lookup retains all established precedence rules, but cannot
/// itself await an effectful host getter. The async evaluator resolves this
/// private carrier immediately after lookup and never exposes it to source.
final class PendingHostPropertyRead {
    let property: HostProperty
    let receiver: RuntimeValue

    init(property: HostProperty, receiver: RuntimeValue) {
        self.property = property
        self.receiver = receiver
    }
}

extension Interpreter {
    /// One funnel for typed and legacy host-member reads. Parsed properties
    /// win; the dynamic hook remains the migration fallback.
    func readHostMember(
        _ name: String, on value: Any,
        deferringAsyncProperty: Bool = false
    ) throws -> RuntimeValue? {
        if let marker = value as? HostTypeMarker,
           marker.name == "MemoryLayout",
           let typeName = marker.genericArguments.first {
            let layout = try runtimeABILayout(typeName: typeName)
            switch name {
            case "size": return .native(layout.size)
            case "stride": return .native(layout.stride)
            case "alignment": return .native(layout.alignment)
            default: break
            }
        }
        if let marker = value as? HostTypeMarker,
           marker.name == "Thread", name == "isMainThread" {
            // The native MainActor is an implementation host for today's
            // cooperative evaluator, not the source program's executor.
            // Project the logical lane so @concurrent/MainActor hops remain
            // observable without pretending the mutable heap is parallel-safe.
            return .native(evaluationTaskContext.currentExecutor.isMainActor)
        }
        if let property = registry?.hostProperty(named: name, on: value) {
            let receiver = RuntimeValue.native(value)
            if deferringAsyncProperty && property.canSuspend {
                return .native(PendingHostPropertyRead(
                    property: property, receiver: receiver))
            }
            return try property.read(from: receiver, in: self)
        }
        return registry?.hostMember(name, on: value)
    }

    /// Setter counterpart to `readHostMember`. A typed descriptor validates
    /// the assigned value before framework code sees it.
    func writeHostMember(
        _ name: String, on value: Any, to newValue: RuntimeValue
    ) throws -> Bool {
        if try writeRuntimeAsyncStreamMember(
            name, on: value, to: newValue) {
            return true
        }
        if let property = registry?.hostProperty(named: name, on: value) {
            if property.signature.isSettable {
                let assigned = try property.signature.returnType.map {
                    try resolveAnnotated(newValue, typeName: $0)
                } ?? newValue
                try property.write(assigned, to: .native(value), in: self)
                return true
            }
            // A typed read-only descriptor can coexist with an explicit
            // compatibility setter during incremental gateway migration. Let
            // that setter win; otherwise retain HostProperty's precise
            // read-only diagnostic.
            if registry?.hostSetMember(name, on: value, to: newValue) == true {
                return true
            }
            try property.write(newValue, to: .native(value), in: self)
            return true
        }
        return registry?.hostSetMember(name, on: value, to: newValue) == true
    }

    /// Shape probe used while resolving lvalues. It intentionally avoids
    /// invoking a typed getter merely to discover writability.
    func hasHostMember(_ name: String, on value: Any) -> Bool {
        hasRuntimeAsyncStreamMember(name, on: value)
            || registry?.hostProperty(named: name, on: value) != nil
            || registry?.hostMember(name, on: value) != nil
    }
}
