import SwiftUI

/// Weather sheet — the realtime reading at the top, then the hourly
/// strip (next 12 h) and the daily rows (next 3 days). Opened by
/// tapping the weather chip on the Plan screen.
struct WeatherForecastView: View {
    let weather: WeatherSnapshot
    let metric: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                nowBlock
                if !weather.hourly.isEmpty { hourlySection }
                if !weather.daily.isEmpty { dailySection }
                if weather.hourly.isEmpty && weather.daily.isEmpty {
                    Text("Forecast unavailable right now.")
                        .font(.system(size: 13))
                        .foregroundColor(RideTokens.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 30)
                }
            }
            .padding(20)
        }
        .background(RideTokens.bg.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(RideTokens.textMuted)
                    .padding(16)
            }
            .buttonStyle(.plain)
        }
    }

    // ── Realtime ──────────────────────────────────────────────────
    private var nowBlock: some View {
        HStack(spacing: 14) {
            Image(systemName: weather.iconName)
                .font(.system(size: 44))
                .foregroundColor(RideTokens.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(WeatherSnapshot.tempText(weather.temperatureC, metric: metric))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(RideTokens.text)
                Text(conditionLabel(weather.condition))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(RideTokens.textMuted)
                Text("Right now")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(RideTokens.muted)
            }
            Spacer()
        }
        .padding(.top, 14)
    }

    // ── Hourly ────────────────────────────────────────────────────
    private var hourlySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("NEXT 12 HOURS")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(weather.hourly) { p in
                        VStack(spacing: 6) {
                            Text(hourLabel(p.time))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(RideTokens.textMuted)
                            Image(systemName: p.iconName)
                                .font(.system(size: 17))
                                .foregroundColor(RideTokens.accent)
                            Text(WeatherSnapshot.tempText(p.temperatureC, metric: metric))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(RideTokens.text)
                            // Precipitation chance — only when meaningful
                            // (> 0), so a dry strip stays uncluttered.
                            if let pop = p.precipitationPct, pop > 0 {
                                Text("\(pop)%")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(RideTokens.accentSoft)
                            } else {
                                Text(" ").font(.system(size: 10))
                            }
                        }
                        .frame(width: 50)
                    }
                }
            }
        }
    }

    // ── Daily ─────────────────────────────────────────────────────
    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("NEXT 3 DAYS")
            VStack(spacing: 0) {
                ForEach(Array(weather.daily.enumerated()), id: \.element.id) { idx, p in
                    HStack {
                        Text(dayLabel(p.time, isFirst: idx == 0))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(RideTokens.text)
                            .frame(width: 96, alignment: .leading)
                        Image(systemName: p.iconName)
                            .font(.system(size: 16))
                            .foregroundColor(RideTokens.accent)
                            .frame(width: 30)
                        Spacer()
                        if let low = p.lowC {
                            Text(WeatherSnapshot.tempText(low, metric: metric))
                                .font(.system(size: 14))
                                .foregroundColor(RideTokens.textMuted)
                        }
                        Text(WeatherSnapshot.tempText(p.temperatureC, metric: metric))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(RideTokens.text)
                            .frame(width: 46, alignment: .trailing)
                    }
                    .padding(.vertical, 12)
                    if idx < weather.daily.count - 1 {
                        Divider().overlay(RideTokens.border)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(RideTokens.surface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // ── Bits ──────────────────────────────────────────────────────
    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(RideTokens.muted)
            .tracking(0.6)
    }

    private func conditionLabel(_ c: String) -> String {
        switch c {
        case "clear":         return "Clear"
        case "partly_cloudy": return "Partly cloudy"
        case "clouds":        return "Cloudy"
        case "fog":           return "Fog"
        case "drizzle":       return "Drizzle"
        case "rain":          return "Rain"
        case "snow":          return "Snow"
        case "thunderstorm":  return "Thunderstorm"
        default:              return "—"
        }
    }

    private func hourLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(d, equalTo: Date(), toGranularity: .hour) { return "Now" }
        let f = DateFormatter()
        f.dateFormat = "ha"          // "3PM"
        return f.string(from: d).lowercased()
    }

    private func dayLabel(_ d: Date, isFirst: Bool) -> String {
        if isFirst { return "Today" }
        let f = DateFormatter()
        f.dateFormat = "EEEE"        // "Tuesday"
        return f.string(from: d)
    }
}
