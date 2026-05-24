import Foundation
import ScoovaNavLayerCore

public struct LatLon: Sendable, Equatable, Codable {
    public let lat: Double
    public let lon: Double
    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// Use Scoova's routing API together with **any** map display (MapKit,
/// Mapbox iOS, MapLibre, your in-house renderer). No host nav SDK required.
///
/// ```swift
/// let nav = ScoovaNavLayer.builder()
///     .apiKey("sk_live_…").locale("ar-EG").profile("scooter").build()
/// nav.start()
///
/// let routing = ScoovaRoutingAdapter(apiKey: "sk_live_…", layer: nav)
/// let shape = try await routing.startRoute(
///     from: LatLon(lat: 30.0444, lon: 31.2357),
///     to:   LatLon(lat: 30.0626, lon: 31.2497),
///     profile: "scooter", language: "ar-EG", landmarks: true
/// )
/// // shape is [[lat, lon], …] — draw on your map.
/// ```
public final class ScoovaRoutingAdapter: @unchecked Sendable {
    private let apiKey: String
    private let layer: ScoovaNavLayer
    private let routingURL: URL

    private var maneuvers: [ManeuverEvent] = []
    private var shape: [[Double]] = []
    /// Shape-vertex index where each maneuver begins (`beginShapeIndex`,
    /// clamped to the polyline). The maneuver *ordinal* must never be
    /// used to index `shape` — that collapses every maneuver onto the
    /// first handful of vertices at the route start.
    private var maneuverShapeIndices: [Int] = []
    /// Cumulative metres from the route start to each polyline vertex —
    /// lets a GPS fix be turned into a continuous distance-travelled.
    private var cumMeters: [Double] = []
    private var totalSeconds: Double = 0
    private var totalMeters: Double = 0
    private var currentManeuverIdx: Int = 0

    /// Trip-level scoova block from the most recent `startRoute` response.
    /// Holds server-rendered state-machine vocabulary (welcome / good /
    /// keepGoing / almostThere / arrived / wrongWay / missedTurn /
    /// rerouting / slow). Nil until a route has been fetched.
    public private(set) var tripScoova: TripScoova?

    public init(apiKey: String, layer: ScoovaNavLayer, routingURL: URL = URL(string: "https://api.scoo-va.info/api/v1/route")!) {
        self.apiKey = apiKey
        self.layer = layer
        self.routingURL = routingURL
    }

    /// Fetch a route and start driving the layer. Returns the decoded
    /// polyline so the caller can draw it on whatever map they're using.
    @discardableResult
    public func startRoute(
        from: LatLon,
        to: LatLon,
        profile: String = "auto",
        language: String = "en-US",
        landmarks: Bool = true,
        eyesOff: Bool = false
    ) async throws -> [[Double]] {
        var payload: [String: Any] = [
            "locations": [
                ["lat": from.lat, "lon": from.lon],
                ["lat": to.lat,   "lon": to.lon],
            ],
            "costing": profile,
            "language": language,
            "simplified_instructions": true,
            "landmarks": landmarks,
        ]
        // Eyes-off → the landmark-proxy swaps to measurement-free,
        // landmark/sequence-led copy. Key is camelCase `voiceMode`,
        // matching the server's `parse_voice_mode`.
        if eyesOff { payload["voiceMode"] = "eyes_off" }

        var req = URLRequest(url: routingURL)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("scoova-nav-layer/1.0 (ios)", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ScoovaRouting", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "routing http \(http.statusCode): \(body.prefix(200))"
            ])
        }
        // Pure JSON → maneuvers decode lives in `decodeRoute` so it can
        // be unit-tested against captured server fixtures, no network.
        let decoded = try Self.decodeRoute(from: data, fallback: from)
        shape = decoded.shape
        cumMeters = Self.cumulativeMeters(decoded.shape)
        maneuverShapeIndices = decoded.maneuverShapeIndices
        totalSeconds = decoded.totalSeconds
        totalMeters = decoded.totalMeters
        currentManeuverIdx = 0
        tripScoova = decoded.tripScoova
        maneuvers = decoded.maneuvers

        if let ts = decoded.tripScoova {
            // Fold the rich full-sentence variants into the state map so
            // the engine can prefer e.g. `welcomeFull` over `welcome`.
            var state = ts.state ?? [:]
            if let v = ts.welcomeFull, !v.isEmpty { state["welcomeFull"] = v }
            if let v = ts.arrivedFull, !v.isEmpty { state["arrivedFull"] = v }
            if let v = ts.almostThereFull, !v.isEmpty { state["almostThereFull"] = v }
            layer.onTripScoova(TripScoovaState(
                lang: ts.lang, dir: ts.dir, state: state))
        } else {
            layer.onTripScoova(nil)
        }

        layer.onRoute(maneuvers)
        // (`onTripScoova` above already handed the layer the trip-level
        // phrase map — including the rich `*Full` variants — so there's
        // no separate `setTripState` call here; that one carried only
        // the raw `state` dict and clobbered the merged map.)
        // Pass the decoded polyline so the NavLayer's GuidanceMonitor
        // can project the rider's GPS onto it for drift / off-route /
        // heading-mismatch detection.
        layer.setRouteShape(shape)
        return shape
    }

    /// The decoded form of a routing-API response — the pure result of
    /// parsing, no networking. Internal so the JSON → `ManeuverEvent`
    /// path can be unit-tested against captured server fixtures.
    struct DecodedRoute {
        let maneuvers: [ManeuverEvent]
        let shape: [[Double]]
        let maneuverShapeIndices: [Int]
        let totalSeconds: Double
        let totalMeters: Double
        let tripScoova: TripScoova?
    }

    /// Parse a routing-API JSON body into a ``DecodedRoute`` — the
    /// JSON → ``ManeuverEvent`` path, lifted out of `startRoute` so it
    /// has no network dependency and can be tested directly.
    static func decodeRoute(from data: Data, fallback: LatLon) throws -> DecodedRoute {
        let parsed = try parseResponse(data)
        let trip = parsed.trip
        let leg = trip.legs.first ?? RoutingLeg(shape: "", maneuvers: [])
        let shape = Polyline6.decode(leg.shape)
        let shapeIndices = leg.maneuvers.map {
            max(0, min($0.beginShapeIndex, max(0, shape.count - 1)))
        }
        let maneuvers = leg.maneuvers.enumerated().map { idx, m -> ManeuverEvent in
            let i = shapeIndices[idx]
            let pt = (shape.indices.contains(i)) ? shape[i] : [fallback.lat, fallback.lon]
            let raw = (m.verbalSuccinct?.isEmpty == false ? m.verbalSuccinct : m.instruction)
            let sc = m.scoova
            let banner = sc?.banner
            let voice = sc?.voice
            return ManeuverEvent(
                index: idx,
                total: leg.maneuvers.count,
                type: Self.mapValhallaType(m.type),
                rawInstruction: raw,
                latitude: pt[0],
                longitude: pt[1],
                segmentLengthMeters: m.length * 1000,
                // Pass through Valhalla's per-maneuver duration so the
                // cue scheduler can space reaffirm cues by time, not
                // distance — the only way one heuristic works across
                // pedestrian / bike / scooter / car at their wildly
                // different speeds.
                segmentDurationSeconds: m.time,
                roundaboutExit: sc?.exit ?? m.roundaboutExitCount,
                // Server-rendered eyes-on-the-road copy — the banner +
                // voice render these verbatim, falling back to
                // `rawInstruction` only when no scoova block was sent.
                bannerVerb: banner?.verb,
                bannerAnchor: banner?.anchor,
                voiceHeadsUp: voice?.headsUp,
                voiceTurnNow: voice?.turnNow,
                voiceAtLandmark: voice?.atLandmark,
                voiceGetReadyTemplate: voice?.getReadyTemplate,
                voiceAtDistanceTemplate: voice?.atDistanceTemplate,
                voiceFar: voice?.far,
                voiceMid: voice?.mid,
                voiceNear: voice?.near,
                voiceChained: voice?.chained,
                voiceConfirm: voice?.confirm,
                voiceRecover: voice?.recover,
                voiceReaffirm: voice?.reaffirm,
                voiceCheckpoint: voice?.checkpoint,
                checkpointOffsetMeters: voice?.checkpointOffsetMeters,
                cueFarMeters: voice?.farMeters,
                cueMidMeters: voice?.midMeters,
                cueNearMeters: voice?.nearMeters,
                landmark: sc?.landmark
            )
        }
        return DecodedRoute(
            maneuvers: maneuvers,
            shape: shape,
            maneuverShapeIndices: shapeIndices,
            totalSeconds: trip.summary.time,
            totalMeters: trip.summary.length * 1000,
            tripScoova: trip.scoova
        )
    }

    /// Feed a location update from your CLLocationManager / FusedLocation.
    public func onLocation(
        lat: Double,
        lon: Double,
        speedMps: Float? = nil,
        bearingDeg: Float? = nil
    ) {
        guard !maneuvers.isEmpty, !shape.isEmpty else { return }
        // Project the rider onto the polyline as a CONTINUOUS distance
        // travelled — not the nearest vertex. Snapping to a vertex flips
        // to the next one at the midpoint between vertices, so the
        // maneuver cursor (and the banner) jumped to the turn-after-next
        // while the rider was still tens of metres short of the current
        // turn. A continuous projection only passes a maneuver once the
        // rider is genuinely past its point.
        let along = distanceAlongRoute(lat: lat, lon: lon)
        currentManeuverIdx = advanceCurrentIndex(distanceAlong: along,
                                                 hint: currentManeuverIdx)
        let nextIdx = min(currentManeuverIdx + 1, maneuvers.count - 1)

        // Distance to the upcoming maneuver, measured ALONG the route —
        // the true distance still to cover, which the cue engine's
        // far / mid / near timing keys off. Straight-line haversine
        // under-reads on a curve and fired the cues a touch late.
        let nextManeuverAlong = cumMeters[maneuverShapeIndices[nextIdx]]
        let distM = max(0, nextManeuverAlong - along)

        let metersRemaining = max(0, Int(totalMeters - along))
        let frac = totalMeters > 0 ? max(0, 1 - along / totalMeters) : 0
        let secondsRemaining = Int(totalSeconds * frac)

        layer.onProgress(ProgressEvent(
            latitude: lat,
            longitude: lon,
            speedMps: speedMps,
            bearingDeg: bearingDeg,
            upcomingManeuverIndex: nextIdx,
            metersToUpcomingManeuver: distM,
            secondsRemaining: secondsRemaining,
            metersRemaining: metersRemaining
        ))
    }

    public func routeShape() -> [[Double]] { shape }

    // MARK: - Internals --------------------------------------------------

    /// Cumulative great-circle distance to each polyline vertex.
    private static func cumulativeMeters(_ shape: [[Double]]) -> [Double] {
        var cum = [Double](repeating: 0, count: shape.count)
        guard shape.count > 1 else { return cum }
        for i in 1..<shape.count {
            cum[i] = cum[i - 1] + GeoMath.haversineMeters(
                shape[i - 1][0], shape[i - 1][1], shape[i][0], shape[i][1])
        }
        return cum
    }

    /// The rider's GPS projected onto the route, returned as metres
    /// travelled from the start. Projects onto the nearest line
    /// SEGMENT (not the nearest vertex), so the position is continuous
    /// and only passes a maneuver once the rider is truly past it.
    private func distanceAlongRoute(lat: Double, lon: Double) -> Double {
        guard shape.count >= 2, cumMeters.count == shape.count else { return 0 }
        // Local equirectangular metres — accurate over a single segment.
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(lat * .pi / 180)
        let rx = lon * mPerDegLon, ry = lat * mPerDegLat
        var bestDistSq = Double.greatestFiniteMagnitude
        var bestAlong = 0.0
        for i in 0..<(shape.count - 1) {
            let ax = shape[i][1] * mPerDegLon,     ay = shape[i][0] * mPerDegLat
            let bx = shape[i + 1][1] * mPerDegLon, by = shape[i + 1][0] * mPerDegLat
            let dx = bx - ax, dy = by - ay
            let segLenSq = dx * dx + dy * dy
            let t = segLenSq > 0
                ? max(0, min(1, ((rx - ax) * dx + (ry - ay) * dy) / segLenSq))
                : 0
            let px = ax + dx * t, py = ay + dy * t
            let distSq = (rx - px) * (rx - px) + (ry - py) * (ry - py)
            if distSq < bestDistSq {
                bestDistSq = distSq
                bestAlong = cumMeters[i] + t * (cumMeters[i + 1] - cumMeters[i])
            }
        }
        return bestAlong
    }

    /// The last maneuver the rider has passed — the highest maneuver
    /// whose point sits at or behind the rider's distance travelled
    /// along the route. `hint` keeps the cursor monotonic against GPS
    /// jitter, so `nextIdx = currentManeuverIdx + 1` is always the
    /// upcoming turn.
    private func advanceCurrentIndex(distanceAlong: Double, hint: Int) -> Int {
        var idx = max(0, min(hint, maneuvers.count - 1))
        while idx + 1 < maneuvers.count
            && cumMeters[maneuverShapeIndices[idx + 1]] <= distanceAlong {
            idx += 1
        }
        return idx
    }

    private static func mapValhallaType(_ t: Int) -> ManeuverType {
        switch t {
        case 1, 2, 3:   return .depart
        case 4, 5, 6:   return .arrive
        case 7:         return .becomes
        case 8:         return .`continue`
        case 9:         return .slightRight
        case 10:        return .right
        case 11:        return .sharpRight
        case 12, 13:    return .uturn
        case 14:        return .sharpLeft
        case 15:        return .left
        case 16:        return .slightLeft
        case 17:        return .rampStraight
        case 18:        return .rampRight
        case 19:        return .rampLeft
        case 20:        return .exitRight
        case 21:        return .exitLeft
        case 22:        return .stayStraight
        case 23:        return .stayRight
        case 24:        return .stayLeft
        case 25:        return .merge
        case 26:        return .roundaboutEnter
        case 27:        return .roundaboutExit
        default:        return .other
        }
    }
}

// MARK: - Response parsing -------------------------------------------------

private struct RoutingResponse: Decodable {
    let trip: RoutingTrip
}
private struct RoutingTrip: Decodable {
    let legs: [RoutingLeg]
    let summary: RoutingSummary
    let scoova: TripScoova?
}
private struct RoutingLeg: Decodable {
    let shape: String
    let maneuvers: [RoutingManeuver]
}
private struct RoutingSummary: Decodable {
    let time: Double
    let length: Double
}
private struct RoutingManeuver: Decodable {
    let type: Int
    let instruction: String?
    let verbalSuccinct: String?
    let length: Double
    /// Expected seconds to traverse this maneuver's segment. Drives the
    /// SDK's time-based reaffirm spacing — without it, pedestrian rides
    /// get one reaffirm every 5 minutes (the old 450 m heuristic).
    /// Defaults to 0 so legacy / mocked routes still decode.
    let time: Double
    let beginShapeIndex: Int
    let roundaboutExitCount: Int?
    /// Server-rendered eyes-on-the-road copy. Source of truth for the
    /// banner + voice — clients render it verbatim.
    let scoova: Scoova?

    enum CodingKeys: String, CodingKey {
        case type, instruction, length, time, scoova
        case verbalSuccinct = "verbal_succinct_transition_instruction"
        case beginShapeIndex = "begin_shape_index"
        case roundaboutExitCount = "roundabout_exit_count"
    }
}

/// Per-maneuver scoova block from `routing.scoo-va.info`. Mirrors the
/// JSON exactly — every field optional so we tolerate schema drift.
public struct Scoova: Decodable, Sendable, Equatable {
    /// Canonical direction kind: "right" / "left" / "roundabout" / "depart" / "arrive" / etc.
    public let kind: String?
    /// Roundabout exit number (1-indexed). Nil when not a roundabout.
    public let exit: Int?
    /// Locale the strings are in (e.g. "ar-EG").
    public let lang: String?
    /// Raw POI name (without infix), useful for icon-overlay lookups.
    public let landmark: String?
    public let banner: ScoovaBanner?
    public let voice: ScoovaVoice?
}

public struct ScoovaBanner: Decodable, Sendable, Equatable {
    /// Big primary line on the banner: "Turn right" / "حوّد يمين".
    public let verb: String?
    /// Secondary line: "after the gas station" / "بعد البنزينة". Nil if no landmark.
    public let anchor: String?
    public let kind: String?
}

public struct ScoovaVoice: Decodable, Sendable, Equatable {
    /// Long-lead cue (~15s out). "Right turn coming up at the next street".
    public let headsUp: String?
    /// At-the-maneuver cue. "Turn right".
    public let turnNow: String?
    /// Turn cue with landmark. "Turn right after the gas station".
    public let atLandmark: String?
    /// Mid-lead template — client substitutes `{secs}`. "Turn right in {secs} seconds…".
    public let getReadyTemplate: String?
    /// Distance variant template — client substitutes `{meters}`. "In {meters} meters, turn right".
    public let atDistanceTemplate: String?
    /// Pre-rendered far-phase eyes-off cue — landmark-led, measurement-free.
    /// "After McDonald's on your right, turn right."
    public let far: String?
    /// Pre-rendered mid-phase eyes-off cue — landmark-led, measurement-free.
    /// "Right after McDonald's on your right, turn right."
    public let mid: String?
    /// Pre-rendered near-phase eyes-off cue — landmark-led, measurement-free.
    /// "At McDonald's on your right, turn right."
    public let near: String?
    /// Pre-rendered chained-turn cue — present only when the NEXT maneuver
    /// follows within ~100 m. Packages both turns into one near-phase cue
    /// ("Turn right now onto X. Then quickly turn right again.") so the
    /// rider isn't ambushed by the second turn. Nil otherwise.
    public let chained: String?
    /// Post-maneuver reassurance — spoken once the turn is completed, so
    /// the rider knows it landed. "Good, you're on West 40th Street."
    public let confirm: String?
    /// Missed-turn recovery cue — spoken when the rider strays off the
    /// route. "Looks like you missed the turn, recalculating."
    public let recover: String?
    /// Mid-segment reassurance — names the current road + the next
    /// action. "Still on University Ave. Then turn right."
    public let reaffirm: String?
    /// Mid-segment checkpoint — a confidence cue naming a POI the rider
    /// passes on a long quiet stretch. "You're passing the museum on
    /// your right."
    public let checkpoint: String?
    /// Distance (m) AFTER the previous maneuver at which to fire the
    /// `checkpoint` cue — the server pins it ~halfway along the segment.
    public let checkpointOffsetMeters: Int?
    /// Distance (m) before the maneuver at which to speak each cue —
    /// the server's own lead-distance choice. The client triggers the
    /// `far` / `mid` / `near` phrase when the rider reaches these.
    public let farMeters: Int?
    public let midMeters: Int?
    public let nearMeters: Int?
}

/// Trip-level scoova block — server-rendered state-machine vocabulary
/// (welcome / good / keepGoing / almostThere / arrived / wrongWay /
/// missedTurn / rerouting / slow). All clients render whatever the server
/// says — no client-side phrasing.
public struct TripScoova: Decodable, Sendable, Equatable {
    public let lang: String?
    public let dir: String?
    public let state: [String: String]?
    /// Rich full-sentence variants the server renders alongside the
    /// short `state` phrases — eyes-off prefers these (they carry the
    /// heading / destination-side a rider can't see for themselves).
    public let welcomeFull: String?
    public let arrivedFull: String?
    public let almostThereFull: String?
}

private func parseResponse(_ data: Data) throws -> RoutingResponse {
    let decoder = JSONDecoder()
    return try decoder.decode(RoutingResponse.self, from: data)
}

// MARK: - Polyline6 decoder ------------------------------------------------
// Valhalla returns shapes encoded as Google's "polyline" format with
// precision 6 (×1e6) instead of the default 5 (×1e5).

enum Polyline6 {
    static func decode(_ encoded: String) -> [[Double]] {
        var coords: [[Double]] = []
        let bytes = Array(encoded.utf8)
        var index = 0
        var lat = 0
        var lng = 0
        while index < bytes.count {
            var result = 0
            var shift = 0
            var b: Int
            repeat {
                b = Int(bytes[index]) - 63
                index += 1
                result |= (b & 0x1f) << shift
                shift += 5
            } while b >= 0x20
            let dLat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lat += dLat

            result = 0
            shift = 0
            repeat {
                b = Int(bytes[index]) - 63
                index += 1
                result |= (b & 0x1f) << shift
                shift += 5
            } while b >= 0x20
            let dLng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            lng += dLng

            coords.append([Double(lat) / 1e6, Double(lng) / 1e6])
        }
        return coords
    }
}
