import Foundation

enum ParkingHistoryEventType: String, Codable, CaseIterable {
    case parkingSaved = "parking_saved"
    case parkingEnded = "parking_ended"
    case manualCheckpoint = "manual_checkpoint"
    case imported = "imported"
}

struct ParkingHistoryEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let userId: UUID
    let latitude: Double
    let longitude: Double
    var addressName: String?
    var eventType: ParkingHistoryEventType
    var createdAt: Date
    var syncedAt: Date?
    var deletedAt: Date?
    var metadata: [String: String]?

    var isDeleted: Bool {
        deletedAt != nil
    }

    init(
        id: UUID = UUID(),
        userId: UUID,
        latitude: Double,
        longitude: Double,
        addressName: String? = nil,
        eventType: ParkingHistoryEventType,
        createdAt: Date = .now,
        syncedAt: Date? = nil,
        deletedAt: Date? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.userId = userId
        self.latitude = latitude
        self.longitude = longitude
        self.addressName = addressName
        self.eventType = eventType
        self.createdAt = createdAt
        self.syncedAt = syncedAt
        self.deletedAt = deletedAt
        self.metadata = metadata?.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }
}
