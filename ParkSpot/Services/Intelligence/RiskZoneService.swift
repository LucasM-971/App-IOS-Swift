import Foundation
import CoreLocation
import Combine

final class RiskZoneService {
    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private let communityTTL: TimeInterval = 120 * 24 * 3600
    private let maxCommunitySignals = 400

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func evaluateRisk(for coordinate: Coordinate) -> ParkingRiskAssessment {
        let openData = Self.openDataSignals
        let community = activeCommunitySignals()
        let all = openData + community

        let nearby = all.filter { haversine($0.coordinate, coordinate) <= impactRadius(for: $0.category) }
        let categories = Array(Set(nearby.map(\ .category))).sorted { $0.localizedTitle < $1.localizedTitle }
        let score = nearby.reduce(0) { $0 + scoreWeight(for: $1.category) }

        let level: ParkingRiskLevel
        switch score {
        case 0..<35:
            level = .low
        case 35..<75:
            level = .medium
        default:
            level = .high
        }

        let openDataMatches = nearby.filter { $0.source == .openData }.count
        let communityMatches = nearby.filter { $0.source == .community }.count

        return ParkingRiskAssessment(
            score: score,
            level: level,
            matchingCategories: categories,
            nearbySignals: nearby,
            openDataMatches: openDataMatches,
            communityMatches: communityMatches
        )
    }

    @discardableResult
    func addCommunitySignal(
        coordinate: Coordinate,
        category: RiskZoneCategory,
        notes: String? = nil
    ) -> RiskZoneSignal {
        var signals = activeCommunitySignals()
        let item = RiskZoneSignal(
            coordinate: coordinate,
            category: category,
            source: .community,
            createdAt: .now,
            notes: notes
        )
        signals.insert(item, at: 0)
        signals = Array(signals.prefix(maxCommunitySignals))
        saveCommunitySignals(signals)
        return item
    }

    private func activeCommunitySignals() -> [RiskZoneSignal] {
        guard let data = defaults.data(forKey: communityKey),
              let decoded = try? decoder.decode([RiskZoneSignal].self, from: data) else {
            return []
        }
        let now = Date()
        let filtered = decoded.filter { now.timeIntervalSince($0.createdAt) <= communityTTL }
        if filtered.count != decoded.count {
            saveCommunitySignals(filtered)
        }
        return filtered
    }

    private func saveCommunitySignals(_ values: [RiskZoneSignal]) {
        guard let data = try? encoder.encode(values) else { return }
        defaults.set(data, forKey: communityKey)
    }

    private func impactRadius(for category: RiskZoneCategory) -> Double {
        switch category {
        case .towing:
            return 140
        case .frequentTickets:
            return 220
        case .roadworks:
            return 260
        }
    }

    private func scoreWeight(for category: RiskZoneCategory) -> Int {
        switch category {
        case .towing:
            return 40
        case .frequentTickets:
            return 28
        case .roadworks:
            return 24
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

    private var communityKey: String { "riskZones.communitySignals.v1" }

    private static let openDataSignals: [RiskZoneSignal] = [
        RiskZoneSignal(
            coordinate: Coordinate(latitude: 48.8606, longitude: 2.3376),
            category: .frequentTickets,
            source: .openData,
            createdAt: .distantPast,
            notes: "OpenData municipal"
        ),
        RiskZoneSignal(
            coordinate: Coordinate(latitude: 48.8530, longitude: 2.3499),
            category: .towing,
            source: .openData,
            createdAt: .distantPast,
            notes: "OpenData fourrière"
        ),
        RiskZoneSignal(
            coordinate: Coordinate(latitude: 45.7640, longitude: 4.8357),
            category: .roadworks,
            source: .openData,
            createdAt: .distantPast,
            notes: "OpenData voirie"
        )
    ]
}
