import XCTest
@testable import ScoovaNavLayerCore

/// Regression tests for the voice ↔ banner distance mismatch the user
/// caught:
///
/// > "It said in 300 meters when the actual distance on the banner
/// > maybe 70 m, and sometimes less."
///
/// The server bakes a static lead distance into the FAR / MID cue text.
/// The SDK fires those cues by TIME (30 s / 15 s out) which, at the
/// rider's actual pace, lands at a very different live distance —
/// pedestrian 30 s × 1.5 m/s = 45 m, not 300 m. The rewrite pass
/// replaces the embedded number with the live one so what the rider
/// HEARS matches what the rider SEES.
final class LiveDistanceRewriteTests: XCTestCase {

    // ── English ─────────────────────────────────────────────────────────

    func testEnglishReplacesEmbeddedDistance() {
        let phrase = "In 300 meters after Starbucks, turn right onto 8th Avenue."
        let out = rewriteEmbeddedDistance(phrase, lang: "en-US", liveMeters: 70)
        // 70 m → "50 meters" via the spokenDistance rounding bucket.
        XCTAssertTrue(
            out.contains("50 meters") || out.contains("70 meters"),
            "Expected the new live distance to appear; got: \(out)"
        )
        XCTAssertFalse(
            out.contains("300 meters"),
            "The stale '300 meters' must not survive the rewrite; got: \(out)"
        )
        XCTAssertTrue(
            out.contains("after Starbucks"),
            "Landmark anchor must be preserved; got: \(out)"
        )
        XCTAssertTrue(
            out.hasSuffix("turn right onto 8th Avenue."),
            "Direction + destination clause must be preserved; got: \(out)"
        )
    }

    func testEnglishWithoutDistancePassesThrough() {
        // Eyes-off cues have no number — must be returned untouched.
        let phrase = "Coming up, you'll turn right."
        XCTAssertEqual(
            rewriteEmbeddedDistance(phrase, lang: "en", liveMeters: 80),
            phrase,
            "Eyes-off cues with no embedded distance must pass through unchanged"
        )
    }

    func testEnglishMidCueReplacesDistance() {
        let phrase = "In 150 meters, get ready to turn right."
        let out = rewriteEmbeddedDistance(phrase, lang: "en", liveMeters: 45)
        XCTAssertFalse(out.contains("150 meters"))
        XCTAssertTrue(out.contains("get ready to turn right."))
    }

    // ── Localised patterns ──────────────────────────────────────────────

    func testFrenchReplacesEmbeddedDistance() {
        let out = rewriteEmbeddedDistance(
            "Dans 300 mètres, après Starbucks, tournez à droite.",
            lang: "fr", liveMeters: 70)
        XCTAssertFalse(out.contains("300 mètres"),
            "French baked distance must be replaced; got: \(out)")
        XCTAssertTrue(out.contains("après Starbucks"))
    }

    func testGermanReplacesEmbeddedDistance() {
        let out = rewriteEmbeddedDistance(
            "In 300 Metern nach Starbucks rechts abbiegen.",
            lang: "de", liveMeters: 70)
        XCTAssertFalse(out.contains("300 Metern"))
    }

    func testArabicReplacesEmbeddedDistance() {
        let out = rewriteEmbeddedDistance(
            "في 300 متر بعد ستاربكس، حوّد يمين.",
            lang: "ar-EG", liveMeters: 70)
        XCTAssertFalse(out.contains("300"),
            "Arabic baked distance must be replaced; got: \(out)")
    }

    // ── Edge cases ──────────────────────────────────────────────────────

    func testZeroOrNegativeLiveMetersIsNoop() {
        let phrase = "In 300 meters, turn right."
        XCTAssertEqual(
            rewriteEmbeddedDistance(phrase, lang: "en", liveMeters: 0),
            phrase, "liveMeters=0 must not rewrite (likely an arrival)")
    }

    func testKmDistanceRewriteEnglish() {
        // Long lead distance — the cue might say "In 1.2 kilometers".
        let phrase = "In 1.2 kilometers, turn right onto Main Street."
        let out = rewriteEmbeddedDistance(phrase, lang: "en", liveMeters: 350)
        XCTAssertFalse(out.contains("1.2 kilometers"))
        XCTAssertTrue(out.contains("turn right onto Main Street."))
    }
}
