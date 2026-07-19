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
