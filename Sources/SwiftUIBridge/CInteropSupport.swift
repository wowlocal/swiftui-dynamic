import Foundation
import SwiftInterpreter

/// Writable value-semantic carrier for a C record constructor discovered in
/// the active Darwin SDK symbol graph. Generated C functions fill `members`;
/// ordinary host-member dispatch then exposes those fields to interpreted
/// source without teaching the runtime any record or function identities.
final class GeneratedCRecordValue: InertCallable, HostValueSemantic {
    let typeName: String
    var members: [String: RuntimeValue]

    init(
        typeName: String,
        members: [String: RuntimeValue] = [:]
    ) {
        self.typeName = typeName
        self.members = members
    }

    func copiedHostValue() -> Any {
        GeneratedCRecordValue(
            typeName: typeName,
            members: members.mapValues { $0.copiedForValueSemantics() })
    }
}

/// Decode a fixed CChar tuple without reading past its metadata-provided
/// bound. Generated adapters use this for record fields selected solely by
/// their all-CChar tuple shape.
func generatedCCharacterBuffer<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { bytes in
        String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
