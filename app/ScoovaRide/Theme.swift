import SwiftUI

/// Scoova brand — orange-on-ink, ported verbatim from the Android demo's
/// `RideTokens`. Orange is the brand (primary action, accent, persona
/// pills). Cyan (`routeCore`) is reserved for the map route polyline and
/// turn arrow only — never a generic UI accent.
enum RideTokens {
    // Surface stack — near-black → ink.
    static let bgTop         = Color(hex: 0x000000)
    static let bgBottom      = Color(hex: 0x0A0A14)
    static let surface       = Color(hex: 0x1A1A1D)
    static let surface2      = Color(hex: 0x22232A)
    static let surface3      = Color(hex: 0x2C2D35)
    static let border        = Color.white.opacity(0.15)
    static let text          = Color.white
    static let textMuted     = Color.white.opacity(0.70)
    static let muted         = Color(hex: 0x8A8E96)

    // Brand orange.
    static let accent        = Color(hex: 0xFF6A00)
    static let accentAlt     = Color(hex: 0xFF3D00)
    static let accentSoft    = Color(hex: 0xFF8B40)

    // Map route — cyan, polyline + turn arrow only.
    static let routeCore     = Color(hex: 0x2EA8FF)

    // Status.
    static let success       = Color(hex: 0x22C55E)
    static let warning       = Color(hex: 0xF59E0B)
    static let danger        = Color(hex: 0xEF4444)

    // Back-compat aliases for screens written against the old names.
    static let bg            = bgTop
    static let surfaceRaised = surface2

    static let corner: CGFloat = 18

    /// Signature vertical background gradient.
    static let appGradient = LinearGradient(
        colors: [bgTop, bgBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Primary-action button gradient (orange, horizontal).
    static let primaryButton = LinearGradient(
        colors: [accent, accentAlt],
        startPoint: .leading,
        endPoint: .trailing
    )
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255
        )
    }
}

/// Full-bleed dark gradient backdrop used by every non-map screen.
struct AppBackground<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            RideTokens.appGradient.ignoresSafeArea()
            content
        }
    }
}

/// Rounded raised card — settings rows, persona tiles, the route sheet.
struct RideCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(RideTokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: RideTokens.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RideTokens.corner, style: .continuous)
                    .stroke(RideTokens.border, lineWidth: 1)
            )
    }
}

/// Primary call-to-action — orange gradient fill.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Group {
                    if let tint = tint {
                        tint
                    } else {
                        RideTokens.primaryButton
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A floating pill/capsule surface — the building block for every
/// on-map control (search, persona, chips, FABs).
struct FloatingSurface<Content: View>: View {
    var cornerRadius: CGFloat = 24
    var stroke: Color = RideTokens.border
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(RideTokens.surface.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }
}
