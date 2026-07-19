struct FilterItem {
    let value: Int
    let accepted: Bool
}

struct FilterRule {
    let divisor: Int

    func validate(_ item: FilterItem) -> Bool {
        item.value % divisor == 0
    }
}

struct HarbourCargo {
    let marker: String
}

struct HarbourOther {
    let marker: String
}

extension Array where Element == FilterItem {
    func filter(_ rules: [FilterRule]) -> [FilterItem] {
        self.filter { item in
            rules.allSatisfy { rule in
                rule.validate(item)
            }
        }
    }
}

extension [HarbourCargo] {
    func filter(_ query: String) -> Self {
        [HarbourCargo(marker: "cargo:\(query)")]
    }
}

extension [HarbourOther] {
    func filter(_ query: String) -> Self {
        [HarbourOther(marker: "other:\(query)")]
    }
}

func sourceImportedArrayFilterOverloadOutput() async -> String {
    await Task.yield()

    let items = [
        FilterItem(value: 2, accepted: true),
        FilterItem(value: 3, accepted: false),
        FilterItem(value: 6, accepted: true),
        FilterItem(value: 12, accepted: true),
    ]
    let rules = [FilterRule(divisor: 2), FilterRule(divisor: 3)]
    let selected = items.filter(rules)
    let accepted = items.filter(\.accepted)
    let selectedOutput = selected.map { String($0.value) }
        .joined(separator: ",")
    let acceptedOutput = accepted.map { String($0.value) }
        .joined(separator: ",")
    let emptyCargo: [HarbourCargo] = []
    let cargoOutput = emptyCargo.filter { _ in true }
        .filter("harbour")
        .map(\.marker)
        .joined(separator: ",")
    return "\(selectedOutput)|\(acceptedOutput)|\(cargoOutput)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await sourceImportedArrayFilterOverloadOutput()
}
