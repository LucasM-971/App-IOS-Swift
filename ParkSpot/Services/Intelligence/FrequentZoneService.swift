import Foundation
import CoreLocation
import Combine

final class FrequentZoneService {
    private let minimumWeeklyVisitsForFrequentZone = 3
    private let frequentZoneWindow: TimeInterval = 7 * 24 * 60 * 60
    private let syncDebounceNanoseconds: UInt64 = 650_000_000

    private struct DeletedZoneMarker: Equatable {
        let center: Coordinate
        let deletedAt: Date
    }

    private let remoteDataSource: RemoteFrequentZoneDataSource?
    private var cachedZonesByUser: [UUID: [FrequentZone]] = [:]
    private var deletedMarkersByUser: [UUID: [DeletedZoneMarker]] = [:]
    private var syncTasks: [UUID: Task<Void, Never>] = [:]

    init(remoteDataSource: RemoteFrequentZoneDataSource? = nil) {
        self.remoteDataSource = remoteDataSource
    }

    deinit {
        syncTasks.values.forEach { $0.cancel() }
    }

    func zones(for userId: UUID) -> [FrequentZone] {
        (cachedZonesByUser[userId] ?? []).sorted { $0.lastVisitedAt > $1.lastVisitedAt }
    }

    func refreshZonesFromDatabase(for userId: UUID) async -> [FrequentZone] {
        guard let remoteDataSource else { return zones(for: userId) }

        do {
            let remoteZones = try await remoteDataSource.fetchZones(userId: userId, includeDeleted: true)
            return updateCache(from: remoteZones, for: userId)
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                print("[FrequentZoneService] Remote fetch failed: \(error.localizedDescription)")
            }
            return zones(for: userId)
        }
    }

    @discardableResult
    func syncZonesToDatabase(_ nextZones: [FrequentZone], userId: UUID) async -> [FrequentZone] {
        setCachedZones(nextZones, for: userId)
        guard let remoteDataSource else { return zones(for: userId) }

        do {
            let syncedZones = try await remoteDataSource.syncZones(nextZones, userId: userId)
            return updateCache(from: syncedZones, for: userId)
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                print("[FrequentZoneService] Remote sync failed: \(error.localizedDescription)")
            }
            return zones(for: userId)
        }
    }

    func updateFromHistory(_ sessions: [ParkingSession], userId: UUID) async -> [FrequentZone] {
        let previousZones = zones(for: userId)
        let deletedMarkers = deletedZoneMarkers(for: userId)
        let eligibleSessions = sessions
            .sorted(by: { $0.startTime < $1.startTime })
            .filter { session in
                !deletedMarkers.contains(where: {
                    haversine($0.center, session.coordinate) < 100 && session.startTime <= $0.deletedAt
                })
            }

        var clusters: [FrequentZone] = []
        for s in eligibleSessions {
            if let idx = clusters.firstIndex(where: { haversine($0.center, s.coordinate) < 100 }) {
                var z = clusters[idx]
                z.visits += 1
                z.lastVisitedAt = max(z.lastVisitedAt, s.startTime)
                z.center = Coordinate(
                    latitude: (z.center.latitude * Double(max(1, z.visits - 1)) + s.coordinate.latitude) / Double(z.visits),
                    longitude: (z.center.longitude * Double(max(1, z.visits - 1)) + s.coordinate.longitude) / Double(z.visits)
                )
                clusters[idx] = z
            } else {
                clusters.append(FrequentZone(userId: userId, center: s.coordinate, visits: 1, lastVisitedAt: s.startTime))
            }
        }

        let cutoffDate = Date().addingTimeInterval(-frequentZoneWindow)
        var merged = deduplicate(clusters).filter {
            weeklyVisitCount(for: $0.center, in: eligibleSessions, since: cutoffDate) >= minimumWeeklyVisitsForFrequentZone
        }

        for index in merged.indices {
            let zoneSessions = eligibleSessions.filter { haversine($0.coordinate, merged[index].center) < 100 }
            let previous = previousZones.first(where: { haversine($0.center, merged[index].center) < 75 })
            let computedZone = merged[index]
            let previousName = previous?.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var name = computedZone.name
            if let previous,
                let previousName,
                !previousName.isEmpty,
                previousName != "Zone fréquente",
                previousName != "Frequent zone"
            {
                name = previous.name
            }
            let parkingType = dominantParkingType(
                for: zoneSessions,
                fallback: previous?.parkingType ?? .unknown
            )

            merged[index] = FrequentZone(
                id: previous?.id ?? computedZone.id,
                userId: userId,
                name: name,
                details: previous?.details,
                landmarkLevel: previous?.landmarkLevel,
                center: computedZone.center,
                visits: computedZone.visits,
                lastVisitedAt: computedZone.lastVisitedAt,
                preferredDurationMinutes: previous?.preferredDurationMinutes,
                parkingType: parkingType
            )
        }

        syncTasks[userId]?.cancel()
        syncTasks[userId] = nil
        return await syncZonesToDatabase(merged, userId: userId)
    }

    func suggestedZoneName(for coordinate: Coordinate, userId: UUID) -> String? {
        zones(for: userId)
            .filter { $0.visits >= minimumWeeklyVisitsForFrequentZone && haversine($0.center, coordinate) <= 100 }
            .sorted(by: { $0.visits > $1.visits })
            .first?
            .name
    }

    func bestZone(for coordinate: Coordinate, userId: UUID) -> FrequentZone? {
        zones(for: userId)
            .filter { $0.visits >= minimumWeeklyVisitsForFrequentZone && haversine($0.center, coordinate) <= 150 }
            .sorted {
                if $0.visits == $1.visits {
                    return haversine($0.center, coordinate) < haversine($1.center, coordinate)
                }
                return $0.visits > $1.visits
            }
            .first
    }

    func nearbyZones(for coordinate: Coordinate, userId: UUID, limit: Int = 3) -> [FrequentZone] {
        zones(for: userId)
            .filter { $0.visits >= minimumWeeklyVisitsForFrequentZone && haversine($0.center, coordinate) <= 250 }
            .sorted {
                let d0 = haversine($0.center, coordinate)
                let d1 = haversine($1.center, coordinate)
                if abs(d0 - d1) < 10 {
                    return $0.visits > $1.visits
                }
                return d0 < d1
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    func renameZone(zoneId: UUID, name: String, userId: UUID) async {
        var all = zones(for: userId)
        guard let idx = all.firstIndex(where: { $0.id == zoneId }) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { all[idx].name = cleaned }
        scheduleSync(all, for: userId)
    }

    func setPreferredDuration(zoneId: UUID, minutes: Int?, userId: UUID) async {
        var all = zones(for: userId)
        guard let idx = all.firstIndex(where: { $0.id == zoneId }) else { return }
        if let minutes {
            all[idx].preferredDurationMinutes = Swift.min(Swift.max(minutes, 5), 12 * 60)
        } else {
            all[idx].preferredDurationMinutes = nil
        }
        scheduleSync(all, for: userId)
    }

    func setZoneDetails(zoneId: UUID, details: String?, userId: UUID) async {
        var all = zones(for: userId)
        guard let idx = all.firstIndex(where: { $0.id == zoneId }) else { return }

        let cleaned = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        all[idx].details = (cleaned?.isEmpty == false) ? cleaned : nil
        scheduleSync(all, for: userId)
    }

    func setZoneLandmarkLevel(zoneId: UUID, level: String?, userId: UUID) async {
        var all = zones(for: userId)
        guard let idx = all.firstIndex(where: { $0.id == zoneId }) else { return }

        let cleaned = level?.trimmingCharacters(in: .whitespacesAndNewlines)
        all[idx].landmarkLevel = (cleaned?.isEmpty == false) ? cleaned : nil
        scheduleSync(all, for: userId)
    }

    func deleteZone(zoneId: UUID, userId: UUID) async {
        let currentZones = zones(for: userId)
        guard let zone = currentZones.first(where: { $0.id == zoneId }) else { return }

        var markers = deletedZoneMarkers(for: userId)
        markers.append(DeletedZoneMarker(center: zone.center, deletedAt: .now))
        setDeletedZoneMarkers(markers, for: userId)

        let remainingZones = currentZones.filter { $0.id != zoneId }
        setCachedZones(remainingZones, for: userId)
        syncTasks[userId]?.cancel()
        syncTasks[userId] = nil

        guard let remoteDataSource else { return }
        do {
            try await remoteDataSource.deleteZone(zoneId: zoneId, userId: userId)
            let refreshedZones = try await remoteDataSource.fetchZones(userId: userId, includeDeleted: true)
            _ = updateCache(from: refreshedZones, for: userId)
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                print("[FrequentZoneService] Remote delete failed: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleSync(_ zones: [FrequentZone], for userId: UUID) {
        setCachedZones(zones, for: userId)
        guard remoteDataSource != nil else { return }

        syncTasks[userId]?.cancel()
        syncTasks[userId] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.syncDebounceNanoseconds ?? 650_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            _ = await self.syncZonesToDatabase(zones, userId: userId)
        }
    }

    private func deduplicate(_ zones: [FrequentZone]) -> [FrequentZone] {
        var result: [FrequentZone] = []
        for zone in zones.sorted(by: { $0.visits > $1.visits }) {
            if let idx = result.firstIndex(where: { haversine($0.center, zone.center) < 50 }) {
                if zone.visits > result[idx].visits { result[idx] = zone }
            } else {
                result.append(zone)
            }
        }
        return result
    }

    private func dominantParkingType(for sessions: [ParkingSession], fallback: ParkingZone) -> ParkingZone {
        var counts: [ParkingZone: Int] = [:]
        for session in sessions where session.zone != .unknown {
            counts[session.zone, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? fallback
    }

    private func deletedZoneMarkers(for userId: UUID) -> [DeletedZoneMarker] {
        deletedMarkersByUser[userId] ?? []
    }

    private func setCachedZones(_ zones: [FrequentZone], for userId: UUID) {
        cachedZonesByUser[userId] = zones.sorted { $0.lastVisitedAt > $1.lastVisitedAt }
    }

    private func setDeletedZoneMarkers(_ markers: [DeletedZoneMarker], for userId: UUID) {
        deletedMarkersByUser[userId] = Array(markers.suffix(50)).sorted { $0.deletedAt > $1.deletedAt }
    }

    private func updateCache(from remoteZones: [FrequentZoneDTO], for userId: UUID) -> [FrequentZone] {
        let activeZones = remoteZones
            .filter { $0.deletedAt == nil }
            .map { $0.toDomain() }
            .sorted { $0.lastVisitedAt > $1.lastVisitedAt }

        let deletedMarkers = remoteZones.compactMap { zone -> DeletedZoneMarker? in
            guard let deletedAt = zone.deletedAt else { return nil }
            return DeletedZoneMarker(
                center: Coordinate(latitude: zone.latitude, longitude: zone.longitude),
                deletedAt: deletedAt
            )
        }

        setCachedZones(activeZones, for: userId)
        setDeletedZoneMarkers(deletedMarkers, for: userId)
        return activeZones
    }

    private func weeklyVisitCount(for center: Coordinate, in sessions: [ParkingSession], since cutoffDate: Date) -> Int {
        sessions.reduce(into: 0) { result, session in
            guard session.startTime >= cutoffDate else { return }
            guard haversine(center, session.coordinate) < 100 else { return }
            result += 1
        }
    }

    private func haversine(_ a: Coordinate, _ b: Coordinate) -> Double {
        let R = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(sqrt(h), sqrt(1 - h))
    }
}
