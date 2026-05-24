import Foundation

/// Continuous closed-loop guidance.
///
/// Ticked from ``ScoovaNavLayer/onProgress(_:)`` (GPS-rate, ~1–4 Hz) and
/// from ``ScoovaNavLayer/onMotion(_:)`` (sensor-rate, ~50 Hz — only the
/// compass heading is fed in to keep heading-mismatch detection live).
///
/// Inputs:
///   * GPS position + speed (from ``ProgressEvent``)
///   * Smoothed compass heading (from MotionFusion via NavLayer)
///   * Route polyline (set once at route-load via ``setRoute(_:)``)
///
/// Outputs: a `[GuidanceEvent]` per tick describing what state the rider
/// just transitioned into. NavLayer maps each event to a phrase from
/// `trip.scoova.state.*` and plays it via the voice engine. Phrases live
/// on the server — this class only emits semantic events.
///
/// State machine (event → trigger → phrase key):
///
///  | Event           | Trigger                                            | Phrase            |
///  |-----------------|----------------------------------------------------|-------------------|
///  | keepGoing       | 40 s of silence on a straight stretch              | keepGoing         |
///  | driftLeft       | 10–30 m right of polyline for 3 s (lean left)      | driftLeft         |
///  | driftRight      | 10–30 m left of polyline for 3 s (lean right)      | driftRight        |
///  | offRoute        | > 30 m off polyline for 5 s                        | wrongWay          |
///  | wrongWayHeading | heading vs polyline bearing > 45° for 3 s @ rest   | wrongWay          |
///  | slowDown        | time-to-maneuver < 3 s at current speed            | slowDown          |
///  | almostThere     | metersRemaining in 50..150                         | almostThere       |
///
/// Each event has its own cooldown (15 s default) so we don't spam the
/// rider with the same phrase. Cross-event isn't deduped — a slowDown
/// can fire right after a keepGoing if the situations warrant.
final class GuidanceMonitor {

    // ── Tunables ──────────────────────────────────────────────────────
    // Silence before the "still on track" chime fires. 40 s is calm —
    // long enough not to nag, short enough that the rider never wonders
    // whether guidance stopped. (The chime, not a spoken phrase, is what
    // plays — see ScoovaNavLayer.handleGuidanceEvent.)
    private let silenceThresholdMs: Int64 = 40_000
    // …or this far covered since the last cue, whichever comes first.
    // The distance cap makes the chime speed-aware: at 100 km/h, 40 s
    // is over a kilometre — too long a gap — so the chime keeps pace
    // with the ground covered instead of the clock alone.
    private let silenceDistanceM: Double = 350.0
    /// Per-costing lateral thresholds. Pedestrian + cyclist sidewalk
    /// offsets routinely sit 10–20 m off the routed centerline (the
    /// sidewalk parallels the road), so a car-tight 30 m off-route
    /// threshold false-fires constantly on foot. The looser numbers
    /// here are still tight enough that genuinely-wrong streets — a
    /// rider one block over — trigger correctly.
    private var costing: String = "auto"
    private var driftMinM: Double { thresholds(costing).drift.min }
    private var driftMaxM: Double { thresholds(costing).drift.max }
    private var offRouteThresholdM: Double { thresholds(costing).offRoute }
    /// Parallel-walking suppressor. When the rider's GPS bearing is
    /// within this many degrees of the route segment's bearing AND
    /// they're moving above the floor speed, drift / off-route events
    /// are suppressed — they're on a sidewalk that parallels the
    /// route, not actually off route. Without this, every NYC
    /// pedestrian on the sidewalk hears "Wrong way, please turn
    /// around" every 5 seconds.
    private let parallelHeadingTolDeg: Float = 35
    private let parallelMinSpeedMps: Float = 0.5
    private let driftDurationMs: Int64 = 3_000
    private let offRouteDurationMs: Int64 = 5_000
    private let headingMismatchDeg: Float = 45
    private let headingMismatchDurationMs: Int64 = 3_000
    private let maxSpeedForHeadingCheckMps: Float = 2.0  // only at standstill
    private let slowDownTimeToManeuverSec: Double = 3.0
    // "Slow down, turn coming" is a genuine-overspeed safety cue, not a
    // per-turn nag. 13 m/s ≈ 47 km/h — above any persona's normal
    // cruising pace; a rider at normal speed gets the turn cue alone.
    private let slowDownMinSpeedMps: Float = 13.0
    private let sameEventCooldownMs: Int64 = 15_000
    private let almostThereWindow: ClosedRange<Int> = 50...150

    /// Mode-aware lateral thresholds.
    /// - pedestrian: walkway can sit 15 m off the routed centreline,
    ///   plaza paths 25 m+. Keep "off-route" honest at 60 m.
    /// - bicycle / scooter: painted bike lanes sit 3–6 m off but the
    ///   GPS jitter on a bike adds 10 m. 50 m off-route catches a
    ///   real wrong-street.
    /// - motorcycle / auto: the historic car-tight values.
    private func thresholds(_ costing: String)
        -> (drift: (min: Double, max: Double), offRoute: Double)
    {
        switch costing {
        case "pedestrian":          return ((20, 60), 60)
        case "bicycle", "scooter":  return ((15, 40), 50)
        case "motorcycle":          return ((12, 35), 40)
        default:                    return ((10, 30), 30)   // auto
        }
    }

    // ── Route + sensor state ──────────────────────────────────────────
    private var shape: [[Double]] = []
    private var compassHeadingDeg: Float? = nil

    // ── Timers & dedup ────────────────────────────────────────────────
    private var lastSpokeAt: Int64 = 0
    private var lastEventAt: [EventKind: Int64] = [:]
    private var driftStartedAt: Int64 = 0
    private var driftDirection: DriftDir? = nil
    private var offRouteStartedAt: Int64 = 0
    private var headingMismatchStartedAt: Int64 = 0
    /// Latest `metersRemaining` seen, and its value when a cue last
    /// spoke — together these measure distance covered since the last
    /// cue, for the speed-aware keep-going chime.
    private var latestMetersRemaining: Int = 0
    private var metersRemainingAtSpoke: Int = 0

    public init() {}

    /// Adapter calls this once per route load.
    public func setRoute(_ routeShape: [[Double]]) {
        self.shape = routeShape
        reset()
    }

    /// Adapter sets the routing profile (pedestrian / bicycle / scooter
    /// / motorcycle / auto) so the drift + off-route thresholds can
    /// scale to mode. Pedestrian on a sidewalk lives 10–20 m off the
    /// routed centerline — without this, every NYC walk false-fires
    /// "wrong way, turn around" the moment the rider steps onto the
    /// kerb. Default `auto` matches the historic tight thresholds.
    public func setCosting(_ c: String) {
        self.costing = c
    }

    /// Reset timers (e.g. on re-route). Doesn't clear the polyline.
    public func reset() {
        lastSpokeAt = 0
        lastEventAt.removeAll()
        driftStartedAt = 0
        driftDirection = nil
        offRouteStartedAt = 0
        headingMismatchStartedAt = 0
        latestMetersRemaining = 0
        metersRemainingAtSpoke = 0
    }

    /// Called by NavLayer every time it actually speaks a cue (or plays
    /// the chime). Resets the silence timer — both the clock and the
    /// distance-covered baseline — so the next chime stays well-spaced.
    public func markSpoke(nowMs: Int64? = nil) {
        lastSpokeAt = nowMs ?? GuidanceMonitor.currentTimeMillis()
        metersRemainingAtSpoke = latestMetersRemaining
    }

    /// Called from MotionFusion output via NavLayer. Heading is live
    /// for the next ``onProgress(_:nowMs:)`` tick.
    public func onCompassHeading(_ degrees: Float) {
        compassHeadingDeg = degrees
    }

    /// Called from `ScoovaNavLayer.onProgress`. Returns the events that
    /// fired this tick — caller plays the matching phrase and calls
    /// ``markSpoke(nowMs:)`` when it does. Empty array = nothing to say.
    public func onProgress(
        _ p: ProgressEvent,
        nowMs: Int64? = nil
    ) -> [GuidanceEvent] {
        let nowMs = nowMs ?? GuidanceMonitor.currentTimeMillis()
        latestMetersRemaining = p.metersRemaining   // for the chime cadence
        if shape.count < 2 { return [] }
        guard let proj = projectOntoPolyline(lat: p.latitude, lon: p.longitude, shape: shape) else {
            return []
        }

        var events: [GuidanceEvent] = []

        // ── Parallel-walking suppression ─────────────────────────────
        // If the rider is moving and their GPS heading aligns with the
        // route's local bearing, they're walking parallel to the
        // route — on a sidewalk, in a bike lane, or just hugging one
        // side of a wide path. That is NOT off-route, no matter how
        // far they look from the polyline. Skip the drift and off-
        // route checks for this tick; the underlying lateral-offset
        // sample is real but it does not describe a navigation error.
        //
        // Falls through to the standard checks at standstill (speed
        // is unreliable, can't trust the direction) so a parked rider
        // who genuinely strayed still gets a "wrong way" eventually.
        let isParallel: Bool = {
            guard let b = p.bearingDeg, let s = p.speedMps,
                  s >= parallelMinSpeedMps else { return false }
            let delta = angleDeltaAbs(b, proj.segmentBearingDeg)
            return delta < parallelHeadingTolDeg
        }()

        // ── Off-route: highest priority ──────────────────────────────
        if !isParallel, proj.lateralM > offRouteThresholdM {
            if offRouteStartedAt == 0 {
                offRouteStartedAt = nowMs
            } else if nowMs - offRouteStartedAt > offRouteDurationMs,
                      shouldFire(.offRoute, nowMs: nowMs) {
                events.append(.offRoute(lateralM: proj.lateralM))
                offRouteStartedAt = nowMs
            }
            // Off-route supersedes drift — clear drift state.
            driftStartedAt = 0
            driftDirection = nil
        } else {
            offRouteStartedAt = 0
        }

        // ── Drift: only when not off-route AND not walking parallel ──
        if !isParallel, offRouteStartedAt == 0,
           proj.lateralM > driftMinM, proj.lateralM <= driftMaxM {
            let dir: DriftDir = proj.lateralSign > 0 ? .right : .left
            if driftDirection != dir {
                driftStartedAt = nowMs
                driftDirection = dir
            } else if nowMs - driftStartedAt > driftDurationMs {
                // Tell the rider to lean OPPOSITE to where they drifted
                let event: GuidanceEvent = dir == .right
                    ? .driftLeft(lateralM: proj.lateralM)
                    : .driftRight(lateralM: proj.lateralM)
                if shouldFire(event.kind, nowMs: nowMs) {
                    events.append(event)
                    driftStartedAt = nowMs
                }
            }
        } else if offRouteStartedAt == 0 {
            driftStartedAt = 0
            driftDirection = nil
        }

        // ── Heading mismatch: only at standstill (GPS bearing unreliable) ─
        let compass = compassHeadingDeg
        let speed = p.speedMps
        if let compass = compass,
           speed == nil || speed! < maxSpeedForHeadingCheckMps {
            let mismatchDeg = angleDeltaAbs(compass, proj.segmentBearingDeg)
            if mismatchDeg > headingMismatchDeg {
                if headingMismatchStartedAt == 0 {
                    headingMismatchStartedAt = nowMs
                } else if nowMs - headingMismatchStartedAt > headingMismatchDurationMs,
                          shouldFire(.wrongWayHeading, nowMs: nowMs) {
                    events.append(.wrongWayHeading(mismatchDeg: mismatchDeg))
                    headingMismatchStartedAt = nowMs
                }
            } else {
                headingMismatchStartedAt = 0
            }
        } else {
            headingMismatchStartedAt = 0
        }

        // ── Speed warning: going too fast for upcoming maneuver ──────
        if let speed = speed,
           speed > slowDownMinSpeedMps,
           p.metersToUpcomingManeuver > 5.0 {
            let timeToManeuver = p.metersToUpcomingManeuver / Double(speed)
            if timeToManeuver < slowDownTimeToManeuverSec,
               shouldFire(.slowDown, nowMs: nowMs) {
                events.append(.slowDown(secondsToManeuver: timeToManeuver))
            }
        }

        // ── Almost-there: between 50 and 150 m of total route remaining ──
        if almostThereWindow.contains(p.metersRemaining),
           shouldFire(.almostThere, nowMs: nowMs) {
            // Side hint lives on the maneuver type at the final step —
            // adapter populates it. We don't have it here directly, so
            // emit a neutral almostThere; NavLayer can pick the sided
            // variant from its current maneuver.
            events.append(.almostThere)
        }

        // ── Keep-going heartbeat ─────────────────────────────────────
        // Fires the soft chime after 40 s of silence OR ~350 m covered
        // since the last cue — whichever first. The distance arm makes
        // it speed-aware: at speed the rider hears the pulse keep pace
        // with the ground, not a fixed clock that leaves a long gap.
        let coveredSinceCue = metersRemainingAtSpoke - p.metersRemaining
        if lastSpokeAt > 0,
           (nowMs - lastSpokeAt > silenceThresholdMs
            || Double(coveredSinceCue) > silenceDistanceM),
           shouldFire(.keepGoing, nowMs: nowMs) {
            events.append(.keepGoing)
        }

        return events
    }

    private func shouldFire(_ kind: EventKind, nowMs: Int64) -> Bool {
        let last = lastEventAt[kind] ?? 0
        if nowMs - last < sameEventCooldownMs { return false }
        lastEventAt[kind] = nowMs
        return true
    }

    private enum DriftDir { case left, right }
    fileprivate enum EventKind: Hashable {
        case keepGoing, driftLeft, driftRight, slowDown,
             wrongWayHeading, offRoute, almostThere
    }

    public static func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// Semantic guidance events. Stateless — the ``GuidanceMonitor`` times
/// them and ``ScoovaNavLayer`` maps each to a server-rendered phrase
/// (`trip.scoova.state.keepGoing` / `.driftLeft` / `.slowDown` / etc.).
enum GuidanceEvent: Sendable, Equatable {
    /// 40 s of silence on a straight stretch — reassure the rider.
    case keepGoing
    /// Drifting too far right of the polyline; tell rider to lean left.
    case driftLeft(lateralM: Double)
    /// Drifting too far left of the polyline; tell rider to lean right.
    case driftRight(lateralM: Double)
    /// Speed × time-to-maneuver below comfort threshold — slow down.
    case slowDown(secondsToManeuver: Double)
    /// Standstill but facing > 45° away from the polyline bearing.
    case wrongWayHeading(mismatchDeg: Float)
    /// Persistently > 30 m off the polyline — needs re-route.
    case offRoute(lateralM: Double)
    /// 50–150 m to destination — fire the "almost there" cue.
    case almostThere

    /// Map a public event back to its dedup key.
    fileprivate var kind: GuidanceMonitor.EventKind {
        switch self {
        case .keepGoing:       return .keepGoing
        case .driftLeft:       return .driftLeft
        case .driftRight:      return .driftRight
        case .slowDown:        return .slowDown
        case .wrongWayHeading: return .wrongWayHeading
        case .offRoute:        return .offRoute
        case .almostThere:     return .almostThere
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Polyline projection — internal but exposed for unit tests.
// ─────────────────────────────────────────────────────────────────────

internal struct PolylineProjection: Equatable {
    /// Distance travelled along the polyline up to the projected point.
    let progressM: Double
    /// Unsigned perpendicular distance from polyline to query point.
    let lateralM: Double
    /// Sign of the lateral offset. Positive = right of polyline (in
    /// travel direction), negative = left.
    let lateralSign: Double
    /// Forward bearing of the polyline segment at the projection.
    let segmentBearingDeg: Float
}

/// Project a point onto the polyline. Uses Euclidean approximation
/// (treats lat/lon as planar — fine at city scale, errors < 0.1% inside
/// ~10 km radius). For each segment computes the foot of perpendicular,
/// picks the closest segment, and returns progress + lateral offset +
/// segment bearing.
internal func projectOntoPolyline(
    lat: Double,
    lon: Double,
    shape: [[Double]]
) -> PolylineProjection? {
    if shape.count < 2 { return nil }
    var bestSeg = 0
    var bestLatProj = lat
    var bestLonProj = lon
    var bestDistM = Double.greatestFiniteMagnitude

    for i in 0..<(shape.count - 1) {
        let a = shape[i]
        let b = shape[i + 1]
        // Use lon = x, lat = y in planar approx.
        let ax = a[1]; let ay = a[0]
        let bx = b[1]; let by = b[0]
        let px = lon;  let py = lat
        let abx = bx - ax; let aby = by - ay
        let apx = px - ax; let apy = py - ay
        let ab2 = abx * abx + aby * aby
        let t: Double
        if ab2 < 1e-15 {
            t = 0.0
        } else {
            let raw = (apx * abx + apy * aby) / ab2
            t = min(1.0, max(0.0, raw))
        }
        let cx = ax + abx * t
        let cy = ay + aby * t
        let d = GeoMath.haversineMeters(py, px, cy, cx)
        if d < bestDistM {
            bestDistM = d
            bestSeg = i
            bestLatProj = cy
            bestLonProj = cx
        }
    }

    let a = shape[bestSeg]
    let b = shape[bestSeg + 1]
    // Lateral sign — 2D cross product of (segment vector) × (a→point vector).
    // Positive cross = point lies to the left of travel direction, negative = right.
    // We want POSITIVE = right (matches "drift right" semantics) → invert sign.
    let cross = (b[1] - a[1]) * (lat - a[0]) - (b[0] - a[0]) * (lon - a[1])
    let sign: Double = cross < 0 ? 1.0 : -1.0

    // Progress: sum of full segments before bestSeg + partial of bestSeg.
    var progress = 0.0
    if bestSeg > 0 {
        for i in 0..<bestSeg {
            progress += GeoMath.haversineMeters(
                shape[i][0], shape[i][1],
                shape[i + 1][0], shape[i + 1][1]
            )
        }
    }
    progress += GeoMath.haversineMeters(a[0], a[1], bestLatProj, bestLonProj)

    let bearing = Float(GeoMath.bearingDeg(a[0], a[1], b[0], b[1]))
    return PolylineProjection(
        progressM: progress,
        lateralM: bestDistM,
        lateralSign: sign,
        segmentBearingDeg: bearing
    )
}

/// Smallest absolute angular distance between two bearings (degrees).
internal func angleDeltaAbs(_ a: Float, _ b: Float) -> Float {
    var d = abs(a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d = 360 - d }
    return d
}
