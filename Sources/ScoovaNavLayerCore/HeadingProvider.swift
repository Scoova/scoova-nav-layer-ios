import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// Emits compass heading in degrees [0..360). Uses CoreLocation's
/// `CLLocationManager.startUpdatingHeading()`.
///
/// On iOS the host app must add `NSLocationWhenInUseUsageDescription` and
/// request permission BEFORE the stream starts emitting.
final class HeadingProvider: NSObject, @unchecked Sendable {

#if canImport(CoreLocation)
    private let manager = CLLocationManager()
#endif
    private var continuation: AsyncStream<Float>.Continuation?

    public override init() {
        super.init()
#if os(iOS)
        manager.delegate = self
        manager.headingFilter = 2  // degrees
#endif
    }

    public func stream() -> AsyncStream<Float> {
        AsyncStream { cont in
            self.continuation = cont
#if os(iOS)
            self.manager.startUpdatingHeading()
#endif
            cont.onTermination = { [weak self] _ in
#if os(iOS)
                self?.manager.stopUpdatingHeading()
#endif
            }
        }
    }
}

#if os(iOS)
extension HeadingProvider: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let trueH = newHeading.trueHeading
        let mag = newHeading.magneticHeading
        let h = trueH >= 0 ? trueH : mag
        continuation?.yield(Float(h))
    }
}
#endif
