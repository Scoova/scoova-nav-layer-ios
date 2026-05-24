import SwiftUI

/// Device picker. The rider chooses what they're travelling on — that
/// drives the routing profile and the pace of the spoken cues.
struct PersonaView: View {
    @EnvironmentObject var model: RideModel

    var body: some View {
        AppBackground {
            VStack(alignment: .leading, spacing: 0) {
                Text("How are you getting there?")
                    .font(.title.bold())
                    .foregroundColor(RideTokens.text)
                    .padding(.horizontal, 24)
                    .padding(.top, 32)

                Text("Pick your device — you can switch any time.")
                    .font(.subheadline)
                    .foregroundColor(RideTokens.textMuted)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Profile.allCases) { profile in
                            personaRow(profile)
                        }
                    }
                    .padding(24)
                }
            }
        }
    }

    private func personaRow(_ profile: Profile) -> some View {
        Button {
            model.selectProfile(profile)
        } label: {
            RideCard {
                HStack(spacing: 16) {
                    PersonaBadge(profile: profile, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.display)
                            .font(.headline)
                            .foregroundColor(RideTokens.text)
                        Text(profile.tagline)
                            .font(.caption)
                            .foregroundColor(RideTokens.textMuted)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(RideTokens.textMuted)
                }
                .padding(16)
            }
            .overlay(
                RoundedRectangle(cornerRadius: RideTokens.corner, style: .continuous)
                    .stroke(profile.accent.opacity(0.5), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
