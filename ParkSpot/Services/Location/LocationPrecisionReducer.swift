import Foundation
import CoreLocation
import Combine
import UIKit

final class LocationPrecisionReducer {
    private let nowProvider: () -> Date
    private var recentReliableLocations: [CLLocation] = []
    private var lastAcceptedLocation: CLLocation?
    private var lastAcceptedAt: Date?

    init(nowProvider: @escaping () -> Date = Date.init) {
        self.nowProvider = nowProvider
    }

    func reset() {
        recentReliableLocations.removeAll(keepingCapacity: true)
        lastAcceptedLocation = nil
        lastAcceptedAt = nil
    }

    func process(_ locations: [CLLocation], profile: LocationFilteringProfile) -> CLLocation? {
        let now = nowProvider()
        pruneReliableHistory(for: profile, now: now)

        guard let candidate = bestCandidate(from: locations, profile: profile, now: now) else {
            return nil
        }
        guard shouldAccept(candidate, profile: profile, now: now) else {
            return nil
        }

        let filtered = smoothedLocation(for: candidate, profile: profile, now: now)
        lastAcceptedLocation = filtered
        lastAcceptedAt = now

        if candidate.horizontalAccuracy <= profile.reliableAccuracyThreshold {
            recentReliableLocations.append(candidate)
            pruneReliableHistory(for: profile, now: now)
        }

        return filtered
    }

    private func bestCandidate(
        from locations: [CLLocation],
        profile: LocationFilteringProfile,
        now: Date
    ) -> CLLocation? {
        let validLocations = locations.filter { location in
            let age = abs(now.timeIntervalSince(location.timestamp))
            return location.horizontalAccuracy > 0
                && location.horizontalAccuracy <= profile.hardMaximumAccuracy
                && age <= 12
        }

        let preferredLocations = validLocations.filter { $0.horizontalAccuracy <= profile.preferredMaximumAccuracy }
        let candidatePool = preferredLocations.isEmpty ? validLocations : preferredLocations

        return candidatePool.min { lhs, rhs in
            score(lhs, now: now) < score(rhs, now: now)
        }
    }

    private func score(_ location: CLLocation, now: Date) -> Double {
        let agePenalty = max(0, now.timeIntervalSince(location.timestamp)) * 4
        return location.horizontalAccuracy + agePenalty
    }

    private func shouldAccept(
        _ candidate: CLLocation,
        profile: LocationFilteringProfile,
        now: Date
    ) -> Bool {
        guard let lastAcceptedLocation, let lastAcceptedAt else { return true }

        if now.timeIntervalSince(lastAcceptedAt) >= profile.staleAcceptanceInterval {
            return true
        }

        let movement = candidate.distance(from: lastAcceptedLocation)
        let uncertaintyRadius = max(
            8,
            min(35, (candidate.horizontalAccuracy + lastAcceptedLocation.horizontalAccuracy) * 0.55)
        )
        let regressedAccuracy = candidate.horizontalAccuracy >
            (lastAcceptedLocation.horizontalAccuracy + profile.maximumAccuracyRegression)

        return !(regressedAccuracy && movement <= uncertaintyRadius)
    }

    private func smoothedLocation(
        for candidate: CLLocation,
        profile: LocationFilteringProfile,
        now: Date
    ) -> CLLocation {
        guard profile.enablesSmoothing else { return candidate }

        let cluster = stableCluster(around: candidate, profile: profile, now: now)
        guard cluster.count >= profile.minimumStableClusterCount else { return candidate }

        let resolvedSpeed = max(0, candidate.speed)
        guard resolvedSpeed <= profile.maximumSmoothingSpeed else { return candidate }

        let coordinate = weightedCoordinate(for: cluster, now: now)
        let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let spread = cluster.map { $0.distance(from: center) }.max() ?? 0
        let bestAccuracy = cluster.map(\.horizontalAccuracy).min() ?? candidate.horizontalAccuracy

        guard spread <= profile.clusterSpreadLimit(for: bestAccuracy) else { return candidate }

        let smoothedAccuracy = min(candidate.horizontalAccuracy, max(bestAccuracy, spread * 1.8))
        return CLLocation(
            coordinate: coordinate,
            altitude: candidate.altitude,
            horizontalAccuracy: smoothedAccuracy,
            verticalAccuracy: candidate.verticalAccuracy,
            course: candidate.course,
            speed: candidate.speed,
            timestamp: candidate.timestamp
        )
    }

    private func stableCluster(
        around candidate: CLLocation,
        profile: LocationFilteringProfile,
        now: Date
    ) -> [CLLocation] {
        var cluster = recentReliableLocations.filter { location in
            now.timeIntervalSince(location.timestamp) <= profile.smoothingWindow
        }
        cluster.append(candidate)
        return Array(cluster.suffix(profile.maxHistoryCount))
    }

    private func weightedCoordinate(for locations: [CLLocation], now: Date) -> CLLocationCoordinate2D {
        var latitude = 0.0
        var longitude = 0.0
        var totalWeight = 0.0

        for location in locations {
            let age = max(0, now.timeIntervalSince(location.timestamp))
            let accuracyWeight = 1 / pow(max(location.horizontalAccuracy, 5), 2)
            let recencyWeight = 1 / max(1, age * 1.5)
            let weight = accuracyWeight * recencyWeight

            latitude += location.coordinate.latitude * weight
            longitude += location.coordinate.longitude * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else { return locations.last?.coordinate ?? .init() }
        return CLLocationCoordinate2D(latitude: latitude / totalWeight, longitude: longitude / totalWeight)
    }

    private func pruneReliableHistory(for profile: LocationFilteringProfile, now: Date) {
        recentReliableLocations = recentReliableLocations.filter { location in
            now.timeIntervalSince(location.timestamp) <= profile.smoothingWindow
        }

        if recentReliableLocations.count > profile.maxHistoryCount {
            recentReliableLocations.removeFirst(recentReliableLocations.count - profile.maxHistoryCount)
        }
    }
}
