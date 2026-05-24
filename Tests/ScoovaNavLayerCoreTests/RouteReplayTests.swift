import XCTest
@testable import ScoovaNavLayerCore

/// End-to-end replay. Builds the engine, pushes a route, then drives a
/// scripted sequence of progress events down a two-turn ride and
/// asserts the spoken cue sequence: a welcome, then each turn's
/// far / mid / near in order, the post-turn confirm, and the arrival.
///
/// No trip-state is fed, so the reactive guidance lines stay silent —
/// the spoken stream is exactly the welcome + cue track + arrival,
/// which makes the assertion deterministic. This is the test that
/// locks down "cues fire in the right order at the right places".
final class RouteReplayTests: XCTestCase {

    private func turn(
        _ i: Int, _ type: ManeuverType, segment: Double,
        far: String, mid: String, near: String, confirm: String
    ) -> ManeuverEvent {
        ManeuverEvent(
            index: i, total: 4, type: type,
            latitude: 0, longitude: 0, segmentLengthMeters: segment,
            voiceFar: far, voiceMid: mid, voiceNear: near,
            voiceConfirm: confirm,
            cueFarMeters: 150, cueMidMeters: 80, cueNearMeters: 20)
    }

    func testTwoTurnRideSpeaksEveryCueInOrder() {
        let nav = ScoovaNavLayer.builder()
            .apiKey("sk_test").locale("en-US").profile("scooter")
            .landmarks(true).build()

        var spoken: [String] = []
        nav.onCueSpoken = { spoken.append($0) }

        let route: [ManeuverEvent] = [
            ManeuverEvent(index: 0, total: 4, type: .depart,
                          latitude: 0, longitude: 0, segmentLengthMeters: 300),
            turn(1, .right, segment: 300,
                 far: "FAR1", mid: "MID1", near: "NEAR1", confirm: "CONFIRM1"),
            turn(2, .left, segment: 300,
                 far: "FAR2", mid: "MID2", near: "NEAR2", confirm: "CONFIRM2"),
            ManeuverEvent(index: 3, total: 4, type: .arrive,
                          latitude: 0, longitude: 0, segmentLengthMeters: 0),
        ]
        nav.onRoute(route)

        func tick(idx: Int, toManeuver: Double, remaining: Int) {
            nav.onProgress(ProgressEvent(
                latitude: 0, longitude: 0,
                speedMps: 6, bearingDeg: 0,
                upcomingManeuverIndex: idx,
                metersToUpcomingManeuver: toManeuver,
                secondsRemaining: remaining / 6,
                metersRemaining: remaining))
        }

        // Approach turn 1 — remaining stays large so arrival can't fire.
        for d in [300.0, 200, 150, 100, 80, 40, 20, 5] {
            tick(idx: 1, toManeuver: d, remaining: 700)
        }
        // Approach turn 2.
        for d in [300.0, 250, 150, 100, 80, 40, 20, 5] {
            tick(idx: 2, toManeuver: d, remaining: 350)
        }
        // Arrive — within range, almost no distance left.
        tick(idx: 3, toManeuver: 8, remaining: 10)

        // The turn cues — each spoken exactly once, in ride order.
        let turnCues = spoken.filter {
            $0.hasPrefix("FAR") || $0.hasPrefix("MID")
                || $0.hasPrefix("NEAR") || $0.hasPrefix("CONFIRM")
        }
        XCTAssertEqual(
            turnCues,
            ["FAR1", "MID1", "NEAR1", "CONFIRM1", "FAR2", "MID2", "NEAR2"],
            "far → mid → near per turn, the previous turn's confirm "
                + "opening turn 2 — each once, none duplicated, none missed")

        // A welcome opens the ride and an arrival closes it — both are
        // real phrases, and neither is one of the turn cues.
        XCTAssertNotEqual(spoken.first, "FAR1", "a welcome is spoken first")
        XCTAssertNotEqual(spoken.last, "NEAR2", "an arrival is spoken last")
        XCTAssertGreaterThanOrEqual(
            spoken.count, 9, "welcome + 7 turn cues + arrival")
    }

    func testOffRouteSpeaksTheManeuverRecoverCue() {
        // When the rider strays off-route, the maneuver they were
        // heading for carries its own recovery line — it's spoken in
        // place of the generic trip-level rerouting phrase.
        let nav = ScoovaNavLayer.builder()
            .apiKey("sk_test").locale("en-US").profile("scooter").build()
        var spoken: [String] = []
        nav.onCueSpoken = { spoken.append($0) }

        let turn = ManeuverEvent(
            index: 1, total: 3, type: .right,
            latitude: 0, longitude: 0, segmentLengthMeters: 300,
            voiceRecover: "Looks like you missed the turn, recalculating.")
        nav.handleGuidanceEvent(.offRoute(lateralM: 45), maneuver: turn)

        XCTAssertEqual(
            spoken, ["Looks like you missed the turn, recalculating."],
            "off-route speaks the maneuver's recover cue")
    }

    func testKeepGoingIsAChimeNotARepeatedPhrase() {
        // On a long quiet stretch the "still on track" reassurance must
        // be the soft chime — never a spoken phrase. Hearing the same
        // words every 40 s was the monotony the 10 km log exposed.
        let nav = ScoovaNavLayer.builder()
            .apiKey("sk_test").locale("en-US").profile("scooter").build()
        var spoken: [String] = []
        nav.onCueSpoken = { spoken.append($0) }
        nav.setTripState(["keepGoing": "Keep going straight"])

        let m = ManeuverEvent(
            index: 1, total: 3, type: .right,
            latitude: 0, longitude: 0, segmentLengthMeters: 300)
        nav.handleGuidanceEvent(.keepGoing, maneuver: m)

        XCTAssertTrue(
            spoken.isEmpty,
            "keepGoing plays a non-verbal chime — it must not speak a phrase")
    }

    func testNothingSpeaksBeforeARouteIsLoaded() {
        let nav = ScoovaNavLayer.builder()
            .apiKey("sk_test").locale("en-US").profile("scooter")
            .landmarks(true).build()
        var spoken: [String] = []
        nav.onCueSpoken = { spoken.append($0) }
        // Progress with no route loaded — must be a no-op, not a crash.
        nav.onProgress(ProgressEvent(
            latitude: 0, longitude: 0,
            upcomingManeuverIndex: 0,
            metersToUpcomingManeuver: 100,
            secondsRemaining: 60, metersRemaining: 500))
        XCTAssertTrue(spoken.isEmpty)
    }
}
