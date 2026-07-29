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
}
