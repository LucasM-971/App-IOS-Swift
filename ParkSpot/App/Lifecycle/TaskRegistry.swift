import SwiftUI
import AppIntents
import CoreLocation
import Combine
import UIKit

/// Registre central des `Task` asynchrones pour permettre une annulation globale.
@MainActor
final class TaskRegistry {
    static let shared = TaskRegistry()

    private var tasks: [UUID: (task: Task<Void, Never>, priority: BackgroundWorkPriority)] = [:]

    @discardableResult
    func register(_ task: Task<Void, Never>, priority: BackgroundWorkPriority = .normal) -> UUID {
        let token = UUID()
        tasks[token] = (task, priority)
        cleanupFinished()
        return token
    }

    func unregister(_ token: UUID) {
        tasks[token] = nil
    }

    func cancelAll(except priority: BackgroundWorkPriority? = nil) {
        for (token, entry) in tasks {
            if entry.priority != priority {
                entry.task.cancel()
#if DEBUG
                print("[Perf] CPU task cancelled: registry_\(token.uuidString.prefix(6))")
#endif
            }
        }
        tasks = tasks.filter { $0.value.priority == priority }
    }

    private func cleanupFinished() {
        tasks = tasks.filter { !$0.value.task.isCancelled }
    }
}
