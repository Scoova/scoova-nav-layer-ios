import SwiftUI

/// Full-screen navigation. The map follows the rider heading-up while
/// the SDK speaks the turn-by-turn cues; the banner mirrors the current
/// spoken instruction for a quick glance.
struct RideView: View {
    @EnvironmentObject var model: RideModel
    @State private var showEndConfirm = false

    var body: some View {
        ZStack {
            RideMap(
                routeShape: model.routeShape,
                destination: model.destination?.coordinate,
                followUser: true,
                simLocation: model.isSimulating ? model.simLocation : nil,
                locale: model.settings.locale,
                mode: (model.profile ?? .bicycle).pathHighlightMode,
                headingDeg: model.isSimulating ? model.simBearing : model.headingDeg,
                onLongPress: nil
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                cueBanner
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    private var cueBanner: some View {
        RideCard {
            HStack(spacing: 14) {
                if model.isRerouting {
                    // Off-route — never leave the rider wondering; the
                    // banner says a fresh route is on the way.
                    ProgressView().tint(RideTokens.accent)
                    Text("Rerouting…")
                        .font(.headline)
                        .foregroundColor(RideTokens.text)
                    Spacer()
                } else {
                    // A turn-direction glyph — points where to turn, not
                    // where the rider is facing.
                    Image(systemName: model.currentManeuverSymbol)
                        .foregroundColor(model.profile?.accent ?? RideTokens.accent)
                        .font(.title2)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        // Glanceable distance-to-turn — visual only;
                        // the spoken cue stays measurement-free.
                        if let distance = model.maneuverDistanceText {
                            Text(distance)
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(model.profile?.accent ?? RideTokens.accent)
                        }
                        Text(model.currentCueText ?? "Head to your route")
                            .font(.headline)
                            .foregroundColor(RideTokens.text)
                        // Server-rendered landmark anchor — the eyes-off
                        // detail that tells the rider where the turn is.
                        if let anchor = model.currentCueAnchor, !anchor.isEmpty {
                            Text(anchor)
                                .font(.subheadline)
                                .foregroundColor(RideTokens.textMuted)
                        }
                    }
                    Spacer()
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.2), value: model.isRerouting)
        }
    }

    private var bottomBar: some View {
        RideCard {
            VStack(spacing: 16) {
                HStack(spacing: 28) {
                    stat(RideFormat.distance(km: model.coveredKm,
                                             metric: model.settings.unitsMetric),
                         "covered")
                    stat(remainingText, "to go")
                }
                Button("End") { showEndConfirm = true }
                    .buttonStyle(PrimaryButtonStyle(tint: RideTokens.danger))
            }
            .padding(18)
        }
        .confirmationDialog("End this ride?", isPresented: $showEndConfirm,
                            titleVisibility: .visible) {
            Button("End ride", role: .destructive) { model.endRide() }
            Button("Keep going", role: .cancel) { }
        } message: {
            Text("You'll go to your trip summary.")
        }
    }

    private var remainingText: String {
        let remaining = max(0, model.routeDistanceKm - model.coveredKm)
        return RideFormat.distance(km: remaining, metric: model.settings.unitsMetric)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .foregroundColor(RideTokens.text)
            Text(label)
                .font(.caption2)
                .foregroundColor(RideTokens.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}
