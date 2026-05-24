import Foundation

/// A language Scoova ships dialect-correct voice cues for.
struct LocaleOption: Identifiable {
    let tag: String
    let display: String
    var id: String { tag }
}

/// Every tag here is a locale the routing server actually renders cue
/// copy for (`scoova-copy.json`). Arabic is a single `ar` entry —
/// formal MSA, spoken by on-device TTS. The Egyptian / Gulf / Levantine
/// / Maghrebi dialect blocks still exist server-side but currently all
/// resolve to MSA, so exposing them as separate picker rows would be a
/// lie. Egyptian gets its own picker entry back when its voice pack
/// ships as a user-facing option.
let scoovaLocales: [LocaleOption] = [
    LocaleOption(tag: "en-US", display: "English"),
    LocaleOption(tag: "ar",    display: "العربية"),
    LocaleOption(tag: "fr",    display: "Français"),
    LocaleOption(tag: "es",    display: "Español"),
    LocaleOption(tag: "de",    display: "Deutsch"),
    LocaleOption(tag: "it",    display: "Italiano"),
    LocaleOption(tag: "pt-BR", display: "Português"),
    LocaleOption(tag: "nl",    display: "Nederlands"),
]

/// Collapse any persisted Arabic dialect tag (`ar-EG`, `ar-SA`, …) to
/// the single `ar` entry — keeps a returning rider whose saved locale
/// is no longer a picker row from landing on a blank selection.
func normalizedLocaleTag(_ tag: String) -> String {
    tag.lowercased().hasPrefix("ar") ? "ar" : tag
}

/// A rider-pinned place — Home, Work, or a saved spot.
struct SavedPlace: Codable, Equatable {
    var label: String
    var lat: Double
    var lon: Double
}

/// User-level settings persisted across launches. Mirrors the Android
/// demo's `RideSettings`.
struct RideSettings: Codable, Equatable {
    var unitsMetric: Bool = true
    var locale: String = "en-US"
    var voiceEnabled: Bool = true
    var spatialAudio: Bool = true
    var homePlace: SavedPlace? = nil
    var workPlace: SavedPlace? = nil

    /// Eyes-on-the-road navigation. When true the routing server emits
    /// landmark-led voice cues ("After the mosque, turn right") instead
    /// of distance-led ones, so the rider never has to glance at the
    /// phone. Default ON — it is the core of what Scoova does; riders
    /// who prefer distance copy can switch it off in Settings.
    var eyesOff: Bool = true

    /// First-launch flag — gates the onboarding tour.
    var onboardingDone: Bool = false

    /// Master switch for trip history. When true (default), each
    /// finished trip is saved to History — its route, distance and
    /// time. When false, Scoova is navigation-only: nothing is logged.
    /// Turning it off stops new recording; it does not erase past trips.
    var recordRides: Bool = true
}

/// UserDefaults-backed persistence for `RideSettings`. The whole struct
/// is stored as one JSON blob under a single key — simple, atomic, and
/// trivially forward-compatible as fields are added.
enum SettingsStore {
    private static let key = "scoova.ride.settings.v1"

    static func load() -> RideSettings {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode(RideSettings.self, from: data)
        else {
            return RideSettings(locale: deviceLocaleDefault())
        }
        // Migrate a persisted Arabic dialect tag to the single `ar`
        // entry — the dialect rows are no longer in the picker.
        var migrated = decoded
        migrated.locale = normalizedLocaleTag(decoded.locale)
        return migrated
    }

    static func save(_ settings: RideSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Pick the closest Scoova-shipped locale to the device language.
    private static func deviceLocaleDefault() -> String {
        let sys = Locale.preferredLanguages.first ?? "en-US"
        if let exact = scoovaLocales.first(where: { $0.tag.caseInsensitiveCompare(sys) == .orderedSame }) {
            return exact.tag
        }
        let base = String(sys.prefix(while: { $0 != "-" })).lowercased()
        if let match = scoovaLocales.first(where: { $0.tag == base }) {
            return match.tag
        }
        return "en-US"
    }
}
