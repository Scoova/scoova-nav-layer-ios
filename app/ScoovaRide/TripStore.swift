import Foundation

/// One completed trip, kept in History. Small enough that the whole
/// list is stored as a single JSON file, rewritten on each change.
struct TripRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let destination: String
    let distanceKm: Double
    let durationMin: Int
    /// Travel mode display name at the time of the trip ("On foot", "Scooter"…).
    let mode: String
    /// `Profile` id (e.g. "scooter") — drives the persona badge in
    /// History. Optional so records written before this field decode.
    let modeId: String?
    /// Route polyline as `[lat, lon]` pairs — drawn as a thumbnail.
    let route: [[Double]]

    init(
        id: UUID = UUID(),
        date: Date,
        destination: String,
        distanceKm: Double,
        durationMin: Int,
        mode: String,
        modeId: String? = nil,
        route: [[Double]]
    ) {
        self.id = id
        self.date = date
        self.destination = destination
        self.distanceKm = distanceKm
        self.durationMin = durationMin
        self.mode = mode
        self.modeId = modeId
        self.route = route
    }
}

/// JSON-file persistence for the trip history — one file in Documents,
/// rewritten whole on each change. The list stays short, so this is
/// simpler and more robust than a database.
enum TripStore {
    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        return docs.appendingPathComponent("scoova-trips.json")
    }

    static func load() -> [TripRecord] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let trips = try? JSONDecoder().decode([TripRecord].self, from: data)
        else { return [] }
        return trips
    }

    static func save(_ trips: [TripRecord]) {
        guard let data = try? JSONEncoder().encode(trips) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
