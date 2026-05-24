import XCTest
@testable import ScoovaNavLayerCore

/// Regression tests for the user-reported "walking on the same direction
/// but not exactly on the line — that's not off-route" complaint.
///
/// Each test feeds GuidanceMonitor a straight north-running route, then
/// pushes a ProgressEvent with the rider OFFSET laterally by the amount
/// under test and a bearing that either matches the route (parallel
/// walking) or opposes it (genuine wrong-way).
final class ParallelWalkingTests: XCTestCase {

    /// Build a 1 km straight route running due north from (40.7600,-73.9850).
    /// One degree latitude ≈ 111_320 m, so 1 km north = +0.00898°.
    private func straightNorthRoute() -> [[Double]] {
        let lat0 = 40.7600
        let lon0 = -73.9850
        return [
            [lat0,           lon0],
            [lat0 + 0.00450, lon0],
            [lat0 + 0.00898, lon0],
        ]
    }

    /// 15 m east of the route line ≈ +0.000179° lon at this latitude.
    private let offsetLon15mEast = 0.000179

    /// Heading 0° (due north) — matches the route segment bearing.
    private let northBearing: Float = 0

    /// Heading 180° (due south) — opposite to the route direction.
    private let southBearing: Float = 180

    private func progress(
        lat: Double, lon: Double,
        speed: Float, bearing: Float
    ) -> ProgressEvent {
        ProgressEvent(
            latitude: lat, longitude: lon,
            speedMps: speed, bearingDeg: bearing,
            upcomingManeuverIndex: 1,
            metersToUpcomingManeuver: 500,
            secondsRemaining: 600,
            metersRemaining: 800
        )
    }

    // ── Pedestrian-parallel suppression ────────────────────────────────

    func testPedestrianSidewalkParallelSuppressesOffRoute() {
        let monitor = GuidanceMonitor()
        monitor.setRoute(straightNorthRoute())
        monitor.setCosting("pedestrian")

        // Rider is on a sidewalk 15 m east of the routed centerline,
        // walking north at 1.5 m/s (3.4 mph). This is the NYC case.
        let lat0 = 40.7600
        let lon0 = -73.9850 + offsetLon15mEast

        // Run several ticks across 8 s — long enough that BOTH the
        // drift timer (3 s) AND the off-route timer (5 s) would expire
        // if the events were triggering. Then assert nothing fired.
        var allEvents: [GuidanceEvent] = []
        for tick in 0...8 {
            let p = progress(
                lat: lat0 + 0.000004 * Double(tick),  // ~0.45 m north / tick
                lon: lon0,
                speed: 1.5, bearing: northBearing)
            let nowMs: Int64 = 1_000_000 + Int64(tick) * 1_000
            allEvents.append(contentsOf: monitor.onProgress(p, nowMs: nowMs))
        }
        let driftLeft = allEvents.contains { if case .driftLeft = $0 { return true } else { return false } }
        let driftRight = allEvents.contains { if case .driftRight = $0 { return true } else { return false } }
        let offRoute = allEvents.contains { if case .offRoute = $0 { return true } else { return false } }
        XCTAssertFalse(driftLeft, "Parallel-walking pedestrian should NOT trigger driftLeft")
        XCTAssertFalse(driftRight, "Parallel-walking pedestrian should NOT trigger driftRight")
        XCTAssertFalse(offRoute,
            "Parallel-walking pedestrian 15 m off the centerline must NOT trigger off-route")
    }

    func testPedestrianWrongDirectionDoesFireOffRoute() {
        let monitor = GuidanceMonitor()
        monitor.setRoute(straightNorthRoute())
        monitor.setCosting("pedestrian")

        // Rider is 65 m east of the line (above the pedestrian off-route
        // threshold of 60 m) AND walking SOUTH (opposite to the route).
        // Parallel-suppression must NOT apply; off-route should fire
        // after the 5 s duration window.
        let lat0 = 40.7610
        let lon0 = -73.9850 + offsetLon15mEast * 5   // 75 m east
        var allEvents: [GuidanceEvent] = []
        for tick in 0...8 {
            let p = progress(
                lat: lat0 - 0.000004 * Double(tick),
                lon: lon0,
                speed: 1.5, bearing: southBearing)
            let nowMs: Int64 = 1_000_000 + Int64(tick) * 1_000
            allEvents.append(contentsOf: monitor.onProgress(p, nowMs: nowMs))
        }
        let offRoute = allEvents.contains { if case .offRoute = $0 { return true } else { return false } }
        XCTAssertTrue(offRoute,
            "Pedestrian 75 m off-line AND heading opposite the route MUST trigger off-route")
    }

    // ── Mode-aware threshold differences ───────────────────────────────

    func testAutoFiresOffRouteAt35mWhilePedestrianDoesNot() {
        // 35 m east of the line — above the auto 30 m threshold but
        // below the pedestrian 60 m threshold. Same heading (south,
        // opposite to route) so parallel-suppression doesn't apply.
        // We're testing the threshold scaling alone.

        func runMonitor(costing: String) -> Bool {
            let monitor = GuidanceMonitor()
            monitor.setRoute(straightNorthRoute())
            monitor.setCosting(costing)
            let lat0 = 40.7610
            let lon0 = -73.9850 + offsetLon15mEast * 35.0 / 15.0    // ≈35 m east
            var allEvents: [GuidanceEvent] = []
            for tick in 0...8 {
                let p = progress(
                    lat: lat0 - 0.000004 * Double(tick),
                    lon: lon0,
                    speed: 1.5, bearing: southBearing)
                let nowMs: Int64 = 1_000_000 + Int64(tick) * 1_000
                allEvents.append(contentsOf: monitor.onProgress(p, nowMs: nowMs))
            }
            return allEvents.contains {
                if case .offRoute = $0 { return true } else { return false }
            }
        }

        XCTAssertTrue(runMonitor(costing: "auto"),
            "Car 35 m off-line MUST trigger off-route (threshold 30 m)")
        XCTAssertFalse(runMonitor(costing: "pedestrian"),
            "Pedestrian 35 m off-line must NOT trigger off-route (threshold 60 m)")
    }

    func testStandstillNoParallelBypass() {
        // At standstill the GPS bearing is unreliable, so the parallel-
        // walking gate cannot fire. A genuinely-strayed pedestrian who
        // stops well off-line should still get an off-route event.
        let monitor = GuidanceMonitor()
        monitor.setRoute(straightNorthRoute())
        monitor.setCosting("pedestrian")

        let lat0 = 40.7610
        let lon0 = -73.9850 + offsetLon15mEast * 5   // 75 m east
        var allEvents: [GuidanceEvent] = []
        for tick in 0...8 {
            let p = progress(
                lat: lat0, lon: lon0,
                speed: 0.0,                  // stopped
                bearing: northBearing)       // looks parallel, but speed=0 kills the bypass
            let nowMs: Int64 = 1_000_000 + Int64(tick) * 1_000
            allEvents.append(contentsOf: monitor.onProgress(p, nowMs: nowMs))
        }
        let offRoute = allEvents.contains { if case .offRoute = $0 { return true } else { return false } }
        XCTAssertTrue(offRoute,
            "A stopped rider 75 m off-line must trigger off-route — parallel bypass needs speed > 0.5 m/s")
    }
}
