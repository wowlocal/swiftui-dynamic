import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct PlatformProbe {
    let framework: String
    let viewSummary: String
    let fontSummary: String
    let colorSummary: String

    init() {
        #if canImport(UIKit)
        let view = UIView(frame: CGRect(x: 2, y: 4, width: 120, height: 48))
        view.frame = CGRect(x: 8, y: 12, width: 240, height: 96)
        view.tag = 42

        let font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        let color = UIColor(
            red: 0.20, green: 0.48, blue: 0.96, alpha: 1
        ).withAlphaComponent(0.72)

        framework = "UIKit"
        viewSummary = "UIView  \(Int(view.frame.width)) × \(Int(view.frame.height))  ·  tag \(view.tag)"
        fontSummary = "\(font.fontName)  ·  \(Int(font.pointSize)) pt"
        colorSummary = color.accessibilityName
        #elseif canImport(AppKit)
        let view = NSView(frame: CGRect(x: 2, y: 4, width: 120, height: 48))
        view.frame = CGRect(x: 8, y: 12, width: 240, height: 96)

        let font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        let color = NSColor(
            calibratedRed: 0.20, green: 0.48, blue: 0.96, alpha: 1
        ).withAlphaComponent(0.72)

        framework = "AppKit"
        viewSummary = "NSView  \(Int(view.frame.width)) × \(Int(view.frame.height))"
        fontSummary = "\(font.fontName)  ·  \(Int(font.pointSize)) pt"
        colorSummary = "custom blue  ·  \(Int(color.alphaComponent * 100))% alpha"
        #endif
    }
}

struct ProbeRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct ContentView: View {
    private let probe = PlatformProbe()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.22), Color.indigo.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(Color.blue)

                VStack(spacing: 6) {
                    Text("Generated \(probe.framework) bridge")
                        .font(.title2.bold())
                    Text("Rendered by SwiftInterpreter")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    ProbeRow(
                        symbol: "rectangle.on.rectangle",
                        title: "Native view · constructor + mutation",
                        value: probe.viewSummary
                    )
                    Divider()
                    ProbeRow(
                        symbol: "textformat",
                        title: "Native font · contextual static method",
                        value: probe.fontSummary
                    )
                    Divider()
                    ProbeRow(
                        symbol: "paintpalette.fill",
                        title: "Native color · constructor + method",
                        value: probe.colorSummary
                    )
                }
                .padding(.horizontal, 18)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))

                Text("Generated contracts are active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(maxWidth: 520)
        }
    }
}
