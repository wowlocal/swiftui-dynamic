extension Interpreter {
    /// One funnel for typed and legacy host-member reads. Parsed properties
    /// win; the dynamic hook remains the migration fallback.
    func readHostMember(
        _ name: String, on value: Any
    ) throws -> RuntimeValue? {
        if let property = registry?.hostProperty(named: name, on: value) {
            return try property.read(from: .native(value), in: self)
        }
        return registry?.hostMember(name, on: value)
    }

    /// Setter counterpart to `readHostMember`. A typed descriptor validates
    /// the assigned value before framework code sees it.
    func writeHostMember(
        _ name: String, on value: Any, to newValue: RuntimeValue
    ) throws -> Bool {
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
        registry?.hostProperty(named: name, on: value) != nil
            || registry?.hostMember(name, on: value) != nil
    }
}
