import XCTest
@testable import ScoovaNavLayerCore

final class ScoovaNavLayerCoreTests: XCTestCase {

    func testThresholdsBicycle() {
        let t = Thresholds.forProfile("bicycle")
        XCTAssertEqual(t, [15, 50, 100, 200])
    }

    func testThresholdsUnknownFallsBackToAuto() {
        let t = Thresholds.forProfile("UNKNOWN")
        XCTAssertEqual(t, [50, 200, 400, 800])
    }

    func testProgressTrackerFiresOnceOnCrossing() {
        let tracker = ProgressTracker(thresholdsMeters: [50, 200])
        _ = tracker.update(maneuverIndex: 0, metersToManeuver: 300)
        _ = tracker.update(maneuverIndex: 0, metersToManeuver: 280)
        let mid = tracker.update(maneuverIndex: 0, metersToManeuver: 180)
        XCTAssertEqual(mid.firedThresholdM, 200)
        let again = tracker.update(maneuverIndex: 0, metersToManeuver: 160)
        XCTAssertEqual(again.firedThresholdM, -1, "Should not re-fire the same threshold")
        let near = tracker.update(maneuverIndex: 0, metersToManeuver: 40)
        XCTAssertEqual(near.firedThresholdM, 50)
    }

    func testProgressTrackerFiresWhenManeuverAppearsClose() {
        // A maneuver that comes into view already close — right after the
        // previous turn, or off the start line — must still get a cue:
        // the band it lands in, not silence. (This was the "tracker
        // never fires for close maneuvers" bug; the band model fixes it.)
        let tracker = ProgressTracker(thresholdsMeters: [50, 200])
        let snap = tracker.update(maneuverIndex: 0, metersToManeuver: 40)
        XCTAssertEqual(snap.firedThresholdM, 50,
                       "Appearing inside the 50 m band should fire 50.")
    }

    func testCuePhraseEnglishLeftMid() {
        let m = ManeuverEvent(
            index: 0, total: 1, type: .left,
            rawInstruction: "Turn left",
            latitude: 0, longitude: 0,
            segmentLengthMeters: 100
        )
        let s = CuePhrases.build(
            lang: "en-US", maneuver: m,
            firedThresholdM: 100,
            thresholdsMeters: [50, 100, 200, 400]
        )
        XCTAssertTrue(s.lowercased().contains("turn left"))
    }

    func testCuePhraseArabicEgyptianLeftMid() {
        let m = ManeuverEvent(
            index: 0, total: 1, type: .left,
            rawInstruction: nil,
            latitude: 0, longitude: 0,
            segmentLengthMeters: 100
        )
        let s = CuePhrases.build(
            lang: "ar-EG", maneuver: m,
            firedThresholdM: 100,
            thresholdsMeters: [50, 100, 200, 400]
        )
        XCTAssertTrue(s.contains("شمال"))
    }

    func testManeuverTypeLeftRightFlags() {
        XCTAssertTrue(ManeuverType.left.isLeftSide)
        XCTAssertTrue(ManeuverType.sharpRight.isRightSide)
        XCTAssertFalse(ManeuverType.left.isRightSide)
        XCTAssertTrue(ManeuverType.uturn.isUturn)
        XCTAssertTrue(ManeuverType.roundaboutEnter.isRoundabout)
    }

    func testGeoMathHaversine() {
        // Cairo → Giza: ~13 km
        let d = GeoMath.haversineMeters(30.0444, 31.2357, 30.0131, 31.2089)
        XCTAssertGreaterThan(d, 3_000)
        XCTAssertLessThan(d, 5_000)
    }
}
