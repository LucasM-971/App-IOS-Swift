import Foundation

enum HistorySyncOperationType: String, Codable {
    case upsert
    case delete
}

struct HistorySyncOperation: Identifiable, Codable, Equatable {
    let id: UUID
    let userId: String
    let recordId: String
    let operationType: HistorySyncOperationType
    let enqueuedAt: Date
    var retryCount: Int
    var lastAttemptAt: Date?

    init(
        id: UUID = UUID(),
        userId: String,
        recordId: String,
        operationType: HistorySyncOperationType,
        enqueuedAt: Date = .now,
        retryCount: Int = 0,
        lastAttemptAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.recordId = recordId
        self.operationType = operationType
        self.enqueuedAt = enqueuedAt
        self.retryCount = retryCount
        self.lastAttemptAt = lastAttemptAt
    }
}
