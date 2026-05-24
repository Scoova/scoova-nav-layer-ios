import Foundation
import simd
#if canImport(CoreMotion)
import CoreMotion
#endif

/// Bridges Apple's `CMMotionManager` (CoreMotion) into the nav layer's
/// ``ScoovaNavLayer/onMotion(_:)`` channel.
///
/// On `start()` we subscribe to **device motion** at 50 Hz with the
/// `.xMagneticNorthZVertical` reference frame so we get an OS-fused
/// magnetic compass heading without having to de-tilt the raw
/// magnetometer ourselves. Each `CMDeviceMotion` carries:
///
///   * `heading`           → world-frame compass deg (already 0..360)
///   * `userAcceleration`  → device-frame accel **in g** (gravity removed)
///   * `rotationRate`      → device-frame yaw rate **in rad/s**
///
/// We pack those into a fresh ``MotionFrame`` per update and forward
/// through the `onFrame` closure. Coalescing per update (vs per sensor)
/// mirrors the Android relay's per-event coalescing and keeps the fusion
/// engine's `dt` math monotonic.
///
/// Battery: device motion at 50 Hz draws ~3–6 mW on an A15+. Negligible
/// versus GPS + tile rendering.
///
/// macOS: this type is a no-op (`start()` / `stop()` do nothing) because
/// CoreMotion isn't available there.
final class SensorRelay: @unchecked Sendable {

    /// Fires once per fused device-motion sample (~50 Hz).
    public let onFrame: (MotionFrame) -> Void

#if canImport(CoreMotion) && os(iOS)
    private let motionManager: CMMotionManager
    private let queue: OperationQueue
#endif

    public init(onFrame: @escaping (MotionFrame) -> Void) {
        self.onFrame = onFrame
#if canImport(CoreMotion) && os(iOS)
        self.motionManager = CMMotionManager()
        self.queue = OperationQueue()
        self.queue.qualityOfService = .userInitiated
        self.queue.maxConcurrentOperationCount = 1
#endif
    }

    /// Begin streaming device-motion updates. Idempotent — calling twice
    /// is a no-op.
    public func start() {
#if canImport(CoreMotion) && os(iOS)
        guard motionManager.isDeviceMotionAvailable else { return }
        if motionManager.isDeviceMotionActive { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
        motionManager.startDeviceMotionUpdates(
            using: .xMagneticNorthZVertical,
            to: queue
        ) { [weak self] dm, _ in
            guard let self = self, let dm = dm else { return }
            let tsMs = Int64(Date().timeIntervalSince1970 * 1000)
            // `userAcceleration` is in g (gravity removed) — scale to m/s².
            let g = 9.81 as Float
            let accel = SIMD3<Float>(
                Float(dm.userAcceleration.x) * g,
                Float(dm.userAcceleration.y) * g,
                Float(dm.userAcceleration.z) * g
            )
            let gyro = SIMD3<Float>(
                Float(dm.rotationRate.x),
                Float(dm.rotationRate.y),
                Float(dm.rotationRate.z)
            )
            // `heading` is magnetic deg 0..360 when we ask for the
            // `.xMagneticNorthZVertical` reference frame; -1 means "not
            // yet available" (calibration in progress).
            let headingDeg: Float? = dm.heading >= 0 ? Float(dm.heading) : nil
            self.onFrame(MotionFrame(
                tsMs: tsMs,
                accel: accel,
                gyro: gyro,
                headingDeg: headingDeg
            ))
        }
#endif
    }

    /// Stop streaming. Safe to call before `start()`.
    public func stop() {
#if canImport(CoreMotion) && os(iOS)
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
#endif
    }

    deinit {
        stop()
    }
}
