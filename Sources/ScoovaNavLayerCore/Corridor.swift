import Foundation

/// Versioned per-route data the on-device guidance reasoner reads to
/// generate cues from grammar instead of replaying pre-baked strings.
///
/// The routing service emits one ``Corridor`` per route at fetch time
/// alongside the existing `trip` block. The SDK decodes it once,
/// stores it on the layer, and the reasoner queries it on every
/// progress tick to answer "where am I in the road network?" and
/// "what should I say next?"
///
/// Contract source-of-truth: ``docs/CorridorContract.md`` in this
/// repository. Both server and SDK build to that document; never
/// alter this struct without first updating the contract doc and
/// bumping ``version``.
///
/// All fields are Optional so the SDK degrades gracefully when an
/// older service is on the other end of the wire — in that case the
/// layer falls back to the legacy baked-string voice path.
public struct Corridor: Decodable, Sendable, Equatable {
    /// Schema version. ``1`` is the initial contract.
    public let version: Int
    /// Polyline-aligned fingerprints identifying which road segment
    /// each run of polyline vertices belongs to. Lets the SDK answer
    /// "which road am I on" without shipping the road graph.
    public let graphFingerprints: [GraphFingerprint]
    /// Per-maneuver context the reasoner uses to pick cue grammar:
    /// cross-streets, ambiguity flags, ordinals.
    public let maneuvers: [CorridorManeuver]
    /// **The map the navigator is holding.** Every OSM way within
    /// ~80 m of the route polyline, returned at route-fetch time so
    /// the SDK can do real on-device map-matching — snapping each
    /// GPS fix to the nearest way, comparing to the route's expected
    /// way, firing off-route the instant the rider's actual way
    /// diverges from the planned one. Optional: empty when the
    /// routing service hasn't shipped Phase G yet; the SDK then
    /// falls back to lateral-distance heuristics.
    public let neighbourGraph: [NeighbourWay]

    public init(
        version: Int = 1,
        graphFingerprints: [GraphFingerprint] = [],
        maneuvers: [CorridorManeuver] = [],
        neighbourGraph: [NeighbourWay] = []
    ) {
        self.version = version
        self.graphFingerprints = graphFingerprints
        self.maneuvers = maneuvers
        self.neighbourGraph = neighbourGraph
    }

    enum CodingKeys: String, CodingKey {
        case version, graphFingerprints, maneuvers, neighbourGraph
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.graphFingerprints = try c.decodeIfPresent(
            [GraphFingerprint].self, forKey: .graphFingerprints) ?? []
        self.maneuvers = try c.decodeIfPresent(
            [CorridorManeuver].self, forKey: .maneuvers) ?? []
        self.neighbourGraph = try c.decodeIfPresent(
            [NeighbourWay].self, forKey: .neighbourGraph) ?? []
    }
}

/// One OSM way in the neighbour graph: a road within ~80 m of the
/// route polyline. The SDK's localizer snaps each GPS fix to the
/// nearest way in this list — that's how the device answers
/// "which road am I on" without shipping the road graph.
public struct NeighbourWay: Decodable, Sendable, Equatable {
    /// OSM way identifier. Stable across server responses.
    public let wayId: Int64
    /// Human-readable street name. May be empty for unnamed ways.
    public let name: String
    /// Road classification: ``"motorway"``, ``"trunk"``, ``"primary"``,
    /// ``"secondary"``, ``"tertiary"``, ``"unclassified"``,
    /// ``"residential"``.
    public let roadClass: String
    /// `true` when the way only allows travel in the `forward`
    /// direction. Used by the wrong-way detector — a rider going
    /// against `forward` on a oneway is unambiguously wrong-way.
    public let oneway: Bool
    /// Posted speed limit in km/h. Optional. Powers the dynamic
    /// "slow down for upcoming maneuver" cue.
    public let speedLimitKph: Int?
    /// Edge segments that make up this way's local geometry. Each
    /// segment is a contiguous run of `[lat, lon]` points plus a
    /// `forward` flag telling the rider's direction-of-travel
    /// convention for that edge.
    public let segments: [NeighbourWaySegment]

    public init(
        wayId: Int64,
        name: String = "",
        roadClass: String = "",
        oneway: Bool = false,
        speedLimitKph: Int? = nil,
        segments: [NeighbourWaySegment] = []
    ) {
        self.wayId = wayId
        self.name = name
        self.roadClass = roadClass
        self.oneway = oneway
        self.speedLimitKph = speedLimitKph
        self.segments = segments
    }
}

/// One edge segment of a neighbour way — a contiguous polyline plus
/// the direction-of-travel convention for the edge.
public struct NeighbourWaySegment: Decodable, Sendable, Equatable {
    /// Polyline points as ``[[lat, lon], …]``.
    public let shape: [[Double]]
    /// `true` when the rider's expected direction of travel on this
    /// edge is forward (lat/lon order). `false` means the edge's
    /// canonical direction is reverse.
    public let forward: Bool

    public init(shape: [[Double]], forward: Bool) {
        self.shape = shape
        self.forward = forward
    }
}

/// One contiguous run of the polyline that shares the same road
/// segment + direction of travel. Adjacent fingerprints with the same
/// ``wayId`` + ``direction`` MUST be merged into one entry on the wire.
public struct GraphFingerprint: Decodable, Sendable, Equatable {
    /// Inclusive index into the concatenated polyline.
    public let polylineFrom: Int
    /// Inclusive index into the concatenated polyline.
    public let polylineTo: Int
    /// Stable identifier for the road segment from the source road graph.
    public let wayId: Int64
    /// `"forward"` or `"reverse"` — direction of travel along the way.
    public let direction: String

    public init(polylineFrom: Int, polylineTo: Int, wayId: Int64, direction: String) {
        self.polylineFrom = polylineFrom
        self.polylineTo = polylineTo
        self.wayId = wayId
        self.direction = direction
    }
}

/// Reasoner context for a single maneuver — what the rider passes on
/// the approach segment, how that disambiguates the upcoming decision.
public struct CorridorManeuver: Decodable, Sendable, Equatable {
    /// Global maneuver index. Matches ``ManeuverEvent.index`` after
    /// multi-leg concatenation.
    public let index: Int
    /// Drivable cross-streets the rider passes between the previous
    /// maneuver and this one, in ride order. May be empty.
    public let crossStreets: [CrossStreet]
    /// Open-vocabulary flags. The reasoner reads known flags and
    /// ignores unknown ones — additive evolution stays compatible.
    /// Defined flags include: ``"multipleLeftsBeforeLeftTurn"``,
    /// ``"multipleRightsBeforeRightTurn"``, ``"interchangeCluster"``,
    /// ``"roundaboutExitAmbiguous"``.
    public let ambiguityFlags: [String]
    /// Ordinal context for "take the [Nth] left/right" grammar.
    /// Counts only the maneuver's turn side.
    public let ordinal: ManeuverOrdinal?
    /// Coarse complexity for host UI emphasis. One of:
    /// ``"simple"``, ``"fourWay"``, ``"complex"``, ``"roundabout"``,
    /// ``"interchange"``. Unknown values treated as ``"simple"``.
    public let intersectionComplexity: String?

    public init(
        index: Int,
        crossStreets: [CrossStreet] = [],
        ambiguityFlags: [String] = [],
        ordinal: ManeuverOrdinal? = nil,
        intersectionComplexity: String? = nil
    ) {
        self.index = index
        self.crossStreets = crossStreets
        self.ambiguityFlags = ambiguityFlags
        self.ordinal = ordinal
        self.intersectionComplexity = intersectionComplexity
    }
}

/// One drivable cross-street the rider passes on the approach to a
/// maneuver. The reasoner uses these to count side-specific options
/// — if the rider has to pass two lefts before the intended left, the
/// grammar shifts from "take the next left" to "take the third left."
public struct CrossStreet: Decodable, Sendable, Equatable {
    /// Index into the concatenated polyline where the crossing sits.
    public let polylineIdx: Int
    /// `"L"` (left of travel direction), `"R"` (right), or `"LR"`
    /// (T-junction where the cross-street appears on both sides).
    public let side: String
    /// Whether a rider on the current routing profile could legally
    /// turn into this cross-street. The reasoner skips
    /// ``drivable: false`` entries when counting ordinals.
    public let drivable: Bool
    /// Human-readable street name. May be empty when the source data
    /// has no name — the reasoner then leans on the ordinal grammar.
    public let name: String
    /// Along-route distance from the crossing to the maneuver.
    public let metersBeforeManeuver: Int

    public init(
        polylineIdx: Int,
        side: String,
        drivable: Bool,
        name: String,
        metersBeforeManeuver: Int
    ) {
        self.polylineIdx = polylineIdx
        self.side = side
        self.drivable = drivable
        self.name = name
        self.metersBeforeManeuver = metersBeforeManeuver
    }
}

/// Ordinal of a maneuver among the same-side turns on its approach
/// segment. ``totalSameSideTurns`` may equal 0 when the rider has no
/// competing same-side turns — the reasoner uses that as proof that
/// "the next left" can be spoken with confidence.
public struct ManeuverOrdinal: Decodable, Sendable, Equatable {
    /// `"L"` or `"R"` — matches the maneuver's turn direction.
    public let side: String
    /// 1-based index of THIS maneuver among same-side turns on the
    /// approach. The rider's Nth same-side turn since the previous
    /// maneuver.
    public let indexAmongSameSideTurns: Int
    /// Total same-side turns between the previous maneuver and this
    /// one, inclusive of this maneuver.
    public let totalSameSideTurns: Int

    public init(side: String, indexAmongSameSideTurns: Int, totalSameSideTurns: Int) {
        self.side = side
        self.indexAmongSameSideTurns = indexAmongSameSideTurns
        self.totalSameSideTurns = totalSameSideTurns
    }
}
