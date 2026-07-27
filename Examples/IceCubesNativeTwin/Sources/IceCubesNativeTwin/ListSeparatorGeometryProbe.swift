import SwiftUI

/// Distilled native oracle for target-platform plain-list separators.
/// The row trailing inset deliberately varies while every row supplies the
/// same separator-leading guide. Compiled Catalyst keeps the separator's
/// trailing edge at x=879 in the 900-point harness for every variant, proving
/// that its 20-point trailing baseline is platform-owned rather than copied
/// from the row inset.
@MainActor
struct ListSeparatorGeometryProbe: View {
    private let trailingInsets: [CGFloat] = [0, 8, 20, 40, 20]

    var body: some View {
        List {
            ForEach(trailingInsets.indices, id: \.self) { index in
                let trailingInset = trailingInsets[index]
                HStack {
                    Color.red
                        .frame(width: 16, height: 16)
                    Text(index == trailingInsets.indices.last
                        ? "SENTINEL"
                        : "TRAILING \(Int(trailingInset))")
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .listRowInsets(.init(
                    top: 0,
                    leading: 20,
                    bottom: 0,
                    trailing: trailingInset))
                .alignmentGuide(.listRowSeparatorLeading) { _ in
                    -100
                }
            }
        }
        .listStyle(.plain)
        .environment(\.colorScheme, .light)
        .background(Color.white)
    }
}
