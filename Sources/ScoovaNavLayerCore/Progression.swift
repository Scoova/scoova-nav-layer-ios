import Foundation

/// Per-costing distance ladder. The cue fires when we cross one of these
/// thresholds for a maneuver — far, mid, near. A runner shouldn't get an
/// "in 800 m turn left" cue and a driver shouldn't get a 50 m one.
enum Thresholds {
    private static let perProfile: [String: [Int]] = [
        "pedestrian":    [50, 25, 10, 3],
        "bicycle":       [200, 100, 50, 15],
        "scooter":       [300, 150, 75, 20],
        "motor_scooter": [600, 300, 150, 30],
        "motorcycle":    [800, 400, 200, 40],
        "auto":          [800, 400, 200, 50],
        "truck":         [800, 400, 200, 50],
    ]

    public static func forProfile(_ profile: String) -> [Int] {
        (perProfile[profile] ?? perProfile["auto"]!).sorted()
    }

    /// Fallback far / mid / near cue lead-distances (m before the
    /// maneuver) used only when the server didn't ship its own.
    public static func cueOffsets(
        for profile: String
    ) -> (far: Double, mid: Double, near: Double) {
        switch profile {
        case "pedestrian":               return (70, 35, 14)
        case "bicycle":                  return (220, 110, 40)
        case "scooter", "motor_scooter": return (320, 160, 60)
        default:                         return (500, 250, 90)
        }
    }
}

/// Progress tracker that fires once per phase band per maneuver.
///
/// The band is the smallest threshold ≥ the current distance. A normal
/// approach escalates far → mid → near as the rider closes in; a turn
/// that only comes into view already close (right after the previous
/// turn, or right off the start line) still gets a cue — just a
/// later-phase one. Outer bands skipped on entry are marked fired so
/// they never play late. Each band fires at most once, so a static or
/// jittery reading never re-triggers.
final class ProgressTracker {
    public struct Snapshot {
        public let maneuverIndex: Int
        public let metersToManeuver: Double
        /// `-1` means no threshold fired this tick.
        public let firedThresholdM: Int
    }

    private let thresholdsMeters: [Int]   // ascending
    private var firedFor: [Int: Set<Int>] = [:]

    public init(thresholdsMeters: [Int]) {
        self.thresholdsMeters = thresholdsMeters.sorted()
    }

    public func update(maneuverIndex: Int, metersToManeuver: Double) -> Snapshot {
        var fired = firedFor[maneuverIndex] ?? []
        var candidate = -1
        if metersToManeuver.isFinite, metersToManeuver >= 0,
           let band = thresholdsMeters.first(where: { Double($0) >= metersToManeuver }),
           !fired.contains(band) {
            candidate = band
            // The rider is inside `band`; any wider band we never
            // announced is now stale — retire it so it can't fire late.
            for t in thresholdsMeters where t >= band { fired.insert(t) }
            firedFor[maneuverIndex] = fired
        }
        return Snapshot(
            maneuverIndex: maneuverIndex,
            metersToManeuver: metersToManeuver,
            firedThresholdM: candidate
        )
    }
}

public enum GeoMath {
    private static let earthR = 6_371_000.0

    public static func haversineMeters(
        _ lat1: Double, _ lon1: Double,
        _ lat2: Double, _ lon2: Double
    ) -> Double {
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon / 2) * sin(dLon / 2)
        return earthR * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Forward bearing from (lat1, lon1) → (lat2, lon2), degrees, 0..360.
    /// 0 = north, 90 = east. Standard great-circle initial bearing formula.
    public static func bearingDeg(
        _ lat1: Double, _ lon1: Double,
        _ lat2: Double, _ lon2: Double
    ) -> Double {
        let φ1 = lat1 * .pi / 180
        let φ2 = lat2 * .pi / 180
        let Δλ = (lon2 - lon1) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        var θ = atan2(y, x) * 180 / .pi
        if θ < 0 { θ += 360.0 }
        return θ
    }
}
