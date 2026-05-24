import XCTest
import ScoovaNavLayerCore
@testable import ScoovaNavLayerScoovaRouting

/// Tests for `ScoovaRoutingAdapter.decodeRoute` — the pure JSON →
/// `ManeuverEvent` path. Guards the "a server field is silently not
/// decoded" bug class: the `far` / `mid` / `near` eyes-off cues were
/// lost exactly that way once, and only a curl caught it.
final class RouteDecodeTests: XCTestCase {

    /// A realistic routing-API response — mirrors the live server's
    /// shape: a depart, a fully-enriched left turn, and an arrive.
    private let fixture = """
    {
      "trip": {
        "legs": [{
          "shape": "",
          "maneuvers": [
            {
              "type": 1, "instruction": "Drive southwest.",
              "length": 0.4, "begin_shape_index": 0,
              "scoova": {
                "kind": "depart",
                "banner": {"verb": "Let's go", "kind": "depart"},
                "voice": {"headsUp": "Let's go.", "turnNow": "Let's go."}
              }
            },
            {
              "type": 15, "instruction": "Turn left onto West 40th Street.",
              "verbal_succinct_transition_instruction": "Turn left at McDonald's.",
              "length": 0.4, "begin_shape_index": 5,
              "scoova": {
                "kind": "left", "landmark": "McDonald's",
                "banner": {"verb": "Turn left", "anchor": "after McDonald's", "kind": "left"},
                "voice": {
                  "headsUp": "Left turn coming up at the next street",
                  "turnNow": "Turn left",
                  "atLandmark": "Turn left after McDonald's",
                  "getReadyTemplate": "Turn left in {secs} seconds",
                  "atDistanceTemplate": "In {meters} meters, turn left",
                  "far": "After McDonald's, turn left.",
                  "mid": "Right after McDonald's, turn left.",
                  "near": "At McDonald's, turn left.",
                  "chained": "At McDonald's, turn left. Then quickly turn right again.",
                  "confirm": "Good.",
                  "recover": "Looks like you missed the turn, recalculating.",
                  "reaffirm": "Still on West 40th Street. Then turn left.",
                  "checkpoint": "You're passing the museum on your right.",
                  "checkpointOffsetMeters": 200,
                  "farMeters": 114, "midMeters": 57, "nearMeters": 19
                }
              }
            },
            {
              "type": 4, "instruction": "You have arrived.",
              "length": 0.0, "begin_shape_index": 9,
              "scoova": {
                "kind": "arrive",
                "banner": {"verb": "You've arrived", "kind": "arrive"},
                "voice": {"turnNow": "You've arrived"}
              }
            }
          ]
        }],
        "summary": {"time": 360.0, "length": 0.8},
        "scoova": {
          "lang": "en", "dir": "ltr",
          "state": {"welcome": "Let's go", "rerouting": "Finding a new route"},
          "welcomeFull": "Let's go. Heading south.",
          "arrivedFull": "You've arrived at your destination on your right."
        }
      }
    }
    """

    private let origin = LatLon(lat: 40.758, lon: -73.9855)

    private func decode(_ json: String) throws -> ScoovaRoutingAdapter.DecodedRoute {
        try ScoovaRoutingAdapter.decodeRoute(from: Data(json.utf8), fallback: origin)
    }

    func testDecodesAllManeuversWithTypes() throws {
        let route = try decode(fixture)
        XCTAssertEqual(route.maneuvers.count, 3)
        XCTAssertEqual(route.maneuvers[0].type, .depart)
        XCTAssertEqual(route.maneuvers[1].type, .left)
        XCTAssertEqual(route.maneuvers[2].type, .arrive)
    }

    func testDecodesEyesOffLandmarkCues() throws {
        // The bug this guards: `far`/`mid`/`near` (+ their meter
        // offsets) silently undecoded → generic cues, no landmarks.
        let turn = try decode(fixture).maneuvers[1]
        XCTAssertEqual(turn.voiceFar, "After McDonald's, turn left.")
        XCTAssertEqual(turn.voiceMid, "Right after McDonald's, turn left.")
        XCTAssertEqual(turn.voiceNear, "At McDonald's, turn left.")
        XCTAssertEqual(turn.voiceChained,
                       "At McDonald's, turn left. Then quickly turn right again.")
        XCTAssertEqual(turn.voiceConfirm, "Good.")
        XCTAssertEqual(turn.cueFarMeters, 114)
        XCTAssertEqual(turn.cueMidMeters, 57)
        XCTAssertEqual(turn.cueNearMeters, 19)
    }

    func testDecodesRecoverReaffirmCheckpointCues() throws {
        // The reactive eyes-off cues — recover (off-route), reaffirm
        // (mid-segment) and checkpoint (+ its offset). Same "field
        // silently undecoded" bug class as the far/mid/near guard above.
        let turn = try decode(fixture).maneuvers[1]
        XCTAssertEqual(turn.voiceRecover,
                       "Looks like you missed the turn, recalculating.")
        XCTAssertEqual(turn.voiceReaffirm,
                       "Still on West 40th Street. Then turn left.")
        XCTAssertEqual(turn.voiceCheckpoint,
                       "You're passing the museum on your right.")
        XCTAssertEqual(turn.checkpointOffsetMeters, 200)
    }

    func testDecodesBannerAndLandmark() throws {
        let turn = try decode(fixture).maneuvers[1]
        XCTAssertEqual(turn.bannerVerb, "Turn left")
        XCTAssertEqual(turn.bannerAnchor, "after McDonald's")
        XCTAssertEqual(turn.landmark, "McDonald's")
        XCTAssertEqual(turn.voiceTurnNow, "Turn left")
    }

    func testRawInstructionPrefersVerbalSuccinct() throws {
        let turn = try decode(fixture).maneuvers[1]
        XCTAssertEqual(turn.rawInstruction, "Turn left at McDonald's.")
    }

    func testDecodesTripSummaryAndScoova() throws {
        let route = try decode(fixture)
        XCTAssertEqual(route.totalSeconds, 360, accuracy: 0.001)
        XCTAssertEqual(route.totalMeters, 800, accuracy: 0.01)     // 0.8 km → m
        XCTAssertEqual(route.tripScoova?.welcomeFull, "Let's go. Heading south.")
        XCTAssertEqual(route.tripScoova?.state?["rerouting"], "Finding a new route")
    }

    func testSegmentLengthConvertedToMeters() throws {
        let turn = try decode(fixture).maneuvers[1]
        XCTAssertEqual(turn.segmentLengthMeters, 400, accuracy: 0.01)  // 0.4 km
    }

    func testDecodesResponseWithNoScoovaBlock() throws {
        // A legacy / third-party response with no `scoova` must still
        // decode — the eyes-off fields are simply nil.
        let bare = """
        {"trip": {"legs": [{"shape": "", "maneuvers": [
          {"type": 1, "instruction": "Head north.", "length": 0.2, "begin_shape_index": 0}
        ]}], "summary": {"time": 60.0, "length": 0.2}}}
        """
        let route = try decode(bare)
        XCTAssertEqual(route.maneuvers.count, 1)
        XCTAssertEqual(route.maneuvers[0].rawInstruction, "Head north.")
        XCTAssertNil(route.maneuvers[0].voiceFar)
        XCTAssertNil(route.tripScoova)
    }

    func testGarbageJSONThrows() {
        XCTAssertThrowsError(try decode("not json"))
    }
}
