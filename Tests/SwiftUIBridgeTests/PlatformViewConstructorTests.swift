import SwiftUI
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct PlatformViewConstructorTests {
    /// Native baseline: a UIKit bitmap can initialize a SwiftUI Image and the
    /// concrete Image value remains available to Image-typed transforms.
    /// The interpreter renders iOS source on a macOS host, so BridgeGen must
    /// retain that same semantic value through its target-overlay adapter.
    @Test func targetPlatformBitmapPreservesConcreteViewSemantics() throws {
        let overloads = GeneratedConstructors.table["Image"]?
            .byArity[1] ?? []
        #expect(overloads.contains {
            $0.params.map(\.label) == ["uiImage"]
                && $0.params.map(\.tag) == [
                    .platformSemanticValue("UIKit", "UIImage"),
                ]
        })

        let registry = ViewRegistry()
        let result = try Interpreter(registry: registry).run(source: """
        let bitmap = UIGraphicsImageRenderer(
            size: CGSize(width: 4, height: 4)
        ).image { _ in }

        Image(uiImage: bitmap).resizable()
        """)

        #expect(result.hostPayload is ImageBox)
        #expect(registry.isViewValue(result))
    }
}
