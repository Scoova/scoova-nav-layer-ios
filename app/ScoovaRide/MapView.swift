import SwiftUI
import CoreLocation
import MapLibre

/// Scoova's own map styles. The style definitions ship **bundled** in
/// the app (`Styles/*.json`) and are refreshed from the server in the
/// background — see `MapStyleStore`. The vector tiles stay remote and
/// are style-independent, so the rider can swap styles freely.
enum MapStyle: CaseIterable {
    case dark, light, satellite

    /// Bundled-resource / disk-cache file name (without extension).
    var resourceName: String {
        switch self {
        case .dark:      return "scoova-dark"
        case .light:     return "scoova-default"
        case .satellite: return "scoova-satellite"
        }
    }

    /// Server style URL — used only by the background refresh. Goes
    /// through the keyed gateway; the bundled styles carry the key too.
    var remoteURL: URL {
        URL(string: "\(ScoovaAPI.gateway)/tiles/styles/\(resourceName)/style.json?api_key=\(ScoovaAPI.key)")!
    }
}

/// MapLibre-backed map surface drawing Scoova's own vector tiles.
///
/// The `MLNMapView` is added as an autoresizing subview of a plain
/// container `UIView` — the proven UIKit pattern. SwiftUI sizes the
/// container; the map autoresizes inside it. (Handing the `MLNMapView`
/// straight to SwiftUI breaks its Metal renderer's resize path — the
/// map then renders into a thin strip.)
struct RideMap: UIViewRepresentable {
    var routeShape: [CLLocationCoordinate2D]
    var destination: CLLocationCoordinate2D?
    var followUser: Bool
    /// When set, the camera follows this synthetic puck (a simulated
    /// ride) instead of the real GPS location.
    var simLocation: CLLocationCoordinate2D? = nil
    var style: MapStyle = .dark
    /// Rider locale — drives the locale-aware label rewrite so the map
    /// labels match the spoken-cue language (parity with Android).
    var locale: String = "en-US"
    /// Travel-mode bucket — drives the path-highlight palette so the
    /// rider sees cycleways bright on a bike, footways bright on foot,
    /// and roads emphasised in a car/motorcycle. Defaults to `.motor`
    /// so the map is sensible even before a persona is picked.
    var mode: PathHighlightMode = .motor
    /// Bump this to re-center the camera on the rider.
    var recenterTick: Int = 0
    /// Travel heading (degrees) — rotates the nav camera heading-up
    /// while `followUser` is on (used for the simulated ride).
    var headingDeg: Float = 0
    var onLongPress: ((CLLocationCoordinate2D) -> Void)?
    /// Tapping a POI icon hands back its coordinate, name, and category.
    var onPoiTap: ((CLLocationCoordinate2D, String, String?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black

        // Loads a local, Scoova-patched style — instant, offline-safe,
        // no remote style fetch. `MapStyleStore` also kicks off a
        // background refresh so the next launch picks up server edits.
        let map = MLNMapView(
            frame: .zero,
            styleURL: MapStyleStore.patchedStyleURL(
                for: style, locale: locale, mode: mode))
        map.translatesAutoresizingMaskIntoConstraints = false
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.automaticallyAdjustsContentInset = false
        map.contentInset = .zero
        let press = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        map.addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        map.addGestureRecognizer(tap)
        container.addSubview(map)
        NSLayoutConstraint.activate([
            map.topAnchor.constraint(equalTo: container.topAnchor),
            map.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            map.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            map.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        context.coordinator.mapView = map
        context.coordinator.lastStyle = style
        context.coordinator.lastLocale = locale
        context.coordinator.lastMode = mode
        MapStyleStore.refreshFromServer()
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let map = context.coordinator.mapView else { return }
        let coord = context.coordinator
        coord.parent = self
        map.contentInset = .zero

        if coord.lastStyle != style
            || coord.lastLocale != locale
            || coord.lastMode != mode {
            coord.lastStyle = style
            coord.lastLocale = locale
            coord.lastMode = mode
            coord.applyPatchedStyle(style: style, locale: locale, mode: mode)
        }

        // Route polyline — re-add only when the shape actually changed.
        let routeChanged = coord.lastRouteCount != routeShape.count
        if routeChanged {
            if let existing = coord.routeLine {
                map.removeAnnotation(existing)
                coord.routeLine = nil
            }
            if routeShape.count > 1 {
                let line = MLNPolyline(coordinates: routeShape, count: UInt(routeShape.count))
                map.addAnnotation(line)
                coord.routeLine = line
            }
            coord.lastRouteCount = routeShape.count
        }

        // Destination pin.
        if coord.lastDestLat != destination?.latitude
            || coord.lastDestLon != destination?.longitude {
            if let existing = coord.destPin {
                map.removeAnnotation(existing)
                coord.destPin = nil
            }
            if let dest = destination {
                let pin = MLNPointAnnotation()
                pin.coordinate = dest
                pin.title = "Destination"
                map.addAnnotation(pin)
                coord.destPin = pin
            }
            coord.lastDestLat = destination?.latitude
            coord.lastDestLon = destination?.longitude
        }

        // Simulated-ride puck — a visible dot at the synthetic position,
        // so the rider sees themselves move along the route. The real
        // GPS dot is hidden during a simulation: it would sit frozen at
        // the actual (stationary) location and confuse.
        if let sim = simLocation {
            if map.showsUserLocation { map.showsUserLocation = false }
            if let puck = coord.simPuck {
                puck.coordinate = sim
            } else {
                let puck = MLNPointAnnotation()
                puck.coordinate = sim
                // Set the reference BEFORE adding — `viewFor` is queried
                // on add and must already recognise this as the puck.
                coord.simPuck = puck
                map.addAnnotation(puck)
            }
        } else {
            if let puck = coord.simPuck {
                map.removeAnnotation(puck)
                coord.simPuck = nil
            }
            if !map.showsUserLocation { map.showsUserLocation = true }
        }

        // Camera.
        if let sim = simLocation {
            // Simulated ride — drive the tilted nav camera off the puck.
            if map.userTrackingMode != .none { map.userTrackingMode = .none }
            if coord.lastSimLat != sim.latitude || coord.lastSimLon != sim.longitude {
                let firstFix = coord.lastSimLat == nil
                coord.lastSimLat = sim.latitude
                coord.lastSimLon = sim.longitude
                Self.applyNavCamera(
                    to: map, center: sim,
                    heading: CLLocationDirection(headingDeg),
                    duration: firstFix ? 0 : 0.28
                )
            }
        } else if followUser {
            // Real ride — the nav camera is driven by GPS fixes in
            // `didUpdate userLocation`; hold tracking off so the manual
            // tilted camera isn't fought by the built-in follow mode.
            if map.userTrackingMode != .none { map.userTrackingMode = .none }
        } else {
            if map.userTrackingMode != .none {
                map.userTrackingMode = .none
            }
            if routeChanged && routeShape.count > 1 {
                map.setVisibleCoordinateBounds(
                    Self.bounds(routeShape),
                    edgePadding: UIEdgeInsets(top: 160, left: 50, bottom: 320, right: 50),
                    animated: true
                )
            }
        }

        if coord.lastRecenterTick != recenterTick {
            coord.lastRecenterTick = recenterTick
            if let loc = map.userLocation?.location {
                map.setCenter(loc.coordinate, zoomLevel: 17, animated: true)
            }
        }
    }

    /// Navigation camera — close, tilted, heading-up, the way Apple /
    /// Google nav frame the road. Used only while `followUser` is on;
    /// the plan screen is a separate map instance, so it stays flat
    /// and north-up with no explicit revert needed.
    static let navZoomLevel: Double = 19
    static let navPitch: CGFloat = 45

    /// Point the camera at `center`, tilted + zoomed for navigation and
    /// rotated so `heading` (degrees, 0 = north) is "up".
    static func applyNavCamera(
        to map: MLNMapView,
        center: CLLocationCoordinate2D,
        heading: CLLocationDirection,
        duration: TimeInterval
    ) {
        let altitude = MLNAltitudeForZoomLevel(
            navZoomLevel, navPitch, center.latitude, map.bounds.size)
        let camera = MLNMapCamera(
            lookingAtCenter: center,
            altitude: altitude,
            pitch: navPitch,
            heading: max(0, heading)
        )
        map.setCamera(camera, withDuration: duration, animationTimingFunction: nil)
    }

    private static func bounds(_ coords: [CLLocationCoordinate2D]) -> MLNCoordinateBounds {
        var minLat = coords[0].latitude, maxLat = coords[0].latitude
        var minLon = coords[0].longitude, maxLon = coords[0].longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
            ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon)
        )
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: RideMap
        weak var mapView: MLNMapView?
        var lastRouteCount = -1
        var lastRecenterTick = 0
        var lastStyle: MapStyle?
        var lastLocale: String?
        var lastMode: PathHighlightMode?
        var lastDestLat: Double?
        var lastDestLon: Double?
        var lastSimLat: Double?
        var lastSimLon: Double?
        var routeLine: MLNPolyline?
        var destPin: MLNPointAnnotation?
        /// The moving dot during a simulated ride.
        var simPuck: MLNPointAnnotation?
        private var didCenterUser = false

        init(_ parent: RideMap) { self.parent = parent }

        /// Resolve + Scoova-patch the style locally and assign it. The
        /// patch is pure-local (no network), so this is synchronous.
        func applyPatchedStyle(style: MapStyle,
                                locale: String,
                                mode: PathHighlightMode) {
            mapView?.styleURL = MapStyleStore.patchedStyleURL(
                for: style, locale: locale, mode: mode)
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            // The one route colour — `RideTokens.routeCore`, shared with
            // the History thumbnail so the line never changes hue
            // between screens.
            UIColor(RideTokens.routeCore)
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            6
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            guard let loc = userLocation?.location else { return }
            // Real ride — keep the tilted nav camera locked on the rider,
            // rotated to the direction of travel.
            if parent.followUser && parent.simLocation == nil {
                let course = loc.course
                let heading: CLLocationDirection = course >= 0
                    ? course
                    : (userLocation?.heading?.trueHeading ?? mapView.direction)
                RideMap.applyNavCamera(to: mapView, center: loc.coordinate,
                                       heading: heading, duration: 0.4)
                return
            }
            // Plan screen — one gentle recenter on the first fix.
            guard !didCenterUser, !parent.followUser, parent.routeShape.isEmpty
            else { return }
            mapView.setCenter(loc.coordinate, zoomLevel: 16.5, animated: true)
            didCenterUser = true
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            // No callout bubbles — the destination pin speaks for itself;
            // a bare "Destination" callout looks unfinished.
            false
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            // Only the ride puck gets a custom view — a directional nav
            // arrow. The destination pin falls through (returns nil) to
            // the default marker.
            guard let puck = simPuck,
                  (annotation as AnyObject) === (puck as AnyObject) else { return nil }
            let id = "scoova-nav-puck"
            if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                return reused
            }
            let view = MLNAnnotationView(reuseIdentifier: id)
            view.frame = CGRect(x: 0, y: 0, width: 38, height: 44)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            let arrow = UIImageView(image: Coordinator.puckArrowImage)
            arrow.frame = view.bounds
            arrow.contentMode = .scaleAspectFit
            view.addSubview(arrow)
            return view
        }

        /// The navigation puck — a directional arrowhead (Mapbox / Apple
        /// style), not a plain location dot. The nav camera is
        /// heading-up, so a fixed up-pointing arrow always reads as
        /// "straight ahead".
        static let puckArrowImage: UIImage = {
            let size = CGSize(width: 38, height: 44)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let g = ctx.cgContext
                // Arrowhead, pointing up: tip, two wings, a centre notch.
                let arrow = UIBezierPath()
                arrow.move(to: CGPoint(x: 19, y: 6))      // tip
                arrow.addLine(to: CGPoint(x: 33, y: 37))  // right wing
                arrow.addLine(to: CGPoint(x: 19, y: 28))  // bottom notch
                arrow.addLine(to: CGPoint(x: 5, y: 37))   // left wing
                arrow.close()
                arrow.lineJoinStyle = .round
                arrow.lineWidth = 3
                g.setShadow(offset: CGSize(width: 0, height: 2), blur: 5,
                            color: UIColor.black.withAlphaComponent(0.5).cgColor)
                UIColor(RideTokens.accent).setFill()
                arrow.fill()
                g.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor.white.setStroke()
                arrow.stroke()
            }
        }()

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let map = recognizer.view as? MLNMapView else { return }
            let point = recognizer.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            parent.onLongPress?(coordinate)
        }

        /// POI symbol layers in the Scoova styles — a tap landing on one
        /// routes straight to that place.
        static let poiLayerIDs: Set<String> = [
            "poi-hospital", "poi-restaurant", "poi-hotel", "poi-school",
            "poi-park", "poi-shop", "poi-transit", "poi-parking", "poi-amenity",
        ]

        /// "poi-restaurant" → "Restaurant" — a human label for the card.
        static func category(for layerID: String) -> String {
            switch layerID {
            case "poi-hospital":   return "Hospital"
            case "poi-restaurant": return "Restaurant"
            case "poi-hotel":      return "Hotel"
            case "poi-school":     return "School"
            case "poi-park":       return "Park"
            case "poi-shop":       return "Shop"
            case "poi-transit":    return "Transit stop"
            case "poi-parking":    return "Parking"
            default:               return "Place"
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let map = recognizer.view as? MLNMapView else { return }
            let point = recognizer.location(in: map)
            // Finger-sized hit box — POI icons are small to pixel-test.
            let pad: CGFloat = 22
            let rect = CGRect(x: point.x - pad, y: point.y - pad,
                              width: pad * 2, height: pad * 2)
            // Query each POI layer in turn — the matching layer is what
            // tells us the category to show in the place card.
            for layerID in Self.poiLayerIDs {
                guard let poi = map.visibleFeatures(
                    in: rect, styleLayerIdentifiers: [layerID])
                    .compactMap({ $0 as? MLNPointFeature })
                    .first else { continue }
                let name = (poi.attribute(forKey: "name") as? String)
                    ?? (poi.attribute(forKey: "name:latin") as? String) ?? ""
                guard !name.isEmpty else { continue }
                parent.onPoiTap?(poi.coordinate, name, Self.category(for: layerID))
                return
            }
        }
    }
}
