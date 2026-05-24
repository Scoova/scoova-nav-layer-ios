import Foundation
import Combine
import CoreLocation
import ScoovaNavLayerCore
import ScoovaNavLayerScoovaRouting

/// The app-wide state machine + SDK owner. Holds the Onboarding →
/// Persona → Plan → Ride phase, the persisted settings, the trip
/// history, and the live `ScoovaNavLayer` instance that speaks the
/// turn-by-turn cues.
@MainActor
final class RideModel: ObservableObject {

    enum Phase { case onboarding, persona, plan, ride, summary }

    /// A routing destination — a coordinate plus a human label.
    struct Destination: Equatable {
        var coordinate: CLLocationCoordinate2D
        var label: String
        static func == (a: Destination, b: Destination) -> Bool {
            a.label == b.label
                && a.coordinate.latitude == b.coordinate.latitude
                && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    /// A place the rider tapped on the map — shown in the info card
    /// before any route is built. "Directions" turns it into a route.
    struct PlaceInfo {
        var coordinate: CLLocationCoordinate2D
        var name: String
        /// What kind of place — "Restaurant", "Park", "Point on map"…
        var category: String?
    }

    // ── Published state ──────────────────────────────────────────────
    @Published var phase: Phase
    @Published var settings: RideSettings
    @Published var profile: Profile?
    @Published var weather: WeatherSnapshot?
    @Published var userLocation: CLLocationCoordinate2D?
    @Published var destination: Destination?
    /// A place tapped on the map, awaiting a "Directions" tap. Nil once
    /// a route is built or the card is dismissed.
    @Published var selectedPlace: PlaceInfo?
    /// Completed trips, newest first — the History list.
    @Published var trips: [TripRecord] = []
    @Published var routeShape: [CLLocationCoordinate2D] = []
    @Published var routeDistanceKm: Double = 0
    @Published var routeDurationMin: Int = 0
    @Published var isLoadingRoute = false
    @Published var routeError: String?
    @Published var searchQuery = ""
    @Published var searchResults: [PlaceSuggestion] = []
    /// True when the last search request failed (network / server) —
    /// distinct from "searched, found nothing".
    @Published var searchFailed = false
    @Published var currentCueText: String?
    /// Server-rendered landmark anchor for the banner's second line —
    /// "after McDonald's". Nil when the maneuver has no landmark.
    @Published var currentCueAnchor: String?
    /// SF Symbol for the upcoming maneuver — a turn-direction glyph the
    /// banner shows instead of a compass arrow.
    @Published var currentManeuverSymbol: String = "location.north.fill"
    /// Metres to the upcoming maneuver — the banner's glanceable
    /// count-down ("300 m"). Nil when there's no live cue.
    @Published var currentManeuverDistanceM: Double?
    /// True while a fresh route is being fetched after the rider
    /// strayed off-route — the banner shows "Rerouting…".
    @Published var isRerouting = false
    /// The trip that just finished — drives the post-ride Summary.
    @Published var lastTrip: TripRecord?
    @Published var headingDeg: Float = 0
    @Published var coveredKm: Double = 0
    @Published var rideStartedAt: Date?
    @Published var rideEndedAt: Date?
    /// True while "Simulate the ride" is walking a synthetic puck.
    @Published var isSimulating = false
    /// Synthetic puck position during a simulated ride — the map
    /// follows this instead of the (stationary) real GPS fix.
    @Published var simLocation: CLLocationCoordinate2D?
    /// Travel bearing of the synthetic puck — rotates the nav camera
    /// heading-up during a simulated ride.
    @Published var simBearing: Float = 0

    let location = LocationManager()

    // ── SDK + plumbing ───────────────────────────────────────────────
    private var nav: ScoovaNavLayer?
    private var routing: ScoovaRoutingAdapter?
    private var cancellables = Set<AnyCancellable>()
    private var lastRideFix: CLLocation?
    /// When the last off-route reroute fired — throttles re-fetching.
    private var lastRerouteAt: Date?
    private var searchTask: Task<Void, Never>?
    private var simulationTask: Task<Void, Never>?
    private var weatherFetchedAt: Date?

    deinit {
        // Released mid-flight (the SwiftUI environment can drop the
        // owning scene). Cancel any in-flight async work so the Tasks
        // don't keep a reference to `self` indefinitely and so a still-
        // ticking simulation doesn't try to update a torn-down model.
        searchTask?.cancel()
        simulationTask?.cancel()
    }

    private let apiKey = ScoovaAPI.key
    private let routingURL = URL(string: "\(ScoovaAPI.gateway)/route")!
    private static let profileKey = "scoova.ride.profile"

    init() {
        let loaded = SettingsStore.load()
        let savedProfile = Profile.fromId(UserDefaults.standard.string(forKey: Self.profileKey))
        self.settings = loaded
        self.profile = savedProfile
        self.trips = TripStore.load()
        if !loaded.onboardingDone {
            self.phase = .onboarding
        } else if savedProfile == nil {
            self.phase = .persona
        } else {
            self.phase = .plan
        }
        location.onUpdate = { [weak self] loc in self?.handleFix(loc) }
        // Never prompt for location over onboarding slide 1 — a new
        // rider hasn't been told why yet. New users get the prompt from
        // `finishOnboarding()`; returning users (past onboarding) here.
        if loaded.onboardingDone {
            location.requestPermission()
        }
    }

    // ── Phase transitions ────────────────────────────────────────────

    func finishOnboarding() {
        settings.onboardingDone = true
        persist()
        // Now that the rider has seen what Scoova does, ask for location.
        location.requestPermission()
        phase = (profile == nil) ? .persona : .plan
    }

    func selectProfile(_ p: Profile) {
        profile = p
        UserDefaults.standard.set(p.rawValue, forKey: Self.profileKey)
        buildNav()
        phase = .plan
    }

    func changeProfile() { phase = .persona }

    /// One-tap mode swap from the Plan screen — re-rates an existing
    /// route under the new device since cyclist/car routes can diverge.
    func switchProfile(_ p: Profile) {
        guard p != profile else { return }
        profile = p
        UserDefaults.standard.set(p.rawValue, forKey: Self.profileKey)
        buildNav()
        if let dest = destination { planRoute(to: dest) }
    }

    func startRide() {
        guard !routeShape.isEmpty else { return }
        phase = .ride
        rideStartedAt = Date()
        rideEndedAt = nil
        coveredKm = 0
        lastRideFix = nil
        lastRerouteAt = nil
        location.setBackground(true)
    }

    /// Preview the planned route without moving — walks a synthetic puck
    /// along the polyline at the persona's pace, feeding the nav engine
    /// so the Eye-on-Road voice cues fire exactly as on a real ride.
    /// Mirrors the Android demo's `simulateRide`.
    func simulateRide() {
        guard routeShape.count >= 2 else { return }
        let coords = routeShape
        startRide()
        isSimulating = true

        let tick: TimeInterval = 0.25

        // Cumulative metres along the polyline, for the interpolator.
        var cum = [Double](repeating: 0, count: coords.count)
        for i in 1..<coords.count {
            cum[i] = cum[i - 1]
                + CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                    .distance(from: CLLocation(latitude: coords[i].latitude,
                                               longitude: coords[i].longitude))
        }
        let total = cum.last ?? 0

        // The puck moves at the rider's REAL pace — the speed the server
        // calibrated the cue lead-times for. No compression: a puck
        // faster than real life is exactly what makes the cues feel
        // like they're racing the rider.
        let cruiseMps = max(1.2, (profile?.averageKmh ?? 18) / 3.6)
        let accelTime = 3.0   // ease 0 → cruise, like a real start
        let startCoord = coords[0]
        let startBearing = Self.bearingDeg(
            from: coords[0], to: coords[min(1, coords.count - 1)])
        // Show the puck parked at the start while the welcome plays.
        simLocation = startCoord
        simBearing = startBearing

        simulationTask?.cancel()
        simulationTask = Task {
            // Pre-roll — deliver the first fix so the welcome cue speaks,
            // and hold still while it plays. Never start moving before
            // the rider has been told where they're going.
            routing?.onLocation(lat: startCoord.latitude, lon: startCoord.longitude,
                                speedMps: 0, bearingDeg: startBearing)
            try? await Task.sleep(nanoseconds: UInt64(3.5 * 1_000_000_000))
            if Task.isCancelled { return }

            var covered = 0.0
            var seg = 0
            var elapsed = 0.0
            while covered < total {
                if Task.isCancelled { return }
                while seg < coords.count - 2 && cum[seg + 1] < covered { seg += 1 }
                let a = coords[seg], b = coords[seg + 1]
                let segLen = cum[seg + 1] - cum[seg]
                let t = segLen > 0 ? min(1, max(0, (covered - cum[seg]) / segLen)) : 0
                let here = CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t)
                let bearing = Self.bearingDeg(from: a, to: b)
                simLocation = here
                simBearing = bearing
                coveredKm = covered / 1000
                // Ease up to cruising pace over the first few seconds —
                // a real start, not an instant jump to full speed.
                let speed = max(0.6, cruiseMps * min(1.0, elapsed / accelTime))
                routing?.onLocation(lat: here.latitude, lon: here.longitude,
                                    speedMps: Float(speed), bearingDeg: bearing)
                covered += speed * tick
                elapsed += tick
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
            }
            if Task.isCancelled { return }
            let last = coords[coords.count - 1]
            coveredKm = total / 1000          // mark the full route covered
            routing?.onLocation(lat: last.latitude, lon: last.longitude,
                                speedMps: 0, bearingDeg: 0)
            endRide()
        }
    }

    private func stopSimulation() {
        simulationTask?.cancel()
        simulationTask = nil
        isSimulating = false
        simLocation = nil
    }

    /// Initial-bearing (great-circle) from `a` to `b`, degrees 0–360.
    private static func bearingDeg(from a: CLLocationCoordinate2D,
                                   to b: CLLocationCoordinate2D) -> Float {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return Float((deg + 360).truncatingRemainder(dividingBy: 360))
    }

    func endRide() {
        // Idempotent: a ride can be ended from several places that may
        // race — the nav layer's `arrived` latch, the simulator's own
        // end-of-route call, and the manual "End ride" control. Only the
        // first one through does the work; the rest no-op.
        guard phase == .ride else { return }
        let wasPreview = isSimulating
        stopSimulation()
        location.setBackground(false)
        rideEndedAt = Date()
        // Did the rider actually complete the route? Covering ~all of it
        // — a finished simulation, or a real ride to the destination —
        // is an arrival. Starting a route and ending it without really
        // moving is NOT, and must never show the "You've arrived"
        // Summary. `coveredKm` resets to 0 at every ride start.
        let arrived = routeDistanceKm > 0
            && coveredKm >= routeDistanceKm * 0.9
        if arrived, let dest = destination, routeShape.count > 1 {
            let record = makeTripRecord(to: dest, wasPreview: wasPreview)
            lastTrip = record
            if settings.recordRides {
                trips.insert(record, at: 0)
                TripStore.save(trips)
            }
        } else {
            lastTrip = nil
        }
        resetRouteState()
        // Only a genuine arrival lands on the Summary; ending a ride
        // early drops straight back to the map.
        phase = (lastTrip != nil) ? .summary : .plan
    }

    /// Dismiss the post-ride Summary, back to the map.
    func dismissSummary() {
        lastTrip = nil
        phase = .plan
    }

    /// Build the record for the just-finished trip — used by both the
    /// Summary screen and the History list.
    private func makeTripRecord(to dest: Destination, wasPreview: Bool) -> TripRecord {
        // A preview compresses the trip, so its elapsed time is
        // meaningless — fall back to the routing estimate.
        let minutes: Int
        if !wasPreview, let start = rideStartedAt, let end = rideEndedAt {
            minutes = max(1, Int(end.timeIntervalSince(start) / 60))
        } else {
            minutes = routeDurationMin
        }
        return TripRecord(
            date: rideEndedAt ?? Date(),
            destination: dest.label,
            distanceKm: routeDistanceKm,
            durationMin: minutes,
            mode: profile?.display ?? "",
            modeId: profile?.rawValue,
            route: routeShape.map { [$0.latitude, $0.longitude] }
        )
    }

    /// Wipe the whole History list.
    func clearHistory() {
        trips = []
        TripStore.save(trips)
    }

    private func resetRouteState() {
        destination = nil
        selectedPlace = nil
        routeShape = []
        routeDistanceKm = 0
        routeDurationMin = 0
        routeError = nil
        currentCueText = nil
        currentCueAnchor = nil
        rideStartedAt = nil
        coveredKm = 0
        lastRideFix = nil
    }

    // ── Routing ──────────────────────────────────────────────────────

    func planRoute(to dest: Destination) {
        guard let origin = userLocation else {
            routeError = "We need your location first. Make sure location is on."
            return
        }
        if nav == nil { buildNav() }
        guard let routing else { return }
        destination = dest
        selectedPlace = nil          // the place card gives way to the route card
        isLoadingRoute = true
        routeError = nil
        let prof = profile?.routingProfile ?? "auto"
        let lang = settings.locale
        let eyesOff = settings.eyesOff
        Task {
            // Retry: a dropped HTTP/3 attempt (Cloudflare-fronted,
            // common on the Simulator) fails fast; the retry recovers
            // over HTTP/2 rather than stranding the rider.
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    let shape = try await routing.startRoute(
                        from: LatLon(lat: origin.latitude, lon: origin.longitude),
                        to: LatLon(lat: dest.coordinate.latitude, lon: dest.coordinate.longitude),
                        profile: prof,
                        language: lang,
                        landmarks: true,
                        eyesOff: eyesOff
                    )
                    let coords = shape.map {
                        CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1])
                    }
                    guard coords.count >= 2 else {
                        // A 2xx with no usable polyline — no route exists.
                        isLoadingRoute = false
                        routeError = "We couldn't find a route to that spot. Try a nearby one."
                        return
                    }
                    routeShape = coords
                    routeDistanceKm = Self.distanceKm(coords)
                    routeDurationMin = Int(routeDistanceKm / (profile?.averageKmh ?? 18) * 60)
                    isLoadingRoute = false
                    return
                } catch {
                    lastError = error
                    NSLog("ScoovaRoute attempt %d failed: %@",
                          attempt, String(describing: error))
                    if attempt < 3 { try? await Task.sleep(nanoseconds: 500_000_000) }
                }
            }
            isLoadingRoute = false
            routeError = Self.routeErrorMessage(for: lastError)
        }
    }

    /// Map long-press → either save the pressed coord into a Home /
    /// Work slot (when the rider asked for "Drop a pin on the map"
    /// from the Set Home/Work action sheet) OR show the standard
    /// place-card for routing.
    func selectPoint(_ coord: CLLocationCoordinate2D) {
        // Pin-drop path — the rider asked to set Home/Work by tapping
        // the map. Save into the slot, clear the target, done. No
        // place card / routing UI for this gesture — it's a single
        // action, not a route plan.
        if let slot = pinDropTarget {
            pinDropTarget = nil
            switch slot {
            case .home: saveAsHome(coord: coord, name: nil)
            case .work: saveAsWork(coord: coord, name: nil)
            }
            return
        }
        clearRoute()
        selectedPlace = PlaceInfo(coordinate: coord, name: "Dropped pin",
                                  category: "Point on the map")
        Task {
            guard let label = await Self.reverseGeocode(coord),
                  selectedPlace?.coordinate.latitude == coord.latitude,
                  selectedPlace?.coordinate.longitude == coord.longitude
            else { return }
            selectedPlace?.name = label
        }
    }

    /// Map POI-icon tap → show the place card (name + what it is).
    /// Routing waits for an explicit "Directions" tap.
    func selectPlace(_ coord: CLLocationCoordinate2D, name: String, category: String?) {
        clearRoute()
        selectedPlace = PlaceInfo(coordinate: coord, name: name, category: category)
    }

    /// "Directions" on the place card → build the route to it.
    func routeToSelectedPlace() {
        guard let place = selectedPlace else { return }
        planRoute(to: Destination(coordinate: place.coordinate, label: place.name))
    }

    /// Dismiss the place card without routing.
    func clearSelectedPlace() { selectedPlace = nil }

    /// Drop the current route / place selection, staying on the map.
    func clearRoute() {
        stopSimulation()
        destination = nil
        selectedPlace = nil
        routeShape = []
        routeDistanceKm = 0
        routeDurationMin = 0
        routeError = nil
    }

    // ── Destination search ───────────────────────────────────────────

    /// Debounced autocomplete. Each keystroke cancels the in-flight
    /// query, waits ~250 ms, then asks the Scoova geocoder.
    func updateSearch(_ text: String) {
        searchQuery = text
        searchTask?.cancel()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
            searchResults = []
            searchFailed = false
            return
        }
        let focus = userLocation
        let lang = settings.locale
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let results = await ScoovaGeocoder.autocomplete(text, focus: focus, lang: lang)
            if Task.isCancelled { return }
            searchResults = results ?? []
            searchFailed = (results == nil)
        }
    }

    /// Straight-line distance from the rider to a coordinate, formatted
    /// for the rider's units. Nil until we have a location fix.
    func distanceText(to coord: CLLocationCoordinate2D) -> String? {
        guard let here = userLocation else { return nil }
        let meters = CLLocation(latitude: here.latitude, longitude: here.longitude)
            .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        return RideFormat.distance(km: meters / 1000, metric: settings.unitsMetric)
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
        searchFailed = false
    }

    /// Rider tapped a search result — clear the search UI and route there.
    func planToSuggestion(_ suggestion: PlaceSuggestion) {
        clearSearch()
        planRoute(to: Destination(coordinate: suggestion.coordinate, label: suggestion.name))
    }

    /// POI category chip ("coffee", "gas", …) — seed the search.
    func searchCategory(_ keyword: String) {
        updateSearch(keyword)
    }

    // ── Saved places (Home / Work) ───────────────────────────────────

    /// Pin-drop target for the saved-place flow. When set, the next
    /// long-press on the map saves that coord as the slot's value
    /// (reverse-geocoded label, falling back to the slot name) and
    /// then clears the target. Nil means a normal "drop a pin to
    /// route there" gesture.
    @Published var pinDropTarget: SavedPlaceSlot? = nil

    enum SavedPlaceSlot { case home, work }

    func saveCurrentAsHome() { saveAsHome(coord: userLocation, name: nil) }
    func saveCurrentAsWork() { saveAsWork(coord: userLocation, name: nil) }

    /// Save a specific coordinate to the Home slot. Called from the
    /// "Set Home" action sheet (current location + search-result +
    /// pin-drop), so the rider always sees a confirmable spot rather
    /// than a silent "we used wherever you happened to be standing."
    /// Reverse-geocoded to a readable label so the chip shows "10
    /// Downing St" not "Home" — riders can tell which Home is set.
    func saveAsHome(coord: CLLocationCoordinate2D?, name: String?) {
        guard let coord else { return }
        let fallback = name ?? "Home"
        settings.homePlace = SavedPlace(label: fallback, lat: coord.latitude, lon: coord.longitude)
        persist()
        upgradeSavedPlaceLabel(slot: .home, coord: coord)
    }

    func saveAsWork(coord: CLLocationCoordinate2D?, name: String?) {
        guard let coord else { return }
        let fallback = name ?? "Work"
        settings.workPlace = SavedPlace(label: fallback, lat: coord.latitude, lon: coord.longitude)
        persist()
        upgradeSavedPlaceLabel(slot: .work, coord: coord)
    }

    func clearHome() { settings.homePlace = nil; persist() }
    func clearWork() { settings.workPlace = nil; persist() }

    /// Enter pin-drop mode for the [slot]. The PlanView's map
    /// long-press handler reads `pinDropTarget` and, if non-nil,
    /// saves the pressed coord into the matching slot instead of
    /// the normal "drop pin to route" gesture.
    func startPinDrop(for slot: SavedPlaceSlot) { pinDropTarget = slot }
    func cancelPinDrop() { pinDropTarget = nil }

    func planToSavedPlace(_ place: SavedPlace) {
        planRoute(to: Destination(
            coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon),
            label: place.label
        ))
    }

    /// Async reverse-geocode a saved place's coord and replace the
    /// label with the resolved street name. Falls back silently to
    /// the original label on any failure — the slot still works.
    private func upgradeSavedPlaceLabel(slot: SavedPlaceSlot, coord: CLLocationCoordinate2D) {
        Task { [weak self] in
            guard let label = await Self.reverseGeocode(coord) else { return }
            await MainActor.run {
                guard let self else { return }
                switch slot {
                case .home:
                    guard var p = self.settings.homePlace,
                          p.lat == coord.latitude, p.lon == coord.longitude
                    else { return }
                    p.label = label
                    self.settings.homePlace = p
                case .work:
                    guard var p = self.settings.workPlace,
                          p.lat == coord.latitude, p.lon == coord.longitude
                    else { return }
                    p.label = label
                    self.settings.workPlace = p
                }
                self.persist()
            }
        }
    }

    // ── Weather ──────────────────────────────────────────────────────

    /// Fetch the chip-sized weather snapshot, at most once every 10 min.
    private func maybeFetchWeather(_ coord: CLLocationCoordinate2D) {
        if let last = weatherFetchedAt, Date().timeIntervalSince(last) < 600 { return }
        weatherFetchedAt = Date()
        Task {
            // One call returns realtime + hourly + daily forecast.
            if let snapshot = await ScoovaWeather.fetch(coord) {
                weather = snapshot
            }
        }
    }

    // ── Settings setters ─────────────────────────────────────────────

    func setRecordRides(_ on: Bool) { settings.recordRides = on; persist() }
    func setVoiceEnabled(_ on: Bool) {
        settings.voiceEnabled = on
        nav?.setVoiceEnabled(on)
        persist()
    }
    func setEyesOff(_ on: Bool) { settings.eyesOff = on; persist() }
    func setSpatialAudio(_ on: Bool) { settings.spatialAudio = on; persist() }
    func setUnitsMetric(_ on: Bool) { settings.unitsMetric = on; persist() }
    func setLocale(_ tag: String) {
        settings.locale = tag
        persist()
        if nav != nil { buildNav() }   // hard TTS-locale switch
    }

    // ── Internals ────────────────────────────────────────────────────

    private func persist() { SettingsStore.save(settings) }

    private func handleFix(_ loc: CLLocation) {
        userLocation = loc.coordinate
        maybeFetchWeather(loc.coordinate)
        guard phase == .ride else { return }
        // The simulator owns onLocation during a previewed ride; ignore
        // the stationary real GPS fix so the two pucks don't fight.
        guard !isSimulating else { return }
        if let prev = lastRideFix {
            let step = loc.distance(from: prev)
            if step >= 4 { coveredKm += step / 1000 }
        }
        lastRideFix = loc
        routing?.onLocation(
            lat: loc.coordinate.latitude,
            lon: loc.coordinate.longitude,
            speedMps: loc.speed >= 0 ? Float(loc.speed) : nil,
            bearingDeg: loc.course >= 0 ? Float(loc.course) : nil
        )
    }

    /// Map a maneuver type to a turn-direction SF Symbol for the banner
    /// — a glyph that points where to *turn*, not where the rider faces.
    static func maneuverSymbol(for type: ManeuverType?) -> String {
        guard let type else { return "location.north.fill" }
        if type == .arrive { return "mappin.and.ellipse" }
        if type.isUturn { return "arrow.uturn.down" }
        if type.isLeftSide { return "arrow.turn.up.left" }
        if type.isRightSide { return "arrow.turn.up.right" }
        return "arrow.up"   // depart / continue / straight / merge / roundabout
    }

    /// The upcoming-maneuver distance formatted for the banner — nil
    /// when the rider is right on top of the turn (the verb covers it).
    var maneuverDistanceText: String? {
        guard let metres = currentManeuverDistanceM, metres > 15 else { return nil }
        return RideFormat.distance(km: metres / 1000,
                                   metric: settings.unitsMetric)
    }

    private func buildNav() {
        nav?.stop()
        cancellables.removeAll()
        let layer = ScoovaNavLayer.builder()
            .apiKey(apiKey)
            .locale(settings.locale)
            .profile(profile?.routingProfile ?? "auto")
            .spatialAudio(settings.spatialAudio)
            .landmarks(true)
            .build()
        layer.setVoiceEnabled(settings.voiceEnabled)
        layer.start()
        layer.$currentInstruction
            .receive(on: RunLoop.main)
            .sink { [weak self] cue in
                // Banner reads the server's eyes-on-the-road copy:
                // `bannerVerb` ("Turn right") + `bannerAnchor`
                // ("after McDonald's"). `text` is the legacy fallback.
                self?.currentCueText = cue?.maneuver.bannerVerb ?? cue?.text
                self?.currentCueAnchor = cue?.maneuver.bannerAnchor
                self?.currentManeuverSymbol =
                    RideModel.maneuverSymbol(for: cue?.maneuver.type)
                self?.currentManeuverDistanceM = cue?.metersToManeuver
            }
            .store(in: &cancellables)
        layer.$headingDeg
            .receive(on: RunLoop.main)
            .sink { [weak self] h in self?.headingDeg = h }
            .store(in: &cancellables)
        // The nav layer latches `arrived` the moment the rider reaches
        // the destination (rolled inside the arrival radius, or parked
        // near it). That's our cue to close the ride out — write the
        // history entry and hand over to the Summary screen. `endRide()`
        // guards on `.ride` so the simulator's own end call can't
        // double-fire the transition.
        layer.$arrived
            .receive(on: RunLoop.main)
            .sink { [weak self] hasArrived in
                guard let self, hasArrived, self.phase == .ride else { return }
                self.endRide()
            }
            .store(in: &cancellables)
        // Off-route → the SDK asks for a fresh route; we re-fetch one
        // from wherever the rider actually is.
        layer.onRerouteNeeded = { [weak self] in
            Task { @MainActor in self?.reroute() }
        }
        nav = layer
        routing = ScoovaRoutingAdapter(apiKey: apiKey, layer: layer, routingURL: routingURL)
    }

    /// The rider strayed off the route — fetch a fresh one from their
    /// current position to the same destination. Throttled so a long
    /// detour doesn't hammer the routing server.
    func reroute() {
        guard phase == .ride,
              let dest = destination,
              let origin = userLocation,
              let routing else { return }
        if let last = lastRerouteAt, Date().timeIntervalSince(last) < 10 { return }
        lastRerouteAt = Date()
        isRerouting = true
        let prof = profile?.routingProfile ?? "auto"
        let lang = settings.locale
        let eyesOff = settings.eyesOff
        // Snapshot the profile's cruising speed at the moment the
        // reroute starts. If the rider switches persona while this
        // async fetch is in flight, the ETA must reflect the persona
        // the route was REQUESTED for, not whichever one they happen
        // to be on when the response lands — otherwise scooter → foot
        // mid-reroute produces a 4× ETA estimate against a route that
        // was bicycle-costed.
        let snapshotKmh = profile?.averageKmh ?? 18
        Task {
            // Clear the banner's "Rerouting…" state however this ends —
            // success, failure, or both attempts exhausted.
            defer { isRerouting = false }
            // Two quick attempts. If both fail, the rider keeps the old
            // line and the next off-route tick reschedules a reroute —
            // so a brief network blip self-heals rather than stranding.
            for attempt in 1...2 {
                do {
                    let shape = try await routing.startRoute(
                        from: LatLon(lat: origin.latitude, lon: origin.longitude),
                        to: LatLon(lat: dest.coordinate.latitude, lon: dest.coordinate.longitude),
                        profile: prof, language: lang, landmarks: true, eyesOff: eyesOff)
                    let coords = shape.map {
                        CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1])
                    }
                    guard coords.count >= 2 else { return }
                    routeShape = coords
                    routeDistanceKm = Self.distanceKm(coords)
                    routeDurationMin = Int(routeDistanceKm / snapshotKmh * 60)
                    return
                } catch {
                    NSLog("ScoovaReroute attempt %d failed: %@",
                          attempt, String(describing: error))
                    if attempt < 2 { try? await Task.sleep(nanoseconds: 600_000_000) }
                }
            }
        }
    }

    /// Turn a routing failure into a message the rider can act on.
    private static func routeErrorMessage(for error: Error?) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Check your connection and try again."
            case .timedOut:
                return "The routing service is slow to respond. Try again."
            default:
                return "We couldn't reach the routing service. Try again."
            }
        }
        if let ns = error as NSError?, ns.domain == "ScoovaRouting" {
            if (400..<500).contains(ns.code) {
                return "We couldn't find a route to that spot. Try a nearby one."
            }
            if ns.code >= 500 {
                return "The routing service is having trouble. Try again shortly."
            }
        }
        return "We couldn't plan a route there. Try a different spot."
    }

    private static func distanceKm(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var meters = 0.0
        for i in 1..<coords.count {
            let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            meters += b.distance(from: a)
        }
        return meters / 1000
    }

    private static func reverseGeocode(_ c: CLLocationCoordinate2D) async -> String? {
        var comps = URLComponents(string: "\(ScoovaAPI.gateway)/reverse")!
        comps.queryItems = [
            URLQueryItem(name: "point.lat", value: String(c.latitude)),
            URLQueryItem(name: "point.lon", value: String(c.longitude)),
            URLQueryItem(name: "size", value: "1"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(ScoovaAPI.key, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 12
        // Retry: a flaky HTTP/3 attempt (Cloudflare-fronted, common on
        // the Simulator) fails fast; the retry falls back to HTTP/2.
        for attempt in 1...3 {
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let features = json["features"] as? [[String: Any]],
               let props = features.first?["properties"] as? [String: Any],
               let label = props["label"] as? String,
               !label.isEmpty {
                return label
            }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        return nil
    }
}
