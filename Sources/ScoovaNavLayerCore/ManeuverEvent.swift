import Foundation

/// Canonical maneuver-type taxonomy. Mirrors the Android SDK's
/// `ManeuverType` enum so adapter authors can write the same mapping table
/// once and use it on both platforms. Aligned with Valhalla / OSRM.
public enum ManeuverType: String, Sendable, Codable, CaseIterable {
    case depart
    case arrive
    case `continue`
    case slightLeft
    case left
    case sharpLeft
    case slightRight
    case right
    case sharpRight
    case uturn
    case roundaboutEnter
    case roundaboutExit
    case rampLeft
    case rampRight
    case rampStraight
    case exitLeft
    case exitRight
    case stayLeft
    case stayRight
    case stayStraight
    case merge
    case becomes
    case other

    public var isLeftSide: Bool {
        switch self {
        case .slightLeft, .left, .sharpLeft, .rampLeft, .exitLeft, .stayLeft: return true
        default: return false
        }
    }

    public var isRightSide: Bool {
        switch self {
        case .slightRight, .right, .sharpRight, .rampRight, .exitRight, .stayRight: return true
        default: return false
        }
    }

    public var isUturn: Bool { self == .uturn }
    public var isRoundabout: Bool { self == .roundaboutEnter || self == .roundaboutExit }
    public var isExit: Bool {
        switch self {
        case .exitLeft, .exitRight, .rampLeft, .rampRight, .rampStraight: return true
        default: return false
        }
    }

    /// Maneuvers that aren't worth speaking when on foot.
    public var isLowValueOnFoot: Bool {
        switch self {
        case .becomes, .`continue`, .slightLeft, .slightRight, .stayStraight: return true
        default: return false
        }
    }
}

/// A single maneuver in a route. Adapters reduce their host-SDK steps to
/// this shape before pushing into `ScoovaNavLayer.onRoute`.
///
/// The server-rendered `scoova` block (banner + voice copy) is the
/// canonical source for eyes-on-the-road copy — adapters that fetch from
/// routing.scoo-va.info pass these straight through. Adapters built on
/// third-party engines (Mapbox, Apple MapKit) leave them nil and the
/// banner falls back to `rawInstruction`.
public struct ManeuverEvent: Sendable, Equatable {
    public let index: Int
    public let total: Int
    public let type: ManeuverType
    public let rawInstruction: String?
    public let latitude: Double
    public let longitude: Double
    public let segmentLengthMeters: Double
    /// Expected duration (seconds) of the segment from the previous
    /// maneuver to this one. Server-provided. Used by the cue scheduler
    /// to space reaffirm/checkpoint cues by *time* (every ~75 s of
    /// riding) instead of by distance — without it, a 1 km walk gets
    /// one reaffirm in five minutes while the same 1 km on a scooter
    /// gets one every 40 seconds. Nil ⇒ scheduler falls back to a
    /// fixed-distance heuristic.
    public let segmentDurationSeconds: Double?
    public let roundaboutExit: Int?

    // ── Server-rendered Scoova navigation copy (the scoova.* block) ──────

    /// Banner primary line — short verb. "Turn right" / "حوّد يمين".
    public let bannerVerb: String?
    /// Banner secondary line — landmark anchor. "after the gas station" / "بعد البنزينة". Nil if none.
    public let bannerAnchor: String?
    /// Long-lead voice cue (~15 s out). "Right turn coming up at the next street".
    public let voiceHeadsUp: String?
    /// At-the-maneuver voice cue. "Turn right" / "حوّد يمين".
    public let voiceTurnNow: String?
    /// Voice cue with landmark. "Turn right after the gas station".
    public let voiceAtLandmark: String?
    /// Mid-lead template — client substitutes `{secs}`.
    public let voiceGetReadyTemplate: String?
    /// Distance variant template — client substitutes `{meters}`.
    public let voiceAtDistanceTemplate: String?
    /// Pre-rendered far-phase cue — landmark-led, measurement-free in
    /// eyes-off mode. Preferred over `voiceHeadsUp`.
    public let voiceFar: String?
    /// Pre-rendered mid-phase cue — mode-aware (measurement-free in
    /// eyes-off mode). Preferred over `voiceGetReadyTemplate`.
    public let voiceMid: String?
    /// Pre-rendered near-phase cue — landmark-led, measurement-free in
    /// eyes-off mode. Preferred over `voiceAtLandmark` / `voiceTurnNow`.
    public let voiceNear: String?
    /// Pre-rendered chained-turn cue — present when the next maneuver
    /// follows within ~100 m, packaging both turns into one near-phase
    /// cue ("Turn right now onto X. Then quickly turn right again.").
    /// Spoken in place of `voiceNear` when present; nil otherwise.
    public let voiceChained: String?
    /// Post-maneuver reassurance, spoken once the turn is completed.
    /// "Good, you're on West 40th Street."
    public let voiceConfirm: String?
    /// Missed-turn recovery cue — spoken when the rider strays off-route
    /// while heading for this maneuver. "Looks like you missed the turn,
    /// recalculating." Nil → fall back to the trip-level rerouting line.
    public let voiceRecover: String?
    /// Mid-segment reassurance — names the current road + next action
    /// ("Still on University Ave. Then turn right."). Spoken once on the
    /// quiet stretch leading into this maneuver; preferred over the
    /// generic trip-level keep-going line.
    public let voiceReaffirm: String?
    /// Mid-segment checkpoint cue — a POI the rider passes on a long
    /// quiet stretch, for confidence ("You're passing the museum on your
    /// right."). Fired at ``checkpointOffsetMeters``.
    public let voiceCheckpoint: String?
    /// Distance (m) AFTER the previous maneuver at which to speak
    /// ``voiceCheckpoint``. Nil → no checkpoint on this segment.
    public let checkpointOffsetMeters: Int?
    /// Distance (m) before the maneuver at which to speak the far / mid
    /// / near cue — the server's own lead-distance choice. Nil → the
    /// SDK falls back to a per-profile default.
    public let cueFarMeters: Int?
    public let cueMidMeters: Int?
    public let cueNearMeters: Int?
    /// Raw POI name (no infix) for icon overlays.
    public let landmark: String?

    public init(
        index: Int,
        total: Int,
        type: ManeuverType,
        rawInstruction: String? = nil,
        latitude: Double,
        longitude: Double,
        segmentLengthMeters: Double,
        segmentDurationSeconds: Double? = nil,
        roundaboutExit: Int? = nil,
        bannerVerb: String? = nil,
        bannerAnchor: String? = nil,
        voiceHeadsUp: String? = nil,
        voiceTurnNow: String? = nil,
        voiceAtLandmark: String? = nil,
        voiceGetReadyTemplate: String? = nil,
        voiceAtDistanceTemplate: String? = nil,
        voiceFar: String? = nil,
        voiceMid: String? = nil,
        voiceNear: String? = nil,
        voiceChained: String? = nil,
        voiceConfirm: String? = nil,
        voiceRecover: String? = nil,
        voiceReaffirm: String? = nil,
        voiceCheckpoint: String? = nil,
        checkpointOffsetMeters: Int? = nil,
        cueFarMeters: Int? = nil,
        cueMidMeters: Int? = nil,
        cueNearMeters: Int? = nil,
        landmark: String? = nil
    ) {
        self.index = index
        self.total = total
        self.type = type
        self.rawInstruction = rawInstruction
        self.latitude = latitude
        self.longitude = longitude
        self.segmentLengthMeters = segmentLengthMeters
        self.segmentDurationSeconds = segmentDurationSeconds
        self.roundaboutExit = roundaboutExit
        self.bannerVerb = bannerVerb
        self.bannerAnchor = bannerAnchor
        self.voiceHeadsUp = voiceHeadsUp
        self.voiceTurnNow = voiceTurnNow
        self.voiceAtLandmark = voiceAtLandmark
        self.voiceGetReadyTemplate = voiceGetReadyTemplate
        self.voiceAtDistanceTemplate = voiceAtDistanceTemplate
        self.voiceFar = voiceFar
        self.voiceMid = voiceMid
        self.voiceNear = voiceNear
        self.voiceChained = voiceChained
        self.voiceConfirm = voiceConfirm
        self.voiceRecover = voiceRecover
        self.voiceReaffirm = voiceReaffirm
        self.voiceCheckpoint = voiceCheckpoint
        self.checkpointOffsetMeters = checkpointOffsetMeters
        self.cueFarMeters = cueFarMeters
        self.cueMidMeters = cueMidMeters
        self.cueNearMeters = cueNearMeters
        self.landmark = landmark
    }
}

/// Trip-level Scoova state-machine vocabulary, pushed by adapters that
/// receive a server-rendered `trip.scoova` block. Holds the phrases the
/// state machine speaks for welcome / good / keepGoing / almostThere /
/// arrived / wrongWay / missedTurn / rerouting / slow. All clients render
/// whatever the server says — no client-side phrasing.
public struct TripScoovaState: Sendable, Equatable {
    public let lang: String?
    public let dir: String?
    public let state: [String: String]

    public init(lang: String? = nil, dir: String? = nil, state: [String: String] = [:]) {
        self.lang = lang
        self.dir = dir
        self.state = state
    }
}

/// Per-tick progress info pushed by the host adapter. 1–4 Hz.
public struct ProgressEvent: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let speedMps: Float?
    public let bearingDeg: Float?
    public let upcomingManeuverIndex: Int
    public let metersToUpcomingManeuver: Double
    public let secondsRemaining: Int
    public let metersRemaining: Int

    public init(
        latitude: Double,
        longitude: Double,
        speedMps: Float? = nil,
        bearingDeg: Float? = nil,
        upcomingManeuverIndex: Int,
        metersToUpcomingManeuver: Double,
        secondsRemaining: Int,
        metersRemaining: Int
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.speedMps = speedMps
        self.bearingDeg = bearingDeg
        self.upcomingManeuverIndex = upcomingManeuverIndex
        self.metersToUpcomingManeuver = metersToUpcomingManeuver
        self.secondsRemaining = secondsRemaining
        self.metersRemaining = metersRemaining
    }
}
