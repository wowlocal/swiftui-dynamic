/// A user-struct instance. Deliberately class-backed even though the source
/// declares a struct: reference semantics are what let a Button action closure
/// mutate `self.count` and have the next `body` evaluation observe it, with no
/// copy machinery. Documented divergence from Swift value semantics.
public final class Instance: CustomStringConvertible {
    public let symbol: StructSymbol
    /// Plain stored properties. `@Binding` properties live here too, but their
    /// Box is shared with the parent's state box rather than owned.
    public var properties: [String: Box] = [:]
    /// `@State`-marked properties, kept separate so the SwiftUI bridge can swap
    /// in persisted boxes across instance recreations.
    public var stateBoxes: [String: Box] = [:]

    public init(symbol: StructSymbol) {
        self.symbol = symbol
    }

    public func box(for name: String) -> Box? {
        stateBoxes[name] ?? properties[name]
    }

    /// The box behind `$name` — an @State box or a shared @Binding box.
    public func projectedBox(for name: String) -> Box? {
        if let state = stateBoxes[name] { return state }
        if symbol.storedProperty(named: name)?.wrapper == .binding { return properties[name] }
        return nil
    }

    public var description: String {
        let props = symbol.storedProperties
            .compactMap { prop in box(for: prop.name).map { "\(prop.name): \($0.value.stringified)" } }
            .joined(separator: ", ")
        return "\(symbol.name)(\(props))"
    }
}
