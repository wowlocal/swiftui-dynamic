import SwiftUI

@MainActor
final class AtmosphereStore: ObservableObject {
    @Published var query = "Lisbon"
    @Published var place: Place? = nil
    @Published var forecast: Forecast? = nil
    @Published var air: AirQuality? = nil
    @Published var suggestions: [Place] = []
    @Published var isLoading = false
    @Published var isSuggesting = false
    @Published var suggestionMessage = ""
    @Published var errorMessage = ""

    private let client = AtmosphereClient()
    private var suggestionGeneration = 0
    private var loadGeneration = 0
    private var committedQuery = "Lisbon"

    var searchActionIcon: String {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if search == committedQuery && forecast != nil {
            return "arrow.clockwise.circle.fill"
        }
        return "arrow.right.circle.fill"
    }

    func queryChanged() {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestionGeneration += 1
        let generation = suggestionGeneration
        suggestionMessage = ""

        guard search.count >= 2 && search != committedQuery else {
            suggestions = []
            isSuggesting = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard generation == suggestionGeneration else { return }
            Task {
                await fetchSuggestions(search, generation: generation)
            }
        }
    }

    private func fetchSuggestions(_ search: String, generation: Int) async {
        guard generation == suggestionGeneration else { return }
        isSuggesting = true
        suggestionMessage = ""
        do {
            let matches = try await client.suggestions(for: search)
            if generation == suggestionGeneration {
                suggestions = matches
                if matches.isEmpty {
                    suggestionMessage = "No matching cities found."
                }
            }
        } catch {
            if generation == suggestionGeneration {
                suggestions = []
                suggestionMessage = "Suggestions are unavailable. Press Return to search."
            }
        }
        if generation == suggestionGeneration {
            isSuggesting = false
        }
    }

    func load() async {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard search.count >= 2 else {
            errorMessage = "Enter at least two characters."
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        suggestionGeneration += 1
        suggestions = []
        isSuggesting = false
        suggestionMessage = ""
        errorMessage = ""
        do {
            let snapshot = try await client.snapshot(for: search)
            if generation == loadGeneration {
                apply(snapshot)
                committedQuery = search
            }
        } catch {
            if generation == loadGeneration {
                errorMessage = "Could not load live atmosphere data: \(error.localizedDescription)"
            }
        }
        if generation == loadGeneration {
            isLoading = false
        }
    }

    func select(_ selected: Place) {
        suggestionGeneration += 1
        loadGeneration += 1
        let generation = loadGeneration
        committedQuery = selected.name
        query = selected.name
        suggestions = []
        isSuggesting = false
        suggestionMessage = ""
        Task {
            await loadSelected(selected, generation: generation)
        }
    }

    func dismissSuggestions() {
        suggestionGeneration += 1
        suggestions = []
        isSuggesting = false
        suggestionMessage = ""
    }

    func clearSearch() {
        loadGeneration += 1
        isLoading = false
        query = ""
        dismissSuggestions()
        errorMessage = ""
    }

    private func loadSelected(_ selected: Place, generation: Int) async {
        isLoading = true
        errorMessage = ""
        do {
            let snapshot = try await client.snapshotForPlace(selected)
            if generation == loadGeneration {
                apply(snapshot)
            }
        } catch {
            if generation == loadGeneration {
                errorMessage = "Could not load live atmosphere data: \(error.localizedDescription)"
            }
        }
        if generation == loadGeneration {
            isLoading = false
        }
    }

    private func apply(_ snapshot: AtmosphereSnapshot) {
        place = snapshot.place
        forecast = snapshot.forecast
        air = snapshot.air
    }
}
