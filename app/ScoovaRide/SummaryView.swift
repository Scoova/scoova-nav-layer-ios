import SwiftUI

/// The post-ride moment. The instant a ride ends, the rider lands here —
/// a calm recap that says, in one screen, the thing the whole product
/// is about: you got there. Then a single tap back to the map.
struct SummaryView: View {
    @EnvironmentObject var model: RideModel
    @State private var appeared = false

    var body: some View {
        AppBackground {
            VStack(spacing: 0) {
                Spacer(minLength: 20)

                arrivalMark

                Text("You've arrived")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundColor(RideTokens.text)
                    .padding(.top, 18)

                if let dest = model.lastTrip?.destination, !dest.isEmpty {
                    Text(dest)
                        .font(.subheadline)
                        .foregroundColor(RideTokens.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                        .padding(.horizontal, 32)
                }

                Spacer(minLength: 28)

                if let trip = model.lastTrip {
                    recap(trip).padding(.horizontal, 20)
                }

                Spacer()

                Button("Done") { model.dismissSummary() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                appeared = true
            }
        }
    }

    /// A checkmark in a soft accent halo — springs in on appear.
    private var arrivalMark: some View {
        ZStack {
            Circle()
                .fill(RideTokens.accent.opacity(0.16))
                .frame(width: 104, height: 104)
            Circle()
                .stroke(RideTokens.accent.opacity(0.35), lineWidth: 2)
                .frame(width: 104, height: 104)
            Image(systemName: "checkmark")
                .font(.system(size: 42, weight: .bold))
                .foregroundColor(RideTokens.accent)
        }
        .scaleEffect(appeared ? 1 : 0.6)
    }

    /// The route line + the trip's headline stats.
    private func recap(_ trip: TripRecord) -> some View {
        RideCard {
            VStack(spacing: 16) {
                RouteThumbnail(route: trip.route)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 0) {
                    stat(RideFormat.distance(km: trip.distanceKm,
                                             metric: model.settings.unitsMetric),
                         "Distance")
                    divider
                    stat(RideFormat.duration(minutes: trip.durationMin), "Time")
                    if !trip.mode.isEmpty {
                        divider
                        stat(trip.mode, "Mode")
                    }
                }
            }
            .padding(18)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(RideTokens.border)
            .frame(width: 1, height: 34)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(RideTokens.text)
            Text(label)
                .font(.caption2)
                .foregroundColor(RideTokens.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}
