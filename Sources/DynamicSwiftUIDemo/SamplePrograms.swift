struct SampleProgram: Identifiable, Hashable {
    let name: String
    let source: String
    var id: String { name }
}

enum SamplePrograms {
    static let all = [atmosphere, counter, calculator, tictactoe, todoMVVM, form, weather, staticLayout, list, segments, material, popup, albums]

    /// A three-request, real-network app: city geocoding feeds weather and
    /// air-quality endpoints. It exercises actors, async/await, generic
    /// Codable decoding, URLComponents, custom Shape drawing, observable
    /// models, task-driven loading, and a non-trivial responsive SwiftUI UI.
    static let atmosphere = SampleProgram(name: "Atmosphere", source: #"""
    struct Place: Codable, Identifiable {
        let id: Int
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
        let admin1: String?
        let timezone: String

        var subtitle: String {
            if let admin1, let country {
                return "\(admin1), \(country)"
            }
            return country ?? timezone
        }
    }

    struct PlaceResponse: Codable {
        let results: [Place]
    }

    struct CurrentWeather: Codable {
        let time: String
        let temperature: Double
        let feelsLike: Double
        let humidity: Int
        let weatherCode: Int
        let windSpeed: Double

        enum CodingKeys: String, CodingKey {
            case time
            case temperature = "temperature_2m"
            case feelsLike = "apparent_temperature"
            case humidity = "relative_humidity_2m"
            case weatherCode = "weather_code"
            case windSpeed = "wind_speed_10m"
        }
    }

    struct HourlyWeather: Codable {
        let time: [String]
        let temperatures: [Double]
        let rainChance: [Int]
        let weatherCodes: [Int]

        enum CodingKeys: String, CodingKey {
            case time
            case temperatures = "temperature_2m"
            case rainChance = "precipitation_probability"
            case weatherCodes = "weather_code"
        }
    }

    struct DailyWeather: Codable {
        let time: [String]
        let weatherCodes: [Int]
        let highs: [Double]
        let lows: [Double]
        let sunrise: [String]
        let sunset: [String]

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCodes = "weather_code"
            case highs = "temperature_2m_max"
            case lows = "temperature_2m_min"
            case sunrise
            case sunset
        }
    }

    struct Forecast: Codable {
        let timezone: String
        let current: CurrentWeather
        let hourly: HourlyWeather
        let daily: DailyWeather
    }

    struct CurrentAir: Codable {
        let aqi: Int
        let particles: Double
        let uvIndex: Double

        enum CodingKeys: String, CodingKey {
            case aqi = "european_aqi"
            case particles = "pm2_5"
            case uvIndex = "uv_index"
        }
    }

    struct AirQuality: Codable {
        let current: CurrentAir
    }

    struct AtmosphereSnapshot {
        let place: Place
        let forecast: Forecast
        let air: AirQuality
    }

    enum AtmosphereError: Error {
        case invalidURL
        case placeNotFound
        case server(Int)
    }

    actor AtmosphereClient {
        private let decoder = JSONDecoder()

        init() {
            decoder.keyDecodingStrategy = .convertFromSnakeCase
        }

        private func makeURL(host: String, path: String, query: [URLQueryItem]) throws -> URL {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = path
            components.queryItems = query
            guard let url = components.url else {
                throw AtmosphereError.invalidURL
            }
            return url
        }

        private func request<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
            let (data, response) = try await URLSession.shared.data(from: url)
            if response.statusCode < 200 || response.statusCode >= 300 {
                throw AtmosphereError.server(response.statusCode)
            }
            return try decoder.decode(T.self, from: data)
        }

        func suggestions(for search: String) async throws -> [Place] {
            let url = try makeURL(
                host: "geocoding-api.open-meteo.com",
                path: "/v1/search",
                query: [
                    URLQueryItem(name: "name", value: search),
                    URLQueryItem(name: "count", value: "6"),
                    URLQueryItem(name: "language", value: "en"),
                    URLQueryItem(name: "format", value: "json"),
                ]
            )
            let response: PlaceResponse = try await request(PlaceResponse.self, from: url)
            return response.results
        }

        private func find(_ search: String) async throws -> Place {
            guard let place = try await suggestions(for: search).first else {
                throw AtmosphereError.placeNotFound
            }
            return place
        }

        private func weather(for place: Place) async throws -> Forecast {
            let url = try makeURL(
                host: "api.open-meteo.com",
                path: "/v1/forecast",
                query: [
                    URLQueryItem(name: "latitude", value: String(place.latitude)),
                    URLQueryItem(name: "longitude", value: String(place.longitude)),
                    URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"),
                    URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
                    URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"),
                    URLQueryItem(name: "timezone", value: "auto"),
                    URLQueryItem(name: "forecast_days", value: "10"),
                    URLQueryItem(name: "forecast_hours", value: "24"),
                ]
            )
            return try await request(Forecast.self, from: url)
        }

        private func airQuality(for place: Place) async throws -> AirQuality {
            let url = try makeURL(
                host: "air-quality-api.open-meteo.com",
                path: "/v1/air-quality",
                query: [
                    URLQueryItem(name: "latitude", value: String(place.latitude)),
                    URLQueryItem(name: "longitude", value: String(place.longitude)),
                    URLQueryItem(name: "current", value: "european_aqi,pm2_5,uv_index"),
                    URLQueryItem(name: "timezone", value: "auto"),
                ]
            )
            return try await request(AirQuality.self, from: url)
        }

        func snapshot(for search: String) async throws -> AtmosphereSnapshot {
            let place = try await find(search)
            return try await snapshotForPlace(place)
        }

        func snapshotForPlace(_ place: Place) async throws -> AtmosphereSnapshot {
            let forecast = try await weather(for: place)
            let air = try await airQuality(for: place)
            return AtmosphereSnapshot(place: place, forecast: forecast, air: air)
        }
    }

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

    struct TemperatureCurve: Shape {
        var values: [Double]

        func path(in rect: CGRect) -> Path {
            Path { path in
                if values.count > 1 {
                    let low = values.min() ?? 0
                    let high = values.max() ?? 1
                    let spread = max(1.0, high - low)
                    for index in values.indices {
                        let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
                        let ratio = (values[index] - low) / spread
                        let y = rect.maxY - rect.height * CGFloat(ratio)
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
            }
        }
    }

    struct SunArc: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addQuadCurve(
                    to: CGPoint(x: rect.maxX, y: rect.maxY),
                    control: CGPoint(x: rect.midX, y: rect.minY)
                )
            }
        }
    }

    struct WeatherPanel<Content: View>: View {
        @ViewBuilder var content: Content

        var body: some View {
            content
                .padding(16)
                .background(.ultraThinMaterial)
                .cornerRadius(22)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        }
    }

    struct WeatherSectionHeader: View {
        var icon: String
        var title: String

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title.uppercased())
                    .tracking(0.5)
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.62))
        }
    }

    struct WeatherMetricTile: View {
        var icon: String
        var title: String
        var value: String
        var detail: String

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                WeatherSectionHeader(icon: icon, title: title)
                Text(value)
                    .font(.system(size: 28, weight: .regular))
                    .monospaced()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(16)
            .background(.ultraThinMaterial)
            .cornerRadius(22)
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
    }

    struct AQIRing: View {
        var air: CurrentAir

        var body: some View {
            WeatherPanel {
                VStack(alignment: .leading, spacing: 13) {
                    WeatherSectionHeader(icon: "aqi.medium", title: "Air Quality")

                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.12), lineWidth: 8)
                            Circle()
                                .trim(from: 0, to: min(1.0, Double(air.aqi) / 100.0))
                                .stroke(aqiColor(air.aqi), lineWidth: 8)
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 0) {
                                Text("\(air.aqi)")
                                    .font(.title2)
                                    .bold()
                                    .monospaced()
                                Text("EAQI")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.58))
                            }
                        }
                        .frame(width: 82, height: 82)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(aqiLabel(air.aqi))
                                .font(.title3)
                                .bold()
                            Text(aqiDescription(air.aqi))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                            Text("PM2.5  \(String(format: "%.1f", air.particles)) µg/m³")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                    }
                }
            }
        }

        func aqiLabel(_ value: Int) -> String {
            switch value {
            case 0..<20: return "Good"
            case 20..<40: return "Fair"
            case 40..<60: return "Moderate"
            case 60..<80: return "Poor"
            default: return "Very poor"
            }
        }

        func aqiDescription(_ value: Int) -> String {
            switch value {
            case 0..<20: return "Air quality is ideal for outdoor activity."
            case 20..<40: return "Air quality is acceptable for most people."
            case 40..<60: return "Sensitive people may notice mild effects."
            case 60..<80: return "Consider reducing prolonged outdoor activity."
            default: return "Limit outdoor activity when possible."
            }
        }

        func aqiColor(_ value: Int) -> Color {
            switch value {
            case 0..<20: return Color.green
            case 20..<40: return Color.mint
            case 40..<60: return Color.yellow
            case 60..<80: return Color.orange
            default: return Color.red
            }
        }
    }

    struct AtmosphereDashboard: View {
        var place: Place
        var forecast: Forecast
        var air: AirQuality
        var isNight: Bool

        var body: some View {
            ScrollView {
                VStack(spacing: 12) {
                    hero
                    hourlyForecast
                    dailyForecast

                    HStack(alignment: .top, spacing: 12) {
                        WeatherMetricTile(
                            icon: "thermometer.medium",
                            title: "Feels Like",
                            value: "\(Int(forecast.current.feelsLike.rounded()))°",
                            detail: feelsLikeDetail
                        )
                        WeatherMetricTile(
                            icon: "humidity.fill",
                            title: "Humidity",
                            value: "\(forecast.current.humidity)%",
                            detail: "Relative humidity at the latest observation."
                        )
                    }

                    HStack(alignment: .top, spacing: 12) {
                        WeatherMetricTile(
                            icon: "wind",
                            title: "Wind",
                            value: "\(String(format: "%.1f", forecast.current.windSpeed))",
                            detail: "Kilometres per hour at the surface."
                        )
                        WeatherMetricTile(
                            icon: "sun.max.fill",
                            title: "UV Index",
                            value: String(format: "%.1f", air.current.uvIndex),
                            detail: uvDescription(air.current.uvIndex)
                        )
                    }

                    AQIRing(air: air.current)
                    sunCard

                    Text("Weather by Open-Meteo • Air quality by CAMS")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.48))
                        .padding(.vertical, 8)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
        }

        var hero: some View {
            VStack(spacing: 4) {
                Text(place.name)
                    .font(.title2)
                    .bold()
                Text(place.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))

                Text("\(Int(forecast.current.temperature.rounded()))°")
                    .font(.system(size: 88, weight: .thin))
                    .padding(.top, 3)

                Text(conditionName(forecast.current.weatherCode))
                    .font(.title3)
                Text("H:\(Int(forecast.daily.highs.first ?? 0))°  L:\(Int(forecast.daily.lows.first ?? 0))°")
                    .font(.headline)

                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text("Updated \(updatedTime(forecast.current.time))")
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.56))
                .padding(.top, 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
            .padding(.bottom, 22)
        }

        var hourlyForecast: some View {
            WeatherPanel {
                VStack(alignment: .leading, spacing: 12) {
                    WeatherSectionHeader(icon: "clock", title: "Hourly Forecast")

                    Text(hourlyNarrative)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))

                    Divider()
                        .opacity(0.18)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 15) {
                            ForEach(0..<min(12, forecast.hourly.time.count / 2)) { position in
                                let index = position * 2
                                VStack(spacing: 7) {
                                    Text(hourLabel(forecast.hourly.time[index], position: position))
                                        .font(.caption)
                                        .bold()
                                    Image(systemName: weatherIcon(
                                        forecast.hourly.weatherCodes[index],
                                        night: night(at: forecast.hourly.time[index])
                                    ))
                                    .font(.title3)
                                    .foregroundStyle(weatherTint(
                                        forecast.hourly.weatherCodes[index],
                                        night: night(at: forecast.hourly.time[index])
                                    ))
                                    Text("\(Int(forecast.hourly.temperatures[index].rounded()))°")
                                        .font(.headline)
                                    if forecast.hourly.rainChance[index] > 0 {
                                        Text("\(forecast.hourly.rainChance[index])%")
                                            .font(.caption2)
                                            .foregroundStyle(.cyan)
                                    } else {
                                        Text(" ")
                                            .font(.caption2)
                                    }
                                }
                                .frame(width: 48)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    Divider()
                        .opacity(0.18)

                    HStack {
                        Text("24-HOUR TEMPERATURE")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Text("\(Int(forecast.hourly.temperatures.min() ?? 0))° — \(Int(forecast.hourly.temperatures.max() ?? 0))°")
                            .font(.caption)
                            .monospaced()
                    }

                    ZStack {
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.2), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        TemperatureCurve(values: forecast.hourly.temperatures)
                            .stroke(Color.white.opacity(0.88), lineWidth: 2)
                            .padding(.vertical, 7)
                    }
                    .frame(height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }

        var dailyForecast: some View {
            WeatherPanel {
                VStack(spacing: 0) {
                    WeatherSectionHeader(
                        icon: "calendar",
                        title: "\(forecast.daily.time.count)-Day Forecast"
                    )
                    .padding(.bottom, 8)

                    ForEach(forecast.daily.time.indices) { index in
                        HStack(spacing: 9) {
                            Text(dayLabel(forecast.daily.time[index], index: index))
                                .font(.subheadline)
                                .frame(width: 68, alignment: .leading)

                            Image(systemName: weatherIcon(forecast.daily.weatherCodes[index], night: false))
                                .foregroundStyle(weatherTint(forecast.daily.weatherCodes[index], night: false))
                                .frame(width: 28)

                            Spacer()

                            Text("\(Int(forecast.daily.lows[index].rounded()))°")
                                .foregroundStyle(.white.opacity(0.54))
                                .monospaced()
                                .frame(width: 34, alignment: .trailing)

                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.14))
                                    .frame(width: 58, height: 5)
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.cyan, Color.yellow],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: rangeWidth(index), height: 5)
                                    .offset(x: rangeOffset(index))
                            }
                            .frame(width: 58)

                            Text("\(Int(forecast.daily.highs[index].rounded()))°")
                                .monospaced()
                                .frame(width: 34, alignment: .trailing)
                        }
                        .padding(.vertical, 10)

                        if index < forecast.daily.time.count - 1 {
                            Divider()
                                .opacity(0.16)
                        }
                    }

                    HStack {
                        Spacer()
                        Text(forecast.timezone)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    .padding(.top, 8)
                }
            }
        }

        var sunCard: some View {
            WeatherPanel {
                VStack(alignment: .leading, spacing: 12) {
                    WeatherSectionHeader(icon: "sunrise.fill", title: "Sun")

                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sunrise")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                            Text(clockTime(forecast.daily.sunrise.first ?? ""))
                                .font(.title3)
                                .bold()
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Sunset")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                            Text(clockTime(forecast.daily.sunset.first ?? ""))
                                .font(.title3)
                                .bold()
                        }
                    }

                    GeometryReader { proxy in
                        let progress = sunProgress()
                        let x = 9 + (proxy.size.width - 18) * CGFloat(progress)
                        let heightRatio = 4.0 * progress * (1.0 - progress)
                        let y = proxy.size.height - 8 - (proxy.size.height - 16) * CGFloat(heightRatio)

                        SunArc()
                            .stroke(Color.white.opacity(0.28), lineWidth: 1)
                            .padding(.horizontal, 7)
                        Image(systemName: isNight ? "moon.fill" : "sun.max.fill")
                            .foregroundStyle(isNight ? Color.white : Color.yellow)
                            .position(x: x, y: y)
                    }
                    .frame(height: 62)
                }
            }
        }

        var hourlyNarrative: String {
            let rain = forecast.hourly.rainChance.max() ?? 0
            let high = Int((forecast.hourly.temperatures.max() ?? forecast.current.temperature).rounded())
            if rain >= 50 {
                return "Rain is likely during the next 24 hours."
            }
            if rain >= 20 {
                return "There is a chance of rain later today."
            }
            if high > Int(forecast.current.temperature.rounded()) + 2 {
                return "Temperatures will rise to around \(high)° today."
            }
            return "\(conditionName(forecast.current.weatherCode)) conditions will continue for the next several hours."
        }

        var feelsLikeDetail: String {
            let difference = forecast.current.feelsLike - forecast.current.temperature
            if difference > 1.5 {
                return "It feels warmer than the actual temperature."
            }
            if difference < -1.5 {
                return "It feels cooler than the actual temperature."
            }
            return "Similar to the actual temperature."
        }

        func weatherIcon(_ code: Int, night: Bool) -> String {
            switch code {
            case 0: return night ? "moon.stars.fill" : "sun.max.fill"
            case 1...3: return night ? "cloud.moon.fill" : "cloud.sun.fill"
            case 45...48: return "cloud.fog.fill"
            case 51...67: return "cloud.rain.fill"
            case 71...77: return "snowflake"
            case 80...82: return "cloud.heavyrain.fill"
            case 95...99: return "cloud.bolt.rain.fill"
            default: return "cloud.fill"
            }
        }

        func weatherTint(_ code: Int, night: Bool) -> Color {
            switch code {
            case 0: return night ? Color.white : Color.yellow
            case 1...3: return night ? Color.white : Color.yellow
            case 71...77: return Color.white
            default: return Color.cyan
            }
        }

        func conditionName(_ code: Int) -> String {
            switch code {
            case 0: return "Clear"
            case 1...3: return "Partly Cloudy"
            case 45...48: return "Fog"
            case 51...67: return "Rain"
            case 71...77: return "Snow"
            case 80...82: return "Showers"
            case 95...99: return "Thunderstorms"
            default: return "Cloudy"
            }
        }

        func night(at value: String) -> Bool {
            let hour = Int(String(value.suffix(5).prefix(2))) ?? 12
            return hour < 6 || hour >= 19
        }

        func hourLabel(_ value: String, position: Int) -> String {
            if position == 0 {
                return "Now"
            }
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
            guard let date = parser.date(from: value) else {
                return String(value.suffix(5))
            }
            parser.dateFormat = "ha"
            return parser.string(from: date)
        }

        func dayLabel(_ value: String, index: Int) -> String {
            if index == 0 {
                return "Today"
            }
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            guard let date = parser.date(from: value) else {
                return String(value.suffix(5))
            }
            parser.dateFormat = "EEE"
            return parser.string(from: date)
        }

        func updatedTime(_ value: String) -> String {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
            guard let date = parser.date(from: value) else {
                return String(value.suffix(5))
            }
            parser.dateFormat = "h:mm a"
            return parser.string(from: date)
        }

        func clockTime(_ value: String) -> String {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
            guard let date = parser.date(from: value) else {
                return String(value.suffix(5))
            }
            parser.dateFormat = "h:mm a"
            return parser.string(from: date)
        }

        func uvDescription(_ value: Double) -> String {
            if value < 3 {
                return "Low for the current hour."
            }
            if value < 6 {
                return "Moderate — protection is recommended."
            }
            if value < 8 {
                return "High — reduce midday exposure."
            }
            return "Very high — use extra protection."
        }

        func rangeOffset(_ index: Int) -> CGFloat {
            let floor = forecast.daily.lows.min() ?? 0
            let ceiling = forecast.daily.highs.max() ?? 1
            let spread = max(1.0, ceiling - floor)
            return CGFloat((forecast.daily.lows[index] - floor) / spread) * 58
        }

        func rangeWidth(_ index: Int) -> CGFloat {
            let floor = forecast.daily.lows.min() ?? 0
            let ceiling = forecast.daily.highs.max() ?? 1
            let spread = max(1.0, ceiling - floor)
            let width = CGFloat((forecast.daily.highs[index] - forecast.daily.lows[index]) / spread) * 58
            return max(7, width)
        }

        func minutes(_ value: String) -> Double {
            let clock = String(value.suffix(5))
            let hour = Double(String(clock.prefix(2))) ?? 0
            let minute = Double(String(clock.suffix(2))) ?? 0
            return hour * 60 + minute
        }

        func sunProgress() -> Double {
            let current = minutes(forecast.current.time)
            let sunrise = minutes(forecast.daily.sunrise.first ?? "06:00")
            let sunset = minutes(forecast.daily.sunset.first ?? "18:00")
            let daylight = max(1.0, sunset - sunrise)
            return min(1.0, max(0.0, (current - sunrise) / daylight))
        }
    }

    struct ContentView: View {
        @StateObject private var store = AtmosphereStore()

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
                            isNight: currentIsNight
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

                if store.isLoading || store.isSuggesting {
                    ProgressView()
                        .scaleEffect(0.72)
                } else {
                    Button {
                        Task { await store.load() }
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.query.count < 2)
                }
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
                Text("Weather Unavailable")
                    .font(.title3)
                    .bold()
                Text(store.errorMessage)
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
    """#)

    /// A real view-model app: ObservableObject store shared by three views.
    static let todoMVVM = SampleProgram(name: "Todo", source: """
    struct Todo {
        var title = ""
        var done = false
    }

    class TodoStore: ObservableObject {
        @Published var todos: [Todo] = [
            Todo(title: "Interpret Swift", done: true),
            Todo(title: "Render SwiftUI", done: true),
            Todo(title: "Run real projects"),
        ]
        @Published var newTitle = ""

        var remaining: Int {
            todos.filter { !$0.done }.count
        }

        func add() {
            let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                return
            }
            todos.append(Todo(title: trimmed))
            newTitle = ""
        }

        func toggle(at index: Int) {
            guard index < todos.count else {
                return
            }
            let item = todos[index]
            item.done = !item.done
            todos[index] = item
        }

        func remove(at index: Int) {
            guard index < todos.count else {
                return
            }
            todos.remove(at: index)
        }
    }

    struct AddBar: View {
        @ObservedObject var store: TodoStore

        var body: some View {
            HStack {
                TextField("What needs doing?", text: $store.newTitle)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    store.add()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.newTitle.isEmpty)
            }
        }
    }

    struct ContentView: View {
        @StateObject var store = TodoStore()

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Todos (MVVM)")
                    .font(.title2)
                    .bold()

                AddBar(store: store)

                VStack(spacing: 6) {
                    ForEach(store.todos.indices) { i in
                        HStack {
                            Button(store.todos[i].done ? "☑" : "☐") {
                                store.toggle(at: i)
                            }
                            .buttonStyle(.plain)
                            Text(store.todos[i].title)
                                .opacity(store.todos[i].done ? 0.4 : 1.0)
                            Spacer()
                            Button("✕") {
                                store.remove(at: i)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }

                Divider()

                Text("\\(store.remaining) of \\(store.todos.count) remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 360)
        }
    }
    """)

    /// Enums with methods, switch in bodies, gradients, shapes, nested views.
    static let weather = SampleProgram(name: "Weather", source: """
    enum Condition: String, CaseIterable {
        case sunny
        case cloudy
        case rainy
        case snowy

        var icon: String {
            switch self {
            case .sunny: return "sun.max.fill"
            case .cloudy: return "cloud.fill"
            case .rainy: return "cloud.rain.fill"
            case .snowy: return "snowflake"
            }
        }
    }

    struct Forecast {
        var day = ""
        var condition: Condition = .sunny
        var high = 0
        var low = 0
    }

    struct ForecastRow: View {
        var forecast = Forecast()

        var body: some View {
            HStack {
                Text(forecast.day)
                    .frame(width: 44, alignment: .leading)
                Image(systemName: forecast.condition.icon)
                Spacer()
                Text("\\(forecast.low)°")
                    .foregroundStyle(.white.opacity(0.7))
                Text("\\(forecast.high)°")
                    .bold()
            }
            .font(.system(size: 14))
        }
    }

    struct ContentView: View {
        @State var selected: Condition = .sunny

        let week = [
            Forecast(day: "Mon", condition: .sunny, high: 28, low: 17),
            Forecast(day: "Tue", condition: .cloudy, high: 24, low: 16),
            Forecast(day: "Wed", condition: .rainy, high: 19, low: 12),
            Forecast(day: "Thu", condition: .snowy, high: 2, low: -3),
        ]

        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: selected.icon)
                    .font(.system(size: 56))
                Text(selected.rawValue.capitalized)
                    .font(.title)
                    .bold()

                HStack(spacing: 8) {
                    ForEach(Condition.allCases, id: \\.self) { condition in
                        Button {
                            selected = condition
                        } label: {
                            Image(systemName: condition.icon)
                        }
                        .buttonStyle(.plain)
                        .opacity(condition == selected ? 1.0 : 0.5)
                    }
                }

                Divider()

                VStack(spacing: 6) {
                    ForEach(week, id: \\.day) { forecast in
                        ForecastRow(forecast: forecast)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
            .cornerRadius(20)
            .shadow(radius: 12, y: 6)
            .frame(maxWidth: 320)
        }
    }
    """)

    /// The acceptance demo: @State + Button actions with live re-render.
    static let counter = SampleProgram(name: "Counter", source: """
    struct ContentView: View {
        @State var count = 0

        var body: some View {
            VStack(spacing: 16) {
                Text("Count: \\(count)")
                    .font(.largeTitle)
                HStack(spacing: 12) {
                    Button("-") {
                        count -= 1
                    }
                    Button("+") {
                        count += 1
                    }
                }
                if count >= 10 {
                    Text("That's a lot of taps.")
                        .foregroundStyle(.orange)
                }
            }
            .padding()
        }
    }
    """)

    /// Two-way bindings: $state projections driving Toggle/Slider/TextField.
    static let form = SampleProgram(name: "Form", source: """
    struct ContentView: View {
        @State var name = ""
        @State var notify = true
        @State var volume = 5

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings")
                    .font(.headline)
                TextField("Your name", text: $name)
                Toggle("Notifications", isOn: $notify)
                HStack {
                    Text("Volume: \\(volume)")
                    Slider(value: $volume, in: 0...10)
                }
                Divider()
                Text("Hi \\(name)! Notifications \\(notify ? "on" : "off"), volume \\(volume).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 340)
        }
    }
    """)

    static let staticLayout = SampleProgram(name: "Layout", source: """
    struct ContentView: View {
        let tags = ["COBOL", "UNIVAC", "Compilers"]

        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                Text("Grace Hopper")
                    .font(.title)
                    .bold()
                Text("Rear admiral, computer scientist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                HStack(spacing: 8) {
                    ForEach(tags, id: \\.self) { tag in
                        Text(tag)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(8)
                    }
                }
                .font(.caption)
            }
            .padding(24)
            .frame(maxWidth: 320)
        }
    }
    """)

    /// Real-world code from the sample-projects corpus: Kavsoft's
    /// AnimatedSegmentedControl — a generic view with a @ViewBuilder closure
    /// property, GeometryReader indicator math, and completion-chained
    /// withAnimation. Adapted for the bridge: the preference-based initial
    /// indicator offset is dropped (the indicator starts on the first tab
    /// anyway) and the iOS-only `.toolbarBackground(for: .navigationBar)`
    /// is removed.
    static let segments = SampleProgram(name: "Segments", source: #"""
    enum SegmentedTab: String, CaseIterable {
        case home = "house.fill"
        case favourites = "suit.heart.fill"
        case notifications = "bell.fill"
        case profile = "person.fill"
    }

    struct SegmentedControl<Indicator: View>: View {
        var tabs: [SegmentedTab]
        @Binding var activeTab: SegmentedTab
        var height: CGFloat = 45
        /// Customization Properties
        var displayAsText: Bool = false
        var font: Font = .title3
        var activeTint: Color
        var inActiveTint: Color
        /// Indicator View
        @ViewBuilder var indicatorView: (CGSize) -> Indicator
        /// View Properties
        @State private var excessTabWidth: CGFloat = .zero
        @State private var minX: CGFloat = .zero
        var body: some View {
            GeometryReader {
                let size = $0.size
                let containerWidthForEachTab = size.width / CGFloat(tabs.count)

                HStack(spacing: 0) {
                    ForEach(tabs, id: \.rawValue) { tab in
                        Group {
                            if displayAsText {
                                Text(tab.rawValue)
                            } else {
                                Image(systemName: tab.rawValue)
                            }
                        }
                        .font(font)
                        .foregroundStyle(activeTab == tab ? activeTint : inActiveTint)
                        .animation(.snappy, value: activeTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.rect)
                        .onTapGesture {
                            if let index = tabs.firstIndex(of: tab), let activeIndex = tabs.firstIndex(of: activeTab) {
                                activeTab = tab

                                withAnimation(.snappy(duration: 0.25, extraBounce: 0), completionCriteria: .logicallyComplete) {
                                    excessTabWidth = containerWidthForEachTab * CGFloat(index - activeIndex)
                                } completion: {
                                    withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
                                        minX = containerWidthForEachTab * CGFloat(index)
                                        excessTabWidth = 0
                                    }
                                }
                            }
                        }
                        .background(alignment: .leading) {
                            if tabs.first == tab {
                                GeometryReader {
                                    let size = $0.size

                                    indicatorView(size)
                                        .frame(width: size.width + (excessTabWidth < 0 ? -excessTabWidth : excessTabWidth), height: size.height)
                                        .frame(width: size.width, alignment: excessTabWidth < 0 ? .trailing : .leading)
                                        .offset(x: minX)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: height)
        }
    }

    struct ContentView: View {
        /// View Properties
        @State private var activeTab: SegmentedTab = .home
        @State private var type2: Bool = false
        var body: some View {
            NavigationStack {
                VStack(spacing: 15) {
                    SegmentedControl(
                        tabs: SegmentedTab.allCases,
                        activeTab: $activeTab,
                        height: 35,
                        font: .body,
                        activeTint: type2 ? .white : .primary,
                        inActiveTint: .gray.opacity(0.5)
                    ) { size in
                        RoundedRectangle(cornerRadius: type2 ? 30 : 0)
                            .fill(.blue)
                            .frame(height: type2 ? size.height : 4)
                            .padding(.horizontal, type2 ? 0 : 10)
                            .offset(y: type2 ? 0 : 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .padding(.top, type2 ? 0 : 10)
                    .background {
                        RoundedRectangle(cornerRadius: type2 ? 30 : 0)
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea()
                    }
                    .padding(.horizontal, type2 ? 15 : 0)

                    Toggle("Segmented Control Type - 2", isOn: $type2)
                        .padding(10)
                        .background(.regularMaterial, in: .rect(cornerRadius: 10))
                        .padding(15)

                    Spacer(minLength: 0)
                }
                .padding(.vertical, type2 ? 15 : 0)
                .animation(.snappy, value: type2)
                .navigationTitle("Segmented Control")
            }
        }
    }
    """#)

    /// Real-world code from the sample-projects corpus: Kavsoft's MaterialTF —
    /// a floating-label material text field whose ObservableObject manager
    /// drives the character counter. Verbatim except for headers/previews.
    static let material = SampleProgram(name: "Material", source: #"""
    struct ContentView: View {
        var body: some View {

            NavigationView{

                Home()
                    .navigationTitle("Material Design")
            }
        }
    }

    struct Home: View {

        @StateObject var manager = TFManager()
        // Animation Properites...
        @State var isTapped = false

        var body: some View{

            VStack{

                VStack(alignment: .leading, spacing: 4, content: {

                    HStack(spacing: 15){

                        // were going to limit the textfiled length....

                        TextField("", text: $manager.text) { (status) in
                            // it will fire when textfield is clicked...
                            if status{
                                withAnimation(.easeIn){
                                    // moving hint to top..
                                    isTapped = true
                                }
                            }
                        } onCommit: {
                            // it will fire when return button is pressed...
                            // only if no text typed..
                            if manager.text == ""{
                                withAnimation(.easeOut){
                                    isTapped = false
                                }
                            }
                        }

                        // Trailing Icon Or Button...

                        Button(action: {}, label: {
                            Image(systemName: "suit.heart")
                                .foregroundColor(.gray)
                        })
                    }
                    // if tapped...
                    .padding(.top,isTapped ? 15 : 0)
                    // overlay will avoid clicking the textfiled...
                    // so moving it below the textfield..
                    .background(

                        Text("UserName")
                            .scaleEffect(isTapped ? 0.8 : 1)
                            .offset(x: isTapped ? -7 : 0, y: isTapped ? -15 : 0)
                            .foregroundColor(isTapped ? .accentColor : .gray)


                        ,alignment: .leading
                    )
                    .padding(.horizontal)

                    // Divider Color...
                    Rectangle()
                        .fill(isTapped ? Color.accentColor : Color.gray)
                        .opacity(isTapped ? 1 : 0.5)
                        .frame(height: 1)
                        .padding(.top,10)
                })
                .padding(.top,12)
                .background(Color.gray.opacity(0.09))
                .cornerRadius(5)

                // Displaying Count...
                HStack{

                    Spacer()

                    Text("\(manager.text.count)/15")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.trailing)
                        .padding(.top,4)
                }
            }
            .padding()
        }
    }

    class TFManager: ObservableObject{

        @Published var text = ""{
            // were going to use didSet Function before assigning the new value...
            // so that we can check the count...
            didSet{
                if text.count > 15 && oldValue.count <= 15{
                    text = oldValue
                }
            }
        }
    }
    """#)

    /// Real-world code from the sample-projects corpus: Kavsoft's
    /// PopUpNavigation — a custom popup built with an `.overlay` extension on
    /// View, hosting a NavigationView with pushable links over a dimmed
    /// backdrop. Adapted for the bridge: the iOS-only keyboard toolbar and
    /// `navigationBarTitleDisplayMode` are dropped; the toolbar Close button
    /// moved below the list.
    static let popup = SampleProgram(name: "Popup", source: #"""
    // MARK: Task Model
    struct Task: Identifiable{
        var id = UUID().uuidString
        var taskTitle: String
        var taskDescription: String
    }

    // MARK: Sample Tasks
    var tasks: [Task] = [

        Task(taskTitle: "Meeting", taskDescription: "Discuss team task for the day"),
        Task(taskTitle: "Icon set", taskDescription: "Edit icons for team task for next week"),
        Task(taskTitle: "Prototype", taskDescription: "Make and send prototype"),
        Task(taskTitle: "Check asset", taskDescription: "Start checking the assets"),
        Task(taskTitle: "Team party", taskDescription: "Make fun with team mates"),
        Task(taskTitle: "Client Meeting", taskDescription: "Explain project to clinet"),

        Task(taskTitle: "Next Project", taskDescription: "Discuss next project with team"),
        Task(taskTitle: "App Proposal", taskDescription: "Meet client for next App Proposal"),
    ]

    // MARK: Custom View Property Extensions
    extension View{

        // MARK: Building a Custom Modifier for Custom Popup navigation View
        func popupNavigationView<Content: View>(horizontalPadding: CGFloat = 40,show: Binding<Bool>,@ViewBuilder content: @escaping ()->Content)->some View{

            return self
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .overlay {

                    if show.wrappedValue{

                        // MARK: Geometry Reader for reading Container Frame
                        GeometryReader{proxy in

                            Color.primary
                                .opacity(0.15)
                                .ignoresSafeArea()

                            let size = proxy.size

                            NavigationView{
                                content()
                            }
                            .frame(width: size.width - horizontalPadding, height: size.height / 1.7, alignment: .center)
                            // Corner Radius
                            .cornerRadius(15)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }
                    }
                }
        }
    }

    struct Home: View {
        @State var showPopup: Bool = false
        var body: some View {

            NavigationView{

                Button("Show Popup"){
                    withAnimation{
                        showPopup.toggle()
                    }
                }
                .navigationTitle("Custom Popup's")
            }
            .popupNavigationView(horizontalPadding: 40, show: $showPopup) {

                // MARK: Your Popup content which will also performs navigations
                VStack(spacing: 0){
                    List{
                        ForEach(tasks){task in
                            NavigationLink(task.taskTitle) {
                                Text(task.taskDescription)
                                    .navigationTitle("Destination")
                            }
                        }
                    }

                    Divider()

                    Button("Close"){
                        withAnimation{showPopup.toggle()}
                    }
                    .padding(.vertical, 10)
                }
                .navigationTitle("Popup Navigation")
            }
        }
    }
    """#)

    /// Real-world code from the sample-projects corpus: Kavsoft's "Filled"
    /// album list — cards scale and fade as they scroll under the header,
    /// driven by nested GeometryReaders. Adapted for the bridge: deprecated
    /// `edgesIgnoringSafeArea` modernized to `ignoresSafeArea`, and the
    /// bundled cover art (unavailable here) replaced with a tinted
    /// system-image tile.
    static let albums = SampleProgram(name: "Albums", source: #"""
    struct Home : View {

        var body: some View{

            VStack(spacing: 0){

                HStack{

                    Text("Album Songs")
                        .font(.system(size: 40))
                        .fontWeight(.bold)
                        .foregroundColor(.black)

                    Spacer(minLength: 0)
                }
                .padding()
                // since top edge is ignored....
                .padding(.top,UIApplication.shared.windows.first?.safeAreaInsets.top)
                .background(Color.white.shadow(color: Color.black.opacity(0.18), radius: 5, x: 0, y: 5))
                .zIndex(0)
                // moving view in stack for shadow effect...

                // Scaling Effect....

                GeometryReader{mainView in

                    ScrollView{

                        VStack(spacing: 15){

                            // setting name as id...

                            ForEach(albums,id: \.album_name){album in

                                // Album View....

                                GeometryReader{item in

                                    AlbumView(album: album)
                                        // scaling effect from bottom....
                                        .scaleEffect(scaleValue(mainFrame: mainView.frame(in: .global).minY, minY: item.frame(in: .global).minY),anchor: .bottom)
                                    // adding opacity effect...
                                        .opacity(Double(scaleValue(mainFrame: mainView.frame(in: .global).minY, minY: item.frame(in: .global).minY)))
                                }
                                // setting default frame height...
                                // since each card height is 100...
                                .frame(height: 100)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top,25)
                    }
                    .zIndex(1)
                }
            }
            .background(Color.black.opacity(0.06).ignoresSafeArea())
            .ignoresSafeArea(edges: .top)
        }

        // Simple Calculation for scaling Effect...

        func scaleValue(mainFrame : CGFloat,minY : CGFloat)-> CGFloat{

            // adding animation...

            withAnimation(.easeOut){

                // reducing top padding value...

                let scale = (minY - 25) / mainFrame

                // retuning scaling value to Album View if its less than 1...

                if scale > 1{

                    return 1
                }
                else{

                    return scale
                }
            }
        }
    }

    struct AlbumView : View {

        var album : Album

        var body: some View{

            HStack{

                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                    .frame(width: 100, height: 100)
                    .background(Color.indigo.opacity(0.75))
                    .cornerRadius(15)

                VStack(alignment: .leading, spacing: 12) {

                    Text(album.album_name)
                        .fontWeight(.bold)

                    Text(album.album_author)
                }
                .padding(.leading,10)

                Spacer(minLength: 0)
            }
            .background(Color.white.shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 4))
            .cornerRadius(15)
        }
    }

    // Sample Data....

    struct Album{

        var album_name : String
        var album_author : String
        var album_cover : String
    }

    var albums = [

        Album(album_name: "Let Her Go", album_author: "Passenger", album_cover: "p1"),
        Album(album_name: "Bad Blood", album_author: "Taylor Swift", album_cover: "p2"),
        Album(album_name: "Believer", album_author: "Kurt Hugo Schneider", album_cover: "p3"),
        Album(album_name: "Let Me Love You", album_author: "DJ Snake", album_cover: "p4"),
        Album(album_name: "Shape Of You", album_author: "Ed Sherran", album_cover: "p5"),
        Album(album_name: "Blank Space", album_author: "Taylor Swift", album_cover: "p6"),
        Album(album_name: "Havana", album_author: "Camila Cabello", album_cover: "p7"),
        Album(album_name: "Red", album_author: "Taylor Swift", album_cover: "p8"),
        Album(album_name: "I Like It", album_author: "J Balvin", album_cover: "p9"),
        Album(album_name: "Lover", album_author: "Taylor Swift", album_cover: "p10"),
        Album(album_name: "7/27 Harmony", album_author: "Camila Cabello", album_cover: "p11"),
        Album(album_name: "Joanne", album_author: "Lady Gaga", album_cover: "p12"),
        Album(album_name: "Roar", album_author: "Kay Perry", album_cover: "p13"),
        Album(album_name: "My Church", album_author: "Maren Morris", album_cover: "p14"),
        Album(album_name: "Part Of Me", album_author: "Katy Perry", album_cover: "p15"),
    ]
    """#)

    static let list = SampleProgram(name: "List", source: """
    struct Row: View {
        var name = ""
        var index = 0

        var body: some View {
            HStack {
                Image(systemName: "person")
                Text(name)
                Spacer()
                Text("#\\(index)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    struct ContentView: View {
        let names = ["Ada Lovelace", "Grace Hopper", "Katherine Johnson", "Margaret Hamilton"]

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pioneers")
                    .font(.headline)
                Divider()
                ForEach(0..<names.count) { i in
                    Row(name: names[i], index: i + 1)
                }
            }
            .padding()
            .frame(maxWidth: 320)
        }
    }
    """)

    /// iOS-style calculator: an immediate-execution state machine (chained
    /// operators, operator replacement, repeat-equals, percent, sign toggle,
    /// divide-by-zero -> Error) — logic-heavy, not just layout.
    static let calculator = SampleProgram(name: "Calculator", source: #"""
    class CalcEngine: ObservableObject {
        @Published var display = "0"
        @Published var activeOp: String? = nil
        var accumulator: Double? = nil
        var pendingOp: String? = nil
        var typing = false
        var lastOp: String? = nil
        var lastOperand: Double? = nil

        func tap(_ key: String) {
            switch key {
            case "AC":
                clear()
            case "±":
                negate()
            case "%":
                percent()
            case "+", "−", "×", "÷":
                operate(key)
            case "=":
                equals()
            case ".":
                dot()
            default:
                digit(key)
            }
        }

        func clear() {
            display = "0"
            accumulator = nil
            pendingOp = nil
            activeOp = nil
            typing = false
            lastOp = nil
            lastOperand = nil
        }

        func digit(_ d: String) {
            if display == "Error" {
                clear()
            }
            if typing {
                if display.count >= 12 {
                    return
                }
                display = display == "0" ? d : display + d
            } else {
                display = d
                typing = true
            }
            activeOp = nil
        }

        func dot() {
            if display == "Error" {
                clear()
            }
            if !typing {
                display = "0."
                typing = true
            } else if !display.contains(".") {
                display = display + "."
            }
            activeOp = nil
        }

        func negate() {
            if display == "Error" || display == "0" {
                return
            }
            if display.hasPrefix("-") {
                display = String(display.dropFirst())
            } else {
                display = "-" + display
            }
        }

        func percent() {
            if display == "Error" {
                return
            }
            display = format(value() / 100)
            typing = false
        }

        func operate(_ op: String) {
            if display == "Error" {
                return
            }
            if !typing && pendingOp != nil {
                pendingOp = op
                activeOp = op
                return
            }
            commit()
            pendingOp = op
            activeOp = op
            typing = false
        }

        func equals() {
            if display == "Error" {
                return
            }
            if let op = pendingOp {
                lastOp = op
                lastOperand = value()
                commit()
                pendingOp = nil
                activeOp = nil
                typing = false
            } else if let op = lastOp, let operand = lastOperand {
                apply(op, value(), operand)
                typing = false
            }
        }

        func commit() {
            let current = value()
            if let a = accumulator, let op = pendingOp {
                apply(op, a, current)
            } else {
                accumulator = current
            }
        }

        func apply(_ op: String, _ a: Double, _ b: Double) {
            if op == "÷" && b == 0 {
                display = "Error"
                accumulator = nil
                pendingOp = nil
                activeOp = nil
                typing = false
                return
            }
            var result = 0.0
            switch op {
            case "+":
                result = a + b
            case "−":
                result = a - b
            case "×":
                result = a * b
            default:
                result = a / b
            }
            accumulator = result
            display = format(result)
        }

        /// Current display as a number; tolerates a trailing "." while typing.
        func value() -> Double {
            Double(display) ?? (Double(display + "0") ?? 0)
        }

        func format(_ number: Double) -> String {
            String(format: "%.10g", number)
        }
    }

    struct CalcKey: View {
        var label: String
        var background: Color
        var foreground = Color.white
        var wide = false
        var action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 28, weight: .medium))
                    .frame(width: wide ? 148 : 68, height: 68)
                    .background(background)
                    .foregroundColor(foreground)
                    .cornerRadius(34)
            }
            .buttonStyle(.plain)
        }
    }

    struct ContentView: View {
        @StateObject var engine = CalcEngine()

        let dark = Color.gray.opacity(0.4)
        let light = Color.gray

        var body: some View {
            VStack(spacing: 12) {
                Text(engine.display)
                    .font(.system(size: 56, weight: .light))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 8)
                HStack(spacing: 12) {
                    CalcKey(label: "AC", background: light, foreground: .black) { engine.tap("AC") }
                    CalcKey(label: "±", background: light, foreground: .black) { engine.tap("±") }
                    CalcKey(label: "%", background: light, foreground: .black) { engine.tap("%") }
                    opKey("÷")
                }
                HStack(spacing: 12) {
                    digitKey("7")
                    digitKey("8")
                    digitKey("9")
                    opKey("×")
                }
                HStack(spacing: 12) {
                    digitKey("4")
                    digitKey("5")
                    digitKey("6")
                    opKey("−")
                }
                HStack(spacing: 12) {
                    digitKey("1")
                    digitKey("2")
                    digitKey("3")
                    opKey("+")
                }
                HStack(spacing: 12) {
                    CalcKey(label: "0", background: dark, wide: true) { engine.tap("0") }
                    digitKey(".")
                    opKey("=")
                }
            }
            .padding(20)
            .background(Color.black)
            .cornerRadius(32)
        }

        func digitKey(_ d: String) -> some View {
            CalcKey(label: d, background: dark) { engine.tap(d) }
        }

        func opKey(_ op: String) -> some View {
            CalcKey(
                label: op,
                background: engine.activeOp == op ? Color.white : Color.orange,
                foreground: engine.activeOp == op ? Color.orange : Color.white
            ) { engine.tap(op) }
        }
    }
    """#)

    /// Tic-tac-toe against a rule-based AI (take the win, block the threat,
    /// center, corners, sides) with win/draw detection and line highlighting.
    static let tictactoe = SampleProgram(name: "Tic-Tac-Toe", source: #"""
    class TicTacToe: ObservableObject {
        @Published var board = ["", "", "", "", "", "", "", "", ""]
        @Published var status = "Your move — you are X"
        @Published var winningLine: [Int] = []
        var gameOver = false

        let lines = [
            [0, 1, 2], [3, 4, 5], [6, 7, 8],
            [0, 3, 6], [1, 4, 7], [2, 5, 8],
            [0, 4, 8], [2, 4, 6],
        ]

        func tap(_ index: Int) {
            if gameOver || !board[index].isEmpty {
                return
            }
            board[index] = "X"
            if settle() {
                return
            }
            aiMove()
            _ = settle()
        }

        func aiMove() {
            let move = bestMove()
            if move >= 0 {
                board[move] = "O"
            }
        }

        func bestMove() -> Int {
            if let winning = completingMove(for: "O") {
                return winning
            }
            if let block = completingMove(for: "X") {
                return block
            }
            if board[4].isEmpty {
                return 4
            }
            for corner in [0, 2, 6, 8] {
                if board[corner].isEmpty {
                    return corner
                }
            }
            for index in 0..<9 {
                if board[index].isEmpty {
                    return index
                }
            }
            return -1
        }

        func completingMove(for player: String) -> Int? {
            for line in lines {
                var owned = 0
                var empty = -1
                for index in line {
                    if board[index] == player {
                        owned += 1
                    }
                    if board[index].isEmpty {
                        empty = index
                    }
                }
                if owned == 2 && empty >= 0 {
                    return empty
                }
            }
            return nil
        }

        func settle() -> Bool {
            for line in lines {
                let mark = board[line[0]]
                if !mark.isEmpty && mark == board[line[1]] && mark == board[line[2]] {
                    winningLine = line
                    status = mark == "X" ? "You win!" : "The machine wins"
                    gameOver = true
                    return true
                }
            }
            if !board.contains("") {
                status = "Draw"
                gameOver = true
                return true
            }
            return false
        }

        func reset() {
            board = ["", "", "", "", "", "", "", "", ""]
            status = "Your move — you are X"
            winningLine = []
            gameOver = false
        }
    }

    struct ContentView: View {
        @StateObject var game = TicTacToe()

        var body: some View {
            VStack(spacing: 16) {
                Text("Tic-Tac-Toe")
                    .font(.title2)
                    .bold()
                Text(game.status)
                    .foregroundColor(.secondary)
                VStack(spacing: 8) {
                    ForEach(0..<3) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<3) { column in
                                cell(row * 3 + column)
                            }
                        }
                    }
                }
                Button("New game") {
                    game.reset()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }

        func cell(_ index: Int) -> some View {
            Button {
                game.tap(index)
            } label: {
                Text(game.board[index])
                    .font(.system(size: 34, weight: .bold))
                    .frame(width: 72, height: 72)
                    .background(game.winningLine.contains(index) ? Color.green.opacity(0.35) : Color.gray.opacity(0.15))
                    .foregroundColor(game.board[index] == "X" ? .blue : .red)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
    }
    """#)
}
