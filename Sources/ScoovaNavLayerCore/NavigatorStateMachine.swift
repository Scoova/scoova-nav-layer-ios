import Foundation

/// The navigator sitting next to the rider. Owns the conceptual state
/// of the trip — what is the rider doing right now, and what (if
/// anything) should I say about it. Replaces the cue scheduler with
/// a state machine that runs on every progress tick.
///
/// Five states. One active at a time. Transitions are driven by the
/// reasoner's ``LiveGuidanceState`` and the upcoming maneuver. Cues
/// are emitted ONLY at state transitions or at clear sub-events within
/// a state. The navigator doesn't talk on a schedule — he talks when
/// something needs saying.
///
/// | State            | Meaning                                    |
/// |------------------|--------------------------------------------|
/// | cruising         | On route, on the right way, far from a decision |
/// | approachingTurn  | Inside the cue-lead distance of the next turn |
/// | offRoute         | Snapped to a non-route way, or far from any way |
/// | wrongWay         | On the right way but going against expected direction |
/// | pastDestination  | Drove past the destination — silent guidance is unacceptable |
/// | arrived          | Trip complete |
public final class NavigatorStateMachine {

    public enum State: Sendable, Equatable {
        case idle
        case cruising
        case approachingTurn(maneuverIndex: Int)
        case offRoute(snappedWayName: String, sinceMs: Int64)
        case wrongWay(snappedWayName: String, sinceMs: Int64)
        case stuckInTraffic(sinceMs: Int64)
        case pastDestination(sinceMs: Int64)
        case arrived
    }

    /// One emitted cue intent — the navigator's decision about WHAT
    /// needs saying. ``ScoovaNavLayer`` maps the intent to a phrase
    /// (via grammar, server vocab, or `voiceRecover` etc.) and speaks
    /// it. The intent isn't text — it's the reason for speaking.
    public enum CueIntent: Sendable, Equatable {
        /// Welcome at trip start. Once per trip.
        case welcome
        /// Approach cue at the given phase. The text is chosen by the
        /// grammar, anchored on the upcoming maneuver.
        case approach(phase: CueGrammar.Phase, maneuverIndex: Int)
        /// Ambiguity heads-up. Fired ~250 m out from a maneuver whose
        /// corridor block flagged "multiple same-side turns" — proactive
        /// "two lefts ahead — take the SECOND one" so the rider is
        /// expecting the ordinal before the per-phase cues arrive.
        case ambiguityHeadsUp(maneuverIndex: Int)
        /// Rider has been stationary on the route for > 30 s. Speaks
        /// every 60 s while in this state so the rider knows the
        /// navigator hasn't died — *"Still on track. Stay on this road."*
        case stuckInTraffic
        /// Eyes-off narration cue. Names a landmark the rider is
        /// passing right now — the navigator's "you're walking past
        /// the museum on your right." Drawn from the server's per-
        /// maneuver `voiceCheckpoint`, fired at `checkpointOffsetMeters`
        /// past the previous maneuver.
        case checkpoint(maneuverIndex: Int)
        /// Long-stretch reassurance. Fired when the navigator has been
        /// silent for ~75 s and the rider is comfortably on a route
        /// way with no decision imminent. Speaks the maneuver's
        /// `voiceReaffirm` ("Still on Camelback Road") + the live
        /// distance to the next turn. Without this the SDK goes mute
        /// on long boring segments and riders think the app died.
        case reaffirm(maneuverIndex: Int)
        /// **Missed turn.** The rider was supposed to turn at maneuver
        /// N but kept going straight — their snapped way is still the
        /// pre-turn way. Fired the moment the cursor advances past N
        /// without the rider's actual road having changed. Triggers a
        /// reroute and speaks "You missed the turn — recalculating."
        case missedTurn(maneuverIndex: Int)
        /// Rider has drifted off the route's way set. ``snappedName``
        /// names the way they're on now (may be empty).
        case offRoute(snappedName: String)
        /// Rider is on the right way but going backwards.
        case wrongWay(snappedName: String)
        /// Past destination — rider drove past the pin without stopping.
        case pastDestination
        /// Reached the destination cleanly.
        case arrived
        /// Confirmation after a turn lands ("Good, you're on X").
        case confirm(maneuverIndex: Int)
    }

    public private(set) var state: State = .idle
    /// Wall-clock (ms) of the last cue intent we emitted. Drives the
    /// per-state cooldowns — the navigator never repeats himself
    /// within 15 s in the same state.
    private var lastIntentAtMs: [String: Int64] = [:]
    private let perIntentCooldownMs: Int64 = 15_000
    /// Approach-cue lead times in SECONDS — the navigator targets the
    /// SAME reaction window across personas. A walker at 1.4 m/s and
    /// a driver at 14 m/s both hear "turn coming up" 25 s out — the
    /// distance differs (35 m vs 350 m) because the speed differs.
    /// Without this scaling the per-phase cues fire too early on
    /// foot (walker hears "in 200 m turn left" with 2½ minutes to
    /// go) or too late in a car (10 seconds isn't enough to merge).
    private let approachLeadSeconds: [CueGrammar.Phase: Double] = [
        .far: 25, .mid: 12, .near: 3
    ]
    /// Fallback speed when no GPS speed is available (first fix, sim,
    /// stationary). Same per-profile defaults used elsewhere in the
    /// SDK — keeps cue timing sensible while the rider is paused
    /// without making the trigger fire at the speed of light.
    private let approachFallbackSpeedMps: Double = 5.0
    /// Hard caps: a stopped rider doesn't get an approach cue (trigger
    /// = 0); a GPS-spiked speed doesn't fire a cue 800 m out.
    private let approachMinSpeedMps: Double = 0.5
    private let approachMaxSpeedMps: Double = 28.0
    private var firedApproachPhases: [Int: Set<CueGrammar.Phase>] = [:]
    /// Last maneuver index we fired a near-phase approach for. When
    /// the rider's upcoming index advances past this one AND they're
    /// still on a route way, the navigator emits a `.confirm` intent
    /// — the human "yes, you got it" after a turn lands.
    private var lastNearFiredFor: Int? = nil
    /// Maneuver indices we've already confirmed, so a noisy upcoming-
    /// index oscillation doesn't double-fire the confirm cue.
    private var confirmedManeuvers: Set<Int> = []
    /// Per-maneuver snap of "what OSM way was the rider on when the
    /// near cue fired for this turn?" — the **pre-turn** way. When
    /// the cursor advances past a maneuver, we compare the rider's
    /// CURRENT snapped way to the pre-turn one. If they're the same
    /// the rider drove straight through the intersection without
    /// actually turning — that's a missed turn. Without this, the
    /// SDK just advanced the cursor and started cueing the NEXT
    /// maneuver while the rider was already off-route.
    private var preTurnSnapWayId: [Int: Int64] = [:]
    /// Wall-clock when the rider's speed last crossed below the
    /// stationary threshold. 0 means moving.
    private var stationarySinceMs: Int64 = 0
    private let stationarySpeedMps: Float = 0.5
    private let stationaryGraceMs: Int64 = 30_000
    private let stuckRepeatMs: Int64 = 60_000
    private var lastStuckIntentAtMs: Int64 = 0
    /// Wall-clock when the current route was installed. The first few
    /// seconds after install are noisy — the engine's snap-to-road
    /// puts the route's start vertex on a particular OSM way, while
    /// the Localizer snaps the rider's GPS to whatever way is
    /// closest. Those are often DIFFERENT (intersections, parallel
    /// paths), so the navigator would fire OFF-ROUTE before the
    /// rider has even moved. The grace window suppresses reactive
    /// cues until the rider has had time to settle onto the polyline.
    private var routeInstalledAtMs: Int64 = 0
    private let routeStartGraceMs: Int64 = 5_000
    /// Wall-clock when ANY intent was last spoken. Drives the reaffirm
    /// timer — silence longer than `reaffirmSilenceMs` while the
    /// rider is cruising on a route way with a turn comfortably far
    /// away earns a "you're still on X" reassurance.
    private var lastAnyIntentAtMs: Int64 = 0
    private let reaffirmSilenceMs: Int64 = 75_000
    private let reaffirmMinDistanceToTurnM: Double = 200
    private var reaffirmedManeuvers: [Int: Int] = [:]   // mIdx → count

    public init() {}

    /// Reset for a new route (initial start OR reroute).
    public func reset(isReroute: Bool) {
        state = .cruising
        routeInstalledAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        firedApproachPhases.removeAll()
        lastNearFiredFor = nil
        confirmedManeuvers.removeAll()
        preTurnSnapWayId.removeAll()
        reaffirmedManeuvers.removeAll()
        lastAnyIntentAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        stationarySinceMs = 0
        if !isReroute {
            lastIntentAtMs.removeAll()
        } else {
            // After a reroute, EVERY per-maneuver throttle key is
            // stale — the keys (`approach-far-1`, `reaffirm-2-0`,
            // `ambiguity-3`, `missedTurn-1`, `checkpoint-2`, etc.)
            // reference indices on the OLD route's maneuver list.
            // The new route has fresh maneuvers at the same indices
            // and they MUST be able to speak now. Bug observed live
            // 2026-05-29: rider on a 6-maneuver reroute, mnv#1
            // (U-turn) 28 m ahead, navigator never spoke approach
            // because `lastIntentAtMs["approach-far-1"]` held a
            // timestamp from the PRIOR route's mnv#1 (also a turn)
            // < 15 s ago. Result: 15 s of silence on every reroute
            // where any old-route key fell inside the cooldown.
            //
            // Wrong-way is the explicit exception: it's about the
            // rider's PHYSICAL direction of travel, unchanged by a
            // reroute. Preserving its throttle stops the "Wrong way"
            // double-fire across the reroute boundary observed live
            // at 04:44:26 → 04:44:28.
            let preservedWrongWay = lastIntentAtMs["wrongWay"]
            lastIntentAtMs.removeAll()
            if let ms = preservedWrongWay {
                lastIntentAtMs["wrongWay"] = ms
            }
            lastStuckIntentAtMs = 0
        }
    }

    /// Tick. Given the latest reasoner state + the upcoming maneuver,
    /// returns the cue intents (zero or more) the navigator wants to
    /// speak this tick. ``ScoovaNavLayer`` maps intents to text and
    /// plays them.
    public func tick(
        live: LiveGuidanceState,
        upcoming: ManeuverEvent?,
        metersRemainingToDestination: Int,
        arrivedLatched: Bool,
        speedMps: Float?,
        riderLat: Double? = nil,
        riderLon: Double? = nil,
        riderBearingDeg: Float? = nil,
        destLat: Double? = nil,
        destLon: Double? = nil,
        nowMs: Int64
    ) -> [CueIntent] {
        var intents: [CueIntent] = []

        // ── Hard arrival latch — once flipped, stay there. ─────────
        if arrivedLatched {
            if state != .arrived {
                state = .arrived
                if shouldFire("arrived", nowMs: nowMs) {
                    intents.append(.arrived)
                }
            }
            return intents
        }

        // ── Past destination ───────────────────────────────────────
        // The polyline projection clamps at the route's end, so
        // `metersRemainingToDestination` falls under 50 m the moment
        // the rider's nearest projection is the final vertex — even
        // if the rider is physically 200 m away. The naive check
        // (small metersRemaining + off-route way) used to false-fire
        // immediately after a small reroute landed: the rider was
        // 49 m from the destination heading PERPENDICULAR to it, and
        // the SDK said "You've passed your destination."
        //
        // Real past-destination requires THREE things together:
        //  1. The polyline projection is at the end (< 50 m remaining)
        //  2. The rider's straight-line distance to the destination is
        //     small enough that they *could* have just been there
        //     (< 80 m — a residential block).
        //  3. The destination is BEHIND the rider — bearing-to-dest
        //     more than 110° off the rider's current bearing. If the
        //     destination is in front (< 110° off course), the rider
        //     is still approaching, not past.
        let pastDest: Bool = {
            guard metersRemainingToDestination < 50 else { return false }
            // Need physical coords to do the real "is dest behind me"
            // check. Without them, fall back to the historical
            // heuristic (route way mismatch / large lateral) so
            // legacy callers don't regress.
            guard let rLat = riderLat, let rLon = riderLon,
                  let dLat = destLat,  let dLon = destLon,
                  let rBrg = riderBearingDeg else {
                if live.snap != nil { return !live.isOnRouteWay }
                return live.alignment.lateralM > 80
            }
            let distToDestM = GeoMath.haversineMeters(
                rLat, rLon, dLat, dLon)
            guard distToDestM < 80 else {
                // Physically too far to have been at the destination —
                // this isn't "past destination," this is "the SDK got
                // confused by a tiny reroute polyline." Stay silent.
                return false
            }
            let brgToDest = GeoMath.bearingDeg(rLat, rLon, dLat, dLon)
            let delta = angleDeltaAbs(rBrg, Float(brgToDest))
            return delta > 110
        }()
        if pastDest {
            let sinceMs = stateStartedAtMs(for: .pastDestination(sinceMs: 0)) ?? nowMs
            state = .pastDestination(sinceMs: sinceMs)
            if shouldFire("pastDestination", nowMs: nowMs) {
                intents.append(.pastDestination)
            }
            return intents
        }

        // Trip-start grace flag — also gates the missed-turn check
        // below and the off-route check further down. Without this,
        // the first few seconds after route install fire false
        // reactive cues from engine-snap vs Localizer-snap mismatch.
        let withinStartGrace = routeInstalledAtMs > 0
            && (nowMs - routeInstalledAtMs) < routeStartGraceMs

        // ── Missed-turn (runs BEFORE off-route so the specific
        // phrase fires when the cursor just advanced past a turn
        // the rider clearly didn't take) ──────────────────────────
        // The rider passed a turn maneuver IF the cursor moved past
        // it AND their snapped way is still the pre-turn way they
        // were on when the near cue fired. In the previous wiring
        // the off-route check fired first (because the rider's snap
        // is no longer on the route's expected post-turn way) and
        // returned with the generic "Looks like you went off route"
        // — losing the more specific "You missed the turn."
        // semantics. The same reroute fires either way; this just
        // gives the rider the right phrase.
        if !withinStartGrace,
           let last = lastNearFiredFor,
           let m = upcoming,
           m.index > last,
           !confirmedManeuvers.contains(last),
           let preWid = preTurnSnapWayId[last],
           let curWid = live.snap?.wayId,
           preWid == curWid {
            confirmedManeuvers.insert(last)
            state = .offRoute(snappedWayName: live.snap?.name ?? "",
                              sinceMs: nowMs)
            if shouldFire("missedTurn-\(last)", nowMs: nowMs) {
                intents.append(.missedTurn(maneuverIndex: last))
            }
            return intents
        }

        // ── Cross-event suppression: don't say BOTH wrong-way AND
        // off-route within the same excursion ────────────────────
        // The natural flow when a rider takes a wrong turn:
        //   1. Wrong-way fires (rider's course is opposite to the
        //      route's expected direction on the segment they were
        //      supposed to be on)
        //   2. ~2 s later, the rider crosses an intersection and
        //      the snap lands on a different OSM way → off-route
        //      fires.
        // Both are correct detections, but the rider hears two
        // alerts for what is functionally one event. We suppress
        // the off-route cue when wrong-way fired in the last 10 s
        // — the wrong-way already informed them and (after the fix
        // below) already triggered a reroute, so off-route's cue
        // would be redundant.
        let wrongWayJustFired = (nowMs - (lastIntentAtMs["wrongWay"] ?? 0)) < 10_000

        // ── Parallel-heading suppression ───────────────────────────
        // A rider whose GPS heading aligns with the route polyline's
        // local direction AND who's not far from the line is walking
        // / cycling parallel to the route — on a sidewalk, in a bike
        // lane, hugging one side of a wide bike path. That's NOT
        // off-route and it's NOT wrong-way. Mirrors the same check
        // GuidanceMonitor already has on the legacy path; the
        // navigator path was missing it, so a rider on a parallel
        // cycleway 20 m off the line could trip off-route. Within
        // the 45 m parallel band, suppress the off-route / wrong-way
        // intents this tick.
        let isParallel: Bool = {
            guard let cms = live.alignment.courseMatchesSegment,
                  cms == true
            else { return false }
            // Hard cap: never suppress beyond the band. The number
            // matches the wrong-way lateral gate above so the rules
            // stay coherent.
            return live.alignment.lateralM <= 45
        }()

        // ── Off-route (real map-matching) ──────────────────────────
        // Snap tells the truth: if the rider's snapped way is not in
        // the route's way set, they're off route. This is the bug
        // class the polyline tripwire never caught — a rider on a
        // parallel street 12 m from the line, snapped to a different
        // OSM way, used to read as "lateral=12m, all good." Now we
        // see it the moment it happens.
        //
        // Trip-start grace: declared above; reused here.
        // Parallel-walking suppression: a rider going the same way
        // as the route along a parallel cycleway / sidewalk inside
        // the drift band is NOT off-route.
        let isOff: Bool = {
            if withinStartGrace { return false }
            if isParallel { return false }
            if live.snap == nil {
                // No graph → fallback to lateral heuristic.
                return live.alignment.lateralM > 60
            }
            return !live.isOnRouteWay
        }()
        if isOff {
            let name = live.snap?.name ?? ""
            // No "if already in .offRoute, do nothing" gate — that
            // gate previously caused 30 s of complete silence after
            // the FIRST reroute landed and the rider continued off
            // the new route. The state machine entered .offRoute on
            // the first detection and then `break`-ed forever even
            // as the rider's lateral distance grew to 25 m+ and
            // they snapped onto a totally different way.
            //
            // The shouldFire cooldown (15 s) is what paces re-
            // emissions now. Every 15 s of sustained off-route, the
            // intent re-fires, the speaker re-triggers the reroute
            // attempt, and the rider gets a fresh route + cue.
            // Wrong-way recency still suppresses the spoken phrase
            // to avoid the double-alert problem from Bug Q.
            let stateChanging: Bool = {
                if case .offRoute = state { return false }
                return true
            }()
            if stateChanging {
                state = .offRoute(snappedWayName: name, sinceMs: nowMs)
            }
            if shouldFire("offRoute", nowMs: nowMs) {
                if !wrongWayJustFired {
                    intents.append(.offRoute(snappedName: name))
                }
            }
            return intents
        }

        // ── Wrong-way (on the right way, going backwards) ──────────
        // Three gates: (1) snapped to a way that's in the route
        // corridor, (2) course mismatches the way's expected forward
        // direction, (3) close enough to the actual route polyline
        // that the snap is honestly about the route — not a different
        // segment of the same OSM way.
        //
        // The third gate fixes the bug observed live at 05:46:45:
        // wrong-way fired with the rider 116 m lateral from the
        // polyline. The way "Infinite Loop" is in the corridor but
        // it's a long road — the rider snapped to a different segment
        // of it. The snap's course=rev was true for that other
        // segment but meaningless for the route's segment. Without a
        // lateral gate, any rider drifting onto a corridor way at any
        // point along its length triggers wrong-way. Threshold per
        // costing matches the off-route drift band so wrong-way and
        // off-route stay coherent: a rider OUTSIDE the band can't be
        // "wrong-way" — they're plainly off-route.
        let wrongWay: Bool = {
            guard let s = live.snap, live.isOnRouteWay else { return false }
            guard let matches = s.courseMatchesForward else { return false }
            if matches { return false }
            // Parallel-heading suppression: a rider whose actual GPS
            // course is aligned with the polyline's local direction
            // is not "wrong way" — they're parallel-following. The
            // snap may report course=rev because the snap matched a
            // different SEGMENT of the same way; we trust the polyline
            // alignment over the snap segment in that case.
            if isParallel { return false }
            // Lateral gate. Default 30 m (auto/driving). Pedestrian
            // and bicycle can live further from the centerline (slip
            // lanes, parallel cycleways). Use a generous 45 m here —
            // the off-route band sets its own per-costing threshold
            // below, this gate is the upper bound that PROTECTS
            // wrong-way from claiming a rider 100+ m off the line.
            if live.alignment.lateralM > 45 { return false }
            return s.oneway || (live.alignment.courseMatchesSegment == false)
        }()
        if wrongWay {
            let name = live.snap?.name ?? ""
            switch state {
            case .wrongWay: break
            default:
                state = .wrongWay(snappedWayName: name, sinceMs: nowMs)
                if shouldFire("wrongWay", nowMs: nowMs) {
                    intents.append(.wrongWay(snappedName: name))
                }
            }
            return intents
        }

        // ── Post-turn: missed-turn vs confirmation ─────────────────
        // The cursor advanced past a maneuver the navigator fired the
        // near cue for. Two paths:
        //
        //  • **Missed turn**: the rider's snapped OSM way is the SAME
        //    as before the near cue fired — they drove straight
        //    through the intersection instead of turning. Fire the
        //    missed-turn intent which triggers a reroute. Without
        //    this branch, the SDK silently advances the cursor and
        //    starts cueing the NEXT maneuver while the rider is
        //    already off the route.
        //
        //  • **Confirmation**: the rider's snapped way changed — they
        //    DID turn. Fire the "Good, you're on [street]" cue.
        //
        // Both fire at most once per maneuver (`confirmedManeuvers`).
        if let last = lastNearFiredFor,
           let m = upcoming,
           m.index > last,
           !confirmedManeuvers.contains(last) {
            confirmedManeuvers.insert(last)
            let preWid = preTurnSnapWayId[last]
            let curWid = live.snap?.wayId
            let missedTurn = (preWid != nil && curWid != nil
                              && preWid == curWid)
            if missedTurn {
                if shouldFire("missedTurn-\(last)", nowMs: nowMs) {
                    intents.append(.missedTurn(maneuverIndex: last))
                }
            } else if shouldFire("confirm-\(last)", nowMs: nowMs) {
                intents.append(.confirm(maneuverIndex: last))
            }
        }

        // ── Stuck-in-traffic ───────────────────────────────────────
        // On the right way + stationary for > 30 s means the rider is
        // in traffic / at a stoplight / parked momentarily. Reassures
        // them the navigator hasn't died. Suppressed near the
        // destination (rider is presumably parking) and on any non-
        // route way (off-route owns that voice).
        if live.isOnRouteWay,
           metersRemainingToDestination > 50,
           let s = speedMps, s < stationarySpeedMps {
            if stationarySinceMs == 0 { stationarySinceMs = nowMs }
            let stuckFor = nowMs - stationarySinceMs
            if stuckFor > stationaryGraceMs {
                let canSpeak = (nowMs - lastStuckIntentAtMs) > stuckRepeatMs
                if canSpeak {
                    state = .stuckInTraffic(sinceMs: stationarySinceMs)
                    lastStuckIntentAtMs = nowMs
                    intents.append(.stuckInTraffic)
                    return intents
                }
            }
        } else {
            stationarySinceMs = 0
        }

        // ── Reaffirm on long quiet stretches ───────────────────────
        // If the rider is comfortably on a route way, more than 200 m
        // from their next decision, and we've been silent for 75 s,
        // emit a reaffirm intent. The cue speaker reads the
        // maneuver's `voiceReaffirm` ("Still on Camelback Road") and
        // appends the live distance to the upcoming turn. Gated on
        // the upcoming maneuver still being ahead — a rider who
        // overshot the turn and is heading away shouldn't hear
        // "Still on X, N m to the next turn" while N is meaningless.
        if live.isOnRouteWay,
           let m = upcoming,
           let dec = live.upcomingDecision,
           dec.distance > reaffirmMinDistanceToTurnM,
           nowMs - lastAnyIntentAtMs > reaffirmSilenceMs,
           coordIsAhead(
               lat: m.latitude, lon: m.longitude,
               riderLat: riderLat, riderLon: riderLon,
               riderBearingDeg: riderBearingDeg,
               speedMps: speedMps) {
            // Limit to a few reaffirms per maneuver so we don't spam
            // a rider on a 3 km straight stretch with the same line.
            let count = reaffirmedManeuvers[m.index] ?? 0
            if count < 4, shouldFire("reaffirm-\(m.index)-\(count)", nowMs: nowMs) {
                reaffirmedManeuvers[m.index] = count + 1
                intents.append(.reaffirm(maneuverIndex: m.index))
            }
        }

        // ── Checkpoint narration ───────────────────────────────────
        // Server pins voiceCheckpoint at an offset past the prior
        // turn ("you're passing the museum on your right"). Gated
        // on the upcoming maneuver still being ahead — if the rider
        // overshot, the checkpoint sentence makes no sense.
        if let m = upcoming,
           let offset = m.checkpointOffsetMeters,
           let dec = live.upcomingDecision,
           m.voiceCheckpoint?.isEmpty == false,
           coordIsAhead(
               lat: m.latitude, lon: m.longitude,
               riderLat: riderLat, riderLon: riderLon,
               riderBearingDeg: riderBearingDeg,
               speedMps: speedMps) {
            let covered = m.segmentLengthMeters - dec.distance
            if covered >= Double(offset),
               shouldFire("checkpoint-\(m.index)", nowMs: nowMs) {
                intents.append(.checkpoint(maneuverIndex: m.index))
            }
        }

        // ── Ambiguity heads-up ─────────────────────────────────────
        // Multi-turn ordinal hint at ~250 m out. Gated on the
        // upcoming maneuver still being ahead — counting "the first
        // / second left" only makes sense while the turn is ahead.
        if let m = upcoming,
           let dec = live.upcomingDecision,
           dec.distance > 180, dec.distance <= 280,
           (live.ambiguityFlags.contains("multipleLeftsBeforeLeftTurn")
            || live.ambiguityFlags.contains("multipleRightsBeforeRightTurn")),
           coordIsAhead(
               lat: m.latitude, lon: m.longitude,
               riderLat: riderLat, riderLon: riderLon,
               riderBearingDeg: riderBearingDeg,
               speedMps: speedMps) {
            if shouldFire("ambiguity-\(m.index)", nowMs: nowMs) {
                intents.append(.ambiguityHeadsUp(maneuverIndex: m.index))
            }
        }

        // ── Approaching a turn ─────────────────────────────────────
        if let m = upcoming,
           let dec = live.upcomingDecision,
           m.type != .depart && m.type != .arrive {
            var fired = firedApproachPhases[m.index] ?? []
            let dist = dec.distance
            // Speed-aware lead: the cue fires when the rider is
            // `secondsOut × liveSpeed` metres before the turn — same
            // reaction window across personas. Clamped so a stopped
            // rider doesn't see lead=0 and a GPS spike doesn't fire
            // the cue half a kilometre out.
            let liveSpeed = max(
                approachMinSpeedMps,
                min(approachMaxSpeedMps,
                    Double(speedMps ?? Float(approachFallbackSpeedMps)))
            )
            // Geometric precondition: the maneuver coordinate must be
            // AHEAD of the rider's direction of travel. The polyline-
            // projected distance never goes negative (clamps at the
            // route end), so a rider physically past the turn or going
            // the wrong way on the right road still reads "120 m to
            // turn" via dist. If we fire the approach cue in that
            // state the rider hears "Turn left in 116 m" while the
            // turn is geometrically behind them — pure nonsense.
            // Computed UP FRONT so the pre-marking below skips too —
            // a U-turn that puts the maneuver back ahead can then
            // still speak the appropriate phase. See
            // [[cue-preconditions-are-coords]].
            let mAhead = coordIsAhead(
                lat: m.latitude, lon: m.longitude,
                riderLat: riderLat, riderLon: riderLon,
                riderBearingDeg: riderBearingDeg,
                speedMps: speedMps
            )
            // If a reroute installed a route whose FIRST turn is
            // already inside the MID window (the rider is < 12 s out
            // from the new mnv 1), don't fire far AT ALL — and skip
            // mid too if we're inside the NEAR window. Otherwise
            // far/mid/near fire in rapid succession with near-
            // identical text on a tight reroute (Cupertino test:
            // 3 cues, 2 s apart, same phrase). Marks the skipped
            // phases consumed so they don't re-attempt. Gated on
            // mAhead — when the maneuver is behind we don't pre-mark
            // anything, so a subsequent U-turn re-opens all phases.
            if mAhead {
                if let midSec = approachLeadSeconds[.mid] {
                    let midLead = midSec * liveSpeed
                    if dist <= midLead { fired.insert(.far) }
                }
                if let nearSec = approachLeadSeconds[.near] {
                    let nearLead = nearSec * liveSpeed
                    if dist <= nearLead {
                        fired.insert(.far)
                        fired.insert(.mid)
                    }
                }
            }
            // Far → Mid → Near in order; each fires once per maneuver.
            // The earlier-fired phases are also marked consumed so a
            // jittery distance reading doesn't replay the same phase.
            for phase in [CueGrammar.Phase.far, .mid, .near] {
                guard let secondsOut = approachLeadSeconds[phase] else { continue }
                let lead = secondsOut * liveSpeed
                if dist <= lead, !fired.contains(phase) {
                    guard mAhead else { continue }
                    fired.insert(phase)
                    // Earlier phases never re-fire after a later one
                    // crosses (a rider who's at near doesn't want to
                    // suddenly hear the far cue from the next iteration
                    // due to GPS noise).
                    if phase == .mid { fired.insert(.far) }
                    if phase == .near { fired.insert(.far); fired.insert(.mid) }
                    state = .approachingTurn(maneuverIndex: m.index)
                    if shouldFire("approach-\(phase)-\(m.index)", nowMs: nowMs) {
                        intents.append(.approach(phase: phase,
                                                 maneuverIndex: m.index))
                        if phase == .near {
                            // Remember this turn so the confirm intent
                            // can fire after the rider passes it, and
                            // snapshot the rider's current OSM way so
                            // we can detect a missed turn — if the
                            // rider's way doesn't CHANGE after passing
                            // this point, they drove straight through.
                            lastNearFiredFor = m.index
                            if let wid = live.snap?.wayId {
                                preTurnSnapWayId[m.index] = wid
                            }
                        }
                    }
                    break   // at most one phase per tick
                }
            }
            firedApproachPhases[m.index] = fired
        }

        // ── Cruising default ───────────────────────────────────────
        if intents.isEmpty {
            switch state {
            case .approachingTurn, .offRoute, .wrongWay, .pastDestination:
                state = .cruising
            default:
                break
            }
        }

        return intents
    }

    private func shouldFire(_ key: String, nowMs: Int64) -> Bool {
        let last = lastIntentAtMs[key] ?? 0
        if nowMs - last < perIntentCooldownMs { return false }
        lastIntentAtMs[key] = nowMs
        lastAnyIntentAtMs = nowMs
        return true
    }

    /// Geometric precondition shared by every cue that references a
    /// specific place (turn point, landmark, destination). Returns
    /// true when the coordinate is in front of the rider's direction
    /// of travel, false when it's behind or abreast (delta ≥ 90°
    /// off the rider's bearing). Returns true (pass-through) when
    /// bearing is unknown OR speed is too low to trust the heading
    /// — we don't silence cues at trip start / stopped at a light.
    internal func coordIsAhead(
        lat: Double, lon: Double,
        riderLat: Double?, riderLon: Double?,
        riderBearingDeg: Float?,
        speedMps: Float?
    ) -> Bool {
        guard let rLat = riderLat, let rLon = riderLon,
              let brg = riderBearingDeg, (speedMps ?? 0) >= 1.0
        else { return true }
        let toCoord = GeoMath.bearingDeg(rLat, rLon, lat, lon)
        let delta = angleDeltaAbs(brg, Float(toCoord))
        return delta < 90
    }

    private func stateStartedAtMs(for sample: State) -> Int64? {
        switch (state, sample) {
        case (.offRoute(_, let ms), .offRoute): return ms
        case (.wrongWay(_, let ms), .wrongWay): return ms
        case (.pastDestination(let ms), .pastDestination): return ms
        default: return nil
        }
    }
}
