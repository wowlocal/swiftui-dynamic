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
    @Published var errorMessage = ""

    private let client = AtmosphereClient()
    private var suggestionGeneration = 0
    private var committedQuery = "Lisbon"

    func queryChanged() {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestionGeneration += 1
        let generation = suggestionGeneration

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
        do {
            let matches = try await client.suggestions(for: search)
            if generation == suggestionGeneration {
                suggestions = matches
            }
        } catch {
            if generation == suggestionGeneration {
                suggestions = []
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

        isLoading = true
        suggestionGeneration += 1
        suggestions = []
        isSuggesting = false
        errorMessage = ""
        do {
            let snapshot = try await client.snapshot(for: search)
            apply(snapshot)
            committedQuery = search
        } catch {
            errorMessage = "Could not load live atmosphere data: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func select(_ selected: Place) {
        suggestionGeneration += 1
        committedQuery = selected.name
        query = selected.name
        suggestions = []
        isSuggesting = false
        Task {
            await loadSelected(selected)
        }
    }

    private func loadSelected(_ selected: Place) async {
        isLoading = true
        errorMessage = ""
        do {
            let snapshot = try await client.snapshotForPlace(selected)
            apply(snapshot)
        } catch {
            errorMessage = "Could not load live atmosphere data: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func apply(_ snapshot: AtmosphereSnapshot) {
        place = snapshot.place
        forecast = snapshot.forecast
        air = snapshot.air
    }
}
