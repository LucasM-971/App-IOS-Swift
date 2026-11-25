import Foundation

struct User: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var email: String
    var displayName: String
    var isPremium: Bool
    var status: String?
    var statusId: Int?
    let createdAt: Date
    var gdprConsentDate: Date?
    var dataRetentionDays: Int

    init(
        id: UUID = .init(),
        email: String,
        displayName: String,
        isPremium: Bool = false,
        status: String? = nil,
        statusId: Int? = nil,
        createdAt: Date = .now,
        gdprConsentDate: Date? = nil,
        dataRetentionDays: Int = 365
    ) {
        self.id                = id
        self.email             = email
        self.displayName       = displayName
        self.isPremium         = isPremium
        self.status            = status
        self.statusId          = statusId
        self.createdAt         = createdAt
        self.gdprConsentDate   = gdprConsentDate
        self.dataRetentionDays = dataRetentionDays
    }
}
