import Foundation

nonisolated enum ParkingSessionSyncOperationType: String, Codable {
    case upsert
}

nonisolated struct ParkingSessionSyncOperation: Identifiable, Codable, Equatable {
    let id: UUID
    let userId: String
    let sessionId: String
    let operationType: ParkingSessionSyncOperationType
    let enqueuedAt: Date
    var retryCount: Int
    var lastAttemptAt: Date?

    init(
        id: UUID = UUID(),
        userId: String,
        sessionId: String,
        operationType: ParkingSessionSyncOperationType = .upsert,
        enqueuedAt: Date = .now,
        retryCount: Int = 0,
        lastAttemptAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.sessionId = sessionId
        self.operationType = operationType
        self.enqueuedAt = enqueuedAt
        self.retryCount = retryCount
        self.lastAttemptAt = lastAttemptAt
    }
}
