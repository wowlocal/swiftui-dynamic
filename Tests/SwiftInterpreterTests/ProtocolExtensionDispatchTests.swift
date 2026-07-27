import CoreGraphics
import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct ProtocolExtensionDispatchTests {
    /// A contextual protocol existential can name a static factory supplied
    /// by a same-type-constrained protocol extension. The constraint proves
    /// the concrete `Self` used to execute the factory.
    @Test func contextualFactoryUsesConstrainedConcreteSelf() throws {
        let source = """
        protocol Processor {
            func process(_ value: Int) -> Int
        }

        struct OffsetProcessor: Processor {
            let amount: Int

            func process(_ value: Int) -> Int {
                value + amount
            }
        }

        extension Processor where Self == OffsetProcessor {
            static func offset(_ amount: Int) -> OffsetProcessor {
                OffsetProcessor(amount: amount)
            }
        }

        let processors: [any Processor] = [.offset(3)]
        processors[0].process(4)
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 7)
    }

    /// A protocol default can adapt a container requirement to a concrete
    /// conformer's same-named scalar requirement. Calls through an existential
    /// must retain the concrete witness while the default body executes.
    @Test func existentialDefaultCallsConcreteOverloadedWitness() throws {
        let source = """
        struct Container {
            var value: Int
        }

        enum ProcessingError: Error {
            case failed
        }

        protocol Processing {
            func process(_ value: Int) -> Int?
            func process(
                _ container: Container, context: Int
            ) throws -> Container
        }

        extension Processing {
            func process(
                _ container: Container, context: Int
            ) throws -> Container {
                guard let output = process(container.value) else {
                    throw ProcessingError.failed
                }
                var container = container
                container.value = output
                return container
            }
        }

        struct Offset: Processing {
            func process(_ value: Int) -> Int? {
                value + 3
            }
        }

        let processors: [any Processing] = [Offset()]
        try processors[0].process(
            Container(value: 4), context: 0
        ).value
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 7)
    }

    @Test func asyncExistentialDefaultCallsConcreteOverloadedWitness() async throws {
        let source = """
        struct Container {
            var value: Int
        }

        enum ProcessingError: Error {
            case failed
        }

        protocol Processing {
            func process(_ value: Int) async -> Int?
            func process(
                _ container: Container, context: Int
            ) async throws -> Container
        }

        extension Processing {
            func process(
                _ container: Container, context: Int
            ) async throws -> Container {
                guard let output = await process(container.value) else {
                    throw ProcessingError.failed
                }
                var container = container
                container.value = output
                return container
            }
        }

        struct Offset: Processing {
            func process(_ value: Int) async -> Int? {
                value + 3
            }
        }

        let processors: [any Processing] = [Offset()]
        try await processors[0].process(
            Container(value: 4), context: 0
        ).value
        """

        let value = try await Interpreter().runAsync(source: source)
        #expect(value.intValue == 7)
    }

    /// A nested source initializer converted to a callback keeps its exact
    /// nominal target and adapts the initializer's argument labels to the
    /// unlabeled function value. A same-spelled host constructor must not
    /// capture the callback when it escapes through stored registry state.
    @Test func escapedNestedInitializerReferenceKeepsSourceNominal() throws {
        let source = """
        struct DecodeContext {
            let marker: Int
        }

        protocol Decoding {
            var marker: Int { get }
        }

        enum Decoders {
            final class Default: Decoding {
                let marker: Int

                init?(context: DecodeContext) {
                    self.marker = context.marker
                }
            }
        }

        final class DecoderRegistry {
            private var factories =
                [(DecodeContext) -> (any Decoding)?]()

            init() {
                register(Decoders.Default.init)
            }

            func register(
                _ factory: @escaping
                    (DecodeContext) -> (any Decoding)?
            ) {
                factories.append(factory)
            }

            func decoder(
                for context: DecodeContext
            ) -> (any Decoding)? {
                for factory in factories.reversed() {
                    if let decoder = factory(context) {
                        return decoder
                    }
                }
                return nil
            }
        }

        DecoderRegistry()
            .decoder(for: DecodeContext(marker: 7))!
            .marker
        """

        let value = try Interpreter(registry: TraceRegistry())
            .run(source: source)
        #expect(value.intValue == 7)
    }

    /// A source alias and its extension commonly live in different files of
    /// one package target. An existential default can call a concrete overload
    /// that returns a decoded semantic carrier through another extension
    /// method; its generated raster property must survive every boundary.
    @Test func decodedRasterDispatchesCrossFileTypeAliasExtension() throws {
        let alias = ProjectMaterial.mergedSource(
            source: """
            import UIKit
            typealias PlatformImage = UIImage
            """,
            moduleName: "ImagePipeline")
        let imageExtensions = ProjectMaterial.mergedSource(
            source: """
            import UIKit

            extension CGSize {
                func rotatedForOrientation(
                    _ orientation: UIImage.Orientation
                ) -> CGSize {
                    recorder.orientationCalls += 1
                    switch orientation {
                    case .left, .leftMirrored, .right, .rightMirrored:
                        return CGSize(width: height, height: width)
                    case .up, .upMirrored, .down, .downMirrored:
                        return self
                    @unknown default:
                        return self
                    }
                }
            }

            struct ImageProcessingExtensions {
                let image: PlatformImage

                var pixelWidth: Int { 8 }

                func byResizing(to targetSize: CGSize) -> PlatformImage? {
                    recorder.resizeCalls += 1
                    guard image.cgImage != nil else {
                        return nil
                    }
                    recorder.imagePropertyCalls += 1
                    let targetSize = targetSize.rotatedForOrientation(
                        image.imageOrientation)
                    guard targetSize.width == 8 else {
                        return nil
                    }
                    return image
                }
            }

            extension PlatformImage {
                var processed: ImageProcessingExtensions {
                    ImageProcessingExtensions(image: self)
                }
            }

            final class Recorder {
                var witnessCalls = 0
                var resizeCalls = 0
                var imagePropertyCalls = 0
                var directImagePropertyCalls = 0
                var orientationCalls = 0
            }

            let recorder = Recorder()
            """,
            moduleName: "ImagePipeline")
        let pipeline = ProjectMaterial.mergedSource(
            source: """
            import UIKit

            struct Container {
                private final class Storage {
                    var image: PlatformImage

                    init(image: PlatformImage) {
                        self.image = image
                    }
                }

                private var storage: Storage

                var image: UIImage {
                    get { storage.image }
                    set { storage.image = newValue }
                }

                init(image: PlatformImage) {
                    self.storage = Storage(image: image)
                }
            }

            protocol Processing {
                func process(_ image: PlatformImage) -> PlatformImage?
                func process(
                    _ container: Container, context: Int
                ) throws -> Container
            }

            extension Processing {
                func process(
                    _ container: Container, context: Int
                ) throws -> Container {
                    guard let output = process(container.image) else {
                        throw ProcessingError.failed
                    }
                    var container = container
                    container.image = output
                    return container
                }
            }

            enum ProcessingError: Error {
                case failed
            }

            struct Resize: Processing {
                func process(_ image: PlatformImage) -> PlatformImage? {
                    recorder.witnessCalls += 1
                    return image.processed.byResizing(
                        to: CGSize(width: 8, height: 8))
                }
            }

            func enqueue(_ operation: @escaping () -> Void) {
                operation()
            }

            final class Loader {
                var output = -1

                func start(_ processor: any Processing) {
                    enqueue { [weak self] in
                        guard let self else { return }
                        let bitmap = UIImage(
                            data: bitmapFixture, scale: 1)!
                        if bitmap.cgImage != nil {
                            recorder.directImagePropertyCalls += 1
                        }
                        let result = Result {
                            try processor.process(
                                Container(image: bitmap), context: 0
                            )
                        }
                        switch result {
                        case .success(let value):
                            output = value.image.processed.pixelWidth
                        case .failure:
                            output = -2
                        }
                    }
                }
            }

            let loader = Loader()
            loader.start(Resize())
            (
                loader.output,
                recorder.witnessCalls,
                recorder.resizeCalls,
                recorder.imagePropertyCalls,
                recorder.directImagePropertyCalls,
                recorder.orientationCalls
            )
            """,
            moduleName: "ImagePipeline")

        let decoded = try #require(
            UIImageBox.decoding(NetworkBridge.placeholderPNG))
        #expect(
            GeneratedPlatformBridge.property(
                "cgImage", onSemanticCarrier: decoded) != nil)
        #expect(
            TraceRegistry().hostProperty(
                named: "cgImage", on: decoded) != nil)

        let interpreter = Interpreter(registry: TraceRegistry())
        interpreter.globals.define(
            "bitmapFixture", .native(NetworkBridge.placeholderPNG))
        let value = try interpreter.run(
            source: alias + imageExtensions + pipeline)
        let tuple = try #require(value.tupleValue)
        #expect(tuple.values[0].intValue == 8)
        #expect(tuple.values[1].intValue == 1)
        #expect(tuple.values[2].intValue == 1)
        #expect(tuple.values[3].intValue == 1)
        #expect(tuple.values[4].intValue == 1)
        #expect(tuple.values[5].intValue == 1)
    }

    /// A generated SDK Optional can unwrap to one imported reference whose
    /// source computed property returns a direct SDK value. The direct value
    /// must retain its interface nominal so source-extension methods chained
    /// directly from that property keep dispatching. IceCubes' image pipeline
    /// surfaces this as `cgImage.size.scaled(by:).rounded()`.
    @Test func generatedDirectValueDispatchesChainedSourceExtensions() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let nativeContext = try #require(CGContext(
            data: nil,
            width: 3,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let nativeImage = try #require(nativeContext.makeImage())
        let nativeResult = CGSize(
            width: CGFloat(nativeImage.width),
            height: CGFloat(nativeImage.height))
        let expected = "\(Int(round(nativeResult.width * 0.5)))x"
            + "\(Int(round(nativeResult.height * 0.5)))"

        let source = """
        import CoreGraphics

        extension CGImage {
            var rasterSize: CGSize {
                CGSize(width: width, height: height)
            }
        }

        extension CGSize {
            func scaled(by scale: CGFloat) -> CGSize {
                CGSize(width: width * scale, height: height * scale)
            }

            func rounded() -> CGSize {
                CGSize(
                    width: CGFloat(round(width)),
                    height: CGFloat(round(height)))
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 3,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            fatalError("bitmap creation failed")
        }
        let size = image.rasterSize.scaled(by: 0.5).rounded()
        "\\(Int(size.width))x\\(Int(size.height))"
        """

        for registry: any HostRegistry in [ViewRegistry(), TraceRegistry()] {
            let value = try Interpreter(registry: registry).run(source: source)
            #expect(value.stringValue == expected)
        }
    }

    /// Once a direct SDK value enters a source extension, operators declared
    /// on that same host-type extension must dispatch from the receiver's
    /// runtime nominal even when the expression itself is unannotated.
    /// Gifski surfaces this as a `CGSize` aspect-fit helper whose body uses
    /// its source-declared `CGSize * Double` operator.
    @Test func directHostExtensionMethodUsesDeclaredStaticOperator() throws {
        let nativeInput = CGSize(width: 3, height: 2)
        let nativeResult = CGSize(
            width: nativeInput.width * 2,
            height: nativeInput.height * 2)
        let expected = "\(Int(nativeResult.width))x\(Int(nativeResult.height))"

        let source = """
        import CoreGraphics

        extension CGSize {
            static func * (lhs: Self, rhs: Double) -> Self {
                Self(width: lhs.width * rhs, height: lhs.height * rhs)
            }

            func scaledByDeclaredOperator(_ factor: Double) -> Self {
                self * factor
            }
        }

        let result = CGSize(width: 3, height: 2)
            .scaledByDeclaredOperator(2)
        "\\(Int(result.width))x\\(Int(result.height))"
        """

        for registry: any HostRegistry in [ViewRegistry(), TraceRegistry()] {
            let value = try Interpreter(registry: registry).run(source: source)
            #expect(value.stringValue == expected)
        }
    }

    /// Unknown reads on an opaque imported carrier are fallback capabilities,
    /// not statically declared members. Otherwise implicit-self lookup inside
    /// a host extension consumes a same-module helper type before lexical
    /// lookup can resolve it.
    @Test func opaqueHostExtensionBodyPrefersLexicalHelperType() throws {
        let helper = ProjectMaterial.mergedSource(
            source: """
            import UIKit

            struct ImageProcessingExtensions {
                let image: UIImage
                var pixelWidth: Int { 8 }
            }
            """,
            moduleName: "ImagePipeline")
        let imageExtension = ProjectMaterial.mergedSource(
            source: """
            import UIKit

            extension UIImage {
                var processed: ImageProcessingExtensions {
                    ImageProcessingExtensions(image: self)
                }
            }
            """,
            moduleName: "ImagePipeline")
        let consumer = ProjectMaterial.mergedSource(
            source: """
            import UIKit

            let bitmap: UIImage = UIImage(named: "fixture")!
            bitmap.processed.pixelWidth
            """,
            moduleName: "ImagePipeline")

        let value = try Interpreter(registry: TraceRegistry()).run(
            source: helper + imageExtension + consumer)
        #expect(value.intValue == 8)
    }

    @Test func inheritedInstanceOverloadUsesRuntimeType() throws {
        let source = """
        struct Slice {}

        class Base {
            func matches(_ value: [Int]) -> String { "array" }
            func matches(_ value: Slice) -> String { "slice" }
        }

        final class Child: Base {}
        Child().matches(Slice())
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "slice")
    }

    /// An inherited method's unqualified call is still virtual: runtime
    /// subclass overrides win even though the call is written in the generic
    /// superclass body.
    @Test func genericBaseMethodDispatchesImplicitSelfOverride() throws {
        let source = """
        class PipelineTask<Value> {
            let value: Value

            init(_ value: Value) {
                self.value = value
            }

            func start() -> String { "base" }
            func subscribe() -> String { "\\(value):\\(start())" }
        }

        final class ConcreteTask: PipelineTask<Int> {
            override func start() -> String { "concrete" }
        }

        ConcreteTask(7).subscribe()
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "7:concrete")
    }

    /// A concrete class returned through a generic base-typed closure keeps
    /// its runtime identity when a nested publisher stores it and invokes a
    /// private base method that makes a virtual call.
    @Test func genericPoolPreservesConcreteTaskIdentity() throws {
        let source = """
        class PipelineTask<Value> {
            struct Publisher {
                let task: PipelineTask

                func subscribe(
                    priority: Int = 0, subscriber: AnyObject,
                    _ closure: (String) -> Void
                ) -> String {
                    task.subscribe(
                        priority: priority,
                        subscriber: subscriber,
                        closure)
                }

                func subscribe<NewValue>(
                    _ subscriber: PipelineTask<NewValue>,
                    onValue: (String) -> Void
                ) -> String {
                    subscribe(subscriber: subscriber) { value in
                        onValue(value)
                    }
                }
            }

            let value: Value

            init(_ value: Value) {
                self.value = value
            }

            var publisher: Publisher { Publisher(task: self) }
            func start() -> String { "base" }
            private func subscribe(
                priority: Int = 0, subscriber: AnyObject,
                _ closure: (String) -> Void
            ) -> String {
                let value = start()
                closure(value)
                return value
            }
        }

        final class ConcreteTask: PipelineTask<Int> {
            override func start() -> String { "concrete" }
        }

        final class TaskPool<Key: Hashable, Value> {
            private var map = [Key: PipelineTask<Value>]()

            func publisherForKey(
                _ key: Key, _ make: () -> PipelineTask<Value>
            ) -> PipelineTask<Value>.Publisher {
                if let task = map[key] {
                    return task.publisher
                }

                let task = make()
                map[key] = task
                return task.publisher
            }
        }

        let pool = TaskPool<Int, Int>()
        pool.publisherForKey(1) { ConcreteTask(7) }
            .subscribe(PipelineTask<Int>(0)) { _ in }
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "concrete")
    }

    @Test func inheritedStaticOverloadUsesCallShape() throws {
        let source = """
        class Base {
            static func label() -> String { "empty" }
            static func label(_ value: String) -> String { value }
        }

        final class Child: Base {}
        Child.label("chosen")
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "chosen")
    }

    /// A concrete setter-like overload must not shadow a protocol-extension
    /// convenience method whose zero-argument call shape is the only fit.
    @Test func protocolDefaultWinsWhenConcreteOverloadDoesNotFit() throws {
        let source = """
        protocol TextReadable {
            func text(normalised: Bool) -> String
        }

        extension TextReadable {
            func text() -> String {
                text(normalised: true)
            }
        }

        class Element: TextReadable {
            func text(normalised: Bool) -> String {
                normalised ? "content" : "raw"
            }

            func text(_ replacement: String) -> Element {
                self
            }
        }

        final class Document: Element {
            override func text(_ replacement: String) -> Element {
                self
            }
        }

        Document().text()
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "content")
    }

    /// Protocol convenience overloads can share the witness's argument labels
    /// while adapting a different type. Runtime argument types must select the
    /// default for the outer call and the concrete witness for its delegation.
    @Test func protocolDefaultWinsSameShapeByRuntimeArgumentType() throws {
        let source = """
        struct Payload {
            let marker: Int
        }

        struct DecodeContext {
            let payload: Payload
        }

        protocol Decoding {
            func decode(_ payload: Payload) -> Int
        }

        extension Decoding {
            func decode(_ context: DecodeContext) -> Int {
                decode(context.payload)
            }
        }

        struct DefaultDecoder: Decoding {
            func decode(_ payload: Payload) -> Int {
                payload.marker
            }
        }

        let decoder: any Decoding = DefaultDecoder()
        decoder.decode(DecodeContext(payload: Payload(marker: 7)))
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 7)
    }

    /// Nuke's ImageDecoding default adapts a context to its Data witness from
    /// inside a throwing scope. Keep that host-payload and return-type shape
    /// independent of the package that surfaced it.
    @Test func protocolDefaultDelegatesHostPayloadInsideThrowingClosure() throws {
        let source = """
        import Foundation

        struct Container {
            let marker: Int
        }

        struct Response {
            let container: Container
        }

        struct DecodeContext {
            let data: Data
            let isCompleted: Bool
        }

        enum DecodeError: Error {
            case incomplete
        }

        protocol Decoding {
            func decode(_ data: Data) throws -> Container
        }

        extension Decoding {
            func decode(_ context: DecodeContext) throws -> Response {
                let container: Container = try autoreleasepool {
                    guard context.isCompleted else {
                        throw DecodeError.incomplete
                    }
                    return try decode(context.data)
                }
                return Response(container: container)
            }
        }

        final class DefaultDecoder: Decoding {
            func decode(_ data: Data) throws -> Container {
                Container(marker: data.count)
            }
        }

        let decoder: any Decoding = DefaultDecoder()
        try decoder.decode(
            DecodeContext(data: payloadData, isCompleted: true)
        ).container.marker
        """

        let interpreter = Interpreter(registry: TraceRegistry())
        interpreter.globals.define(
            "payloadData", .native(Data([0, 1, 2, 3, 4, 5, 6])))
        let value = try interpreter.run(source: source)
        #expect(value.intValue == 7)
    }

    /// A refined nonthrowing requirement is a better match for an unmarked
    /// call than its same-shaped throwing ancestor. This is the delegation
    /// pattern used when a throwing protocol default adapts a nonthrowing
    /// conformer to the ancestor requirement.
    @Test func unmarkedCallInThrowingDefaultSelectsNonthrowingWitness() throws {
        let source = """
        protocol ThrowingStore {
            func fetch(forKey key: String) throws -> String?
        }

        protocol Store: ThrowingStore {
            func fetch(forKey key: String) -> String?
        }

        extension Store {
            func fetch(forKey key: String) throws -> String? {
                fetch(forKey: key)
            }
        }

        struct Box: Store {
            func fetch(forKey key: String) -> String? {
                "native-ok"
            }
        }

        func throughThrowing(_ store: any ThrowingStore) throws -> String {
            try store.fetch(forKey: "key") ?? "nil"
        }

        try throughThrowing(Box())
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "native-ok")
    }

    /// The same rule applies when the refined witness is supplied by an SDK
    /// host type rather than an interpreted nominal declaration.
    @Test func unmarkedCallInThrowingDefaultSelectsHostWitness() throws {
        let source = """
        import Foundation

        protocol ThrowingStore {
            func object(forKey key: String) throws -> Any?
        }

        protocol Store: ThrowingStore {
            func object(forKey key: String) -> Any?
        }

        extension Store {
            func object(forKey key: String) throws -> Any? {
                object(forKey: key)
            }
        }

        extension UserDefaults: Store {}

        final class Settings {
            let defaults: Store

            init(defaults: Store = UserDefaults.standard) {
                self.defaults = defaults
            }

            func marker() -> String {
                defaults.object(forKey: "dynamic-swiftui-missing-key") == nil
                    ? "native-ok" : "unexpected"
            }
        }
        """

        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(
            source: source,
            lazyTopLevelGlobals: true)
        let symbol = try #require(
            interpreter.structSymbols.first { $0.name == "Settings" })
        guard case .instance(let settings) = try interpreter.instantiateRoot(
            symbol) else {
            Issue.record("Settings did not instantiate")
            return
        }
        let value = try interpreter.callMethod(
            named: "marker", on: settings, arguments: [])
        #expect(value.stringValue == "native-ok")
    }

    /// Suspending dispatch follows the same inherited-family and
    /// protocol-default rules as eager dispatch.
    @Test func asyncProtocolDefaultWinsWhenConcreteOverloadDoesNotFit() async throws {
        let source = """
        protocol TextReadable {
            func text(normalised: Bool) async -> String
        }

        extension TextReadable {
            func text() async -> String {
                await text(normalised: true)
            }
        }

        class Element: TextReadable {
            func text(normalised: Bool) async -> String {
                normalised ? "content" : "raw"
            }

            func text(_ replacement: String) async -> Element {
                self
            }
        }

        final class Document: Element {
            override func text(_ replacement: String) async -> Element {
                self
            }
        }

        await Document().text()
        """

        let value = try await Interpreter().runAsync(source: source)
        #expect(value.stringValue == "content")
    }

    /// Native Swift selects the one-input closure overload here. The
    /// function type is hidden behind a nested alias, matching scheduler
    /// helpers that distinguish a plain block from a starter callback.
    @Test func nestedFunctionAliasPreservesClosureArityDuringOverloadRanking() throws {
        let source = """
        final class Job {
            typealias Starter = (_ finish: @escaping () -> Void) -> Void
        }

        func select(_ action: @escaping () -> Void) -> String {
            "zero"
        }

        func select(_ starter: @escaping Job.Starter) -> String {
            starter({})
            return "one"
        }

        select { finish in finish() }
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "one")
    }

    /// Native Swift selects the nested-alias overload on a native host
    /// receiver too. Nuke's operation scheduler has this exact extension
    /// shape (`OperationQueue.add`), and the request pipeline cannot start if
    /// host-extension ranking treats the alias as a non-function parameter.
    @Test func nestedFunctionAliasRanksHostExtensionClosureOverloads() throws {
        let source = """
        final class Job {
            typealias Starter = @Sendable (
                _ finish: @Sendable @escaping () -> Void
            ) -> Void
        }

        extension String {
            func enqueue(
                _ action: @Sendable @escaping () -> Void
            ) -> String {
                "zero"
            }

            func enqueue(_ starter: @escaping Job.Starter) -> String {
                starter({})
                return "one"
            }
        }

        "queue".enqueue { finish in finish() }
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "one")
    }

    /// IceCubes' full app shell made protocol-candidate discovery visible on
    /// every host member read. Native precedence is exact nominal member,
    /// then a protocol-extension default when that exact lookup misses.
    /// Preserve that semantic order so conformance enumeration is demand
    /// driven rather than paid for by unrelated exact properties.
    @Test func exactHostMemberDefersProtocolCandidateEnumerationUntilMiss()
        throws
    {
        let registry = try ProtocolCandidateEnumerationRegistry()
        let source = """
        protocol Tagged {}

        extension Tagged {
            var fallback: Int { 9 }
        }

        let probe = ProtocolCandidateEnumerationProbe()
        (probe.value, probe.fallback)
        """

        let value = try Interpreter(registry: registry).run(source: source)
        let tuple = try #require(value.tupleValue)
        #expect(tuple.values[0].intValue == 7)
        #expect(tuple.values[1].intValue == 9)
        #expect(registry.queryCount == 1)
    }
}

private final class ProtocolCandidateEnumerationProbe {}

@MainActor
private final class ProtocolCandidateEnumerationRegistry: HostRegistry {
    private let probe = ProtocolCandidateEnumerationProbe()
    private let valueProperty: HostProperty
    private(set) var queryCount = 0

    init() throws {
        valueProperty = try HostProperty(
            declaration:
                "var ProtocolCandidateEnumerationProbe.value: Int { get }",
            get: { _, _ in .native(7) })
    }

    func cFunction(named name: String) -> HostFunction? { nil }
    func absorbedCValue(named name: String) -> RuntimeValue? { nil }
    func storeBlob(_ value: RuntimeValue, at path: String) {}
    func constructor(named name: String) -> HostFunction? {
        guard name == "ProtocolCandidateEnumerationProbe" else { return nil }
        return HostFunction(name: name) { [probe] _, _ in .native(probe) }
    }
    func modifier(named name: String) -> HostModifier? { nil }
    func isViewValue(_ value: RuntimeValue) -> Bool { false }
    func makeRenderable(
        instance: Instance, interpreter: Interpreter
    ) -> RuntimeValue { .void }
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue { .void }
    func hostTypeName(of value: Any) -> String? {
        value is ProtocolCandidateEnumerationProbe
            ? "ProtocolCandidateEnumerationProbe" : nil
    }
    func hostProtocolCandidates(of value: Any) -> [String] {
        guard value is ProtocolCandidateEnumerationProbe else { return [] }
        queryCount += 1
        return ["Tagged"]
    }
    func hostProperty(named name: String, on value: Any) -> HostProperty? {
        value is ProtocolCandidateEnumerationProbe && name == "value"
            ? valueProperty : nil
    }
}
