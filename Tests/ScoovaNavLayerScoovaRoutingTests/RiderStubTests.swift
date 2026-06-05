import XCTest
@testable import ScoovaNavLayerScoovaRouting

/// `prependRiderStubIfNeeded` adds the rider's real GPS as the
/// polyline's vertex 0 when the engine snapped the start to a road
/// > 15 m away. This is the "rider is in a parking lot, the route
/// starts on the street" case Google Maps / Mapbox cover by
/// drawing a stub from puck to first vertex. Without the stub
/// there's a visible gap between rider and the drawn line.
final class RiderStubTests: XCTestCase {

    /// Rider in a parking lot, snap point on the street ~50 m east.
    /// Must prepend the rider's coord so the line connects.
    func testStubPrependsRiderWhenGapAbove15m() {
        let shape: [[Double]] = [
            [37.330000, -122.030000],   // snap point on street
            [37.330200, -122.030000]
        ]
        let augmented = ScoovaRoutingAdapter.prependRiderStubIfNeeded(
            shape,
            riderLat: 37.330000,
            riderLon: -122.030500   // ~44 m west of the snap point
        )
        XCTAssertEqual(augmented.count, 3,
            "Augmented shape must include the rider stub")
        XCTAssertEqual(augmented[0][0], 37.330000, accuracy: 1e-9)
        XCTAssertEqual(augmented[0][1], -122.030500, accuracy: 1e-9,
            "Vertex 0 must be the rider's actual GPS")
    }

    /// Rider already on the snap point (< 15 m). No stub needed.
    func testStubSkippedWhenGapBelowThreshold() {
        let shape: [[Double]] = [
            [37.330000, -122.030000],
            [37.330200, -122.030000]
        ]
        let augmented = ScoovaRoutingAdapter.prependRiderStubIfNeeded(
            shape,
            riderLat: 37.330050,
            riderLon: -122.030010   // ~6 m off the first vertex
        )
        XCTAssertEqual(augmented.count, 2,
            "Below-threshold gap must NOT augment the shape")
    }

    /// Empty shape: nothing to do.
    func testStubNoopOnEmptyShape() {
        let augmented = ScoovaRoutingAdapter.prependRiderStubIfNeeded(
            [], riderLat: 37.33, riderLon: -122.03)
        XCTAssertEqual(augmented.count, 0)
    }
}
