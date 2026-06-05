import Foundation
import AVFoundation

/// Audio output route the user is currently hearing through. Mirror of
/// the Android enum; drives A2DP latency compensation and feature gating.
public enum AudioRoute: String, Sendable {
    case builtInSpeaker     // built-in iPhone speaker
    case builtInReceiver    // ear-piece during a call
    case wiredHeadphones
    case bluetoothA2dp      // music-quality Bluetooth (AirPods, headphones)
    case bluetoothHFP       // hands-free profile (call-only Bluetooth, lower fidelity)
    case usbHeadset
    case hdmi
    case carAudio           // CarPlay
    case airPlay
    case unknown

    public var defaultLookaheadMs: Int {
        switch self {
        case .builtInSpeaker, .builtInReceiver: return 0
        case .wiredHeadphones:                  return 30
        case .bluetoothA2dp:                    return 250
        case .bluetoothHFP:                     return 280
        case .usbHeadset:                       return 60
        case .hdmi:                             return 80
        case .carAudio:                         return 180
        case .airPlay:                          return 150
        case .unknown:                          return 100
        }
    }
}

/// Wraps `AVAudioSession` with three reliability features (iOS-only):
///
///   • **Route detection** — reads `currentRoute` and emits a `@Published`
///     of it. Listens for `routeChangeNotification` and refreshes.
///   • **Session lifecycle** — `.playback` + `.voicePrompt` + `.duckOthers`.
///     `setActive(true)` before a cue, `setActive(false, notifyOthersOnDeactivation: true)`
///     after the cue completes. Prevents pops and orphan-duck state.
///   • **No system volume mutation** — the SDK never touches
///     `outputVolume`, `MPVolumeView`, or anything that modifies the user's
///     phone media volume. The volume slider is sacred.
///
/// macOS / watchOS get a no-op stub since `AVAudioSession` doesn't exist.
final class AudioReliability: @unchecked Sendable {

    @Published public private(set) var route: AudioRoute = .unknown
    @Published public private(set) var interrupted: Bool = false

    private var observers: [NSObjectProtocol] = []

    public init() {
#if os(iOS)
        refreshRoute()
        installObservers()
#endif
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    public func refreshRoute() {
#if os(iOS)
        route = currentSystemRoute()
#endif
    }

    /// Activate the audio session for a cue. Idempotent.
    public func activateForCue() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // `.duckOthers` and `.mixWithOthers` are mutually exclusive per
            // Apple's docs — combining them makes `setCategory` throw
            // OSStatus -50 (invalid arg), the session never routes for
            // playback, and EVERY cue plays into a dead session. The
            // correct pair for nav voice is `[.duckOthers,
            // .interruptSpokenAudioAndMixWithOthers]`: duck music, mix
            // with Siri / audiobooks. Riders flagged "no voice at all"
            // for weeks until this was found.
            try session.setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try session.setActive(true, options: [])
        } catch {
            // Surface — silent failure here is the bug we shipped before.
            NSLog("🔊 [AudioReliability] activateForCue FAILED: \(error.localizedDescription)")
        }
#endif
    }

    /// Deactivate after a cue. Use `.notifyOthersOnDeactivation` so other
    /// apps un-duck immediately.
    public func deactivateAfterCue() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Non-fatal — session stays active but next cue will reuse it.
        }
#endif
    }

#if os(iOS)
    // MARK: - Internals --------------------------------------------------

    private func installObservers() {
        let center = NotificationCenter.default

        let routeObs = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshRoute()
        }

        let interruptObs = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let kind = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                      .flatMap(AVAudioSession.InterruptionType.init)
            else { return }
            switch kind {
            case .began:
                self.interrupted = true
            case .ended:
                self.interrupted = false
                // Reactivate so the next cue can speak.
                self.activateForCue()
            @unknown default:
                self.interrupted = false
            }
        }

        observers = [routeObs, interruptObs]
    }

    private func currentSystemRoute() -> AudioRoute {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let first = outs.first else { return .unknown }
        switch first.portType {
        case .builtInSpeaker:                       return .builtInSpeaker
        case .builtInReceiver:                      return .builtInReceiver
        case .headphones, .headsetMic:              return .wiredHeadphones
        case .bluetoothA2DP, .bluetoothLE:          return .bluetoothA2dp
        case .bluetoothHFP:                         return .bluetoothHFP
        case .usbAudio:                             return .usbHeadset
        case .HDMI, .displayPort:                   return .hdmi
        case .carAudio:                             return .carAudio
        case .airPlay:                              return .airPlay
        default:                                    return .unknown
        }
    }
#endif
}

/// Diagnostics snapshot — what the SDK thinks is true. Mirror surface
/// across all platforms.
public struct Diagnostics: Sendable, Equatable {
    public let audioRoute: AudioRoute
    public let ttsEngineReady: Bool
    public let lastCueLatencyMs: Int64
    public let voiceLocaleResolved: String?
    public let voiceFallback: String?
    public let lookaheadOffsetMs: Int
    public let interrupted: Bool

    public init(
        audioRoute: AudioRoute = .unknown,
        ttsEngineReady: Bool = false,
        lastCueLatencyMs: Int64 = -1,
        voiceLocaleResolved: String? = nil,
        voiceFallback: String? = nil,
        lookaheadOffsetMs: Int = 0,
        interrupted: Bool = false
    ) {
        self.audioRoute = audioRoute
        self.ttsEngineReady = ttsEngineReady
        self.lastCueLatencyMs = lastCueLatencyMs
        self.voiceLocaleResolved = voiceLocaleResolved
        self.voiceFallback = voiceFallback
        self.lookaheadOffsetMs = lookaheadOffsetMs
        self.interrupted = interrupted
    }
}
