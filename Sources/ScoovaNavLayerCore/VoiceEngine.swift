import Foundation
import AVFoundation

/// Importance bucket — higher pre-empts lower mid-utterance.
public enum CueTone: Int, Sendable {
    case calm = 0, normal = 1, cheerful = 2, urgent = 3, alert = 4
    public var priority: Int { rawValue }
}

/// AVSpeechSynthesizer wrapper with three behaviours that matter for nav:
///
///   • **Duration-aware** — a cue is spoken only once the previous one
///     has finished. While a cue is mid-phrase a new one either
///     interrupts (strictly higher priority) or is dropped — never
///     queued, so cues can't race each other or play seconds late.
///   • **Locale fallback** — "ar-EG" gracefully degrades to "ar" when the
///     device doesn't have the Egyptian voice installed.
///   • **Spatial audio** — a panned cue (`spatialPan != 0`) renders to
///     PCM via `write(_:toBufferCallback:)` and plays through an
///     `AVAudioEngine` player node whose `pan` places the turn in the
///     matching ear. Device-only; falls back to plain speech anywhere
///     it can't run — a cue is never lost to the spatial path.
final class VoiceEngine: NSObject, @unchecked Sendable {

    private let synth = AVSpeechSynthesizer()
#if os(iOS)
    private let session = AVAudioSession.sharedInstance()
#endif

    public let reliability = AudioReliability()

    @Published public private(set) var ttsReady: Bool = false
    @Published public private(set) var lastCueLatencyMs: Int64 = -1
    @Published public private(set) var voiceLocaleResolved: String? = nil
    @Published public private(set) var voiceFallback: String? = nil

    private var pendingThresholdCrossedAt: TimeInterval = 0

    /// Wall-clock time (ms) the current cue is estimated to keep
    /// speaking until — a new cue arriving before this would race it.
    private var speakingUntil: TimeInterval = 0
    private var currentTone: CueTone = .calm
    private var currentUtterance: AVSpeechUtterance?

    // Spatial-audio graph — built lazily on the first panned cue. The
    // synthesised speech renders into PCM buffers played through an
    // `AVAudioPlayerNode`, whose `pan` puts a left turn in the left ear.
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var spatialFormat: AVAudioFormat?

    // Soft "still on track" chime — built once, lazily, the first time
    // a long quiet stretch needs the eyes-off heartbeat.
    private var chimePlayer: AVAudioPlayer?

    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    public var pitch: Float = 1.0
    public var locale: String = "en-US" {
        didSet { voicePack = VoicePack.loadOrNull(locale: locale) }
    }
    public var spatialEnabled: Bool = true
    public var voiceEnabled: Bool = true

    /// Dialect voice pack bundled in the SDK's resources. When present,
    /// `say` plays a pre-rendered clip instead of synthesising TTS — the
    /// only way to give the rider a genuine Cairo / Gulf / etc. accent
    /// (on-device `AVSpeechSynthesizer` ships only MSA for Arabic). Falls
    /// through to TTS when the pack is missing the cue or absent entirely.
    private var voicePack: VoicePack?
    private var clipSeqPlayer: ClipSequencePlayer?

    public override init() {
        super.init()
        synth.delegate = self
        configureSession()
        prewarm()
    }

    /// Mark the moment a threshold was crossed in `ScoovaNavLayer.onProgress`.
    /// The next `say` call measures (cue latency = TTS-start-time − this).
    public func markThresholdCrossed() {
        pendingThresholdCrossedAt = Date().timeIntervalSince1970 * 1000
    }

    /// Pre-warm the synthesiser so the first real cue doesn't pay the
    /// voice-load cost (1.5–2.5 s on a cold engine).
    private func prewarm() {
        let utt = AVSpeechUtterance(string: " ")
        utt.volume = 0.0
        utt.voice = bestVoice(for: locale)
        synth.speak(utt)
        ttsReady = true
    }

    public func shutdown() {
        synth.stopSpeaking(at: .immediate)
        playerNode.stop()
        chimePlayer?.stop()
        if audioEngine.isRunning { audioEngine.stop() }
    }

    /// Speak `text` with optional spatial pan in `[-1, 1]`.
    @discardableResult
    public func say(
        _ text: String,
        tone: CueTone = .normal,
        spatialPan: Float = 0,
        id: String? = nil
    ) -> Bool {
        guard voiceEnabled else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let now = Date().timeIntervalSince1970 * 1000
        // While the previous cue is still being spoken, a new cue must
        // not pile up behind it — it would play seconds late, past the
        // point it was meant for. An urgent cue interrupts; anything
        // that isn't strictly higher priority is dropped, not queued.
        if now < speakingUntil {
            guard tone.priority > currentTone.priority else { return false }
            synth.stopSpeaking(at: .immediate)
            playerNode.stop()
        }

        // Reactivate session in case we were interrupted (phone call) since
        // last cue; idempotent so no-op when already active.
        reliability.activateForCue()
        reliability.refreshRoute()

        // ── Voice pack lookup ──────────────────────────────────────
        // Before paying for TTS synthesis, ask the dialect pack if it
        // has this cue. The pack is the only way to get a genuine
        // Egyptian / Gulf / Levantine / Maghrebi accent — on-device TTS
        // only knows MSA. If the pack has the cue, play the clip(s);
        // otherwise fall through to TTS below.
        if let pack = voicePack {
            let urls: [URL]? = pack.lookup(trimmed).map { [$0] }
                ?? pack.lookupCompound(trimmed)
            if let urls {
                clipSeqPlayer?.stop()
                let p = ClipSequencePlayer(
                    urls: urls,
                    onDone: { [weak self] in self?.clipSeqPlayer = nil },
                    onError: { [weak self] in self?.clipSeqPlayer = nil }
                )
                clipSeqPlayer = p
                p.start()
                currentTone = tone
                speakingUntil = now + Self.estimatedSpeechMs(trimmed)
                if pendingThresholdCrossedAt > 0 {
                    lastCueLatencyMs = Int64(now - pendingThresholdCrossedAt)
                    pendingThresholdCrossedAt = 0
                }
                _ = id
                return true
            }
        }

        let utt = AVSpeechUtterance(string: trimmed)
        utt.voice = bestVoice(for: locale)
        utt.rate = rate
        utt.pitchMultiplier = pitch

        // A panned cue (left / right turn) renders to PCM and plays
        // through the `AVAudioPlayerNode` so the turn lands in the
        // matching ear; everything else speaks straight. Spatial is
        // device-only (see `spatialSupported`) and any failure inside
        // the spatial path falls back to plain speech.
        let pan = max(-1, min(1, spatialPan))
        if spatialEnabled, pan != 0, Self.spatialSupported, #available(iOS 16.0, *) {
            speakSpatial(utt, pan: pan)
        } else {
            synth.speak(utt)
        }

        currentUtterance = utt
        currentTone = tone
        speakingUntil = now + Self.estimatedSpeechMs(trimmed)
        _ = id  // utterance IDs are reserved for future cancellation
        return true
    }

    /// Rough wall-clock duration of a phrase at the default rate.
    /// Deliberately a little generous — over-estimating just drops the
    /// next cue, while under-estimating lets it race the current one.
    private static func estimatedSpeechMs(_ text: String) -> Double {
        let words = text.split(whereSeparator: { $0 == " " }).count
        return Double(max(1, words)) * 350 + 600
    }

    // MARK: - Internals --------------------------------------------------

    private func configureSession() {
        // Delegated to AudioReliability so the lifecycle (route observer,
        // interruption handler, deactivation timing) is all in one place.
        reliability.activateForCue()
    }

    private func bestVoice(for tag: String) -> AVSpeechSynthesisVoice? {
        if let v = AVSpeechSynthesisVoice(language: tag) {
            voiceLocaleResolved = tag
            voiceFallback = nil
            return v
        }
        // Fallback: take the base language.
        let parts = tag.split(separator: "-")
        if let base = parts.first, let v = AVSpeechSynthesisVoice(language: String(base)) {
            let baseTag = String(base)
            voiceLocaleResolved = baseTag
            voiceFallback = "\(tag) → \(baseTag)"
            return v
        }
        voiceLocaleResolved = "en-US"
        voiceFallback = "\(tag) → en-US"
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - Spatial playback ------------------------------------------

    /// Whether the panned-playback path can run. `AVSpeechSynthesizer.
    /// write` yields no usable buffers on the Simulator, and spatial is
    /// an iOS feature — everywhere else a panned cue speaks centered.
    private static var spatialSupported: Bool {
#if os(iOS) && !targetEnvironment(simulator)
        if #available(iOS 16.0, *) { return true }
        return false
#else
        return false
#endif
    }

    /// Render `utt` to PCM, then hand the buffers to `playPanned`. A
    /// safety-net timeout guarantees the cue is still spoken even if
    /// `write` never reports completion — a cue is never lost.
    @available(iOS 16.0, *)
    private func speakSpatial(_ utt: AVSpeechUtterance, pan: Float) {
        var buffers: [AVAudioPCMBuffer] = []
        var settled = false
        func finish() {
            guard !settled else { return }
            settled = true
            if buffers.isEmpty {
                self.synth.speak(utt)                  // no audio — speak it
            } else {
                self.playPanned(buffers, pan: pan, fallback: utt)
            }
        }
        synth.write(utt) { buffer in
            // Marshal onto main so `buffers` / `settled` stay single-threaded.
            DispatchQueue.main.async {
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength > 0 { buffers.append(pcm) }
                else { finish() }                      // empty buffer = done
            }
        }
        // If `write` never reports completion, speak whatever we have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { finish() }
    }

    /// Play already-rendered speech buffers through the engine's player
    /// node, panned. Any setup failure falls back to plain speech.
    @available(iOS 16.0, *)
    private func playPanned(_ buffers: [AVAudioPCMBuffer], pan: Float,
                            fallback utt: AVSpeechUtterance) {
        guard let format = buffers.first?.format else {
            synth.speak(utt); return
        }
        do {
            if !audioEngine.attachedNodes.contains(playerNode) {
                audioEngine.attach(playerNode)
            }
            // (Re)connect whenever the voice's audio format changes.
            if !format.isEqual(spatialFormat) {
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode,
                                    format: format)
                spatialFormat = format
            }
            if !audioEngine.isRunning { try audioEngine.start() }
            playerNode.stop()                          // drop any prior cue
            playerNode.pan = pan
            if pendingThresholdCrossedAt > 0 {
                lastCueLatencyMs = Int64(Date().timeIntervalSince1970 * 1000
                                         - pendingThresholdCrossedAt)
                pendingThresholdCrossedAt = 0
            }
            for (i, buf) in buffers.enumerated() {
                let isLast = i == buffers.count - 1
                playerNode.scheduleBuffer(buf) { [weak self] in
                    guard isLast else { return }
                    DispatchQueue.main.async { self?.reliability.deactivateAfterCue() }
                }
            }
            playerNode.play()
        } catch {
            synth.speak(utt)                           // engine wouldn't start
        }
    }

    // MARK: - Guidance chime --------------------------------------------

    /// Play a soft two-note "still on track" chime — the eyes-off
    /// heartbeat on a long quiet stretch. Deliberately non-verbal: it
    /// reassures the rider that guidance is alive without the monotony
    /// of a repeated spoken phrase, and without masking traffic the way
    /// continuous background audio would.
    public func playGuidanceChime() {
        guard voiceEnabled else { return }
        if chimePlayer == nil {
            let player = try? AVAudioPlayer(data: Self.makeChimeData())
            player?.volume = 0.32
            player?.prepareToPlay()
            chimePlayer = player
        }
        guard let player = chimePlayer else { return }
        reliability.activateForCue()
        player.currentTime = 0
        player.play()
    }

    /// Synthesise the chime once: a gentle rising two-note tone
    /// (D5 → G5) with a soft attack and exponential decay, rendered to
    /// an in-memory 16-bit PCM WAV — no bundled resource needed.
    private static func makeChimeData() -> Data {
        let sr = 44100.0
        var samples: [Int16] = []
        for (freq, dur) in [(587.33, 0.16), (783.99, 0.40)] {
            let n = Int(sr * dur)
            for i in 0..<n {
                let t = Double(i) / sr
                var env = exp(-t * 7.0)
                if t < 0.006 { env *= t / 0.006 }   // soft attack — no click
                let s = sin(2.0 * Double.pi * freq * t) * env * 0.5
                samples.append(Int16(max(-1.0, min(1.0, s)) * 32767.0))
            }
        }
        return wavData(samples: samples, sampleRate: Int(sr))
    }

    /// Wrap raw mono 16-bit samples in a minimal WAV container.
    private static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let dataBytes = samples.count * 2
        var d = Data()
        d.append(Data("RIFF".utf8))
        d.append(le32(UInt32(36 + dataBytes)))
        d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8))
        d.append(le32(16))                       // PCM fmt chunk size
        d.append(le16(1))                        // PCM
        d.append(le16(1))                        // mono
        d.append(le32(UInt32(sampleRate)))
        d.append(le32(UInt32(sampleRate * 2)))   // byte rate
        d.append(le16(2))                        // block align
        d.append(le16(16))                       // bits per sample
        d.append(Data("data".utf8))
        d.append(le32(UInt32(dataBytes)))
        for s in samples { d.append(le16(UInt16(bitPattern: s))) }
        return d
    }

}

extension VoiceEngine: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                  didStart utterance: AVSpeechUtterance) {
        if pendingThresholdCrossedAt > 0 {
            let nowMs = Date().timeIntervalSince1970 * 1000
            lastCueLatencyMs = Int64(nowMs - pendingThresholdCrossedAt)
            pendingThresholdCrossedAt = 0
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                  didFinish utterance: AVSpeechUtterance) {
        // The cue finished — if it ran shorter than the estimate, free
        // the channel now so the next cue isn't needlessly held back.
        if utterance === currentUtterance {
            currentUtterance = nil
            speakingUntil = Date().timeIntervalSince1970 * 1000
        }
        // Deactivate after the utterance drains, so other apps un-duck.
        reliability.deactivateAfterCue()
    }
}
