import Foundation

struct Coordinate: Equatable, Codable, Sendable {
    let latitude: Double
    let longitude: Double
    static let zero = Coordinate(latitude: 0, longitude: 0)

    var isValidGeoCoordinate: Bool {
        latitude.isFinite
            && longitude.isFinite
            && abs(latitude) <= 90
            && abs(longitude) <= 180
    }
}
