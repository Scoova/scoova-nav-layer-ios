# Scoova Routing API — Corridor Contract (v1)

Versioned JSON contract between the routing service and the navigation
SDKs. The corridor is the data the on-device guidance reasoner needs to
generate cues from grammar instead of reading pre-baked strings — see
the eye-on-the-road north-star and the wrong-cue failure mode the
contract is meant to eliminate.

This document is normative. Server and SDK MUST agree on this shape.
Both sides ship migrations together; never bump the schema without
incrementing `corridor.version`.

## Top-level shape

The routing response carries one new top-level block alongside `trip`:

```jsonc
{
  "trip": { /* unchanged */ },
  "corridor": {
    "version": 1,
    "graphFingerprints": [ /* see below */ ],
    "maneuvers":         [ /* see below */ ]
  }
}
```

`corridor` is optional. SDK MUST tolerate its absence and fall back to
the legacy `scoova.voice.*` baked strings on the maneuver. SDK SHOULD
prefer reasoner-generated cues when `corridor` is present.

## graphFingerprints[]

Ordered, polyline-aligned. Lets the SDK answer "which road segment am
I on right now?" without shipping the road graph to the device. One
entry per contiguous run of polyline points that share the same edge.

```jsonc
{
  "polylineFrom": 0,        // inclusive index into trip.legs[*].shape
  "polylineTo":   4,        // inclusive
  "wayId":        12345678, // OSM way id; stable identifier for the road segment
  "direction":    "forward" // "forward" | "reverse" — direction of travel along the way
}
```

Notes:
- Adjacent entries with the same `wayId` + `direction` MUST be merged into one.
- `polylineFrom`/`polylineTo` are continuous; the SDK iterates `currentVertexIndex` against this list to identify the active fingerprint in O(log N).
- A point exactly on the boundary belongs to the lower-indexed fingerprint.
- For multi-leg routes the polyline is the concatenated shape (matches what `ScoovaRoutingAdapter` already produces — see `decodeRoute` in `Sources/ScoovaNavLayerScoovaRouting/ScoovaRoutingAdapter.swift`).

## maneuvers[]

One entry per maneuver in `trip.legs[*].maneuvers[]`, in route order.
`index` is the global maneuver index across all legs (post-concatenation).

```jsonc
{
  "index": 1,

  // Drivable cross-streets the rider PASSES between the previous maneuver
  // and THIS maneuver, in ride order. Used by the reasoner to disambiguate
  // "the next left" — if there are two lefts before the intended one, the
  // grammar shifts to "the third left" / a landmark anchor / distance.
  "crossStreets": [
    {
      "polylineIdx":          7,           // index into the concatenated polyline
      "side":                 "L",         // "L" | "R" | "LR" (T-junctions both sides)
      "drivable":             true,        // whether a rider on this profile could turn into it
      "name":                 "5th Avenue",// human-readable name, may be empty
      "metersBeforeManeuver": 80           // walking-along-route distance to the maneuver
    }
  ],

  // Flags the reasoner reads to pick the right grammar primitive.
  // Open vocabulary; new flags can be added without bumping schema
  // as long as the SDK treats unknown flags as no-ops.
  "ambiguityFlags": [
    "multipleLeftsBeforeLeftTurn",  // > 1 drivable left in the approach segment
    "multipleRightsBeforeRightTurn",
    "interchangeCluster",           // > 2 maneuvers within 80 m
    "roundaboutExitAmbiguous"
  ],

  // Ordinal context for "take the [Nth] left/right" grammar.
  // Counts ONLY the maneuver's turn side; matches existing
  // `compute_streets_to_turn` semantics in the server proxy.
  "ordinal": {
    "side": "L",                       // "L" | "R" — matches the maneuver type
    "indexAmongSameSideTurns": 2,      // 1-based; the rider's Nth same-side turn
    "totalSameSideTurns":      2       // total same-side turns between prev maneuver and this one
  },

  // Coarse complexity hint for the host UI (lane diagrams, banner emphasis).
  // "simple" | "fourWay" | "complex" | "roundabout" | "interchange"
  "intersectionComplexity": "fourWay"
}
```

Notes:
- `index` 0 (depart) and the final maneuver (arrive) MAY omit
  `crossStreets`, `ambiguityFlags`, `ordinal` — those are about
  approach decisions, not start/end.
- `ordinal.totalSameSideTurns` MAY equal 0 — a maneuver with no
  competing same-side turns on the approach. The reasoner uses that
  signal to emit "the next left" with confidence.
- `crossStreets[*].name` MAY be empty string when the source data has
  no name. The reasoner falls back to ordinal grammar.

## Versioning

`version: 1` is the initial contract. Breaking changes (renames,
removed fields, semantic shifts) MUST bump the version. Additive
changes (new optional fields, new ambiguity-flag strings) are NOT
breaking and don't require a version bump — the SDK ignores unknown
fields and unknown flag strings.

## Fallback semantics

Old SDK + new server: the corridor block is parsed and ignored. The
SDK keeps using `scoova.voice.{far,mid,near}`. No regression.

New SDK + old server: `corridor` is absent. The SDK reasoner detects
this and falls back to the legacy baked-string path. No regression.

The fallback path is exercised by the existing `RouteReplayTests` —
those tests construct routes without a corridor block and continue to
pass.

## Open questions to settle before locking version 1

- **Driving direction language**: do we use "forward"/"reverse" or
  "withWay"/"againstWay"? Picked "forward"/"reverse" because it
  matches the routing engine's own convention and is more intuitive
  to host-app authors.
- **Side encoding for crossings on a one-way**: a one-way street
  branching only-left from a two-way main road is encoded `side: "L"`,
  `drivable: true`. A driveway on the right that the profile can't
  enter is `side: "R"`, `drivable: false`. Reasoner skips `drivable: false`.
- **Limit on crossStreets length**: cap server side at 8 per maneuver
  to prevent payload bloat. After 8 the maneuver is by definition in
  an interchange and we set `ambiguityFlags: ["interchangeCluster"]`.

Schema closed. Server and SDK build to this.
