import Foundation
import Combine
import CoreLocation

protocol LocationServiceProtocol {
    var authorizationStatus: AnyPublisher<LocationAuthStatus, Never> { get }
    var accuracyAuthorization: AnyPublisher<LocationAccuracyAuthorization, Never> { get }
    var currentCoordinate: AnyPublisher<Coordinate, Never> { get }
    var currentLocationSample: AnyPublisher<LocationSample, Never> { get }
    var currentHeading: AnyPublisher<CLHeading?, Never> { get }
    func requestAuthorization()
    func requestAlwaysAuthorizationIfNeeded()
    func requestTemporaryFullAccuracyIfNeeded()
    func refreshAuthorizationStatus()
    func startUpdating()
    func stopUpdating()
    func setPreferredLocationMode(_ mode: LocationMode)
    func setBackgroundParkingAssistanceActive(_ active: Bool)
    func reverseGeocode(_ coordinate: Coordinate) async throws -> String
}

extension LocationServiceProtocol {
    func requestTemporaryFullAccuracyIfNeeded() {}
    func setPreferredLocationMode(_ mode: LocationMode) {}
}

extension LocationServiceProtocol {
    var accuracyAuthorization: AnyPublisher<LocationAccuracyAuthorization, Never> {
        Just(.unknown).eraseToAnyPublisher()
    }

    func requestAlwaysAuthorizationIfNeeded() {}
    func refreshAuthorizationStatus() {}
    func setBackgroundParkingAssistanceActive(_ active: Bool) { _ = active }
}

struct LocationSample: Equatable {
    let coordinate: Coordinate
    let accuracy: Double
    let date: Date
    let speed: Double
    let course: Double?

    init(
        coordinate: Coordinate,
        accuracy: Double,
        date: Date,
        speed: Double = 0,
        course: Double? = nil
    ) {
        self.coordinate = coordinate
        self.accuracy = accuracy
        self.date = date
        self.speed = speed
        self.course = course
    }
}

enum LocationAuthStatus: Equatable {
    case notDetermined, denied, restricted, authorized, authorizedWhenInUse, authorizedAlways
}

extension LocationAuthStatus {
    var isDeniedOrRestricted: Bool {
        self == .denied || self == .restricted
    }

    var needsAlwaysUpgrade: Bool {
        self == .authorizedWhenInUse
    }
}

enum LocationAccuracyAuthorization: Equatable {
    case unknown, reducedAccuracy, fullAccuracy
}
