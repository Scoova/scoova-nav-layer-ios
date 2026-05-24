import Foundation

/// Path-rendering bucket — drives which infrastructure the map
/// highlights to the rider. Three buckets cover the five personas:
///
///  • `.bike` — bicycle + scooter (lightweight two-wheel) → cycleways
///    bright cyan, footways dimmed (you don't ride on a sidewalk).
///  • `.foot` — walking + running → footways bright amber, cycleways
///    visible but dimmed (you can use them but they're not yours).
///  • `.motor` — motorcycle + car → all paths muted grey (irrelevant
///    to a driver; they care about roads).
enum PathHighlightMode { case bike, foot, motor }

/// Style.json transforms — the iOS port of the Android
/// `ScoovaStylePatcher` (adapter-maplibre). Applies four idempotent
/// passes, purely on a local JSON (no network — the JSON is resolved
/// by `MapStyleStore` from the bundle or disk cache):
///
///  1. **Font collapse** — force every text-font chain to a single
///     known-good font (`Noto Sans Regular`). Multi-font stacks 404 on
///     the tile server and the renderer drops the glyphs instead of
///     falling back, which mangles RTL text.
///  2. **3D building extrusions** — inject a `fill-extrusion` layer so
///     building footprints rise when the camera tilts.
///  3. **Locale-aware labels** — rewrite every text-field to a
///     `coalesce` that prefers `name:<locale>` and falls back to
///     `name:latin`, so labels follow the rider's language.
///  4. **Mode-aware path split** — the base style lumps cycleways,
///     footways and generic paths into one dimmed layer, so a rider
///     looking at the map can't tell which dashed line is a bike lane.
///     This pass replaces that layer with three subclass-filtered
///     layers, coloured per the active mode.
///
/// Mirrors `ScoovaStylePatcher.kt`.
enum ScoovaStylePatcher {

    private static let building3DLayerID = "scoova-building-3d"

    /// Apply the transforms to a style JSON and write the patched
    /// result to a temp file; return its `file://` URL. [name] keys
    /// the temp file so the three styles don't collide.
    static func patch(_ data: Data,
                      named name: String,
                      locale: String,
                      mode: PathHighlightMode = .motor,
                      building3d: Bool = true) -> URL? {
        guard var style = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else { return nil }

        rewriteFonts(&style)
        if building3d { addBuildingExtrusions(&style) }
        rewriteTextLanguage(&style, locale: locale)
        splitPathsByMode(&style, mode: mode)

        guard let out = try? JSONSerialization.data(withJSONObject: style)
        else { return nil }
        let loc = locale.isEmpty ? "base" : locale
        let modeKey: String = {
            switch mode { case .bike: return "bike"; case .foot: return "foot"; case .motor: return "motor" }
        }()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("scoova-style-\(name)-\(loc)-\(modeKey).json")
        guard (try? out.write(to: file)) != nil else { return nil }
        return file
    }

    /// Force every text-font chain to a single known-good font.
    static func rewriteFonts(_ style: inout [String: Any]) {
        guard var layers = style["layers"] as? [[String: Any]] else { return }
        for i in layers.indices {
            guard var layout = layers[i]["layout"] as? [String: Any],
                  layout["text-field"] != nil else { continue }
            layout["text-font"] = ["Noto Sans Regular"]
            layers[i]["layout"] = layout
        }
        style["layers"] = layers
    }

    /// Inject a `fill-extrusion` layer for 3D building footprints,
    /// spliced just before the first symbol layer so labels stay on top.
    static func addBuildingExtrusions(_ style: inout [String: Any]) {
        guard var layers = style["layers"] as? [[String: Any]] else { return }
        if layers.contains(where: { ($0["id"] as? String) == building3DLayerID }) {
            return
        }
        // Source that actually carries the `building` source-layer;
        // fall back to the first vector source if none is found.
        let buildingSource = layers.first {
            ($0["source-layer"] as? String) == "building"
        }?["source"] as? String
        let vectorSource = (style["sources"] as? [String: Any])?
            .first { ($0.value as? [String: Any])?["type"] as? String == "vector" }?.key
        guard let source = buildingSource ?? vectorSource else { return }

        var firstSymbolIdx = layers.count
        for (i, layer) in layers.enumerated()
        where (layer["type"] as? String) == "symbol" {
            firstSymbolIdx = i
            break
        }
        let extrusion: [String: Any] = [
            "id": building3DLayerID,
            "type": "fill-extrusion",
            "source": source,
            "source-layer": "building",
            "minzoom": 14.0,
            "paint": [
                "fill-extrusion-color": "#3a3f4c",
                "fill-extrusion-height": ["get", "render_height"],
                "fill-extrusion-base": ["get", "render_min_height"],
                "fill-extrusion-opacity": 0.92,
            ] as [String: Any],
        ]
        layers.insert(extrusion, at: firstSymbolIdx)
        style["layers"] = layers
    }

    /// Replace the base style's catch-all `road_path_pedestrian` layer
    /// with three subclass-filtered layers (cycleway / footway / generic
    /// path), coloured per the active travel mode. Looking at the map
    /// the rider can now tell which dashed line is a bike lane vs a
    /// sidewalk — the routing engine has always known the difference,
    /// the map style just wasn't showing it.
    static func splitPathsByMode(_ style: inout [String: Any],
                                  mode: PathHighlightMode) {
        guard var layers = style["layers"] as? [[String: Any]] else { return }
        let target = "road_path_pedestrian"
        guard let idx = layers.firstIndex(where: {
            ($0["id"] as? String) == target
        }) else { return }
        let base = layers[idx]
        let source = base["source"] as? String ?? "openmaptiles"
        let sourceLayer = base["source-layer"] as? String ?? "transportation"
        let minzoom = base["minzoom"]
        let maxzoom = base["maxzoom"]
        let lineWidth = (base["paint"] as? [String: Any])?["line-width"]

        // Per-mode palette — bright = "this is what you want to use",
        // dim = "exists but not yours".
        struct Palette {
            let cycleway: (color: String, opacity: Double)
            let footway:  (color: String, opacity: Double)
            let generic:  (color: String, opacity: Double)
        }
        let p: Palette
        switch mode {
        case .bike:
            p = Palette(cycleway: ("#06b6d4", 1.00),   // bright cyan
                         footway:  ("#3d5446", 0.45),
                         generic:  ("#5a8c5a", 0.80))
        case .foot:
            p = Palette(cycleway: ("#5a8c5a", 0.65),
                         footway:  ("#f59e0b", 1.00),   // bright amber
                         generic:  ("#a3b18a", 0.90))
        case .motor:
            p = Palette(cycleway: ("#3d5446", 0.45),
                         footway:  ("#3d5446", 0.40),
                         generic:  ("#3d5446", 0.45))
        }

        func makeLayer(id: String,
                        subclasses: [String],
                        color: String,
                        opacity: Double,
                        dash: [Double]) -> [String: Any] {
            var filter: [Any] = ["all",
                                  ["==", "$type", "LineString"],
                                  ["!in", "brunnel", "bridge", "tunnel"],
                                  ["in", "class", "path", "pedestrian"]]
            // OpenMapTiles `subclass` is the original highway= value.
            if subclasses.count == 1 {
                filter.append(["==", "subclass", subclasses[0]])
            } else {
                var sub: [Any] = ["in", "subclass"]
                sub.append(contentsOf: subclasses as [Any])
                filter.append(sub)
            }
            var paint: [String: Any] = [
                "line-color": color,
                "line-opacity": opacity,
                "line-dasharray": dash,
            ]
            if let lw = lineWidth { paint["line-width"] = lw }
            var layer: [String: Any] = [
                "id": id,
                "type": "line",
                "source": source,
                "source-layer": sourceLayer,
                "filter": filter,
                "paint": paint,
            ]
            if let mz = minzoom { layer["minzoom"] = mz }
            if let xz = maxzoom { layer["maxzoom"] = xz }
            return layer
        }

        let cycleway = makeLayer(id: "scoova_road_cycleway",
                                  subclasses: ["cycleway", "mountain_bike"],
                                  color: p.cycleway.color,
                                  opacity: p.cycleway.opacity,
                                  dash: [4, 2])
        let footway = makeLayer(id: "scoova_road_footway",
                                  subclasses: ["footway", "pedestrian", "steps", "sidewalk"],
                                  color: p.footway.color,
                                  opacity: p.footway.opacity,
                                  dash: [2, 2])
        let generic = makeLayer(id: "scoova_road_path_generic",
                                  subclasses: ["path", "track", "bridleway"],
                                  color: p.generic.color,
                                  opacity: p.generic.opacity,
                                  dash: [3, 2])

        layers.remove(at: idx)
        layers.insert(contentsOf: [cycleway, footway, generic], at: idx)
        style["layers"] = layers
    }

    /// Rewrite every text-field to prefer the rider's language, falling
    /// back to `name:latin`. Road shields (`{ref}`) are left alone.
    ///
    /// We coalesce in three tiers — fully-qualified locale first, then
    /// the base language, then Latin. OpenMapTiles names are usually
    /// keyed on base language (`name:ar`), but some sources carry
    /// region-specific keys (`name:ar-EG`, `name:zh-Hant`) and we want
    /// those when present rather than dropping straight to the Latin
    /// transliteration for a dialect speaker.
    static func rewriteTextLanguage(_ style: inout [String: Any], locale: String) {
        let trimmed = locale.lowercased()
        let base = trimmed.split(separator: "-").first.map(String.init) ?? ""
        guard !base.isEmpty else { return }
        guard var layers = style["layers"] as? [[String: Any]] else { return }
        // Three-tier coalesce: full locale → base → latin.
        // For locales WITHOUT a region tag (e.g. "en", "fr"), the first
        // two tiers collapse into the same key; that's harmless — the
        // MapLibre expression engine just resolves the same field twice.
        let coalesced: [Any] = [
            "coalesce",
            ["get", "name:\(trimmed)"],
            ["get", "name:\(base)"],
            ["get", "name:latin"],
        ]
        for i in layers.indices {
            guard var layout = layers[i]["layout"] as? [String: Any],
                  let textField = layout["text-field"] else { continue }
            if let token = textField as? String, token.contains("{ref}") { continue }
            layout["text-field"] = coalesced
            layers[i]["layout"] = layout
        }
        style["layers"] = layers
    }
}
