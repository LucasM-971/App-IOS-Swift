// LocationService.swift
// Wraps CoreLocation – emits coordinates reactively via Combine

import Foundation
import CoreLocation
import Combine
import UIKit

final class LocationService: NSObject, LocationServiceProtocol {

    private static let temporaryFullAccuracyPurposeKey = "ParkingSavePrecision"

    private let manager = CLLocationManager()
    private let lastKnownStore: LastKnownLocationStore
    private let precisionReducer = LocationPrecisionReducer()
    private let authSubject = CurrentValueSubject<LocationAuthStatus, Never>(.notDetermined)
    private let accuracyAuthorizationSubject =
        CurrentValueSubject<LocationAccuracyAuthorization, Never>(.unknown)
    private let coordSubject = PassthroughSubject<Coordinate, Never>()
    private let locationSampleSubject = PassthroughSubject<LocationSample, Never>()
    private let headingSubject = CurrentValueSubject<CLHeading?, Never>(nil)
    private var lifecycleCancellables = Set<AnyCancellable>()
    private var currentMode: LocationMode = .off
    private var previousForegroundMode: LocationMode = .balanced
    private var lastPublishedCoordinate: CLLocation?
    private var lastPublishedAt: Date?
    private var lastPersistedCoordinate: CLLocation?
    private var lastPersistedAccuracy: Double?
    private var lastPersistedAt: Date?
    private var lastRawLocation: CLLocation?
    private var backgroundParkingAssistanceActive = false
    private var hasRequestedTemporaryFullAccuracy = false

    var authorizationStatus: AnyPublisher<LocationAuthStatus, Never> {
        authSubject.eraseToAnyPublisher()
    }
    var accuracyAuthorization: AnyPublisher<LocationAccuracyAuthorization, Never> {
        accuracyAuthorizationSubject.eraseToAnyPublisher()
    }
    var currentCoordinate: AnyPublisher<Coordinate, Never> {
        coordSubject.eraseToAnyPublisher()
    }
    var currentLocationSample: AnyPublisher<LocationSample, Never> {
        locationSampleSubject.eraseToAnyPublisher()
    }
    var currentHeading: AnyPublisher<CLHeading?, Never> {
        headingSubject.eraseToAnyPublisher()
    }

    init(lastKnownStore: LastKnownLocationStore = .shared) {
        self.lastKnownStore = lastKnownStore
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter  = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = true
        manager.headingFilter = 1
        // Only enable background location updates when the app is actually backgroundable for
        // location and we have the proper authorization. Forcing this to true triggers an
        // internal CoreLocation assertion ("stayUp") on some iOS versions.
        manager.allowsBackgroundLocationUpdates = false
        updateBackgroundLocationBehavior(for: .off)
        bindApplicationLifecycle()
        publishCurrentAuthorizationState()
    }

    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            requestTemporaryFullAccuracyIfNeeded()
            publishCurrentAuthorizationState()
        }
    }

    func requestAlwaysAuthorizationIfNeeded() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            publishCurrentAuthorizationState()
        }
    }

    func requestTemporaryFullAccuracyIfNeeded() {
        guard isAuthorizedForLocationUpdates else { return }

        if #available(iOS 14.0, *) {
            guard manager.accuracyAuthorization == .reducedAccuracy,
                  !hasRequestedTemporaryFullAccuracy else {
                publishCurrentAuthorizationState()
                return
            }

            hasRequestedTemporaryFullAccuracy = true
            manager.requestTemporaryFullAccuracyAuthorization(
                withPurposeKey: Self.temporaryFullAccuracyPurposeKey
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.publishCurrentAuthorizationState()
                    if self.currentMode != .off {
                        self.manager.requestLocation()
                    }
                }
            }
        } else {
            publishCurrentAuthorizationState()
        }
    }

    func refreshAuthorizationStatus() {
        publishCurrentAuthorizationState()
    }

    func startUpdating() {
        requestTemporaryFullAccuracyIfNeeded()
        let bootstrapMode = constrainedMode(for: .balanced)
        if let last = bootstrapLocationIfAvailable(profile: bootstrapMode.filteringProfile) {
            publishImmediately(last)
        }
        setMode(.balanced)
        if isAuthorizedForLocationUpdates {
            manager.requestLocation()
        }
    }

    func stopUpdating() {
        precisionReducer.reset()
        setMode(.off)
    }

    func setPreferredLocationMode(_ mode: LocationMode) {
        setMode(mode)
    }

    func setBackgroundParkingAssistanceActive(_ active: Bool) {
        backgroundParkingAssistanceActive = active

        guard UIApplication.shared.applicationState != .active else { return }
        guard currentMode != .off else { return }

        if active {
            setMode(.balanced)
        } else {
            setMode(.significant)
        }
    }

    /// Définit le profil énergétique de localisation.
    /// Conserve les APIs publiques existantes (`startUpdating` / `stopUpdating`) pour rétrocompatibilité.
    func setMode(_ mode: LocationMode) {
        let effectiveMode = constrainedMode(for: mode)
        guard effectiveMode != currentMode else { return }

        currentMode = effectiveMode
        if mode != .off && mode != .significant {
            previousForegroundMode = mode
        }

        updateBackgroundLocationBehavior(for: effectiveMode)

        switch effectiveMode {
        case .off:
            precisionReducer.reset()
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            manager.stopMonitoringSignificantLocationChanges()
        case .significant:
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
            manager.startMonitoringSignificantLocationChanges()
        case .balanced:
            manager.stopMonitoringSignificantLocationChanges()
            manager.activityType = .other
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 8
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.headingFilter = 3
                manager.startUpdatingHeading()
            }
        case .navigation:
            manager.stopMonitoringSignificantLocationChanges()
            manager.activityType = .fitness
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 2
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.headingFilter = 2
                manager.startUpdatingHeading()
            }
        case .precisionNavigation:
            manager.stopMonitoringSignificantLocationChanges()
            manager.activityType = .fitness
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = kCLDistanceFilterNone
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.headingFilter = 1
                manager.startUpdatingHeading()
            }
        }

#if DEBUG
        print("[Energy][Location] requested=\(String(describing: mode)) effective=\(String(describing: effectiveMode))")
#endif
    }

    /// Restaure le mode foreground précédemment appliqué.
    func restorePreviousMode() {
        setMode(previousForegroundMode)
    }

    func reverseGeocode(_ coordinate: Coordinate) async throws -> String {
        let geocoder  = CLGeocoder()
        let location  = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        // Timeout de 2 secondes pour éviter de bloquer l'UI sans connexion
        let placemarks = try await withThrowingTaskGroup(of: [CLPlacemark].self) { group in
            group.addTask {
                try await geocoder.reverseGeocodeLocation(location)
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw NSError(domain: "LocationService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Reverse geocoding timed out"])
            }
            
            guard let result = try await group.next() else {
                throw NSError(domain: "LocationService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Reverse geocoding failed"])
            }
            group.cancelAll()
            return result
        }
        
        guard let p = placemarks.first else { return streetViewFallbackAddress(for: coordinate) }
        let components = [p.thoroughfare, p.subThoroughfare, p.locality]
            .compactMap { $0 }
        return components.isEmpty ? streetViewFallbackAddress(for: coordinate) : components.joined(separator: ", ")
    }

    private func streetViewFallbackAddress(for coordinate: Coordinate) -> String {
        let lat = String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude)
        let lon = String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), coordinate.longitude)
        return "Street View: \(lat), \(lon)"
    }
}

extension LocationService: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = precisionReducer.process(locations, profile: currentMode.filteringProfile) else { return }
        let inferredSpeed = resolvedSpeed(for: loc)
        let coordinate = Coordinate(latitude: loc.coordinate.latitude,
                                    longitude: loc.coordinate.longitude)
        let sample = LocationSample(
            coordinate: coordinate,
            accuracy: loc.horizontalAccuracy,
            date: loc.timestamp,
            speed: inferredSpeed,
            course: loc.course >= 0 ? loc.course : nil
        )
        lastRawLocation = loc

        let now = Date()
        let publishPolicy = publishPolicy(for: currentMode)
        let enoughTime = lastPublishedAt.map { now.timeIntervalSince($0) >= publishPolicy.minimumInterval } ?? true
        let enoughDistance = lastPublishedCoordinate.map { $0.distance(from: loc) >= publishPolicy.minimumDistance } ?? true

        if enoughTime || enoughDistance {
            coordSubject.send(coordinate)
            lastPublishedCoordinate = loc
            lastPublishedAt = now
        }

        locationSampleSubject.send(sample)

        if loc.horizontalAccuracy <= 15, shouldPersistReliableLocation(loc, now: now) {
            lastKnownStore.save(coordinate, accuracy: loc.horizontalAccuracy)
            lastPersistedCoordinate = loc
            lastPersistedAccuracy = loc.horizontalAccuracy
            lastPersistedAt = now
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // headingAccuracy == -1 → cap invalide/non calibré ; >= 0 inclut la précision parfaite (0°)
        if newHeading.headingAccuracy >= 0 {
            headingSubject.send(newHeading)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        publishCurrentAuthorizationState()
        requestTemporaryFullAccuracyIfNeeded()
        updateBackgroundLocationBehavior(for: currentMode)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
#if DEBUG
        print("[Location] didFailWithError: \(error.localizedDescription)")
#endif
    }
}

private extension LocationService {
    typealias PublishPolicy = (minimumInterval: TimeInterval, minimumDistance: CLLocationDistance)

    var hasLocationBackgroundModeEnabled: Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            return false
        }
        return modes.contains("location")
    }

    var canRunContinuousLocationInBackground: Bool {
        hasLocationBackgroundModeEnabled && manager.authorizationStatus == .authorizedAlways
    }

    func updateBackgroundLocationBehavior(for mode: LocationMode) {
        // Continuous updates (.startUpdatingLocation) are the ones that can trigger the internal
        // CoreLocation "stayUp" constraint if the client isn't backgroundable.
        let usesContinuousUpdates: Bool
        switch mode {
        case .balanced, .navigation, .precisionNavigation:
            usesContinuousUpdates = true
        case .off, .significant:
            usesContinuousUpdates = false
        }

        manager.allowsBackgroundLocationUpdates = usesContinuousUpdates && canRunContinuousLocationInBackground
    }

    var isAuthorizedForLocationUpdates: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    func publishCurrentAuthorizationState() {
        publishAuthorizationStatus(manager.authorizationStatus)
        publishAccuracyAuthorization(manager.accuracyAuthorization)
    }

    func publishAuthorizationStatus(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            authSubject.send(.notDetermined)
        case .denied:
            authSubject.send(.denied)
        case .restricted:
            authSubject.send(.restricted)
        case .authorizedWhenInUse:
            authSubject.send(.authorizedWhenInUse)
        case .authorizedAlways:
            authSubject.send(.authorizedAlways)
        @unknown default:
            authSubject.send(.notDetermined)
        }
    }

    func publishAccuracyAuthorization(_ status: CLAccuracyAuthorization) {
        switch status {
        case .fullAccuracy:
            accuracyAuthorizationSubject.send(.fullAccuracy)
        case .reducedAccuracy:
            accuracyAuthorizationSubject.send(.reducedAccuracy)
        @unknown default:
            accuracyAuthorizationSubject.send(.unknown)
        }
    }

    func constrainedMode(for requested: LocationMode) -> LocationMode {
        let processInfo = ProcessInfo.processInfo
        let isConstrained = processInfo.isLowPowerModeEnabled || processInfo.thermalState == .serious || processInfo.thermalState == .critical
        guard isConstrained else { return requested }

        switch requested {
        case .precisionNavigation:
            return .navigation
        case .navigation:
            return .balanced
        case .balanced:
            return .significant
        case .significant, .off:
            return requested
        }
    }

    func publishPolicy(for mode: LocationMode) -> PublishPolicy {
        switch mode {
        case .precisionNavigation:
            return (0.15, 1)
        case .navigation:
            return (0.35, 2)
        case .balanced:
            return (1.0, 6)
        case .significant:
            return (8.0, 150)
        case .off:
            return (1.0, 5)
        }
    }

    /// Passe automatiquement en mode économique en arrière-plan.
    func bindApplicationLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.setMode(self.backgroundParkingAssistanceActive ? .balanced : .significant)
            }
            .store(in: &lifecycleCancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.restorePreviousMode()
            }
            .store(in: &lifecycleCancellables)
    }

    func shouldPersistReliableLocation(_ location: CLLocation, now: Date) -> Bool {
        let improvedAccuracy = lastPersistedAccuracy.map { location.horizontalAccuracy + 5 < $0 } ?? true
        let movedEnough = lastPersistedCoordinate.map { $0.distance(from: location) >= 30 } ?? true
        let staleEnough = lastPersistedAt.map { now.timeIntervalSince($0) >= 60 } ?? true
        return improvedAccuracy || movedEnough || staleEnough
    }

    func resolvedSpeed(for location: CLLocation) -> Double {
        if location.speed >= 0 {
            return location.speed
        }

        guard let previous = lastRawLocation else { return 0 }
        let elapsed = location.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return 0 }
        return max(0, location.distance(from: previous) / elapsed)
    }

    func bootstrapLocationIfAvailable(profile: LocationFilteringProfile) -> CLLocation? {
        guard let location = manager.location else { return nil }

        let age = abs(location.timestamp.timeIntervalSinceNow)
        guard age <= 120 else { return nil }
        guard location.horizontalAccuracy > 0, location.horizontalAccuracy <= profile.hardMaximumAccuracy else {
            return nil
        }

        return location
    }

    func publishImmediately(_ location: CLLocation) {
        let coordinate = Coordinate(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        let sample = LocationSample(
            coordinate: coordinate,
            accuracy: location.horizontalAccuracy,
            date: location.timestamp,
            speed: max(0, location.speed),
            course: location.course >= 0 ? location.course : nil
        )

        lastRawLocation = location
        coordSubject.send(coordinate)
        locationSampleSubject.send(sample)
        lastPublishedCoordinate = location
        lastPublishedAt = Date()
    }
}
