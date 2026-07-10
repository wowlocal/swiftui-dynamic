import Foundation

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
