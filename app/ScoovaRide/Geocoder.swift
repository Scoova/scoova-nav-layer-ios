import Foundation
import CoreLocation

/// A place the rider can route to — one Pelias autocomplete result.
struct PlaceSuggestion: Identifiable, Equatable {
    let id = UUID()
    /// Short place name — "Bryant Park".
    let name: String
    /// Area context for the second line — "Midtown, NY". Nil if none.
    let context: String?
    /// Straight-line distance from the rider, km. Pelias computes this
    /// from the `focus.point` we send — nil if no fix / not returned.
    let distanceKm: Double?
    let coordinate: CLLocationCoordinate2D

    static func == (a: PlaceSuggestion, b: PlaceSuggestion) -> Bool { a.id == b.id }
}

/// Search against Scoova's Pelias geocoder, through the keyed gateway
/// (`api.scoo-va.info/api/v1/autocomplete`). Best-effort: any failure
/// returns an empty list so the search bar just shows no results.
enum ScoovaGeocoder {
    /// Returns the matches, `[]` for "searched, nothing found", or
    /// `nil` for "the request failed" — so the UI can tell a genuinely
    /// empty result from a network outage.
    static func autocomplete(
        _ text: String,
        focus: CLLocationCoordinate2D?,
        lang: String = "en-US"
    ) async -> [PlaceSuggestion]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var comps = URLComponents(string: "\(ScoovaAPI.gateway)/autocomplete")!
        var items = [
            URLQueryItem(name: "text", value: trimmed),
            URLQueryItem(name: "size", value: "8"),
            // Localise results to the rider's voice language.
            URLQueryItem(name: "lang", value: String(lang.prefix(2))),
        ]
        // `focus.point` biases results toward the rider *and* makes
        // Pelias return `properties.distance` (km) on every result.
        if let focus = focus {
            items.append(URLQueryItem(name: "focus.point.lat", value: String(focus.latitude)))
            items.append(URLQueryItem(name: "focus.point.lon", value: String(focus.longitude)))
        }
        comps.queryItems = items

        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue(ScoovaAPI.key, forHTTPHeaderField: "X-API-Key")
        // Network / HTTP failure → nil ("search unavailable"). A 200
        // we just can't read → [] (treat as no matches).
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]]
        else { return [] }

        return features.compactMap { feature -> PlaceSuggestion? in
            guard let props = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let coords = geometry["coordinates"] as? [Double], coords.count == 2
            else { return nil }

            // Prefer the short `name`; fall back to the full label.
            let name = (props["name"] as? String)
                ?? (props["label"] as? String) ?? ""
            guard !name.isEmpty else { return nil }

            // Second line — the street address for a venue, else the
            // neighbourhood / locality + region for an area result.
            let context: String?
            if let street = props["street"] as? String, !street.isEmpty {
                if let house = props["housenumber"] as? String, !house.isEmpty {
                    context = "\(house) \(street)"
                } else {
                    context = street
                }
            } else {
                let area = (props["neighbourhood"] as? String)
                    ?? (props["locality"] as? String)
                    ?? (props["county"] as? String)
                let region = (props["region_a"] as? String) ?? (props["region"] as? String)
                let joined = [area, region].compactMap { $0 }.joined(separator: ", ")
                context = joined.isEmpty ? nil : joined
            }

            return PlaceSuggestion(
                name: name,
                context: context,
                distanceKm: props["distance"] as? Double,
                coordinate: CLLocationCoordinate2D(latitude: coords[1], longitude: coords[0])
            )
        }
    }
}
