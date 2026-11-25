import SwiftUI
import AppIntents
import CoreLocation
import Combine
import UIKit

/// Registre central des `Timer` pour invalider en masse ce qui n'est pas critique.
@MainActor
final class TimerRegistry {
    static let shared = TimerRegistry()

    private var timers: [UUID: (timer: Timer, priority: BackgroundWorkPriority)] = [:]

    @discardableResult
    func register(_ timer: Timer, priority: BackgroundWorkPriority = .normal) -> UUID {
        let token = UUID()
        timers[token] = (timer, priority)
        cleanupInvalid()
        return token
    }

    func unregister(_ token: UUID) {
        timers[token] = nil
    }

    func invalidateAll(except priority: BackgroundWorkPriority? = nil) {
        for (_, entry) in timers {
            if entry.priority != priority {
                entry.timer.invalidate()
            }
        }
        timers = timers.filter { $0.value.priority == priority }
    }

    private func cleanupInvalid() {
        timers = timers.filter { $0.value.timer.isValid }
    }
}
