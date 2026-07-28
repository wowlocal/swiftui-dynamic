/// The only thing the host and a compiled boundary shim must agree on.
///
/// Both sides link this module dynamically, so a shim can hand native Swift
/// values back and forth as `Any` with NO serialization: reference types,
/// opaque SDK values and structs all cross by identity, not by copy.
public final class BoundaryCall {
    public var receiver: Any?
    public var arguments: [Any]
    public var result: Any?
    public var failure: String?

    public init(receiver: Any?, arguments: [Any]) {
        self.receiver = receiver
        self.arguments = arguments
        self.result = nil
        self.failure = nil
    }
}

/// C entry point every emitted shim exposes.
public typealias BoundaryEntry =
    @convention(c) (UnsafeMutableRawPointer) -> Void
