import Foundation

struct LocalParkingHistoryRecord: Codable, Equatable {
    var id: String
    var userId: String
    var latitude: Double
    var longitude: Double
    var addressName: String?
    var eventType: String
    var createdAt: Date
    var syncedAt: Date?
    var deletedAt: Date?
    var metadata: [String: String]?

    init(from event: ParkingHistoryEvent) {
        id = event.id.uuidString
        userId = event.userId.uuidString
        latitude = event.latitude
        longitude = event.longitude
        addressName = event.addressName
        eventType = event.eventType.rawValue
        createdAt = event.createdAt
        syncedAt = event.syncedAt
        deletedAt = event.deletedAt
        metadata = event.metadata
    }

    func toDomain() -> ParkingHistoryEvent {
        ParkingHistoryEvent(
            id: UUID(uuidString: id) ?? UUID(),
            userId: UUID(uuidString: userId) ?? UUID(),
            latitude: latitude,
            longitude: longitude,
            addressName: addressName,
            eventType: ParkingHistoryEventType(rawValue: eventType) ?? .manualCheckpoint,
            createdAt: createdAt,
            syncedAt: syncedAt,
            deletedAt: deletedAt,
            metadata: metadata
        )
    }
}
