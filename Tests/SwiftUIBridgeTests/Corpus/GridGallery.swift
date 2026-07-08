struct ContentView: View {
    @State var columnCount = 3

    let palette: [String] = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown"]

    var columns: [GridItem] {
        var items: [GridItem] = []
        for _ in 0..<columnCount {
            items.append(GridItem(.flexible(), spacing: 8))
        }
        return items
    }

    func color(named name: String) -> String {
        name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gallery")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("-") {
                    columnCount = max(1, columnCount - 1)
                }
                Text("\(columnCount)")
                    .monospaced()
                Button("+") {
                    columnCount = min(6, columnCount + 1)
                }
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(palette.indices) { i in
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.blue.opacity(0.15))
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(.blue.gradient)
                                    .frame(width: 28, height: 28)
                                Text(palette[i])
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .padding(6)
                        }
                        .aspectRatio(1.0, contentMode: .fit)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: 420, maxHeight: 480)
    }
}
