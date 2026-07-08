import SwiftUI
import SwiftUIBridge

struct ContentView: View {
    @State private var source = SamplePrograms.counter.source
    @State private var selectedSampleID = SamplePrograms.counter.id
    @State private var renderedView: AnyView?
    @State private var errorMessage: String?
    @State private var generation = 0

    private let host = InterpreterHost()

    var body: some View {
        HSplitView {
            editor
            preview
        }
        .toolbar {
            Picker("Sample", selection: $selectedSampleID) {
                ForEach(SamplePrograms.all) { sample in
                    Text(sample.name).tag(sample.id)
                }
            }
            .pickerStyle(.segmented)
        }
        .onChange(of: selectedSampleID) {
            if let sample = SamplePrograms.all.first(where: { $0.id == selectedSampleID }) {
                source = sample.source
            }
        }
        .task(id: source) {
            // Debounce: each edit restarts this task, cancelling the sleep.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            render()
        }
    }

    private var editor: some View {
        TextEditor(text: $source)
            .font(.system(size: 13, design: .monospaced))
            .autocorrectionDisabled()
            .frame(minWidth: 320)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            ZStack {
                if let renderedView {
                    // Fresh parse → fresh identity → interpreted @State resets.
                    renderedView.id(generation)
                } else {
                    Text("rendering…")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.red.opacity(0.85))
            }
        }
        .frame(minWidth: 320)
    }

    private func render() {
        switch host.render(source: sanitized(source)) {
        case .success(let view):
            renderedView = view
            generation += 1
            errorMessage = nil
        case .failure(let error):
            // Keep the last good view; just surface the error.
            errorMessage = error.description
        }
    }

    /// macOS TextEditor substitutes smart quotes, which silently breaks parsing.
    private func sanitized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }
}
