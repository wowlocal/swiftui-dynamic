import SwiftUI
import SwiftInterpreter
import SwiftUIBridge

@main
struct AtmosphereDeviceApp: App {
    init() {
        NetworkBridge.policy = .live
        NetworkBridge.requestLog = []
    }

    var body: some Scene {
        WindowGroup {
            AtmosphereInterpreterView()
        }
    }
}

private struct AtmosphereInterpreterView: View {
    @State private var renderedView: AnyView?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let renderedView {
                renderedView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ScrollView {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .padding()
                }
            } else {
                ProgressView("Interpreting Atmosphere…")
            }
        }
        .task {
            renderAtmosphere()
        }
    }

    private func renderAtmosphere() {
        guard let resources = Bundle.main.resourceURL else {
            errorMessage = "The application resource directory is unavailable."
            return
        }

        let bundledProject = resources.appendingPathComponent("Atmosphere", isDirectory: true)
        let root = FileManager.default.fileExists(atPath: bundledProject.path)
            ? bundledProject
            : resources
        let files = ProjectMaterial.swiftFiles(under: root.path)
        guard !files.isEmpty else {
            errorMessage = "No bundled Atmosphere Swift source files were found."
            print("[AtmosphereDevice] error: \(errorMessage!)")
            return
        }

        print("[AtmosphereDevice] interpreting \(files.count) bundled source files")
        RenderDiagnostics.reset()
        let source = ProjectMaterial.mergedSource(at: root.path, files: files)
        switch InterpreterHost().render(source: source, lazyTopLevelGlobals: true) {
        case .success(let view):
            renderedView = view
            print("[AtmosphereDevice] root view interpreted successfully")
            Task {
                try? await Task.sleep(for: .seconds(8))
                if RenderDiagnostics.errors.isEmpty {
                    print("[AtmosphereDevice] render diagnostics clean")
                } else {
                    for diagnostic in RenderDiagnostics.errors {
                        print("[AtmosphereDevice] diagnostic [\(diagnostic.view)]: \(diagnostic.error)")
                    }
                }
                print("[AtmosphereDevice] live requests: \(NetworkBridge.requestLog.count)")
                for request in NetworkBridge.requestLog {
                    print("[AtmosphereDevice] network: \(request)")
                }
            }
        case .failure(let error):
            errorMessage = error.description
            print("[AtmosphereDevice] interpreter error: \(error.description)")
        }
    }
}
