import Foundation
import SwiftInterpreter
@testable import SwiftUIBridge
import Testing

/// IceCubes' HTMLString surfaced this build-material class: SwiftPM compiled
/// SwiftSoup, but the interpreted projection only walked the app's local
/// Packages directory. This fixture is the smallest equivalent graph: the
/// build description names one app source and one dependency source, and the
/// result is only defined when both compiler inputs join the merge.
@Suite("SwiftPM build-description material", .serialized)
struct SwiftPMBuildDescriptionMaterialTests {
    @Test
    func combinedSourceAnalysisPreservesBothProjections() {
        let source = """
            import SurfaceKit
            struct LocalValue {}
            #if os(iOS)
            func conditionalValue() -> SurfaceKit.Value {
                SurfaceKit.makeValue(LocalValue())
            }
            #endif
            """
        let analysis = Interpreter.sourceModuleAnalysis(in: source)

        #expect(analysis.usage == Interpreter.sourceModuleUsage(in: source))
        #expect(
            analysis.topLevelDeclarationNames
                == Interpreter.topLevelDeclarationNames(in: source))
        #expect(analysis.usage.importedModuleNames == ["SurfaceKit"])
        #expect(analysis.usage.qualifiedReferences.contains(
            SourceModuleReference(
                moduleName: "SurfaceKit", memberName: "makeValue")))
        #expect(analysis.topLevelDeclarationNames.contains("LocalValue"))
        #expect(analysis.topLevelDeclarationNames.contains("conditionalValue"))
    }

    @Test
    func importedUnqualifiedNominalSelectsCompleteModule() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpm-imported-surface-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("App/Sources/App.swift")
        let value = root.appendingPathComponent(
            ".build/checkouts/SurfaceKit/Sources/SurfaceKit/Value.swift")
        let styling = root.appendingPathComponent(
            ".build/checkouts/SurfaceKit/Sources/SurfaceKit/String+Styling.swift")
        for file in [app, value, styling] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        try """
            import SurfaceKit
            let importedSurface = SurfaceValue.message + "|" + "plain".surfaceStyled
            """
            .write(to: app, atomically: true, encoding: .utf8)
        try "struct SurfaceValue { static let message = \"surface\" }\n"
            .write(to: value, atomically: true, encoding: .utf8)
        try "extension String { var surfaceStyled: String { self + \"-styled\" } }\n"
            .write(to: styling, atomically: true, encoding: .utf8)

        let description = root.appendingPathComponent("description.json")
        let payload: [String: Any] = [
            "swiftCommands": [
                "C.App.module": [
                    "moduleName": "App",
                    "sources": [app.path],
                ],
                "C.SurfaceKit.module": [
                    "moduleName": "SurfaceKit",
                    "sources": [value.path, styling.path],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: description, options: .atomic)

        let dependencies = try ProjectMaterial.swiftFiles(
            inSwiftPMBuildDescriptionAt: description.path,
            requiredBy: [app.path])
        #expect(dependencies == [styling.path, value.path].sorted())

        let sourceModules = try ProjectMaterial.sourceModuleNames(
            inSwiftPMBuildDescriptionAt: description.path)
        let merged = ProjectMaterial.mergedSource(
            files: [app.path] + dependencies,
            sourceModules: sourceModules)
        let interpreter = Interpreter()
        try interpreter.run(source: merged)
        #expect(interpreter.globals.lookup("importedSurface")?.stringValue
            == "surface|plain-styled")
    }

    @Test
    func compiledDependencySourceJoinsRuntimeProjection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpm-material-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("App/Sources/App.swift")
        let dependency = root.appendingPathComponent(
            ".build/checkouts/Dependency/Sources/Dependency/Value.swift")
        let namespace = root.appendingPathComponent(
            ".build/checkouts/NamespaceKit/Sources/NamespaceKit/Namespace.swift")
        let unused = root.appendingPathComponent(
            ".build/checkouts/Unused/Sources/Unused/Unused.swift")
        try FileManager.default.createDirectory(
            at: app.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dependency.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: namespace.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: unused.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try """
            import Dependency
            import NamespaceKit
            let dependencyResult = Dependency.dependencyMessage()
            let dependencyModelValue = Dependency.Model.value()
            let namespaceValue = NamespaceKit.Config()
            """
            .write(to: app, atomically: true, encoding: .utf8)
        try """
            func dependencyMessage() -> String { "resolved-dependency" }
            struct Model {
                static func value() -> Int { 42 }
            }
            """
            .write(to: dependency, atomically: true, encoding: .utf8)
        try "enum NamespaceKit { struct Config {} }\n"
            .write(to: namespace, atomically: true, encoding: .utf8)
        try "func neverReferenced() -> String { \"unused\" }\n"
            .write(to: unused, atomically: true, encoding: .utf8)

        let description = root.appendingPathComponent("description.json")
        let payload: [String: Any] = [
            "swiftCommands": [
                "C.App.module": [
                    "moduleName": "App",
                    "sources": [app.path],
                ],
                "C.Dependency.module": [
                    "moduleName": "Dependency",
                    "sources": [dependency.path],
                ],
                "C.NamespaceKit.module": [
                    "moduleName": "NamespaceKit",
                    "sources": [namespace.path],
                ],
                "C.Unused.module": [
                    "moduleName": "Unused",
                    "sources": [unused.path],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: description, options: .atomic)

        let allFiles = try ProjectMaterial.swiftFiles(
            inSwiftPMBuildDescriptionAt: description.path)
        #expect(allFiles == [app.path, dependency.path, namespace.path, unused.path]
            .sorted())

        let dependencies = try ProjectMaterial.swiftFiles(
            inSwiftPMBuildDescriptionAt: description.path,
            requiredBy: [app.path])
        // Dependency contributes the referenced free global. NamespaceKit is
        // a same-named type qualifier, and Unused has no qualified demand.
        #expect(dependencies == [dependency.path])

        let interpreter = Interpreter()
        let sourceModules = try ProjectMaterial.sourceModuleNames(
            inSwiftPMBuildDescriptionAt: description.path)
        let merged = ProjectMaterial.mergedSource(
            files: [app.path] + dependencies,
            sourceModules: sourceModules)
        #expect(merged.contains("// swift-interpreter-module Dependency"))
        #expect(merged.contains(
            "// swift-interpreter-source-module Dependency"))
        #expect(!merged.contains("\nimport Dependency\n"))
        try interpreter.run(source: merged)
        #expect(interpreter.globals.lookup("dependencyResult")?.stringValue
            == "resolved-dependency")
        #expect(interpreter.globals.lookup("dependencyModelValue")?.intValue
            == 42)
    }

    /// A compiled Swift target that directly imports a Clang module cannot be
    /// interpreted from its Swift files alone. Keep it opaque while still
    /// selecting a pure-Swift sibling from the same build description.
    @Test
    func directClangDependencyRemainsACompiledImport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpm-clang-boundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("App/App.swift")
        let pure = root.appendingPathComponent("PureKit/Pure.swift")
        let backed = root.appendingPathComponent("ParserKit/Parser.swift")
        let moduleMap = root.appendingPathComponent(
            "NativeParser/include/module.modulemap")
        for file in [app, pure, backed, moduleMap] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        try """
            import PureKit
            import ParserKit
            let pureValue = PureValue.answer
            let parsedValue = NativeParserWrapper.parse("fixture")
            """.write(to: app, atomically: true, encoding: .utf8)
        try "struct PureValue { static let answer = 42 }\n"
            .write(to: pure, atomically: true, encoding: .utf8)
        try """
            import NativeParser
            struct NativeParserWrapper {
                static func parse(_ value: String) -> String {
                    native_parse(value)
                }
            }
            """.write(to: backed, atomically: true, encoding: .utf8)
        try "module NativeParser { header \"NativeParser.h\" }\n"
            .write(to: moduleMap, atomically: true, encoding: .utf8)

        let description = root.appendingPathComponent("description.json")
        let payload: [String: Any] = [
            "swiftCommands": [
                "C.App.module": [
                    "moduleName": "App", "sources": [app.path],
                ],
                "C.PureKit.module": [
                    "moduleName": "PureKit", "sources": [pure.path],
                ],
                "C.ParserKit.module": [
                    "moduleName": "ParserKit", "sources": [backed.path],
                    "otherArguments": [
                        "-Xcc", "-fmodule-map-file=\(moduleMap.path)",
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: description, options: .atomic)

        let dependencies = try ProjectMaterial.swiftFiles(
            inSwiftPMBuildDescriptionAt: description.path,
            requiredBy: [app.path])
        #expect(dependencies == [pure.path])
    }

    /// IceCubes' StatusKit imports SwiftUI.Text while the flattened dependency
    /// slice also contains Markdown.Text. A native two-module probe prints
    /// "visible": merely compiling HiddenMarkdown beside App does not import
    /// its nominal into App's lexical scope.
    @Test
    func unqualifiedNominalRespectsFileImportsAcrossFlattenedModules() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpm-import-visibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let visible = root.appendingPathComponent("VisibleUI/Text.swift")
        let app = root.appendingPathComponent("App/Screen.swift")
        let hidden = root.appendingPathComponent("HiddenMarkdown/Text.swift")
        for file in [visible, app, hidden] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        try """
            struct Text {
                let marker: String
                init(_ value: String) { marker = "visible" }
            }
            """.write(to: visible, atomically: true, encoding: .utf8)
        try """
            import VisibleUI
            struct Screen {
                var selectedTextMarker: String { Text("").marker }
            }
            """.write(to: app, atomically: true, encoding: .utf8)
        try """
            struct Text {
                let marker: String
                init(_ value: String) { marker = "hidden" }
            }
            """.write(to: hidden, atomically: true, encoding: .utf8)

        let merged = ProjectMaterial.mergedSource(
            files: [visible.path, app.path, hidden.path],
            sourceModules: [
                visible.path: "VisibleUI",
                hidden.path: "HiddenMarkdown",
            ])
        #expect(!merged.contains("\nimport VisibleUI\n"))
        #expect(merged.contains(
            "// swift-interpreter-source-import VisibleUI"))
        #expect(merged.contains("// swift-interpreter-source-file"))
        let result = try Interpreter().run(
            source: merged + "\nScreen().selectedTextMarker")
        #expect(result.stringValue == "visible")
    }

    /// An extension is owned by the same compiler module as its nominal even
    /// when a later flattened module declares another type with the same bare
    /// name. This is the Markdown.Document / SwiftSoup.Document shape used by
    /// EmojiText: `init(parsing:)` must attach to Markdown's Document rather
    /// than whichever Document most recently occupied the merged global.
    @Test
    func extensionTargetsOwningModuleAcrossNominalCollision() throws {
        let markdownType = ProjectMaterial.mergedSource(source: """
        import Foundation
        public struct ParseOptions: OptionSet {
            public let rawValue: Int
            public init(rawValue: Int) { self.rawValue = rawValue }
        }
        public struct Document {
            let text: String
            public init(_ text: String) { self.text = text }
        }
        """, moduleName: "Markdown")
        let soupType = ProjectMaterial.mergedSource(source: """
        public struct Document {
            let tag: Int
            public init(tag: Int) { self.tag = tag }
        }
        """, moduleName: "SwiftSoup")
        let markdownExtension = ProjectMaterial.mergedSource(source: """
        import Foundation
        public extension Document {
            init(
                parsing text: String,
                source: URL? = nil,
                options: ParseOptions = []
            ) { self.init(text) }
        }
        """, moduleName: "Markdown")
        let client = ProjectMaterial.mergedSource(source: """
        import Markdown
        protocol Rendering {
            func render() -> String
        }
        struct Renderer: Rendering {
            func render() -> String {
                parsedText()
            }
            private func parsedText() -> String {
                Document(parsing: "module-owned-extension").text
            }
        }
        let renderer: any Rendering = Renderer()
        renderer.render()
        """, moduleName: "Client")

        let result = try Interpreter().run(
            source: markdownType + soupType + markdownExtension + client)
        #expect(result.stringValue == "module-owned-extension")
    }

    /// A bare nominal reference resolves in the modules its own region can
    /// SEE, not in whichever same-named declaration the merge happened to
    /// flatten last.
    ///
    /// This is the `Models.Tag` / `SwiftSoup.Tag` collision, and it is the
    /// sibling of `extensionTargetsOwningModuleAcrossNominalCollision` above:
    /// that one pins an EXTENSION to its owning module, this one pins an
    /// ordinary type reference in a stored property and a `Decodable`
    /// memberwise initializer. IceCubes reaches it because
    /// `Models/Alias/HTMLString.swift`
    /// imports SwiftSoup for HTML->attributed text, so `SwiftSoup.Tag` (an
    /// `open class`) joins the same merged program as `Models.Tag` (the
    /// Mastodon hashtag `struct`), while `Timeline` — which declares
    /// `@Binding var tag: Tag?` — imports Models and never imports SwiftSoup.
    ///
    /// ORDER IS THE POINT, so the collider is declared LAST here. The two
    /// halves of a merged IceCubes program sort into different relative orders
    /// depending on where the checkout lives: app sources reach the merge
    /// through an absolute `External` symlink that points OUTSIDE the root,
    /// while SwiftPM's dependency checkouts live UNDER it, and
    /// `Array(Set(local + external)).sorted()` interleaves the two by absolute
    /// path. A lane worktree under `/Users/...` sorts the dependency first and
    /// `Models.Tag` last; a close-gate checkout under `/private/tmp/...` sorts
    /// it the other way. Same commit, same bytes, opposite winner — which is
    /// why this presented for weeks as "the capture differs by checkout path"
    /// and could not be reproduced in the tree that was being used to debug it.
    ///
    /// The observable it cost: `TimelineTagHeaderView` is `if let tag { ... }`,
    /// so a `tag` that decodes to the wrong `Tag` renders NOTHING, the whole
    /// hashtag header block disappears, every row below shifts up by its
    /// height, and the screen scores 206,522 AE against a floor of 0.
    @Test
    func bareNominalResolvesInImportedModuleNotTheLastFlattenedOne() throws {
        let models = ProjectMaterial.mergedSource(source: """
        public struct Tag: Codable, Equatable {
            public let name: String
            public let totalUses: Int
            public init(name: String, totalUses: Int) {
                self.name = name
                self.totalUses = totalUses
            }
        }
        """, moduleName: "Models")
        // Declared AFTER Models, exactly as the close-gate checkout orders it.
        // `open class` matches SwiftSoup's real shape: it is not `Decodable`,
        // has no memberwise `init(name:totalUses:)`, and so cannot satisfy the
        // use below — a wrong winner fails loudly rather than silently.
        let soup = ProjectMaterial.mergedSource(source: """
        open class Tag: Hashable, @unchecked Sendable {
            public let tagName: String
            public init(_ tagName: String) { self.tagName = tagName }
            public static func == (lhs: Tag, rhs: Tag) -> Bool {
                lhs.tagName == rhs.tagName
            }
            public func hash(into hasher: inout Hasher) {
                hasher.combine(tagName)
            }
        }
        """, moduleName: "SwiftSoup")
        // Imports Models and never imports SwiftSoup — the visibility that has
        // to decide this, since both declarations are in the same flat program.
        // The reference sits INSIDE a type owned by the Timeline region, which
        // is where IceCubes has it (`@Binding var tag: Tag?` on
        // `TimelineTagHeaderView`) — not at top level, where a merged program
        // has no owning declaration to carry module provenance.
        let timeline = ProjectMaterial.mergedSource(source: """
        import Models
        struct TagHeader {
            var tag: Tag?
            static func make() -> TagHeader {
                TagHeader(tag: Tag(name: "swift", totalUses: 77))
            }
            func headline() -> String {
                if let tag {
                    return "#\\(tag.name) \\(tag.totalUses)"
                }
                return "<no header>"
            }
        }
        TagHeader.make().headline()
        """, moduleName: "Timeline")

        let result = try Interpreter().run(
            source: models + soup + timeline)
        #expect(result.stringValue == "#swift 77")
    }

    /// The same collision reached the way IceCubes actually reaches it: through
    /// a GENERIC function that lives in a third module and is bound to the
    /// concrete type by the CALLER's annotation.
    ///
    /// `TimelineViewModel.fetchTag` is `let tag: Tag = try await
    /// client.get(endpoint: Tags.tag(id:))` — module Timeline names the type,
    /// module NetworkClient runs the decode, and neither the generic parameter
    /// nor the frame it executes in carries Timeline's imports. The sibling
    /// test above pins the direct case, which already works; this pins the
    /// indirect one, and the difference between them is the whole bug.
    ///
    /// Why this is the shape that matters for the hashtag header: the capture
    /// harness hands the screen only the tag NAME, and gates readiness on
    /// `/api/v1/tags/swift` being served, so the response provably arrives.
    /// Everything the header draws — the use and participant counts — comes
    /// back through this generic decode. If it binds `SwiftSoup.Tag`, the
    /// assignment yields nil, `if let tag` renders nothing, and the header
    /// block vanishes without a single diagnostic.
    /// Was RED when first pinned, under `withKnownIssue`, with `23:9: missing
    /// argument for parameter 'tagName'` — `Entity` had bound `SwiftSoup.Tag`
    /// and its `init(_:)` inside a module importing neither Models nor
    /// SwiftSoup. Fixed by carrying the lexical scope that SPELLED the
    /// annotation, so the generic binds what the caller can see instead of
    /// what the merge flattened last.
    @Test
    func genericDecodeBindsCallerModulesNominalNotTheLastFlattenedOne() async throws {
        let models = ProjectMaterial.mergedSource(source: """
        public protocol Fixture {
            init(fixture: String)
        }
        public struct Tag: Fixture, Equatable {
            public let name: String
            public let totalUses: Int
            public init(fixture: String) {
                self.name = fixture
                self.totalUses = 77
            }
        }
        """, moduleName: "Models")
        // The decoding module never sees Models or SwiftSoup; it is generic
        // over the caller's type exactly as `Client.get` is.
        let network = ProjectMaterial.mergedSource(source: """
        public struct Client {
            public init() {}
            public func get<Entity: Fixture>(endpoint: String) async throws -> Entity {
                Entity(fixture: endpoint)
            }
        }
        """, moduleName: "NetworkClient")
        // Declared LAST, as the close-gate checkout orders it.
        let soup = ProjectMaterial.mergedSource(source: """
        open class Tag: Hashable, @unchecked Sendable {
            public let tagName: String
            public init(_ tagName: String) { self.tagName = tagName }
            public static func == (lhs: Tag, rhs: Tag) -> Bool {
                lhs.tagName == rhs.tagName
            }
            public func hash(into hasher: inout Hasher) {
                hasher.combine(tagName)
            }
        }
        """, moduleName: "SwiftSoup")
        let timeline = ProjectMaterial.mergedSource(source: """
        import Models
        import NetworkClient
        struct TagHeader {
            var tag: Tag?
            static func fetch() async throws -> TagHeader {
                let client = Client()
                let tag: Tag = try await client.get(endpoint: "swift")
                return TagHeader(tag: tag)
            }
            func headline() -> String {
                if let tag {
                    return "#\\(tag.name) \\(tag.totalUses)"
                }
                return "<no header>"
            }
        }
        let header = try await TagHeader.fetch()
        header.headline()
        """, moduleName: "Timeline")

        let result = try await Interpreter().runAsync(
            source: models + network + soup + timeline)
        #expect(result.stringValue == "#swift 77")
    }

    /// The same binding under the DECLARATION ORDER that used to pass by
    /// accident: SwiftSoup ahead of Models is what a lane worktree produces,
    /// and it scored 0 for weeks while clean checkouts lost the header. Both
    /// orders must now give the same answer, because the answer comes from
    /// module visibility rather than from which declaration landed last.
    @Test
    func genericDecodeIsIndependentOfFlattenedDeclarationOrder() throws {
        let models = ProjectMaterial.mergedSource(source: """
        public protocol Fixture {
            init(fixture: String)
        }
        public struct Tag: Fixture, Equatable {
            public let name: String
            public let totalUses: Int
            public init(fixture: String) {
                self.name = fixture
                self.totalUses = 77
            }
        }
        """, moduleName: "Models")
        let network = ProjectMaterial.mergedSource(source: """
        public struct Client {
            public init() {}
            public func get<Entity: Fixture>(endpoint: String) -> Entity {
                Entity(fixture: endpoint)
            }
        }
        """, moduleName: "NetworkClient")
        let soup = ProjectMaterial.mergedSource(source: """
        open class Tag: Hashable, @unchecked Sendable {
            public let tagName: String
            public init(_ tagName: String) { self.tagName = tagName }
            public static func == (lhs: Tag, rhs: Tag) -> Bool {
                lhs.tagName == rhs.tagName
            }
            public func hash(into hasher: inout Hasher) {
                hasher.combine(tagName)
            }
        }
        """, moduleName: "SwiftSoup")
        let timeline = ProjectMaterial.mergedSource(source: """
        import Models
        import NetworkClient
        struct TagHeader {
            var tag: Tag?
            static func fetch() -> TagHeader {
                let client = Client()
                let tag: Tag = client.get(endpoint: "swift")
                return TagHeader(tag: tag)
            }
            func headline() -> String {
                if let tag {
                    return "#\\(tag.name) \\(tag.totalUses)"
                }
                return "<no header>"
            }
        }
        TagHeader.fetch().headline()
        """, moduleName: "Timeline")

        // SwiftSoup FIRST — the order the lane worktree flattens.
        let soupFirst = try Interpreter().run(
            source: soup + models + network + timeline)
        #expect(soupFirst.stringValue == "#swift 77")
        // SwiftSoup LAST — the order the close-gate checkout flattens.
        let soupLast = try Interpreter().run(
            source: models + network + soup + timeline)
        #expect(soupLast.stringValue == "#swift 77")
    }

    @Test
    func hostImportedNominalWinsOverUnimportedFlattenedSourceType() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-import-visibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("App/Screen.swift")
        let hidden = root.appendingPathComponent("HiddenMarkdown/Text.swift")
        for file in [app, hidden] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        try """
            import SwiftUI
            struct Screen: View {
                var body: some View { Text("visible-host") }
            }
            """.write(to: app, atomically: true, encoding: .utf8)
        try """
            struct Text {
                init(_ value: String) {}
            }
            """.write(to: hidden, atomically: true, encoding: .utf8)

        let merged = ProjectMaterial.mergedSource(
            files: [app.path, hidden.path],
            sourceModules: [hidden.path: "HiddenMarkdown"])
        let strings = try await LiveCheckSupport.renderedStrings(source: merged)
        #expect(strings.contains("visible-host"))
    }

    @Test
    func appendedInlineSourceRetainsItsOwnHostImports() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inline-import-visibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent("HiddenMarkdown/Text.swift")
        try FileManager.default.createDirectory(
            at: hidden.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try """
            struct Text {
                init(_ value: String) {}
            }
            """.write(to: hidden, atomically: true, encoding: .utf8)

        let dependency = ProjectMaterial.mergedSource(
            files: [hidden.path],
            sourceModules: [hidden.path: "HiddenMarkdown"])
        let probe = ProjectMaterial.mergedSource(
            source: """
            import SwiftUI
            struct ProbeView: View {
                var body: some View { Text("inline-visible-host") }
            }
            """,
            moduleName: "Probe")
        let strings = try await LiveCheckSupport.renderedStrings(
            source: dependency + probe)

        #expect(strings.contains("inline-visible-host"))
    }

    /// IceCubes' R1 probe is appended as its own source projection and launches
    /// through an `App` scene. The scene harness extracts the `WindowGroup`
    /// trailing closure for later evaluation; that detached syntax must retain
    /// the declaring file's imports just like an escaped source closure does.
    /// A native two-module probe resolves this `Text` to SwiftUI.Text, never the
    /// unimported dependency nominal with the same unqualified name.
    @Test
    func extractedAppSceneRetainsInlineSourceImports() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-import-visibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent("HiddenMarkdown/Text.swift")
        try FileManager.default.createDirectory(
            at: hidden.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try """
            struct Text {
                init(_ value: String) {}
            }
            """.write(to: hidden, atomically: true, encoding: .utf8)

        let dependency = ProjectMaterial.mergedSource(
            files: [hidden.path],
            sourceModules: [hidden.path: "HiddenMarkdown"])
        let probe = ProjectMaterial.mergedSource(
            source: """
            import SwiftUI
            @main struct ProbeApp: App {
                var body: some Scene {
                    WindowGroup {
                        Text("scene-visible-host")
                    }
                }
            }
            """,
            moduleName: "Probe")
        let render = try await LiveCheckSupport.render(
            source: dependency + probe)

        #expect(render.strings.contains("scene-visible-host"),
                "detached scene lost its source imports: \(render.strings), root \(render.rootSymbol)")
    }

    /// One directory reached by two names must merge to one program.
    ///
    /// A merge has two halves that arrive spelled differently: files WALKED
    /// off the filesystem keep whatever spelling the caller passed, while
    /// files read from a SwiftPM build description are already resolved. The
    /// halves are then unioned and SORTED BY ABSOLUTE PATH, so a caller who
    /// names the root through a symlink does not merely get cosmetically
    /// different strings — it gets a different merge ORDER, and later
    /// declarations win.
    ///
    /// This is not hypothetical on macOS, where `/tmp` and `/var` are
    /// symlinks into `/private` and `getcwd()` returns the physical spelling.
    /// Measured 2026-08-08: IceCubes' `hashtag-timeline` rendered its pinned
    /// tag header as an empty 20pt cell instead of an 84pt one — every row
    /// below shifted up, ~205.5k AE — purely because a gate checkout under
    /// `/tmp/lane-gate-<sha>` reached the interpreter as `/private/tmp/...`
    /// while its own build description canonicalised to `/tmp/...`. The same
    /// binary on the same bytes named the other way rendered it correctly.
    ///
    /// The fixture picks names that make the sort INVERT rather than merely
    /// differ: `walked` sorts before `described` under the real directory,
    /// and after it through the alias.
    @Test
    func mergeIsIndependentOfHowTheRootIsSpelled() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpm-root-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        // "aaa-real" / "zzz-alias" are load-bearing: they put the alias on the
        // far side of the described half in a lexicographic sort.
        let real = base.appendingPathComponent("aaa-real")
        let alias = base.appendingPathComponent("zzz-alias")

        let walked = real.appendingPathComponent("Aaa/Sources/Aaa/Walked.swift")
        let described = real.appendingPathComponent("Zzz/Sources/Zzz/Described.swift")
        for file in [walked, described] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        try "struct Walked { static let origin = \"walked\" }\n"
            .write(to: walked, atomically: true, encoding: .utf8)
        try "struct Described { static let origin = \"described\" }\n"
            .write(to: described, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: real)

        let description = real.appendingPathComponent("description.json")
        try JSONSerialization.data(withJSONObject: [
            "swiftCommands": [
                "C.Zzz.module": [
                    "moduleName": "Zzz",
                    "sources": [described.path],
                ],
            ],
        ]).write(to: description, options: .atomic)

        let sourceModules = try ProjectMaterial.sourceModuleNames(
            inSwiftPMBuildDescriptionAt: description.path)

        func merge(under root: URL) throws -> (files: [String], source: String) {
            let local = ProjectMaterial.swiftFiles(
                under: root.appendingPathComponent("Aaa/Sources").path)
            let dependencies = try ProjectMaterial.swiftFiles(
                inSwiftPMBuildDescriptionAt:
                    root.appendingPathComponent("description.json").path)
            let files = Array(Set(local + dependencies)).sorted()
            return (files, ProjectMaterial.mergedSource(
                files: files, sourceModules: sourceModules))
        }

        let viaReal = try merge(under: real)
        let viaAlias = try merge(under: alias)

        // The walked half must not carry the alias into the merge at all.
        #expect(!viaAlias.files.contains { $0.contains("zzz-alias") },
                "alias spelling reached the merge: \(viaAlias.files)")
        #expect(viaAlias.files == viaReal.files,
                "same directory, two names, two file lists: real \(viaReal.files) alias \(viaAlias.files)")
        #expect(viaAlias.source == viaReal.source,
                "same directory, two names, two merged programs")
    }
}
