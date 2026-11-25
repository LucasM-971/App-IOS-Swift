import UIKit
import UserNotifications
import CarPlay
import CoreLocation

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private weak var interfaceController: CPInterfaceController?
    private static var lastDisconnectNotificationAt: Date?

    static func debugSimulateCarPlayTurnedOff() {
        Task { await handleCarPlayTurnedOff(trigger: .debug) }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        CarPlayConnectionStateStore.setConnected(true)
        interfaceController.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        self.interfaceController = nil
        CarPlayConnectionStateStore.setConnected(false)
        Task { await Self.handleCarPlayTurnedOff(trigger: .system) }
    }

    private func makeRootTemplate() -> CPListTemplate {
        let saveItem = CPListItem(
            text: "Enregistrer ma voiture".psLocalized,
            detailText: "Sauvegarder la position actuelle".psLocalized
        )
        saveItem.handler = { [weak self] _, completion in
            completion()
            Task { await self?.handleSaveParking() }
        }

        let findItem = CPListItem(
            text: "Où est ma voiture ?".psLocalized,
            detailText: "Afficher la dernière position enregistrée".psLocalized
        )
        findItem.handler = { [weak self] _, completion in
            completion()
            Task { await self?.handleFindParking() }
        }

        let section = CPListSection(items: [saveItem, findItem])
        return CPListTemplate(title: "MosiMap", sections: [section])
    }

    private func handleSaveParking() async {
        let saveContext = try? await MainActor.run { () throws -> (UUID, Bool, SaveParkingUseCase) in
            let container = DIContainer.shared
            let value = try container.keychainService.get(.userId)
            guard let userId = UUID(uuidString: value) else {
                throw NSError(domain: "ParkSpot.CarPlay", code: 2001)
            }
            let hasPremiumWidgetsAccess = HistoryPlanResolver.resolvePlan(for: userId) == .premium
            return (userId, hasPremiumWidgetsAccess, container.makeSaveParkingUseCase())
        }

        guard let saveContext else {
            presentAlert("Connectez-vous dans l'app pour utiliser CarPlay.".psLocalized)
            return
        }

        let locationProvider = await MainActor.run { CarPlayOneShotLocationProvider() }
        guard let coordinate = await locationProvider.currentCoordinate() else {
            presentAlert("Impossible d'obtenir votre position actuelle.".psLocalized)
            return
        }

        let (userId, hasPremiumWidgetsAccess, saveUseCase) = saveContext

        do {
            _ = try await saveUseCase.execute(
                userId: userId,
                coordinate: coordinate,
                note: "CarPlay",
                parkingLevel: nil,
                maxDuration: nil,
                zone: .unknown,
                allowsPremiumWidgetSurfaces: hasPremiumWidgetsAccess
            )
            presentAlert("C'est fait, votre voiture est enregistrée.".psLocalized)
        } catch {
            presentAlert("Échec de l'enregistrement. Réessayez.".psLocalized)
        }
    }

    private func handleFindParking() async {
        let fetchContext = try? await MainActor.run { () throws -> (UUID, FetchActiveSessionUseCase) in
            let container = DIContainer.shared
            let value = try container.keychainService.get(.userId)
            guard let userId = UUID(uuidString: value) else {
                throw NSError(domain: "ParkSpot.CarPlay", code: 2002)
            }
            return (userId, container.makeFetchActiveSessionUseCase())
        }

        guard let fetchContext else {
            presentAlert("Connectez-vous dans l'app pour utiliser CarPlay.".psLocalized)
            return
        }

        let (userId, fetchUseCase) = fetchContext

        do {
            let active = try await fetchUseCase.execute(userId: userId)
            guard let active else {
                presentAlert("Aucune voiture enregistrée pour le moment.".psLocalized)
                return
            }

            if let address = active.address, !address.isEmpty {
                presentAlert(String(format: "Votre voiture est enregistrée à %@.".psLocalized, address))
            } else {
                presentAlert("Votre voiture est bien enregistrée.".psLocalized)
            }
        } catch {
            presentAlert("Impossible de récupérer la position actuelle.".psLocalized)
        }
    }

    private func presentAlert(_ message: String) {
        let action = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [action])
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    private enum CarPlayTurnedOffTrigger: String {
        case system
        case debug
    }

    private static func handleCarPlayTurnedOff(trigger: CarPlayTurnedOffTrigger) async {
        print("[CarPlay] carplay turned off (\(trigger.rawValue))")

        let now = Date()
        if let lastNotificationAt = Self.lastDisconnectNotificationAt,
           now.timeIntervalSince(lastNotificationAt) < 5 {
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }

        let isAuthorized: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = await withCheckedContinuation { continuation in
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            isAuthorized = false
        @unknown default:
            isAuthorized = false
        }

        guard isAuthorized else { return }
        Self.lastDisconnectNotificationAt = now

        let content = UNMutableNotificationContent()
        content.title = "Did you park?".psLocalized
        content.body = "CarPlay disconnected. Open the app to confirm and save your parking location.".psLocalized
        content.sound = .default
        content.threadIdentifier = CarPlayDisconnectNotificationPayloadStore.threadIdentifier
        content.categoryIdentifier = CarPlayDisconnectNotificationCategory.identifier
        content.userInfo = [
            CarPlayDisconnectNotificationPayloadStore.markerUserInfoKey: true
        ]

        let identifier = "parkspot.carplay.disconnect.\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(request)
    }
}
