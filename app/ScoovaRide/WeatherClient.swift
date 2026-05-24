import Foundation
import CoreLocation

/// One forecast row — an hour or a day ahead.
struct WeatherForecastPoint: Equatable, Identifiable {
    /// Start of the hour (hourly) or the day (daily).
    let time: Date
    /// Hourly: the temperature that hour. Daily: the day's HIGH.
    let temperatureC: Double
    /// Daily only — the day's low. nil for hourly rows.
    let lowC: Double?
    /// Coarse condition bucket — same vocabulary as `WeatherSnapshot`.
    let condition: String
    /// Chance of precipitation, 0–100. nil when the feed didn't carry it.
    let precipitationPct: Int?

    var id: Date { time }

    var iconName: String { WeatherSnapshot.icon(for: condition) }
}

/// Weather at the rider's location — the realtime reading plus the
/// hourly and daily forecast. The chip shows `current`; tapping it
/// opens the forecast.
struct WeatherSnapshot: Equatable {
    // ── Realtime ──────────────────────────────────────────────────
    let temperatureC: Double
    let condition: String
    /// Hourly + daily forecast. Empty when the feed only returned the
    /// current reading (older server, or a trimmed request).
    let hourly: [WeatherForecastPoint]
    let daily: [WeatherForecastPoint]

    /// SF Symbol for a coarse condition bucket — an SF Symbol, not an
    /// emoji, so it renders reliably everywhere (emoji tofu to "?" on
    /// simulator runtimes that lack the colour-emoji font).
    static func icon(for condition: String) -> String {
        switch condition {
        case "clear":           return "sun.max.fill"
        case "partly_cloudy":   return "cloud.sun.fill"
        case "clouds":          return "cloud.fill"
        case "fog":             return "cloud.fog.fill"
        case "drizzle", "rain": return "cloud.rain.fill"
        case "snow":            return "snowflake"
        case "thunderstorm":    return "cloud.bolt.rain.fill"
        default:                return "cloud.sun.fill"
        }
    }

    var iconName: String { Self.icon(for: condition) }

    func temperatureText(metric: Bool) -> String {
        Self.tempText(temperatureC, metric: metric)
    }

    /// Shared temperature formatter — used by the chip and every
    /// forecast row so the unit handling never drifts between them.
    static func tempText(_ celsius: Double, metric: Bool) -> String {
        metric
            ? "\(Int(celsius.rounded()))°"
            : "\(Int((celsius * 9 / 5 + 32).rounded()))°"
    }
}

/// Thin client over Scoova's Open-Meteo-compatible weather endpoint,
/// through the keyed gateway (`api.scoo-va.info/api/v1/weather`).
/// Best-effort — failures return nil.
enum ScoovaWeather {

    /// Fetch realtime + forecast in a single request. The Scoova
    /// weather service is Open-Meteo-compatible, so `current`,
    /// `hourly` and `daily` all come back from one call — the gateway
    /// forwards every query param straight through. No extra round-trips.
    static func fetch(_ coord: CLLocationCoordinate2D) async -> WeatherSnapshot? {
        var comps = URLComponents(string: "\(ScoovaAPI.gateway)/weather")!
        comps.queryItems = [
            URLQueryItem(name: "latitude",  value: String(coord.latitude)),
            URLQueryItem(name: "longitude", value: String(coord.longitude)),
            URLQueryItem(name: "current",   value: "temperature_2m,weathercode"),
            URLQueryItem(name: "hourly",
                         value: "temperature_2m,weathercode,precipitation_probability"),
            URLQueryItem(name: "daily",
                         value: "temperature_2m_max,temperature_2m_min,weathercode"),
            URLQueryItem(name: "forecast_days", value: "3"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(ScoovaAPI.key, forHTTPHeaderField: "X-API-Key")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let temp = current["temperature_2m"] as? Double
        else { return nil }
        let code = (current["weathercode"] as? Int) ?? -1

        return WeatherSnapshot(
            temperatureC: temp,
            condition: wmoCondition(code),
            hourly: parseHourly(json["hourly"] as? [String: Any]),
            daily:  parseDaily(json["daily"] as? [String: Any])
        )
    }

    /// Legacy name kept so older call sites still compile. Prefer
    /// ``fetch(_:)`` — it carries the forecast.
    static func now(_ coord: CLLocationCoordinate2D) async -> WeatherSnapshot? {
        await fetch(coord)
    }

    // ── Parsing ───────────────────────────────────────────────────

    /// Open-Meteo returns column-oriented arrays — `time[]`,
    /// `temperature_2m[]`, … all index-aligned. Zip them into rows.
    /// The hourly feed starts at midnight; trim to the next 12 hours
    /// from now so the panel stays glanceable.
    private static func parseHourly(_ h: [String: Any]?) -> [WeatherForecastPoint] {
        guard let h,
              let times = h["time"] as? [String],
              let temps = h["temperature_2m"] as? [Double]
        else { return [] }
        let codes = h["weathercode"] as? [Int] ?? []
        let pops  = h["precipitation_probability"] as? [Int] ?? []
        let now = Date()
        var out: [WeatherForecastPoint] = []
        for i in times.indices where i < temps.count {
            guard let t = isoHour.date(from: times[i]) else { continue }
            // Keep the current hour through the next 12.
            if t < now.addingTimeInterval(-3600) { continue }
            if out.count >= 12 { break }
            out.append(WeatherForecastPoint(
                time: t,
                temperatureC: temps[i],
                lowC: nil,
                condition: wmoCondition(i < codes.count ? codes[i] : -1),
                precipitationPct: i < pops.count ? pops[i] : nil))
        }
        return out
    }

    private static func parseDaily(_ d: [String: Any]?) -> [WeatherForecastPoint] {
        guard let d,
              let times = d["time"] as? [String],
              let highs = d["temperature_2m_max"] as? [Double],
              let lows  = d["temperature_2m_min"] as? [Double]
        else { return [] }
        let codes = d["weathercode"] as? [Int] ?? []
        var out: [WeatherForecastPoint] = []
        for i in times.indices where i < highs.count && i < lows.count {
            guard let t = isoDay.date(from: times[i]) else { continue }
            out.append(WeatherForecastPoint(
                time: t,
                temperatureC: highs[i],
                lowC: lows[i],
                condition: wmoCondition(i < codes.count ? codes[i] : -1),
                precipitationPct: nil))
        }
        return out
    }

    private static let isoHour: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func wmoCondition(_ code: Int) -> String {
        switch code {
        case 0:                                  return "clear"
        case 1, 2:                               return "partly_cloudy"
        case 3:                                  return "clouds"
        case 45, 48:                             return "fog"
        case 51, 53, 55, 56, 57:                 return "drizzle"
        case 61, 63, 65, 66, 67, 80, 81, 82:     return "rain"
        case 71, 73, 75, 77, 85, 86:             return "snow"
        case 95, 96, 99:                         return "thunderstorm"
        default:                                 return "unknown"
        }
    }
}
