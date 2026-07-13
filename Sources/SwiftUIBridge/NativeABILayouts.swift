import Darwin
import SwiftInterpreter

extension ViewRegistry {
    /// Darwin C records are imported by the host compiler rather than parsed
    /// as source structs. Keep their layout behind HostRegistry so
    /// MemoryLayout reads use this SDK/architecture's compiled ABI metadata.
    public func hostABILayout(
        ofTypeNamed rawName: String
    ) -> RuntimeABILayout? {
        darwinABILayout(ofTypeNamed: rawName)
    }
}

extension TraceRegistry {
    public func hostABILayout(
        ofTypeNamed rawName: String
    ) -> RuntimeABILayout? {
        darwinABILayout(ofTypeNamed: rawName)
    }
}

private func darwinABILayout(
    ofTypeNamed rawName: String
) -> RuntimeABILayout? {
    let name = rawName
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "Darwin.", with: "")
    switch name {
    case "sockaddr": return nativeABILayout(sockaddr.self)
    case "sockaddr_in": return nativeABILayout(sockaddr_in.self)
    case "sockaddr_in6": return nativeABILayout(sockaddr_in6.self)
    case "sockaddr_storage": return nativeABILayout(sockaddr_storage.self)
    case "sockaddr_un": return nativeABILayout(sockaddr_un.self)
    case "in_addr": return nativeABILayout(in_addr.self)
    case "in6_addr": return nativeABILayout(in6_addr.self)
    case "timeval": return nativeABILayout(timeval.self)
    case "sa_family_t": return nativeABILayout(sa_family_t.self)
    case "in_port_t": return nativeABILayout(in_port_t.self)
    default: return nil
    }
}

private func nativeABILayout<T>(_: T.Type) -> RuntimeABILayout {
    RuntimeABILayout(
        size: MemoryLayout<T>.size,
        stride: MemoryLayout<T>.stride,
        alignment: MemoryLayout<T>.alignment)
}
