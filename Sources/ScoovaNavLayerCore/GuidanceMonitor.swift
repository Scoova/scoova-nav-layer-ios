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
    /// Persistence at which the SDK first whispers "you might be off
    /// the route" without yet calling a reroute. Buys the rider a
    /// chance to course-correct before we wipe their route line.
    /// Half the hard threshold so a brief excursion (mis-set lane,
    /// quick lane change to overtake) doesn't both alert AND fetch.
    private let softOffRouteDurationMs: Int64 = 2_500
    private let offRouteDurationMs: Int64 = 5_000
    private let headingMismatchDeg: Float = 45
    private let headingMismatchDurationMs: Int64 = 3_000
    private let maxSpeedForHeadingCheckMps: Float = 2.0  // only at standstill

    // ── Moving-speed wrong-way detection ─────────────────────────────
    // The standstill compass check above tells the SDK which way the
    // device is FACING when the rider is parked. While moving, the
    // compass is dominated by handlebar/torso orientation and unreliable;
    // CLLocation.course (the GPS-derived bearing-of-travel) is the
    // truth. Below: if a moving rider's course is opposed to the
    // routed segment's bearing for a sustained window, they're going
    // the wrong way down the route.
    //
    // 120° tolerance — anything tighter than that fires false on
    // U-curves and roundabouts (where the rider is briefly heading
    // backwards relative to the next segment).
    private let reverseHeadingDeg: Float = 120
    /// Speed at which the GPS course becomes reliable. ~2 m/s = 7 km/h
    /// matches CoreLocation's own confidence ramp.
    private let reverseHeadingMinSpeedMps: Float = 2.0
    /// How long the rider must hold a reverse course before we fire.
    /// 4 s outlasts a typical roundabout traversal so we don't false
    /// on standard turns.
    private let reverseHeadingDurationMs: Int64 = 4_000
    private var reverseHeadingStartedAt: Int64 = 0
    private let slowDownTimeToManeuverSec: Double = 3.0
    // "Slow down, turn coming" is a genuine-overspeed safety cue, not a
    // per-turn nag. 13 m/s ≈ 47 km/h — above any persona's normal
    // cruising pace; a rider at normal speed gets the turn cue alone.
    private let slowDownMinSpeedMps: Float = 13.0
    private let sameEventCooldownMs: Int64 = 15_000
    /// Mode-aware "almost there" window. "Your destination is just
    /// ahead" wants a lead of ~10–25 s — long enough for the rider to
    /// scan for the kerb-cut / parking spot, short enough that "just
    /// ahead" reads as truthful. Earlier values topped out at 30–40+ s
    /// of lead (e.g. scooter at 250 m ≈ 42 s), which rode as "the SDK
    /// keeps announcing the destination ages before I'm anywhere near
    /// it." Cap the lead at ~25 s at the persona's cruise pace.
    private var almostThereWindow: ClosedRange<Int> {
        switch costing {
        case "pedestrian":          return 15...35      // ~11–25 s @ 1.4 m/s
        case "bicycle":             return 40...100     // ~10–25 s @ 4 m/s
        case "scooter":             return 60...150     // ~10–25 s @ 6 m/s
        case "motorcycle":          return 100...300    // ~8–25 s @ 12 m/s
        default:                    return 140...350    // ~10–25 s @ 14 m/s (auto)
        }
    }

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
        // Safe-default tier — Apple Maps / Google Maps / Mapbox Nav SDK
        // all sit in this range. Urban CoreLocation accuracy is 5–15 m
        // typical, 15–30 m near tall buildings / under tree cover, so
        // an off-route threshold below ~40 m fires on GPS jitter as
        // often as on real deviation. Drift band stays just inside the
        // off-route band so the rider gets a "lean right / lean left"
        // hint before the reroute fires.
        //
        // We tried 25 m first; in dense-urban field testing it would
        // trigger false reroutes near tall buildings before the rider
        // actually deviated. Backed off to 40 m for bike / scooter /
        // motorcycle and 50 m for pedestrian (walks happen on
        // sidewalks parallel to the polyline so the lateral baseline
        // is higher).
        switch costing {
        case "pedestrian":          return ((10, 35), 50)
        case "bicycle", "scooter":  return ((10, 30), 40)
        case "motorcycle":          return ((10, 30), 40)
        default:                    return ((10, 25), 30)   // auto
        }
    }

    // ── Reasoner inputs ───────────────────────────────────────────────
    //
    // When ``ScoovaNavLayer`` has a corridor for the trip, it produces
    // a ``LiveGuidanceState`` per progress tick and feeds it in here
    // via ``setLiveAlignment(_:)``. The monitor then prefers the
    // graph-topology signals over the lateral-distance heuristics:
    //
    //   • Off-route: fingerprint mismatch is an EARLIER signal than
    //     lateral. A rider on a parallel street ten metres from the
    //     route polyline reads as lateral=OK but graph=MISMATCH, which
    //     is the wrong-street case lateral was always missing.
    //
    //   • Wrong-way (moving): reasoner already computes
    //     `courseMatchesSegment` against the rider's actual graph
    //     segment direction — far more precise than the 120° course-
    //     vs-route-polyline check below, because it uses the OSM way
    //     direction the rider is genuinely on.
    //
    // Both checks fall back to the lateral / polyline heuristics when
    // no corridor was shipped — legacy services keep working.
    private var liveAlignment: LiveGuidanceState.Alignment? = nil
    private var liveGraphMatched: Bool = false

    // ── Route + sensor state ──────────────────────────────────────────
    private var shape: [[Double]] = []
    private var compassHeadingDeg: Float? = nil

    // ── Timers & dedup ────────────────────────────────────────────────
    private var lastSpokeAt: Int64 = 0
    private var lastEventAt: [EventKind: Int64] = [:]
    private var driftStartedAt: Int64 = 0
    private var driftDirection: DriftDir? = nil
    private var offRouteStartedAt: Int64 = 0
    /// Latches once the soft warning fires for the current off-route
    /// excursion, so the SDK doesn't emit the soft cue and then a
    /// near-identical hard cue 2.5 s later. Cleared when the rider
    /// returns onto the polyline.
    private var softOffRouteFiredForThisExcursion: Bool = false
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
        reverseHeadingStartedAt = 0
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

    /// Called from ``ScoovaNavLayer.onProgress`` after the reasoner has
    /// produced this tick's ``LiveGuidanceState``. The monitor reads
    /// the alignment to prefer graph-topology signals (fingerprint
    /// match + course-vs-segment direction) over lateral-distance
    /// heuristics for off-route and wrong-way checks. Pass ``nil``
    /// when no corridor was shipped — the monitor then falls back to
    /// the legacy lateral / polyline-bearing checks.
    public func setLiveAlignment(_ alignment: LiveGuidanceState.Alignment?,
                                 graphMatched: Bool) {
        self.liveAlignment = alignment
        self.liveGraphMatched = graphMatched
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
        // route's local bearing AND they're not too far from the line,
        // they're walking parallel to the route — on a sidewalk, in a
        // bike lane, or hugging one side of a wide path. That is NOT
        // off-route. Skip the drift / off-route checks for this tick.
        //
        // HARD CAP: parallel suppression only applies inside the drift
        // band (≤ drift-max metres). Beyond that, the rider is on a
        // genuinely different street — even if it happens to point the
        // same way as the route — and off-route MUST fire so a reroute
        // can refetch from where they actually are. (Without the cap,
        // a rider 90 m off the route heading north on a parallel
        // street never gets a reroute, which the log confirmed in the
        // 2026-05-28 test session.)
        let isParallel: Bool = {
            guard let b = p.bearingDeg, let s = p.speedMps,
                  s >= parallelMinSpeedMps else { return false }
            // Hard cap: never suppress beyond the drift band.
            let driftMax = thresholds(costing).drift.max
            if proj.lateralM > driftMax { return false }
            let delta = angleDeltaAbs(b, proj.segmentBearingDeg)
            return delta < parallelHeadingTolDeg
        }()

        // ── Off-route: highest priority ──────────────────────────────
        // Two stages (soft / hard). The PRIMARY signal is lateral
        // distance to the route polyline — that's the only signal
        // the device can derive honestly today.
        //
        // The corridor's graph-fingerprint signal is informative but
        // not authoritative: the fingerprint list only describes the
        // ROUTE'S OWN ways, so a fingerprint match means "the rider's
        // projected position is near the route" — essentially a
        // lateral-proximity proxy, not real map-matching. Without an
        // on-device neighbour graph we can't tell which OTHER road
        // the rider is on. So we never let "fingerprint matched"
        // suppress the lateral check; the rider going 50 m off the
        // line in the wrong direction MUST fire off-route. The
        // reasoner's lateral guard on `segmentOnGraph` (25 m)
        // already prevents that false-positive.
        //
        // Future work: server emits a neighbour-corridor with
        // adjacent ways, and the SDK does real on-device map-
        // matching against that local sub-graph. Then graph mismatch
        // becomes an authoritative EARLIER signal.
        if !isParallel, proj.lateralM > offRouteThresholdM {
            if offRouteStartedAt == 0 {
                offRouteStartedAt = nowMs
                softOffRouteFiredForThisExcursion = false
            }
            let elapsed = nowMs - offRouteStartedAt
            if elapsed > offRouteDurationMs, shouldFire(.offRoute, nowMs: nowMs) {
                events.append(.offRoute(lateralM: proj.lateralM))
                offRouteStartedAt = nowMs
                softOffRouteFiredForThisExcursion = false
            } else if elapsed > softOffRouteDurationMs,
                      !softOffRouteFiredForThisExcursion,
                      shouldFire(.softOffRoute, nowMs: nowMs) {
                events.append(.softOffRoute(lateralM: proj.lateralM))
                softOffRouteFiredForThisExcursion = true
            }
            // Off-route supersedes drift — clear drift state.
            driftStartedAt = 0
            driftDirection = nil
        } else {
            offRouteStartedAt = 0
            softOffRouteFiredForThisExcursion = false
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

        // ── Reverse-course detection: AT MOVING SPEED ───────────────
        // The compass check above only runs at standstill. While moving,
        // GPS course (bearing-of-travel) is the reliable signal — a
        // rider on a scooter at 25 km/h who's pointed the wrong way
        // down the route gets no warning from the compass check
        // (handlebar orientation dominates the magnetometer), but the
        // GPS course is dead-clear. Without this branch, a rider
        // genuinely riding the wrong way down a one-way street hears
        // nothing until the off-route lateral threshold fires — which
        // is too late if they're following the routed line geometrically.
        //
        // Fires only when:
        //   • GPS course is available and speed > 2 m/s (course noisy below)
        //   • Bearing differs from route segment by > 120° (clearly opposed)
        //   • Sustained for 4 s (filters U-curves, roundabouts)
        //   • Not parallel-walking (handled by the suppression above)
        if !isParallel,
           proj.lateralM <= offRouteThresholdM,  // on-route only
           let bearing = p.bearingDeg,
           let s = speed, s >= reverseHeadingMinSpeedMps {
            // Moving wrong-way is a DIRECTION cue for a rider who is
            // ON the route but pointed backwards. Once the rider has
            // strayed beyond the off-route lateral band they are no
            // longer on the route polyline — they're on a different
            // street whose direction has no relationship to the
            // route's segment bearing. The previous code ran this
            // check anyway and lit up "Wrong way — please turn around"
            // every time a rider drifted into a side street, which
            // mis-labelled lateral drift as a U-turn problem. Off-
            // route owns the alert at that point.
            //
            // Reasoner's `courseMatchesSegment` (when present) is the
            // authoritative graph-direction check — uses the segment
            // direction of the rider's projected position. Fall back
            // to the polyline-bearing comparison when no corridor was
            // shipped.
            let courseMatches = liveAlignment?.courseMatchesSegment
            let mismatchDeg = angleDeltaAbs(bearing, proj.segmentBearingDeg)
            let reverseFromReasoner = (courseMatches == false)
            let reverseFromPolyline = (courseMatches == nil) && mismatchDeg > reverseHeadingDeg
            if reverseFromReasoner || reverseFromPolyline {
                if reverseHeadingStartedAt == 0 {
                    reverseHeadingStartedAt = nowMs
                } else if nowMs - reverseHeadingStartedAt > reverseHeadingDurationMs,
                          shouldFire(.wrongWayHeading, nowMs: nowMs) {
                    events.append(.wrongWayHeading(mismatchDeg: mismatchDeg))
                    reverseHeadingStartedAt = nowMs
                }
            } else {
                reverseHeadingStartedAt = 0
            }
        } else {
            reverseHeadingStartedAt = 0
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
             wrongWayHeading, softOffRoute, offRoute, almostThere
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
    /// Rider has been beyond the off-route threshold for ~2.5 s — a
    /// heads-up before the SDK triggers a refetch. Does NOT request a
    /// reroute; just speaks a soft "looks like you may be off-route"
    /// cue. Lets the rider correct before the hard reroute fires.
    case softOffRoute(lateralM: Double)
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
        case .softOffRoute:    return .softOffRoute
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

/// Project a point onto the polyline. Works in **metric** local
/// coordinates — lon is scaled by `cos(lat)` so the foot of
/// perpendicular is geometrically correct, not skewed toward N–S on
/// E–W segments. (Treating raw lon/lat as a flat plane works near the
/// equator but biases the perpendicular badly at high latitudes — at
/// 45°N, 1° lon ≈ 78 km vs 1° lat ≈ 111 km, so a "perpendicular"
/// computed in degree space leans ~30% toward east-west.)
///
/// Same coordinate convention as ``ScoovaRoutingAdapter.distanceAlongRoute``
/// — the two projections must agree, otherwise GuidanceMonitor's
/// off-route check and the cue engine's progress can disagree about
/// whether the rider is on the route.
///
/// Returns: progress along the polyline (m), unsigned lateral distance
/// (m), sign of the lateral offset (positive = right of travel
/// direction), and the bearing of the segment at the projection.
internal func projectOntoPolyline(
    lat: Double,
    lon: Double,
    shape: [[Double]]
) -> PolylineProjection? {
    if shape.count < 2 { return nil }
    // Local equirectangular metres — accurate over a single segment
    // at the rider's latitude.
    let mPerDegLat = 111_320.0
    let mPerDegLon = 111_320.0 * cos(lat * .pi / 180)

    var bestSeg = 0
    var bestProjMx = lon * mPerDegLon
    var bestProjMy = lat * mPerDegLat
    var bestDistM = Double.greatestFiniteMagnitude

    let rx = lon * mPerDegLon
    let ry = lat * mPerDegLat
    for i in 0..<(shape.count - 1) {
        let a = shape[i]
        let b = shape[i + 1]
        let ax = a[1] * mPerDegLon; let ay = a[0] * mPerDegLat
        let bx = b[1] * mPerDegLon; let by = b[0] * mPerDegLat
        let abx = bx - ax;          let aby = by - ay
        let apx = rx - ax;          let apy = ry - ay
        let ab2 = abx * abx + aby * aby
        let t: Double
        if ab2 < 1e-9 {
            t = 0.0
        } else {
            let raw = (apx * abx + apy * aby) / ab2
            t = min(1.0, max(0.0, raw))
        }
        let cx = ax + abx * t
        let cy = ay + aby * t
        let dx = rx - cx, dy = ry - cy
        let d = (dx * dx + dy * dy).squareRoot()
        if d < bestDistM {
            bestDistM = d
            bestSeg = i
            bestProjMx = cx
            bestProjMy = cy
        }
    }

    let a = shape[bestSeg]
    let b = shape[bestSeg + 1]
    // Lateral sign — 2D cross of (segment vector) × (point vector) in
    // METRIC space. The scaling preserves sign, so this is equivalent
    // to the historic degree-space cross, but kept here in metric
    // coordinates for clarity. cross > 0 ⇒ point is LEFT of segment;
    // we want sign = +1 for RIGHT, so invert.
    let segDx = (b[1] - a[1]) * mPerDegLon
    let segDy = (b[0] - a[0]) * mPerDegLat
    let pointDx = (lon - a[1]) * mPerDegLon
    let pointDy = (lat - a[0]) * mPerDegLat
    let cross = segDx * pointDy - segDy * pointDx
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
    // Project bestProj back to degrees to call haversine for the
    // partial-segment progress.
    let bestProjLat = bestProjMy / mPerDegLat
    let bestProjLon = bestProjMx / mPerDegLon
    progress += GeoMath.haversineMeters(a[0], a[1], bestProjLat, bestProjLon)

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
