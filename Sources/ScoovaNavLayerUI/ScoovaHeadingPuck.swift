import SwiftUI

/// Compass-driven heading puck. Bind to `ScoovaNavLayer.headingDeg`.
public struct ScoovaHeadingPuck: View {
    public let headingDeg: Float
    public var size: CGFloat
    public var style: ScoovaUIStyle

    public init(
        headingDeg: Float,
        size: CGFloat = 88,
        style: ScoovaUIStyle = .default
    ) {
        self.headingDeg = headingDeg
        self.size = size
        self.style = style
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(style.accent.opacity(0.22))
                .frame(width: size, height: size)
            Circle()
                .strokeBorder(style.accent, lineWidth: 2)
                .frame(width: size * 0.55, height: size * 0.55)
            // Heading arrow
            Image(systemName: "location.north.fill")
                .font(.system(size: size * 0.30, weight: .bold))
                .foregroundStyle(style.accent)
                .rotationEffect(.degrees(Double(headingDeg)))
        }
        .accessibilityLabel("Heading \(Int(headingDeg)) degrees")
    }
}
