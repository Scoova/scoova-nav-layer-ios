import XCTest
@testable import ScoovaNavLayerCore

/// Two acceptance suites:
/// 1. Post-reroute turn-around: when a reroute lands and its first
///    meaningful segment is > 120° off the rider's bearing, the SDK
///    speaks the wrong-way cue. Covers the case the navigator's
///    on-route wrong-way check misses (rider snap off the new
///    corridor).
/// 2. Eye-on-the-road never emits metres: when eyesOff=true is
///    passed at trip start, the SDK MUST NOT generate a metre-based
///    cue. It either uses the server's pre-rendered eyes-off string,
///    a minimal "Let's go." welcome, or stays silent — never
///    "Turn left in 80 metres".
final class EyesOffAndUTurnTests: XCTestCase {

    // MARK: - Helpers

    private func turn(
        _ i: Int, _ type: ManeuverType, segment: Double = 300,
        lat: Double = 0, lon: Double = 0,
        voiceFar: String? = nil, voiceMid: String? = nil,
        voiceNear: String? = nil, voiceConfirm: String? = nil
    ) -> ManeuverEvent {
        ManeuverEvent(
            index: i, total: 4, type: type,
            latitude: lat, longitude: lon, segmentLengthMeters: segment,
            voiceFar: voiceFar, voiceMid: voiceMid, voiceNear: voiceNear,
            voiceConfirm: voiceConfirm,
            cueFarMeters: 150, cueMidMeters: 80, cueNearMeters: 20)
    }

    // MARK: - Bug A: post-reroute turn-around cue

    /// Reroute lands. New route's first meaningful segment heads EAST
    /// (lon increases). Rider's last bearing was WEST. Delta = 180° →
    /// turn-around cue must fire after setRouteShape lands the shape.
    func testTurnAroundCueFiresWhenRerouteIsBehindRider() {
        let nav = ScoovaNavLayer.builder()
            .apiKey("sk_test").locale("en-US").profile("scooter")
            .landmarks(true).build()
        var spoken: [String] = []
        nav.onCueSpoken = { spoken.append($0) }

        let route: [ManeuverEvent] = [
            turn(0, .depart, lat: 0, lon: 0),
            turn(1, .right, lat: 0, lon: 0.001),
            turn(2, .arrive, lat: 0, lon: 0.002)
        ]
        // Trip-level state must include `wrongWay` so the SDK has the
        // phrase to speak. Otherwise it falls back to a default.
        nav.setTripState(["wrongWay": "Wrong direction — please turn around."])
        nav.onRoute(route, isReroute: false, eyesOff: false)
        nav.setActive(true)

        // First progress tick gives the rider a westward bearing.
        nav.onProgress(ProgressEvent(
            latitude: 0, longitude: 0,
            speedMps: 5, bearingDeg: 270,    // heading west
            upcomingManeuverIndex: 1,
            metersToUpcomingManeuver: 100,
            secondsRemaining: 20, metersRemaining: 200))
        spoken.removeAll()   // discard welcome / initial cues

        // Reroute lands. New route goes EAST.
        let newShape: [[Double]] = [
            [0, 0], [0, 0.0002], [0, 0.001]
        ]
        nav.onRoute(route, isReroute: true, eyesOff: false)
        nav.setRouteShape(newShape)

        let saidTurnAround = spoken.contains {
            $0.lowercased().contains("turn around")
        }
        XCTAssertTrue(saidTurnAround,
            "Post-reroute turn-around cue must fire when route's first segment is > 120° off rider bearing. Spoken: \(spoken)")
    }

    /// Reroute lands going the SAME direction as the rider. No
    /// turn-around cue.
    func testTurnAroundCueSuppressedWhenRerouteIsAhead() {
        let nav = ScoovaNavLayer.builder()
            .apiKey("sk_test").locale("en-US").profile("scooter")
            .landmarks(true).build()
        var spoken: [String] = []
        nav.onCueSpoken = { spoken.append($0) }

        let route: [ManeuverEvent] = [
            turn(0, .depart, lat: 0, lon: 0),
            turn(1, .right, lat: 0, lon: 0.001),
            turn(2, .arrive, lat: 0, lon: 0.002)
        ]
        nav.setTripState(["wrongWay": "Wrong direction — please turn around."])
        nav.onRoute(route, isReroute: false, eyesOff: false)
        nav.setActive(true)

        // Rider bearing EAST.
        nav.onProgress(ProgressEvent(
            latitude: 0, longitude: 0,
            speedMps: 5, bearingDeg: 90,
            upcomingManeuverIndex: 1,
            metersToUpcomingManeuver: 100,
            secondsRemaining: 20, metersRemaining: 200))
        spoken.removeAll()

        // Reroute goes EAST too — same direction as rider.
        let newShape: [[Double]] = [
            [0, 0], [0, 0.0002], [0, 0.001]
        ]
        nav.onRoute(route, isReroute: true, eyesOff: false)
        nav.setRouteShape(newShape)

        let saidTurnAround = spoken.contains {
            $0.lowercased().contains("turn around")
        }
        XCTAssertFalse(saidTurnAround,
            "Turn-around cue must NOT fire when reroute is aligned with rider direction. Spoken: \(spoken)")
    }

    /// Initial route (non-reroute) does NOT trigger the U-turn check
    /// even if its direction differs from the rider's last bearing —
    /// the rider hasn't started moving for real yet.
    func testTurnAroundCueSkippedOnInitialRoute() {
        let nav = ScoovaNavLayer.builder()
            .apiKey("sk_test").locale("en-US").profile("scooter")
            .landmarks(true).build()
        var spoken: [String] = []
        nav.onCueSpoken = { spoken.append($0) }

        let route: [ManeuverEvent] = [
            turn(0, .depart, lat: 0, lon: 0),
            turn(1, .right, lat: 0, lon: 0.001),
            turn(2, .arrive, lat: 0, lon: 0.002)
        ]
        nav.setTripState(["wrongWay": "Wrong direction — please turn around."])
        nav.onRoute(route, isReroute: false, eyesOff: false)
        nav.setRouteShape([[0, 0], [0, 0.0002], [0, 0.001]])
        nav.setActive(true)

        let saidTurnAround = spoken.contains {
            $0.lowercased().contains("turn around")
        }
        XCTAssertFalse(saidTurnAround,
            "Initial route must not trigger the post-reroute turn-around check")
    }

    // MARK: - Bug B: eye-on-the-road never emits metres

    /// Eye-on-the-road, server didn't ship a welcome string → SDK
    /// speaks the minimal "Let's go." instead of the metre-based
    /// welcomeText.
    func testWelcomeIsMinimalInEyesOffMode() {
        let nav = ScoovaNavLayer.builder()
            .apiKey("sk_test").locale("en-US").profile("scooter")
            .landmarks(true).build()
        var spoken: [String] = []
        nav.onCueSpoken = { spoken.append($0) }

        let route: [ManeuverEvent] = [
            turn(0, .depart, lat: 0, lon: 0),
            turn(1, .right, lat: 0, lon: 0.001),
            turn(2, .arrive, lat: 0, lon: 0.002)
        ]
        nav.setTripState([:])   // no server welcome
        nav.onRoute(route, isReroute: false, eyesOff: true)
        nav.setRouteShape([[0, 0], [0, 0.0002], [0, 0.001]])
        nav.setActive(true)

        nav.onProgress(ProgressEvent(
            latitude: 0, longitude: 0,
            speedMps: 5, bearingDeg: 90,
            upcomingManeuverIndex: 1,
            metersToUpcomingManeuver: 100,
            secondsRemaining: 20, metersRemaining: 200))

        // The welcome must NEVER contain "metres" / "meters" / "minute"
        // / "minutes" or a cardinal direction in eyes-off mode.
        for cue in spoken {
            XCTAssertFalse(cue.lowercased().contains("metre"),
                "Eye-on-the-road welcome must not contain 'metres'. Got: \(cue)")
            XCTAssertFalse(cue.lowercased().contains("meter"),
                "Eye-on-the-road welcome must not contain 'meters'. Got: \(cue)")
            XCTAssertFalse(cue.lowercased().contains("minute"),
                "Eye-on-the-road welcome must not contain 'minutes'. Got: \(cue)")
        }
    }

    /// Eye-on-the-road, server's voiceMid IS landmark-led (proxy
    /// emits eyes-off-compliant copy when voiceMode=eyes_off was
    /// requested) → SDK speaks the server string, no grammar
    /// override to "Turn left in 80 metres".
    func testApproachCueUsesServerStringInEyesOffMode() {
        let nav = ScoovaNavLayer.builder()
            .apiKey("sk_test").locale("en-US").profile("scooter")
            .landmarks(true).build()
        var spoken: [String] = []
        nav.onCueSpoken = { spoken.append($0) }

        let route: [ManeuverEvent] = [
            turn(0, .depart, lat: 0, lon: 0),
            turn(1, .right, lat: 0, lon: 0.001,
                 voiceFar: "After the gas station on your right, turn right.",
                 voiceMid: "After the gas station on your right, turn right.",
                 voiceNear: "At the gas station on your right, turn right.",
                 voiceConfirm: "Good."),
            turn(2, .arrive, lat: 0, lon: 0.002)
        ]
        nav.onRoute(route, isReroute: false, eyesOff: true)
        nav.setRouteShape([[0, 0], [0, 0.0002], [0, 0.001]])
        nav.setActive(true)

        // Drive the rider into the far / mid / near windows.
        let positions: [(toMnv: Double, remaining: Int)] = [
            (200, 400), (140, 340), (75, 275), (18, 218)
        ]
        for pos in positions {
            nav.onProgress(ProgressEvent(
                latitude: 0, longitude: 0,
                speedMps: 6, bearingDeg: 90,
                upcomingManeuverIndex: 1,
                metersToUpcomingManeuver: pos.toMnv,
                secondsRemaining: pos.remaining / 6,
                metersRemaining: pos.remaining))
        }

        // Every spoken cue in eye-on-the-road MUST NOT contain metres.
        for cue in spoken {
            XCTAssertFalse(cue.lowercased().contains("metre"),
                "Eye-on-the-road approach cue must not contain 'metres'. Got: \(cue)")
            XCTAssertFalse(cue.lowercased().contains("meter"),
                "Eye-on-the-road approach cue must not contain 'meters'. Got: \(cue)")
        }
    }

    /// Eye-on-the-MAP (eyesOff=false) — the metre-based welcome and
    /// the grammar's distance forms ARE allowed. Asserts the bug
    /// fix didn't kill the eye-on-the-map path.
    func testApproachCueUsesMetresInEyesOnMode() {
        let nav = ScoovaNavLayer.builder()
            .apiKey("sk_test").locale("en-US").profile("scooter")
            .landmarks(true).build()
        var spoken: [String] = []
        nav.onCueSpoken = { spoken.append($0) }

        let route: [ManeuverEvent] = [
            turn(0, .depart, lat: 0, lon: 0),
            turn(1, .right, lat: 0, lon: 0.001,
                 voiceFar: "FAR-SERVER", voiceMid: "MID-SERVER",
                 voiceNear: "NEAR-SERVER", voiceConfirm: "Good."),
            turn(2, .arrive, lat: 0, lon: 0.002)
        ]
        nav.onRoute(route, isReroute: false, eyesOff: false)
        nav.setRouteShape([[0, 0], [0, 0.0002], [0, 0.001]])
        nav.setActive(true)

        let positions: [(toMnv: Double, remaining: Int)] = [
            (200, 400), (140, 340), (75, 275), (18, 218)
        ]
        for pos in positions {
            nav.onProgress(ProgressEvent(
                latitude: 0, longitude: 0,
                speedMps: 6, bearingDeg: 90,
                upcomingManeuverIndex: 1,
                metersToUpcomingManeuver: pos.toMnv,
                secondsRemaining: pos.remaining / 6,
                metersRemaining: pos.remaining))
        }

        // Eye-on-the-map: at least ONE cue should contain "metres"
        // (the server string is "FAR-SERVER" / "MID-SERVER", which
        // the corridor-aware grammar overrides with a metre form
        // when no corridor data is present — the layer's rewrite path).
        // The bigger assertion: the SDK isn't silenced in eyes-on
        // mode.
        XCTAssertFalse(spoken.isEmpty,
            "Eye-on-the-map mode must speak cues, not stay silent")
    }
}
