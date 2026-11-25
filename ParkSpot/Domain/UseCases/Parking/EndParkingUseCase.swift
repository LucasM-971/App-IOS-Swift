import Foundation
import Combine

final class EndParkingUseCase {
    private let parkingRepo: ParkingRepositoryProtocol
    private let notificationService: NotificationServiceProtocol
    private let widgetDataStore: ParkingWidgetDataStore
    private let photoStorage: PhotoStorageProtocol

    init(
        parkingRepo: ParkingRepositoryProtocol,
        notificationService: NotificationServiceProtocol,
        widgetDataStore: ParkingWidgetDataStore = .shared,
        photoStorage: PhotoStorageProtocol
    ) {
        self.parkingRepo = parkingRepo
        self.notificationService = notificationService
        self.widgetDataStore = widgetDataStore
        self.photoStorage = photoStorage
    }

    func execute(sessionId: UUID) async throws -> ParkingSession {
        let ended = try await parkingRepo.endSession(id: sessionId)

        // Tâches secondaires en arrière-plan
        Task { [notificationService, widgetDataStore, photoStorage, ended] in
            notificationService.cancelAlert(for: sessionId)
            
            if let photoPath = ended.photoPath {
                try? await photoStorage.delete(path: photoPath)
            }

            // Clear shared active parking for widget
            widgetDataStore.clear()

            // Terminer le Live Activity (iOS 16.2+)
            if #available(iOS 16.2, *) {
                await LiveActivityService.shared.end(sessionId: sessionId)
            }
        }

        return ended
    }
}
