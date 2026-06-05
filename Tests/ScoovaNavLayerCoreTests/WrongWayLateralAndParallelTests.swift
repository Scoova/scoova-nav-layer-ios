import XCTest
@testable import ScoovaNavLayerCore

/// Three acceptance suites:
/// 1. Wrong-way must NOT fire when the rider is > 45 m from the
///    polyline (the snap may have matched a different segment of
///    the same OSM way — that's not a route signal).
/// 2. Parallel-heading suppression: a rider whose course aligns
///    with the polyline's local direction and who's inside the
///    drift band is NOT off-route or wrong-way, regardless of
///    snap.
/// 3. Both gates allow the legitimate cases through unchanged.
final class WrongWayLateralAndParallelTests: XCTestCase {

    private func leftTurn() -> ManeuverEvent {
        ManeuverEvent(
            index: 1, total: 3, type: .left,
            latitude: 0, longitude: 0.001,
            segmentLengthMeters: 200
        )
    }

    private func liveState(
        lateralM: Double,
        courseMatchesForward: Bool?,
        courseMatchesSegment: Bool?,
        snapWayId: Int64 = 1,
        isOnRouteWay: Bool = true,
        oneway: Bool = false
    ) -> LiveGuidanceState {
        let snap = Localizer.Snap(
            wayId: snapWayId, name: "Test Road",
            lateralM: 5,
            segmentBearingDeg: 0,
            courseMatchesForward: courseMatchesForward,
            oneway: oneway,
            snappedLat: 0, snappedLon: 0
        )
        return LiveGuidanceState(
            snap: snap,
            isOnRouteWay: isOnRouteWay,
            segmentOnGraph: nil,
            segmentOnRoute: 1,
            alignment: LiveGuidanceState.Alignment(
                onRoute: lateralM <= 60,
                lateralM: lateralM,
                courseMatchesSegment: courseMatchesSegment
            ),
            upcomingDecision: LiveGuidanceState.UpcomingDecision(
                type: .left, distance: 80,
                ordinal: 1, totalSameSideTurns: 1
            ),
            ambiguityFlags: []
        )
    }

    private func nowMs(plus ms: Int64 = 0) -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000) + ms
    }

    // MARK: - Wrong-way lateral gate

    /// Bug observed 2026-05-29 at 05:46:45: wrong-way fired with
    /// rider 116 m lateral from polyline. Snap matched a different
    /// SEGMENT of a corridor way — irrelevant to the route's actual
    /// path. Must NOT fire above the 45 m gate.
    func testWrongWaySuppressedWhenLateralAbove45m() {
        let nav = NavigatorStateMachine()
        nav.reset(isReroute: false)
        let intents = nav.tick(
            live: liveState(
                lateralM: 116, courseMatchesForward: false,
                courseMatchesSegment: false, oneway: true),
            upcoming: leftTurn(),
            metersRemainingToDestination: 200,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 90,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        XCTAssertFalse(intents.contains { intent in
            if case .wrongWay = intent { return true }
            return false
        }, "Wrong-way must NOT fire when lateral > 45 m. Got \(intents)")
    }

    /// Legitimate wrong-way: rider close to polyline (lateral 10 m),
    /// course reversed, oneway road. Must still fire.
    func testWrongWayFiresWhenLateralBelowThresholdAndCourseReversed() {
        let nav = NavigatorStateMachine()
        nav.reset(isReroute: false)
        let intents = nav.tick(
            live: liveState(
                lateralM: 10, courseMatchesForward: false,
                courseMatchesSegment: false, oneway: true),
            upcoming: leftTurn(),
            metersRemainingToDestination: 200,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 180,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        XCTAssertTrue(intents.contains { intent in
            if case .wrongWay = intent { return true }
            return false
        }, "Wrong-way must fire when lateral <= 45 m AND course reversed")
    }

    // MARK: - Parallel-heading suppression

    /// Rider on a parallel cycleway 20 m off the route, going the
    /// SAME direction as the route's local segment. Snap matched a
    /// different way (off-route snap). The legacy GuidanceMonitor
    /// suppresses off-route in this case; the navigator now does too.
    func testParallelHeadingSuppressesOffRoute() {
        let nav = NavigatorStateMachine()
        nav.reset(isReroute: false)
        let intents = nav.tick(
            live: liveState(
                lateralM: 20,
                courseMatchesForward: true,
                courseMatchesSegment: true,
                snapWayId: 999,
                isOnRouteWay: false),
            upcoming: leftTurn(),
            metersRemainingToDestination: 200,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 90,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        XCTAssertFalse(intents.contains { intent in
            if case .offRoute = intent { return true }
            return false
        }, "Off-route must NOT fire when rider is parallel-following within the band")
    }

    /// Same geometry but courseMatchesSegment is FALSE → not
    /// parallel; off-route must fire.
    func testNonParallelOffRouteStillFires() {
        let nav = NavigatorStateMachine()
        nav.reset(isReroute: false)
        let intents = nav.tick(
            live: liveState(
                lateralM: 20,
                courseMatchesForward: false,
                courseMatchesSegment: false,
                snapWayId: 999,
                isOnRouteWay: false),
            upcoming: leftTurn(),
            metersRemainingToDestination: 200,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 270,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        XCTAssertTrue(intents.contains { intent in
            if case .offRoute = intent { return true }
            return false
        }, "Off-route must still fire when course does not match the polyline")
    }

    /// Parallel suppression has a hard lateral cap — a rider 90 m
    /// off the route going the same direction is genuinely on a
    /// different street; off-route must fire.
    func testParallelSuppressionCappedByBand() {
        let nav = NavigatorStateMachine()
        nav.reset(isReroute: false)
        let intents = nav.tick(
            live: liveState(
                lateralM: 90,
                courseMatchesForward: true,
                courseMatchesSegment: true,
                snapWayId: 999,
                isOnRouteWay: false),
            upcoming: leftTurn(),
            metersRemainingToDestination: 200,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 90,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        XCTAssertTrue(intents.contains { intent in
            if case .offRoute = intent { return true }
            return false
        }, "Parallel suppression must not apply beyond the 45 m band")
    }
}
