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
    /// Server-rendered state-machine vocabulary for the current trip.
    /// Nil until an adapter pushes a `TripScoovaState` (currently the
    /// `ScoovaRoutingAdapter` does this on every `startRoute`).
    @Published public private(set) var tripScoova: TripScoovaState?

    /// Fired when the rider has strayed off the route long enough that a
    /// fresh one should be fetched. The host re-runs its routing call
    /// from the current location — `ScoovaRoutingAdapter` users just
    /// wire this to another `startRoute`. May fire off the main thread.
    public var onRerouteNeeded: (() -> Void)?

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
    /// Window after a turn cue inside which a matching yaw counts as
    /// confirmation. 8 seconds covers slow scooter turns + light delay.
    private let turnConfirmWindowMs: Int64 = 8_000
    /// Latest progress tick's metres-to-destination. Cached for the
    /// silence-filler verbal cue, which composes "Still on X. N metres
    /// to your destination." without re-receiving the ProgressEvent.
    private var latestMetersRemaining: Int = 0
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
                await MainActor.run { self.headingDeg = h }
            }
        }
        // Roll Diagnostics from the underlying VoiceEngine + AudioReliability.
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            guard let self = self else { return }
            await self.observeDiagnostics()
        }
    }

    public func stop() {
        headingTask?.cancel()
        diagnosticsTask?.cancel()
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

    /// Adapter calls once when the host gives us the route.
    public func onRoute(_ maneuvers: [ManeuverEvent]) {
        self.maneuvers = maneuvers
        self.welcomed = false
        self.arrived = false
        self.stoppedNearDestSinceMs = 0
        self.cueFired = [:]
        self.cueSchedule = Self.buildCueSchedule(
            maneuvers,
            defaults: cueDefaults,
            keepGoing: tripScoovaState?["keepGoing"],
            pan: panFor
        )
        guidance.reset()
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
        pan: (ManeuverType) -> Float
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
            // is intentionally NOT used (it bundled two turns into one
            // breath, which the rider hears as a contradictory command).
            if let phrase = m.voiceNear ?? m.voiceAtLandmark ?? m.voiceTurnNow {
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

    /// The distance-before-the-maneuver at which a cue fires *right now*.
    /// Distance-pinned cues (confirm / reaffirm / checkpoint) use their
    /// fixed `triggerMeters`. Time-pinned cues (far / mid / near) convert
    /// their seconds-out to metres against the live speed — so at 60 km/h
    /// "turn" fires three times farther out than at 20 km/h, and the
    /// rider gets the same seconds to react. The speed is clamped: the
    /// cue still fires when stopped (≥ 2.5 m/s floor) and a GPS spike
    /// can't fling it absurdly far (≤ 28 m/s ceiling).
    static func effectiveTriggerMeters(_ cue: CuePoint, speedMps: Float?) -> Double {
        guard let seconds = cue.triggerSeconds else { return cue.triggerMeters }
        // No low speed floor: a stopped rider (speed 0) gets trigger 0,
        // so an approach cue never fires at someone who isn't moving yet
        // — the pre-roll, or a wait at a light. The moment they move,
        // the time-based trigger gives the right seconds of lead. Only
        // a GPS dropout (nil speed) assumes a nominal 8 m/s.
        let v = Double(min(28.0, max(0.0, speedMps ?? 8.0)))
        return seconds * v
    }

    /// Adapter sets the decoded polyline shape so ``GuidanceMonitor`` can
    /// project the rider onto the line for drift / off-route / heading
    /// checks. Call once per route, ideally right after ``onRoute(_:)``.
    /// Also pushes the routing profile so the monitor can pick mode-
    /// aware drift / off-route thresholds — pedestrian on a sidewalk
    /// lives 10–20 m off the routed centerline, the same distance a
    /// car would correctly call "off route."
    public func setRouteShape(_ shape: [[Double]]) {
        guidance.setRoute(shape)
        guidance.setCosting(profile)
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
                return
            }
            let actual: TurnDir = turnDeg > 0 ? .left : .right
            if actual == expected && abs(turnDeg) > 30 {
                // Confirmed — fire "Good" from server state copy if set.
                if let good = tripScoovaState?["good"], !good.isEmpty {
                    saySpoken(good, tone: .cheerful)
                }
                pendingTurnDirection = nil
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
        // Cache for silence-filler verbal cue — see handleGuidanceEvent.
        latestMetersRemaining = p.metersRemaining
        latestMetersToUpcomingManeuver = Int(p.metersToUpcomingManeuver.rounded())
        if !welcomed {
            welcomed = true
            // Prefer server-rendered welcome — fall back to the hardcoded
            // distance-bearing phrase when no scoova block was forwarded.
            let serverWelcome = tripScoovaState?["welcomeFull"]
                ?? tripScoovaState?["welcome"]
            let phrase: String
            if let serverWelcome = serverWelcome, !serverWelcome.isEmpty {
                phrase = serverWelcome
            } else {
                phrase = welcomeText(lang: locale, distanceKm: Double(p.metersRemaining) / 1000)
            }
            saySpoken(phrase, tone: .calm)
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

        // ── Cue track ────────────────────────────────────────────────
        // Speak the server's pinned cues like subtitles. Each cue fires
        // once, the moment the rider reaches its trigger — a fixed
        // distance for confirm / reaffirm / checkpoint, but a speed-
        // scaled distance (constant seconds-out) for the far / mid /
        // near approach cues. At most one cue per tick; when several
        // cross together the nearest one supersedes the rest.
        if let points = cueSchedule[idx] {
            var fired = cueFired[idx] ?? []
            var toSpeak: CuePoint?
            var nearest = Double.greatestFiniteMagnitude
            for (ci, cue) in points.enumerated() where !fired.contains(ci) {
                let trigger = Self.effectiveTriggerMeters(cue, speedMps: p.speedMps)
                if dist <= trigger {
                    fired.insert(ci)                  // crossed — consumed
                    if trigger <= nearest { nearest = trigger; toSpeak = cue }
                }
            }
            cueFired[idx] = fired
            if let cue = toSpeak {
                voice.markThresholdCrossed()  // last-cue-latency diagnostic
                // The urgent (near) cue asks the rider to act now — arm
                // yaw confirmation for `onMotion`.
                if cue.tone == .urgent {
                    pendingTurnDirection = expectedTurnDir(maneuver.type)
                    pendingTurnFiredAtMs = Int64(Date().timeIntervalSince1970 * 1000)
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
                    // The server bakes a static lead distance into the
                    // FAR/MID cue text ("In 300 meters after Starbucks,
                    // turn right..."). That number was the server's
                    // assumed lead for the costing — but the SDK fires
                    // far/mid by TIME, which at pedestrian pace lands
                    // at ~42 m, not 300 m. Rewrite any "In N meters"
                    // / "In N km" prefix to the LIVE distance so the
                    // voice number matches the banner.
                    phrase = rewriteEmbeddedDistance(
                        phrase, lang: locale,
                        liveMeters: Int(p.metersToUpcomingManeuver.rounded()))
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
        if !arrived && nearLastManeuver {
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
        let atDestination = arrived
            || (nearLastManeuver && p.metersRemaining < arriveStopRadiusM)
        if !atDestination {
            for event in guidance.onProgress(p) {
                handleGuidanceEvent(event, maneuver: maneuver)
            }
        }
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
        NSLog("[ScoovaCue] saySpoken: %@", text)
        #endif
        onCueSpoken?(text)
        let spoken = voice.say(text, tone: tone, spatialPan: spatialPan)
        guidance.markSpoke()
        return spoken
    }

    /// Map a ``GuidanceEvent`` to its server phrase + cue tone, then play.
    /// Internal (not private) so the guidance-event unit tests can drive
    /// it directly without a full off-route GPS replay.
    func handleGuidanceEvent(_ event: GuidanceEvent, maneuver: ManeuverEvent) {
        // Off-route → ask the host to fetch a fresh route. Fired before
        // the phrase guard so a reroute still happens with no server copy.
        if case .offRoute = event {
            onRerouteNeeded?()
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
        guard let phrase = state[key + "Full"] ?? state[key],
              !phrase.isEmpty else { return }
        saySpoken(phrase, tone: tone)
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
