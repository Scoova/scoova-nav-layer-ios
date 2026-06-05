import Foundation

/// The "guy holding the map." Snaps a GPS fix to the nearest road
/// in the route's neighbour graph and tells the reasoner WHICH road
/// the rider is physically on — not "near the polyline" but the
/// actual OSM way they're traversing. This is the difference between
/// a polyline tripwire and a real navigator.
///
/// Stateless by design: every fix is independent. State lives in the
/// reasoner, which sees the localiser's outputs over time.
public enum Localizer {

    /// The result of snapping a GPS fix to the neighbour graph.
    public struct Snap: Sendable, Equatable {
        /// OSM way the rider is closest to.
        public let wayId: Int64
        /// Way name (may be empty).
        public let name: String
        /// Distance from the rider to the snap point (m).
        public let lateralM: Double
        /// Bearing of the snapped segment in the way's `forward`
        /// direction. 0..360, where 0 = north.
        public let segmentBearingDeg: Double
        /// `true` when the rider's GPS course aligns with the
        /// segment's `forward` direction within ~60°. Nil when no
        /// course supplied (stationary / first fix).
        public let courseMatchesForward: Bool?
        /// The way's `oneway` flag — propagated for the wrong-way
        /// detector. On a oneway, course-against-forward is an
        /// unambiguous wrong-way fire.
        public let oneway: Bool
        /// Snap point itself, as `[lat, lon]`. Lets the host draw a
        /// "snapped position" puck or compute follow-on math.
        public let snappedLat: Double
        public let snappedLon: Double
    }

    /// Snap a GPS fix against the neighbour graph. Returns nil when
    /// the graph is empty (legacy server) OR no way is within
    /// `maxLateralM`. The reasoner reads nil as "the rider is far
    /// from any road in the corridor" — a strong signal they have
    /// left the route's neighbourhood entirely.
    ///
    /// O(N·M) where N = number of ways, M = total segments. For a
    /// typical urban route (100 ways, 1500 segments) this is
    /// ~150k operations per tick — sub-millisecond on real
    /// hardware. If routes ever grow into the thousand-way range a
    /// spatial index can be added; not needed today.
    public static func snap(
        lat: Double,
        lon: Double,
        courseDeg: Double?,
        speedMps: Double?,
        graph: [NeighbourWay],
        maxLateralM: Double = 30
    ) -> Snap? {
        guard !graph.isEmpty else { return nil }
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(lat * .pi / 180)
        let rx = lon * mPerDegLon
        let ry = lat * mPerDegLat

        // The rider's course, when trusted (moving > 2 m/s), is a
        // tie-breaker between equidistant ways. At an intersection
        // the rider is geometrically close to BOTH the way they're
        // travelling along AND the way that crosses it; raw lateral
        // distance can pick the wrong one. We penalise candidates
        // whose segment bearing is perpendicular to the rider's
        // course — the rider physically can't be traveling 90° to
        // the way they're on. See [[data-in-hand-principle]] /
        // [[navigator-with-map-frame]].
        let trustCourse = (courseDeg != nil) && ((speedMps ?? 0) >= 2.0)

        var bestScore = Double.greatestFiniteMagnitude
        var bestWay: NeighbourWay? = nil
        var bestSnapX = 0.0
        var bestSnapY = 0.0
        var bestSegBearingDeg = 0.0
        var bestForward = true
        var bestLateralM = Double.greatestFiniteMagnitude

        for way in graph {
            for seg in way.segments where seg.shape.count >= 2 {
                for i in 0..<(seg.shape.count - 1) {
                    let a = seg.shape[i]
                    let b = seg.shape[i + 1]
                    let ax = a[1] * mPerDegLon
                    let ay = a[0] * mPerDegLat
                    let bx = b[1] * mPerDegLon
                    let by = b[0] * mPerDegLat
                    let abx = bx - ax
                    let aby = by - ay
                    let ab2 = abx * abx + aby * aby
                    if ab2 < 1e-9 { continue }
                    let t = max(0.0, min(1.0,
                        ((rx - ax) * abx + (ry - ay) * aby) / ab2))
                    let cx = ax + abx * t
                    let cy = ay + aby * t
                    let dx = rx - cx
                    let dy = ry - cy
                    let lateralM = (dx * dx + dy * dy).squareRoot()

                    // Course-aware scoring. Base score = lateral
                    // distance (m). When course is trusted, add a
                    // penalty proportional to how perpendicular the
                    // way is to the rider's heading. A 90°
                    // perpendicular way gets +20 m of effective
                    // distance — enough to lose to a parallel way
                    // 15 m away. A way aligned within 30° pays no
                    // penalty. Penalty caps at 25 m so a clearly-
                    // closer perpendicular way (e.g. a one-block
                    // alley right under the rider) still wins.
                    let segBearing = GeoMath.bearingDeg(
                        a[0], a[1], b[0], b[1])
                    var score = lateralM
                    if trustCourse, let c = courseDeg {
                        // Bidirectional alignment: course can go
                        // either way along the segment, so we take
                        // the smaller of (delta, 180-delta).
                        let delta = angleDeltaAbs(Float(c), Float(segBearing))
                        let bidiDelta = Float(min(Float(delta), 180 - Float(delta)))
                        // Linear 0..25 m penalty from 30° to 90°.
                        let pen: Double
                        if bidiDelta <= 30 { pen = 0 }
                        else if bidiDelta >= 90 { pen = 25 }
                        else { pen = Double(bidiDelta - 30) / 60 * 25 }
                        score += pen
                    }

                    if score < bestScore {
                        bestScore = score
                        bestWay = way
                        bestSnapX = cx
                        bestSnapY = cy
                        bestSegBearingDeg = segBearing
                        bestForward = seg.forward
                        bestLateralM = lateralM
                    }
                }
            }
        }

        guard let way = bestWay else { return nil }
        let lateralM = bestLateralM
        if lateralM > maxLateralM { return nil }

        // Course-vs-forward check. Speed gate matches the reasoner's
        // own course-trust threshold so we don't latch onto noise at
        // stationary / first-fix.
        let courseMatchesForward: Bool? = {
            guard let course = courseDeg,
                  let speed = speedMps, speed >= 2.0 else { return nil }
            let segDir = bestForward
                ? bestSegBearingDeg
                : (bestSegBearingDeg + 180).truncatingRemainder(dividingBy: 360)
            let delta = angleDeltaAbs(Float(course), Float(segDir))
            return delta < 60
        }()

        return Snap(
            wayId: way.wayId,
            name: way.name,
            lateralM: lateralM,
            segmentBearingDeg: bestSegBearingDeg,
            courseMatchesForward: courseMatchesForward,
            oneway: way.oneway,
            snappedLat: bestSnapY / mPerDegLat,
            snappedLon: bestSnapX / mPerDegLon
        )
    }

    /// The set of OSM ways the ROUTE itself rides — derived from the
    /// corridor's graph fingerprints. The reasoner uses this to ask
    /// "is the rider's snapped way one of the route's ways?" — that
    /// IS the on-route signal.
    public static func routeWayIds(_ corridor: Corridor) -> Set<Int64> {
        Set(corridor.graphFingerprints.map { $0.wayId })
    }
}
