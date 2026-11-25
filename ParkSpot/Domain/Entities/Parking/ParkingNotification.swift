import Foundation

struct ParkingNotification: Identifiable, Codable {
    let id: UUID
    let sessionId: UUID
    let triggerDate: Date
    let message: String
    var isSent: Bool

    init(
        id: UUID = .init(),
        sessionId: UUID,
        triggerDate: Date,
        message: String,
        isSent: Bool = false
    ) {
        self.id          = id
        self.sessionId   = sessionId
        self.triggerDate = triggerDate
        self.message     = message
        self.isSent      = isSent
    }
}
