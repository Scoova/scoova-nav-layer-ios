import XCTest
@testable import ScoovaNavLayerCore

/// Acceptance tests for the navigator state machine's geometric
/// preconditions. Each test pins one rule from
/// [[cue-preconditions-are-coords]] — a cue must NOT fire when the
/// place it references is geometrically behind the rider.
final class NavigatorStateMachineTests: XCTestCase {

    // MARK: - Fixtures

    /// Maneuver at a given lat/lon, type=left, index=1 of 3.
    private func leftTurn(lat: Double, lon: Double) -> ManeuverEvent {
        ManeuverEvent(
            index: 1, total: 3, type: .left,
            latitude: lat, longitude: lon,
            segmentLengthMeters: 200
        )
    }

    /// LiveGuidanceState built so the navigator's approach path is
    /// otherwise unblocked: snap on a route way, alignment on-route,
    /// upcomingDecision with a small distance so far/mid/near windows
    /// open at any reasonable speed.
    private func liveStateApproaching(
        distance: Double = 80,
        snapWayId: Int64 = 1,
        courseMatchesForward: Bool? = true
    ) -> LiveGuidanceState {
        let snap = Localizer.Snap(
            wayId: snapWayId, name: "Test Road",
            lateralM: 5, segmentBearingDeg: 0,
            courseMatchesForward: courseMatchesForward,
            oneway: false,
            snappedLat: 0, snappedLon: 0
        )
        let alignment = LiveGuidanceState.Alignment(
            onRoute: true, lateralM: 5,
            courseMatchesSegment: true
        )
        let decision = LiveGuidanceState.UpcomingDecision(
            type: .left, distance: distance,
            ordinal: 1, totalSameSideTurns: 1
        )
        return LiveGuidanceState(
            snap: snap, isOnRouteWay: true,
            segmentOnGraph: nil, segmentOnRoute: 1,
            alignment: alignment,
            upcomingDecision: decision,
            ambiguityFlags: []
        )
    }

    /// Wall-clock "now" + an offset (ms). The navigator's grace
    /// window and per-intent cooldowns subtract against wall clock,
    /// so synthetic tiny nowMs values mask the throttle. All tests
    /// derive `nowMs` from this so the grace + cooldown act like
    /// real life.
    private func nowMs(plus ms: Int64 = 0) -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000) + ms
    }

    // MARK: - Approach precondition

    /// The maneuver is to the east of the rider (lon 0.001 ≈ ~111 m).
    /// Rider is at the origin heading EAST (bearing 90°). Maneuver IS
    /// ahead → approach intent emitted.
    func testApproachFiresWhenManeuverAheadOfRider() {
        let nav = NavigatorStateMachine()
        let m = leftTurn(lat: 0, lon: 0.001)
        nav.reset(isReroute: false)
        // 20 s after reset — past the 5 s start-grace window.
        let intents = nav.tick(
            live: liveStateApproaching(distance: 60),
            upcoming: m,
            metersRemainingToDestination: 600,
            arrivedLatched: false,
            speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 90,    // heading east, toward maneuver
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        let approach = intents.first { intent in
            if case .approach = intent { return true }
            return false
        }
        XCTAssertNotNil(approach,
            "Approach intent must fire when the maneuver is ahead")
    }

    /// Same geometry, rider heading WEST (bearing 270°) — the maneuver
    /// is now BEHIND. The polyline-projected distance still reads 60 m
    /// (cursor logic), but the cue is nonsense. Must NOT fire.
    func testApproachSuppressedWhenManeuverBehindRider() {
        let nav = NavigatorStateMachine()
        let m = leftTurn(lat: 0, lon: 0.001)
        nav.reset(isReroute: false)
        let intents = nav.tick(
            live: liveStateApproaching(distance: 60),
            upcoming: m,
            metersRemainingToDestination: 600,
            arrivedLatched: false,
            speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 270,   // heading west, AWAY from maneuver
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        let approach = intents.first { intent in
            if case .approach = intent { return true }
            return false
        }
        XCTAssertNil(approach,
            "Approach intent must NOT fire when the maneuver is behind")
    }

    /// Suppressed approach must NOT mark the phase consumed — a U-turn
    /// that brings the maneuver back ahead must let the cue fire.
    func testApproachReopensAfterUTurnPutsManeuverAhead() {
        let nav = NavigatorStateMachine()
        let m = leftTurn(lat: 0, lon: 0.001)
        nav.reset(isReroute: false)
        // First tick: maneuver behind (rider heading west). No fire,
        // no phase consumption.
        _ = nav.tick(
            live: liveStateApproaching(distance: 60),
            upcoming: m,
            metersRemainingToDestination: 600,
            arrivedLatched: false,
            speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 270,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 6_000)
        )
        // Second tick (well past per-intent cooldown): rider U-turned.
        // Approach must NOW fire.
        let intents = nav.tick(
            live: liveStateApproaching(distance: 60),
            upcoming: m,
            metersRemainingToDestination: 600,
            arrivedLatched: false,
            speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 90,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 25_000)
        )
        let approach = intents.first { intent in
            if case .approach = intent { return true }
            return false
        }
        XCTAssertNotNil(approach,
            "Approach must re-open after the maneuver becomes ahead again")
    }

    /// No bearing → can't judge direction → cue passes through.
    /// Trip-start case (first GPS fix, no heading yet) must not be
    /// silenced.
    func testApproachFiresWhenBearingUnknown() {
        let nav = NavigatorStateMachine()
        let m = leftTurn(lat: 0, lon: 0.001)
        nav.reset(isReroute: false)
        let intents = nav.tick(
            live: liveStateApproaching(distance: 60),
            upcoming: m,
            metersRemainingToDestination: 600,
            arrivedLatched: false,
            speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: nil,   // no heading
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        let approach = intents.first { intent in
            if case .approach = intent { return true }
            return false
        }
        XCTAssertNotNil(approach,
            "Approach must fire when bearing is unknown (pass-through)")
    }

    // MARK: - Wrong-way throttle across reroute

    /// Wrong-way fires on a fresh route, the rider keeps going wrong
    /// way, a reroute lands shortly after, the rider is STILL going
    /// wrong way — wrong-way must NOT re-fire within the 15 s
    /// per-intent throttle. Live-observed bug 2026-05-29: rider heard
    /// the cue twice in 2 seconds across the reroute boundary.
    func testWrongWayThrottleSurvivesReroute() {
        let nav = NavigatorStateMachine()
        // Wrong-way snap: on a route way but going the wrong way.
        let wrongSnap = Localizer.Snap(
            wayId: 1, name: "Infinite Loop",
            lateralM: 5, segmentBearingDeg: 0,
            courseMatchesForward: false,
            oneway: true,
            snappedLat: 0, snappedLon: 0
        )
        let live = LiveGuidanceState(
            snap: wrongSnap, isOnRouteWay: true,
            segmentOnGraph: nil, segmentOnRoute: 1,
            alignment: LiveGuidanceState.Alignment(
                onRoute: true, lateralM: 5,
                courseMatchesSegment: false
            ),
            upcomingDecision: LiveGuidanceState.UpcomingDecision(
                type: .left, distance: 80,
                ordinal: 1, totalSameSideTurns: 1
            ),
            ambiguityFlags: []
        )
        let m = leftTurn(lat: 0, lon: 0.001)

        nav.reset(isReroute: false)
        // 20 s after reset — wrong-way fires.
        let firstIntents = nav.tick(
            live: live, upcoming: m,
            metersRemainingToDestination: 600,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 180,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        XCTAssertTrue(firstIntents.contains { intent in
            if case .wrongWay = intent { return true }
            return false
        }, "Wrong-way must fire on first detection")

        // Reroute lands. New route, but the rider's direction is
        // unchanged.
        nav.reset(isReroute: true)
        // 2 s after the first cue, with the SAME wrong-way condition.
        // The 15 s throttle MUST hold — no second cue.
        let secondIntents = nav.tick(
            live: live, upcoming: m,
            metersRemainingToDestination: 600,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 180,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 22_000)
        )
        XCTAssertFalse(secondIntents.contains { intent in
            if case .wrongWay = intent { return true }
            return false
        }, "Wrong-way must NOT re-fire 2 s after reroute when the rider's direction is unchanged")
    }

    /// On a fresh (non-reroute) start, wrong-way fires whenever the
    /// condition is met. Ensures the throttle-preservation fix didn't
    /// break the normal case.
    func testWrongWayFiresFreshOnInitialRoute() {
        let nav = NavigatorStateMachine()
        let wrongSnap = Localizer.Snap(
            wayId: 1, name: "Test Road",
            lateralM: 5, segmentBearingDeg: 0,
            courseMatchesForward: false,
            oneway: true,
            snappedLat: 0, snappedLon: 0
        )
        let live = LiveGuidanceState(
            snap: wrongSnap, isOnRouteWay: true,
            segmentOnGraph: nil, segmentOnRoute: 1,
            alignment: LiveGuidanceState.Alignment(
                onRoute: true, lateralM: 5,
                courseMatchesSegment: false
            ),
            upcomingDecision: LiveGuidanceState.UpcomingDecision(
                type: .left, distance: 80,
                ordinal: 1, totalSameSideTurns: 1
            ),
            ambiguityFlags: []
        )
        let m = leftTurn(lat: 0, lon: 0.001)
        nav.reset(isReroute: false)
        let intents = nav.tick(
            live: live, upcoming: m,
            metersRemainingToDestination: 600,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 180,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        XCTAssertTrue(intents.contains { intent in
            if case .wrongWay = intent { return true }
            return false
        }, "Wrong-way must fire on a fresh initial route when the condition is met")
    }

    // MARK: - Reroute clears stale per-maneuver throttles

    /// Bug observed 2026-05-29: after a reroute, no approach cues
    /// fired for the new route's first turn because the throttle
    /// key `approach-far-1` carried over from the old route's mnv#1
    /// firing < 15 s earlier. Per-maneuver keys MUST clear on
    /// reroute; the new route's maneuver #1 is a different turn at
    /// a different coord.
    func testRerouteClearsStaleApproachThrottle() {
        let nav = NavigatorStateMachine()
        let m = leftTurn(lat: 0, lon: 0.001)
        nav.reset(isReroute: false)
        // Fire the far approach on the OLD route.
        let firstIntents = nav.tick(
            live: liveStateApproaching(distance: 120),
            upcoming: m,
            metersRemainingToDestination: 600,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 90,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        XCTAssertTrue(firstIntents.contains { intent in
            if case .approach(.far, _) = intent { return true }
            return false
        }, "Approach far must fire on the old route")

        // Reroute lands 2 s later. New route, same maneuver index 1
        // (different turn, different place). The throttle key
        // `approach-far-1` carries over if reroute reset is bugged.
        nav.reset(isReroute: true)
        let m2 = leftTurn(lat: 0, lon: 0.001)
        let secondIntents = nav.tick(
            live: liveStateApproaching(distance: 120),
            upcoming: m2,
            metersRemainingToDestination: 600,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 90,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 22_000)
        )
        XCTAssertTrue(secondIntents.contains { intent in
            if case .approach(.far, _) = intent { return true }
            return false
        }, "Approach far must fire fresh on the new route after a reroute")
    }

    /// The wrong-way throttle MUST still survive a reroute (Bug
    /// observed 04:44:26 → 04:44:28). The reroute-clears-throttles
    /// fix must NOT regress the wrong-way preservation.
    func testRerouteThrottleClearPreservesWrongWayKey() {
        let nav = NavigatorStateMachine()
        let wrongSnap = Localizer.Snap(
            wayId: 1, name: "Infinite Loop",
            lateralM: 5, segmentBearingDeg: 0,
            courseMatchesForward: false,
            oneway: true,
            snappedLat: 0, snappedLon: 0
        )
        let live = LiveGuidanceState(
            snap: wrongSnap, isOnRouteWay: true,
            segmentOnGraph: nil, segmentOnRoute: 1,
            alignment: LiveGuidanceState.Alignment(
                onRoute: true, lateralM: 5,
                courseMatchesSegment: false
            ),
            upcomingDecision: LiveGuidanceState.UpcomingDecision(
                type: .left, distance: 80,
                ordinal: 1, totalSameSideTurns: 1
            ),
            ambiguityFlags: []
        )
        let m = leftTurn(lat: 0, lon: 0.001)
        nav.reset(isReroute: false)
        // Fire wrong-way.
        _ = nav.tick(
            live: live, upcoming: m,
            metersRemainingToDestination: 600,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 180,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 20_000)
        )
        // Reroute lands. Wrong-way throttle MUST survive.
        nav.reset(isReroute: true)
        let secondIntents = nav.tick(
            live: live, upcoming: m,
            metersRemainingToDestination: 600,
            arrivedLatched: false, speedMps: 5,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 180,
            destLat: nil, destLon: nil,
            nowMs: nowMs(plus: 22_000)
        )
        XCTAssertFalse(secondIntents.contains { intent in
            if case .wrongWay = intent { return true }
            return false
        }, "Wrong-way throttle MUST survive a reroute even though other per-maneuver throttles clear")
    }

    // MARK: - coordIsAhead helper

    func testCoordIsAheadWhenInFront() {
        let nav = NavigatorStateMachine()
        // Rider at (0,0) heading east; target at (0, 0.001) — east.
        XCTAssertTrue(nav.coordIsAhead(
            lat: 0, lon: 0.001,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 90, speedMps: 5
        ))
    }

    func testCoordIsAheadFalseWhenBehind() {
        let nav = NavigatorStateMachine()
        // Rider at (0,0) heading east; target at (0, -0.001) — west.
        XCTAssertFalse(nav.coordIsAhead(
            lat: 0, lon: -0.001,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 90, speedMps: 5
        ))
    }

    func testCoordIsAheadPassThroughWhenNoBearing() {
        let nav = NavigatorStateMachine()
        XCTAssertTrue(nav.coordIsAhead(
            lat: 0, lon: -0.001,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: nil, speedMps: 5
        ))
    }

    func testCoordIsAheadPassThroughWhenSpeedTooLow() {
        let nav = NavigatorStateMachine()
        // Stationary — bearing untrustworthy — pass through.
        XCTAssertTrue(nav.coordIsAhead(
            lat: 0, lon: -0.001,
            riderLat: 0, riderLon: 0,
            riderBearingDeg: 90, speedMps: 0.5
        ))
    }
}
