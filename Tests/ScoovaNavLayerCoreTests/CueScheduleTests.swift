import XCTest
@testable import ScoovaNavLayerCore

/// Tests for the navigation "subtitle" cue track. `buildCueSchedule`
/// lays out, per maneuver, the cues to speak and the distance-before-
/// the-turn each one fires at — far / mid / near, plus the post-turn
/// confirm and the keep-going reassurance.
final class CueScheduleTests: XCTestCase {

    private let panZero: (ManeuverType) -> Float = { _ in 0 }
    private let defaults = (far: 500.0, mid: 250.0, near: 90.0)

    /// Minimal maneuver builder — only the fields these tests care about.
    private func maneuver(
        _ index: Int,
        _ type: ManeuverType,
        segment: Double,
        far: String? = nil, mid: String? = nil, near: String? = nil,
        chained: String? = nil,
        confirm: String? = nil,
        reaffirm: String? = nil,
        checkpoint: String? = nil, checkpointOffset: Int? = nil,
        cueFar: Int? = nil, cueMid: Int? = nil, cueNear: Int? = nil
    ) -> ManeuverEvent {
        ManeuverEvent(
            index: index, total: 0, type: type,
            latitude: 0, longitude: 0, segmentLengthMeters: segment,
            voiceFar: far, voiceMid: mid, voiceNear: near,
            voiceChained: chained, voiceConfirm: confirm,
            voiceReaffirm: reaffirm,
            voiceCheckpoint: checkpoint, checkpointOffsetMeters: checkpointOffset,
            cueFarMeters: cueFar, cueMidMeters: cueMid, cueNearMeters: cueNear
        )
    }

    func testFarMidNearUseServerLeadDistances() {
        let route = [
            // 400 m approach — long enough to carry far + mid cues.
            maneuver(0, .depart, segment: 400),
            maneuver(1, .right, segment: 300,
                     far: "FAR", mid: "MID", near: "NEAR",
                     cueFar: 114, cueMid: 57, cueNear: 19),
            maneuver(2, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: nil, pan: panZero)

        guard let cues = schedule[1] else {
            return XCTFail("the turn at index 1 should have a cue track")
        }
        XCTAssertEqual(cues.count, 3)
        // Ordered far → near, pinned to the server's own lead distances.
        XCTAssertEqual(cues.map(\.triggerMeters), [114, 57, 19])
        XCTAssertEqual(cues.map(\.phrase), ["FAR", "MID", "NEAR"])
        XCTAssertEqual(cues.last?.tone, .urgent, "the near cue is urgent")
    }

    func testDepartAndArriveGetNoCueTrack() {
        let route = [
            maneuver(0, .depart, segment: 100),
            maneuver(1, .left, segment: 200, near: "x"),
            maneuver(2, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: nil, pan: panZero)
        XCTAssertNil(schedule[0], "depart is covered by the welcome line")
        XCTAssertNil(schedule[2], "arrive is covered by the arrival line")
        XCTAssertNotNil(schedule[1])
    }

    func testFallbackOffsetsWhenServerSendsNone() {
        // No cueFar/Mid/Near on the maneuver → the per-profile defaults.
        let route = [
            // 700 m approach — room for the default far (500) heads-up.
            maneuver(0, .depart, segment: 700),
            maneuver(1, .right, segment: 300, far: "f", mid: "m", near: "n"),
            maneuver(2, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: nil, pan: panZero)
        XCTAssertEqual(schedule[1]?.map(\.triggerMeters), [500, 250, 90])
    }

    func testCloseCuesAreSpacedApart() {
        // Two cue points within the 16 m min-gap → the wider (less
        // urgent) one is dropped so two cues never tread on each other.
        let near = ScoovaNavLayer.CuePoint(
            triggerMeters: 18, phrase: "near", tone: .urgent, pan: 0)
        let mid = ScoovaNavLayer.CuePoint(
            triggerMeters: 24, phrase: "mid", tone: .normal, pan: 0)
        let far = ScoovaNavLayer.CuePoint(
            triggerMeters: 200, phrase: "far", tone: .normal, pan: 0)
        let spaced = ScoovaNavLayer.spaceCues([far, mid, near])
        XCTAssertEqual(spaced.map(\.phrase), ["far", "near"],
                       "the mid cue, 6 m behind near, is dropped")
    }

    func testConfirmCueOpensTheNextTurnsTrack() {
        // Index ≥ 2: the previous turn's `confirm` is spoken just after
        // it lands, provided the segment is long enough to fit it.
        let route = [
            maneuver(0, .depart, segment: 100),
            maneuver(1, .right, segment: 300, near: "turn1", confirm: "Good."),
            maneuver(2, .left, segment: 200, near: "turn2"),
            maneuver(3, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: nil, pan: panZero)
        let phrases = schedule[2]?.map(\.phrase) ?? []
        XCTAssertTrue(phrases.contains("Good."),
                      "turn 2's track should open with turn 1's confirm")
    }

    func testTwoCloseTurnsStayTwoSeparateCues() {
        // Two turns close together must NOT be bundled into one cue. m1
        // speaks only m1's turn, m2 speaks only m2's turn — one direction
        // per cue. The chained-turn field, even when the server sets it,
        // is never spoken (it bundled two turns into one breath).
        let route = [
            maneuver(0, .depart, segment: 600),
            maneuver(1, .right, segment: 80, near: "turn right onto A",
                     chained: "turn right onto A, then turn right onto B"),
            maneuver(2, .right, segment: 200, near: "turn right onto B"),
            maneuver(3, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: nil, pan: panZero)
        XCTAssertEqual(schedule[1]?.last?.phrase, "turn right onto A",
                       "m1 speaks only its own turn — not the chained pair")
        XCTAssertEqual(schedule[2]?.last?.phrase, "turn right onto B",
                       "m2 speaks its own turn, as a separate cue")
    }

    func testKeepGoingOnALongStretch() {
        // A long quiet stretch (segment ≫ far offset) carries a
        // "keep going" reassurance in the middle.
        let route = [
            maneuver(0, .depart, segment: 100),
            maneuver(1, .right, segment: 900, near: "t1", confirm: "ok"),
            maneuver(2, .left, segment: 200, near: "t2",
                     cueFar: 120, cueMid: 60, cueNear: 20),
            maneuver(3, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: "Keep going straight",
            pan: panZero)
        let phrases = schedule[2]?.map(\.phrase) ?? []
        XCTAssertTrue(phrases.contains("Keep going straight"),
                      "a 900 m stretch should carry a keep-going cue")
    }

    func testCheckpointCueFiresAtServerOffset() {
        // The checkpoint offset is measured from the PRIOR maneuver; the
        // cue track is keyed on distance-before-this-maneuver, so a 900 m
        // approach segment with a checkpoint 600 m in fires at
        // 900 − 600 = 300 m to go.
        let route = [
            maneuver(0, .depart, segment: 900),
            maneuver(1, .right, segment: 300, far: "f", near: "n",
                     checkpoint: "CHECKPOINT", checkpointOffset: 600,
                     cueFar: 150, cueMid: 80, cueNear: 20),
            maneuver(2, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: nil, pan: panZero)
        let cp = schedule[1]?.first { $0.phrase == "CHECKPOINT" }
        XCTAssertNotNil(cp, "the checkpoint cue should be on the track")
        XCTAssertEqual(cp?.triggerMeters, 300, "fires at segLen − offset")
    }

    func testReaffirmSpreadsAlongALongStretch() {
        // A long quiet stretch carries the reaffirm repeatedly — one
        // spoken position check roughly every 450 m — so the rider
        // isn't left with minutes of silence between turns.
        let route = [
            maneuver(0, .depart, segment: 2000),
            maneuver(1, .right, segment: 300, far: "f", near: "n",
                     reaffirm: "REAFFIRM",
                     cueFar: 120, cueMid: 60, cueNear: 20),
            maneuver(2, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: nil, pan: panZero)
        // quietZone = 2000 − 120 = 1880 m → 1880 / 450 = 4 reaffirms.
        let reaffirms = schedule[1]?.filter { $0.phrase == "REAFFIRM" } ?? []
        XCTAssertEqual(reaffirms.count, 4,
                       "a 1880 m quiet zone carries 4 spread reaffirms")
        // Still ordered far → near alongside the approach cues.
        let triggers = schedule[1]?.map(\.triggerMeters) ?? []
        XCTAssertEqual(triggers, triggers.sorted(by: >))
    }

    func testReaffirmIsPreferredOverKeepGoing() {
        // A long approach segment with a server `reaffirm` speaks it once
        // at the quiet-zone midpoint — the generic keep-going line is not
        // used. (Reaffirm names the road + next action; it's the better
        // cue, so it wins.)
        let route = [
            maneuver(0, .depart, segment: 900),
            maneuver(1, .right, segment: 300, far: "f", near: "n",
                     reaffirm: "REAFFIRM",
                     cueFar: 150, cueMid: 80, cueNear: 20),
            maneuver(2, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: "keep going", pan: panZero)
        let phrases = schedule[1]?.map(\.phrase) ?? []
        XCTAssertTrue(phrases.contains("REAFFIRM"),
                      "the server reaffirm is spoken on the quiet stretch")
        XCTAssertFalse(phrases.contains("keep going"),
                       "the generic keep-going is suppressed when reaffirm exists")
    }

    func testApproachCuesScaleWithSpeed() {
        // The far cue's trigger distance must grow with speed so the
        // lead TIME stays constant — a faster rider hears "turn" from
        // proportionally farther out.
        let route = [
            maneuver(0, .depart, segment: 600),
            maneuver(1, .right, segment: 400, far: "FAR", near: "NEAR",
                     cueFar: 200, cueMid: 100, cueNear: 30),
            maneuver(2, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: nil, pan: panZero)
        guard let far = schedule[1]?.first(where: { $0.phrase == "FAR" }) else {
            return XCTFail("far cue missing")
        }
        // far cue's target is 30 s out → distance = 30 × clamped speed.
        XCTAssertEqual(
            ScoovaNavLayer.effectiveTriggerMeters(far, speedMps: 5),
            150, accuracy: 0.1, "slow rider: 30 s × 5 m/s")
        XCTAssertEqual(
            ScoovaNavLayer.effectiveTriggerMeters(far, speedMps: 20),
            600, accuracy: 0.1, "fast rider: 30 s × 20 m/s — same 30 s out")
        XCTAssertEqual(
            ScoovaNavLayer.effectiveTriggerMeters(far, speedMps: 0),
            0, accuracy: 0.1, "stopped → trigger 0; the cue waits for the rider to move")
    }

    func testDistancePinnedCuesIgnoreSpeed() {
        // confirm / reaffirm / checkpoint are pinned to a point on the
        // road — speed must never move them.
        let cue = ScoovaNavLayer.CuePoint(
            triggerMeters: 120, phrase: "x", tone: .calm, pan: 0)
        XCTAssertEqual(
            ScoovaNavLayer.effectiveTriggerMeters(cue, speedMps: 5), 120)
        XCTAssertEqual(
            ScoovaNavLayer.effectiveTriggerMeters(cue, speedMps: 25), 120)
    }

    func testEveryTurnIsScheduledItsFullHeadsUp() {
        // Every turn gets all three approach cues scheduled, regardless
        // of how short the approach is — the heads-up is never thrown
        // away at build time. (The runtime collapses any that cross
        // together; that is its job, not the schedule builder's.)
        for approach in [600.0, 130.0, 60.0] {
            let route = [
                maneuver(0, .depart, segment: approach),
                maneuver(1, .right, segment: 300, far: "FAR", mid: "MID",
                         near: "NEAR", cueFar: 200, cueMid: 100, cueNear: 20),
                maneuver(2, .arrive, segment: 0),
            ]
            let schedule = ScoovaNavLayer.buildCueSchedule(
                route, defaults: defaults, keepGoing: nil, pan: panZero)
            XCTAssertEqual(schedule[1]?.map(\.phrase), ["FAR", "MID", "NEAR"],
                           "a \(Int(approach)) m approach still schedules all three")
        }
    }

    func testCuesCarryTheirKind() {
        // Every cue is tagged with what it is — the layer keys fire-time
        // behaviour off `kind` (a reaffirm gets the live distance-to-
        // destination appended when spoken).
        let route = [
            maneuver(0, .depart, segment: 2000),
            maneuver(1, .right, segment: 300, far: "f", mid: "m", near: "n",
                     reaffirm: "r",
                     checkpoint: "cp", checkpointOffset: 1000),
            maneuver(2, .left, segment: 200, near: "n2", confirm: "c1"),
            maneuver(3, .left, segment: 200, near: "n3"),
            maneuver(4, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: nil, pan: panZero)
        func kind(_ phrase: String, _ idx: Int) -> ScoovaNavLayer.CueKind? {
            schedule[idx]?.first { $0.phrase == phrase }?.kind
        }
        XCTAssertEqual(kind("f", 1), .approach)
        XCTAssertEqual(kind("n", 1), .approach)
        XCTAssertEqual(kind("r", 1), .reaffirm)
        XCTAssertEqual(kind("cp", 1), .checkpoint)
        // m2's confirm rides on the next turn's (m3's) track.
        XCTAssertEqual(kind("c1", 3), .confirm)
    }

    func testTrackIsOrderedFarToNear() {
        let route = [
            maneuver(0, .depart, segment: 600),
            maneuver(1, .right, segment: 900, near: "t1", confirm: "ok",
                     cueFar: 120, cueMid: 60, cueNear: 20),
            maneuver(2, .left, segment: 900, far: "f", mid: "m", near: "n",
                     cueFar: 120, cueMid: 60, cueNear: 20),
            maneuver(3, .arrive, segment: 0),
        ]
        let schedule = ScoovaNavLayer.buildCueSchedule(
            route, defaults: defaults, keepGoing: "keep", pan: panZero)
        for (_, cues) in schedule {
            let triggers = cues.map(\.triggerMeters)
            XCTAssertEqual(triggers, triggers.sorted(by: >),
                           "every track runs far → near")
        }
    }
}
