import Foundation

/// Hybrid delivery for the Scoova map styles.
///
/// The three styles ship **bundled** in the app (`Styles/*.json`) so the
/// map renders instantly and offline. In the background the store
/// refreshes them from `tiles.scoo-va.info` and caches the result; the
/// next map load prefers the cached copy. So server-side style fixes
/// reach users without an app release — but a launch never waits on the
/// network.
///
/// `MLNMapView` therefore only ever loads a *local* `file://` style, so
/// the QUIC / HTTP-3 flakiness that breaks remote style fetches in the
/// Simulator (and on poor networks) can't affect the map's appearance.
enum MapStyleStore {

    /// Resolve the base JSON for [style], apply the Scoova patches for
    /// [locale] + [mode], and return a local `file://` style URL ready
    /// for `MLNMapView.styleURL`. Entirely local — no network on this
    /// path. [mode] drives the path-highlight palette (cycleway bright
    /// for bike riders, footway bright for walkers, all muted for cars).
    static func patchedStyleURL(for style: MapStyle,
                                 locale: String,
                                 mode: PathHighlightMode = .motor) -> URL {
        let data = baseStyleData(for: style)
        return ScoovaStylePatcher.patch(
            data, named: style.resourceName, locale: locale, mode: mode)
            ?? bundledURL(for: style)
    }

    /// Base (un-patched) style JSON — the cached server copy if one has
    /// been downloaded, otherwise the copy bundled with the app.
    static func baseStyleData(for style: MapStyle) -> Data {
        if let cached = cacheURL(for: style),
           let data = try? Data(contentsOf: cached), !data.isEmpty {
            return data
        }
        return (try? Data(contentsOf: bundledURL(for: style))) ?? Data()
    }

    /// Fetch the latest styles from the server once per launch and cache
    /// them for next time. Failures are silent — the bundled (or
    /// previously cached) copy keeps the map working regardless.
    /// Also sweeps stale patched-style temp files (>24h old) so the
    /// temp directory doesn't grow without bound for riders who try
    /// many locales or who keep the app installed across many versions.
    static func refreshFromServer() {
        guard !didStartRefresh else { return }
        didStartRefresh = true
        Task.detached(priority: .utility) {
            pruneStalePatchedStyles()
            for style in MapStyle.allCases {
                var req = URLRequest(url: style.remoteURL)
                req.timeoutInterval = 20
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      (try? JSONSerialization.jsonObject(with: data)) != nil,
                      let dest = cacheURL(for: style)
                else { continue }
                try? data.write(to: dest)
            }
        }
    }

    /// Remove patched-style temp files older than 24 hours. Each
    /// `ScoovaStylePatcher.patch(…)` call writes one file keyed on
    /// `name-locale-mode`. Active files get rewritten on the next map
    /// load, so anything older than a day is genuinely stale.
    private static func pruneStalePatchedStyles() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let contents = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for url in contents where url.lastPathComponent.hasPrefix("scoova-style-") {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            if mtime < cutoff { try? fm.removeItem(at: url) }
        }
    }

    // ── Internals ────────────────────────────────────────────────────

    private static var didStartRefresh = false

    private static func bundledURL(for style: MapStyle) -> URL {
        // The bundled style is a required resource — a missing one is a
        // packaging bug, so force-unwrap to surface it immediately.
        Bundle.main.url(forResource: style.resourceName, withExtension: "json")!
    }

    private static func cacheURL(for style: MapStyle) -> URL? {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let dir = caches.appendingPathComponent("ScoovaStyles", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(style.resourceName).json")
    }
}
