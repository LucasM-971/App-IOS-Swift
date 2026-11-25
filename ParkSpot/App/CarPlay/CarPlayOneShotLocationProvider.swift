import UIKit
import UserNotifications
import CarPlay
import CoreLocation

@MainActor
final class CarPlayOneShotLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Coordinate?, Never>?
    private var bestLocation: CLLocation?

    func currentCoordinate() async -> Coordinate? {
        if let location = manager.location,
           location.horizontalAccuracy > 0,
           location.horizontalAccuracy <= 30 {
            return Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        }

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        bestLocation = nil

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, let continuation = self.continuation else { return }
                self.manager.stopUpdatingLocation()
                self.continuation = nil
                if let best = self.bestLocation {
                    continuation.resume(returning: Coordinate(latitude: best.coordinate.latitude, longitude: best.coordinate.longitude))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations where location.horizontalAccuracy > 0 {
            if bestLocation == nil || location.horizontalAccuracy < (bestLocation?.horizontalAccuracy ?? .greatestFiniteMagnitude) {
                bestLocation = location
            }
        }

        guard let continuation, let bestLocation, bestLocation.horizontalAccuracy <= 15 else { return }
        manager.stopUpdatingLocation()
        continuation.resume(returning: Coordinate(latitude: bestLocation.coordinate.latitude, longitude: bestLocation.coordinate.longitude))
        self.continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
