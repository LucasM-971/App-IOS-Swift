import Foundation
import CoreLocation
import Combine

final class DepartureDetectionService: NSObject {
    private let manager = CLLocationManager()
    private let departureSubject = PassthroughSubject<Void, Never>()
    private var activeRegionId: String?
    private var activeSessionId: UUID?
    private var activeRegionCenter: CLLocationCoordinate2D?
    private var activeRegionRadius: CLLocationDistance?

    var departureEvents: AnyPublisher<Void, Never> { departureSubject.eraseToAnyPublisher() }

    override init() {
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = true
    }

    func startMonitoring(sessionId: UUID, center: Coordinate, radius: Double) {
        requestAuthorizationIfNeeded()
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }

        let safeRadius = min(max(radius, 80), 500)
        let nextCenter = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)

        if activeSessionId == sessionId,
           let activeRegionCenter,
           let activeRegionRadius {
            let current = CLLocation(latitude: activeRegionCenter.latitude, longitude: activeRegionCenter.longitude)
            let next = CLLocation(latitude: nextCenter.latitude, longitude: nextCenter.longitude)
            let centerDelta = current.distance(from: next)
            if centerDelta < 15, abs(activeRegionRadius - safeRadius) < 8 {
                return
            }
        }

        stopMonitoring()

        let region = CLCircularRegion(
            center: nextCenter,
            radius: safeRadius,
            identifier: "parkspot.departure.\(sessionId.uuidString)"
        )
        region.notifyOnEntry = false
        region.notifyOnExit = true
        activeRegionId = region.identifier
        activeSessionId = sessionId
        activeRegionCenter = nextCenter
        activeRegionRadius = safeRadius
        manager.startMonitoring(for: region)
    }

    func stopMonitoring() {
        if let activeRegionId,
           let region = manager.monitoredRegions.first(where: { $0.identifier == activeRegionId }) {
            manager.stopMonitoring(for: region)
        }
        activeRegionId = nil
        activeSessionId = nil
        activeRegionCenter = nil
        activeRegionRadius = nil
    }

    private func requestAuthorizationIfNeeded() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .denied, .restricted:
            break
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        @unknown default:
            break
        }
    }
}

extension DepartureDetectionService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == activeRegionId else { return }
        departureSubject.send(())
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
#if DEBUG
        print("[DepartureDetection] didFailWithError: \(error.localizedDescription)")
#endif
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
#if DEBUG
        print("[DepartureDetection] monitoringDidFailFor: \(error.localizedDescription)")
#endif
    }
}
