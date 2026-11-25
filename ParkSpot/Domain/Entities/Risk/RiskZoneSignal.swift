import Foundation
import CoreLocation
import Combine

struct RiskZoneSignal: Identifiable, Codable, Equatable {
    let id: UUID
    let coordinate: Coordinate
    let category: RiskZoneCategory
    let source: RiskZoneSource
    let createdAt: Date
    let notes: String?

    init(
        id: UUID = UUID(),
        coordinate: Coordinate,
        category: RiskZoneCategory,
        source: RiskZoneSource,
        createdAt: Date = .now,
        notes: String? = nil
    ) {
        self.id = id
        self.coordinate = coordinate
        self.category = category
        self.source = source
        self.createdAt = createdAt
        self.notes = notes
    }
}
