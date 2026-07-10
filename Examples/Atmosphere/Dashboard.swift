import SwiftUI

struct AtmosphereDashboard: View {
    var place: Place
    var forecast: Forecast
    var air: AirQuality
    var isNight: Bool
    var usesFahrenheit: Bool

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
                        value: "\(displayTemperature(forecast.current.feelsLike))°",
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

            Text("\(displayTemperature(forecast.current.temperature))°")
                .font(.system(size: 88, weight: .thin))
                .padding(.top, 3)

            Text(conditionName(forecast.current.weatherCode))
                .font(.title3)
            Text("H:\(displayTemperature(forecast.daily.highs.first ?? 0))°  L:\(displayTemperature(forecast.daily.lows.first ?? 0))°")
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
                                Text("\(displayTemperature(forecast.hourly.temperatures[index]))°")
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
                    Text(usesFahrenheit ? "24-HOUR TEMPERATURE • °F" : "24-HOUR TEMPERATURE • °C")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text("\(displayTemperature(forecast.hourly.temperatures.min() ?? 0))° — \(displayTemperature(forecast.hourly.temperatures.max() ?? 0))°")
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

                        Text("\(displayTemperature(forecast.daily.lows[index]))°")
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

                        Text("\(displayTemperature(forecast.daily.highs[index]))°")
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
        let high = forecast.hourly.temperatures.max() ?? forecast.current.temperature
        if rain >= 50 {
            return "Rain is likely during the next 24 hours."
        }
        if rain >= 20 {
            return "There is a chance of rain later today."
        }
        if high > forecast.current.temperature + 2 {
            return "Temperatures will rise to around \(displayTemperature(high))° today."
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
        switch value {
        case 0..<3: return "Low for the current hour."
        case 3..<6: return "Moderate — protection is recommended."
        case 6..<8: return "High — reduce midday exposure."
        default: return "Very high — use extra protection."
        }
    }

    func displayTemperature(_ value: Double) -> Int {
        let converted = usesFahrenheit ? value * 9.0 / 5.0 + 32.0 : value
        return Int(converted.rounded())
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
