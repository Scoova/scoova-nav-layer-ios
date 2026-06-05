import Foundation

/// Spoken cue text plus the rule that produced it. The rule label is
/// telemetry — every cue we say carries a trace of WHY we said it,
/// readable from the ``CueEvent`` callback and the SDK logs. When
/// "wrong cue" bug reports come in, the rule label is what tells us
/// whether the grammar chose right and the data was wrong, or the
/// grammar chose wrong.
public struct SpokenCueText: Sendable, Equatable {
    /// The text the voice engine speaks.
    public let text: String
    /// Which grammar rule fired. One of: ``"landmark"``,
    /// ``"ordinal"``, ``"next-confirmed"``, ``"distance"``,
    /// ``"fallback"``.
    public let rule: String
}

/// Cue-grammar engine — turns a ``LiveGuidanceState.UpcomingDecision``
/// + a cue phase into a spoken phrase. The whole point of having the
/// corridor + the reasoner is to STOP playing pre-baked strings and
/// start choosing grammar at speak time.
///
/// **Phase matters.** The same maneuver fires three approach cues —
/// FAR (~30 s out), MID (~15 s out), NEAR (~3 s out). If the grammar
/// produces the same text at all three phases the rider hears the
/// identical sentence three times and stops listening. Worse, ordinal
/// claims made far out ("take the second left") can be wrong by the
/// time the rider gets there if the corridor's data is imperfect.
///
/// Rules per phase:
///
/// | Phase | Rule order                                                |
/// |-------|-----------------------------------------------------------|
/// | far   | distance-only ("In 200 metres, turn right")               |
/// | mid   | distance-only ("In 80 metres, turn right")                |
/// | near  | landmark → ordinal → next-confirmed → action-now          |
///
/// Far and mid never make ordinal claims — they're heads-up cues, not
/// commitments. The rider has time to see the actual intersection by
/// near, so the strongest grammar fires there. "The next left" lives
/// only inside near AND only when the corridor proves there is exactly
/// one same-side turn ahead.
public enum CueGrammar {

    /// Which approach-cue phase is firing. Drives which rules are in
    /// scope when choosing text. Caller picks the phase from the
    /// ``CuePoint`` being played (urgent tone ⇒ near; long triggerSeconds
    /// ⇒ far; otherwise mid).
    public enum Phase: Sendable, Equatable { case far, mid, near }

    /// Build the cue text for an approach cue, given the reasoner's
    /// upcoming-decision context, the cue phase, and optional anchors.
    ///
    /// - Parameters:
    ///   - decision: structured upcoming decision the reasoner produced
    ///     this tick.
    ///   - phase: which approach phase is firing (far / mid / near).
    ///   - locale: BCP-47 locale string (e.g. ``"en-US"``, ``"ar-EG"``).
    ///   - landmark: optional landmark anchor. Used by the near phase
    ///     to fire the strongest "Turn left at [landmark]" form.
    ///   - fallback: optional pre-baked phrase from the legacy
    ///     ``scoova.voice.*`` block. Used when the maneuver has no
    ///     side (continue / depart / arrive) or as a last resort.
    public static func chooseCue(
        decision: LiveGuidanceState.UpcomingDecision,
        phase: Phase = .near,
        locale: String,
        landmark: String?,
        fallback: String?
    ) -> SpokenCueText {
        let side = sideWord(for: decision.type, locale: locale)
        let meters = Int(decision.distance.rounded())

        switch phase {
        case .far:
            // 30 s out. Heads-up. Never commits to an ordinal. The
            // distance form is honest at any moment — the rider hears
            // a number that matches the banner.
            if let s = side {
                return SpokenCueText(
                    text: render(.distance, side: s, locale: locale, value: "\(meters)"),
                    rule: "far-distance"
                )
            }
            return SpokenCueText(text: fallback ?? "", rule: "fallback")

        case .mid:
            // 15 s out. Still distance-led, but landmark anchors are
            // useful here ("after McDonald's, turn left") because the
            // rider can plausibly see the landmark already.
            if let lm = landmark, !lm.isEmpty, let s = side {
                return SpokenCueText(
                    text: render(.afterLandmark, side: s, locale: locale, value: lm),
                    rule: "mid-landmark"
                )
            }
            if let s = side {
                return SpokenCueText(
                    text: render(.distance, side: s, locale: locale, value: "\(meters)"),
                    rule: "mid-distance"
                )
            }
            return SpokenCueText(text: fallback ?? "", rule: "fallback")

        case .near:
            // 3 s out. This is the action moment — the strongest form
            // we know is correct. Rule order: landmark beats ordinal
            // beats next-confirmed beats action-now. Ordinal +
            // next-confirmed only fire when the corridor proves them.
            if let lm = landmark, !lm.isEmpty, let s = side {
                return SpokenCueText(
                    text: render(.atLandmark, side: s, locale: locale, value: lm),
                    rule: "landmark"
                )
            }
            if let total = decision.totalSameSideTurns,
               let ord = decision.ordinal,
               total > 1, ord >= 1, ord <= 5,
               let s = side {
                let word = ordinalWord(ord, locale: locale)
                return SpokenCueText(
                    text: render(.ordinal, side: s, locale: locale, value: word),
                    rule: "ordinal"
                )
            }
            if decision.totalSameSideTurns == 1, let s = side {
                return SpokenCueText(
                    text: render(.next, side: s, locale: locale, value: ""),
                    rule: "next-confirmed"
                )
            }
            if let s = side {
                return SpokenCueText(
                    text: render(.now, side: s, locale: locale, value: ""),
                    rule: "near-action"
                )
            }
            return SpokenCueText(text: fallback ?? "", rule: "fallback")
        }
    }

    // MARK: - Phrasebook --------------------------------------------------

    private enum Pattern { case atLandmark, afterLandmark, ordinal, next, distance, now }

    /// One side-word per ``ManeuverType``, per locale. Used to interpolate
    /// the per-pattern templates below.
    private static func sideWord(for type: ManeuverType, locale: String) -> String? {
        let lc = locale.lowercased()
        let isArabic = lc.hasPrefix("ar")
        switch type {
        case .left, .slightLeft:    return isArabic ? "شمال" : "left"
        case .sharpLeft:            return isArabic ? "شمال حاد" : "sharp left"
        case .right, .slightRight:  return isArabic ? "يمين" : "right"
        case .sharpRight:           return isArabic ? "يمين حاد" : "sharp right"
        case .uturn:                return isArabic ? "عكس الاتجاه" : "U-turn"
        default:                    return nil
        }
    }

    private static func ordinalWord(_ n: Int, locale: String) -> String {
        let lc = locale.lowercased()
        if lc.hasPrefix("ar") {
            // Arabic ordinals 1..5 — matches the proxy's eyes-off
            // ordinal copy so the grammar is consistent across both
            // baked and reasoner-emitted cues.
            switch n {
            case 1: return "الأول"
            case 2: return "التاني"
            case 3: return "التالت"
            case 4: return "الرابع"
            case 5: return "الخامس"
            default: return "\(n)"
            }
        }
        // English-style ordinals; same surface for en-US / en-GB.
        switch n {
        case 1: return "next"           // "the next left"
        case 2: return "second"
        case 3: return "third"
        case 4: return "fourth"
        case 5: return "fifth"
        default: return "\(n)th"
        }
    }

    private static func render(
        _ pattern: Pattern, side: String, locale: String, value: String
    ) -> String {
        let lc = locale.lowercased()
        let isArabic = lc.hasPrefix("ar")
        switch pattern {
        case .atLandmark:
            // Near phase: "Turn left at McDonald's." Used at the moment
            // of action — the rider is on top of the landmark.
            if isArabic { return "حوّد \(side) عند \(value)." }
            return "Turn \(side) at \(value)."
        case .afterLandmark:
            // Mid phase: "After McDonald's, turn left." Used at ~15 s
            // out when the rider can plausibly see the landmark
            // already but the turn itself is still ahead.
            if isArabic { return "بعد \(value)، حوّد \(side)." }
            return "After \(value), turn \(side)."
        case .ordinal:
            // Near phase: "Take the second left." / "خد الشمال التاني."
            if isArabic { return "خد ال\(side) \(value)." }
            return "Take the \(value) \(side)."
        case .next:
            // Near phase: "Take the next left." / "خد الشمال الجاي."
            // Spoken only when the corridor proved there is exactly
            // one same-side turn ahead.
            if isArabic { return "خد ال\(side) الجاي." }
            return "Take the next \(side)."
        case .distance:
            // Far / mid phase: "Turn left in 80 metres."
            // / "بعد 80 متر حوّد شمال." The rider hears a number that
            // matches the banner exactly; no ordinal claim.
            if isArabic { return "بعد \(value) متر حوّد \(side)." }
            return "Turn \(side) in \(value) metres."
        case .now:
            // Near phase fallback when no landmark + no ordinal proof:
            // a plain action form. Less informative than the other
            // near-phase forms but never wrong.
            if isArabic { return "حوّد \(side) دلوقتي." }
            return "Turn \(side) now."
        }
    }
}
