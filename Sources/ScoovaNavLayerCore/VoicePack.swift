import Foundation
import AVFoundation

/// Pre-rendered dialect voice clips bundled in the SDK's resources.
///
/// For dialects where iOS's on-device TTS only knows MSA (every Arabic
/// dialect), we ship a folder of WAV clips synthesised at build time by a
/// real dialect voice (Egyptian, Gulf, Levantine, Maghrebi). At runtime,
/// when `VoiceEngine` is about to speak a cue, it first asks the pack: "do
/// you have a clip for this exact text?" If yes — play the clip; the rider
/// hears authentic dialect audio. If no — fall through to `AVSpeechSynthesizer`
/// as before.
///
/// Two lookup paths:
///   1. **Exact** — the cue is one whole sentence we pre-rendered
///      (e.g. *"حوّد يمين دلوقتي."* → one clip).
///   2. **Comma-split** — the cue is a distance lead-in + an instruction
///      (*"بعد 200 متر، حوّد يمين."*) — we play *two* clips back-to-back,
///      joined at a natural comma pause. The seam is where a human would
///      breathe anyway, so it doesn't sound chopped.
///
/// Pack location: `Resources/voicepack/{locale}/manifest.json` + clip files.
final class VoicePack {

    private let bundle: Bundle
    private let dirName: String                 // e.g. "voicepack/ar-EG"
    private let textToClip: [String: String]

    private init(bundle: Bundle, dirName: String, textToClip: [String: String]) {
        self.bundle = bundle
        self.dirName = dirName
        self.textToClip = textToClip
    }

    /// Find a clip for the literal cue text. Returns the URL of the WAV in
    /// the SDK bundle, or `nil`. Tries a sequence of leniency candidates —
    /// stripping a landmark-prefix and/or onto-street-suffix the server
    /// may have wrapped around the bare instruction.
    func lookup(_ text: String) -> URL? {
        for c in candidates(text) {
            if let name = textToClip[c] { return urlFor(name) }
        }
        return nil
    }

    /// Try to split the cue at the Arabic comma (،) and look up each part.
    /// Tries each leniency form of the whole text first — landmark prefix
    /// may wrap a comma-split cue, and stripping it can yield a single
    /// recognisable sentence per fragment.
    func lookupCompound(_ text: String) -> [URL]? {
        for form in formsToTry(text) {
            guard form.contains("،") else { continue }
            let raw = form
                .split(separator: "،")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard raw.count >= 2 else { continue }
            var urls: [URL] = []
            urls.reserveCapacity(raw.count)
            var ok = true
            for (i, p) in raw.enumerated() {
                let key = (i < raw.count - 1) ? p + "،" : p
                if let url = lookup(key) { urls.append(url) }
                else { ok = false; break }
            }
            if ok { return urls }
        }
        return nil
    }

    // MARK: - Lenient matching ------------------------------------------
    //
    // The server's voice cue can come wrapped with a leading landmark
    // anchor ("بعد ميدان X على شمالك، ") and/or a trailing street suffix
    // (" ع شارع Y.") that the pack doesn't ship a clip for. The PACK
    // intentionally only carries the bare instruction (eyes-off design:
    // street names live on screen, not in voice). To match wrapped cues,
    // we try the literal text first, then variants with prefix/suffix
    // stripped, then both stripped together.

    private static let sideWords: Set<String> =
        ["يمينك", "شمالك", "يدك", "يسارك", "اليمين", "اليسار"]

    private static let landmarkPrefix = try! NSRegularExpression(
        pattern: #"^(بعد|عند)\s+[^،]+،\s*"#, options: [])

    /// Strip a trailing " ع شارع X." / " على X." suffix, but NOT an
    /// intrinsic " ع يمينك" / " ع شمالك" (those are side words, part of
    /// the cue body).
    private func stripStreetSuffix(_ s: String) -> String {
        let words = s.components(separatedBy: .whitespaces)
        // Walk from the end, find the LAST " ع " / " على " whose next
        // word is NOT a side word — that's the server-appended street.
        var i = words.count - 1
        var lastNonSide = -1
        while i >= 1 {
            let w = words[i - 1]
            if w == "ع" || w == "على" {
                let next = words[i].trimmingCharacters(in: CharacterSet(charactersIn: ".،"))
                if !Self.sideWords.contains(next) {
                    lastNonSide = i - 1
                    break
                }
            }
            i -= 1
        }
        guard lastNonSide >= 0 else { return s }
        let kept = words.prefix(lastNonSide).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".،  "))
        return kept.isEmpty ? s : kept + "."
    }

    private func stripLandmarkPrefix(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        let stripped = Self.landmarkPrefix.stringByReplacingMatches(
            in: s, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formsToTry(_ text: String) -> [String] {
        var out: [String] = []
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append(cleaned)
        let noStreet = stripStreetSuffix(cleaned)
        if noStreet != cleaned { out.append(noStreet) }
        let noLm = stripLandmarkPrefix(cleaned)
        if noLm != cleaned {
            out.append(noLm)
            let both = stripStreetSuffix(noLm)
            if both != noLm { out.append(both) }
        }
        return out
    }

    private func candidates(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for form in formsToTry(text) {
            for variant in [form,
                            form.trimmingCharacters(in: CharacterSet(charactersIn: ".، ")),
                            form.hasSuffix(".") ? form
                                : form.trimmingCharacters(in: CharacterSet(charactersIn: ".، ")) + "."] {
                if !variant.isEmpty && !seen.contains(variant) {
                    seen.insert(variant); out.append(variant)
                }
            }
        }
        return out
    }

    private func urlFor(_ filename: String) -> URL? {
        let stem = (filename as NSString).deletingPathExtension
        let ext  = (filename as NSString).pathExtension
        return bundle.url(forResource: stem, withExtension: ext, subdirectory: dirName)
    }

    /// Try to load the pack for `locale` from the SDK bundle. Returns `nil`
    /// when no pack is bundled for that locale (caller treats absence as
    /// "fall through to AVSpeechSynthesizer for everything").
    static func loadOrNull(locale: String) -> VoicePack? {
        let dir = "voicepack/\(locale)"
        let bundle = Bundle.module
        guard let manifestUrl = bundle.url(
            forResource: "manifest", withExtension: "json", subdirectory: dir
        ),
        let data = try? Data(contentsOf: manifestUrl),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let map  = json["text_to_clip"] as? [String: String]
        else { return nil }
        // Normalise keys with whitespace trim for robust lookup.
        var normalized = [String: String]()
        normalized.reserveCapacity(map.count)
        for (k, v) in map {
            normalized[k.trimmingCharacters(in: .whitespacesAndNewlines)] = v
        }
        return VoicePack(bundle: bundle, dirName: dir, textToClip: normalized)
    }
}

// MARK: - Sequential clip playback ------------------------------------------

/// Plays a sequence of bundled WAV URLs back-to-back, then invokes `onDone`.
/// Used by `VoiceEngine` when a cue resolves to one or more dialect-pack
/// clips instead of synthesised TTS.
///
/// Uses `AVAudioPlayer` (not `AVAudioPlayerNode`) because the clips are
/// short WAVs streamed from the app bundle — no need for the spatial graph.
final class ClipSequencePlayer: NSObject, AVAudioPlayerDelegate {
    private let urls: [URL]
    private let onDone: () -> Void
    private let onError: () -> Void
    private var index = 0
    private var player: AVAudioPlayer?
    private var cancelled = false

    init(urls: [URL], onDone: @escaping () -> Void, onError: @escaping () -> Void) {
        self.urls = urls
        self.onDone = onDone
        self.onError = onError
    }

    func start() { advance() }

    func stop() {
        cancelled = true
        player?.stop()
        player = nil
    }

    private func advance() {
        guard !cancelled else { return }
        guard index < urls.count else { onDone(); return }
        let u = urls[index]
        index += 1
        do {
            let p = try AVAudioPlayer(contentsOf: u)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            onError()
        }
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        guard !cancelled else { return }
        player = nil
        if flag { advance() } else { onError() }
    }

    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        player = nil
        onError()
    }
}
