import Foundation

/// Dead-reckons the rider's position forward when GPS drops out
/// (tunnels, underpasses, urban canyons). The navigator is most
/// useful precisely in the places GPS fails — a tunnel is exactly
/// where a rider needs the next cue to fire on time. Without
/// dead-reckoning the cursor freezes the moment the fix goes silent
/// and every downstream cue mis-fires.
///
/// The math is intentionally minimal: take the last known
/// `(lat, lon, courseDeg, speedMps)` and integrate forward by the
/// elapsed wall-clock time. No EKF, no Kalman — just constant-
/// velocity along the last-known heading. Good for ~30 s of tunnel;
/// errors compound past that. The reasoner re-anchors on the next
/// real GPS fix.
public final class DeadReckoner {
    /// Latest GPS observation the reckoner remembers. The reckoner
    /// emits forward extrapolations from this anchor when no fresh
    /// fix has arrived.
    private struct Anchor {
        let lat: Double
        let lon: Double
        let courseDeg: Double
        let speedMps: Double
        let tsMs: Int64
    }

    private var anchor: Anchor?
    /// Maximum time the reckoner is willing to extrapolate before
    /// giving up and reporting `nil`. 30 s of tunnel at 10 m/s is
    /// 300 m of error build-up — acceptable; beyond that the
    /// projection drifts too far to trust.
    private let maxExtrapolationMs: Int64 = 30_000

    public init() {}

    /// Anchor on a real GPS fix. The reckoner overwrites whatever
    /// it had — the freshest observation always wins.
    public func observe(
        lat: Double, lon: Double,
        courseDeg: Double?, speedMps: Double?,
        tsMs: Int64
    ) {
        // Only anchor on a fix that has both course AND moving speed.
        // Stationary fixes have no information about future motion, so
        // dead-reckoning them is no better than holding the cursor.
        guard let course = courseDeg, let speed = speedMps, speed >= 1.0 else {
            anchor = nil
            return
        }
        anchor = Anchor(
            lat: lat, lon: lon,
            courseDeg: course, speedMps: speed, tsMs: tsMs
        )
    }

    /// Returns the dead-reckoned position at `nowMs` — the rider's
    /// estimated location given the anchor + elapsed time. Returns
    /// nil when no anchor exists, when the anchor is too old, or
    /// when speed was too low to extrapolate from.
    public func project(nowMs: Int64) -> (lat: Double, lon: Double)? {
        guard let a = anchor else { return nil }
        let dtMs = nowMs - a.tsMs
        guard dtMs >= 0, dtMs <= maxExtrapolationMs else { return nil }
        let distanceM = a.speedMps * Double(dtMs) / 1000.0
        // Local equirectangular forward step. Adequate at city scale
        // for ≤300 m extrapolation; the global geometry of great-
        // circle bearings doesn't change much over that range.
        let headingRad = a.courseDeg * .pi / 180
        let dLatM = distanceM * cos(headingRad)
        let dLonM = distanceM * sin(headingRad)
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(a.lat * .pi / 180)
        let newLat = a.lat + dLatM / mPerDegLat
        let newLon = a.lon + dLonM / mPerDegLon
        return (newLat, newLon)
    }

    /// Clear the anchor — call when starting / stopping nav.
    public func reset() { anchor = nil }
}
