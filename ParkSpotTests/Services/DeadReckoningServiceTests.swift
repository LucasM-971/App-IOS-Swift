import XCTest
@testable import ParkSpot

final class DeadReckoningServiceTests: XCTestCase {

    func testEstimateCoordinateMovesNorth() {
        let start = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let estimated = DeadReckoningService.estimateCoordinate(
            from: start,
            distanceMeters: 75,
            headingDegrees: 0
        )

        XCTAssertGreaterThan(estimated.latitude, start.latitude)
        XCTAssertEqual(estimated.longitude, start.longitude, accuracy: 0.001)
    }

    func testEstimateCoordinateMovesEast() {
        let start = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let estimated = DeadReckoningService.estimateCoordinate(
            from: start,
            distanceMeters: 75,
            headingDegrees: 90
        )

        XCTAssertGreaterThan(estimated.longitude, start.longitude)
        XCTAssertEqual(estimated.latitude, start.latitude, accuracy: 0.001)
    }

    func testDistanceHelperIsConsistent() {
        let a = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let b = Coordinate(latitude: 48.8570, longitude: 2.3522)
        let c = Coordinate(latitude: 48.8580, longitude: 2.3522)

        let ab = DeadReckoningService.distance(from: a, to: b)
        let ac = DeadReckoningService.distance(from: a, to: c)

        XCTAssertGreaterThan(ab, 0)
        XCTAssertGreaterThan(ac, ab)
    }
}
