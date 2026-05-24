import Foundation

/// Distance / duration formatting that respects the rider's units
/// setting. Shared by the Plan, Ride, and Summary screens.
enum RideFormat {
    static func distance(km: Double, metric: Bool) -> String {
        if metric {
            return km < 1
                ? "\(Int((km * 1000).rounded())) m"
                : String(format: "%.1f km", km)
        }
        let miles = km * 0.621371
        return String(format: "%.1f mi", miles)
    }

    static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
