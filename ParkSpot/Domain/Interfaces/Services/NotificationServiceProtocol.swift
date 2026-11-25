import Foundation
import Combine
import CoreLocation

protocol NotificationServiceProtocol {
    func scheduleAlert(for session: ParkingSession) async throws
    func cancelAlert(for sessionId: UUID)
    func cancelAll()
    func syncPendingAlertsWithPreferences()
}
