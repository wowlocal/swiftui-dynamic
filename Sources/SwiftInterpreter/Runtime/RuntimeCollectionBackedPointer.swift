import Foundation

/// Property-based native indexing used by the evaluator's reusable subscript
/// dispatch. Carriers conform here instead of growing one handwritten
/// `subscript` member case per runtime type.
@MainActor
protocol RuntimeIntegerSubscriptReadable: AnyObject {
    /// Static element spelling retained by the carrier. Runtime scalars erase
    /// fixed-width integer identity, so downstream source-extension dispatch
    /// uses this provenance instead of guessing from the boxed payload.
    var runtimeElementTypeName: String? { get }
    func runtimeElement(at index: Int) throws -> RuntimeValue
}

/// Shared immutable storage for a read-only interpreted buffer. Source-level
/// arrays erase fixed-width integer spelling in `RuntimeValue`; the declared
/// element type restores its ABI stride and byte encoding at this one unsafe
/// boundary. A stable virtual address supports pointer-distance arithmetic
/// without exposing an interpreter or temporary host allocation.
@MainActor
fileprivate final class RuntimeCollectionBackedStorage: @unchecked Sendable {
    private static var nextVirtualAddress: UInt = 0x1000_0000

    let elements: [RuntimeValue]
    let elementTypeName: String?
    let elementStride: Int
    let rawBytes: Data?
    let virtualBaseAddress: UInt

    init(elements: [RuntimeValue], elementTypeName: String?) {
        self.elements = elements
        self.elementTypeName = elementTypeName

        var bytes = Data()
        var stride: Int?
        var encodingFailed = false
        for element in elements {
            guard let encoded = try? RuntimeABIMemory.encodedElement(
                element, typeName: elementTypeName),
                  stride == nil || stride == encoded.layout.stride else {
                encodingFailed = true
                break
            }
            stride = encoded.layout.stride
            bytes.append(encoded.data)
        }
        if stride == nil, let elementTypeName {
            stride = RuntimeABIMemory.scalarLayout(
                RuntimeABIMemory.canonicalTypeName(elementTypeName))?.stride
        }
        if stride == nil, let first = elements.first {
            stride = (try? RuntimeABIMemory.layout(of: first))?.stride
        }
        elementStride = max(1, stride ?? 1)
        rawBytes = encodingFailed ? nil : bytes

        virtualBaseAddress = Self.nextVirtualAddress
        let byteCapacity = max(1, elements.count * elementStride)
        let allocation = UInt(max(4_096, (byteCapacity + 4_095) & ~4_095))
        Self.nextVirtualAddress &+= allocation
    }
}

/// Read-only unsafe-buffer capability backed by interpreter-owned values.
/// Buffer construction preserves this carrier instead of flattening it to an
/// array, so a stored `UnsafeBufferPointer` retains both its values and its
/// scoped pointer semantics after the creating closure returns.
@MainActor
final class RuntimeCollectionBackedBuffer:
    RuntimeIntegerSubscriptReadable, @unchecked Sendable
{
    private let storage: RuntimeCollectionBackedStorage
    private let elementRange: Range<Int>

    init(_ elements: [RuntimeValue], elementTypeName: String? = nil) {
        let storage = RuntimeCollectionBackedStorage(
            elements: elements, elementTypeName: elementTypeName)
        self.storage = storage
        elementRange = elements.indices
    }

    fileprivate init(
        storage: RuntimeCollectionBackedStorage,
        elementRange: Range<Int>
    ) {
        self.storage = storage
        self.elementRange = elementRange
    }

    var elements: [RuntimeValue] {
        Array(storage.elements[elementRange])
    }

    var elementTypeName: String? { storage.elementTypeName }
    var runtimeElementTypeName: String? { elementTypeName }

    func runtimeElement(at index: Int) throws -> RuntimeValue {
        guard index >= 0, index < elementRange.count else {
            throw EvalMessage(text: "buffer index out of range")
        }
        return storage.elements[elementRange.lowerBound + index]
    }

    var baseAddress: RuntimeCollectionBackedPointer? {
        guard !elementRange.isEmpty else { return nil }
        return RuntimeCollectionBackedPointer(
            storage: storage,
            byteOffset: elementRange.lowerBound * storage.elementStride,
            advanceStride: storage.elementStride)
    }

    func prefix(_ count: Int) -> RuntimeCollectionBackedBuffer {
        let end = min(elementRange.upperBound,
                      elementRange.lowerBound + max(0, count))
        return RuntimeCollectionBackedBuffer(
            storage: storage,
            elementRange: elementRange.lowerBound..<end)
    }
}

/// Address-like cursor into immutable collection storage. Typed cursors advance
/// by the source element stride; raw views advance by bytes. The address token
/// and `HostRawMemoryCursor` conformance let generated C adapters translate
/// native pointer results back into retained interpreter cursors by offset.
@MainActor
final class RuntimeCollectionBackedPointer: HostRawMemoryCursor,
    RuntimeIntegerSubscriptReadable, @unchecked Sendable
{
    private let storage: RuntimeCollectionBackedStorage
    let byteOffset: Int
    private let advanceStride: Int

    fileprivate init(
        storage: RuntimeCollectionBackedStorage,
        byteOffset: Int,
        advanceStride: Int
    ) {
        self.storage = storage
        self.byteOffset = max(
            0, min(byteOffset, storage.elements.count * storage.elementStride))
        self.advanceStride = max(1, advanceStride)
    }

    convenience init(
        elements: [RuntimeValue],
        elementTypeName: String? = nil,
        offset: Int = 0
    ) {
        let storage = RuntimeCollectionBackedStorage(
            elements: elements, elementTypeName: elementTypeName)
        self.init(
            storage: storage,
            byteOffset: offset * storage.elementStride,
            advanceStride: storage.elementStride)
    }

    var rawMemoryAddress: UInt {
        storage.virtualBaseAddress &+ UInt(byteOffset)
    }

    var runtimeElementTypeName: String? { storage.elementTypeName }

    var rawMemoryCount: Int {
        max(0, storage.elements.count * storage.elementStride - byteOffset)
    }

    func advanced(by distance: Int) -> RuntimeCollectionBackedPointer {
        RuntimeCollectionBackedPointer(
            storage: storage,
            byteOffset: byteOffset + distance * advanceStride,
            advanceStride: advanceStride)
    }

    func rawView() -> RuntimeCollectionBackedPointer {
        RuntimeCollectionBackedPointer(
            storage: storage,
            byteOffset: byteOffset,
            advanceStride: 1)
    }

    func element(atRelativeIndex index: Int) throws -> RuntimeValue {
        let targetByteOffset = byteOffset + index * advanceStride
        guard targetByteOffset >= 0,
              targetByteOffset % storage.elementStride == 0 else {
            throw EvalMessage(text: "pointer is not aligned to an element")
        }
        let position = targetByteOffset / storage.elementStride
        guard storage.elements.indices.contains(position) else {
            throw EvalMessage(text: "pointer index out of range")
        }
        return storage.elements[position]
    }

    func runtimeElement(at index: Int) throws -> RuntimeValue {
        try element(atRelativeIndex: index)
    }

    func window(count: Int) throws -> RuntimeCollectionBackedBuffer {
        guard byteOffset % storage.elementStride == 0 else {
            throw EvalMessage(text: "buffer start is not element-aligned")
        }
        let start = byteOffset / storage.elementStride
        let available = max(0, storage.elements.count - start)
        let boundedCount = min(max(0, count), available)
        return RuntimeCollectionBackedBuffer(
            storage: storage,
            elementRange: start..<(start + boundedCount))
    }

    func loadedValue(typeName: String) throws -> RuntimeValue {
        let layout = try RuntimeABIMemory.layout(
            typeName: typeName, value: nil)
        return try RuntimeABIMemory.value(
            from: readBytes(count: layout.size), typeName: typeName)
    }

    func readBytes(count: Int) throws -> Data {
        guard count >= 0 else {
            throw RuntimeError(message: "raw-memory read count cannot be negative")
        }
        guard count <= rawMemoryCount else {
            throw RuntimeError(message:
                "raw-memory read count \(count) exceeds \(rawMemoryCount) remaining bytes")
        }
        guard let rawBytes = storage.rawBytes else {
            throw RuntimeError(message:
                "collection element ABI is unavailable for raw-memory access")
        }
        return rawBytes.subdata(in: byteOffset..<(byteOffset + count))
    }

    func writeBytes(_ data: Data, count: Int) throws {
        throw RuntimeError(message: "collection-backed raw memory is read-only")
    }

    func advancedRawMemory(byByteOffset offset: Int) throws
        -> any HostRawMemoryCursor
    {
        guard offset >= 0, offset <= rawMemoryCount else {
            throw RuntimeError(message:
                "raw pointer offset \(offset) exceeds \(rawMemoryCount) remaining bytes")
        }
        return RuntimeCollectionBackedPointer(
            storage: storage,
            byteOffset: byteOffset + offset,
            advanceStride: 1)
    }
}
