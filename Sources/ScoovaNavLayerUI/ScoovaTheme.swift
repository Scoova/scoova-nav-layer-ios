import SwiftUI

/// Shared style across the Scoova Nav Layer UI components. White-label
/// integrators override the `accent` / `surface` etc. to brand the UI.
public struct ScoovaUIStyle: Sendable {
    public var surface: Color
    public var surfaceRaised: Color
    public var border: Color
    public var text: Color
    public var muted: Color
    public var accent: Color
    public var accentSoft: Color
    public var success: Color
    public var warning: Color
    public var error: Color

    public static let `default` = ScoovaUIStyle(
        surface:       Color(red: 15/255, green: 20/255, blue: 33/255),    // #0F1421
        surfaceRaised: Color(red: 26/255, green: 31/255, blue: 46/255),    // #1A1F2E
        border:        Color(red: 45/255, green: 53/255, blue: 72/255),    // #2D3548
        text:          .white,
        muted:         Color(red: 148/255, green: 163/255, blue: 184/255), // #94A3B8
        accent:        Color(red: 14/255, green: 165/255, blue: 233/255),  // #0EA5E9
        accentSoft:    Color(red: 56/255, green: 189/255, blue: 248/255),  // #38BDF8
        success:       Color(red: 132/255, green: 204/255, blue: 22/255),  // #84CC16
        warning:       Color(red: 245/255, green: 158/255, blue: 11/255),  // #F59E0B
        error:         Color(red: 239/255, green: 68/255,  blue: 68/255)   // #EF4444
    )

    public init(
        surface: Color, surfaceRaised: Color, border: Color,
        text: Color, muted: Color, accent: Color, accentSoft: Color,
        success: Color, warning: Color, error: Color
    ) {
        self.surface = surface
        self.surfaceRaised = surfaceRaised
        self.border = border
        self.text = text
        self.muted = muted
        self.accent = accent
        self.accentSoft = accentSoft
        self.success = success
        self.warning = warning
        self.error = error
    }
}
