import Foundation
import simd

/// One sensor tick from the device IMU. Adapters / host apps call
/// ``ScoovaNavLayer/onMotion(_:)`` with one of these per sensor frame
/// (~10–100 Hz depending on platform).
///
/// All vectors are in the **device-local** frame. ``headingDeg`` is the
/// single world-frame field — it's the OS-fused magnetic compass heading
/// (Android's `TYPE_ROTATION_VECTOR`, iOS's `CMDeviceMotion.heading`,
/// browser `DeviceOrientationEvent.alpha`). Either supply it (preferred —
/// already de-tilted and gravity-aligned by the OS) or leave nil and the
/// fusion engine will integrate ``gyro`` to dead-reckon when GPS bearing
/// drops.
///
/// Every field is optional so an adapter can send partial frames; e.g. a
/// relay that ticks on each sensor independently will send one frame with
/// just `accel`, the next with just `gyro`, etc.
public struct MotionFrame: Sendable, Equatable {
    /// Monotonic timestamp in milliseconds. Used for dt calculations.
    public let tsMs: Int64
    /// Linear acceleration (gravity removed), device-local frame, m/s².
    /// Used for crash / hard-brake detection on accelerometer magnitude.
    public let accel: SIMD3<Float>?
    /// Angular velocity, device-local frame, rad/s. Used as a fallback
    /// source of heading-delta when the compass loses lock (indoors /
    /// near electrical interference / first second after boot).
    public let gyro: SIMD3<Float>?
    /// World-frame magnetic compass heading in degrees, 0..360
    /// (0 = magnetic north, 90 = east). Pre-fused by the OS — DO NOT
    /// pass raw magnetometer readings here.
    public let headingDeg: Float?

    public init(
        tsMs: Int64,
        accel: SIMD3<Float>? = nil,
        gyro: SIMD3<Float>? = nil,
        headingDeg: Float? = nil
    ) {
        self.tsMs = tsMs
        self.accel = accel
        self.gyro = gyro
        self.headingDeg = headingDeg
    }
}

/// Output of one motion-fusion update — the engine emits this every call
/// to ``MotionFusion/process(frame:)``. Consumers read what's interesting
/// to them; nils mean "no signal this tick."
public struct MotionState: Sendable, Equatable {
    /// Smoothed compass heading, 0..360, magnetic north reference. Nil
    /// until the first valid heading reading arrives.
    public let headingDeg: Float?
    /// If the fusion engine detected a turn completing during this
    /// window, the signed magnitude in degrees (positive = left,
    /// negative = right). Nil otherwise.
    public let turnDeg: Float?
    /// If a crash / hard-brake event fired this tick.
    public let crash: CrashEvent?

    public init(headingDeg: Float? = nil, turnDeg: Float? = nil, crash: CrashEvent? = nil) {
        self.headingDeg = headingDeg
        self.turnDeg = turnDeg
        self.crash = crash
    }
}

/// Detected adverse motion events the rider should be alerted about.
public enum CrashEvent: Sendable, Equatable {
    /// Sudden deceleration — rider braked hard or was rear-ended.
    /// Threshold: `|a| > 8 m/s²` sustained for > 300 ms.
    case hardBrake(tsMs: Int64, peakG: Float)
    /// Sudden impact — rider crashed. Threshold: `|a| > 30 m/s²` for any
    /// single sample. Higher confidence than `hardBrake`.
    case impact(tsMs: Int64, peakG: Float)

    public var tsMs: Int64 {
        switch self {
        case .hardBrake(let t, _), .impact(let t, _): return t
        }
    }
    /// Peak acceleration during the event, expressed in g (1g ≈ 9.81 m/s²).
    public var peakG: Float {
        switch self {
        case .hardBrake(_, let g), .impact(_, let g): return g
        }
    }
}

/// Stateful sensor fusion. One instance per nav session — feed it every
/// ``MotionFrame`` arriving from the host adapter; it returns a
/// ``MotionState`` describing what it derived from that frame plus the
/// recent history.
///
/// Math is intentionally simple (no Kalman filter) so the algorithm ports
/// cleanly to Kotlin / Dart / TypeScript without dragging in a linear-
/// algebra dependency. The trade-off: short-term GPS-outage dead reckoning
/// is heading-only, not position. (Position dead reckoning needs an EKF
/// and weeks of per-platform tuning — deferred.)
internal final class MotionFusion {
    // ── Tunables ──────────────────────────────────────────────────────
    /// Exponential moving average alpha for compass smoothing. Higher =
    /// more responsive, less stable. 0.25 is ~4-sample low-pass.
    private let headingEmaAlpha: Float = 0.25
    /// Sustained yaw magnitude that counts as a "turn completing".
    private let turnDeltaThresholdDeg: Float = 30
    /// Window in which we accumulate heading deltas to call a turn.
    private let turnWindowMs: Int64 = 4_000
    /// Crash impact: any single sample exceeds this magnitude (m/s²).
    private let crashImpactMps2: Float = 30
    /// Hard brake: sustained magnitude over this for > 300 ms.
    private let hardBrakeMps2: Float = 8
    private let hardBrakeDurationMs: Int64 = 300

    // ── State ─────────────────────────────────────────────────────────
    private var smoothedHeadingDeg: Float? = nil
    private var lastRawHeadingDeg: Float? = nil
    private var lastTsMs: Int64 = 0
    /// Accumulated signed heading change inside the active turn window.
    private var turnAccum: Float = 0
    private var turnWindowStartMs: Int64 = 0
    /// Last time we saw |accel| above the brake threshold.
    private var brakeStartMs: Int64 = 0

    func process(frame: MotionFrame) -> MotionState {
        let ts = frame.tsMs
        let dtMs: Int64 = lastTsMs > 0 ? ts - lastTsMs : 0
        lastTsMs = ts

        // ── Heading: prefer OS compass, fall back to gyro integration ──
        let newHeading: Float?
        if let raw = frame.headingDeg {
            let h = wrap360(raw)
            if let current = smoothedHeadingDeg {
                newHeading = circularEma(current, h, headingEmaAlpha)
            } else {
                newHeading = h
            }
        } else if let g = frame.gyro,
                  let current = smoothedHeadingDeg,
                  dtMs >= 1, dtMs <= 200 {
            // Gyro z-axis ≈ yaw rate in device frame. Imperfect (assumes
            // phone roughly upright on a handlebar mount) but better than
            // letting heading freeze when compass is briefly unavailable.
            // Convention: positive yaw = left turn = decreasing magnetic
            // heading.
            let dHeading = Float((Double(-g.z) * Double(dtMs) / 1000.0) * (180.0 / .pi))
            newHeading = wrap360(current + dHeading)
        } else {
            newHeading = smoothedHeadingDeg
        }
        smoothedHeadingDeg = newHeading

        // ── Turn detection (heading delta accumulating in a 4s window) ──
        var turnFired: Float? = nil
        if let raw = frame.headingDeg {
            if let last = lastRawHeadingDeg {
                let delta = headingDelta(last, raw)  // signed, in -180..180
                if turnWindowStartMs == 0 || ts - turnWindowStartMs > turnWindowMs {
                    turnWindowStartMs = ts
                    turnAccum = 0
                }
                turnAccum += delta
                if abs(turnAccum) > turnDeltaThresholdDeg {
                    turnFired = turnAccum
                    turnAccum = 0
                    turnWindowStartMs = ts
                }
            }
            lastRawHeadingDeg = raw
        }

        // ── Crash / hard-brake detection ──
        var crash: CrashEvent? = nil
        if let a = frame.accel {
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            if mag > crashImpactMps2 {
                crash = .impact(tsMs: ts, peakG: mag / 9.81)
                brakeStartMs = 0
            } else if mag > hardBrakeMps2 {
                if brakeStartMs == 0 {
                    brakeStartMs = ts
                } else if ts - brakeStartMs > hardBrakeDurationMs {
                    crash = .hardBrake(tsMs: ts, peakG: mag / 9.81)
                    brakeStartMs = 0
                }
            } else {
                brakeStartMs = 0
            }
        }

        return MotionState(
            headingDeg: smoothedHeadingDeg,
            turnDeg: turnFired,
            crash: crash
        )
    }

    func reset() {
        smoothedHeadingDeg = nil
        lastRawHeadingDeg = nil
        lastTsMs = 0
        turnAccum = 0
        turnWindowStartMs = 0
        brakeStartMs = 0
    }
}

// ── Math helpers ──────────────────────────────────────────────────────

/// Normalise an angle to [0, 360).
internal func wrap360(_ deg: Float) -> Float {
    var x = deg.truncatingRemainder(dividingBy: 360)
    if x < 0 { x += 360 }
    return x
}

/// Signed shortest-path delta between two headings.
/// `headingDelta(350, 10) == +20`, `headingDelta(10, 350) == -20`.
/// Positive = left turn (counter-clockwise from above in NED).
internal func headingDelta(_ prev: Float, _ next: Float) -> Float {
    var d = next - prev
    while d > 180 { d -= 360 }
    while d < -180 { d += 360 }
    return -d  // flip sign so left = positive (matches gyro convention)
}

/// Exponential moving average that respects the 360°→0° wrap-around. Used
/// to smooth compass readings without "snapping" across the boundary.
internal func circularEma(_ prev: Float, _ next: Float, _ alpha: Float) -> Float {
    // Average via unit vectors — sums to a stable mean even across 0°/360°.
    let pRad = Double(prev) * .pi / 180
    let nRad = Double(next) * .pi / 180
    let a = Double(alpha)
    let x = (1 - a) * cos(pRad) + a * cos(nRad)
    let y = (1 - a) * sin(pRad) + a * sin(nRad)
    return wrap360(Float(atan2(y, x) * 180 / .pi))
}
