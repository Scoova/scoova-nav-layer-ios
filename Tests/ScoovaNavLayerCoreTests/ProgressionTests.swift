import XCTest
@testable import ScoovaNavLayerCore

/// Tests for `ProgressTracker` (the per-maneuver cue cursor) and
/// `Thresholds` (the per-profile cue lead-distances).
final class ProgressionTests: XCTestCase {

    // MARK: - ProgressTracker

    func testNormalApproachFiresEachBandOnce() {
        let t = ProgressTracker(thresholdsMeters: [15, 50, 150])
        var fired: [Int] = []
        for d in stride(from: 200.0, through: 0, by: -10) {
            let s = t.update(maneuverIndex: 0, metersToManeuver: d)
            if s.firedThresholdM > 0 { fired.append(s.firedThresholdM) }
        }
        XCTAssertEqual(fired, [150, 50, 15], "far → mid → near, each once")
    }

    func testBandFiresAtMostOnce() {
        let t = ProgressTracker(thresholdsMeters: [15, 50, 150])
        _ = t.update(maneuverIndex: 0, metersToManeuver: 140)   // fires 150
        let again = t.update(maneuverIndex: 0, metersToManeuver: 120)
        XCTAssertEqual(again.firedThresholdM, -1, "150 band already fired")
    }

    func testManeuverAppearingCloseFiresItsBandNotOuterOnes() {
        // Comes into view at 40 m — fires the 50 band, and never
        // belatedly fires the 150 band it never legitimately entered.
        let t = ProgressTracker(thresholdsMeters: [15, 50, 150])
        XCTAssertEqual(t.update(maneuverIndex: 0, metersToManeuver: 40)
            .firedThresholdM, 50)
        XCTAssertEqual(t.update(maneuverIndex: 0, metersToManeuver: 30)
            .firedThresholdM, -1, "the skipped 150 band must not fire late")
        XCTAssertEqual(t.update(maneuverIndex: 0, metersToManeuver: 10)
            .firedThresholdM, 15)
    }

    func testStaticReadingDoesNotRefire() {
        let t = ProgressTracker(thresholdsMeters: [15, 50, 150])
        _ = t.update(maneuverIndex: 0, metersToManeuver: 45)    // fires 50
        for _ in 0..<5 {
            XCTAssertEqual(t.update(maneuverIndex: 0, metersToManeuver: 45)
                .firedThresholdM, -1)
        }
    }

    func testEachManeuverTracksIndependently() {
        let t = ProgressTracker(thresholdsMeters: [15, 50, 150])
        XCTAssertEqual(t.update(maneuverIndex: 0, metersToManeuver: 40)
            .firedThresholdM, 50)
        XCTAssertEqual(t.update(maneuverIndex: 1, metersToManeuver: 40)
            .firedThresholdM, 50, "maneuver 1 fires on its own clock")
    }

    func testBeyondAllThresholdsFiresNothing() {
        let t = ProgressTracker(thresholdsMeters: [15, 50, 150])
        XCTAssertEqual(t.update(maneuverIndex: 0, metersToManeuver: 800)
            .firedThresholdM, -1)
    }

    // MARK: - Thresholds

    func testCueOffsetsScaleWithSpeed() {
        // A walker needs a short heads-up; a driver needs a long one.
        let foot = Thresholds.cueOffsets(for: "pedestrian")
        let car = Thresholds.cueOffsets(for: "auto")
        XCTAssertEqual(foot.far, 70)
        XCTAssertEqual(foot.near, 14)
        XCTAssertGreaterThan(car.far, foot.far)
        XCTAssertGreaterThan(car.mid, foot.mid)
        XCTAssertGreaterThan(car.near, foot.near)
    }

    func testCueOffsetsAreOrderedFarMidNear() {
        for profile in ["pedestrian", "bicycle", "scooter", "auto"] {
            let o = Thresholds.cueOffsets(for: profile)
            XCTAssertGreaterThan(o.far, o.mid, "\(profile): far > mid")
            XCTAssertGreaterThan(o.mid, o.near, "\(profile): mid > near")
        }
    }

    func testCueOffsetsUnknownProfileFallsBack() {
        let unknown = Thresholds.cueOffsets(for: "hovercraft")
        XCTAssertGreaterThan(unknown.far, 0, "unknown profile still usable")
    }
}
