import SwiftUI
import AppIntents
import CoreLocation
import Combine
import UIKit

/// Gestionnaire centralisé de cycle de vie pour suspendre/reprendre
/// les tâches non critiques en background/foreground.
@MainActor
final class AppLifecycleManager {
    static let shared = AppLifecycleManager()

    private var backgroundObserver: AnyCancellable?
    private var foregroundObserver: AnyCancellable?

    private var backgroundHandlers: [UUID: () -> Void] = [:]
    private var foregroundHandlers: [UUID: () -> Void] = [:]

    private init() {
        backgroundObserver = NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.backgroundHandlers.values.forEach { $0() }
            }

        foregroundObserver = NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.foregroundHandlers.values.forEach { $0() }
            }
    }

    /// Enregistre des callbacks lifecycle.
    /// - Returns: Token à conserver pour désenregistrer proprement.
    func register(onBackground: (() -> Void)? = nil, onForeground: (() -> Void)? = nil) -> UUID {
        let token = UUID()
        if let onBackground {
            backgroundHandlers[token] = onBackground
        }
        if let onForeground {
            foregroundHandlers[token] = onForeground
        }
        return token
    }

    func unregister(_ token: UUID) {
        backgroundHandlers[token] = nil
        foregroundHandlers[token] = nil
    }
}
