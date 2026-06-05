import XCTest
@testable import ScoovaNavLayerCore

/// `stripLeadingGoodPrefix` removes the "Good. " affirmation from
/// the server's almostThere phrase when the rider hasn't actually
/// executed the previous turn. Live-observed 2026-05-29 06:24:13:
/// SDK said "Good. Almost there." while the rider was still going
/// the wrong direction. The "Good" claim should only be made when
/// the rider has actually executed the turn.
final class GoodPrefixStripTests: XCTestCase {

    func testStripsLeadingGoodPeriodSpace() {
        XCTAssertEqual(
            ScoovaNavLayer.stripLeadingGoodPrefix("Good. Almost there."),
            "Almost there.")
    }

    func testStripsLeadingGoodCommaSpace() {
        XCTAssertEqual(
            ScoovaNavLayer.stripLeadingGoodPrefix("Good, you're nearly there."),
            "You're nearly there.")
    }

    func testStripsLeadingGoodSpace() {
        XCTAssertEqual(
            ScoovaNavLayer.stripLeadingGoodPrefix("Good you've nearly arrived."),
            "You've nearly arrived.")
    }

    func testNoStripWhenNoGoodPrefix() {
        XCTAssertEqual(
            ScoovaNavLayer.stripLeadingGoodPrefix("Almost there."),
            "Almost there.")
        XCTAssertEqual(
            ScoovaNavLayer.stripLeadingGoodPrefix("You're nearly there."),
            "You're nearly there.")
    }

    func testHandlesEmptyAfterStrip() {
        XCTAssertEqual(
            ScoovaNavLayer.stripLeadingGoodPrefix("Good. "),
            "")
    }

    func testCaseInsensitiveDetectionPreservesOriginalCase() {
        // "good. " also matches (server might lowercase)
        XCTAssertEqual(
            ScoovaNavLayer.stripLeadingGoodPrefix("good. almost there."),
            "Almost there.")
    }

    func testDoesNotStripGoodInsideSentence() {
        // "Good" appearing later must NOT be stripped.
        XCTAssertEqual(
            ScoovaNavLayer.stripLeadingGoodPrefix("Looks good. Keep going."),
            "Looks good. Keep going.")
    }
}
