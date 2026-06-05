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

    /// Maneuver list for the active route. Host UIs (banner / step list /
    /// total-distance pill) read this after `startRoute` returns. Empty
    /// before the first successful route fetch.
    public private(set) var maneuvers: [ManeuverEvent] = []
    private var shape: [[Double]] = []
    /// Shape-vertex index where each maneuver begins (`beginShapeIndex`,
    /// clamped to the polyline). The maneuver *ordinal* must never be
    /// used to index `shape` — that collapses every maneuver onto the
    /// first handful of vertices at the route start.
    private var maneuverShapeIndices: [Int] = []
    /// Cumulative metres from the route start to each polyline vertex —
    /// lets a GPS fix be turned into a continuous distance-travelled.
    private var cumMeters: [Double] = []
    /// Total trip time in seconds (sum of all maneuver durations).
    public private(set) var totalSeconds: Double = 0
    /// Total trip distance in metres (sum of all maneuver lengths).
    public private(set) var totalMeters: Double = 0
    private var currentManeuverIdx: Int = 0

    /// Trip-level scoova block from the most recent `startRoute` response.
    /// Holds server-rendered state-machine vocabulary (welcome / good /
    /// keepGoing / almostThere / arrived / wrongWay / missedTurn /
    /// rerouting / slow). Nil until a route has been fetched.
    public private(set) var tripScoova: TripScoova?
    /// Reasoner context for the current route (graph fingerprints +
    /// per-maneuver cross-streets + ordinals + ambiguity flags). Nil
    /// until a route has been fetched OR when the routing service
    /// hasn't shipped the corridor contract yet — in which case the
    /// SDK falls back to the legacy baked-string voice path.
    public private(set) var corridor: Corridor?

    // ── Auto-reroute state ────────────────────────────────────────────
    //
    // Once `startRoute` has run, the adapter remembers what the rider
    // asked for plus the freshest GPS fix it has seen. When the SDK's
    // `GuidanceMonitor` decides the rider is genuinely off-route, the
    // adapter refetches from the CURRENT position (not the original
    // origin) with the rider's CURRENT bearing — so the new route
    // starts where the rider actually is and doesn't ask them to
    // immediately U-turn. Throttled so a sustained off-route condition
    // (or a stuck simulator GPS) can't loop reroute requests.
    private var lastDest: LatLon?
    private var lastProfile: String = "auto"
    private var lastLanguage: String = "en-US"
    private var lastLandmarks: Bool = true
    private var lastEyesOff: Bool = false
    private var lastLat: Double?
    private var lastLon: Double?
    private var lastBearingDeg: Float?
    private var rerouteInFlight = false
    /// Wall-clock ms of the most recent successful reroute. Used by the
    /// throttle so a stuck off-route condition (e.g. simulator GPS
    /// pinned 60 m off the route line) doesn't trigger a fresh fetch
    /// on every fix.
    private var lastRerouteAtMs: Int64 = 0
    /// Minimum gap between reroute fetches (ms). 8 s comfortably
    /// outlasts the GuidanceMonitor's 5 s off-route persistence — if
    /// the new route still shows the rider off, we let the SDK
    /// re-evaluate before firing again.
    private let rerouteMinIntervalMs: Int64 = 8_000
    /// Wall-clock ms when the most recent route was installed (initial
    /// OR auto-reroute). Used as a "cooldown" so an off-route detection
    /// fired in the first second after install — typically caused by
    /// the rider's GPS being slightly offset from the routing API's
    /// snapped origin — doesn't immediately wipe the route we just
    /// drew.
    private var routeInstalledAtMs: Int64 = 0
    /// Minimum age (ms) of the current route before we'll honour an
    /// off-route reroute request. 3 s gives the GPS a couple of fixes
    /// to settle onto the line.
    private let routeMinAgeBeforeRerouteMs: Int64 = 3_000

    // ── Dead-reckoning during GPS gaps ───────────────────────────────
    /// Re-projects the rider's position forward when the host's GPS
    /// stops delivering — tunnels, underpasses, urban canyons. The
    /// reckoner anchors on every REAL fix and the watchdog below
    /// synthesises a projected fix every second during a gap so the
    /// cue engine keeps reasoning instead of freezing.
    private let deadReckoner = DeadReckoner()
    private var deadReckonTask: Task<Void, Never>?
    private let deadReckonStartGapMs: Int64 = 2_500
    private let deadReckonStopGapMs:  Int64 = 30_000

    // ── Teleport-jump filter (P1.8) ──────────────────────────────────
    /// Wall-clock ms of the previous accepted fix. Used by the
    /// teleport filter to compute an implied speed for the next fix
    /// and reject impossible jumps. 0 ⇒ no prior fix.
    private var lastFixTsMs: Int64 = 0
    /// Max ground speed (m/s) we'll accept between consecutive fixes.
    /// 65 m/s ≈ 234 km/h — well above any rider on a scooter or in
    /// urban traffic; anything faster is a GPS jump (sim resume,
    /// teleport from a tunnel, or location-services restart).
    private let maxPlausibleSpeedMps: Double = 65
    /// Hard floor on the rejected jump distance. A fix 30 m off in 100 ms
    /// implies 300 m/s and would be rejected — but 30 m at 30 km/h
    /// is normal jitter. Only reject jumps over 50 m AND faster than
    /// `maxPlausibleSpeedMps`.
    private let teleportMinJumpMeters: Double = 50
    /// After this much time between fixes, the teleport check is
    /// disabled — a genuine gap (tunnel exit, app resume) shouldn't
    /// keep blocking the rider's location forever.
    private let teleportRelaxAfterMs: Int64 = 10_000
    /// How many consecutive teleport rejections we tolerate before
    /// accepting the new fix anyway — guards against a permanent
    /// teleport (e.g. user phone-swap) locking us out.
    private let teleportMaxConsecutiveDrops: Int = 3
    private var teleportConsecutiveDrops: Int = 0

    /// Callback invoked whenever the adapter has just installed a fresh
    /// route shape — either an initial `startRoute` or an auto-reroute
    /// triggered by the SDK. Hosts can use this to redraw the map
    /// polyline. The argument is `[[lon, lat]]` per GeoJSON convention.
    public var onRouteRefreshed: (([[Double]]) -> Void)?

    public init(apiKey: String, layer: ScoovaNavLayer, routingURL: URL = URL(string: "https://api.scoo-va.info/api/v1/route")!) {
        self.apiKey = apiKey
        self.layer = layer
        self.routingURL = routingURL
        // Auto-handle reroute events from the layer. Without this hook
        // the SDK keeps firing "Looks like you missed the turn,
        // recalculating" on every fix until the host supplies a fresh
        // route — see the loop bug riders flagged on 2026-05-28.
        layer.onRerouteNeeded = { [weak self] in
            self?.handleRerouteNeeded()
        }
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
        eyesOff: Bool = false,
        bearingDeg: Float? = nil,
        isReroute: Bool = false
    ) async throws -> [[Double]] {
        // Remember everything so an auto-reroute later can rebuild the
        // request without needing the host to supply it again.
        lastDest = to
        lastProfile = profile
        lastLanguage = language
        lastLandmarks = landmarks
        lastEyesOff = eyesOff

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

        // Heading-aware routing: hint the server with the rider's
        // current bearing so the returned route doesn't start by asking
        // for an immediate U-turn when the rider is mid-street.
        // Valhalla honours `heading` (0-359°) on the first location
        // when supplied with a `heading_tolerance` window.
        //
        // Tolerance 60° — the industry-consensus middle. Mapbox
        // Directions defaults to 45°, HERE to 30°. 60° gives the
        // engine room to pick the shortest legal path including small
        // turns, while still keeping the route from starting in a
        // direction the rider can't actually go. Settled on this after
        // briefly trying 90° (too loose — produced U-turn-first
        // routes) and the original 45° (too tight — produced
        // 442 "no path" errors on edges that didn't allow the
        // rider's exact bearing). The server's landmark-proxy also
        // strips heading on short A→B trips and retries without
        // heading on 442 errors, so failures here recover gracefully.
        if let bearing = bearingDeg, bearing >= 0, bearing <= 360,
           var locations = payload["locations"] as? [[String: Any]],
           !locations.isEmpty {
            locations[0]["heading"] = Int(bearing)
            locations[0]["heading_tolerance"] = 60
            payload["locations"] = locations
        }

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
        // Rider-to-route stub: the routing engine snaps the input
        // location to the nearest routable edge. When the rider is in
        // a parking lot, alley, or off-network area, the shape's
        // first vertex lands on the street — leaving a visible gap
        // between the rider's puck and the start of the drawn line.
        // Google Maps and Mapbox solve this by prepending the rider's
        // actual coord as the polyline's vertex 0 so the line
        // visually connects. Mirror that here: when the gap > 15 m,
        // prepend (from.lat, from.lon) to the shape. Threshold is
        // small enough that ordinary snap stubs (< 5 m) don't get
        // augmented; only the genuine "rider is far from the road"
        // case adds the stub.
        let augmentedShape = Self.prependRiderStubIfNeeded(
            decoded.shape, riderLat: from.lat, riderLon: from.lon)
        shape = augmentedShape
        cumMeters = Self.cumulativeMeters(augmentedShape)
        maneuverShapeIndices = decoded.maneuverShapeIndices
        totalSeconds = decoded.totalSeconds
        totalMeters = decoded.totalMeters
        currentManeuverIdx = 0
        tripScoova = decoded.tripScoova
        corridor = decoded.corridor
        maneuvers = decoded.maneuvers
        Self.logRouteResponse(
            decoded: decoded, isReroute: isReroute,
            profile: profile, language: language,
            riderBearingAtFetch: bearingDeg,
            riderLatAtFetch: from.lat,
            riderLonAtFetch: from.lon)

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

        // Hand the corridor block to the layer BEFORE `onRoute` so
        // the reasoner has the road-graph context the moment cues
        // start firing for this trip. Nil corridor (legacy service)
        // triggers the layer's fallback path automatically.
        layer.onCorridor(decoded.corridor)
        // `isReroute` lets the layer suppress the welcome-cue reset on
        // mid-trip refetches. Without this, every off-route reroute
        // fires "Let's go, your trip is X km…" again — random-feeling
        // chatter that riders flagged immediately.
        layer.onRoute(maneuvers, isReroute: isReroute, eyesOff: eyesOff)
        // (`onTripScoova` above already handed the layer the trip-level
        // phrase map — including the rich `*Full` variants — so there's
        // no separate `setTripState` call here; that one carried only
        // the raw `state` dict and clobbered the merged map.)
        // Pass the decoded polyline so the NavLayer's GuidanceMonitor
        // can project the rider's GPS onto it for drift / off-route /
        // heading-mismatch detection.
        layer.setRouteShape(shape)
        routeInstalledAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        startDeadReckonTaskIfNeeded()

        // Cursor catchup: if the rider is already moving when the route
        // lands (which is the norm for reroutes), project their current
        // GPS onto the freshly installed polyline and advance
        // currentManeuverIdx past any maneuvers already BEHIND them.
        // Otherwise the cue engine starts at maneuver 0 again and
        // either fires duplicate cues or — worse — jumps multiple
        // maneuvers ahead on the first progress event (which is what
        // produced the "cursor jumped from #1 to #3 in 2 seconds"
        // glitch the rider saw in the log).
        currentManeuverIdx = 0
        if let lat = lastLat, let lon = lastLon {
            let along = distanceAlongRoute(lat: lat, lon: lon)
            currentManeuverIdx = advanceCurrentIndex(distanceAlong: along, hint: 0)
            NSLog("🎯 [cursor] catchup: rider at along=\(Int(along))m → maneuver #\(currentManeuverIdx) of \(maneuvers.count)")
        }

        // ALWAYS notify the host so the map line matches the route the
        // cue engine is following.
        onRouteRefreshed?(shape)
        return shape
    }

    /// Same as `startRoute` but uses the adapter's remembered
    /// destination + the most recent GPS fix + bearing. The SDK's
    /// off-route handler calls this directly — hosts don't need to wire
    /// anything for reroute to work.
    private func handleRerouteNeeded() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        NSLog("🔁 [reroute] requested. inFlight=\(rerouteInFlight) sinceLast=\(nowMs - lastRerouteAtMs)ms sinceInstall=\(nowMs - routeInstalledAtMs)ms hasDest=\(lastDest != nil) hasLoc=\(lastLat != nil && lastLon != nil)")
        // Throttle: 8 s minimum between fetches.
        if rerouteInFlight { NSLog("🔁 [reroute] BLOCKED — in flight"); return }
        if nowMs - lastRerouteAtMs < rerouteMinIntervalMs {
            NSLog("🔁 [reroute] BLOCKED — within throttle window")
            return
        }
        if nowMs - routeInstalledAtMs < routeMinAgeBeforeRerouteMs {
            NSLog("🔁 [reroute] BLOCKED — within install cooldown")
            return
        }
        guard lastDest != nil, lastLat != nil, lastLon != nil else {
            NSLog("🔁 [reroute] BLOCKED — missing dest or location cache")
            return
        }

        rerouteInFlight = true

        Task { [weak self] in
            defer { self?.rerouteInFlight = false }
            // Read GPS state INSIDE the Task — by the time the URLSession
            // round-trip lands, the rider has moved (a 30 km/h scooter
            // covers 17 m in the 2 s a typical route fetch takes). Using
            // the freshest cached fix here, then again on each retry,
            // keeps the new route line under the rider, not behind them.
            guard let self,
                  let dest = self.lastDest,
                  let lat = self.lastLat,
                  let lon = self.lastLon else { return }
            let from = LatLon(lat: lat, lon: lon)
            let bearing = self.lastBearingDeg
            let profile = self.lastProfile
            let language = self.lastLanguage
            let landmarks = self.lastLandmarks
            let eyesOff = self.lastEyesOff
            // Reroute payload visibility — see product memory:
            // log-every-point-during-ride. The user surfaced bugs
            // where the new route went toward the destination
            // direction instead of the rider's actual heading; we
            // need to be able to see WHAT WE TOLD THE SERVER so we
            // can tell whether the server ignored the bearing or
            // whether we sent the wrong one. Logs: rider's position
            // (where they are), destination (where we're heading),
            // bearing being sent (rider's current direction), and
            // straight-line distance to destination + bearing to
            // destination so the next route's first segment can
            // be visually compared against both the rider's bearing
            // AND the destination bearing.
            let destBrg = GeoMath.bearingDeg(
                lat, lon, dest.lat, dest.lon)
            let destDistM = Int(GeoMath.haversineMeters(
                lat, lon, dest.lat, dest.lon))
            NSLog("🔁 [reroute/request] from=(\(String(format:"%.5f",lat)),\(String(format:"%.5f",lon))) " +
                  "to=(\(String(format:"%.5f",dest.lat)),\(String(format:"%.5f",dest.lon))) " +
                  "rider_bearing=\(bearing.map{String(format:"%.0f°", $0)} ?? "?") " +
                  "to_dest_bearing=\(Int(destBrg))° to_dest_dist=\(destDistM)m " +
                  "profile=\(profile)")
            do {
                _ = try await self.startRoute(
                    from: from, to: dest,
                    profile: profile,
                    language: language,
                    landmarks: landmarks,
                    eyesOff: eyesOff,
                    bearingDeg: bearing,
                    isReroute: true
                )
                self.lastRerouteAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            } catch {
                NSLog("[ScoovaRouting] auto-reroute failed: %@", "\(error)")
            }
        }
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
        /// Reasoner context for the route. Optional — absent on legacy
        /// servers that haven't shipped the corridor contract yet, in
        /// which case the SDK falls back to the baked `scoova.voice.*`
        /// strings on each maneuver.
        let corridor: Corridor?
    }

    /// Parse a routing-API JSON body into a ``DecodedRoute`` — the
    /// JSON → ``ManeuverEvent`` path, lifted out of `startRoute` so it
    /// has no network dependency and can be tested directly.
    ///
    /// Multi-leg routes (waypoints): all legs are concatenated into one
    /// continuous shape + maneuver list. The boundary vertex between
    /// legs (last vertex of leg N = first vertex of leg N+1) is
    /// deduplicated. Intermediate `.arrive` maneuvers — Valhalla emits
    /// one at each waypoint — are demoted to `.continue` so the SDK
    /// doesn't fire the arrival cue mid-trip. The FINAL `.arrive` (last
    /// maneuver of the last leg) is preserved; that's the real
    /// destination. A future iteration can surface waypoint events
    /// to the host as a dedicated callback.
    /// Compact, parseable log of WHAT the server returned. Lets
    /// post-ride analysis reconstruct the data the SDK was reasoning
    /// against — not just what cues fired. See
    /// `feedback_log_the_data_not_just_behavior` in product memory.
    /// One line per response; never dumps full polylines or shapes
    /// (counts + IDs are enough to reconstruct context).
    static func logRouteResponse(
        decoded: DecodedRoute,
        isReroute: Bool,
        profile: String,
        language: String,
        riderBearingAtFetch: Float? = nil,
        riderLatAtFetch: Double? = nil,
        riderLonAtFetch: Double? = nil
    ) {
        let tag = isReroute ? "REROUTE" : "INITIAL"
        // First-MEANINGFUL-segment direction — answers "which way did
        // the new route ask me to go first?" Walks the shape forward
        // accumulating distance until > 20 m to skip the snap-
        // correction stub the engine inserts when it snaps the
        // rider's input position to the nearest routable edge. The
        // log used to read "firstSegBrg=271°" for a route that
        // actually heads north 117 m — because the engine had
        // inserted a 6 m west-going snap stub at index 0 → 1. The
        // user called that out as misleading; this fix makes the
        // direction measure the real intended heading.
        if decoded.shape.count >= 2 {
            let stubThresholdM: Double = 20
            var cumDist: Double = 0
            var firstBrg = GeoMath.bearingDeg(
                decoded.shape[0][0], decoded.shape[0][1],
                decoded.shape[1][0], decoded.shape[1][1])
            for i in 1..<decoded.shape.count {
                let segDist = GeoMath.haversineMeters(
                    decoded.shape[i - 1][0], decoded.shape[i - 1][1],
                    decoded.shape[i][0], decoded.shape[i][1])
                cumDist += segDist
                if cumDist >= stubThresholdM {
                    firstBrg = GeoMath.bearingDeg(
                        decoded.shape[0][0], decoded.shape[0][1],
                        decoded.shape[i][0], decoded.shape[i][1])
                    break
                }
            }
            let riderTag = riderBearingAtFetch.map { String(format: "%.0f°", $0) } ?? "?"
            // U-turn detection: > 120° between rider's bearing and
            // route's first meaningful segment bearing.
            let uturnFlag: String
            if let rb = riderBearingAtFetch {
                let delta = abs(((Double(rb) - firstBrg + 540).truncatingRemainder(dividingBy: 360)) - 180)
                uturnFlag = delta > 120 ? " ⚠ U-TURN" : ""
            } else { uturnFlag = "" }
            NSLog("🛣 [route/\(tag)/firstSeg] firstSegBrg=\(Int(firstBrg))° riderBrg=\(riderTag)\(uturnFlag)")
        }
        // Full geometry — answers "WHERE on the map does this route
        // actually go?" Logs every shape vertex + every maneuver's
        // pin point. The shape points are listed compactly as
        // `lat,lon;lat,lon;…` so they can be pasted into geojson.io
        // / a map preview / etc. The user asked: "where is the route
        // in this log, where is the recreated route?" — the answer
        // is now here, every fetch.
        if !decoded.shape.isEmpty {
            let pts = decoded.shape.map { p in
                String(format: "%.5f,%.5f", p[0], p[1])
            }.joined(separator: ";")
            NSLog("🛣 [route/\(tag)/shape] (\(decoded.shape.count) pts) %@", pts)
        }
        for m in decoded.maneuvers {
            let typeStr = "\(m.type)"
                .replacingOccurrences(of: "ManeuverType.", with: "")
            NSLog("🛣 [route/\(tag)/pin] mnv#\(m.index) type=\(typeStr) at=\(String(format: "%.5f,%.5f", m.latitude, m.longitude))")
        }
        let maneuverSummary = decoded.maneuvers.prefix(12).map { m -> String in
            let dist = Int(m.segmentLengthMeters.rounded())
            let typeStr = "\(m.type)"
                .replacingOccurrences(of: "ManeuverType.", with: "")
            return "#\(m.index):\(typeStr)(\(dist)m)"
        }.joined(separator: " ")
        NSLog("🛣 [route/\(tag)] profile=\(profile) lang=\(language) "
              + "legs=concat maneuvers=\(decoded.maneuvers.count) "
              + "shape=\(decoded.shape.count)pts "
              + "total=\(Int(decoded.totalMeters))m,\(Int(decoded.totalSeconds))s "
              + "mans: \(maneuverSummary)")
        if let c = decoded.corridor {
            let fingerprintCount = c.graphFingerprints.count
            let neighbourCount = c.neighbourGraph.count
            let neighbourNames = c.neighbourGraph.prefix(8)
                .map { "\($0.name.isEmpty ? "<unnamed>" : $0.name)" }
                .joined(separator: ", ")
            let onewayCount = c.neighbourGraph.filter { $0.oneway }.count
            NSLog("🛣 [route/corridor] fingerprints=\(fingerprintCount) "
                  + "neighbours=\(neighbourCount)ways (\(onewayCount)oneway) "
                  + "first: \(neighbourNames)")
            // Per-maneuver corridor summary — what the navigator's
            // grammar will see for each turn.
            for mb in c.maneuvers.prefix(8) {
                let xs = mb.crossStreets.prefix(4).map { c -> String in
                    let nm = c.name.isEmpty ? "?" : c.name
                    return "\(c.side):\(nm)@\(c.metersBeforeManeuver)m"
                }.joined(separator: ", ")
                let ord = mb.ordinal.map { "\($0.indexAmongSameSideTurns)/\($0.totalSameSideTurns)\($0.side)" } ?? "_"
                let flags = mb.ambiguityFlags.isEmpty
                    ? "—" : mb.ambiguityFlags.joined(separator: ",")
                NSLog("🛣 [route/mnv#\(mb.index)] ord=\(ord) "
                      + "complexity=\(mb.intersectionComplexity ?? "?") "
                      + "flags=\(flags) "
                      + "xs[\(mb.crossStreets.count)]: \(xs)")
            }
        } else {
            NSLog("🛣 [route/corridor] ABSENT — legacy server response or build failed")
        }
        if let ts = decoded.tripScoova {
            let stateKeys = (ts.state ?? [:]).keys.sorted().joined(separator: ",")
            NSLog("🛣 [route/scoova] lang=\(ts.lang ?? "?") dir=\(ts.dir ?? "?") "
                  + "state.keys=[\(stateKeys)]")
        }
    }

    static func decodeRoute(from data: Data, fallback: LatLon) throws -> DecodedRoute {
        let parsed = try parseResponse(data)
        let trip = parsed.trip
        guard !trip.legs.isEmpty else {
            return DecodedRoute(
                maneuvers: [], shape: [], maneuverShapeIndices: [],
                totalSeconds: trip.summary.time,
                totalMeters: trip.summary.length * 1000,
                tripScoova: trip.scoova,
                corridor: parsed.corridor)
        }

        // Concatenate every leg into a single shape + manuever list.
        // For legs after the first, drop the first vertex of that
        // leg's shape (it coincides with the last vertex of the
        // previous leg) and offset each maneuver's beginShapeIndex
        // by the accumulated shape length.
        var concatShape: [[Double]] = []
        var concatRouting: [RoutingManeuver] = []
        var concatShapeIndices: [Int] = []
        let legCount = trip.legs.count
        for (legIdx, leg) in trip.legs.enumerated() {
            let legShape = Polyline6.decode(leg.shape)
            // Shape offset: subtract 1 from the second-and-later legs
            // because their first vertex is dropped to avoid the
            // duplicated boundary vertex.
            let baseOffset: Int
            if legIdx == 0 || concatShape.isEmpty || legShape.isEmpty {
                baseOffset = concatShape.count
                concatShape.append(contentsOf: legShape)
            } else {
                baseOffset = concatShape.count - 1   // we drop legShape[0]
                concatShape.append(contentsOf: legShape.dropFirst())
            }
            for (mIdx, m) in leg.maneuvers.enumerated() {
                let isFirstLeg = (legIdx == 0)
                let isFirstManeuverInLeg = (mIdx == 0)
                let isFinalLeg = (legIdx == legCount - 1)
                let isFinalManeuverInLeg = (mIdx == leg.maneuvers.count - 1)
                // Demote the intermediate waypoint markers — Valhalla
                // emits a `.depart` at the start of every leg and an
                // `.arrive` at the end of every leg, so a 3-leg route
                // has 3 of each. Keep the FIRST leg's depart (the real
                // trip start) and the LAST leg's arrive (the real
                // destination); demote the rest to `.continue` so the
                // SDK doesn't fire welcome / arrival cues at waypoint
                // crossings.
                var demoted = m
                let mappedType = mapValhallaType(m.type)
                if mappedType == .depart, !(isFirstLeg && isFirstManeuverInLeg) {
                    demoted = m.withTypeReplacedByContinue()
                } else if mappedType == .arrive,
                          !(isFinalLeg && isFinalManeuverInLeg) {
                    demoted = m.withTypeReplacedByContinue()
                }
                let adjustedShape = max(0, min(m.beginShapeIndex + baseOffset,
                                                max(0, concatShape.count - 1)))
                concatRouting.append(demoted)
                concatShapeIndices.append(adjustedShape)
            }
        }

        let shape = concatShape
        let shapeIndices = concatShapeIndices
        let maneuvers = concatRouting.enumerated().map { idx, m -> ManeuverEvent in
            let i = shapeIndices[idx]
            let pt = (shape.indices.contains(i)) ? shape[i] : [fallback.lat, fallback.lon]
            let raw = (m.verbalSuccinct?.isEmpty == false ? m.verbalSuccinct : m.instruction)
            let sc = m.scoova
            let banner = sc?.banner
            let voice = sc?.voice
            return ManeuverEvent(
                index: idx,
                total: concatRouting.count,
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
                segmentDurationSeconds: m.time ?? 0,
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
                landmark: sc?.landmark,
                landmarkLat: sc?.landmarkLat,
                landmarkLon: sc?.landmarkLon,
                lanes: voice?.lanes,
                speedLimitKph: voice?.speedLimitKph
            )
        }
        return DecodedRoute(
            maneuvers: maneuvers,
            shape: shape,
            maneuverShapeIndices: shapeIndices,
            totalSeconds: trip.summary.time,
            totalMeters: trip.summary.length * 1000,
            tripScoova: trip.scoova,
            corridor: parsed.corridor
        )
    }

    /// Feed a location update from your CLLocationManager / FusedLocation.
    public func onLocation(
        lat: Double,
        lon: Double,
        speedMps: Float? = nil,
        bearingDeg: Float? = nil
    ) {
        onLocation(lat: lat, lon: lon, speedMps: speedMps,
                   bearingDeg: bearingDeg, fromDeadReckoning: false)
    }

    /// Real entry point — splits the public `onLocation` (always real
    /// fixes from the host) from the dead-reckoner's projected fixes,
    /// which must NOT re-anchor the reckoner (would compound error)
    /// and must NOT reset the teleport filter's "last real fix"
    /// timestamp (a tunnel exit needs the filter to know nothing has
    /// arrived in a while).
    private func onLocation(
        lat: Double,
        lon: Double,
        speedMps: Float?,
        bearingDeg: Float?,
        fromDeadReckoning: Bool
    ) {
        // ── Teleport filter ────────────────────────────────────────────
        // GPS occasionally delivers a fix hundreds of metres from the
        // previous one — sim resume, tunnel exit with a stale fix, the
        // location-services daemon restarting. Letting these through
        // jumps the route cursor forward irrecoverably (advanceCurrentIndex
        // is monotonic) and triggers a spurious reroute. Reject any fix
        // that implies a ground speed above ``maxPlausibleSpeedMps``
        // unless it's been long enough since the last fix to be a
        // legitimate gap. After three consecutive rejections accept
        // anyway — guards against permanent lock-out.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if !fromDeadReckoning,
           let prevLat = lastLat, let prevLon = lastLon, lastFixTsMs > 0 {
            let dtMs = nowMs - lastFixTsMs
            if dtMs > 0, dtMs < teleportRelaxAfterMs {
                let dist = GeoMath.haversineMeters(prevLat, prevLon, lat, lon)
                let allowed = maxPlausibleSpeedMps * Double(dtMs) / 1000.0
                if dist > allowed, dist > teleportMinJumpMeters,
                   teleportConsecutiveDrops < teleportMaxConsecutiveDrops {
                    teleportConsecutiveDrops += 1
                    NSLog("📍 [filter] DROPPING teleport fix \(teleportConsecutiveDrops)/\(teleportMaxConsecutiveDrops): \(Int(dist))m in \(dtMs)ms (max plausible \(Int(allowed))m)")
                    return
                }
            }
        }
        if !fromDeadReckoning {
            teleportConsecutiveDrops = 0
            lastFixTsMs = nowMs
            // Anchor the dead-reckoner on every REAL fix so the next
            // tunnel / GPS gap projects forward from current truth.
            deadReckoner.observe(
                lat: lat, lon: lon,
                courseDeg: bearingDeg.map { Double($0) },
                speedMps: speedMps.map { Double($0) },
                tsMs: nowMs
            )
        }
        // Cache the freshest fix + bearing so an auto-reroute uses the
        // rider's CURRENT position + heading instead of going stale.
        lastLat = lat
        lastLon = lon
        if let bearing = bearingDeg, bearing >= 0, bearing <= 360 {
            lastBearingDeg = bearing
        }

        guard !maneuvers.isEmpty, !shape.isEmpty else {
            // Log when location lands but we have no route loaded yet.
            // Helps distinguish "fix never arrived" from "fix arrived
            // before route fetched".
            NSLog("📍 [trace] loc=(\(String(format:"%.5f",lat)),\(String(format:"%.5f",lon))) speed=\(speedMps.map{String(format:"%.1f",$0)} ?? "?")m/s bearing=\(bearingDeg.map{String(format:"%.0f",$0)} ?? "?")° route=NOT_LOADED")
            return
        }
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

        // One structured trace line per location fix. Captures rider
        // position, geometry projection, and where they are in the
        // route's maneuver sequence — the three pieces needed to
        // diagnose "cues don't match what I see" or "should have
        // rerouted but didn't" without bouncing between three log
        // sources. Logged every ~1.5 s at typical fix cadence.
        let nextType = nextIdx < maneuvers.count ? "\(maneuvers[nextIdx].type)" : "?"
        let alongPct = totalMeters > 0 ? Int(along / totalMeters * 100) : 0
        NSLog("📍 [trace] loc=(\(String(format:"%.5f",lat)),\(String(format:"%.5f",lon))) speed=\(speedMps.map{String(format:"%.1f",$0)} ?? "?")m/s bearing=\(bearingDeg.map{String(format:"%.0f",$0)} ?? "?")° along=\(Int(along))m(\(alongPct)%) lateral=\(String(format:"%.0f", distancePerpToPolyline(lat: lat, lon: lon)))m remaining=\(metersRemaining)m nextMnv=#\(nextIdx)(\(nextType)) in \(Int(distM))m")
    }

    /// Perpendicular distance from a fix to the closest point on the
    /// route polyline. Used purely for diagnostics — the SDK's own
    /// GuidanceMonitor does the same computation internally for the
    /// off-route check.
    private func distancePerpToPolyline(lat: Double, lon: Double) -> Double {
        guard shape.count >= 2 else { return 0 }
        var best = Double.greatestFiniteMagnitude
        for i in 0..<(shape.count - 1) {
            let a = shape[i], b = shape[i+1]
            // shape rows are [lat, lon]. Planar approx uses x=lon, y=lat.
            let d = perpDistanceFromSegment(px: lon, py: lat,
                                             ax: a[1], ay: a[0],
                                             bx: b[1], by: b[0])
            if d < best { best = d }
        }
        // Crude metres conversion at this latitude.
        return best * 111_320
    }

    private func perpDistanceFromSegment(px: Double, py: Double,
                                          ax: Double, ay: Double,
                                          bx: Double, by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let lenSq = dx*dx + dy*dy
        if lenSq == 0 {
            let ddx = px - ax, ddy = py - ay
            return (ddx*ddx + ddy*ddy).squareRoot()
        }
        var t = ((px - ax) * dx + (py - ay) * dy) / lenSq
        t = max(0, min(1, t))
        let cx = ax + t * dx, cy = ay + t * dy
        let ex = px - cx, ey = py - cy
        return (ex*ex + ey*ey).squareRoot()
    }

    public func routeShape() -> [[Double]] { shape }

    /// Start (or restart) the 1 Hz watchdog that fills GPS gaps with
    /// dead-reckoned position projections. Idempotent — the previous
    /// task is cancelled before a new one starts. The task no-ops
    /// until a real fix has anchored the reckoner.
    private func startDeadReckonTaskIfNeeded() {
        deadReckonTask?.cancel()
        deadReckonTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self else { return }
                self.tickDeadReckonIfStale()
            }
        }
    }

    private func tickDeadReckonIfStale() {
        guard !maneuvers.isEmpty, !shape.isEmpty else { return }
        guard lastFixTsMs > 0 else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let gap = now - lastFixTsMs
        // Only synthesise a fix when the gap is INSIDE the dead-
        // reckon window. Inside [start, stop] we project forward; the
        // reckoner itself enforces its own 30 s extrapolation cap so
        // outside the band the projection returns nil and we stay
        // quiet.
        guard gap > deadReckonStartGapMs, gap < deadReckonStopGapMs else {
            return
        }
        guard let projected = deadReckoner.project(nowMs: now) else { return }
        // Preserve the last-known speed + bearing so the reasoner's
        // course-vs-segment check keeps working through the gap. Mark
        // the fix as dead-reckoned so the teleport filter doesn't
        // touch its bookkeeping AND so the reckoner doesn't re-anchor
        // on itself (compounding error).
        NSLog("🕯 [dr] projecting fix at (\(String(format:"%.5f",projected.lat)),\(String(format:"%.5f",projected.lon))) — gap=\(gap)ms")
        onLocation(
            lat: projected.lat, lon: projected.lon,
            speedMps: nil, bearingDeg: lastBearingDeg,
            fromDeadReckoning: true
        )
    }

    /// Tear down the adapter's route state so further ``onLocation``
    /// calls become no-ops and the layer stops firing cues. Call from
    /// the host's stop-nav handler. The layer itself stays alive
    /// (sensors continue) so the next ``startRoute`` is instant.
    ///
    /// Without this, ``onLocation`` keeps projecting against the prior
    /// route and the layer keeps running its progress cycle — a rider
    /// who cancels nav and walks ten metres has the SDK firing
    /// "almost there" cues at them.
    public func stop() {
        maneuvers = []
        shape = []
        cumMeters = []
        maneuverShapeIndices = []
        totalSeconds = 0
        totalMeters = 0
        currentManeuverIdx = 0
        tripScoova = nil
        corridor = nil
        // Push the empty maneuver list through so the layer also drops
        // its current route, clears the banner, and stops scheduling
        // cues. The `onRoute(.., isReroute:)` overload would reset
        // `welcomed` — we use the simple form (`isReroute = false`)
        // so a subsequent start replays the welcome cue naturally.
        layer.onRoute([])
        layer.onTripScoova(nil)
        layer.onCorridor(nil)
        layer.setRouteShape([])
        // Reset reroute / fix-filter bookkeeping so the next trip
        // starts from a clean slate.
        rerouteInFlight = false
        lastRerouteAtMs = 0
        routeInstalledAtMs = 0
        teleportConsecutiveDrops = 0
        lastFixTsMs = 0
        // Stop dead-reckoning + clear the anchor so the next trip
        // doesn't start by extrapolating from a stale position.
        deadReckonTask?.cancel()
        deadReckonTask = nil
        deadReckoner.reset()
    }

    // MARK: - Internals --------------------------------------------------

    /// Rider-to-route stub. The routing engine snaps the input
    /// coord to the nearest routable edge — for a rider in a
    /// parking lot, alley, or pedestrian-only zone, the polyline's
    /// first vertex can be 20–200 m from where the rider actually
    /// is. Drawing the polyline as-is leaves a visible gap between
    /// the puck and the start of the line. Google Maps + Mapbox
    /// solve this by prepending the rider's actual coord as the
    /// polyline's vertex 0. Mirror that: when the gap > 15 m,
    /// prepend (riderLat, riderLon) so the visible line connects.
    /// Threshold is small enough that ordinary engine snap stubs
    /// (typically < 5 m) don't get augmented; only the genuine
    /// off-road case adds the stub.
    internal static func prependRiderStubIfNeeded(
        _ shape: [[Double]],
        riderLat: Double,
        riderLon: Double,
        stubThresholdM: Double = 15
    ) -> [[Double]] {
        guard let first = shape.first,
              first.count >= 2 else { return shape }
        let gap = GeoMath.haversineMeters(
            riderLat, riderLon, first[0], first[1])
        if gap < stubThresholdM { return shape }
        var augmented = shape
        augmented.insert([riderLat, riderLon], at: 0)
        return augmented
    }

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
    /// New since corridor-contract v1. Absent on legacy servers — the
    /// SDK reasoner then falls back to the baked `scoova.voice.*`
    /// strings on each maneuver.
    let corridor: Corridor?
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
    /// Optional so legacy / mocked routes (and older Valhalla responses
    /// without per-maneuver `time`) still decode; consumers treat nil as 0.
    let time: Double?
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

    /// Return a copy with `type` replaced by Valhalla's `.continue`
    /// code (8). Used by the multi-leg concatenator to demote the
    /// intermediate `.depart` / `.arrive` markers at waypoint
    /// boundaries — the SDK doesn't fire the arrival cue mid-trip,
    /// and the rider sees a single continuous instruction stream.
    func withTypeReplacedByContinue() -> RoutingManeuver {
        RoutingManeuver(
            type: 8,                       // Valhalla `.continue`
            instruction: instruction,
            verbalSuccinct: verbalSuccinct,
            length: length,
            time: time,
            beginShapeIndex: beginShapeIndex,
            roundaboutExitCount: roundaboutExitCount,
            scoova: scoova
        )
    }

    init(type: Int, instruction: String?, verbalSuccinct: String?,
         length: Double, time: Double?, beginShapeIndex: Int,
         roundaboutExitCount: Int?, scoova: Scoova?) {
        self.type = type
        self.instruction = instruction
        self.verbalSuccinct = verbalSuccinct
        self.length = length
        self.time = time
        self.beginShapeIndex = beginShapeIndex
        self.roundaboutExitCount = roundaboutExitCount
        self.scoova = scoova
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
    /// Landmark POI's latitude. Server emits this alongside the name so
    /// the SDK can check whether the landmark is still ahead of the
    /// rider before speaking an "After <X>" / "Turn left at <X>" cue —
    /// a landmark already behind the rider makes those forms nonsense.
    /// Nil when no landmark was attached to this maneuver.
    public let landmarkLat: Double?
    public let landmarkLon: Double?
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
    /// Lane-guidance hints for the rider — left-to-right across the
    /// road. Optional because the server may not ship it for every
    /// maneuver (it's expensive to derive). Hosts render these as a
    /// strip under the banner.
    public let lanes: [LaneInfo]?
    /// Posted speed limit (km/h) on the segment leading INTO this
    /// maneuver. Lets the SDK make the "slow down" cue dynamic and
    /// lets the host show a speed-limit pip on the puck. Nil ⇒ server
    /// did not ship a limit.
    public let speedLimitKph: Int?
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
