import Foundation

struct FrequentZoneDTO: Codable {
    let id: String
    let userId: String
    let name: String?
    let details: String?
    let landmarkLevel: String?
    let latitude: Double
    let longitude: Double
    let visits: Int?
    let lastVisitedAt: Date?
    let deletedAt: Date?
    let preferredDurationMinutes: Int?
    let parkingType: String?

    func toDomain() -> FrequentZone {
        let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FrequentZone(
            id: UUID(uuidString: id) ?? UUID(),
            userId: UUID(uuidString: userId) ?? UUID(),
            name: cleanedName?.isEmpty == false ? cleanedName! : "Frequent zone",
            details: details,
            landmarkLevel: landmarkLevel,
            center: Coordinate(latitude: latitude, longitude: longitude),
            visits: max(visits ?? 1, 1),
            lastVisitedAt: lastVisitedAt ?? .now,
            preferredDurationMinutes: preferredDurationMinutes,
            parkingType: parkingType.flatMap(ParkingZone.init(rawValue:)) ?? .unknown
        )
    }
}

struct FrequentZoneUpsertDTO: Encodable {
    let id: String
    let userId: String
    let name: String
    let details: String?
    let landmarkLevel: String?
    let latitude: Double
    let longitude: Double
    let visits: Int
    let lastVisitedAt: Date
    let preferredDurationMinutes: Int?
    let parkingType: String

    init(from zone: FrequentZone) {
        id = zone.id.uuidString
        userId = zone.userId.uuidString
        name = zone.name
        details = zone.details
        landmarkLevel = zone.landmarkLevel
        latitude = zone.center.latitude
        longitude = zone.center.longitude
        visits = zone.visits
        lastVisitedAt = zone.lastVisitedAt
        preferredDurationMinutes = zone.preferredDurationMinutes
        parkingType = zone.parkingType.rawValue
    }
}
