import Foundation

/// Phase-based cue phrasing for hands-busy navigation.
///
/// Three phases per maneuver:
///   • far  — "Get ready to turn left ahead" / "استعد، حوّد شمال قريب"
///   • mid  — "Turn left at the next street" / "في الشارع اللي جاي حوّد شمال"
///   • near — "Turn left now" / "حوّد شمال دلوقتي"
///
/// 7 locales: ar-EG (Egyptian colloquial), ar (MSA), en, fr, de, es, tr.
public enum CuePhrases {

    public enum Phase: Sendable { case far, mid, near }

    public static func pickPhase(thresholdsMeters: [Int], firedThresholdM: Int) -> Phase {
        guard !thresholdsMeters.isEmpty, firedThresholdM > 0 else { return .mid }
        let sorted = thresholdsMeters.sorted()
        if firedThresholdM <= sorted.first! { return .near }
        if firedThresholdM >= sorted.last!  { return .far }
        return .mid
    }

    public static func build(
        lang: String,
        maneuver: ManeuverEvent,
        firedThresholdM: Int,
        thresholdsMeters: [Int],
        landmark: String? = nil
    ) -> String {
        let phase = pickPhase(thresholdsMeters: thresholdsMeters, firedThresholdM: firedThresholdM)
        let type = maneuver.type

        // Roundabouts: the host SDK already encodes "take the Nth exit". Pass-through.
        if type.isRoundabout {
            return maneuver.rawInstruction
                ?? localized(lang: lang, phase: phase, side: .other, setting: .generic, landmark: landmark)
        }
        if type == .depart || type == .arrive {
            return maneuver.rawInstruction
                ?? localized(lang: lang, phase: phase, side: .other, setting: .generic, landmark: landmark)
        }

        let side: Side
        if type.isUturn { side = .uturn }
        else if type == .`continue` || type == .stayStraight { side = .straight }
        else if type.isLeftSide  { side = .left }
        else if type.isRightSide { side = .right }
        else { side = .other }

        let setting: Setting
        if type.isExit { setting = .exit }
        else if type == .stayLeft || type == .stayRight || type == .merge { setting = .highway }
        else if type == .arrive { setting = .destination }
        else if [.left, .right, .sharpLeft, .sharpRight, .slightLeft, .slightRight].contains(type) {
            setting = .street
        }
        else { setting = .generic }

        return localized(lang: lang, phase: phase, side: side, setting: setting, landmark: landmark)
    }

    private enum Side { case left, right, straight, uturn, other }
    private enum Setting { case street, exit, roundabout, highway, destination, generic }

    private static func localized(lang: String, phase: Phase, side: Side, setting: Setting, landmark: String?) -> String {
        let raw: String
        if lang.hasPrefix("ar-EG") { raw = egyptian(phase: phase, side: side, setting: setting) }
        else if lang.hasPrefix("ar") { raw = msa(phase: phase, side: side, setting: setting) }
        else if lang.hasPrefix("fr") { raw = french(phase: phase, side: side, setting: setting) }
        else if lang.hasPrefix("de") { raw = german(phase: phase, side: side, setting: setting) }
        else if lang.hasPrefix("es") { raw = spanish(phase: phase, side: side, setting: setting) }
        else if lang.hasPrefix("tr") { raw = turkish(phase: phase, side: side, setting: setting) }
        else                         { raw = english(phase: phase, side: side, setting: setting) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = landmark, !name.isEmpty else { return trimmed }
        return appendLandmark(lang: lang, base: trimmed, name: name)
    }

    private static func appendLandmark(lang: String, base: String, name: String) -> String {
        let inline: String
        if lang.hasPrefix("ar") { inline = "، عند \(name)" }
        else if lang.hasPrefix("fr") { inline = " à \(name)" }
        else if lang.hasPrefix("de") { inline = " bei \(name)" }
        else if lang.hasPrefix("es") { inline = " en \(name)" }
        else if lang.hasPrefix("tr") { inline = " \(name) yanında" }
        else                         { inline = " at \(name)" }
        if base.hasSuffix(".") { return String(base.dropLast()) + inline + "." }
        return base + inline + "."
    }

    // MARK: — Locale tables ----------------------------------------------

    private static func egyptian(phase: Phase, side: Side, setting: Setting) -> String {
        let verb: String = {
            switch side {
            case .left: return "حوّد شمال"
            case .right: return "حوّد يمين"
            case .uturn: return "اعمل يو تيرن"
            case .straight: return "كمل على طول"
            case .other: return "كمل"
            }
        }()
        let landmark: String
        switch setting {
        case .exit:    landmark = "خد المخرج اللي جاي"
        case .highway: landmark = "فضل في حارة جنب الجاي"
        default:
            landmark = (side == .left || side == .right) ? "في الشارع اللي جاي" : "قدامك"
        }
        switch phase {
        case .far:
            return setting == .exit ? "استعد، المخرج قريب" : "استعد، \(verb) قريب"
        case .mid:
            switch setting {
            case .exit: return "خد المخرج اللي جاي"
            case .highway: return landmark
            default: return "\(landmark) \(verb)"
            }
        case .near:
            return setting == .exit ? "خد المخرج دلوقتي" : "\(verb) دلوقتي"
        }
    }

    private static func msa(phase: Phase, side: Side, setting: Setting) -> String {
        let verb: String = {
            switch side {
            case .left: return "انعطف يساراً"
            case .right: return "انعطف يميناً"
            case .uturn: return "استدر"
            case .straight: return "تابع مستقيماً"
            case .other: return "تابع"
            }
        }()
        switch phase {
        case .far:
            return setting == .exit ? "استعد، المخرج قريب" : "استعد، \(verb) قريباً"
        case .mid:
            switch setting {
            case .exit: return "خذ المخرج التالي"
            case .highway: return "ابقَ في المسار التالي"
            default: return "\(verb) عند الشارع التالي"
            }
        case .near:
            return setting == .exit ? "خذ المخرج الآن" : "\(verb) الآن"
        }
    }

    private static func english(phase: Phase, side: Side, setting: Setting) -> String {
        let verb: String = {
            switch side {
            case .left: return "turn left"
            case .right: return "turn right"
            case .uturn: return "make a U-turn"
            case .straight: return "keep going straight"
            case .other: return "keep going"
            }
        }()
        switch phase {
        case .far:
            return setting == .exit ? "Get ready, exit ahead" : "Get ready to \(verb) ahead"
        case .mid:
            switch setting {
            case .exit: return "Take the next exit"
            case .highway: return "Stay in the next lane"
            default: return "\(verb.capitalizedFirst) at the next street"
            }
        case .near:
            return setting == .exit ? "Take the exit now" : "\(verb.capitalizedFirst) now"
        }
    }

    private static func french(phase: Phase, side: Side, setting: Setting) -> String {
        let verb: String = {
            switch side {
            case .left: return "tournez à gauche"
            case .right: return "tournez à droite"
            case .uturn: return "faites demi-tour"
            case .straight: return "continuez tout droit"
            case .other: return "continuez"
            }
        }()
        let base: String
        switch phase {
        case .far:
            base = setting == .exit ? "Préparez-vous, sortie proche" : "Préparez-vous, \(verb)"
        case .mid:
            switch setting {
            case .exit: base = "Prenez la prochaine sortie"
            case .highway: base = "Restez sur la prochaine voie"
            default: base = "À la prochaine rue, \(verb)"
            }
        case .near:
            base = setting == .exit ? "Prenez la sortie maintenant" : "\(verb) maintenant"
        }
        return base.capitalizedFirst
    }

    private static func german(phase: Phase, side: Side, setting: Setting) -> String {
        let verb: String = {
            switch side {
            case .left: return "links abbiegen"
            case .right: return "rechts abbiegen"
            case .uturn: return "wenden"
            case .straight: return "geradeaus weiter"
            case .other: return "weiter"
            }
        }()
        let base: String
        switch phase {
        case .far:
            base = setting == .exit ? "Bereit machen, Ausfahrt voraus" : "Bereit machen, gleich \(verb)"
        case .mid:
            switch setting {
            case .exit: base = "Nehmen Sie die nächste Ausfahrt"
            case .highway: base = "Bleiben Sie auf der nächsten Spur"
            default: base = "An der nächsten Straße \(verb)"
            }
        case .near:
            base = setting == .exit ? "Jetzt die Ausfahrt nehmen" : "Jetzt \(verb)"
        }
        return base.capitalizedFirst
    }

    private static func spanish(phase: Phase, side: Side, setting: Setting) -> String {
        let verb: String = {
            switch side {
            case .left: return "gira a la izquierda"
            case .right: return "gira a la derecha"
            case .uturn: return "haz un cambio de sentido"
            case .straight: return "sigue recto"
            case .other: return "sigue"
            }
        }()
        let base: String
        switch phase {
        case .far:
            base = setting == .exit ? "Prepárate, salida cerca" : "Prepárate, vas a \(verb)"
        case .mid:
            switch setting {
            case .exit: base = "Toma la siguiente salida"
            case .highway: base = "Mantente en el siguiente carril"
            default: base = "En la próxima calle, \(verb)"
            }
        case .near:
            base = setting == .exit ? "Toma la salida ahora" : "\(verb) ahora"
        }
        return base.capitalizedFirst
    }

    private static func turkish(phase: Phase, side: Side, setting: Setting) -> String {
        let verb: String = {
            switch side {
            case .left: return "sola dön"
            case .right: return "sağa dön"
            case .uturn: return "U dönüşü yap"
            case .straight: return "düz devam et"
            case .other: return "devam et"
            }
        }()
        let base: String
        switch phase {
        case .far:
            base = setting == .exit ? "Hazırlan, çıkış yakın" : "Hazırlan, birazdan \(verb)"
        case .mid:
            switch setting {
            case .exit: base = "Bir sonraki çıkıştan çık"
            case .highway: base = "Bir sonraki şeritte kal"
            default: base = "Bir sonraki sokakta \(verb)"
            }
        case .near:
            base = setting == .exit ? "Şimdi çıkıştan çık" : "Şimdi \(verb)"
        }
        return base.capitalizedFirst
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
