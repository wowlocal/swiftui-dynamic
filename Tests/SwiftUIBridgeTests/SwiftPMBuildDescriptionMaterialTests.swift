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
        #expect(!merged.contains("import Dependency"))
        try interpreter.run(source: merged)
        #expect(interpreter.globals.lookup("dependencyResult")?.stringValue
            == "resolved-dependency")
        #expect(interpreter.globals.lookup("dependencyModelValue")?.intValue
            == 42)
    }
}
