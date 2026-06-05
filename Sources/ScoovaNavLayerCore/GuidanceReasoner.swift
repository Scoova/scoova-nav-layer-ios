import Foundation

/// One coherent answer the reasoner produces per GPS tick. Every other
/// system reads from this struct: the cue speaker reads ``upcomingDecision``
/// and ``ambiguityFlags``, the off-route detector reads ``alignment``,
/// the reroute trigger reads ``segmentOnGraph != nil`` against the
/// route's corridor, the heading puck reads ``alignment.courseMatchesSegment``.
///
/// The reasoner runs on every tick — so this struct is the unit of
/// reasoning. If it's wrong, downstream systems are wrong. If it's right,
/// downstream becomes mechanical.
public struct LiveGuidanceState: Sendable, Equatable {
    /// Real map-matched snap of the rider to the nearest road in the
    /// neighbour graph — "which OSM way am I physically on." Nil when
    /// no neighbour graph was shipped OR when no way in the graph is
    /// within `maxLateralM` of the rider. The latter is the
    /// **strongest** off-route signal we have: the rider is not on
    /// any road in the route's neighbourhood.
    public let snap: Localizer.Snap?
    /// `true` when ``snap.wayId`` is one of the route's expected ways
    /// (derived from corridor's graph fingerprints). The reasoner's
    /// authoritative on-route signal.
    public let isOnRouteWay: Bool
    /// The road-graph segment the rider is currently on, identified by
    /// the corridor's graph fingerprint. Nil when the corridor isn't
    /// available (legacy server) OR when the rider's projection lands
    /// outside every fingerprint — the latter is a strong signal that
    /// the rider has left the route corridor entirely.
    public let segmentOnGraph: GraphFingerprint?
    /// Where the rider is in the route's maneuver sequence: index of
    /// the **upcoming** maneuver (matches ``ProgressEvent.upcomingManeuverIndex``).
    public let segmentOnRoute: Int
    /// How well the rider's GPS lines up with the route polyline + the
    /// expected segment direction. Drives off-route / drift / wrong-way
    /// state without leaning on lateral-distance heuristics alone.
    public let alignment: Alignment
    /// What the rider is approaching: the upcoming maneuver's direction,
    /// the live distance, and the ordinal-and-ambiguity context the
    /// cue grammar needs to phrase the instruction unambiguously.
    public let upcomingDecision: UpcomingDecision?
    /// Open-vocabulary flags from the corridor's per-maneuver block.
    /// Unknown flags treated as no-ops; known flags drive grammar:
    /// ``"multipleLeftsBeforeLeftTurn"`` shifts "the next left" to
    /// "take the [Nth] left", ``"interchangeCluster"`` collapses the
    /// next two cues into a single "stay right through the interchange"
    /// (future work).
    public let ambiguityFlags: [String]

    public struct Alignment: Sendable, Equatable {
        /// Rider is on the route polyline within an acceptable lateral
        /// band. `false` means lateral distance has crossed the
        /// off-route threshold AND no fingerprint match.
        public let onRoute: Bool
        /// Perpendicular distance from rider to the route polyline (m).
        public let lateralM: Double
        /// `true` when the rider's GPS course matches the expected
        /// direction-of-travel for the segment they're on. Nil when
        /// GPS course is unavailable (stationary / first tick).
        public let courseMatchesSegment: Bool?
    }

    public struct UpcomingDecision: Sendable, Equatable {
        public let type: ManeuverType
        /// Along-route distance from the rider to the maneuver (m).
        public let distance: Double
        /// 1-based ordinal among same-side turns on the approach
        /// segment. Nil when the corridor wasn't available or the
        /// maneuver has no side (continue / arrive / depart).
        public let ordinal: Int?
        /// Total same-side turns the rider passes on the approach.
        /// `ordinal == totalSameSideTurns == 1` means the maneuver is
        /// the only same-side turn — "the next left" can be spoken
        /// with confidence. Higher values shift the grammar to
        /// ordinals.
        public let totalSameSideTurns: Int?
    }
}

/// Stateless reasoning function — given the latest progress event, the
/// route's maneuver list, and the route's corridor (when available),
/// produces the live state every other system reads from.
///
/// Lives outside ``ScoovaNavLayer`` so it can be unit-tested in
/// isolation: build a synthetic ``ProgressEvent`` + ``Corridor`` +
/// ``[ManeuverEvent]``, call ``reason(_:route:corridor:)``, assert on
/// the result. No I/O, no timers, no actor boundaries.
///
/// Re-uses ``projectOntoPolyline`` from ``GuidanceMonitor.swift`` for
/// the polyline projection — single source of truth for "where on the
/// route is the rider," now scaled to metric coords (P0.3).
public enum GuidanceReasoner {

    public static func reason(
        _ p: ProgressEvent,
        route: [ManeuverEvent],
        corridor: Corridor?,
        shape: [[Double]]
    ) -> LiveGuidanceState {
        // ── Real map-matching ────────────────────────────────────────
        // The neighbour-graph snap is the navigator's "which road are
        // you on" answer. When present + matched, it's authoritative
        // for on-route / off-route / wrong-way. When the graph is
        // empty (legacy server) we fall back to the polyline
        // projection below.
        let snap: Localizer.Snap? = {
            guard let c = corridor, !c.neighbourGraph.isEmpty else { return nil }
            return Localizer.snap(
                lat: p.latitude, lon: p.longitude,
                courseDeg: p.bearingDeg.map { Double($0) },
                speedMps: p.speedMps.map { Double($0) },
                graph: c.neighbourGraph
            )
        }()
        let isOnRouteWay: Bool = {
            guard let c = corridor, let s = snap else { return false }
            return Localizer.routeWayIds(c).contains(s.wayId)
        }()

        // ── Polyline projection ──────────────────────────────────────
        // The metric-scaled projection from GuidanceMonitor — same
        // coord convention everywhere in the SDK. Kept as a fallback
        // when no neighbour graph is available + as a secondary signal
        // for distance-to-line.
        let proj = projectOntoPolyline(lat: p.latitude, lon: p.longitude, shape: shape)
        let lateralM = proj?.lateralM ?? Double.greatestFiniteMagnitude
        let segmentBearing = proj?.segmentBearingDeg

        // ── Graph fingerprint match ──────────────────────────────────
        // Find the fingerprint whose polyline range contains the
        // rider's nearest vertex AND require the rider to be within a
        // road-width's lateral distance of the polyline. Without the
        // lateral gate this lookup ALWAYS succeeds (the polyline is
        // the route, so the nearest vertex is always inside some
        // fingerprint), which silently suppressed off-route firing —
        // the regression that left riders going the wrong way without
        // any cue at all. The corridor's fingerprints can only tell us
        // "is the rider near the route" — they do NOT know about
        // parallel side streets, so we treat the fingerprint match as
        // honest only when the rider is plausibly ON the route's road
        // surface.
        //
        // 25 m matches a typical urban road's half-width including
        // sidewalks; on a multi-lane highway the rider can sit a touch
        // beyond, and we miss the match — but that's the failure mode
        // we want (lateral off-route gets a chance to fire) rather
        // than the previous false-positive everything-is-fine.
        let graphMatchMaxLateralM: Double = 25
        let nearestVertex = Self.nearestPolylineVertex(lat: p.latitude,
                                                       lon: p.longitude,
                                                       shape: shape)
        let segmentOnGraph: GraphFingerprint? = corridor.flatMap { c in
            guard lateralM <= graphMatchMaxLateralM else { return nil }
            return c.graphFingerprints.first {
                nearestVertex >= $0.polylineFrom && nearestVertex <= $0.polylineTo
            }
        }

        // ── Course-vs-segment direction ──────────────────────────────
        // The reasoner trusts GPS course at speed (> ~2 m/s) and falls
        // back to nil at rest. Headings within 60° of the segment
        // bearing count as aligned — generous enough to cover wind on
        // a bike + GPS noise, tight enough to catch real reversals.
        let courseMatchesSegment: Bool? = {
            guard let bearing = p.bearingDeg,
                  let speed = p.speedMps, speed >= 2.0,
                  let segB = segmentBearing else { return nil }
            let delta = angleDeltaAbs(bearing, segB)
            return delta < 60
        }()

        // ── On-route decision ────────────────────────────────────────
        // Authoritative when neighbour graph is present: the snap
        // landed on one of the route's expected ways. Falls back to
        // the lateral-distance heuristic when no graph was shipped.
        let onRoute: Bool = {
            if snap != nil { return isOnRouteWay }
            return lateralM < 60
        }()

        // ── Upcoming decision ────────────────────────────────────────
        let upcomingIdx = max(0, min(p.upcomingManeuverIndex, route.count - 1))
        let upcoming: LiveGuidanceState.UpcomingDecision? = {
            guard !route.isEmpty else { return nil }
            let m = route[upcomingIdx]
            let block = corridor?.maneuvers.first { $0.index == upcomingIdx }
            return LiveGuidanceState.UpcomingDecision(
                type: m.type,
                distance: p.metersToUpcomingManeuver,
                ordinal: block?.ordinal?.indexAmongSameSideTurns,
                totalSameSideTurns: block?.ordinal?.totalSameSideTurns
            )
        }()

        let flags = corridor?.maneuvers
            .first { $0.index == upcomingIdx }?
            .ambiguityFlags ?? []

        return LiveGuidanceState(
            snap: snap,
            isOnRouteWay: isOnRouteWay,
            segmentOnGraph: segmentOnGraph,
            segmentOnRoute: upcomingIdx,
            alignment: LiveGuidanceState.Alignment(
                onRoute: onRoute,
                lateralM: lateralM,
                courseMatchesSegment: courseMatchesSegment
            ),
            upcomingDecision: upcoming,
            ambiguityFlags: flags
        )
    }

    /// Nearest-vertex index — used to look up the active fingerprint.
    /// Cheaper than a full segment projection because we only need
    /// "which entry contains the rider," not the perpendicular foot.
    private static func nearestPolylineVertex(
        lat: Double, lon: Double, shape: [[Double]]
    ) -> Int {
        guard !shape.isEmpty else { return 0 }
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(lat * .pi / 180)
        let rx = lon * mPerDegLon
        let ry = lat * mPerDegLat
        var bestIdx = 0
        var bestDistSq = Double.greatestFiniteMagnitude
        for i in 0..<shape.count {
            let p = shape[i]
            let dx = p[1] * mPerDegLon - rx
            let dy = p[0] * mPerDegLat - ry
            let d = dx * dx + dy * dy
            if d < bestDistSq {
                bestDistSq = d
                bestIdx = i
            }
        }
        return bestIdx
    }
}
