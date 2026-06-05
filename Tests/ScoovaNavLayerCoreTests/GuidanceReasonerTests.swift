import XCTest
@testable import ScoovaNavLayerCore

/// Reasoner + grammar acceptance: the wrong-cue class of bugs the
/// corridor work is built to fix. Each test pins one architectural
/// promise — read these as the contract the SDK is held to.
final class GuidanceReasonerTests: XCTestCase {

    // MARK: - Fixtures

    private func progress(_ lat: Double = 0, _ lon: Double = 0,
                          upcoming: Int = 1, toMnv: Double = 100,
                          speed: Float? = 5, bearing: Float? = 90) -> ProgressEvent {
        ProgressEvent(
            latitude: lat, longitude: lon,
            speedMps: speed, bearingDeg: bearing,
            upcomingManeuverIndex: upcoming,
            metersToUpcomingManeuver: toMnv,
            secondsRemaining: 60,
            metersRemaining: 600
        )
    }

    private func leftTurn(index: Int = 1, total: Int = 3, landmark: String? = nil) -> ManeuverEvent {
        ManeuverEvent(
            index: index, total: total, type: .left,
            latitude: 0, longitude: 0,
            segmentLengthMeters: 200,
            landmark: landmark
        )
    }

    /// Trivial two-vertex polyline running east along the equator.
    /// `nearestPolylineVertex` returns 0 or 1 depending on lon.
    private let eastWestShape: [[Double]] = [[0, 0], [0, 0.001]]

    // MARK: - Grammar rules

    func testLandmarkGrammarWinsAtNearPhase() {
        let dec = LiveGuidanceState.UpcomingDecision(
            type: .left, distance: 12, ordinal: 2, totalSameSideTurns: 2
        )
        let cue = CueGrammar.chooseCue(
            decision: dec, phase: .near, locale: "en-US",
            landmark: "the gas station", fallback: nil
        )
        XCTAssertEqual(cue.rule, "landmark")
        XCTAssertEqual(cue.text, "Turn left at the gas station.")
    }

    func testOrdinalGrammarFiresAtNearWhenMultipleSameSideTurnsAhead() {
        // Two lefts on the approach, near phase: the maneuver is the
        // SECOND. Grammar must NEVER emit "the next left" here — that
        // was the bug class the user hit. Ordinal is the corridor's
        // whole purpose. (Far/mid phases must NOT make ordinal claims
        // even with this data, since they fire too early to commit.)
        let dec = LiveGuidanceState.UpcomingDecision(
            type: .left, distance: 12, ordinal: 2, totalSameSideTurns: 2
        )
        let cue = CueGrammar.chooseCue(
            decision: dec, phase: .near, locale: "en-US",
            landmark: nil, fallback: nil
        )
        XCTAssertEqual(cue.rule, "ordinal")
        XCTAssertEqual(cue.text, "Take the second left.")
    }

    func testNextConfirmedAtNearOnlyWhenExactlyOneSameSideTurn() {
        let dec = LiveGuidanceState.UpcomingDecision(
            type: .right, distance: 10, ordinal: 1, totalSameSideTurns: 1
        )
        let cue = CueGrammar.chooseCue(
            decision: dec, phase: .near, locale: "en-US",
            landmark: nil, fallback: nil
        )
        XCTAssertEqual(cue.rule, "next-confirmed")
        XCTAssertEqual(cue.text, "Take the next right.")
    }

    func testFarPhaseAlwaysDistanceFormEvenWithOrdinalData() {
        // Even when the corridor supplied a clean ordinal, the FAR
        // cue (30 s out) must NOT commit to "take the second left" —
        // that's a heads-up moment, not an action. Distance form is
        // honest at any distance.
        let dec = LiveGuidanceState.UpcomingDecision(
            type: .left, distance: 200, ordinal: 2, totalSameSideTurns: 2
        )
        let cue = CueGrammar.chooseCue(
            decision: dec, phase: .far, locale: "en-US",
            landmark: "McDonald's", fallback: nil
        )
        XCTAssertEqual(cue.rule, "far-distance")
        XCTAssertEqual(cue.text, "Turn left in 200 metres.")
    }

    func testMidPhasePrefersLandmarkOverDistanceWhenAvailable() {
        let dec = LiveGuidanceState.UpcomingDecision(
            type: .right, distance: 80, ordinal: 1, totalSameSideTurns: 1
        )
        let cue = CueGrammar.chooseCue(
            decision: dec, phase: .mid, locale: "en-US",
            landmark: "the bakery", fallback: nil
        )
        XCTAssertEqual(cue.rule, "mid-landmark")
        XCTAssertEqual(cue.text, "After the bakery, turn right.")
    }

    func testMidPhaseFallsBackToDistanceWithoutLandmark() {
        let dec = LiveGuidanceState.UpcomingDecision(
            type: .right, distance: 80, ordinal: 1, totalSameSideTurns: 1
        )
        let cue = CueGrammar.chooseCue(
            decision: dec, phase: .mid, locale: "en-US",
            landmark: nil, fallback: nil
        )
        XCTAssertEqual(cue.rule, "mid-distance")
        XCTAssertEqual(cue.text, "Turn right in 80 metres.")
    }

    func testNearActionWhenNoOrdinalProofAndNoLandmark() {
        // Reasoner has NO ordinal context — happens for maneuvers the
        // corridor block didn't include (e.g. interchange clusters
        // capped at 8 crossings). Near phase falls to a plain action.
        let dec = LiveGuidanceState.UpcomingDecision(
            type: .left, distance: 8, ordinal: nil, totalSameSideTurns: nil
        )
        let cue = CueGrammar.chooseCue(
            decision: dec, phase: .near, locale: "en-US",
            landmark: nil, fallback: "BAKED"
        )
        XCTAssertEqual(cue.rule, "near-action")
        XCTAssertEqual(cue.text, "Turn left now.")
    }

    func testFallbackWhenManeuverHasNoSide() {
        let dec = LiveGuidanceState.UpcomingDecision(
            type: .continue, distance: 100, ordinal: nil, totalSameSideTurns: nil
        )
        let cue = CueGrammar.chooseCue(
            decision: dec, phase: .near, locale: "en-US",
            landmark: nil, fallback: "BAKED"
        )
        XCTAssertEqual(cue.rule, "fallback")
        XCTAssertEqual(cue.text, "BAKED")
    }

    func testArabicOrdinalGrammarAtNear() {
        let dec = LiveGuidanceState.UpcomingDecision(
            type: .right, distance: 10, ordinal: 3, totalSameSideTurns: 3
        )
        let cue = CueGrammar.chooseCue(
            decision: dec, phase: .near, locale: "ar-EG",
            landmark: nil, fallback: nil
        )
        XCTAssertEqual(cue.rule, "ordinal")
        XCTAssertEqual(cue.text, "خد اليمين التالت.")
    }

    // MARK: - Reasoner outputs

    func testReasonerProducesUpcomingDecisionFromRouteAlone() {
        // No corridor — the SDK still gets the maneuver type + distance,
        // just no ordinal context. Grammar will pick the distance form.
        let route = [
            ManeuverEvent(index: 0, total: 2, type: .depart,
                          latitude: 0, longitude: 0, segmentLengthMeters: 200),
            ManeuverEvent(index: 1, total: 2, type: .left,
                          latitude: 0, longitude: 0, segmentLengthMeters: 0),
        ]
        let state = GuidanceReasoner.reason(
            progress(toMnv: 80, speed: 5, bearing: 90),
            route: route, corridor: nil, shape: eastWestShape
        )
        XCTAssertEqual(state.upcomingDecision?.type, .left)
        XCTAssertEqual(state.upcomingDecision?.distance, 80)
        XCTAssertNil(state.upcomingDecision?.ordinal)
        XCTAssertNil(state.upcomingDecision?.totalSameSideTurns)
        XCTAssertNil(state.segmentOnGraph)
    }

    func testReasonerCarriesOrdinalContextFromCorridor() {
        let route = [
            ManeuverEvent(index: 0, total: 2, type: .depart,
                          latitude: 0, longitude: 0, segmentLengthMeters: 200),
            ManeuverEvent(index: 1, total: 2, type: .left,
                          latitude: 0, longitude: 0, segmentLengthMeters: 0),
        ]
        let corridor = Corridor(
            version: 1,
            graphFingerprints: [
                GraphFingerprint(polylineFrom: 0, polylineTo: 1,
                                 wayId: 7, direction: "forward")
            ],
            maneuvers: [
                CorridorManeuver(
                    index: 1,
                    crossStreets: [],
                    ambiguityFlags: ["multipleLeftsBeforeLeftTurn"],
                    ordinal: ManeuverOrdinal(
                        side: "L", indexAmongSameSideTurns: 2,
                        totalSameSideTurns: 2
                    ),
                    intersectionComplexity: "fourWay"
                )
            ]
        )
        let state = GuidanceReasoner.reason(
            progress(toMnv: 80), route: route,
            corridor: corridor, shape: eastWestShape
        )
        XCTAssertEqual(state.upcomingDecision?.ordinal, 2)
        XCTAssertEqual(state.upcomingDecision?.totalSameSideTurns, 2)
        XCTAssertEqual(state.ambiguityFlags, ["multipleLeftsBeforeLeftTurn"])
        XCTAssertNotNil(state.segmentOnGraph)
        XCTAssertEqual(state.segmentOnGraph?.wayId, 7)
    }

    func testReasonerCourseMatchesSegmentWhenMovingAlignedWithBearing() {
        // East-running segment + east-pointing GPS course at 5 m/s.
        let state = GuidanceReasoner.reason(
            progress(speed: 5, bearing: 90),
            route: [
                ManeuverEvent(index: 0, total: 1, type: .depart,
                              latitude: 0, longitude: 0, segmentLengthMeters: 0)
            ],
            corridor: nil, shape: eastWestShape
        )
        XCTAssertEqual(state.alignment.courseMatchesSegment, true)
    }

    func testReasonerCourseMismatchWhenMovingAgainstSegment() {
        // East-running segment but the rider's course is 270° (west).
        let state = GuidanceReasoner.reason(
            progress(speed: 5, bearing: 270),
            route: [
                ManeuverEvent(index: 0, total: 1, type: .depart,
                              latitude: 0, longitude: 0, segmentLengthMeters: 0)
            ],
            corridor: nil, shape: eastWestShape
        )
        XCTAssertEqual(state.alignment.courseMatchesSegment, false)
    }

    func testReasonerCourseUnknownAtStandstill() {
        let state = GuidanceReasoner.reason(
            progress(speed: 0.5, bearing: 90),
            route: [
                ManeuverEvent(index: 0, total: 1, type: .depart,
                              latitude: 0, longitude: 0, segmentLengthMeters: 0)
            ],
            corridor: nil, shape: eastWestShape
        )
        XCTAssertNil(state.alignment.courseMatchesSegment)
    }

    func testReasonerOnRouteFalseWhenFingerprintMismatched() {
        // Corridor present but no fingerprint covers the rider's nearest
        // polyline vertex — they're on a parallel street. Lateral may
        // still read inside the threshold but graph mismatch trumps it.
        let route = [
            ManeuverEvent(index: 0, total: 1, type: .depart,
                          latitude: 0, longitude: 0, segmentLengthMeters: 0)
        ]
        // Neighbour graph contains a way that the localizer WILL snap
        // the rider to (the only way nearby) — but the graph fingerprint
        // marks a DIFFERENT wayId as the route's expected way. So the
        // rider snaps successfully but to a non-route way → off-route.
        let corridor = Corridor(
            version: 1,
            graphFingerprints: [
                GraphFingerprint(polylineFrom: 0, polylineTo: 1,
                                 wayId: 999, direction: "forward")  // route's way
            ],
            maneuvers: [],
            neighbourGraph: [
                NeighbourWay(
                    wayId: 7,                   // a different way nearby
                    name: "Parallel Street",
                    roadClass: "secondary",
                    oneway: false,
                    segments: [
                        NeighbourWaySegment(shape: [[0, 0], [0, 0.001]],
                                            forward: true)
                    ]
                )
            ]
        )
        let state = GuidanceReasoner.reason(
            progress(), route: route,
            corridor: corridor, shape: eastWestShape
        )
        XCTAssertNotNil(state.snap, "should snap to the only nearby way")
        XCTAssertEqual(state.snap?.wayId, 7)
        XCTAssertFalse(state.isOnRouteWay,
                       "snapped wayId 7 is not in the route's way set {999}")
        XCTAssertFalse(state.alignment.onRoute)
    }

    func testReasonerIsOnRouteWayWhenSnappedToRouteWay() {
        let route = [
            ManeuverEvent(index: 0, total: 1, type: .depart,
                          latitude: 0, longitude: 0, segmentLengthMeters: 0)
        ]
        // Single way nearby AND it's the route's expected way.
        let corridor = Corridor(
            version: 1,
            graphFingerprints: [
                GraphFingerprint(polylineFrom: 0, polylineTo: 1,
                                 wayId: 7, direction: "forward")
            ],
            maneuvers: [],
            neighbourGraph: [
                NeighbourWay(
                    wayId: 7, name: "Main Street",
                    roadClass: "secondary", oneway: false,
                    segments: [
                        NeighbourWaySegment(shape: [[0, 0], [0, 0.001]],
                                            forward: true)
                    ]
                )
            ]
        )
        let state = GuidanceReasoner.reason(
            progress(), route: route,
            corridor: corridor, shape: eastWestShape
        )
        XCTAssertEqual(state.snap?.wayId, 7)
        XCTAssertTrue(state.isOnRouteWay)
        XCTAssertTrue(state.alignment.onRoute)
    }
}
