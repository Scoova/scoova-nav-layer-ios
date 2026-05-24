import SwiftUI
import ScoovaNavLayerCore

/// Drop-in maneuver banner. Bind to `ScoovaNavLayer.currentInstruction`:
///
/// ```swift
/// @StateObject var nav: ScoovaNavLayer
/// var body: some View {
///     ZStack(alignment: .top) {
///         // your map …
///         if let cue = nav.currentInstruction {
///             ScoovaManeuverBanner(cue: cue).padding()
///         }
///     }
/// }
/// ```
public struct ScoovaManeuverBanner: View {
    public let cue: ScoovaNavLayer.DisplayCue
    public var showPhase: Bool
    public var style: ScoovaUIStyle

    public init(
        cue: ScoovaNavLayer.DisplayCue,
        showPhase: Bool = true,
        style: ScoovaUIStyle = .default
    ) {
        self.cue = cue
        self.showPhase = showPhase
        self.style = style
    }

    public var body: some View {
        // Text source priority:
        //   1. cue.maneuver.bannerVerb — the server's scoova.banner.verb,
        //      the canonical eyes-on-road copy identical across all 5 SDKs
        //   2. cue.text — legacy / third-party adapters that don't ship
        //      a scoova block (falls back to dialect-aware synthesized phrase)
        let primary = (cue.maneuver.bannerVerb?.isEmpty == false ? cue.maneuver.bannerVerb : nil) ?? cue.text
        let anchor: String? = (cue.maneuver.bannerAnchor?.isEmpty == false) ? cue.maneuver.bannerAnchor : nil
        return VStack(alignment: .leading, spacing: 6) {
            if showPhase {
                Text(phaseLabel(cue.phase))
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(style.muted)
            }
            HStack(spacing: 14) {
                ArrowChip(type: cue.maneuver.type, color: style.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(primary)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(style.text)
                        .lineLimit(1)
                    if let anchor = anchor {
                        Text(anchor)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(style.muted)
                            .lineLimit(1)
                    }
                    if cue.metersToManeuver.isFinite && cue.metersToManeuver > 5 {
                        Text(formatDistance(cue.metersToManeuver))
                            .font(.system(size: 13))
                            .foregroundStyle(style.muted)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(style.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(style.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 10)
    }
}

private struct ArrowChip: View {
    let type: ManeuverType
    let color: Color
    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.15))
            Circle()
                .strokeBorder(color, lineWidth: 2)
            Image(systemName: symbolFor(type))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: 60, height: 60)
    }
    private func symbolFor(_ type: ManeuverType) -> String {
        if type.isRightSide { return "arrow.turn.up.right" }
        if type.isLeftSide  { return "arrow.turn.up.left" }
        switch type {
        case .uturn:           return "arrow.uturn.up"
        case .arrive:          return "flag.fill"
        case .roundaboutEnter,
             .roundaboutExit:  return "arrow.triangle.2.circlepath"
        default:               return "arrow.up"
        }
    }
}

private func phaseLabel(_ phase: CuePhrases.Phase) -> String {
    switch phase {
    case .far: return "GET READY"
    case .mid: return "NEXT"
    case .near: return "NOW"
    }
}

private func formatDistance(_ m: Double) -> String {
    if m < 1000 { return "\(Int(m)) m" }
    return String(format: "%.1f km", m / 1000)
}
