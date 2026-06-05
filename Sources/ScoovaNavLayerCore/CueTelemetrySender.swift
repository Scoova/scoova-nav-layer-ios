import Foundation

/// Pluggable batch-uploader for cue telemetry. The host wires this to
/// ``ScoovaNavLayer.onCueFired`` and forgets about it — the sender
/// buffers cues in memory and POSTs them to a configurable endpoint
/// in batches (every N seconds or after M events, whichever first).
/// Network failures are logged and dropped; nav cues never block on
/// telemetry.
///
/// Wire-format: a JSON object with the trip id + an array of cue
/// payloads matching ``ScoovaNavLayer.CueEvent``'s fields. Any backend
/// can ingest it — Scoova Monitor, Amplitude, a custom analytics
/// pipeline. The SDK doesn't care what's on the other end.
public final class CueTelemetrySender: @unchecked Sendable {

    public struct Config: Sendable {
        public let endpointURL: URL
        public let apiKey: String
        /// Opaque per-trip identifier the backend uses to group cues
        /// from the same ride. The host generates one (e.g. a UUID)
        /// at trip start and gives it here.
        public let tripId: String
        /// Flush cadence. Defaults to 10 s — small enough that a
        /// rider quitting the app doesn't lose more than the last
        /// 10 s of telemetry.
        public let flushIntervalMs: Int64
        /// Cue count that forces a flush regardless of the clock —
        /// guards against unbounded memory growth if the rider hits
        /// many cues quickly (interchange clusters).
        public let maxBatchSize: Int

        public init(
            endpointURL: URL, apiKey: String, tripId: String,
            flushIntervalMs: Int64 = 10_000,
            maxBatchSize: Int = 50
        ) {
            self.endpointURL = endpointURL
            self.apiKey = apiKey
            self.tripId = tripId
            self.flushIntervalMs = flushIntervalMs
            self.maxBatchSize = maxBatchSize
        }
    }

    private let config: Config
    private var buffer: [ScoovaNavLayer.CueEvent] = []
    private let lock = NSLock()
    private var flushTask: Task<Void, Never>?

    public init(config: Config) {
        self.config = config
        startFlushTimer()
    }

    deinit { flushTask?.cancel() }

    /// The function the host plugs into ``ScoovaNavLayer.onCueFired``.
    public func observe(_ event: ScoovaNavLayer.CueEvent) {
        lock.lock()
        buffer.append(event)
        let shouldFlush = buffer.count >= config.maxBatchSize
        lock.unlock()
        if shouldFlush {
            Task { [weak self] in await self?.flushNow() }
        }
    }

    /// Force an immediate flush — useful on app background / trip
    /// stop so the last few cues don't sit in memory until the next
    /// flush tick.
    public func flushNow() async {
        let snapshot: [ScoovaNavLayer.CueEvent] = {
            lock.lock(); defer { lock.unlock() }
            let copy = buffer
            buffer.removeAll(keepingCapacity: true)
            return copy
        }()
        guard !snapshot.isEmpty else { return }
        var req = URLRequest(url: config.endpointURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("scoova-nav-layer/1.0 (telemetry)", forHTTPHeaderField: "User-Agent")
        let cueDicts: [[String: Any]] = snapshot.map { e in
            var d: [String: Any] = [
                "tsMs": e.tsMs,
                "text": e.text,
                "tone": e.tone,
                "locale": e.locale,
            ]
            if let mi = e.maneuverIndex     { d["maneuverIndex"] = mi }
            if let mm = e.metersToManeuver { d["metersToManeuver"] = mm }
            return d
        }
        let body: [String: Any] = [
            "tripId": config.tripId,
            "cues": cueDicts,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return
        }
        req.httpBody = data
        _ = try? await URLSession.shared.data(for: req)
    }

    private func startFlushTimer() {
        flushTask?.cancel()
        let interval = config.flushIntervalMs
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                await self?.flushNow()
            }
        }
    }
}
