import SwiftUI

/// Trip history — every completed navigation, newest first. A roll-up
/// summary on top, then one compact row per trip; tapping a row opens
/// its detail with the route drawn. Mirrors the Android demo's
/// `HistoryScreen`. Presented as a sheet from the map.
struct HistoryView: View {
    @EnvironmentObject var model: RideModel
    @Environment(\.dismiss) private var dismiss
    @State private var detailTrip: TripRecord?
    @State private var confirmClear = false

    var body: some View {
        AppBackground {
            ZStack {
                VStack(spacing: 0) {
                    header
                    if model.trips.isEmpty {
                        Spacer()
                        EmptyState(
                            icon: "map",
                            title: "No trips yet",
                            message: "Finished trips show up here — where you went, how far it was, and how long it took."
                        )
                        Spacer()
                        Spacer()
                    } else {
                        ScrollView {
                            VStack(spacing: 10) {
                                totalsRow
                                    .padding(.bottom, 6)
                                ForEach(model.trips) { trip in
                                    tripRow(trip)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 28)
                        }
                    }
                }

                if let trip = detailTrip {
                    TripDetailView(trip: trip,
                                   metric: model.settings.unitsMetric,
                                   onClose: { detailTrip = nil })
                        .transition(.move(edge: .trailing))
                }
            }
        }
    }

    // ── Header ───────────────────────────────────────────────────────

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(RideTokens.text)
                Text(model.trips.isEmpty
                     ? "No trips yet"
                     : "\(model.trips.count) \(model.trips.count == 1 ? "trip" : "trips")")
                    .font(.system(size: 12))
                    .foregroundColor(RideTokens.muted)
            }
            Spacer()
            if !model.trips.isEmpty {
                Button("Clear") { confirmClear = true }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(RideTokens.muted)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(RideTokens.muted)
                    .frame(width: 34, height: 34)
                    .background(RideTokens.surface2)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .confirmationDialog("Clear all trip history?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { model.clearHistory() }
        }
    }

    // ── Roll-up totals ───────────────────────────────────────────────

    private var totalsRow: some View {
        let totalKm = model.trips.reduce(0) { $0 + $1.distanceKm }
        let totalMin = model.trips.reduce(0) { $0 + $1.durationMin }
        return HStack(spacing: 0) {
            totalsCell(RideFormat.distance(km: totalKm, metric: model.settings.unitsMetric),
                       "Distance")
            divider
            totalsCell(RideFormat.duration(minutes: totalMin), "Time")
            divider
            totalsCell("\(model.trips.count)", "Trips")
        }
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity)
        .background(RideTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(RideTokens.border, lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle().fill(RideTokens.border).frame(width: 1, height: 32)
    }

    private func totalsCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(RideTokens.accent)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundColor(RideTokens.muted)
        }
        .frame(maxWidth: .infinity)
    }

    // ── Trip row ─────────────────────────────────────────────────────

    private func tripRow(_ trip: TripRecord) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { detailTrip = trip }
        } label: {
            HStack(spacing: 14) {
                PersonaBadge(profile: Self.profile(for: trip), size: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(trip.destination)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(RideTokens.text)
                        .lineLimit(1)
                    Text(Self.rowDate(trip.date))
                        .font(.system(size: 11))
                        .foregroundColor(RideTokens.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(RideFormat.distance(km: trip.distanceKm,
                                             metric: model.settings.unitsMetric))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(RideTokens.accent)
                    Text(RideFormat.duration(minutes: trip.durationMin))
                        .font(.system(size: 11))
                        .foregroundColor(RideTokens.muted)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(RideTokens.muted)
            }
            .padding(14)
            .background(RideTokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(RideTokens.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // ── Helpers ──────────────────────────────────────────────────────

    static func profile(for trip: TripRecord) -> Profile {
        if let id = trip.modeId, let p = Profile(rawValue: id) { return p }
        // Older records (pre-modeId) — best-guess from the mode label.
        let m = trip.mode.lowercased()
        if m.contains("walk") || m.contains("foot") { return .foot }
        if m.contains("scoot") { return .scooter }
        if m.contains("car") || m.contains("driv") { return .car }
        if m.contains("motor") { return .motorcycle }
        return .bicycle
    }

    private static let rowFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d · h:mm a"; return f
    }()

    static func rowDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            let t = DateFormatter(); t.dateFormat = "h:mm a"
            return "Today · \(t.string(from: date))"
        }
        return rowFormatter.string(from: date)
    }
}

// ── Trip detail ──────────────────────────────────────────────────────

/// Full-screen detail for one trip — the route drawn, plus its stats.
/// Slides in over the History list; close returns to it.
private struct TripDetailView: View {
    let trip: TripRecord
    let metric: Bool
    let onClose: () -> Void

    var body: some View {
        AppBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerRow
                    RouteThumbnail(route: trip.route)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(RideTokens.border, lineWidth: 1)
                        )
                    statsRow
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(RideTokens.muted)
                    .frame(width: 36, height: 36)
                    .background(RideTokens.surface)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(RideTokens.border, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.destination)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(RideTokens.text)
                    .lineLimit(1)
                Text(Self.detailFormatter.string(from: trip.date))
                    .font(.system(size: 12))
                    .foregroundColor(RideTokens.muted)
            }
            Spacer()
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(RideFormat.distance(km: trip.distanceKm, metric: metric), "Distance")
            cellDivider
            statCell(RideFormat.duration(minutes: trip.durationMin), "Time")
            cellDivider
            statCell(trip.mode.isEmpty ? "—" : trip.mode, "Mode")
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(RideTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(RideTokens.border, lineWidth: 1)
        )
    }

    private var cellDivider: some View {
        Rectangle().fill(RideTokens.border).frame(width: 1, height: 34)
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(RideTokens.text)
                .lineLimit(1)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundColor(RideTokens.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private static let detailFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d · h:mm a"; return f
    }()
}

// ── Shared pieces ────────────────────────────────────────────────────

/// Lightweight route drawing — the trip's polyline scaled into the
/// view, no MapLibre. Cheap enough to render many in a scrolling list.
struct RouteThumbnail: View {
    /// Route polyline as `[lat, lon]` pairs.
    let route: [[Double]]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RideTokens.surface2
                if route.count > 1 {
                    let pts = points(in: geo.size)
                    Path { path in
                        path.move(to: pts[0])
                        for p in pts.dropFirst() { path.addLine(to: p) }
                    }
                    .stroke(RideTokens.routeCore,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    if let start = pts.first {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(RideTokens.accent, lineWidth: 2))
                            .position(start)
                    }
                    if let end = pts.last {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 17))
                            .foregroundColor(RideTokens.accent)
                            .position(end)
                    }
                }
            }
        }
    }

    /// Scale the lat/lon polyline into the view, north up, aspect-correct.
    private func points(in size: CGSize) -> [CGPoint] {
        let lats = route.map { $0[0] }
        let lons = route.map { $0[1] }
        let midLat = ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2
        let lonScale = cos(midLat * .pi / 180)        // even out lon vs lat spacing
        let xs = lons.map { $0 * lonScale }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = lats.min() ?? 0, maxY = lats.max() ?? 0
        let spanX = max(maxX - minX, 1e-7)
        let spanY = max(maxY - minY, 1e-7)
        let pad = 20.0
        let w = max(Double(size.width) - pad * 2, 1)
        let h = max(Double(size.height) - pad * 2, 1)
        let scale = min(w / spanX, h / spanY)
        let offX = pad + (w - spanX * scale) / 2
        let offY = pad + (h - spanY * scale) / 2
        return route.map { pair in
            CGPoint(
                x: offX + (pair[1] * lonScale - minX) * scale,
                y: offY + (maxY - pair[0]) * scale     // flip — north is up
            )
        }
    }
}

/// Centered empty-state block — icon, title, supporting copy.
struct EmptyState: View {
    let icon: String   // SF Symbol
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundColor(RideTokens.muted)
            Text(title)
                .font(.title3.bold())
                .foregroundColor(RideTokens.text)
            Text(message)
                .font(.subheadline)
                .foregroundColor(RideTokens.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}
