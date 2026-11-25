import Foundation

struct HistoryEventUpsertDTO: Codable {
    let id: String
    let userId: String
    let latitude: Double
    let longitude: Double
    let addressName: String?
    let eventType: String
    let createdAt: Date
    let syncedAt: Date?
    let deletedAt: Date?
    let metadata: [String: String]?

    init(from event: ParkingHistoryEvent) {
        self.id = event.id.uuidString
        self.userId = event.userId.uuidString
        self.latitude = event.latitude
        self.longitude = event.longitude
        self.addressName = event.addressName
        self.eventType = event.eventType.rawValue
        self.createdAt = event.createdAt
        self.syncedAt = event.syncedAt
        self.deletedAt = event.deletedAt
        self.metadata = event.metadata
    }
}
