import SwiftUI

/// Drop-in route preview card. Renders distance, ETA, optional profile
/// pill, optional error / loading states, and a primary "Start" CTA.
public struct ScoovaRoutePreviewCard: View {
    public var destinationLabel: String?
    public var distanceKm: Double
    public var etaMinutes: Int
    public var profileLabel: String?
    public var profileAccent: Color?
    public var isLoading: Bool
    public var error: String?
    public var secondaryLabel: String
    public var onStart: () -> Void
    public var onSecondary: (() -> Void)?
    public var style: ScoovaUIStyle

    public init(
        destinationLabel: String?,
        distanceKm: Double,
        etaMinutes: Int,
        profileLabel: String? = nil,
        profileAccent: Color? = nil,
        isLoading: Bool = false,
        error: String? = nil,
        secondaryLabel: String = "Simulate",
        onStart: @escaping () -> Void = {},
        onSecondary: (() -> Void)? = nil,
        style: ScoovaUIStyle = .default
    ) {
        self.destinationLabel = destinationLabel
        self.distanceKm = distanceKm
        self.etaMinutes = etaMinutes
        self.profileLabel = profileLabel
        self.profileAccent = profileAccent
        self.isLoading = isLoading
        self.error = error
        self.secondaryLabel = secondaryLabel
        self.onStart = onStart
        self.onSecondary = onSecondary
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(destinationLabel ?? "Route preview")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(style.text)
                .lineLimit(1)
            Spacer().frame(height: 4)
            Text(String(format: "%.1f km · %d min", distanceKm, etaMinutes))
                .font(.system(size: 13))
                .foregroundStyle(style.muted)

            if isLoading {
                Spacer().frame(height: 10)
                Text("Planning route…")
                    .font(.system(size: 13))
                    .foregroundStyle(style.accent)
            }
            if let err = error, !err.isEmpty {
                Spacer().frame(height: 10)
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(style.error)
            }

            Spacer().frame(height: 14)
            HStack(spacing: 8) {
                StatBlock(label: "DISTANCE",
                          value: String(format: "%.1f km", distanceKm),
                          valueColor: style.text, style: style)
                StatBlock(label: "EST. TIME",
                          value: "\(etaMinutes) min",
                          valueColor: style.warning, style: style)
                if let p = profileLabel, !p.isEmpty {
                    StatBlock(label: "PROFILE",
                              value: p,
                              valueColor: profileAccent ?? style.success, style: style)
                }
            }

            Spacer().frame(height: 16)
            HStack(spacing: 8) {
                if let onSec = onSecondary {
                    Button(action: onSec) {
                        Text(secondaryLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(style.text)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(style.surfaceRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(style.border, lineWidth: 1)
                            )
                    }
                }
                Button(action: onStart) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Start ride").font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(colors: [style.accentSoft, style.accent],
                                                 startPoint: .top, endPoint: .bottom))
                    )
                }
            }
        }
        .padding(20)
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

private struct StatBlock: View {
    let label: String
    let value: String
    let valueColor: Color
    let style: ScoovaUIStyle
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(style.muted)
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
