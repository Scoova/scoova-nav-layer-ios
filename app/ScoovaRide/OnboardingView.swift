import SwiftUI

/// First-launch value-prop tour. Three pages explaining what makes
/// Scoova's navigation different, then a single "Get started" button.
struct OnboardingView: View {
    @EnvironmentObject var model: RideModel
    @State private var page = 0

    private struct Slide {
        let icon: String    // SF Symbol — renders crisp at any size,
                            // never tofus the way an emoji can.
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        Slide(
            icon: "eye.slash.fill",
            title: "Navigation you don't have to look at",
            body: "Scoova guides you with spoken cues anchored on what you can actually see — the road ahead, the turn count, real landmarks."
        ),
        Slide(
            icon: "headphones",
            title: "Cues in the right ear",
            body: "Spatial audio plays a left turn in your left ear and a right turn in your right. Keep your eyes on the road."
        ),
        Slide(
            icon: "figure.walk.motion",
            title: "Built for how you move",
            body: "On foot, bicycle, scooter, motorcycle or car — Scoova routes and paces its guidance to your device."
        ),
    ]

    var body: some View {
        AppBackground {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(slides.indices, id: \.self) { i in
                        slideView(slides[i]).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button(action: advance) {
                    Text(page == slides.count - 1 ? "Get started" : "Next")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                Button("Skip") { model.finishOnboarding() }
                    .foregroundColor(RideTokens.textMuted)
                    .padding(.bottom, 24)
            }
        }
    }

    private func slideView(_ s: Slide) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: s.icon)
                .font(.system(size: 66, weight: .medium))
                .foregroundColor(RideTokens.accent)
                .frame(height: 96)
            Text(s.title)
                .font(.title.bold())
                .foregroundColor(RideTokens.text)
                .multilineTextAlignment(.center)
            Text(s.body)
                .font(.body)
                .foregroundColor(RideTokens.textMuted)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func advance() {
        if page < slides.count - 1 {
            withAnimation { page += 1 }
        } else {
            model.finishOnboarding()
        }
    }
}
