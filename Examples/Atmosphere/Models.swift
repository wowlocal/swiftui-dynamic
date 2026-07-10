import Foundation

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
