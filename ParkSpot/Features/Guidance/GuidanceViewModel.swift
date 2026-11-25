import SwiftUI
import CoreLocation
import Combine
import UIKit
import MapKit

@MainActor
final class GuidanceViewModel: NSObject, ObservableObject {
    private enum LocationProfile {
        case map
        case compass
        case ar
    }

    private let manager = CLLocationManager()
    private let precisionReducer = LocationPrecisionReducer()
    private let fallbackLocationMaxAge: TimeInterval = 12 * 60 * 60
    private var targetCoordinate: Coordinate?
    private var currentProfile: LocationProfile = .map
    private var isHeadingActive = false
    private var isSuspendedForBackground = false
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var latestHeading: CLHeading?

    private var isPowerConstrained: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.isLowPowerModeEnabled || processInfo.thermalState == .serious || processInfo.thermalState == .critical
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 2
        manager.headingFilter = 1
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = true
    }

    func start(to coordinate: Coordinate) {
        guard coordinate.isValidGeoCoordinate else { return }
        targetCoordinate = coordinate
        precisionReducer.reset()
        currentProfile = .map
        latestHeading = nil
        latestLocation = bootstrapInitialLocation()
        manager.requestWhenInUseAuthorization()
        applyManagerSettings(for: currentProfile)
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        stopHeadingUpdatesIfNeeded()
        precisionReducer.reset()
        targetCoordinate = nil
        currentProfile = .map
        isSuspendedForBackground = false
    }

    func handleDidEnterBackground(distanceToCar: Double) {
        guard distanceToCar > 30 else { return }
        isSuspendedForBackground = true
        stopHeadingUpdatesIfNeeded()
        manager.stopUpdatingLocation()
    }

    func handleWillEnterForeground() {
        guard isSuspendedForBackground, targetCoordinate != nil else { return }
        isSuspendedForBackground = false
        manager.startUpdatingLocation()
    }

    func distanceMeters(to coordinate: Coordinate) -> Double {
        guard coordinate.isValidGeoCoordinate,
              let user = latestLocation,
              user.coordinate.latitude.isFinite,
              user.coordinate.longitude.isFinite else {
            return .infinity
        }

        let car = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return user.distance(from: car)
    }

    func distanceText(to coordinate: Coordinate) -> String {
        let meters = distanceMeters(to: coordinate)
        guard meters.isFinite else { return "--" }
        return meters < 1000 ? String(format: "%.0f m", meters) : String(format: "%.2f km", meters / 1000)
    }

    func relativeBearing(to coordinate: Coordinate) -> Double {
        guard coordinate.isValidGeoCoordinate,
              let user = latestLocation,
              user.coordinate.latitude.isFinite,
              user.coordinate.longitude.isFinite,
              let heading = latestHeading else {
            return 0
        }

        let userLat = user.coordinate.latitude * .pi / 180
        let userLon = user.coordinate.longitude * .pi / 180
        let carLat = coordinate.latitude * .pi / 180
        let carLon = coordinate.longitude * .pi / 180

        let dLon = carLon - userLon
        let y = sin(dLon) * cos(carLat)
        let x = cos(userLat) * sin(carLat) - sin(userLat) * cos(carLat) * cos(dLon)

        var bearing = atan2(y, x) * 180 / .pi
        bearing = (bearing + 360).truncatingRemainder(dividingBy: 360)
        let relative = bearing - resolvedHeadingValue(from: heading)
        return relative.isFinite ? relative : 0
    }

    private func updateLocationProfile(with userLocation: CLLocation) {
        guard let targetCoordinate else { return }

        let car = CLLocation(latitude: targetCoordinate.latitude, longitude: targetCoordinate.longitude)
        let distance = userLocation.distance(from: car)

        let constrained = isPowerConstrained

        let nextProfile: LocationProfile
        if distance >= 500 {
            nextProfile = .map
        } else if constrained || distance >= 100 {
            nextProfile = .compass
        } else {
            nextProfile = .ar
        }

        guard nextProfile != currentProfile else { return }
        currentProfile = nextProfile
        applyManagerSettings(for: nextProfile)

#if DEBUG
        let dStr = distance.isFinite ? "\(Int(distance))" : "inf"
        print("[Energy][Guidance] profile=\(String(describing: nextProfile)) distance=\(dStr)m")
#endif
    }

    private func applyManagerSettings(for profile: LocationProfile) {
        let constrained = isPowerConstrained

        switch profile {
        case .map:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = constrained ? 10 : 5
            startHeadingUpdatesIfNeeded(filter: constrained ? 15 : 8)
        case .compass:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = constrained ? 5 : 2
            startHeadingUpdatesIfNeeded(filter: constrained ? 12 : 5)
        case .ar:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = constrained ? 2 : 1
            startHeadingUpdatesIfNeeded(filter: constrained ? 6 : 2)
        }
    }

    private func locationFilteringProfile(for profile: LocationProfile) -> LocationFilteringProfile {
        switch profile {
        case .map:
            return .balanced
        case .compass:
            return .navigation
        case .ar:
            return .precisionNavigation
        }
    }

    private func startHeadingUpdatesIfNeeded(filter: CLLocationDirection) {
        guard CLLocationManager.headingAvailable() else { return }
        manager.headingFilter = filter
        guard !isHeadingActive else { return }
        manager.startUpdatingHeading()
        isHeadingActive = true
    }

    private func stopHeadingUpdatesIfNeeded() {
        guard isHeadingActive else { return }
        manager.stopUpdatingHeading()
        isHeadingActive = false
    }

    private func resolvedHeadingValue(from heading: CLHeading) -> Double {
        let value = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        return value.isFinite ? value : 0
    }

    private func bootstrapInitialLocation() -> CLLocation? {
        if let location = manager.location {
            let age = abs(location.timestamp.timeIntervalSinceNow)
            if age <= 120,
               location.horizontalAccuracy > 0,
               location.horizontalAccuracy <= 100,
               location.coordinate.latitude.isFinite,
               location.coordinate.longitude.isFinite {
                return location
            }
        }

        guard let lastKnown = LastKnownLocationStore.shared.load(maxAge: fallbackLocationMaxAge) else {
            return nil
        }

        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: lastKnown.coordinate.latitude,
                longitude: lastKnown.coordinate.longitude
            ),
            altitude: 0,
            horizontalAccuracy: lastKnown.accuracy,
            verticalAccuracy: -1,
            timestamp: lastKnown.date
        )
    }
}

extension GuidanceViewModel: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let filteredLocation = precisionReducer.process(
            locations,
            profile: locationFilteringProfile(for: currentProfile)
        ) else {
            return
        }
        latestLocation = filteredLocation
        updateLocationProfile(with: filteredLocation)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        if newHeading.headingAccuracy >= 0 {
            latestHeading = newHeading
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
#if DEBUG
        print("[GuidanceVM] didFailWithError: \(error.localizedDescription)")
#endif
    }
}
