enum ParseFailure: Error {
    case notANumber
}

struct ContentView: View {
    @State var input = "the quick brown fox jumps over the lazy dog the end"

    var words: [String] {
        input.lowercased().split(separator: " ")
    }

    var counts: [String: Int] {
        var tally: [String: Int] = [:]
        for word in words {
            tally[word] = (tally[word] ?? 0) + 1
        }
        return tally
    }

    var repeated: [String] {
        var seen: [String] = []
        for word in words {
            if (counts[word] ?? 0) > 1 && !seen.contains(word) {
                seen.append(word)
            }
        }
        return seen.sorted()
    }

    var longest: String {
        words.sorted { $0.count > $1.count }.first ?? ""
    }

    func numberSummary(of text: String) -> String {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else {
            return "not a number"
        }
        return n % 2 == 0 ? "even \(n)" : "odd \(n)"
    }

    func strictParse(_ text: String) throws -> Int {
        guard let n = Int(text) else {
            throw ParseFailure.notANumber
        }
        return n
    }

    var todayStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yyyy"
        return formatter.string(from: Date())
    }

    var strictReport: String {
        do {
            let n = try strictParse("12x")
            return "parsed \(n)"
        } catch {
            return "rejected: \(error)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("String toolkit")
                .font(.headline)

            TextField("Type words…", text: $input)
                .textFieldStyle(.roundedBorder)

            HStack {
                statChip("\(words.count) words")
                statChip("\(counts.count) unique")
                statChip("longest: \(longest)")
            }

            if repeated.isEmpty {
                Text("No repeated words")
                    .foregroundStyle(.secondary)
            } else {
                Text("Repeated: " + repeated.joined(separator: ", "))
                    .font(.caption)
            }

            Divider()

            Text("42 is " + numberSummary(of: "42"))
            Text("'fox' is " + numberSummary(of: "fox"))
            Text(strictReport)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("stamp: \(todayStamp)")
                .font(.caption2)
                .monospaced()
        }
        .padding()
        .frame(maxWidth: 400)
    }

    func statChip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.teal.opacity(0.15))
            .cornerRadius(6)
    }
}
