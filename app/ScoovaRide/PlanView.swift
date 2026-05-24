import SwiftUI

/// A POI quick-search category — seeds the search bar with a keyword.
private struct POICategory {
    let icon: String   // SF Symbol — reliable everywhere, unlike emoji.
    let label: String
    let query: String
}

/// The Map tab — a full-bleed map with the brand header, persona +
/// search row, quick-action chips, map FABs, and the route-preview
/// sheet all floating on top. Ported from the Android demo's PlanScreen.
struct PlanView: View {
    @EnvironmentObject var model: RideModel
    @State private var showProfilePicker = false
    @State private var quickActionsExpanded = true
    @State private var mapStyleIndex = 0
    @State private var recenterTick = 0
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showWeather = false
    /// Which Home/Work slot is showing its action sheet right now —
    /// `.home`, `.work`, or nil. Drives `.confirmationDialog` below.
    /// Two slots, two presentation states, but a SHARED dialog
    /// renderer that branches on whether the slot is empty or filled.
    @State private var setPlaceSlot: RideModel.SavedPlaceSlot? = nil
    @FocusState private var searchFocused: Bool

    private let mapStyles: [MapStyle] = MapStyle.allCases
    private let poiCategories = [
        POICategory(icon: "cup.and.saucer.fill", label: "Coffee", query: "coffee"),
        POICategory(icon: "fuelpump.fill", label: "Gas", query: "gas station"),
        POICategory(icon: "fork.knife", label: "Food", query: "restaurant"),
        POICategory(icon: "parkingsign", label: "Parking", query: "parking"),
    ]

    var body: some View {
        ZStack {
            RideMap(
                routeShape: model.routeShape,
                destination: model.destination?.coordinate ?? model.selectedPlace?.coordinate,
                followUser: false,
                style: mapStyles[mapStyleIndex],
                locale: model.settings.locale,
                mode: (model.profile ?? .bicycle).pathHighlightMode,
                recenterTick: recenterTick,
                onLongPress: { model.selectPoint($0) },
                onPoiTap: { model.selectPlace($0, name: $1, category: $2) }
            )
            .ignoresSafeArea()

            topControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            fabColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 14)
                .padding(.bottom, 96)

            bottomArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 14)
                .padding(.bottom, 96)
        }
        .confirmationDialog("Travelling by", isPresented: $showProfilePicker, titleVisibility: .visible) {
            ForEach(Profile.allCases) { p in
                Button(p.display) { model.switchProfile(p) }
            }
        }
        // Action sheet for Set Home / Set Work — shows EXACTLY what the
        // tap will do (use current location, drop a pin) and gives an
        // edit / remove path when the slot is already filled. Replaces
        // the silent "tap = saveCurrentAs…" with explicit consent so
        // the rider can't end up with the wrong Home pinned because
        // they were standing at the coffee shop.
        .confirmationDialog(
            setPlaceSlot.map { slotName($0) } ?? "",
            isPresented: Binding(
                get: { setPlaceSlot != nil },
                set: { if !$0 { setPlaceSlot = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let slot = setPlaceSlot {
                let existing: SavedPlace? = slot == .home
                    ? model.settings.homePlace
                    : model.settings.workPlace
                Button("Use my current location") {
                    switch slot {
                    case .home: model.saveCurrentAsHome()
                    case .work: model.saveCurrentAsWork()
                    }
                }
                .disabled(model.userLocation == nil)
                Button("Drop a pin on the map") {
                    model.startPinDrop(for: slot)
                }
                if existing != nil {
                    Button("Remove \(slotName(slot))", role: .destructive) {
                        switch slot {
                        case .home: model.clearHome()
                        case .work: model.clearWork()
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
        } message: {
            if let slot = setPlaceSlot {
                let existing: SavedPlace? = slot == .home
                    ? model.settings.homePlace
                    : model.settings.workPlace
                if let p = existing {
                    Text("Currently set to \(p.label).")
                } else {
                    Text("Where do you want \(slotName(slot)) to be?")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model)
        }
        .sheet(isPresented: $showHistory) {
            HistoryView().environmentObject(model)
        }
        .sheet(isPresented: $showWeather) {
            if let weather = model.weather {
                WeatherForecastView(weather: weather,
                                    metric: model.settings.unitsMetric)
            }
        }
    }

    // ── Top controls ─────────────────────────────────────────────────

    private var topControls: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                brandGreeting
                Spacer()
                weatherChip
                circleButton("clock.arrow.circlepath") { showHistory = true }
                circleButton("gearshape.fill") { showSettings = true }
            }
            .padding(.horizontal, 4)

            // Once a place is picked or a route is up, the search +
            // persona row gives way to the destination card below.
            if model.destination == nil && model.selectedPlace == nil {
                HStack(spacing: 8) {
                    personaPill
                    searchPill
                }
                if let slot = model.pinDropTarget {
                    pinDropBanner(slot: slot)
                } else if model.searchFailed {
                    searchUnavailableCard
                } else if !model.searchResults.isEmpty {
                    searchResultsCard
                } else {
                    quickActions
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var brandGreeting: some View {
        HStack(spacing: 9) {
            Image("ScoovaLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 30)
                .foregroundColor(RideTokens.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("SCOOVA")
                    .font(.system(size: 17, weight: .black))
                    .tracking(3)
                    .foregroundColor(RideTokens.accent)
                Text(greetingText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(RideTokens.text.opacity(0.85))
            }
        }
    }

    private var greetingText: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Riding late"
        }
    }

    /// Weather pill — shown only once a reading has resolved. Until then
    /// (and if the fetch fails) it simply isn't there: a naked "—°"
    /// reads as broken in a demo.
    @ViewBuilder
    private var weatherChip: some View {
        if let weather = model.weather {
            // Tappable — realtime reading on the chip, full hourly +
            // daily forecast in the sheet it opens.
            Button { showWeather = true } label: {
                FloatingSurface(cornerRadius: 18) {
                    HStack(spacing: 6) {
                        Image(systemName: weather.iconName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(RideTokens.text)
                        Text(weather.temperatureText(metric: model.settings.unitsMetric))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(RideTokens.text)
                        if !weather.hourly.isEmpty || !weather.daily.isEmpty {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(RideTokens.muted)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// Small round floating control — History / Settings on the map.
    private func circleButton(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FloatingSurface(cornerRadius: 19) {
                Image(systemName: system)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(RideTokens.text)
                    .frame(width: 38, height: 38)
            }
        }
        .buttonStyle(.plain)
    }

    private var personaPill: some View {
        Button { showProfilePicker = true } label: {
            FloatingSurface(
                cornerRadius: 24,
                stroke: (model.profile?.accent ?? RideTokens.accent).opacity(0.5)
            ) {
                HStack(spacing: 5) {
                    PersonaBadge(profile: model.profile ?? .scooter, size: 30)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(RideTokens.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain)
    }

    private var searchPill: some View {
        FloatingSurface(cornerRadius: 24) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(RideTokens.accent)
                TextField("Search for a place", text: searchBinding)
                    .focused($searchFocused)
                    .foregroundColor(RideTokens.text)
                    .tint(RideTokens.accent)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !model.searchQuery.isEmpty {
                    Button {
                        model.clearSearch()
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(RideTokens.muted)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    private var searchResultsCard: some View {
        RideCard {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.searchResults) { suggestion in
                        Button {
                            model.planToSuggestion(suggestion)
                            searchFocused = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 19))
                                    .foregroundColor(RideTokens.accentSoft)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(RideTokens.text)
                                        .lineLimit(1)
                                    if let context = suggestion.context {
                                        Text(context)
                                            .font(.system(size: 11))
                                            .foregroundColor(RideTokens.muted)
                                            .lineLimit(1)
                                    }
                                }
                                .multilineTextAlignment(.leading)
                                Spacer()
                                if let km = suggestion.distanceKm {
                                    Text(RideFormat.distance(km: km,
                                                             metric: model.settings.unitsMetric))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(RideTokens.accent)
                                }
                            }
                            .padding(13)
                        }
                        .buttonStyle(.plain)
                        if suggestion != model.searchResults.last {
                            Rectangle()
                                .fill(RideTokens.border)
                                .frame(height: 1)
                                .padding(.leading, 13)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
    }

    /// Shown when a search request failed outright — distinct from an
    /// empty result, so the rider knows it's the connection, not the query.
    private var searchUnavailableCard: some View {
        FloatingSurface(cornerRadius: 16) {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(RideTokens.warning)
                Text("Search isn't available — check your connection.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(RideTokens.text)
                Spacer()
            }
            .padding(13)
        }
    }

    // ── Quick actions ────────────────────────────────────────────────

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { quickActionsExpanded.toggle() }
            } label: {
                FloatingSurface(cornerRadius: 18) {
                    HStack(spacing: 4) {
                        Image(systemName: quickActionsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text(quickActionsExpanded ? "Hide shortcuts" : "Shortcuts")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(RideTokens.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
            }
            .buttonStyle(.plain)

            if quickActionsExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        savedPlaceChip(
                            slot: .home,
                            icon: "house.fill",
                            emptyLabel: "Set home",
                            place: model.settings.homePlace,
                            accent: RideTokens.accent
                        )
                        savedPlaceChip(
                            slot: .work,
                            icon: "briefcase.fill",
                            emptyLabel: "Set work",
                            place: model.settings.workPlace,
                            accent: RideTokens.accentSoft
                        )
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(poiCategories, id: \.label) { cat in
                            Button {
                                model.searchCategory(cat.query)
                                searchFocused = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: cat.icon)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(RideTokens.accentSoft)
                                    Text(cat.label)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(RideTokens.text)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(RideTokens.surface.opacity(0.96))
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(RideTokens.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func destChip(
        icon: String,
        label: String,
        filled: Bool,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(filled ? accent : RideTokens.muted)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(filled ? RideTokens.text : RideTokens.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RideTokens.surface.opacity(filled ? 0.96 : 0.7))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(filled ? accent.opacity(0.45) : RideTokens.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Home / Work shortcut chip with a clear two-mode UX:
    ///   • EMPTY  — tap opens the "Set Home" action sheet so the rider
    ///              picks HOW to set it (current location, drop a pin),
    ///              instead of the old behaviour of silently snapping
    ///              wherever they happened to be standing.
    ///   • FILLED — tap plans a route there (the common case).
    ///              Long-press opens an action sheet to UPDATE or
    ///              REMOVE — which is the missing edit affordance the
    ///              rider explicitly asked for.
    private func savedPlaceChip(
        slot: RideModel.SavedPlaceSlot,
        icon: String,
        emptyLabel: String,
        place: SavedPlace?,
        accent: Color
    ) -> some View {
        destChip(
            icon: icon,
            label: place?.label ?? emptyLabel,
            filled: place != nil,
            accent: accent
        ) {
            if let p = place {
                model.planToSavedPlace(p)
            } else {
                setPlaceSlot = slot
            }
        }
        .contextMenu {
            if place != nil {
                Button("Update \(slotName(slot))") { setPlaceSlot = slot }
                Button("Remove \(slotName(slot))", role: .destructive) {
                    switch slot {
                    case .home: model.clearHome()
                    case .work: model.clearWork()
                    }
                }
            } else {
                Button("Set \(slotName(slot))") { setPlaceSlot = slot }
            }
        }
    }

    private func slotName(_ s: RideModel.SavedPlaceSlot) -> String {
        switch s { case .home: return "Home"; case .work: return "Work" }
    }

    /// Inline banner shown while the rider is in pin-drop mode for a
    /// saved-place slot. Replaces the quick-action chips so the next
    /// long-press on the map saves into the slot — and the rider has
    /// an explicit Cancel to back out, in case they changed their
    /// mind or want to try the "current location" path instead.
    private func pinDropBanner(slot: RideModel.SavedPlaceSlot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(RideTokens.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tap and hold on the map to set \(slotName(slot))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(RideTokens.text)
                Text("Long-press the spot you want to save.")
                    .font(.system(size: 11))
                    .foregroundColor(RideTokens.muted)
            }
            Spacer(minLength: 6)
            Button("Cancel") { model.cancelPinDrop() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(RideTokens.accent)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RideTokens.surface.opacity(0.7))
                .clipShape(Capsule())
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RideTokens.surface.opacity(0.92))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(RideTokens.accent.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // ── Map FABs ─────────────────────────────────────────────────────

    private var fabColumn: some View {
        VStack(spacing: 10) {
            fab(systemImage: mapStyleIcon) {
                mapStyleIndex = (mapStyleIndex + 1) % mapStyles.count
            }
            fab(systemImage: "location.fill", tint: RideTokens.accent) {
                recenterTick += 1
            }
        }
    }

    private var mapStyleIcon: String {
        switch mapStyles[mapStyleIndex] {
        case .dark:      return "moon.fill"
        case .light:     return "sun.max.fill"
        case .satellite: return "globe.americas.fill"
        }
    }

    private func fab(
        systemImage: String,
        tint: Color = RideTokens.text,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 48, height: 48)
                .background(RideTokens.surface.opacity(0.96))
                .clipShape(Circle())
                .overlay(Circle().stroke(RideTokens.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    // ── Bottom: route preview / loading / error ──────────────────────

    @ViewBuilder private var bottomArea: some View {
        VStack(spacing: 8) {
            if model.isLoadingRoute {
                FloatingSurface(cornerRadius: 16) {
                    HStack(spacing: 10) {
                        ProgressView().tint(RideTokens.accent)
                        Text(model.routeShape.isEmpty ? "Calculating route…" : "Updating route…")
                            .font(.subheadline)
                            .foregroundColor(RideTokens.text)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(14)
                }
            }
            if let err = model.routeError {
                errorCard(err)
            }
            if let dest = model.destination, !model.routeShape.isEmpty {
                routePreviewCard(dest)
            } else if let place = model.selectedPlace {
                placeCard(place)
            }
        }
    }

    /// Shown when the rider taps a POI or long-presses a point — what
    /// the place is, with a Directions button. No route yet.
    private func placeCard(_ place: RideModel.PlaceInfo) -> some View {
        RideCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: placeIcon(place.category))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(RideTokens.accent)
                        .frame(width: 42, height: 42)
                        .background(RideTokens.accent.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(place.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(RideTokens.text)
                            .lineLimit(2)
                        Text([place.category ?? "Place",
                              model.distanceText(to: place.coordinate).map { "\($0) away" }]
                                .compactMap { $0 }
                                .joined(separator: "  ·  "))
                            .font(.system(size: 12))
                            .foregroundColor(RideTokens.muted)
                    }
                    Spacer()
                    Button { model.clearSelectedPlace() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(RideTokens.muted)
                            .frame(width: 34, height: 34)
                            .background(RideTokens.surface2)
                            .clipShape(Circle())
                    }
                }
                Button("Directions") { model.routeToSelectedPlace() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(18)
        }
    }

    private func placeIcon(_ category: String?) -> String {
        let c = (category ?? "").lowercased()
        if c.contains("restaurant") || c.contains("food") { return "fork.knife" }
        if c.contains("hospital") { return "cross.case.fill" }
        if c.contains("hotel") { return "bed.double.fill" }
        if c.contains("school") { return "graduationcap.fill" }
        if c.contains("park") { return "tree.fill" }
        if c.contains("shop") { return "bag.fill" }
        if c.contains("transit") { return "tram.fill" }
        if c.contains("parking") { return "p.circle.fill" }
        return "mappin.circle.fill"
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 12) {
            Text("!")
                .font(.system(size: 18, weight: .black))
                .foregroundColor(RideTokens.warning)
                .frame(width: 32, height: 32)
                .background(RideTokens.warning.opacity(0.18))
                .clipShape(Circle())
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(RideTokens.text)
            Spacer()
            Button { model.routeError = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(RideTokens.muted)
            }
        }
        .padding(14)
        .background(RideTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(RideTokens.warning.opacity(0.5), lineWidth: 1)
        )
    }

    private func routePreviewCard(_ dest: RideModel.Destination) -> some View {
        RideCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dest.label)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(RideTokens.text)
                            .lineLimit(1)
                        Text(routeSubtitle)
                            .font(.system(size: 12))
                            .foregroundColor(RideTokens.muted)
                    }
                    Spacer()
                    Button { model.clearRoute() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(RideTokens.muted)
                            .frame(width: 34, height: 34)
                            .background(RideTokens.surface2)
                            .clipShape(Circle())
                    }
                }
                Button("Go") { model.startRide() }
                    .buttonStyle(PrimaryButtonStyle())
                Button {
                    model.simulateRide()
                } label: {
                    Label("Preview route", systemImage: "play.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(RideTokens.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
            }
            .padding(18)
        }
    }

    private var routeSubtitle: String {
        let dist = RideFormat.distance(km: model.routeDistanceKm, metric: model.settings.unitsMetric)
        let dur = RideFormat.duration(minutes: model.routeDurationMin)
        let mode = model.profile?.display ?? ""
        return "\(dist) · \(dur) · \(mode)"
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { model.searchQuery },
            set: { model.updateSearch($0) }
        )
    }
}
