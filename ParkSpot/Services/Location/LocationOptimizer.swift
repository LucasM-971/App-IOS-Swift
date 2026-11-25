import Foundation
import CoreLocation
import Combine
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)

struct ParkedLocation: Codable, Equatable {
    let coordinate: Coordinate
    let horizontalAccuracy: Double
    let timestamp: Date
}

enum LocationOptimizationResult: Equatable {
    case optimizing
    case success(ParkedLocation)
    case timedOut(ParkedLocation?)
    case requiresManualAdjustment(ParkedLocation)
    case failedAuthorization
}

protocol LocationOptimizing {
    var results: AnyPublisher<LocationOptimizationResult, Never> { get }
    var lastBestLocation: ParkedLocation? { get }
    var currentBestLocation: ParkedLocation? { get }

    func startOptimization()
    func stopOptimization()
}

/// Module 2 - Capture GPS ponctuelle, bufferisée, avec timeout strict.
final class LocationOptimizer: NSObject, LocationOptimizing {
    private static let temporaryFullAccuracyPurposeKey = "ParkingSavePrecision"

    private enum Keys {
        static let parkedLocation = "parkspot.location_optimizer.best"
    }

    private let locationManager = CLLocationManager()
    private let precisionReducer = LocationPrecisionReducer()
    private let resultsSubject = PassthroughSubject<LocationOptimizationResult, Never>()

    private var timeoutWorkItem: DispatchWorkItem?
    private var locationBuffer: [CLLocation] = []
    private let maxBufferSize = 10
    private var lifecycleCancellables = Set<AnyCancellable>()
    private var wasInterruptedByBackground = false
    private var sessionBestLocation: ParkedLocation?
    private var hasRequestedTemporaryFullAccuracy = false
    private var isOptimizationActive = false

    var results: AnyPublisher<LocationOptimizationResult, Never> {
        resultsSubject.eraseToAnyPublisher()
    }

    var currentBestLocation: ParkedLocation? {
        sessionBestLocation
    }

    var lastBestLocation: ParkedLocation? {
        if let sessionBestLocation {
            return sessionBestLocation
        }

        guard let data = UserDefaults.standard.data(forKey: Keys.parkedLocation),
              let value = try? JSONDecoder().decode(ParkedLocation.self, from: data) else {
            return nil
        }
        return value
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .fitness
        locationManager.pausesLocationUpdatesAutomatically = true
        bindLifecycleEvents()
    }

    func startOptimization() {
        wasInterruptedByBackground = false
        guard CLLocationManager.locationServicesEnabled() else {
            resultsSubject.send(.failedAuthorization)
            return
        }

        let status = locationManager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            locationManager.requestWhenInUseAuthorization()
            return
        }

        locationBuffer.removeAll(keepingCapacity: true)
        sessionBestLocation = nil
        isOptimizationActive = true
        precisionReducer.reset()
        resultsSubject.send(.optimizing)

        startHighAccuracyUpdates()

        let work = DispatchWorkItem { [weak self] in
            self?.finishWithTimeout()
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func stopOptimization() {
        isOptimizationActive = false
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        locationManager.stopUpdatingLocation()
    }

    private func append(_ location: CLLocation) {
        guard let filtered = precisionReducer.process([location], profile: .precisionNavigation) else {
            return
        }
        locationBuffer.append(filtered)
        if locationBuffer.count > maxBufferSize {
            locationBuffer.removeFirst(locationBuffer.count - maxBufferSize)
        }

        if let best = bestLocation() {
            sessionBestLocation = parkedLocation(from: best)
            resultsSubject.send(.optimizing)
        }
    }

    private func bestLocation() -> CLLocation? {
        locationBuffer.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy })
    }

    private func persist(_ location: CLLocation) -> ParkedLocation {
        let parked = parkedLocation(from: location)

        if let data = try? JSONEncoder().encode(parked) {
            UserDefaults.standard.set(data, forKey: Keys.parkedLocation)
        }

        sessionBestLocation = parked
        return parked
    }

    private func parkedLocation(from location: CLLocation) -> ParkedLocation {
        ParkedLocation(
            coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: Date()
        )
    }

    private func startHighAccuracyUpdates() {
        if #available(iOS 14.0, *),
           locationManager.accuracyAuthorization == .reducedAccuracy,
           !hasRequestedTemporaryFullAccuracy {
            hasRequestedTemporaryFullAccuracy = true
            locationManager.requestTemporaryFullAccuracyAuthorization(
                withPurposeKey: Self.temporaryFullAccuracyPurposeKey
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.isOptimizationActive else { return }
                    self.locationManager.startUpdatingLocation()
                }
            }
            return
        }

        locationManager.startUpdatingLocation()
    }

    private func finishWithTimeout() {
        defer { stopOptimization() }

        guard let best = bestLocation() else {
            resultsSubject.send(.timedOut(nil))
            return
        }

        let saved = persist(best)
        if best.horizontalAccuracy > 12 {
            resultsSubject.send(.requiresManualAdjustment(saved))
        } else {
            resultsSubject.send(.timedOut(saved))
        }
    }

    private func bindLifecycleEvents() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Mémorise si une optimisation était en cours pour pouvoir la reprendre
                self.wasInterruptedByBackground = self.timeoutWorkItem != nil
                self.stopOptimization()
            }
            .store(in: &lifecycleCancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.wasInterruptedByBackground else { return }
                self.wasInterruptedByBackground = false
                // Relance l'optimisation interrompue par le passage en arrière-plan
                self.startOptimization()
            }
            .store(in: &lifecycleCancellables)
    }
}

extension LocationOptimizer: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            startOptimization()
        } else if status == .denied || status == .restricted {
            resultsSubject.send(.failedAuthorization)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locations.forEach(append)

        guard let best = bestLocation() else { return }
        if best.horizontalAccuracy < 8 {
            stopOptimization()
            let saved = persist(best)
            resultsSubject.send(.success(saved))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishWithTimeout()
    }
}

#else

struct Coordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct ParkedLocation: Codable, Equatable {
    let coordinate: Coordinate
    let horizontalAccuracy: Double
    let timestamp: Date
}

enum LocationOptimizationResult: Equatable {
    case optimizing
    case success(ParkedLocation)
    case timedOut(ParkedLocation?)
    case requiresManualAdjustment(ParkedLocation)
    case failedAuthorization
}

protocol LocationOptimizing {
    var results: AnyPublisher<LocationOptimizationResult, Never> { get }
    var lastBestLocation: ParkedLocation? { get }
    var currentBestLocation: ParkedLocation? { get }

    func startOptimization()
    func stopOptimization()
}

final class LocationOptimizer: NSObject, LocationOptimizing {
    private let resultsSubject = PassthroughSubject<LocationOptimizationResult, Never>()

    var results: AnyPublisher<LocationOptimizationResult, Never> {
        resultsSubject.eraseToAnyPublisher()
    }

    var lastBestLocation: ParkedLocation? { nil }
    var currentBestLocation: ParkedLocation? { nil }

    func startOptimization() {
        resultsSubject.send(.failedAuthorization)
    }

    func stopOptimization() {}
}

#endif
