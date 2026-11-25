import SwiftUI
import AppIntents
import CoreLocation
import Combine
import UIKit

/// Arrêt d'urgence des traitements non critiques au passage en arrière-plan.
@MainActor
final class BackgroundShutdownManager {
    static let shared = BackgroundShutdownManager()

    private var observers: Set<AnyCancellable> = []
    private weak var locationService: LocationService?

    private init() {}

    func setup(
        locationService: LocationService?
    ) {
        self.locationService = locationService

        guard observers.isEmpty else { return }

        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.handleBackgroundTransition()
            }
            .store(in: &observers)

        NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.handleForegroundTransition()
            }
            .store(in: &observers)
    }

    private func handleBackgroundTransition() {
        // 1) GPS en mode économique
        locationService?.setMode(.significant)

        // 2) Annulation de toutes les tâches non critiques
        TaskRegistry.shared.cancelAll(except: .critical)

        // 3) Invalidation de tous les timers non critiques
        TimerRegistry.shared.invalidateAll(except: .critical)

#if DEBUG
        print("[Background] Shutdown complet effectué")
#endif
    }

    private func handleForegroundTransition() {
        locationService?.restorePreviousMode()

#if DEBUG
        print("[Background] Restauration effectuée")
#endif
    }
}
