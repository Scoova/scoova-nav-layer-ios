import SwiftUI

/// Scoova Ride — iOS. Consumer turn-by-turn navigation built on the
/// ScoovaNavLayer SDK. Sibling of the Android `scoova-nav-layer-android`
/// demo app: same phases, same Eye-on-Road guidance.
@main
struct ScoovaRideApp: App {
    @StateObject private var model = RideModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

/// Routes the single window to the screen for the current phase.
struct RootView: View {
    @EnvironmentObject var model: RideModel

    var body: some View {
        switch model.phase {
        case .onboarding: OnboardingView()
        case .persona:    PersonaView()
        case .plan:       PlanView()
        case .ride:       RideView()
        case .summary:    SummaryView()
        }
    }
}
