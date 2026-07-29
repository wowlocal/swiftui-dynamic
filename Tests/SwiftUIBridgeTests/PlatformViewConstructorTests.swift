import AppKit
import SwiftUI
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct PlatformViewConstructorTests {
    /// A same-platform generated initializer must not erase its concrete View
    /// before interface-declared, same-type members run. Both constructor and
    /// member are selected from generated metadata; no handwritten modifier
    /// participates.
    @Test func generatedViewRetainsConcreteMemberSurface() throws {
        let candidates = GeneratedConstructors.table["Image"]?
            .byArity[1] ?? []
        guard let constructor = candidates.first(where: {
            $0.params.map(\.label) == ["nsImage"]
        }) else {
            Issue.record("generated Image(nsImage:) is missing")
            return
        }

        let constructed = try constructor.invoke([
            NSImage(size: NSSize(width: 4, height: 4)),
        ])
        #expect(constructed is Image)

        guard let members = GeneratedMembers.methods["Image.resizable"],
              let resizable = members.overloads.first(where: {
                  $0.params.isEmpty
              }) else {
            Issue.record("generated Image.resizable() is missing")
            return
        }
        let resized = try resizable.invoke(constructed, [])
        #expect(resized.hostPayload is Image)
        #expect(ViewRegistry().modifiers["resizable"] == nil)
    }

    /// Once BridgeGen owns a concrete View member, a handwritten modifier
    /// with the same callable name would shadow the interface-derived table.
    /// Keep that identity-keyed drift mechanically impossible.
    @Test func generatedConcreteViewMembersHaveNoHandwrittenDuplicates() {
        let generatedNames = Set(
            GeneratedMembers.concreteViewMethodKeys.compactMap {
                $0.split(separator: ".").last.map(String.init)
            })
        let handwrittenNames = Set(ViewRegistry().modifiers.keys)

        #expect(!GeneratedMembers.concreteViewMethodKeys.isEmpty)
        #expect(generatedNames.isDisjoint(with: handwrittenNames))
    }

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

        #expect(result.hostPayload is Image)
        #expect(registry.isViewValue(result))
    }

    /// Nuke keeps its target-platform bitmap behind a nested reference
    /// container, projects it through `Optional.map`, and only then unwraps
    /// the resulting SwiftUI `Image` in a builder. The transferable platform
    /// value must retain pixels through that ownership shape.
    @MainActor
    @Test func targetPlatformBitmapRendersThroughNestedContainer() throws {
        let rendered = InterpreterHost().render(
            source: """
            typealias PlatformImage = UIImage

            struct ImageContainer {
                private final class Storage {
                    var image: PlatformImage

                    init(image: PlatformImage) {
                        self.image = image
                    }
                }

                private var storage: Storage

                var image: PlatformImage {
                    get { storage.image }
                    set { storage.image = newValue }
                }

                init(image: PlatformImage) {
                    storage = Storage(image: image)
                }
            }

            protocol ImageState {
                var imageContainer: ImageContainer? { get }
            }

            extension ImageState {
                var image: Image? {
                    imageContainer.map { Image(uiImage: $0.image) }
                }
            }

            struct State: ImageState {
                let imageContainer: ImageContainer?
            }

            struct BitmapView: View {
                var body: some View {
                    let bitmap = UIGraphicsImageRenderer(
                        size: CGSize(width: 8, height: 8)
                    ).image { _ in }
                    let state = State(
                        imageContainer: ImageContainer(image: bitmap)
                    )
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .overlay(.black.opacity(0.50))
                            .frame(width: 40, height: 40)
                            .clipped()
                    }
                }
            }
            """,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("nested platform bitmap failed to render: \(rendered)")
            return
        }

        let bitmap = Self.bitmap(view, size: NSSize(width: 80, height: 80))
        var redPixels = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.redComponent > 0.3,
                   color.greenComponent < 0.2,
                   color.blueComponent < 0.2 {
                    redPixels += 1
                }
            }
        }
        #expect(redPixels >= 1_500)
    }

    @MainActor
    private static func bitmap(
        _ view: AnyView, size: NSSize
    ) -> NSBitmapImageRep {
        let hosting = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .background(Color.white))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(
            in: hosting.bounds
        ) else {
            fatalError("could not allocate bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}
