import SwiftUI

struct ContentView: View {
    @StateObject private var store = AtmosphereStore()
    @State private var usesFahrenheit = false

    var body: some View {
        ZStack(alignment: .top) {
            atmosphericBackground

            VStack(spacing: 0) {
                searchBar

                if let place = store.place,
                   let forecast = store.forecast,
                   let air = store.air {
                    AtmosphereDashboard(
                        place: place,
                        forecast: forecast,
                        air: air,
                        isNight: currentIsNight,
                        usesFahrenheit: usesFahrenheit
                    )
                } else if store.isLoading {
                    loadingView
                } else {
                    unavailableView
                }
            }
            .foregroundStyle(.white)

                if !store.suggestions.isEmpty {
                    suggestionMenu
                        .padding(.horizontal, 16)
                        .padding(.top, 64)
                        .zIndex(10)
                } else if !store.suggestionMessage.isEmpty {
                    suggestionStatus
                        .padding(.horizontal, 16)
                        .padding(.top, 64)
                        .zIndex(10)
                } else if !store.errorMessage.isEmpty && store.forecast != nil {
                errorBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 64)
                    .zIndex(9)
            }
        }
        .task {
            if store.forecast == nil {
                await store.load()
            }
        }
    }

    var atmosphericBackground: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: backgroundColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill((currentIsNight ? Color.indigo : Color.cyan).opacity(0.25))
                .frame(width: 330, height: 330)
                .blur(radius: 55)
                .offset(x: 125, y: -80)

            Circle()
                .fill(Color.blue.opacity(0.18))
                .frame(width: 260, height: 260)
                .blur(radius: 60)
                .offset(x: -270, y: 470)

            Image(systemName: backgroundSymbol)
                .font(.system(size: 250, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.055))
                .offset(x: 68, y: 90)

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.24)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .onTapGesture {
            store.dismissSuggestions()
        }
    }

    var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.72))

            TextField("Search for a city", text: $store.query)
                .textFieldStyle(.plain)
                .onChange(of: store.query, initial: false) {
                    store.queryChanged()
                }
                .onSubmit {
                    Task { await store.load() }
                }

            if store.isSuggesting {
                ProgressView()
                    .scaleEffect(0.72)
            }

            if store.isLoading {
                ProgressView()
                    .scaleEffect(0.72)
            } else {
                Button {
                    Task { await store.load() }
                } label: {
                    Image(systemName: store.searchActionIcon)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(store.query.count < 2)
            }

            if !store.query.isEmpty {
                Button {
                    store.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.48))
                }
                .buttonStyle(.plain)
            }

            Button {
                usesFahrenheit = !usesFahrenheit
            } label: {
                Text(usesFahrenheit ? "°F" : "°C")
                    .font(.caption)
                    .bold()
                    .frame(width: 27)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: 560)
        .frame(height: 44)
        .background(.regularMaterial)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)
        )
        .shadow(radius: 12, y: 5)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    var suggestionMenu: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CITY SUGGESTIONS")
                    .font(.caption2)
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.58))
                Spacer()
                Button {
                    store.dismissSuggestions()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)

            Divider()
                .opacity(0.16)

            ForEach(store.suggestions) { suggestion in
                Button {
                    store.select(suggestion)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.1))
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(.cyan)
                        }
                        .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.name)
                                .font(.headline)
                            Text(suggestion.subtitle)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.36))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 560)
        .padding(.vertical, 5)
        .background(.regularMaterial)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(radius: 18, y: 8)
        .transition(.opacity)
    }

    var suggestionStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.slash")
                .foregroundStyle(.cyan)
            Text(store.suggestionMessage)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                store.dismissSuggestions()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 560)
        .padding(12)
        .background(.regularMaterial)
        .cornerRadius(16)
        .shadow(radius: 14, y: 6)
    }

    var errorBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(store.errorMessage)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                store.errorMessage = ""
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 560)
        .padding(12)
        .background(.regularMaterial)
        .cornerRadius(16)
        .shadow(radius: 14, y: 6)
    }

    var loadingView: some View {
        VStack(spacing: 13) {
            Image(systemName: backgroundSymbol)
                .font(.system(size: 50, weight: .thin))
                .foregroundStyle(.white.opacity(0.8))
            ProgressView()
            Text("Loading Weather")
                .font(.headline)
            Text("Forecast • air quality • local conditions")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.slash.fill")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(.white.opacity(0.75))
            Text(store.query.isEmpty ? "Search for a City" : "Weather Unavailable")
                .font(.title3)
                .bold()
            Text(store.query.isEmpty ? "Enter a city name above to load its forecast." : store.errorMessage)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await store.load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var currentIsNight: Bool {
        guard let time = store.forecast?.current.time else {
            return false
        }
        let hour = Int(String(time.suffix(5).prefix(2))) ?? 12
        return hour < 6 || hour >= 19
    }

    var backgroundColors: [Color] {
        let code = store.forecast?.current.weatherCode ?? 0
        if currentIsNight {
            switch code {
            case 95...99:
                return [Color.black, Color.purple, Color.indigo]
            case 51...82:
                return [Color.black, Color.indigo, Color.blue.opacity(0.7)]
            default:
                return [Color.black, Color.indigo, Color.blue.opacity(0.68)]
            }
        }

        switch code {
        case 0:
            return [Color.blue, Color.cyan.opacity(0.8), Color.indigo]
        case 1...48:
            return [Color.indigo, Color.blue, Color.gray]
        case 51...82:
            return [Color.indigo, Color.blue.opacity(0.82), Color.black]
        case 95...99:
            return [Color.black, Color.purple, Color.indigo]
        default:
            return [Color.blue, Color.indigo, Color.black]
        }
    }

    var backgroundSymbol: String {
        let code = store.forecast?.current.weatherCode ?? 0
        switch code {
        case 0: return currentIsNight ? "moon.stars.fill" : "sun.max.fill"
        case 1...3: return currentIsNight ? "cloud.moon.fill" : "cloud.sun.fill"
        case 45...48: return "cloud.fog.fill"
        case 51...67: return "cloud.rain.fill"
        case 71...77: return "snowflake"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}
