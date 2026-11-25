import Foundation
import CoreLocation
import Combine

struct FrequentZone: Identifiable, Codable, Equatable {
    let id: UUID
    let userId: UUID
    var name: String
    var details: String?
    var landmarkLevel: String?
    var center: Coordinate
    var visits: Int
    var lastVisitedAt: Date
    var preferredDurationMinutes: Int?
    var parkingType: ParkingZone

    init(
        id: UUID = UUID(),
        userId: UUID,
        name: String = "Frequent zone",
        details: String? = nil,
        landmarkLevel: String? = nil,
        center: Coordinate,
        visits: Int = 1,
        lastVisitedAt: Date = .now,
        preferredDurationMinutes: Int? = nil,
        parkingType: ParkingZone = .unknown
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.details = details
        self.landmarkLevel = landmarkLevel
        self.center = center
        self.visits = visits
        self.lastVisitedAt = lastVisitedAt
        self.preferredDurationMinutes = preferredDurationMinutes
        self.parkingType = parkingType
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case userId
        case name
        case details
        case landmarkLevel
        case center
        case visits
        case lastVisitedAt
        case preferredDurationMinutes
        case parkingType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userId = try container.decode(UUID.self, forKey: .userId)
        name = try container.decode(String.self, forKey: .name)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        landmarkLevel = try container.decodeIfPresent(String.self, forKey: .landmarkLevel)
        center = try container.decode(Coordinate.self, forKey: .center)
        visits = try container.decode(Int.self, forKey: .visits)
        lastVisitedAt = try container.decode(Date.self, forKey: .lastVisitedAt)
        preferredDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .preferredDurationMinutes)
        parkingType = try container.decodeIfPresent(ParkingZone.self, forKey: .parkingType) ?? .unknown
    }
}
