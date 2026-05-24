import SwiftUI
import UIKit

/// The five movers Scoova ships with — keyed on the DEVICE the rider is
/// travelling on, not the activity. Walking and running are the same
/// device (your feet), so they collapse into one "On foot" profile;
/// what changes the routing + cue behaviour is the vehicle.
///
/// Identical set + ids to the Android demo's `Profile` enum so a rider's
/// choice means the same thing on either platform.
enum Profile: String, CaseIterable, Identifiable, Codable {
    case foot
    case bicycle
    case scooter
    case motorcycle
    case car

    var id: String { rawValue }

    var display: String {
        switch self {
        case .foot:       return "On foot"
        case .bicycle:    return "Bicycle"
        case .scooter:    return "Scooter"
        case .motorcycle: return "Motorcycle"
        case .car:        return "Car"
        }
    }

    /// SF Symbol for the device — a clean monochrome glyph, rendered in
    /// `PersonaBadge`. Replaces the old casual emoji.
    var icon: String {
        switch self {
        case .foot:       return "figure.walk"
        case .bicycle:    return "bicycle"
        case .scooter:    return "scooter"
        case .motorcycle: return "motorcycle"
        case .car:        return "car.fill"
        }
    }

    /// A glyph guaranteed to exist on every supported iOS — used by
    /// `PersonaBadge` when `icon` isn't in this device's SF Symbols set
    /// (`scooter` is iOS 17+, `motorcycle` newer still), so the badge
    /// never renders a blank box.
    var fallbackIcon: String {
        switch self {
        case .foot:                           return "figure.walk"
        case .bicycle, .scooter, .motorcycle: return "bicycle"
        case .car:                            return "car.fill"
        }
    }

    var tagline: String {
        switch self {
        case .foot:       return "Walking or running — calm cues, sidewalk routes."
        case .bicycle:    return "Bike routes. Mid-range cues."
        case .scooter:    return "Scooter pace. Curb-aware."
        case .motorcycle: return "Motorbike routes. Quick, urgent cues."
        case .car:        return "Highway speeds. Eyes up."
        }
    }

    /// The Valhalla costing profile asked of Scoova's routing engine.
    ///
    /// Scoova's `scooter` is the urban kick / e-scooter — the same lane
    /// vocabulary as a bike, not the Vespa-class motor scooter Valhalla's
    /// `scooter` costing was designed for. We route it as `bicycle` so
    /// it inherits the cyclist-friendly defaults the proxy injects
    /// (use_roads=0.2, bicycle_type=hybrid, avoid_bad_surfaces=0.25)
    /// and lands on the cycleways the map already paints in cyan for
    /// the rider. Without this flip the route line was on motor roads
    /// while the highlighted lanes were a few metres away.
    var routingProfile: String {
        switch self {
        case .foot:       return "pedestrian"
        case .bicycle:    return "bicycle"
        case .scooter:    return "bicycle"
        case .motorcycle: return "motorcycle"
        case .car:        return "auto"
        }
    }

    /// Which path-highlight bucket the map style uses. Drives
    /// `ScoovaStylePatcher.splitPathsByMode` — cycleways bright on a
    /// bike or scooter, footways bright on foot, everything muted in a
    /// motorcycle or car.
    var pathHighlightMode: PathHighlightMode {
        switch self {
        case .bicycle, .scooter: return .bike
        case .foot:              return .foot
        case .motorcycle, .car:  return .motor
        }
    }

    /// Profile-specific accent — the only thing in the UI that changes
    /// with the rider's chosen device.
    var accent: Color {
        switch self {
        case .foot:       return Color(hex: 0x7DD3FC)
        case .bicycle:    return Color(hex: 0x0EA5E9)
        case .scooter:    return Color(hex: 0x38BDF8)
        case .motorcycle: return Color(hex: 0xA855F7)
        case .car:        return Color(hex: 0xEF4444)
        }
    }

    /// Rough cruising speed (km/h) — drives the plan-screen ETA before
    /// the server's own duration estimate is trusted, and the simulated
    /// puck pace in the preview-ride. Scooter shares 18 km/h with
    /// bicycle because they route on the same costing (see
    /// `routingProfile`); a separate 24 km/h estimate would make every
    /// scooter ETA 33 % shorter than the server actually computes.
    var averageKmh: Double {
        switch self {
        case .foot:       return 5.5
        case .bicycle:    return 18
        case .scooter:    return 18
        case .motorcycle: return 45
        case .car:        return 45
        }
    }

    /// Map a persisted id to a profile, migrating the legacy
    /// activity-based ids from pre-device-refactor builds.
    static func fromId(_ id: String?) -> Profile? {
        guard let id else { return nil }
        if let exact = Profile(rawValue: id) { return exact }
        switch id {
        case "walker", "runner": return .foot
        case "cyclist":          return .bicycle
        case "driver":           return .car
        case "courier":          return .motorcycle
        default:                 return nil
        }
    }
}

/// Premium device badge — the persona's SF Symbol on an accent-tinted
/// squircle. The app's single source of persona iconography; replaces
/// the old emoji everywhere a device is shown.
struct PersonaBadge: View {
    let profile: Profile
    var size: CGFloat = 48

    /// The device glyph, or a guaranteed-present fallback when this
    /// iOS version's SF Symbols set doesn't carry it.
    private var symbol: String {
        UIImage(systemName: profile.icon) != nil
            ? profile.icon : profile.fallbackIcon
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [profile.accent, profile.accent.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: size * 0.30, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}
