import Foundation
import Network

final class HistoryRetentionManager {
    private let localStorage: LocalParkingHistoryStorageService

    init(localStorage: LocalParkingHistoryStorageService) {
        self.localStorage = localStorage
    }

    func enforce(userId: UUID, plan: HistoryRetentionPlan, now: Date = .now) throws -> HistoryRetentionResult {
        try localStorage.applyRetention(
            userId: userId,
            retentionDays: plan.retentionDays,
            plan: plan,
            now: now
        )
    }
}
