import Foundation
import SwiftInterpreter

/// Execute one generated C function whose result is a pointer relative to its
/// first read-only memory argument. The host call sees a scoped Data copy;
/// only its byte offset survives, translated back into the retained source
/// cursor. This is shared by every declaration selected from SDK metadata.
@MainActor
func generatedCRelativePointerFunction(
    memory: RuntimeValue?,
    scalar: RuntimeValue?,
    count: RuntimeValue?,
    invoke: (UnsafeRawPointer, Int32, Int) -> UnsafeMutableRawPointer?
) throws -> RuntimeValue {
    guard let memory = memory?.unwrappedOptionalOrSelf,
          case .host(let payload) = memory,
          let cursor = payload as? any HostRawMemoryCursor,
          let scalar = scalar?.intValue,
          let count = count?.intValue else {
        throw RuntimeError(message:
            "generated C relative-pointer function needs memory, scalar, and count")
    }
    guard count >= 0, count <= cursor.rawMemoryCount else {
        throw RuntimeError(message:
            "generated C read count \(count) exceeds \(cursor.rawMemoryCount) bytes")
    }
    guard count > 0 else {
        return .none(wrappedTypeName: "UnsafeMutableRawPointer")
    }
    let bytes = try cursor.readBytes(count: count)
    return try bytes.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress,
              let result = invoke(base, Int32(truncatingIfNeeded: scalar), count)
        else {
            return .none(wrappedTypeName: "UnsafeMutableRawPointer")
        }
        let offset = Int(bitPattern: result) - Int(bitPattern: base)
        guard offset >= 0, offset < count else {
            throw RuntimeError(message:
                "generated C function returned a pointer outside its input memory")
        }
        let retained = try cursor.advancedRawMemory(byByteOffset: offset)
        return .some(
            .native(retained as Any),
            wrappedTypeName: "UnsafeMutableRawPointer")
    }
}
