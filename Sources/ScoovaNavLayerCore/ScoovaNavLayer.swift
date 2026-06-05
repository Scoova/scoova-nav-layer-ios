import Foundation
import Combine

/// The public Scoova Nav Layer entry point for Apple platforms.
///
/// **5-line integration:**
/// ```swift
/// let nav = ScoovaNavLayer.builder()
///     .apiKey("sk_live_…")
///     .locale("ar-EG")
///     .profile("scooter")
///     .landmarks(true)
///     .build()
/// nav.start()
/// // … wire your host SDK adapter to push events
/// ```
///
/// Once attached, the layer:
///   - Speaks dialect-aware turn-by-turn cues
///   - Plays left-turn cues in your left ear (spatial audio, default on)
///   - Publishes `currentInstruction` for your SwiftUI banner to bind to
///   - Publishes `headingDeg` for a sensor-driven heading puck
public final class ScoovaNavLayer: @unchecked Sendable {

    public struct DisplayCue: Sendable, Equatable {
        public let maneuver: ManeuverEvent
        public let metersToManeuver: Double
        public let phase: CuePhrases.Phase
        public let text: String
    }

    /// Structured payload for the `onCueFired` telemetry callback.
    /// One of these per spoken cue. Hosts forward it to whichever
    /// analytics SDK they use — Scoova Monitor, Amplitude, etc.
    /// All field types are pure-Swift / Sendable so this can cross
    /// actor boundaries without ceremony.
    public struct CueEvent: Sendable, Equatable {
        /// Wall-clock ms (UTC).
        public let tsMs: Int64
        /// The exact text the voice engine was asked to speak.
        public let text: String
        /// String form of the cue's ``CueTone`` (e.g. "calm", "urgent",
        /// "alert", "cheerful"). Stringly-typed on purpose so the
        /// public surface stays stable across CueTone evolution.
        public let tone: String
        /// Index of the maneuver the cue belongs to, when known.
        public let maneuverIndex: Int?
        /// Live metres to that maneuver at fire time. Lets the
        /// analytics side reconstruct how-many-seconds-out the cue
        /// fired across the persona's speed.
        public let metersToManeuver: Int?
        /// Resolved locale string for the spoken cue ("en-US",
        /// "ar-EG"). Lets analytics split cue quality by language.
        public let locale: String
    }

    /// What a cue is for. Drives fire-time behaviour — a `reaffirm` cue
    /// gets the live distance-to-destination appended when it is spoken,
    /// turning "You're on Route 10, heading south." into a real progress
    /// check: "…heading south. 19 kilometers to your destination."
    enum CueKind: Equatable { case approach, confirm, reaffirm, checkpoint }

    /// One spoken cue, pinned to a point on the route like a movie
    /// subtitle: a phrase plus the distance-before-the-maneuver at
    /// which to speak it. Spoken once, when the rider reaches it.
    /// Internal (not private) so the cue-schedule unit tests can read it.
    struct CuePoint: Equatable {
        let triggerMeters: Double
        let phrase: String
        let tone: CueTone
        let pan: Float
        /// When set, the cue fires by TIME-to-maneuver — this many
        /// seconds out, measured against the rider's live speed —
        /// instead of at the fixed `triggerMeters`. So the reaction
        /// window stays constant whether the rider is at 20 km/h or
        /// 100 km/h. nil ⇒ plain distance trigger (confirm / reaffirm /
        /// checkpoint, which are pinned to a point on the road).
        var triggerSeconds: Double? = nil
        /// What the cue is — see ``CueKind``. Defaults to `.approach`
        /// (the far / mid / near turn cues).
        var kind: CueKind = .approach
    }

    /// Seconds-before-the-maneuver each approach cue aims for. The cue's
    /// trigger distance is this × live speed (see
    /// ``effectiveTriggerMeters(_:speedMps:)``) — a faster rider hears
    /// "turn" proportionally earlier and always gets the same lead time.
    /// `near` is the "do it now" cue ("Turn right here") — it must land
    /// right at the turn, so ~3 s out, not a leisurely heads-up.
    static let cueLeadSeconds: (far: Double, mid: Double, near: Double)
        = (far: 30, mid: 15, near: 3)

    public let apiKey: String
    public let locale: String
    public let profile: String
    private let landmarksEnabled: Bool
    private let spatialAudio: Bool

    private let voice: VoiceEngine
    private let heading = HeadingProvider()
    /// Fallback cue lead-distances when a maneuver carries none.
    private let cueDefaults: (far: Double, mid: Double, near: Double)
    private var maneuvers: [ManeuverEvent] = []
    private var welcomed = false
    /// Wall-clock (ms) when the rider first went still within the wider
    /// arrival radius (``arriveStopRadiusM``). 0 = not currently stopped
    /// near the destination. Drives the parked-at-the-kerb arrival path.
    private var stoppedNearDestSinceMs: Int64 = 0
    /// Per-maneuver cue track, ordered far → near — the "subtitles".
    private var cueSchedule: [Int: [CuePoint]] = [:]
    /// Indices of cues already spoken per maneuver — each fires once.
    /// A set (not a cursor) because time-based triggers move with speed,
    /// so cues can't be assumed to cross in a fixed order.
    private var cueFired: [Int: Set<Int>] = [:]

    @Published public private(set) var currentInstruction: DisplayCue?
    @Published public private(set) var headingDeg: Float = 0
    /// Flips to true the moment the rider reaches the destination — the
    /// arrival cue has been spoken and the trip is over. The host app
    /// observes this to close out the ride (write history, show the
    /// summary). Latches: never flips back within a route, and the
    /// arrival cue fires exactly once. Reset to false by ``onRoute(_:)``.
    @Published public private(set) var arrived = false
    @Published public private(set) var diagnostics: Diagnostics = Diagnostics()
    /// `true` when the adapter has not pushed a progress tick in the
    /// recent past (no GPS for ``gpsLostThresholdMs`` ms). The host's
    /// banner / map can show a "GPS signal lost" indicator. Flips
    /// back to `false` on the next `onProgress` call. Does NOT fire
    /// before the first progress tick — silent until the trip starts.
    @Published public private(set) var gpsLost: Bool = false
    /// Metres still to ride to the destination. Mirrors the latest
    /// ``ProgressEvent.metersRemaining`` so SwiftUI banners that don't
    /// own the progress event can bind directly.
    @Published public private(set) var metersRemaining: Int = 0
    /// Seconds-to-destination based on the rider's progress through the
    /// route. Computed by the adapter and forwarded here for binding.
    @Published public private(set) var secondsRemaining: Int = 0
    /// The maneuver that follows the currently-banner one. Lets the host
    /// render a "Then in 200 m, turn left" mini-line below the primary
    /// banner — critical for city interchanges where the second turn
    /// arrives within seconds of the first. `metersToManeuver` here is
    /// the rider's distance via the upcoming maneuver.
    @Published public private(set) var followingInstruction: DisplayCue?
    /// Lane-guidance hints for the upcoming maneuver — left-to-right
    /// across the road. The host renders these as a strip under the
    /// banner. `nil` ⇒ no lane data shipped for this maneuver.
    @Published public private(set) var currentLanes: [LaneInfo]?
    /// Posted speed limit (km/h) on the segment the rider is currently
    /// on. Drives the SDK's dynamic slowDown cue threshold and lets
    /// hosts paint a speed-limit pip on the puck. `nil` ⇒ no limit
    /// shipped from the server.
    @Published public private(set) var currentSpeedLimitKph: Int?
    /// Server-rendered state-machine vocabulary for the current trip.
    /// Nil until an adapter pushes a `TripScoovaState` (currently the
    /// `ScoovaRoutingAdapter` does this on every `startRoute`).
    @Published public private(set) var tripScoova: TripScoovaState?
    /// Reasoner context for the current route — graph fingerprints +
    /// per-maneuver cross-streets + ordinals + ambiguity flags.
    /// Nil before the first route loads, OR when the routing service
    /// hasn't shipped the corridor contract yet (in which case the
    /// SDK falls back to the legacy baked-string voice path).
    @Published public private(set) var corridor: Corridor?
    /// One structured answer the reasoner produces per progress tick:
    /// where the rider is on the road network, where they are on the
    /// route, whether they're aligned with the segment, what the
    /// upcoming decision is, and what ambiguity flags apply. Every
    /// downstream surface (cue speaker, off-route detector, heading
    /// puck) reads from this struct. Nil before the first progress
    /// tick OR when the route + shape haven't been installed yet.
    @Published public private(set) var liveState: LiveGuidanceState?
    /// Master gate for cue firing + reactive guidance.
    ///
    /// `false` (the default) means the layer ignores every `onProgress`
    /// call without speaking, advancing the cursor, or firing
    /// reactive events. The polyline can still be drawn — the adapter
    /// fetched the route — but no welcome cue plays while the rider
    /// is looking at a preview.
    ///
    /// Hosts call ``setActive(_:)`` ⇒ `true` when the rider taps Start
    /// Navigation, ⇒ `false` when they tap Stop or back out to the
    /// preview screen. The default is `false` so legacy hosts that
    /// haven't been updated yet stay quiet during preview — much
    /// safer than the previous behaviour where the cue fired the
    /// instant a location landed.
    @Published public private(set) var isActive: Bool = false

    /// Fired when the rider has strayed off the route long enough that a
    /// fresh one should be fetched. The host re-runs its routing call
    /// from the current location — `ScoovaRoutingAdapter` users just
    /// wire this to another `startRoute`. May fire off the main thread.
    public var onRerouteNeeded: (() -> Void)?

    /// Production telemetry: fires every time the SDK actually speaks a
    /// cue, with structured context (text, tone, maneuver index,
    /// distance, locale, wall-clock timestamp). The host wires this to
    /// its analytics pipeline so "what cue fired when, on which turn"
    /// is measurable in the field. Nil = no-op. Fires on whatever
    /// thread `saySpoken` is called from — usually the main thread.
    public var onCueFired: ((CueEvent) -> Void)?

    /// Test seam — receives every spoken cue's text, in order, so the
    /// route-replay tests can assert the cue sequence end-to-end.
    /// `internal`: nil and untouched in production.
    var onCueSpoken: ((String) -> Void)?

    // ── Sensor / IMU fusion outputs ──────────────────────────────────
    // Filled by `onMotion`. Until the host adapter starts forwarding
    // sensor frames these stay at their defaults (nil / no emissions).
    private let motionFusion = MotionFusion()
    /// Magnetic compass heading, smoothed, 0..360. Nil until the host
    /// adapter forwards its first IMU frame via ``onMotion(_:)``.
    @Published public private(set) var compassHeadingDeg: Float? = nil
    /// One-shot stream of crash / hard-brake events the rider should be
    /// alerted to. Consumers subscribe to wire crash overlays /
    /// emergency-contact prompts.
    public let crashEvents = PassthroughSubject<CrashEvent, Never>()

    /// Direction kind the most recently fired Near-phase cue asked the
    /// rider to yaw. Used by ``onMotion(_:)`` to confirm execution and
    /// fire the trip-level "good" affirmation.
    public enum TurnDir: Sendable { case left, right }

    /// Tracks the *expected* turn direction from the most recently fired
    /// cue so we can confirm execution from gyro/compass yaw.
    private var pendingTurnDirection: TurnDir? = nil
    private var pendingTurnFiredAtMs: Int64 = 0
    /// The maneuver index whose near-cue armed the pending confirm. Set
    /// at the same time as ``pendingTurnDirection``, cleared when the
    /// gyro confirms or the confirm window expires. When the gyro
    /// confirms, the maneuver index is moved to
    /// ``confirmedTurnManeuvers`` so downstream cues can ask "did the
    /// rider actually execute this turn?"
    private var pendingTurnManeuverIdx: Int? = nil
    /// Maneuver indices whose turn motion was actually confirmed by
    /// the gyro. The almost-there cue inspects this — when the
    /// previous turn was NOT confirmed (rider drove straight through),
    /// the cue strips the leading "Good." prefix so we don't pat the
    /// rider on the back for a turn they didn't make.
    private var confirmedTurnManeuvers: Set<Int> = []
    /// The most recent maneuver index whose near-cue armed a turn
    /// confirm. Persists after the pending state is cleared so
    /// downstream cues (almostThere) can ask "did the rider execute
    /// the previous turn?" Set whenever ``pendingTurnManeuverIdx``
    /// is set; cleared on a fresh route.
    private var lastArmedTurnManeuverIdx: Int? = nil
    /// Window after a turn cue inside which a matching yaw counts as
    /// confirmation. 8 seconds covers slow scooter turns + light delay.
    private let turnConfirmWindowMs: Int64 = 8_000
    /// Latest progress tick's metres-to-destination. Cached for the
    /// silence-filler verbal cue, which composes "Still on X. N metres
    /// to your destination." without re-receiving the ProgressEvent.
    private var latestMetersRemaining: Int = 0
    /// Most recent ``ProgressEvent`` cached so guidance handlers (which
    /// don't receive the event directly) can ask "is X ahead of the
    /// rider?" Used by keepGoing's coord-ahead gate.
    private var lastProgressForGate: ProgressEvent?
    /// Set when ``onRoute(isReroute: true)`` runs, consumed by the
    /// next ``setRouteShape`` to check whether the just-landed route's
    /// first meaningful segment is geometrically BEHIND the rider —
    /// in which case the rider needs to be told to physically turn
    /// around. The navigator's wrong-way logic only fires when the
    /// rider's snap is already on a route way; this check covers the
    /// OFF-ROUTE-but-route-is-behind case the navigator misses. Bug
    /// observed live 2026-05-29 at 05:27:30: U-TURN reroute landed,
    /// rider snap off the route corridor, no turn-around cue fired.
    private var pendingRerouteUTurnCheck: Bool = false
    /// Remembered eye-on-the-road flag from the most recent
    /// ``onRoute`` call. Used by the cue-text selection code to gate
    /// out the metre-based grammar — eye-on-the-road BANS distance,
    /// time, cardinal directions, street names per
    /// [[feedback-eyesoff-cue-grammar]]. The grammar's distance
    /// fallback ("Turn left in 80 metres") is appropriate only when
    /// the rider can look at the phone.
    private var routeEyesOff: Bool = false
    /// Latest progress tick's metres to the upcoming maneuver. Used by
    /// the silence-filler so its distance number matches the banner
    /// (which counts down to the next turn, not the destination). The
    /// rider hearing "812 m to the next turn" while looking at "812 m"
    /// on the banner is the whole point — mismatched numbers read as
    /// a bug.
    private var latestMetersToUpcomingManeuver: Int = 0

    // ── Arrival detection ────────────────────────────────────────────
    /// Route metres remaining at which the rider counts as arrived.
    private let arriveRadiusM = 30
    /// A rider who parks at the kerb, or whose GPS settles a little
    /// short of the pin, may never roll inside ``arriveRadiusM``. Within
    /// this wider radius, holding still for ``arriveStopDwellMs`` also
    /// counts as arrival — so the trip ends cleanly instead of leaving
    /// guidance running (which would false-fire "wrong way, turn
    /// around" at a rider who has simply arrived).
    private let arriveStopRadiusM = 70
    private let arriveStopSpeedMps: Float = 0.7
    private let arriveStopDwellMs: Int64 = 6_000

    /// Continuous closed-loop guidance — silence/drift/off-route/heading/
    /// speed/almost-there state machine. Ticked from every ``onProgress(_:)``
    /// call; reads compass heading from ``onMotion(_:)`` via
    /// ``GuidanceMonitor/onCompassHeading(_:)``.
    private let guidance = GuidanceMonitor()

    /// Trip-level state phrases set by the adapter from the server's
    /// `trip.scoova.state` block. Adapter calls ``setTripState(_:)`` on
    /// route load. We read `good`, `wrongWay`, `keepGoing`, etc. here.
    private var tripScoovaState: [String: String]? = nil

    private var headingTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    /// CoreMotion bridge — packs `CMDeviceMotion` frames at 50 Hz into
    /// ``MotionFrame`` and forwards them to ``onMotion(_:)``. Without
    /// this, ``MotionFusion`` (smoothed compass, turn detection, crash
    /// detection) never runs and ``GuidanceMonitor``'s standstill
    /// wrong-way check is starved of heading. Earlier builds defined
    /// ``SensorRelay`` but never instantiated it; the relay is now owned
    /// by the layer's lifecycle so the SDK works out-of-the-box.
    private var sensorRelay: SensorRelay?
    /// Wall-clock (ms) when an off-route event last asked the host for
    /// a fresh route. Used to suppress redundant recovery cues while a
    /// reroute is already in flight — otherwise the rider hears "Looks
    /// like you missed the turn, recalculating" on every fix until the
    /// new route lands. Reset to 0 when a fresh route is installed.
    private var rerouteRequestedAtMs: Int64 = 0
    private let rerouteCueCooldownMs: Int64 = 10_000
    /// Wall-clock (ms) when the LAST reroute response actually landed
    /// (the adapter called `onRoute(isReroute: true)`). The adapter
    /// throttles its actual /route fetch to one per 8 s — so the
    /// navigator can fire its off-route intent freely (and DOES,
    /// after the cooldown clear we ship on every successful reroute),
    /// but if the speaker fires the "Recalculating" cue ON A TICK
    /// WHERE THE FETCH WILL BE THROTTLED, the rider hears it and
    /// nothing happens. That's a lie. We track when the last route
    /// actually landed and suppress the cue during the next 8 s.
    private var lastRerouteLandedAtMs: Int64 = 0
    private let rerouteFetchThrottleMs: Int64 = 8_000
    /// Wall-clock (ms) of the most recent ``onProgress`` tick — the
    /// proxy for "we just heard from the host's location service."
    /// The watchdog flips ``gpsLost`` to true if this stays stale.
    /// 0 ⇒ no progress tick yet (trip hasn't truly started).
    private var lastProgressAtMs: Int64 = 0
    /// Threshold after which the host hears nothing. 8 s is roughly
    /// twice the worst-case CoreLocation cadence for "deferred"
    /// foreground updates — anything past that is genuinely silence.
    private let gpsLostThresholdMs: Int64 = 8_000
    private var gpsWatchdogTask: Task<Void, Never>?

    // ── Course-when-moving heading (P1.9) ────────────────────────────
    /// Speed above which GPS course (bearing of travel) is trusted over
    /// the compass for the puck. ~1 m/s = 3.6 km/h — slower than a
    /// brisk walk, which keeps a walker holding the phone in their hand
    /// from constantly snapping the puck to wherever the phone is
    /// pointed. Below this, the heading falls back to compass.
    private let courseHeadingMinSpeedMps: Float = 1.0
    /// How long after the last moving fix to keep using GPS course
    /// instead of compass. Briefly outlasts the typical fix gap (4 s)
    /// so a single missed fix doesn't snap the puck back to compass.
    private let courseHeadingHoldMs: Int64 = 5_000
    /// Wall-clock (ms) until which the GPS course is preferred over
    /// compass for the published `headingDeg`. 0 ⇒ compass is the
    /// source of truth.
    private var movingHeadingValidUntilMs: Int64 = 0

    private init(
        apiKey: String, locale: String, profile: String,
        landmarks: Bool, spatialAudio: Bool
    ) {
        self.apiKey = apiKey
        self.locale = locale
        self.profile = profile
        self.landmarksEnabled = landmarks
        self.spatialAudio = spatialAudio
        self.cueDefaults = Thresholds.cueOffsets(for: profile)
        self.voice = VoiceEngine()
        self.voice.locale = locale
        self.voice.spatialEnabled = spatialAudio
    }

    public func start() {
        headingTask?.cancel()
        headingTask = Task { [weak self] in
            guard let self = self else { return }
            for await h in self.heading.stream() {
                await MainActor.run {
                    // Heading source policy: GPS course when moving,
                    // compass when stopped. A pedestrian holding the
                    // phone in their hand while walking south but
                    // pointing the phone north should see the puck
                    // point south — compass alone gets that wrong.
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    if now > self.movingHeadingValidUntilMs {
                        self.headingDeg = h
                    }
                    // GuidanceMonitor ALWAYS gets compass — the
                    // standstill wrong-way check explicitly needs the
                    // phone's facing direction, not the GPS course.
                    self.guidance.onCompassHeading(h)
                }
            }
        }
        // Roll Diagnostics from the underlying VoiceEngine + AudioReliability.
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            guard let self = self else { return }
            await self.observeDiagnostics()
        }
        // Spin up the CoreMotion bridge so MotionFusion gets sensor frames.
        // Without this, ``compassHeadingDeg``, turn detection, and crash
        // events never fire. Owned here so ``stop()`` tears it down.
        sensorRelay = SensorRelay { [weak self] frame in
            self?.onMotion(frame)
        }
        sensorRelay?.start()
        // GPS-staleness watchdog. Polls once per second; if the rider
        // hasn't seen a progress tick in 8 s, flip ``gpsLost`` so the
        // host can surface a "GPS signal lost" indicator. Without
        // this, the SDK silently freezes the cursor when the location
        // feed dies (tunnel / phone sleep / app suspended) and the
        // rider has no idea anything is wrong.
        gpsWatchdogTask?.cancel()
        gpsWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self else { return }
                await MainActor.run {
                    guard self.lastProgressAtMs > 0 else { return }
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    let stale = (now - self.lastProgressAtMs) > self.gpsLostThresholdMs
                    if stale != self.gpsLost {
                        self.gpsLost = stale
                        // Speak the transition so the rider knows the
                        // navigator's blind (or back online). Only
                        // when the layer is active — silent in preview
                        // or after stopNav.
                        guard self.isActive, !self.maneuvers.isEmpty else { return }
                        if stale {
                            let phrase = self.tripScoovaState?["gpsLost"]
                                ?? "GPS signal lost. Keep going on your current road."
                            self.saySpoken(phrase, tone: .alert)
                        } else {
                            let phrase = self.tripScoovaState?["gpsBack"]
                                ?? "GPS signal is back."
                            self.saySpoken(phrase, tone: .calm)
                        }
                    }
                }
            }
        }
    }

    public func stop() {
        headingTask?.cancel()
        diagnosticsTask?.cancel()
        gpsWatchdogTask?.cancel()
        gpsWatchdogTask = nil
        lastProgressAtMs = 0
        gpsLost = false
        sensorRelay?.stop()
        sensorRelay = nil
        voice.shutdown()
    }

    @MainActor
    private func observeDiagnostics() async {
        // Poll-on-publish: every time any sub-signal changes, rebuild a
        // Diagnostics snapshot. Coarse-grained (50 ms tick) is plenty —
        // diagnostics are observability, not nav state.
        while !Task.isCancelled {
            let d = Diagnostics(
                audioRoute: voice.reliability.route,
                ttsEngineReady: voice.ttsReady,
                lastCueLatencyMs: voice.lastCueLatencyMs,
                voiceLocaleResolved: voice.voiceLocaleResolved,
                voiceFallback: voice.voiceFallback,
                lookaheadOffsetMs: voice.reliability.route.defaultLookaheadMs,
                interrupted: voice.reliability.interrupted
            )
            if d != diagnostics { diagnostics = d }
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
        }
    }

    public func setVoiceEnabled(_ enabled: Bool) {
        voice.voiceEnabled = enabled
    }

    /// Switch the layer between preview and active navigation. While
    /// the rider is looking at a route preview the layer holds a
    /// route + a shape (drawn on the map by the host) but stays
    /// silent — no welcome cue, no approach cues, no reactive
    /// guidance. The moment the rider taps Start Navigation the host
    /// flips this to `true` and the next `onProgress` tick fires the
    /// welcome cue + begins guidance. Flipping back to `false` also
    /// resets the `welcomed` latch so a subsequent activation
    /// replays the welcome.
    public func setActive(_ active: Bool) {
        let wasActive = self.isActive
        self.isActive = active
        NSLog("🟢 [Nav] setActive(\(active)) wasActive=\(wasActive) maneuvers=\(maneuvers.count) welcomed=\(welcomed)")
        if !active && wasActive {
            // Going active → idle: forget that the welcome ran so the
            // next activation greets the rider again. Don't clear the
            // route — the host may still be showing the polyline.
            welcomed = false
            // Stop any in-flight wrong-way / drift timers from
            // surviving across the gap.
            guidance.reset()
        }
    }

    /// Adapter calls once when the host gives us the route.
    public func onRoute(_ maneuvers: [ManeuverEvent]) {
        onRoute(maneuvers, isReroute: false, eyesOff: false)
    }

    /// Install a fresh maneuver list. `isReroute` distinguishes the
    /// rider's INITIAL trip from a mid-trip auto-reroute. Welcome cues
    /// and post-arrival flags only reset on initial routes — a reroute
    /// should drop seamlessly into the rider's existing trip without
    /// spamming "Let's go" again on every refetch. The cue-fired
    /// dedup table DOES reset either way so the rider hears the
    /// approach cues for the new maneuvers.
    ///
    /// `eyesOff` toggles the eye-off cue rewrites (bare "Turn right"
    /// becomes "Take the next right" — ordinal-only, unambiguous to a
    /// non-looking rider). Adapters know the rider's voice mode from
    /// the route request, so they pass it through here. Eyes-on
    /// riders keep the original "turn right onto X" because they can
    /// see the street name on the banner.
    public func onRoute(_ maneuvers: [ManeuverEvent], isReroute: Bool, eyesOff: Bool = false) {
        self.maneuvers = maneuvers
        self.routeEyesOff = eyesOff
        if !isReroute {
            self.welcomed = false
            self.arrived = false
            self.stoppedNearDestSinceMs = 0
            self.confirmedTurnManeuvers.removeAll()
            self.lastArmedTurnManeuverIdx = nil
            self.pendingTurnDirection = nil
            self.pendingTurnManeuverIdx = nil
        }
        // Fresh route is here — clear the reroute-cue suppression gate so
        // the NEXT genuine off-route event speaks its recovery cue.
        self.rerouteRequestedAtMs = 0
        if isReroute {
            self.lastRerouteLandedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        } else {
            self.lastRerouteLandedAtMs = 0
        }
        // Empty maneuver list ⇒ host is tearing down (see ``stop()`` on
        // ScoovaRoutingAdapter / NavLayerSession). Clear the surfaces
        // that the banner binds to so nothing stale stays on screen
        // while the new trip spins up. Done before the cueFired reset
        // so a host that re-uses the layer across trips sees a clean
        // transition.
        if maneuvers.isEmpty {
            currentInstruction = nil
            followingInstruction = nil
            metersRemaining = 0
            secondsRemaining = 0
            liveState = nil
            routeShape = []
        }
        self.cueFired = [:]
        self.cueSchedule = Self.buildCueSchedule(
            maneuvers,
            defaults: cueDefaults,
            keepGoing: tripScoovaState?["keepGoing"],
            pan: panFor,
            eyesOff: eyesOff
        )
        guidance.reset()
        navigator.reset(isReroute: isReroute)
        // Arm the U-turn check the next ``setRouteShape`` consumes.
        // Only reroutes carry this — on initial route the rider hasn't
        // moved yet, no bearing to compare against.
        if isReroute { pendingRerouteUTurnCheck = true }
    }

    /// Lay out the per-maneuver cue track — the "subtitles". Each turn
    /// contributes its approach cues (far / mid / near, pinned to the
    /// lead distance the server chose) plus the reassurance the rider
    /// needs *between* turns: the previous turn's `confirm` right after
    /// it lands, and "keep going" on the quiet middle of a long stretch.
    /// Depart and arrive are skipped — welcome and arrival cover those.
    static func buildCueSchedule(
        _ maneuvers: [ManeuverEvent],
        defaults: (far: Double, mid: Double, near: Double),
        keepGoing: String?,
        pan: (ManeuverType) -> Float,
        eyesOff: Bool = false
    ) -> [Int: [CuePoint]] {
        guard maneuvers.count > 2 else { return [:] }

        // One turn per cue. Each maneuver gets its OWN cues, spoken at
        // its own moment — never two turns bundled into one breath
        // ("turn right here, then turn right again"). Two close turns
        // are simply two cues in sequence; the gating below keeps the
        // second turn's heads-up from bunching onto the first.
        var schedule: [Int: [CuePoint]] = [:]
        for i in 1..<(maneuvers.count - 1) {
            let m = maneuvers[i]

            // Skip maneuvers that aren't actual turns — they're just the
            // road bending, forking-straight, or being renamed.
            // Announcing "turn right" while the rider is riding straight
            // along a curving road is what one rider called "telling me
            // to turn right when the street itself turns right and I'm
            // already on it." The maneuver still exists in the route
            // (needed for distance-to-next-real-turn calculation), but
            // it doesn't earn its own audible cue.
            switch m.type {
            case .`continue`, .stayStraight, .becomes:
                continue
            default:
                break
            }

            let p = pan(m.type)
            let far = m.cueFarMeters.map(Double.init) ?? defaults.far
            let mid = m.cueMidMeters.map(Double.init) ?? defaults.mid
            let near = m.cueNearMeters.map(Double.init) ?? defaults.near
            // Distance the rider covers on the way to this maneuver —
            // `metersToUpcomingManeuver` runs from here down to 0.
            let segLen = maneuvers[i - 1].segmentLengthMeters
            var points: [CuePoint] = []

            // Reassurance just after the previous turn landed. Gated to
            // segments with real room (> 160 m): inside an interchange —
            // a cluster of ramp/merge maneuvers 10–80 m apart — there is
            // no quiet beat for a confirm, and stacking one on top of the
            // next turn's approach cues is exactly the bunching we avoid.
            if i >= 2, segLen > 160,
               let confirm = maneuvers[i - 1].voiceConfirm, !confirm.isEmpty {
                // Fire 10 m past the turn — far enough for GPS to settle
                // onto the new segment, close enough that the rider hears
                // "good, you're on X" while still finishing the turn, not
                // a block later.
                points.append(CuePoint(
                    triggerMeters: max(near + 1, segLen - 10),
                    phrase: confirm, tone: .calm, pan: 0, kind: .confirm))
            }
            // Mid-segment reassurance on the quiet stretch between the
            // post-turn confirm and the far cue. The server's per-
            // maneuver `reaffirm` ("You're on Camelback Road. Heading
            // east.") names the road + compass heading, so it doubles
            // as a position check — spread by *time*, not distance, so
            // the cadence stays right across personas. Target ~75 s
            // between reaffirms; without time data fall back to ~450 m
            // (the historic distance heuristic). Each repeat states
            // the road + heading, so it stays a real confirmation,
            // never filler. Falls back to `keepGoing` if the per-
            // maneuver reaffirm is missing.
            //
            // Why time-based: a fixed 450 m means a pedestrian (1.5
            // m/s) hears reaffirm every 5 minutes — way too long, the
            // rider thinks the app has died. The same 450 m on a
            // scooter (5 m/s) is every 90 s, fine. Scaling by the
            // segment's actual expected speed cures both ends.
            let quietZone = segLen - far
            if quietZone > 120 {
                // Reaffirm spacing in metres = target seconds × this
                // segment's average speed (length / duration). Falls
                // back to 450 m when the server didn't send a duration
                // (e.g. third-party adapters), or to a minimum 150 m
                // for very slow segments so we never schedule a
                // reaffirm every few metres.
                let targetReaffirmSeconds = 75.0
                let segmentSpeedMps: Double = {
                    guard let dur = m.segmentDurationSeconds, dur > 0
                    else { return 0 }
                    return segLen / dur
                }()
                let reaffirmSpacingMeters: Double = segmentSpeedMps > 0
                    ? max(150, targetReaffirmSeconds * segmentSpeedMps)
                    : 450
                if let reaffirm = m.voiceReaffirm, !reaffirm.isEmpty {
                    let n = max(1, min(24, Int(quietZone / reaffirmSpacingMeters)))
                    for k in 1...n {
                        points.append(CuePoint(
                            triggerMeters: far + quietZone * Double(k) / Double(n + 1),
                            phrase: reaffirm, tone: .calm, pan: 0, kind: .reaffirm))
                    }
                } else if let keep = keepGoing, !keep.isEmpty {
                    // Same speed-aware cadence for the keep-going
                    // fallback — bumped up from the prior 1-3 hard cap.
                    let n = max(1, min(8, Int(quietZone / reaffirmSpacingMeters)))
                    for k in 1...n {
                        points.append(CuePoint(
                            triggerMeters: far + quietZone * Double(k) / Double(n + 1),
                            phrase: keep, tone: .calm, pan: 0, kind: .reaffirm))
                    }
                }
            }
            // Mid-segment checkpoint — "You're passing the museum on
            // your right." The server pins it to an offset measured
            // from the PRIOR maneuver; convert to the distance-before-
            // this-maneuver the cue track is keyed on.
            if let checkpoint = m.voiceCheckpoint, !checkpoint.isEmpty,
               let offset = m.checkpointOffsetMeters {
                let trigger = segLen - Double(offset)
                if trigger > near {
                    points.append(CuePoint(
                        triggerMeters: trigger,
                        phrase: checkpoint, tone: .calm, pan: 0, kind: .checkpoint))
                }
            }
            // Approach cues — far / mid / near. Every turn gets all
            // three scheduled. They fire by TIME, not distance:
            // `effectiveTriggerMeters` turns the target seconds-out into
            // metres against the rider's live speed, so the far cue
            // fires ~30 s before the turn, mid ~15 s, near ~3 s — the
            // same lead time at any speed.
            //
            // No build-time gating: the runtime already adapts. On a
            // long approach the three cues land spaced out; on a short
            // interchange segment they cross in the same tick and the
            // runtime speaks only the nearest, so the turn self-collapses
            // to mid+near, or just near. Gating them here only threw away
            // heads-ups the rider should have heard.
            if let phrase = m.voiceFar ?? m.voiceHeadsUp {
                points.append(CuePoint(triggerMeters: far, phrase: phrase,
                                       tone: .normal, pan: p,
                                       triggerSeconds: cueLeadSeconds.far))
            }
            if let phrase = m.voiceMid {
                points.append(CuePoint(triggerMeters: mid, phrase: phrase,
                                       tone: .normal, pan: p,
                                       triggerSeconds: cueLeadSeconds.mid))
            }
            // Near cue — the one cue every turn gets, spoken right at the
            // turn. Just this maneuver's own turn; the chained-turn cue
            // (voiceChained) is intentionally NOT used because it
            // bundled two turns into one breath, which the rider hears
            // as a contradictory command ("Turn right now. Then
            // immediately turn right.").
            //
            // The server's landmark-proxy ALSO bakes the chained suffix
            // straight into `voiceNear` for tight back-to-back turns —
            // strip it so only the immediate turn instruction plays.
            // The next maneuver fires its own far/mid/near naturally a
            // moment later, which sounds vastly cleaner than a single
            // composite sentence.
            if let raw = m.voiceNear ?? m.voiceAtLandmark ?? m.voiceTurnNow {
                // Two-pass sanitization for the near cue, because the
                // server's phrasing is what the rider HEARS at the
                // turn — wrong phrasing here is the most dangerous:
                //   1. stripChainedSuffix — chop "Then immediately…"
                //   2. rewriteBareNearForEyesOff (eyes-off ONLY) —
                //      when there's no landmark anchor at all
                //      ("Turn right now."), swap to ordinal form
                //      ("Take the next right.") which is unambiguous
                //      to a non-looking rider. The rewrite is gated
                //      on `eyesOff` because eyes-on riders see the
                //      street name on the banner and the "onto X"
                //      phrasing is fine.
                let stripped = Self.stripChainedSuffix(raw)
                let phrase = eyesOff
                    ? Self.rewriteBareNearForEyesOff(stripped, type: m.type)
                    : stripped
                points.append(CuePoint(triggerMeters: near, phrase: phrase,
                                       tone: .urgent, pan: p,
                                       triggerSeconds: cueLeadSeconds.near))
            }
            // Order far → near; drop any cue too close behind a more
            // urgent one so two never tread on each other. A fully
            // suppressed maneuver (its turn spoken by the prior chain,
            // its approach too short for far/mid) gets no track at all.
            if !points.isEmpty {
                schedule[i] = spaceCues(points.sorted { $0.triggerMeters > $1.triggerMeters })
            }
        }
        return schedule
    }

    /// `points` come in far → near. Keep the near cue, then keep each
    /// earlier cue only if it leads the last kept one by a speakable gap.
    static func spaceCues(_ points: [CuePoint]) -> [CuePoint] {
        let minGapMeters = 16.0
        var kept: [CuePoint] = []
        for cue in points.reversed() {   // near → far
            if let last = kept.last,
               cue.triggerMeters - last.triggerMeters < minGapMeters {
                continue
            }
            kept.append(cue)
        }
        return kept.reversed()
    }

    /// The Scoova landmark-proxy bakes the chained-turn callout into
    /// `voiceNear` whenever the next maneuver follows within ~100 m:
    ///
    ///   "Turn right now onto X. Then immediately turn right."
    ///   "Turn left now onto Y. Then quickly turn left again."
    ///
    /// Spoken as one sentence it sounds like a contradictory two-action
    /// command and riders flagged it as confusing. Strip every sentence
    /// from "Then …" onward so just the immediate instruction plays;
    /// the next maneuver fires its own far/mid/near cues a moment later,
    /// which the rider hears as a clean second turn.
    ///
    /// Conservative — only matches an English sentence boundary
    /// followed by literally "Then ", which is the proxy's fixed
    /// template. Non-matching phrases (other locales, custom server
    /// overrides) pass through unchanged. Localised forms can be added
    /// here as the proxy's locale coverage grows.
    static func stripChainedSuffix(_ phrase: String) -> String {
        let lower = phrase.lowercased()
        guard let range = lower.range(of: #"[.!?]\s+then\s+"#, options: .regularExpression) else {
            return phrase
        }
        // Keep up to (and including) the punctuation that ends the
        // first clause; drop the " Then …" suffix.
        let endOfFirstClause = phrase.index(phrase.startIndex,
                                            offsetBy: phrase.distance(from: lower.startIndex,
                                                                       to: range.lowerBound) + 1)
        let trimmed = String(phrase[..<endOfFirstClause])
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rewrite bare "Turn X now" / "Turn X now onto STREET" cues into
    /// the eye-off-friendly "Take the next X" pattern. The Scoova
    /// north-star says an eyes-off rider should reach destination on
    /// audio alone — but the server falls back to generic phrasing in
    /// English when it can't synth an ordinal/landmark variant, leaving
    /// a non-looking rider with "turn right now" at a 4-way intersection
    /// with no idea WHICH right. "Take the next right" is unambiguous
    /// even without a landmark anchor: it counts from where the rider
    /// IS, not from some abstract street geometry.
    ///
    /// Only invoked when the layer is built with `landmarks(true)` and
    /// the rider is in eyes-off mode (server-supplied voiceMode flag).
    /// Eyes-on riders see the street name on the banner so the bare
    /// "Turn right onto X" cue is fine.
    static func rewriteBareNearForEyesOff(_ phrase: String, type: ManeuverType) -> String {
        let lower = phrase.lowercased()
        // Direction word for the substitution. If the maneuver type
        // doesn't map cleanly to one of our four buckets, leave the
        // server's phrasing alone.
        let dir: String
        switch type {
        case .left, .slightLeft, .sharpLeft:    dir = "left"
        case .right, .slightRight, .sharpRight: dir = "right"
        case .uturn:                            dir = "U-turn"
        default:                                return phrase
        }
        // Match the proxy's fixed template: an immediate-turn cue with
        // no anchor. We accept the bare form ("Turn right now."), the
        // onto-street form ("Turn right now onto X."), and the
        // possessive form ("Turn right.").
        let bareNear = #"^turn\s+(right|left)(\s+now)?(\s+onto\s+[^.!?]+)?[.!?]?$"#
        let uturnBare = #"^make\s+a\s+u-turn(\s+now)?[.!?]?$"#
        let regex = (type == .uturn) ? uturnBare : bareNear
        guard lower.range(of: regex, options: .regularExpression) != nil else {
            return phrase
        }
        if dir == "U-turn" { return "Make the U-turn here." }
        return "Take the next \(dir)."
    }

    /// The distance-before-the-maneuver at which a cue fires *right now*.
    /// Distance-pinned cues (confirm / reaffirm / checkpoint) use their
    /// fixed `triggerMeters`. Time-pinned cues (far / mid / near) convert
    /// their seconds-out to metres against the live speed — so at 60 km/h
    /// "turn" fires three times farther out than at 20 km/h, and the
    /// rider gets the same seconds to react. Speed is clamped to a sane
    /// envelope (≤ 28 m/s) so a GPS spike can't fling the trigger
    /// absurdly far. When the host hasn't yet reported a speed —
    /// typically the first second or two of the trip before CoreLocation
    /// has settled — `defaultSpeedMps` is used as the fallback. The
    /// default is per-profile (1.4 for pedestrian, 14 for auto, etc.)
    /// because an 8 m/s nominal turned the pedestrian's far cue into a
    /// 240 m fire instead of the natural ~42 m, consuming the cue
    /// before it could be useful.
    static func effectiveTriggerMeters(
        _ cue: CuePoint,
        speedMps: Float?,
        defaultSpeedMps: Double = 8.0
    ) -> Double {
        guard let seconds = cue.triggerSeconds else { return cue.triggerMeters }
        let v = Double(min(28.0, max(0.0, speedMps ?? Float(defaultSpeedMps))))
        return seconds * v
    }

    /// Plausible cruising speed for the persona — used as the cue-trigger
    /// fallback while CoreLocation has not yet reported a speed. Values
    /// are deliberately at the LOW end of each persona's cruise range so
    /// that the cues don't fire too early at trip start.
    static func defaultSpeedMps(for profile: String) -> Double {
        switch profile {
        case "pedestrian":                  return 1.4   // ~5 km/h walk
        case "bicycle":                     return 4.0   // ~14 km/h
        case "scooter":                     return 6.0   // ~22 km/h
        case "motor_scooter", "motorcycle": return 12.0
        default:                            return 14.0  // ~50 km/h urban auto
        }
    }

    /// Decoded polyline for the current route. The reasoner reads it on
    /// every progress tick to map-match the rider onto the route + the
    /// corridor's graph fingerprints. Mirrors what GuidanceMonitor
    /// stores internally; the layer holds the canonical copy so the
    /// reasoner doesn't have to reach into the monitor.
    private var routeShape: [[Double]] = []

    /// The navigator — the state machine the layer reads from on
    /// every progress tick when a corridor + neighbour graph are
    /// available. Replaces the cue scheduler's pre-pinned-distance
    /// approach cues and the guidance monitor's lateral-tripwire
    /// off-route check with real reasoning against the road network.
    private let navigator = NavigatorStateMachine()

    /// Adapter sets the decoded polyline shape so ``GuidanceMonitor`` can
    /// project the rider onto the line for drift / off-route / heading
    /// checks. Call once per route, ideally right after ``onRoute(_:)``.
    /// Also pushes the routing profile so the monitor can pick mode-
    /// aware drift / off-route thresholds — pedestrian on a sidewalk
    /// lives 10–20 m off the routed centerline, the same distance a
    /// car would correctly call "off route."
    public func setRouteShape(_ shape: [[Double]]) {
        self.routeShape = shape
        guidance.setRoute(shape)
        guidance.setCosting(profile)
        // Post-reroute turn-around check: if the just-installed route
        // starts in a direction > 120° off the rider's current bearing,
        // the rider needs to physically turn around to follow it. The
        // navigator's on-route wrong-way detector cannot speak this
        // when the rider's snap is off the new corridor (a common
        // case in the first ~5 s after a reroute), so we say it here.
        // Fires at most once per reroute.
        if pendingRerouteUTurnCheck {
            pendingRerouteUTurnCheck = false
            speakTurnAroundIfRouteBehindRider(shape: shape)
        }
    }

    /// Walk past the snap-correction stub (< 20 m) to find the route's
    /// real intended heading; compare to the rider's last known
    /// bearing; speak the turn-around cue when the delta is > 120°.
    /// Uses the trip-level ``wrongWay`` server phrase so the wording
    /// matches the navigator's own wrong-way cue.
    private func speakTurnAroundIfRouteBehindRider(shape: [[Double]]) {
        guard shape.count >= 2,
              let p = lastProgressForGate,
              let riderBearing = p.bearingDeg else { return }
        let stubThresholdM: Double = 20
        var cumDist: Double = 0
        var firstBrg = GeoMath.bearingDeg(
            shape[0][0], shape[0][1],
            shape[1][0], shape[1][1])
        for i in 1..<shape.count {
            let segDist = GeoMath.haversineMeters(
                shape[i - 1][0], shape[i - 1][1],
                shape[i][0], shape[i][1])
            cumDist += segDist
            if cumDist >= stubThresholdM {
                firstBrg = GeoMath.bearingDeg(
                    shape[0][0], shape[0][1],
                    shape[i][0], shape[i][1])
                break
            }
        }
        let delta = angleDeltaAbs(riderBearing, Float(firstBrg))
        guard delta > 120 else { return }
        let phrase = tripScoovaState?["wrongWay"]
            ?? "Wrong direction — please turn around."
        #if DEBUG
        NSLog("🧭 [navigator] POST-REROUTE TURN-AROUND firstSegBrg=\(Int(firstBrg))° riderBrg=\(Int(riderBearing))° delta=\(Int(delta))°")
        #endif
        saySpoken(phrase, tone: .alert)
    }


    /// Adapter calls this once per route with the trip-level `scoova`
    /// block (server-rendered state-machine vocabulary). Wires the
    /// published `tripScoova` for state-machine surfaces. Pass `nil` for
    /// adapters that don't carry server copy.
    public func onTripScoova(_ trip: TripScoovaState?) {
        self.tripScoova = trip
        // Keep the flat phrase map in sync so `onMotion` can read
        // "good" / "wrongWay" / etc. without re-projecting on every tick.
        self.tripScoovaState = trip?.state
    }

    /// Adapter pushes the parsed `trip.scoova.state` here on route load.
    /// Convenience overload that mirrors the Android `setTripState(Map)`
    /// API for adapters that don't carry a full ``TripScoovaState``.
    public func setTripState(_ state: [String: String]?) {
        self.tripScoovaState = state
    }

    /// Adapter calls this once per route with the parsed ``Corridor``
    /// (or nil when the routing service didn't ship one). Drives the
    /// on-device guidance reasoner — when a corridor is present, the
    /// reasoner generates cues from grammar against the rider's live
    /// position on the road graph; when absent, the SDK falls back to
    /// the legacy baked-string path on each maneuver.
    public func onCorridor(_ corridor: Corridor?) {
        self.corridor = corridor
    }

    /// Adapter / host app calls this on every IMU sensor tick (~10–50 Hz).
    /// The fusion engine smooths heading, detects completed turns, and
    /// flags crash / hard-brake events. Outputs land on:
    ///   * ``compassHeadingDeg`` — for the puck / banner heading indicator
    ///   * ``crashEvents``       — for emergency-contact overlays
    ///
    /// When a detected turn matches the most recent Near-phase cue's
    /// direction (left ↔ right), the layer fires a "Good" confirmation
    /// cue from the trip-level scoova state ("تمام كده" / "Good, you're
    /// on track"). The rider hears reassurance the moment they execute,
    /// without waiting for GPS to catch up — the missing post-turn
    /// affirmation flagged by the SDK audits.
    public func onMotion(_ frame: MotionFrame) {
        let state = motionFusion.process(frame: frame)
        if let h = state.headingDeg {
            compassHeadingDeg = h
            guidance.onCompassHeading(h)
        }
        if let c = state.crash {
            crashEvents.send(c)
        }
        if let turnDeg = state.turnDeg {
            guard let expected = pendingTurnDirection else { return }
            let now = frame.tsMs
            if now - pendingTurnFiredAtMs > turnConfirmWindowMs {
                pendingTurnDirection = nil
                pendingTurnManeuverIdx = nil
                return
            }
            let actual: TurnDir = turnDeg > 0 ? .left : .right
            if actual == expected && abs(turnDeg) > 30 {
                // Fix B: confirm cue must wait until the rider has
                // actually passed the turn point — a yaw spike WHILE
                // approaching (course correction at the intersection,
                // side-glance, hand signal) would otherwise pat the
                // rider on the back before they've executed. Gate on
                // the cursor having advanced past the maneuver that
                // armed this confirm.
                if let armedIdx = pendingTurnManeuverIdx,
                   let currentUpcoming = lastProgressForGate?.upcomingManeuverIndex,
                   currentUpcoming <= armedIdx {
                    // Cursor hasn't advanced past the armed maneuver
                    // yet — the rider is still approaching, not past.
                    return
                }
                // Confirmed — fire "Good" from server state copy if set.
                if let good = tripScoovaState?["good"], !good.isEmpty {
                    saySpoken(good, tone: .cheerful)
                }
                if let mIdx = pendingTurnManeuverIdx {
                    confirmedTurnManeuvers.insert(mIdx)
                }
                pendingTurnDirection = nil
                pendingTurnManeuverIdx = nil
            }
        }
    }

    /// Maps a maneuver type to the direction the rider is expected to
    /// yaw. Returns nil for non-turning maneuvers (depart / arrive /
    /// continue) — those don't produce a yaw signature.
    private func expectedTurnDir(_ type: ManeuverType) -> TurnDir? {
        switch type {
        case .left, .sharpLeft, .slightLeft,
             .rampLeft, .exitLeft, .stayLeft,
             .roundaboutEnter:  // best guess for roundabout
            return .left
        case .right, .sharpRight, .slightRight,
             .rampRight, .exitRight, .stayRight:
            return .right
        case .uturn:
            // U-turns are full-180 either way; we don't enforce side.
            return .left
        default:
            return nil
        }
    }

    /// Adapter calls on every host-SDK route-progress update (1-4 Hz).
    public func onProgress(_ p: ProgressEvent) {
        guard !maneuvers.isEmpty else { return }
        // Preview gate. The host loads a route + a polyline (drawn on
        // the map) before the rider taps Start Navigation. Until
        // ``setActive(true)`` is called we accept locations silently
        // so the polyline can be drawn, but emit no cues and run no
        // reactive guidance. Without this, the welcome cue fires the
        // instant the first GPS fix arrives during preview.
        guard isActive else { return }
        // GPS-staleness watchdog heartbeat: every tick proves the feed
        // is live. The watchdog flips ``gpsLost`` back to false here so
        // the banner clears the moment a fix lands.
        lastProgressAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        if gpsLost { gpsLost = false }
        // Publish destination distance + ETA so the banner can bind
        // without owning the ProgressEvent itself.
        if metersRemaining != p.metersRemaining { metersRemaining = p.metersRemaining }
        if secondsRemaining != p.secondsRemaining { secondsRemaining = p.secondsRemaining }
        // Course-when-moving heading (P1.9). When GPS reports a course
        // and the rider is moving, override the compass-sourced heading
        // with the bearing-of-travel — that's what the puck should
        // point. The CL stream still fires `guidance.onCompassHeading`
        // so the standstill wrong-way check has compass data; only the
        // PUBLISHED `headingDeg` for the puck swaps to GPS course.
        if let bearing = p.bearingDeg, bearing >= 0, bearing <= 360,
           let speed = p.speedMps, speed >= courseHeadingMinSpeedMps {
            headingDeg = bearing
            movingHeadingValidUntilMs = lastProgressAtMs + courseHeadingHoldMs
        }
        // Cache for silence-filler verbal cue — see handleGuidanceEvent.
        latestMetersRemaining = p.metersRemaining
        latestMetersToUpcomingManeuver = Int(p.metersToUpcomingManeuver.rounded())
        lastProgressForGate = p
        // Reasoner tick — produce the one coherent answer downstream
        // systems read from. Stored AND published so the host can bind
        // to it (debug UIs, instrumentation), AND so the cue speaker
        // below sees the latest decision context.
        let newState = GuidanceReasoner.reason(
            p, route: maneuvers, corridor: corridor, shape: routeShape
        )
        liveState = newState
        // Snap visibility — every tick (no throttle). Throttled logs
        // hide bugs at intersections where the snap can flip between
        // way IDs in a single second. See product memory:
        // `log-every-point-during-ride`.
        #if DEBUG
        if let snap = newState.snap {
            let onRouteTag = newState.isOnRouteWay ? "ON-ROUTE" : "OFF-ROUTE"
            let courseTag = snap.courseMatchesForward.map { $0 ? "fwd" : "rev" } ?? "?"
            NSLog("🧷 [snap] way=\(snap.wayId) name=\(snap.name.isEmpty ? "?" : snap.name) lateral=\(Int(snap.lateralM))m segBrg=\(Int(snap.segmentBearingDeg))° course=\(courseTag) oneway=\(snap.oneway) → \(onRouteTag)")
        } else if corridor?.neighbourGraph.isEmpty == false {
            // Graph present but snap returned nil — rider is OUTSIDE
            // the 25 m snap window of every neighbour way. That's a
            // strong signal something's wrong; log so we can see it.
            NSLog("🧷 [snap] NO MATCH (rider > 25 m from every neighbour way)")
        }
        #endif
        // Feed the alignment into the guidance monitor so off-route +
        // wrong-way checks can prefer graph-topology signals over the
        // lateral-distance / polyline-bearing heuristics. Nil when no
        // corridor was shipped — the monitor then falls back to the
        // legacy rules untouched.
        guidance.setLiveAlignment(
            corridor != nil ? newState.alignment : nil,
            graphMatched: newState.segmentOnGraph != nil
        )
        // ── Navigator state machine ──────────────────────────────────
        // When a neighbour graph is in play, the state machine is the
        // primary cue source for approach / off-route / wrong-way /
        // past-destination. It uses real map-matching against the
        // OSM ways around the rider, not polyline distance. We still
        // run the legacy cue scheduler + guidance monitor in parallel
        // but suppress their approach/off-route/wrong-way cues when
        // the navigator already spoke for them.
        let useNavigator = (corridor?.neighbourGraph.isEmpty == false)
        // Welcome must always be the FIRST thing the rider hears on a
        // new route. We run it BEFORE the navigator so a reactive
        // off-route / wrong-way intent doesn't beat it to the voice
        // queue on the same tick. Without this, the rider got
        // "Looks like you went off route" 1 ms before "Let's go..."
        // — they'd never know whether the route they were starting
        // on was the right one in the first place.
        let wasWelcomed = welcomed
        if !welcomed {
            NSLog("🟢 [Nav] firing WELCOME (isActive=\(isActive), maneuvers=\(maneuvers.count), routeEyesOff=\(routeEyesOff))")
            welcomed = true
            // Prefer server-rendered welcome — fall back to the hardcoded
            // distance-bearing phrase when no scoova block was forwarded.
            let serverWelcome = tripScoovaState?["welcomeFull"]
                ?? tripScoovaState?["welcome"]
            let phrase: String
            if let serverWelcome = serverWelcome, !serverWelcome.isEmpty {
                phrase = serverWelcome
            } else if routeEyesOff {
                // Eye-on-the-road: the metre-based welcomeText
                // ("Your trip is 400 meters, 1 minute, with 3 turns.
                // Heading south.") violates the BANNED list (metres,
                // minutes, cardinals). When the server didn't ship a
                // welcome, fall back to a minimal eyes-off phrase
                // rather than violate the contract. See
                // [[feedback-eyesoff-cue-grammar]].
                phrase = "Let's go."
            } else {
                phrase = welcomeText(lang: locale, distanceKm: Double(p.metersRemaining) / 1000)
            }
            saySpoken(phrase, tone: .calm)
        }

        // ── Navigator state machine ──────────────────────────────────
        // Runs AFTER welcome so the rider always hears "Let's go..."
        // first on a new trip. The state machine emits cue intents at
        // state transitions and ScoovaNavLayer maps them to spoken
        // text via the grammar. Owns approach / off-route / wrong-way
        // / past-destination / stuck-in-traffic / checkpoint when the
        // corridor has a neighbour graph.
        if useNavigator {
            let nowMsForNav = lastProgressAtMs
            let upcomingIdx = max(0, min(p.upcomingManeuverIndex,
                                         maneuvers.count - 1))
            let upcomingForNav = maneuvers.indices.contains(upcomingIdx)
                ? maneuvers[upcomingIdx] : nil
            // Pass physical rider position + destination + bearing so
            // the past-destination check can verify the rider is
            // ACTUALLY past the destination (bearing-to-dest > 110°
            // off rider's current bearing) instead of just "near the
            // end of a tiny polyline projection."
            let destCoord = maneuvers.last.map {
                ($0.latitude, $0.longitude)
            }
            let intents = navigator.tick(
                live: newState,
                upcoming: upcomingForNav,
                metersRemainingToDestination: p.metersRemaining,
                arrivedLatched: arrived,
                speedMps: p.speedMps,
                riderLat: p.latitude,
                riderLon: p.longitude,
                riderBearingDeg: p.bearingDeg,
                destLat: destCoord?.0,
                destLon: destCoord?.1,
                nowMs: nowMsForNav
            )
            // Suppress reactive intents (off-route / wrong-way / etc.)
            // on the SAME tick the welcome cue fired — the rider
            // shouldn't hear an alert before they've heard the trip
            // start. Approach + confirm + checkpoint can still fire
            // because they relate to the upcoming maneuver, not a
            // problem the rider can act on at trip start.
            for intent in intents {
                if !wasWelcomed {
                    switch intent {
                    case .offRoute, .wrongWay, .pastDestination,
                         .stuckInTraffic:
                        continue
                    default: break
                    }
                }
                _ = speakNavigatorIntent(intent, p: p, live: newState)
            }
        }

        let idx = max(0, min(p.upcomingManeuverIndex, maneuvers.count - 1))
        let maneuver = maneuvers[idx]
        let dist = p.metersToUpcomingManeuver

        // Banner — the upcoming maneuver's server-rendered copy. `phase`
        // is a coarse far/mid/near hint kept for any UI bound to it.
        let phase: CuePhrases.Phase =
            dist > cueDefaults.mid ? .far : (dist > cueDefaults.near ? .mid : .near)
        let text = maneuver.voiceTurnNow
            ?? CuePhrases.build(
                lang: locale, maneuver: maneuver,
                firedThresholdM: -1, thresholdsMeters: [], landmark: nil
            )
        currentInstruction = DisplayCue(
            maneuver: maneuver,
            metersToManeuver: dist,
            phase: phase,
            text: text
        )

        // Lane + speed-limit surfaces (P2.12+13). Only publish when
        // the value actually changes — Combine subscribers don't need
        // 4 emits per second of the same array.
        if currentLanes != maneuver.lanes { currentLanes = maneuver.lanes }
        if currentSpeedLimitKph != maneuver.speedLimitKph {
            currentSpeedLimitKph = maneuver.speedLimitKph
        }

        // ── Following instruction (P1.11) ────────────────────────────
        // The maneuver AFTER the upcoming one — the "then in 200 m turn
        // left" line that goes under the primary banner on city
        // interchanges. We surface it as a DisplayCue with the rider's
        // total distance via the upcoming maneuver, which the host can
        // render below the main banner or hide on long single-turn
        // segments. Skipped at the very end of the trip when there's
        // no further turn left.
        if idx + 1 < maneuvers.count {
            let following = maneuvers[idx + 1]
            // Skip non-turn followups (continue / becomes / stayStraight)
            // — they're not actionable for the rider, so showing them
            // as a "next" would just be noise.
            switch following.type {
            case .`continue`, .stayStraight, .becomes, .arrive:
                followingInstruction = nil
            default:
                // Valhalla convention: `maneuvers[idx].segmentLengthMeters`
                // is the OUTBOUND segment from the upcoming maneuver,
                // i.e. the distance from upcoming to over-next.
                let outboundFromUpcoming = maneuver.segmentLengthMeters
                let distToFollowing = dist + outboundFromUpcoming
                let followingText = following.voiceTurnNow
                    ?? CuePhrases.build(
                        lang: locale, maneuver: following,
                        firedThresholdM: -1, thresholdsMeters: [], landmark: nil)
                followingInstruction = DisplayCue(
                    maneuver: following,
                    metersToManeuver: distToFollowing,
                    phase: .far,
                    text: followingText
                )
            }
        } else {
            followingInstruction = nil
        }

        // ── Cue track ────────────────────────────────────────────────
        // Speak the server's pinned cues like subtitles. Each cue fires
        // once, the moment the rider reaches its trigger — a fixed
        // distance for confirm / reaffirm / checkpoint, but a speed-
        // scaled distance (constant seconds-out) for the far / mid /
        // near approach cues. At most one cue per tick; when several
        // cross together the nearest one supersedes the rest.
        //
        // When the navigator state machine is in play it owns ALL of
        // the approach + confirm + reaffirm + checkpoint cues, so the
        // legacy scheduler does not run AT ALL. The previous gate
        // checked whether the navigator's `saySpoken` returned true
        // — but `voice.say` returns false whenever a higher-priority
        // cue is currently speaking, even though the navigator
        // intended to handle the tick. Result: rider heard every cue
        // twice. The new gate is intent-based: corridor has neighbour
        // graph ⇒ navigator owns the cue path, period.
        if !useNavigator, let points = cueSchedule[idx] {
            var fired = cueFired[idx] ?? []
            var toSpeak: CuePoint?
            var nearest = Double.greatestFiniteMagnitude
            let fallbackSpeed = Self.defaultSpeedMps(for: profile)
            for (ci, cue) in points.enumerated() where !fired.contains(ci) {
                let trigger = Self.effectiveTriggerMeters(
                    cue, speedMps: p.speedMps, defaultSpeedMps: fallbackSpeed)
                if dist <= trigger {
                    fired.insert(ci)                  // crossed — consumed
                    if trigger <= nearest { nearest = trigger; toSpeak = cue }
                }
            }
            cueFired[idx] = fired
            if let cue = toSpeak,
               // Precondition: the maneuver this cue is about must be
               // geometrically ahead of the rider. The polyline-driven
               // trigger fires when `dist <= trigger`, but `dist`
               // clamps at the route end — a rider physically past
               // the turn or going the wrong way still reads
               // dist=99 m and triggers the approach cue. The cue
               // text ("Turn left in 100 m") is nonsense in that
               // state. Skip; let the missed-turn / wrong-way intent
               // own the recovery.
               coordIsAhead(
                   lat: maneuver.latitude, lon: maneuver.longitude,
                   rider: p) {
                voice.markThresholdCrossed()  // last-cue-latency diagnostic
                // The urgent (near) cue asks the rider to act now — arm
                // yaw confirmation for `onMotion`. Remember WHICH
                // maneuver armed the confirm so Fix B can gate the
                // "Good" cue on the cursor having advanced past it.
                if cue.tone == .urgent {
                    pendingTurnDirection = expectedTurnDir(maneuver.type)
                    pendingTurnFiredAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    pendingTurnManeuverIdx = maneuver.index
                    lastArmedTurnManeuverIdx = maneuver.index
                }
                // A reaffirm fired on a long quiet stretch carries the
                // live distance-to-destination, so the rider gets a real
                // progress check — "…heading south. 19 kilometers to your
                // destination." — instead of minutes with no sense of how
                // far is left.
                var phrase = cue.phrase
                if cue.kind == .reaffirm {
                    // Distance to the NEXT TURN, not destination — so
                    // the voice number matches the banner exactly. A
                    // mismatched "812 m" banner + "1.4 km" voice reads
                    // as a bug to the rider.
                    phrase = appendDistanceToNextTurn(
                        phrase, lang: locale,
                        metersToTurn: Int(p.metersToUpcomingManeuver.rounded()))
                } else if cue.kind == .approach {
                    // Corridor-aware grammar overrides the baked
                    // string. The phase that fired (far / mid / near)
                    // determines the rule ladder — far + mid stay
                    // distance-led, only near commits to ordinal /
                    // landmark / next-confirmed forms. Without phase
                    // awareness the rider hears the same sentence
                    // three times in a row for one maneuver.
                    let phase: CueGrammar.Phase = {
                        if cue.tone == .urgent { return .near }
                        if let s = cue.triggerSeconds, s >= 25 { return .far }
                        return .mid
                    }()
                    if routeEyesOff {
                        // Eye-on-the-road: the server's voiceFar/voiceMid/
                        // voiceNear strings ARE already landmark-led and
                        // measurement-free (the proxy renders eyes-off
                        // copy when voiceMode=eyes_off is requested).
                        // Bypass the grammar entirely so the SDK doesn't
                        // replace "After McDonald's, turn right" with
                        // "Turn right in 80 metres" — that violation is
                        // exactly the bug observed in the 2026-05-29 log.
                        phrase = cue.phrase
                        #if DEBUG
                        NSLog("🧠 [grammar] phase=\(phase) eyesOff=true → server-rendered phrase preserved")
                        #endif
                    } else if let state = newState.upcomingDecision,
                       corridor != nil {
                        let effLm = effectiveLandmark(for: maneuver, rider: p)
                        let chosen = CueGrammar.chooseCue(
                            decision: state,
                            phase: phase,
                            locale: locale,
                            landmark: effLm,
                            fallback: cue.phrase
                        )
                        phrase = chosen.text
                        #if DEBUG
                        let lmTag: String = {
                            if let lm = maneuver.landmark, !lm.isEmpty {
                                return effLm == nil ? "\(lm)(behind)" : lm
                            }
                            return "_"
                        }()
                        NSLog("🧠 [grammar] phase=\(phase) rule=\(chosen.rule) lm=\(lmTag) ord=\(state.ordinal.map{"\($0)"} ?? "_")/\(state.totalSameSideTurns.map{"\($0)"} ?? "_") → %@", phrase)
                        #endif
                    } else {
                        // Legacy path: rewrite the baked "In N meters"
                        // prefix to the LIVE distance so the voice
                        // number matches the banner. Without the
                        // corridor we can't do better.
                        phrase = rewriteEmbeddedDistance(
                            phrase, lang: locale,
                            liveMeters: Int(p.metersToUpcomingManeuver.rounded()))
                    }
                }
                saySpoken(phrase, tone: cue.tone, spatialPan: cue.pan)
            }
        }

        // ── Arrival ──────────────────────────────────────────────────
        // The trip ends one of two ways, whichever lands first:
        //   1. The rider rolls inside the arrival radius (30 m of route
        //      remaining).
        //   2. The rider goes still (< 2.5 km/h) for 6 s within the
        //      wider 70 m radius — a rider who parks at the kerb, or
        //      whose GPS settles a little short of the pin, still gets a
        //      clean arrival. WITHOUT this the trip never concludes:
        //      guidance keeps running and the standstill heading-
        //      mismatch check false-fires an endless "wrong way, turn
        //      around" at a rider who has simply arrived.
        // Latched via `arrived` so the cue speaks exactly once.
        let nearLastManeuver = idx >= maneuvers.count - 2
        // Bug V: false ARRIVED on parallel/wrong road. `p.metersRemaining`
        // is polyline-derived and clamps to ~0 once the rider's projection
        // hits the last vertex — so a rider 60 m sideways on a parallel
        // street, or 200 m past the destination on the same bearing,
        // reads metersRemaining≈0 and the arrival cue fires while the
        // rider is nowhere near the destination AND on the wrong road.
        // Gate the arrival cue on physical haversine distance AND
        // (when a snap is available) on the rider's current way
        // belonging to the route corridor.
        let physicallyAtDestination: Bool = {
            guard let dLat = maneuvers.last?.latitude,
                  let dLon = maneuvers.last?.longitude else {
                return true
            }
            let physDist = GeoMath.haversineMeters(
                p.latitude, p.longitude, dLat, dLon)
            if physDist > Double(arriveStopRadiusM) { return false }
            if newState.snap != nil && !newState.isOnRouteWay {
                return false
            }
            return true
        }()
        if !arrived && nearLastManeuver && physicallyAtDestination {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let withinArriveRadius = p.metersRemaining < arriveRadiusM
            let parkedNearDest = p.metersRemaining < arriveStopRadiusM
                && (p.speedMps ?? 0) < arriveStopSpeedMps
            if parkedNearDest {
                if stoppedNearDestSinceMs == 0 { stoppedNearDestSinceMs = now }
            } else {
                stoppedNearDestSinceMs = 0
            }
            let dwellSatisfied = stoppedNearDestSinceMs != 0
                && now - stoppedNearDestSinceMs >= arriveStopDwellMs
            if withinArriveRadius || dwellSatisfied {
                arrived = true
                // Rich server copy carries the destination side
                // ("…on your right"); fall back to hardcoded text.
                let phrase = tripScoovaState?["arrivedFull"]
                    ?? tripScoovaState?["arrived"]
                    ?? arrivedText(lang: locale)
                saySpoken(phrase, tone: .cheerful)
            }
        }

        // ── Continuous closed-loop guidance ──────────────────────────
        // Drift / off-route / heading-mismatch / speed / silence /
        // almost-there. The monitor runs its own timers; we just play
        // whatever it tells us to. Phrases come from the server-side
        // `trip.scoova.state` block — copy stays in lockstep across SDKs.
        //
        // Suppressed once the rider is at the destination — arrived, or
        // inside the arrival zone slowing to a stop. Closed-loop
        // guidance is for the journey, not the doorstep: a rider
        // stopping, dismounting, or turning the phone to pocket it would
        // otherwise trip the standstill heading-mismatch check and hear
        // "wrong way, turn around" on a loop after they have arrived.
        // Past-destination guard. `p.metersRemaining` is derived from
        // the rider's projection along the route polyline, so it CAPS
        // at zero once the projection clamps to the last vertex. A
        // rider who drove past the destination 200 m east keeps reading
        // metersRemaining≈0 even though they're physically far away.
        // Without the lateral gate, the SDK kept declaring "at
        // destination" and silently disabled off-route / wrong-way
        // detection for the rest of the ride. The gate requires lateral
        // proximity to the polyline as proof the rider really is at
        // the destination, not just past its perpendicular.
        let lateralFromReasoner = liveState?.alignment.lateralM
        let lateralOK = (lateralFromReasoner ?? 0) <= 80
        // Bug V: same suppression bug as the arrival cue. A rider on a
        // parallel road within the 80 m lateral band but on a way that's
        // NOT in the route corridor must NOT have off-route/wrong-way
        // detection silenced. When we have a snap, require on-route.
        let snapOnRouteOrAbsent = newState.snap == nil
            || newState.isOnRouteWay
        let atDestination = arrived
            || (nearLastManeuver && p.metersRemaining < arriveStopRadiusM
                && lateralOK && snapOnRouteOrAbsent)
        if !atDestination {
            // Bug W/X: legacy GuidanceMonitor cues (almostThere, drift)
            // run off polyline projection. When the rider is OFF-ROUTE
            // (snap on a way not in the route corridor), those cues are
            // meaningless — "you're drifting left" or "destination just
            // ahead" makes no sense when the rider is on the wrong road.
            // Suppress them when the navigator state machine is active
            // and the snap proves we're off-corridor.
            let offCorridor = useNavigator
                && newState.snap != nil
                && !newState.isOnRouteWay
            for event in guidance.onProgress(p) {
                // When the navigator state machine is the primary
                // cue source (neighbour graph in play), suppress the
                // legacy reactive events it already covers so the
                // rider doesn't hear the same situation announced
                // twice with different phrasing.
                if useNavigator {
                    switch event {
                    case .offRoute, .softOffRoute, .wrongWayHeading:
                        continue
                    case .driftLeft, .driftRight, .almostThere:
                        if offCorridor { continue }
                    case .keepGoing, .slowDown:
                        break
                    }
                }
                handleGuidanceEvent(event, maneuver: maneuver)
            }
        }
    }

    /// Map a navigator state-machine intent to actual spoken text and
    /// play it. Returns `true` when something was spoken — the caller
    /// uses that to suppress the legacy cue scheduler for this tick.
    /// Off-route intents also fire the reroute request.
    private func speakNavigatorIntent(
        _ intent: NavigatorStateMachine.CueIntent,
        p: ProgressEvent,
        live: LiveGuidanceState
    ) -> Bool {
        switch intent {
        case .welcome:
            // Existing welcome path owns this — never duplicate.
            return false
        case .arrived:
            // Same as welcome — existing arrival path owns the cue.
            return false
        case .approach(let phase, let mIdx):
            guard maneuvers.indices.contains(mIdx),
                  let decision = live.upcomingDecision else { return false }
            let m = maneuvers[mIdx]
            let bakedFallback = phaseFallbackText(for: m, phase: phase)
            let tone: CueTone = (phase == .near) ? .urgent : .normal
            let pan = panFor(m.type)
            // Arm the gyro-based confirm so onMotion can fire "Good"
            // once the rider's yaw matches the expected direction AND
            // the cursor advances past the turn. Without this the
            // navigator path never confirmed (only the legacy path
            // did) so the standalone "Good" cue was effectively
            // dead on routes with a corridor.
            if phase == .near {
                pendingTurnDirection = expectedTurnDir(m.type)
                pendingTurnFiredAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                pendingTurnManeuverIdx = m.index
                lastArmedTurnManeuverIdx = m.index
            }
            if routeEyesOff {
                // Eye-on-the-road: the proxy already rendered an
                // eyes-off-compliant string (landmark-led, no metres /
                // street names / cardinals) into voiceFar/voiceMid/
                // voiceNear. Speak that verbatim. If the server
                // shipped nothing for this phase, stay SILENT — eyes-
                // off bans the SDK's metre-based fallback. See
                // [[cue-preconditions-are-coords]] /
                // [[eyesoff-cue-grammar]].
                guard let phrase = bakedFallback, !phrase.isEmpty
                else {
                    #if DEBUG
                    NSLog("🧭 [navigator] approach phase=\(phase) eyesOff=true server-rendered ABSENT — staying silent (no metre fallback)")
                    #endif
                    return false
                }
                #if DEBUG
                NSLog("🧭 [navigator] approach phase=\(phase) eyesOff=true → %@", phrase)
                #endif
                return saySpoken(phrase, tone: tone, spatialPan: pan)
            }
            let effLm = effectiveLandmark(for: m, rider: p)
            let chosen = CueGrammar.chooseCue(
                decision: decision,
                phase: phase,
                locale: locale,
                landmark: effLm,
                fallback: bakedFallback
            )
            #if DEBUG
            let lmTag: String = {
                if let lm = m.landmark, !lm.isEmpty {
                    return effLm == nil ? "\(lm)(behind)" : lm
                }
                return "_"
            }()
            NSLog("🧭 [navigator] approach phase=\(phase) rule=\(chosen.rule) lm=\(lmTag) → %@", chosen.text)
            #endif
            return saySpoken(chosen.text, tone: tone, spatialPan: pan)
        case .offRoute(let name):
            // Ask the host for a fresh route. The adapter throttles
            // the actual fetch to 1/8 s — so if we just got a route
            // less than 8 s ago, the fetch will be blocked. In that
            // case we DO NOT speak "Recalculating" because nothing
            // will recalculate — the rider perceives that as a lie.
            // We still call onRerouteNeeded (no-op if throttled, but
            // keeps the adapter informed for diagnostics).
            onRerouteNeeded?()
            rerouteRequestedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            let nowMs = rerouteRequestedAtMs
            let willBeThrottled = lastRerouteLandedAtMs > 0
                && (nowMs - lastRerouteLandedAtMs) < rerouteFetchThrottleMs
            if willBeThrottled {
                #if DEBUG
                NSLog("🧭 [navigator] OFF-ROUTE snappedWay=\(name) — fetch throttled, cue suppressed")
                #endif
                return false
            }
            #if DEBUG
            NSLog("🧭 [navigator] OFF-ROUTE snappedWay=\(name)")
            #endif
            // Maneuver-specific recover phrase if available, else
            // trip-level rerouting copy, else a default English line.
            let upcoming = maneuvers.indices.contains(p.upcomingManeuverIndex)
                ? maneuvers[p.upcomingManeuverIndex] : nil
            let phrase = upcoming?.voiceRecover
                ?? tripScoovaState?["rerouting"]
                ?? "Looks like you went off route. Recalculating."
            return saySpoken(phrase, tone: .alert)
        case .wrongWay(let name):
            // Wrong-way ALSO triggers the reroute (not just the
            // cue). If the rider is going the wrong direction on
            // the route's expected way, we want a fresh route
            // computed from their actual heading — not to wait for
            // off-route to fire on the next OSM way change. With
            // wrong-way triggering reroute, off-route can suppress
            // its cue when wrong-way fired recently (Bug Q fix).
            onRerouteNeeded?()
            rerouteRequestedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            #if DEBUG
            NSLog("🧭 [navigator] WRONG-WAY on \(name)")
            #endif
            let phrase = tripScoovaState?["wrongWay"]
                ?? "Wrong way. Please turn around."
            return saySpoken(phrase, tone: .alert)
        case .pastDestination:
            // Drove past the pin without arriving — explicit alert.
            // Past-dest does NOT auto-reroute (the rider may be
            // parking around the corner); the cue is enough.
            #if DEBUG
            NSLog("🧭 [navigator] PAST-DESTINATION")
            #endif
            let phrase = tripScoovaState?["pastDestination"]
                ?? "You've passed your destination. It's behind you."
            return saySpoken(phrase, tone: .alert)
        case .missedTurn(let mIdx):
            // Trigger the reroute fetch (subject to the adapter's
            // throttle). If the throttle WILL block the fetch — i.e.
            // a route landed less than 8 s ago — DON'T speak
            // "Recalculating" because nothing will recalculate. The
            // rider hearing "Recalculating" while nothing happens is
            // a lie. Same logic as off-route (Bug H fix).
            onRerouteNeeded?()
            rerouteRequestedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            let nowMs = rerouteRequestedAtMs
            let willBeThrottled = lastRerouteLandedAtMs > 0
                && (nowMs - lastRerouteLandedAtMs) < rerouteFetchThrottleMs
            if willBeThrottled {
                #if DEBUG
                NSLog("🧭 [navigator] MISSED-TURN at mnv #\(mIdx) — fetch throttled, cue suppressed")
                #endif
                return false
            }
            #if DEBUG
            NSLog("🧭 [navigator] MISSED-TURN at mnv #\(mIdx)")
            #endif
            let upcoming = maneuvers.indices.contains(mIdx)
                ? maneuvers[mIdx] : nil
            let phrase = upcoming?.voiceRecover
                ?? tripScoovaState?["missedTurn"]
                ?? tripScoovaState?["rerouting"]
                ?? "You missed the turn. Recalculating."
            return saySpoken(phrase, tone: .alert)
        case .confirm(let mIdx):
            guard maneuvers.indices.contains(mIdx),
                  let confirm = maneuvers[mIdx].voiceConfirm,
                  !confirm.isEmpty else { return false }
            return saySpoken(confirm, tone: .calm)
        case .checkpoint(let mIdx):
            guard maneuvers.indices.contains(mIdx),
                  let phrase = maneuvers[mIdx].voiceCheckpoint,
                  !phrase.isEmpty else { return false }
            #if DEBUG
            NSLog("🧭 [navigator] CHECKPOINT %@", phrase)
            #endif
            return saySpoken(phrase, tone: .calm)
        case .reaffirm(let mIdx):
            // "Still on Camelback Road. 600 m to your next turn."
            // Prefer the maneuver's server-rendered reaffirm; fall
            // back to a snap-name + distance composition so a route
            // without per-maneuver reaffirm still gets the cue.
            let m = maneuvers.indices.contains(mIdx) ? maneuvers[mIdx] : nil
            let wayName = liveState?.snap?.name ?? ""
            let metersToTurn = Int(p.metersToUpcomingManeuver.rounded())
            let base = m?.voiceReaffirm
                ?? (wayName.isEmpty
                    ? "You're still on track."
                    : "Still on \(wayName).")
            let phrase = appendDistanceToNextTurn(
                base, lang: locale, metersToTurn: metersToTurn)
            #if DEBUG
            NSLog("🧭 [navigator] REAFFIRM %@", phrase)
            #endif
            return saySpoken(phrase, tone: .calm)
        case .stuckInTraffic:
            #if DEBUG
            NSLog("🧭 [navigator] STUCK-IN-TRAFFIC")
            #endif
            let phrase = tripScoovaState?["stuckInTraffic"]
                ?? "Still on track. Stay on this road."
            return saySpoken(phrase, tone: .calm)
        case .ambiguityHeadsUp(let mIdx):
            guard maneuvers.indices.contains(mIdx),
                  let dec = live.upcomingDecision,
                  let total = dec.totalSameSideTurns, total > 1,
                  let ord = dec.ordinal else { return false }
            // "Two lefts ahead — take the SECOND one." Composed from
            // grammar primitives so it localizes alongside the
            // approach cues.
            let m = maneuvers[mIdx]
            let phrase = ambiguityHeadsUpPhrase(
                type: m.type, total: total, ordinal: ord, locale: locale)
            #if DEBUG
            NSLog("🧭 [navigator] HEADS-UP %@", phrase)
            #endif
            return saySpoken(phrase, tone: .normal)
        }
    }

    /// Localized "N lefts/rights ahead — take the [Nth] one."
    private func ambiguityHeadsUpPhrase(
        type: ManeuverType, total: Int, ordinal: Int, locale: String
    ) -> String {
        let lc = locale.lowercased()
        let isArabic = lc.hasPrefix("ar")
        let isLeft = type.isLeftSide
        if isArabic {
            let side = isLeft ? "شمالات" : "يمينات"
            let ord = ["", "الأول", "التاني", "التالت", "الرابع", "الخامس"]
            let ordWord = (ordinal < ord.count) ? ord[ordinal] : "\(ordinal)"
            return "في \(total) \(side) قدامك. خد ال\(isLeft ? "شمال" : "يمين") \(ordWord)."
        }
        let side = isLeft ? "lefts" : "rights"
        let ords = ["", "first", "second", "third", "fourth", "fifth"]
        let ordWord = (ordinal < ords.count) ? ords[ordinal] : "\(ordinal)th"
        let singleSide = isLeft ? "left" : "right"
        return "\(total) \(side) ahead — take the \(ordWord) \(singleSide)."
    }

    /// Pre-baked text the grammar uses as the `fallback` argument when
    /// none of its rules apply — typically the server's per-phase
    /// voice copy for this maneuver.
    private func phaseFallbackText(for m: ManeuverEvent, phase: CueGrammar.Phase) -> String? {
        switch phase {
        case .far:  return m.voiceFar ?? m.voiceHeadsUp
        case .mid:  return m.voiceMid ?? m.voiceGetReadyTemplate
        case .near: return m.voiceNear ?? m.voiceTurnNow
        }
    }

    /// Resolve the effective landmark for cue grammar. Returns the
    /// name when the landmark coordinate is geometrically ahead of
    /// the rider, nil when behind/abreast — forcing the grammar to
    /// fall through to the distance form. A cue that says "After
    /// <X>" or "Turn left at <X>" makes no sense when <X> is already
    /// behind the rider. Applied at both mid + near phases.
    ///
    /// Fallback when no landmark coordinate: pass the name through
    /// — server selected it, no data to disagree with.
    /// Fallback when no rider bearing: pass the name through (see
    /// ``coordIsAhead`` for the rationale).
    /// See [[cue-preconditions-are-coords]].
    private func effectiveLandmark(
        for m: ManeuverEvent, rider p: ProgressEvent
    ) -> String? {
        guard let name = m.landmark, !name.isEmpty else { return nil }
        guard let lLat = m.landmarkLat, let lLon = m.landmarkLon
        else { return name }
        return coordIsAhead(lat: lLat, lon: lLon, rider: p) ? name : nil
    }

    /// Coordinate-ahead precondition used by every cue that references
    /// a specific place. Delegates to the navigator's helper so the
    /// two paths can never disagree. Pass-through when bearing is
    /// untrusted (stationary, low speed) — cues fire at trip start.
    private func coordIsAhead(
        lat: Double, lon: Double, rider p: ProgressEvent
    ) -> Bool {
        navigator.coordIsAhead(
            lat: lat, lon: lon,
            riderLat: p.latitude, riderLon: p.longitude,
            riderBearingDeg: p.bearingDeg,
            speedMps: p.speedMps
        )
    }

    /// Helper: `voice.say` + tick `guidance.markSpoke` so the silence
    /// timer never fires right after we already spoke.
    @discardableResult
    private func saySpoken(
        _ text: String,
        tone: CueTone = .normal,
        spatialPan: Float = 0
    ) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        // Tagged log so the spoken cue text lands in the os_log next to
        // the audio-queue timestamps — makes the banner ↔ voice
        // distance correlation auditable without recording the mic.
        // DEBUG-only so production integrators don't get every cue
        // dumped to their device log.
        #if DEBUG
        // Capture the cue context: tone + current maneuver index +
        // distance to upcoming maneuver. With one structured line per
        // cue, "what cue fired when, while where on the route" is
        // pinpointed from a single grep.
        let mIdx = (currentInstruction?.maneuver.index).map { "\($0)" } ?? "?"
        let mDist = currentInstruction.map { Int($0.metersToManeuver) }.map { "\($0)m" } ?? "?"
        NSLog("🔊 [cue] tone=\(tone) mnv=#\(mIdx) distToMnv=\(mDist) → %@", text)
        #endif
        onCueSpoken?(text)
        // Production telemetry — host wires `onCueFired` to its
        // analytics. Fires on every spoken cue with structured
        // context, so cue cadence + per-maneuver behaviour is
        // measurable in the field. Internal `onCueSpoken` test
        // seam is unchanged and stays nil in production.
        if let onCueFired = onCueFired {
            let event = CueEvent(
                tsMs: Int64(Date().timeIntervalSince1970 * 1000),
                text: text,
                tone: "\(tone)",
                maneuverIndex: currentInstruction?.maneuver.index,
                metersToManeuver: currentInstruction.map { Int($0.metersToManeuver) },
                locale: locale
            )
            onCueFired(event)
        }
        let spoken = voice.say(text, tone: tone, spatialPan: spatialPan)
        guidance.markSpoke()
        return spoken
    }

    /// Map a ``GuidanceEvent`` to its server phrase + cue tone, then play.
    /// Internal (not private) so the guidance-event unit tests can drive
    /// it directly without a full off-route GPS replay.
    func handleGuidanceEvent(_ event: GuidanceEvent, maneuver: ManeuverEvent) {
        // Soft off-route → speak a heads-up only when the server
        // shipped a dedicated `softOffRoute` phrase. With no
        // dedicated phrase the event stays silent and the hard
        // `.offRoute` (2.5 s later) delivers `voiceRecover` instead.
        //
        // Two earlier mistakes are deliberately undone here:
        //
        // 1. Falling back to `wrongWay` mis-labelled lateral drift as
        //    a direction reversal — the rider on a parallel street
        //    heard "Wrong way — please turn around" when they should
        //    have heard "Looks like you missed the turn, recalculating."
        //
        // 2. Setting `rerouteRequestedAtMs` from the soft event gated
        //    the hard event's `voiceRecover` cue (10 s cooldown), so
        //    the rider got two mis-labelled alerts and never the
        //    proper recovery line.
        if case .softOffRoute = event {
            if let phrase = tripScoovaState?["softOffRoute"], !phrase.isEmpty {
                saySpoken(phrase, tone: .alert)
            }
            return
        }
        // Off-route → ask the host to fetch a fresh route, but suppress
        // the recovery cue if we've already kicked one off in the recent
        // past. Without this gate, every off-route tick during the 1–3 s
        // a reroute fetch takes plays "Looks like you missed the turn,
        // recalculating" again — riders flagged it as a stutter loop.
        // The route adapter throttles actual fetches at 8 s; the cue
        // gate here is the speakable equivalent.
        if case .offRoute = event {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let recentlyRequested = rerouteRequestedAtMs > 0
                && now - rerouteRequestedAtMs < rerouteCueCooldownMs
            onRerouteNeeded?()
            rerouteRequestedAtMs = now
            if recentlyRequested {
                return                // reroute already in flight; stay quiet
            }
            // The maneuver the rider was heading for carries its own
            // recovery line ("Looks like you missed the turn,
            // recalculating.") — more specific than the trip-level
            // rerouting phrase, so speak it instead when present.
            if let recover = maneuver.voiceRecover, !recover.isEmpty {
                saySpoken(recover, tone: .alert)
                return
            }
        }
        // keepGoing → fill the silence with a VERBAL "still on X"
        // confirmation, not a non-verbal chime. Eyes-off riders flag
        // anything less informative than words as "the app died." The
        // phrase picks the richest source available:
        //   1. The upcoming maneuver's `voiceReaffirm` — already
        //      includes street + heading ("You're on 7th Avenue.
        //      Heading north-east.")
        //   2. Trip-level `keepGoing` ("Keep going straight.") if the
        //      per-maneuver reaffirm is missing
        //   3. Trip-level `good` ("Good, you're on track.") as a last
        //      resort — still a real word, never a click
        // Distance-to-destination is appended when > 300 m so the
        // rider gets a real progress check, not the same words on a
        // loop. `markSpoke` runs inside `saySpoken`, so the silence
        // timer resets correctly.
        //
        // The 40-second chime cadence is unchanged; we simply convert
        // each chime moment into one short spoken sentence. Quiet but
        // informative beats silent-and-anxious.
        if case .keepGoing = event {
            // Suppress "Keep going straight" when the rider is right
            // on top of a turn. A near-cue at 10 m + a "keep going
            // straight" filler in the same 10 s window are flatly
            // contradictory — the rider hears both and can't tell
            // which to follow. Bar: skip keepGoing if we're inside
            // the upcoming maneuver's near-cue window.
            if latestMetersToUpcomingManeuver > 0,
               latestMetersToUpcomingManeuver < 60 {
                return
            }
            // Precondition: the upcoming maneuver this cue's distance
            // clause references must be ahead of the rider. Same
            // rule as the approach cues — saying "N m to the next
            // turn" when the turn is behind is nonsense.
            if let lastP = lastProgressForGate,
               !coordIsAhead(
                   lat: maneuver.latitude, lon: maneuver.longitude,
                   rider: lastP) {
                return
            }
            let reaffirm = maneuver.voiceReaffirm
            let tripKeep = tripScoovaState?["keepGoing"]
            let tripGood = tripScoovaState?["good"]
            let base: String? = [reaffirm, tripKeep, tripGood].first {
                !($0?.isEmpty ?? true)
            } ?? nil
            if let base = base {
                // Distance-to-next-turn so the voice matches the banner
                // exactly. Falls back to total remaining when there's
                // no next turn (very short trip / arrival imminent) so
                // the rider isn't told "0 metres to the next turn."
                let metersForClause = latestMetersToUpcomingManeuver > 0
                    ? latestMetersToUpcomingManeuver
                    : latestMetersRemaining
                let phrase = appendDistanceToNextTurn(
                    base, lang: locale, metersToTurn: metersForClause)
                saySpoken(phrase, tone: .calm)
            } else {
                // Genuinely nothing to say (no scoova block on this
                // route + no maneuver reaffirm) — fall back to the
                // historic chime so the rider still gets a pulse.
                voice.playGuidanceChime()
                guidance.markSpoke()
            }
            return
        }
        guard let state = tripScoovaState else { return }  // no server phrases → silent
        let key: String
        let tone: CueTone
        switch event {
        case .keepGoing:
            key = "keepGoing";  tone = .calm
        case .driftLeft:
            key = "driftLeft";  tone = .normal
        case .driftRight:
            key = "driftRight"; tone = .normal
        case .slowDown:
            key = "slowDown";   tone = .urgent
        case .wrongWayHeading:
            key = "wrongWay";   tone = .alert
        case .offRoute:
            key = "rerouting"; tone = .alert
        case .softOffRoute:
            // Handled in the early-return branch at the top of this
            // function (sets the cue cooldown + speaks the soft phrase
            // without triggering a reroute). Reaching here means the
            // soft event slipped past that branch — silent fallback so
            // the switch stays exhaustive without speaking twice.
            return
        case .almostThere:
            // Gate: don't say "destination just ahead" while there's
            // still a TURN between the rider and the destination. The
            // GuidanceMonitor fires this when total metresRemaining is
            // 50–150 m — but on routes whose last turn IS at the
            // destination (Manhattan side-street, kerb-cut into a
            // driveway, etc.) the rider can be 60 m from "arrival"
            // and still need to turn left first. Hearing "your
            // destination is just ahead" while approach cues for the
            // turn are queued reads as a contradictory command.
            //
            // The upcoming maneuver must be the ARRIVE itself for
            // almost-there to fire. Anything else (turn / merge /
            // continue) means there's an action between the rider
            // and the destination, and the final turn's approach
            // stack will hand off to the arrive cue on its own.
            guard maneuver.type == .arrive else { return }
            key = almostThereKey(for: maneuver); tone = .calm
        }
        // Prefer the rich full-sentence variant (e.g. `almostThereFull`)
        // when the server shipped one — it carries the destination side.
        guard let rawPhrase = state[key + "Full"] ?? state[key],
              !rawPhrase.isEmpty else { return }
        // Fix A: when the cue is the destination-proximity `almostThere`
        // AND the rider did NOT actually execute the previous turn
        // (the gyro never confirmed it), strip the leading "Good. "
        // affirmation. The server's almostThere often opens with
        // "Good. Almost there." as a stylistic prefix; that "Good"
        // pats the rider on the back for a turn they may not have
        // made (live-observed 2026-05-29 06:24:13: cue fired while
        // rider was still heading west, having missed the left turn).
        // Keep the prefix when the rider DID confirm a turn since
        // the last almostThere window.
        let phrase: String = {
            guard case .almostThere = event,
                  shouldStripGoodPrefix()
            else { return rawPhrase }
            return Self.stripLeadingGoodPrefix(rawPhrase)
        }()
        saySpoken(phrase, tone: tone)
    }

    /// Returns true when the cue speaker should drop a leading
    /// "Good. " from the next almostThere cue — fires when the
    /// previous turn maneuver hasn't been confirmed via gyro yet.
    /// The "previous turn" is the most recent maneuver index
    /// whose near-cue armed a confirm. If that index isn't in
    /// ``confirmedTurnManeuvers``, the rider hasn't actually
    /// executed it.
    private func shouldStripGoodPrefix() -> Bool {
        // No turn was ever armed → no "Good" to claim, no strip
        // (it's the first turn-less leg / direct shot to destination).
        guard let armed = lastArmedTurnManeuverIdx else { return false }
        return !confirmedTurnManeuvers.contains(armed)
    }

    /// "Good. Almost there." → "Almost there." Handles "Good. ",
    /// "Good, ", "Good ". Other prefixes pass through unchanged.
    internal static func stripLeadingGoodPrefix(_ s: String) -> String {
        let lower = s.lowercased()
        let prefixes = ["good. ", "good, ", "good "]
        for p in prefixes where lower.hasPrefix(p) {
            let trimmed = String(s.dropFirst(p.count))
            // Re-capitalize: original sentence's first letter became
            // lowercase when we trimmed off "Good. "; restore it.
            guard let first = trimmed.first else { return trimmed }
            return first.uppercased() + trimmed.dropFirst()
        }
        return s
    }

    /// Pick the sided variant of "almost there" if the destination
    /// maneuver type encodes a side.
    private func almostThereKey(for maneuver: ManeuverEvent) -> String {
        // Final maneuver in the list — peek at it for side info. Adapter
        // currently maps Valhalla 5 → .arrive (loses right/left). Until
        // that's surfaced as a sub-type we use the neutral "almostThere".
        _ = maneuvers.last ?? maneuver
        return "almostThere"
    }

    private func panFor(_ type: ManeuverType) -> Float {
        if type.isLeftSide { return -0.8 }
        if type.isRightSide { return 0.8 }
        return 0
    }

    /// Crude seconds-to-maneuver estimator. Used to substitute `{secs}`
    /// in the server's getReady template. We floor the speed at 5 m/s
    /// (~18 km/h cycling pace) so a stationary GPS fix doesn't produce
    /// "in 9999 seconds" cues. Clamped to 1..99.
    static func estimateSecondsToManeuver(metersToManeuver: Double, speedMps: Float?) -> Int {
        let s = max(5.0, Double(speedMps ?? 0))
        let raw = Int((metersToManeuver / s).rounded(.toNearestOrAwayFromZero))
        return min(99, max(1, raw))
    }

    // MARK: - Builder ----------------------------------------------------

    public static func builder() -> Builder { Builder() }

    public final class Builder {
        private var apiKey = ""
        private var locale = "en-US"
        private var profile = "auto"
        private var landmarks = true
        private var spatialAudio = true

        public func apiKey(_ v: String) -> Builder { apiKey = v; return self }
        public func locale(_ v: String) -> Builder { locale = v; return self }
        public func profile(_ v: String) -> Builder { profile = v; return self }
        public func landmarks(_ v: Bool) -> Builder { landmarks = v; return self }
        public func spatialAudio(_ v: Bool) -> Builder { spatialAudio = v; return self }

        public func build() -> ScoovaNavLayer {
            precondition(!apiKey.isEmpty, "apiKey is required")
            return ScoovaNavLayer(
                apiKey: apiKey,
                locale: locale,
                profile: profile,
                landmarks: landmarks,
                spatialAudio: spatialAudio
            )
        }
    }
}

/// Rewrites any baked-in distance prefix in a server-rendered cue
/// ("In 300 meters after Starbucks, turn right onto 8th Avenue.")
/// to the LIVE distance from the rider to the maneuver. The server's
/// number is the costing's expected lead distance — 300 m for car,
/// often wildly different from where the SDK actually fires the cue
/// for a pedestrian or scooter. Banner shows live; voice must too.
///
/// Localised patterns cover the launch markets (en / fr / es / de / it
/// / pt / nl) plus Arabic and Turkish. Each pattern matches the
/// leading "in N meters/kilometres" clause only — landmark anchors
/// and direction words are preserved verbatim.
///
/// If no pattern matches (e.g. an eyes-off cue with no distance, or
/// a language not yet handled), the cue is returned unchanged — the
/// rider hears the server's text as-is, same as before this pass.
internal func rewriteEmbeddedDistance(
    _ phrase: String, lang: String, liveMeters: Int
) -> String {
    guard liveMeters > 0 else { return phrase }
    let lc = lang.lowercased()
    let live = spokenDistance(lang: lang, meters: liveMeters)

    // Each entry is (regex pattern, replacement-template with $live).
    // The regex must match at the START of the cue, case-insensitive,
    // and capture the static "{N} unit" clause so we replace exactly
    // that prefix. Trailing comma / space stays put.
    let patterns: [(String, String)]
    if lc.hasPrefix("ar") {
        patterns = [
            (#"^(?:في|بعد)\s+\d+(?:\.\d+)?\s*(?:متر|كيلومتر|كم|م)\b"#, "بعد \(live)"),
        ]
    } else if lc.hasPrefix("fr") {
        patterns = [
            (#"^Dans\s+\d+(?:[.,]\d+)?\s*(?:m[èe]tres?|km|kilom[èe]tres?|m)\b"#, "Dans \(live)"),
        ]
    } else if lc.hasPrefix("de") {
        patterns = [
            (#"^In\s+\d+(?:[.,]\d+)?\s*(?:Metern?|km|Kilometern?|m)\b"#, "In \(live)"),
        ]
    } else if lc.hasPrefix("es") {
        patterns = [
            (#"^En\s+\d+(?:[.,]\d+)?\s*(?:metros?|km|kil[óo]metros?|m)\b"#, "En \(live)"),
        ]
    } else if lc.hasPrefix("it") {
        patterns = [
            (#"^Tra\s+\d+(?:[.,]\d+)?\s*(?:metri|km|chilometri|m)\b"#, "Tra \(live)"),
        ]
    } else if lc.hasPrefix("pt") {
        patterns = [
            (#"^Em\s+\d+(?:[.,]\d+)?\s*(?:metros?|km|quil[óo]metros?|m)\b"#, "Em \(live)"),
        ]
    } else if lc.hasPrefix("nl") {
        patterns = [
            (#"^Over\s+\d+(?:[.,]\d+)?\s*(?:meter|km|kilometer|m)\b"#, "Over \(live)"),
        ]
    } else if lc.hasPrefix("tr") {
        patterns = [
            (#"^\d+(?:[.,]\d+)?\s*(?:metre|km|kilometre|m)\s+sonra"#, "\(live) sonra"),
        ]
    } else {
        // English (default) + any locale not specifically handled.
        patterns = [
            (#"^In\s+\d+(?:\.\d+)?\s*(?:meters?|metres?|km|kilometers?|kilometres?|m)\b"#, "In \(live)"),
        ]
    }
    var out = phrase
    for (pat, repl) in patterns {
        if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            let result = re.stringByReplacingMatches(
                in: out, options: [], range: range, withTemplate: repl)
            if result != out {
                out = result
                break   // First match wins; no point trying more patterns.
            }
        }
    }
    return out
}

private func welcomeText(lang: String, distanceKm: Double) -> String {
    let km = String(format: "%.1f", distanceKm)
    if lang.hasPrefix("ar") { return "ابدأ الرحلة. حوالي \(km) كيلومتر." }
    if lang.hasPrefix("fr") { return "C'est parti. Environ \(km) kilomètres." }
    if lang.hasPrefix("de") { return "Los geht's. Etwa \(km) Kilometer." }
    if lang.hasPrefix("es") { return "Vamos. Unos \(km) kilómetros." }
    if lang.hasPrefix("tr") { return "Başlıyoruz. Yaklaşık \(km) kilometre." }
    return "Let's go. About \(km) kilometers."
}

private func arrivedText(lang: String) -> String {
    if lang.hasPrefix("ar") { return "وصلت لوجهتك." }
    if lang.hasPrefix("fr") { return "Vous êtes arrivé." }
    if lang.hasPrefix("de") { return "Sie haben Ihr Ziel erreicht." }
    if lang.hasPrefix("es") { return "Has llegado." }
    if lang.hasPrefix("tr") { return "Hedefe ulaştınız." }
    return "You have arrived."
}

/// A spoken distance — "19 kilometers" past 1 km, "350 meters" below it
/// (rounded to the nearest 50 so TTS never reads "347 meters"). Kept in
/// kilometres to match the welcome cue's units.
private func spokenDistance(lang: String, meters: Int) -> String {
    if meters >= 1000 {
        let km = Double(meters) / 1000.0
        let n = km >= 10 ? String(format: "%.0f", km) : String(format: "%.1f", km)
        if lang.hasPrefix("ar") { return "\(n) كيلومتر" }
        if lang.hasPrefix("fr") { return "\(n) kilomètres" }
        if lang.hasPrefix("de") { return "\(n) Kilometer" }
        if lang.hasPrefix("es") { return "\(n) kilómetros" }
        if lang.hasPrefix("tr") { return "\(n) kilometre" }
        return "\(n) kilometers"
    }
    let m = max(50, Int((Double(meters) / 50.0).rounded()) * 50)
    if lang.hasPrefix("ar") { return "\(m) متر" }
    if lang.hasPrefix("fr") { return "\(m) mètres" }
    if lang.hasPrefix("de") { return "\(m) Meter" }
    if lang.hasPrefix("es") { return "\(m) metros" }
    if lang.hasPrefix("tr") { return "\(m) metre" }
    return "\(m) meters"
}

/// Appends a live distance clause to a reaffirm / silence-filler cue.
///
/// The clause names the distance to the **next turn**, not the
/// destination — so the voice number matches what the banner shows
/// the rider. Mismatched numbers (banner "812 m" vs voice "1.4 km to
/// destination") read as a bug: the rider can't square the two and
/// loses trust. Skipped when the rider is near the maneuver (the
/// far / mid / near approach cues own that last stretch) or when
/// the next maneuver IS the destination (then it's the same number
/// either way — but the arrival cue speaks for itself).
private func appendDistanceToNextTurn(
    _ phrase: String, lang: String, metersToTurn: Int
) -> String {
    guard metersToTurn > 300 else { return phrase }
    let dist = spokenDistance(lang: lang, meters: metersToTurn)
    let clause: String
    if lang.hasPrefix("ar")      { clause = "باقي \(dist) للتحويلة الجاية." }
    else if lang.hasPrefix("fr") { clause = "\(dist) avant le prochain virage." }
    else if lang.hasPrefix("de") { clause = "Noch \(dist) bis zur nächsten Abbiegung." }
    else if lang.hasPrefix("es") { clause = "\(dist) hasta el próximo giro." }
    else if lang.hasPrefix("tr") { clause = "Sonraki dönüşe \(dist)." }
    else                         { clause = "\(dist) to the next turn." }
    let base = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    return base.isEmpty ? clause : base + " " + clause
}

/// DEPRECATED: kept only because external callers in adapters may
/// import the symbol. New callers use ``appendDistanceToNextTurn``,
/// which matches the banner's distance.
@available(*, deprecated, renamed: "appendDistanceToNextTurn")
private func appendDistanceToDestination(
    _ phrase: String, lang: String, metersRemaining: Int
) -> String {
    appendDistanceToNextTurn(phrase, lang: lang, metersToTurn: metersRemaining)
}
