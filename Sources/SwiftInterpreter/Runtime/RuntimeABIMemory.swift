import Foundation

/// A retained host-memory region. Framework bridges use this instead of
/// leaking an `UnsafePointer` into `RuntimeValue`: the owner remains alive and
/// Foundation gateways can copy bytes without knowing the originating SDK.
public protocol HostRawMemory: AnyObject {
    func readBytes(count: Int) throws -> Data
    func writeBytes(_ data: Data, count: Int) throws
}

public struct RuntimeABILayout: Equatable, Sendable {
    public let size: Int
    public let stride: Int
    public let alignment: Int

    public init(size: Int, stride: Int, alignment: Int) {
        self.size = size
        self.stride = stride
        self.alignment = alignment
    }
}

/// Native-layout serialization for interpreted values crossing an unsafe
/// byte boundary. This is intentionally small and strict: fixed-width scalar
/// fields and recursively represented source structs are laid out exactly;
/// reference, resilient, wrapped, and otherwise unknowable representations
/// are rejected instead of guessed.
@MainActor
public enum RuntimeABIMemory {
    public static func layout(of value: RuntimeValue) throws -> RuntimeABILayout {
        switch value {
        case .instance(let instance):
            return try layout(of: instance)
        case .int:
            return nativeLayout(Int.self)
        case .double:
            return nativeLayout(Double.self)
        case .bool:
            return nativeLayout(Bool.self)
        case .host(let value):
            if value is UInt64 { return nativeLayout(UInt64.self) }
            if let data = value as? Data {
                return RuntimeABILayout(size: data.count, stride: data.count, alignment: 1)
            }
            throw unsupported("host value '\(type(of: value))'")
        default:
            throw unsupported("'\(value.stringified)'")
        }
    }

    public static func data(from value: RuntimeValue) throws -> Data {
        switch value {
        case .instance(let instance):
            return try encode(instance)
        case .int(let value):
            return bytes(of: value)
        case .double(let value):
            return bytes(of: value)
        case .bool(let value):
            return bytes(of: value)
        case .host(let value):
            if let data = value as? Data { return data }
            if let value = value as? UInt64 { return bytes(of: value) }
            throw unsupported("host value '\(type(of: value))'")
        default:
            throw unsupported("'\(value.stringified)'")
        }
    }

    static func layout(of instance: Instance) throws -> RuntimeABILayout {
        guard !instance.symbol.isClass else {
            throw unsupported("class '\(instance.symbol.name)'")
        }
        var offset = 0
        var maximumAlignment = 1
        for property in instance.symbol.storedProperties {
            guard property.wrapper == .none,
                  let typeName = property.typeAnnotation?.trimmedDescription,
                  let field = instance.box(for: property.name)?.value else {
                throw unsupported("property '\(instance.symbol.name).\(property.name)'")
            }
            let fieldLayout = try layout(typeName: typeName, value: field)
            offset = aligned(offset, to: fieldLayout.alignment)
            offset += fieldLayout.size
            maximumAlignment = max(maximumAlignment, fieldLayout.alignment)
        }
        return RuntimeABILayout(
            size: offset,
            stride: aligned(offset, to: maximumAlignment),
            alignment: maximumAlignment)
    }

    static func layout(typeName rawName: String, value: RuntimeValue?) throws -> RuntimeABILayout {
        let name = canonicalTypeName(rawName)
        if let layout = scalarLayout(name) { return layout }
        if case .instance(let nested)? = value { return try layout(of: nested) }
        throw unsupported("type '\(rawName)'")
    }

    static func scalarLayout(_ name: String) -> RuntimeABILayout? {
        switch name {
        case "Bool": return nativeLayout(Bool.self)
        case "Int": return nativeLayout(Int.self)
        case "Int8": return nativeLayout(Int8.self)
        case "Int16": return nativeLayout(Int16.self)
        case "Int32": return nativeLayout(Int32.self)
        case "Int64": return nativeLayout(Int64.self)
        case "UInt": return nativeLayout(UInt.self)
        case "UInt8": return nativeLayout(UInt8.self)
        case "UInt16": return nativeLayout(UInt16.self)
        case "UInt32": return nativeLayout(UInt32.self)
        case "UInt64": return nativeLayout(UInt64.self)
        case "Float": return nativeLayout(Float.self)
        case "Double": return nativeLayout(Double.self)
        case "CGFloat": return nativeLayout(CGFloat.self)
        default: return nil
        }
    }

    private static func encode(_ instance: Instance) throws -> Data {
        let layout = try layout(of: instance)
        var result = Data()
        result.reserveCapacity(layout.stride)
        for property in instance.symbol.storedProperties {
            guard property.wrapper == .none,
                  let typeName = property.typeAnnotation?.trimmedDescription,
                  let field = instance.box(for: property.name)?.value else {
                throw unsupported("property '\(instance.symbol.name).\(property.name)'")
            }
            let fieldLayout = try self.layout(typeName: typeName, value: field)
            appendZeros(to: &result, until: aligned(result.count, to: fieldLayout.alignment))
            let encoded = try encodeScalarOrStruct(field, typeName: typeName)
            guard encoded.count == fieldLayout.size else {
                throw RuntimeError(message:
                    "ABI encoding for '\(instance.symbol.name).\(property.name)' produced "
                    + "\(encoded.count) bytes; expected \(fieldLayout.size)")
            }
            result.append(encoded)
        }
        appendZeros(to: &result, until: layout.stride)
        return result
    }

    private static func encodeScalarOrStruct(
        _ value: RuntimeValue, typeName rawName: String
    ) throws -> Data {
        let name = canonicalTypeName(rawName)
        if case .instance(let nested) = value { return try encode(nested) }
        switch name {
        case "Bool": return bytes(of: value.boolValue ?? false)
        case "Int": return bytes(of: value.intValue ?? 0)
        case "Int8": return bytes(of: Int8(truncatingIfNeeded: value.intValue ?? 0))
        case "Int16": return bytes(of: Int16(truncatingIfNeeded: value.intValue ?? 0))
        case "Int32": return bytes(of: Int32(truncatingIfNeeded: value.intValue ?? 0))
        case "Int64": return bytes(of: Int64(value.intValue ?? 0))
        case "UInt": return bytes(of: UInt(truncatingIfNeeded: value.intValue ?? 0))
        case "UInt8": return bytes(of: UInt8(truncatingIfNeeded: value.intValue ?? 0))
        case "UInt16": return bytes(of: UInt16(truncatingIfNeeded: value.intValue ?? 0))
        case "UInt32": return bytes(of: UInt32(truncatingIfNeeded: value.intValue ?? 0))
        case "UInt64":
            if case .host(let host) = value, let exact = host as? UInt64 {
                return bytes(of: exact)
            }
            return bytes(of: UInt64(truncatingIfNeeded: value.intValue ?? 0))
        case "Float": return bytes(of: Float(value.doubleValue ?? 0))
        case "Double": return bytes(of: value.doubleValue ?? 0)
        case "CGFloat": return bytes(of: CGFloat(value.doubleValue ?? 0))
        default: throw unsupported("type '\(rawName)'")
        }
    }

    private static func canonicalTypeName(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Swift.", "Foundation.", "CoreGraphics."] {
            name = name.replacingOccurrences(of: prefix, with: "")
        }
        return name
    }

    private static func nativeLayout<T>(_ type: T.Type) -> RuntimeABILayout {
        RuntimeABILayout(
            size: MemoryLayout<T>.size,
            stride: MemoryLayout<T>.stride,
            alignment: MemoryLayout<T>.alignment)
    }

    private static func bytes<T>(of value: T) -> Data {
        var copy = value
        return withUnsafeBytes(of: &copy) { Data($0) }
    }

    private static func aligned(_ offset: Int, to alignment: Int) -> Int {
        guard alignment > 1 else { return offset }
        return (offset + alignment - 1) & ~(alignment - 1)
    }

    private static func appendZeros(to data: inout Data, until count: Int) {
        if data.count < count {
            data.append(Data(repeating: 0, count: count - data.count))
        }
    }

    private static func unsupported(_ description: String) -> RuntimeError {
        RuntimeError(message: "cannot derive a stable native ABI layout for \(description)")
    }
}

extension Interpreter {
    func runtimeABILayout(typeName rawName: String) throws -> RuntimeABILayout {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scalar = RuntimeABIMemory.scalarLayout(name) { return scalar }
        guard case .type(let symbol)? = typeValue(named: name), !symbol.isClass else {
            throw RuntimeError(message:
                "cannot derive a stable native ABI layout for type '\(rawName)'")
        }
        var offset = 0
        var maximumAlignment = 1
        for property in symbol.storedProperties {
            guard property.wrapper == .none,
                  let fieldName = property.typeAnnotation?.trimmedDescription else {
                throw RuntimeError(message:
                    "cannot derive ABI layout for '\(symbol.name).\(property.name)'")
            }
            let field = try runtimeABILayout(typeName: fieldName)
            offset = (offset + field.alignment - 1) & ~(field.alignment - 1)
            offset += field.size
            maximumAlignment = max(maximumAlignment, field.alignment)
        }
        let stride = (offset + maximumAlignment - 1) & ~(maximumAlignment - 1)
        return RuntimeABILayout(
            size: offset, stride: stride, alignment: maximumAlignment)
    }
}
