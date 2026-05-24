# ScoovaNavLayer — iOS

Eyes-off turn-by-turn navigation for iOS. A voice-first navigation
engine: the rider reaches an unfamiliar destination on audio alone —
calm, conversational cues, no glances at the phone.

```
"Coming up, take the second right onto Camelback Road."
"Get ready to turn right onto Camelback Road."
"Okay, turn right here onto Camelback Road."
"Good — you're on Camelback Road, heading east."
```

Same module shape and API style as the
[Android SDK](../scoova-nav-layer-android).

## Requirements

- iOS 15+ · Swift 5.9 / Xcode 15+ (macOS 13+ builds for tests/tools)
- A Scoova API key — [cloud.scoo-va.info](https://cloud.scoo-va.info)

## Installation

Swift Package Manager — Xcode → **File → Add Package Dependencies…**:

```
https://github.com/scoova/scoova-nav-layer-ios
```

Or for `Package.swift` consumers:

```swift
dependencies: [
    .package(url: "https://github.com/scoova/scoova-nav-layer-ios", from: "1.0.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "ScoovaNavLayerCore", package: "scoova-nav-layer-ios"),
        .product(name: "ScoovaNavLayerUI", package: "scoova-nav-layer-ios"),
        .product(name: "ScoovaNavLayerScoovaRouting", package: "scoova-nav-layer-ios"),
    ]),
]
```

| Product | What it gives you |
|---|---|
| `ScoovaNavLayerCore` | The navigation engine — cues, voice, guidance |
| `ScoovaNavLayerScoovaRouting` | Route fetching + GPS → engine adapter |
| `ScoovaNavLayerUI` | SwiftUI drop-ins — heading puck, maneuver banner, route card |

## App setup — `Info.plist`

Navigation runs with the screen locked, so the **host app** must declare
the background modes and a location-usage string:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>location</string>
  <string>audio</string>
</array>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Used during a ride to guide you turn-by-turn.</string>
```

`When In Use` authorization is enough — the `location` background mode
keeps the app alive for the whole ride (no "Always" permission, no
30-second suspension). The SDK sets `allowsBackgroundLocationUpdates`
when a ride starts; the `audio` mode lets cues play with the screen
locked.

## Quick start

### Option A — let the SDK handle routing (recommended)

```swift
import ScoovaNavLayerCore
import ScoovaNavLayerScoovaRouting

let layer = ScoovaNavLayer.builder()
    .apiKey("sk_live_…")
    .locale("en-US")
    .profile("scooter")          // pedestrian | bicycle | scooter | auto
    .landmarks(true)
    .spatialAudio(true)
    .build()
layer.start()

let routing = ScoovaRoutingAdapter(apiKey: "sk_live_…", layer: layer)

// Fetch a route and start guiding. eyesOff: true selects the
// audio-first cue style (no on-screen distances in the voice).
let shape = try await routing.startRoute(
    from: LatLon(lat: 37.3175, lon: -122.0050),
    to:   LatLon(lat: 37.3290, lon: -122.0530),
    profile: "scooter", language: "en-US", eyesOff: true)
// Draw `shape` ([[lat, lon]]) on MapKit / Mapbox / MapLibre.

// Feed every GPS fix from your CLLocationManager:
routing.onLocation(lat: fix.coordinate.latitude,
                    lon: fix.coordinate.longitude,
                    speedMps: Float(fix.speed),
                    bearingDeg: Float(fix.course))
```

The adapter fetches the route, projects each GPS fix onto it, fires the
voice cues, detects off-route and requests reroutes.

### Option B — bring your own routing

```swift
let layer = ScoovaNavLayer.builder().apiKey("sk_live_…").build()
layer.start()

layer.onRoute(maneuvers)                    // [ManeuverEvent]
layer.onProgress(ProgressEvent(             // on every GPS tick
    latitude: lat, longitude: lon,
    speedMps: speed, bearingDeg: course,
    upcomingManeuverIndex: idx,
    metersToUpcomingManeuver: dist,
    secondsRemaining: secs, metersRemaining: rem))
```

### SwiftUI bindings

`ScoovaNavLayer` publishes `currentInstruction` and `headingDeg`, so
`@ObservedObject` / `@StateObject` works directly:

```swift
import SwiftUI
import ScoovaNavLayerCore
import ScoovaNavLayerUI

struct RideView: View {
    @ObservedObject var nav: ScoovaNavLayer
    var body: some View {
        ZStack {
            // your map here
            if let cue = nav.currentInstruction {
                VStack { ScoovaManeuverBanner(cue: cue).padding(); Spacer() }
            }
            ScoovaHeadingPuck(headingDeg: nav.headingDeg)
        }
    }
}
```

### Reroute

```swift
layer.onRerouteNeeded = {
    Task { try await routing.startRoute(from: here, to: destination, eyesOff: true) }
}
```

## Public API

| Type | Role |
|---|---|
| `ScoovaNavLayer` | The engine — `builder()`, `start()`, `stop()`, `onRoute`, `onProgress`, `onMotion`, `setVoiceEnabled`, `$currentInstruction`, `$headingDeg`, `onRerouteNeeded`, `crashEvents`, `diagnostics` |
| `ScoovaRoutingAdapter` | `startRoute(from:to:…)`, `onLocation(…)` — routing + GPS bridge |
| `ManeuverEvent` / `ProgressEvent` | Route + per-tick progress data |
| `MotionFrame` / `CrashEvent` | Optional IMU input + crash-detection output |
| `Diagnostics` | Audio route, TTS readiness, last-cue latency |

The engine internals (voice synthesis, guidance monitor, sensor fusion)
are deliberately not part of the public surface — drive everything
through `ScoovaNavLayer`.

### Optional — IMU fusion

Forward CoreMotion frames via `layer.onMotion(_:)` for gyro confirmation
that a turn was taken, plus hard-brake / crash detection on
`layer.crashEvents`.

## Voice / locales

Cue copy is **server-rendered** by the Scoova routing API — the SDK
speaks what the route response carries. English (`en-US`) is the fully
reworked conversational copy; `fr · es · de · it · pt-BR · nl · ar ·
ar-EG` are shipping and being brought up to the same style. The SDK also
carries a 7-locale offline phrase fallback for when no server copy is
present.

## Status

- ✅ Navigation engine, routing adapter, SwiftUI components
- ✅ 45 unit tests passing (`swift test`)
- ✅ iOS background operation (location + audio modes)
- ⏳ Non-English cue copy — being upgraded to the new conversational style
- ⏳ Real-device ride validation — pending
- ❌ Mapbox / Google Maps / MapKit map adapters — bring up per integration

## Tests

```bash
swift test     # Executed 45 tests, with 0 failures
```

## License

Proprietary — © Scoova. Contact for licensing terms.
