# Changelog

All notable changes to ScoovaNavLayer (iOS).

## [1.0.1] — 2026-06-06

First CocoaPods publish. The 1.0.0 git tag landed but never made it to
`pod trunk push`, so 1.0.1 is effectively the SDK's first published
version across all three pods (`ScoovaNavLayerCore`, `ScoovaNavLayerUI`,
`ScoovaNavLayerScoovaRouting`).

### Guidance
- Persona + heading-aware off-route — sidewalk-parallel walking 15-25 m
  off the routed centerline no longer false-fires wrong-way. Drift /
  off-route thresholds scale by costing (pedestrian 60 m vs auto 30 m);
  GPS bearing matching segment bearing within 35° suppresses drift +
  off-route entirely. Voice silence-filler says "N metres to the next
  turn" (matches the banner) instead of "to your destination" (which
  was a different number from the banner).
- Side-aware street counting — "take the second right" now counts only
  RIGHT-side streets via the routing adapter's `trace_cross_streets`
  L/R/LR tagging. Previously counted both sides, producing the wrong
  ordinal and an early turn.
- Cue-bunching fix — landmark-proxy trims far/mid cues when the run-up
  into a turn is too short; no more cluster of cues at route start.

### Routing adapter
- Richer corridor data parsing in `ScoovaRoutingAdapter` for upcoming
  guidance-reasoner work (graph fingerprints, per-maneuver cross-street
  list, ambiguity flags).

## [1.0.0] — unreleased

First packaged release — the eyes-off navigation engine.

### Engine
- Turn-by-turn voice cues — heads-up → get-ready → turn, conversational,
  every cue names the destination road
- Cues lead with an ordinal count where one exists ("take the second
  left") — the eyes-off rider's anchor
- Speed-adaptive cue timing — cues fire by time-to-turn, so the lead
  time is constant at any speed
- Post-turn confirmation with compass heading ("you're on X, heading
  east")
- Live progress notes on long roads ("…16 km to your destination")
- `GuidanceMonitor` — off-route detection + reroute callback, drift /
  heading-mismatch, silence chime, "almost there"
- IMU/motion fusion — gyro confirms a turn was taken; hard-brake /
  crash detection
- `AudioReliability` — `AVAudioSession` lifecycle, ducking, route-change
  and interruption handling; cues play with the screen locked

### Routing
- `ScoovaRoutingAdapter` — fetches + decodes routes from the Scoova API
- Continuous projection of each GPS fix onto the route (distance-along,
  maneuver cursor) — the upcoming-maneuver banner only advances once the
  rider has truly passed a turn

### UI (`ScoovaNavLayerUI`)
- Directional heading puck, maneuver banner, route-preview card

### API
- Public surface reduced to `ScoovaNavLayer`, `ScoovaRoutingAdapter`
  and the data types — engine internals are no longer exposed

### Tested
- 45 unit tests (cue schedule, route decode, progression, end-to-end
  replay)

### Known limitations
- Non-English cue copy is being upgraded to the new conversational style
- Real-device ride validation pending
- No bundled Mapbox / Google Maps / MapKit adapter
