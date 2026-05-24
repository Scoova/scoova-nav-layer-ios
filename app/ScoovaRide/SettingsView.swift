import SwiftUI

/// Settings tab. Notably hosts the "Record rides" master switch —
/// riders who only want turn-by-turn guidance can opt out of all
/// tracking (history, route trail, the Summary screen).
struct SettingsView: View {
    @EnvironmentObject var model: RideModel

    var body: some View {
        NavigationView {
            ZStack {
                RideTokens.appGradient.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        section("Trips") {
                            toggleRow(
                                "Save trip history",
                                "Keep each finished trip — its route, distance and time — in History. Turn off to navigate without logging anything.",
                                isOn: settingBinding(\.recordRides, model.setRecordRides)
                            )
                        }
                        section("Voice") {
                            toggleRow("Spoken guidance",
                                      "Speak turn-by-turn cues aloud.",
                                      isOn: settingBinding(\.voiceEnabled, model.setVoiceEnabled))
                            rowDivider
                            toggleRow("Eyes on the road",
                                      "Anchor cues on what you can see instead of distances — so you can navigate without looking at the phone.",
                                      isOn: settingBinding(\.eyesOff, model.setEyesOff))
                            rowDivider
                            toggleRow("Spatial audio",
                                      "Play a left turn in your left ear, a right turn in your right.",
                                      isOn: settingBinding(\.spatialAudio, model.setSpatialAudio))
                        }
                        section("Units") {
                            toggleRow("Metric",
                                      "Show distances in kilometres. Off shows miles.",
                                      isOn: settingBinding(\.unitsMetric, model.setUnitsMetric))
                        }
                        section("Language") {
                            localeRow
                        }
                        section("You") {
                            tapRow("Change device", model.profile?.display ?? "Not set") {
                                model.changeProfile()
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 110)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }

    // ── Row builders ─────────────────────────────────────────────────

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(RideTokens.textMuted)
                .padding(.leading, 4)
            RideCard {
                VStack(spacing: 0) { content() }
            }
        }
    }

    private func toggleRow(_ title: String, _ desc: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundColor(RideTokens.text)
                Text(desc)
                    .font(.caption)
                    .foregroundColor(RideTokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(RideTokens.accent)
        }
        .padding(16)
    }

    private func tapRow(_ title: String, _ value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundColor(RideTokens.text)
                Spacer()
                Text(value)
                    .font(.subheadline)
                    .foregroundColor(RideTokens.textMuted)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(RideTokens.textMuted)
            }
            .padding(16)
        }
        .buttonStyle(.plain)
    }

    private var localeRow: some View {
        Menu {
            ForEach(scoovaLocales) { loc in
                Button(loc.display) { model.setLocale(loc.tag) }
            }
        } label: {
            HStack {
                Text("Voice language")
                    .font(.body.weight(.medium))
                    .foregroundColor(RideTokens.text)
                Spacer()
                Text(currentLocaleDisplay)
                    .font(.subheadline)
                    .foregroundColor(RideTokens.textMuted)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundColor(RideTokens.textMuted)
            }
            .padding(16)
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(RideTokens.border)
            .frame(height: 1)
            .padding(.leading, 16)
    }

    private var currentLocaleDisplay: String {
        scoovaLocales.first { $0.tag == model.settings.locale }?.display ?? model.settings.locale
    }

    private func settingBinding(
        _ keyPath: KeyPath<RideSettings, Bool>,
        _ setter: @escaping (Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { setter($0) }
        )
    }
}
