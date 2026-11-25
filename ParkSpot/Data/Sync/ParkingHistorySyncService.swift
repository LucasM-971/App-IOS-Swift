import Foundation
import Network

@MainActor
final class ParkingHistorySyncService {
    private let localStorage: LocalParkingHistoryStorageService
    private let remoteBackup: RemoteParkingHistoryBackupDataSource
    private let retentionManager: HistoryRetentionManager
    private let reachability: NetworkReachabilityMonitor
    private let defaults: UserDefaults
    private let autoBackfillOnUpgrade: Bool

    private let maxBatchSize = 80
    private let planKeyPrefix = "parkspot.history.plan.v1."
    private let pendingCloudWipePrefix = "parkspot.history.pendingCloudWipe.v1."

    private var isSyncInFlight = false
    private var retryTask: Task<Void, Never>?

    init(
        localStorage: LocalParkingHistoryStorageService,
        remoteBackup: RemoteParkingHistoryBackupDataSource,
        retentionManager: HistoryRetentionManager,
        reachability: NetworkReachabilityMonitor,
        defaults: UserDefaults = .standard,
        autoBackfillOnUpgrade: Bool = true
    ) {
        self.localStorage = localStorage
        self.remoteBackup = remoteBackup
        self.retentionManager = retentionManager
        self.reachability = reachability
        self.defaults = defaults
        self.autoBackfillOnUpgrade = autoBackfillOnUpgrade

        self.reachability.onConnectionRestored = { [weak self] in
            guard let self else { return }
            Task {
                await self.syncCachedUserIfNeeded()
            }
        }
    }

    func recordFromParkingSession(
        _ session: ParkingSession,
        eventType: ParkingHistoryEventType,
        user: User? = nil
    ) async {
        let resolvedUser = resolvedUser(for: session.userId, explicitUser: user)
        let plan = HistoryPlanResolver.resolvePlan(for: resolvedUser)

        let eventDate: Date
        switch eventType {
        case .parkingEnded:
            eventDate = session.endTime ?? .now
        default:
            eventDate = session.startTime
        }

        let event = ParkingHistoryEvent(
            userId: session.userId,
            latitude: session.coordinate.latitude,
            longitude: session.coordinate.longitude,
            addressName: session.address,
            eventType: eventType,
            createdAt: eventDate,
            syncedAt: nil,
            deletedAt: nil,
            metadata: [
                "zone": session.zone.rawValue,
                "is_approximate": session.isApproximate ? "true" : "false",
            ]
        )

        do {
            try localStorage.save(event, plan: plan)
            _ = try retentionManager.enforce(userId: session.userId, plan: plan)
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                print("[ParkingHistorySyncService] Local save failed: \(error.localizedDescription)")
            }
            return
        }

        if plan.cloudBackupEnabled {
            await syncIfNeeded(currentUser: resolvedUser)
        }
    }

    func handleUserStateChange(_ user: User?) async {
        guard let user else { return }
        let currentPlan = HistoryPlanResolver.resolvePlan(for: user)
        let previousPlan = storedPlan(for: user.id)

        if autoBackfillOnUpgrade,
           currentPlan == .premium,
           previousPlan != .premium {
            do {
                _ = try localStorage.enqueueUpsertsForRecentEvents(
                    userId: user.id,
                    withinDays: currentPlan.retentionDays
                )
            } catch {
                if AppConfig.isDebugLoggingEnabled {
                    print("[ParkingHistorySyncService] Failed to enqueue upgrade backfill: \(error.localizedDescription)")
                }
            }
        }

        do {
            _ = try retentionManager.enforce(userId: user.id, plan: currentPlan)
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                print("[ParkingHistorySyncService] Retention enforcement failed: \(error.localizedDescription)")
            }
        }

        // Free users now keep their recent history in the cloud as well.
        // Clear any legacy pending wipe flag from older builds before syncing.
        setCloudWipePending(false, for: user.id)
        storePlan(currentPlan, for: user.id)
        await syncIfNeeded(currentUser: user)
    }

    func appDidBecomeActive(currentUser: User?) async {
        await handleUserStateChange(currentUser)
        await syncIfNeeded(currentUser: currentUser)
    }

    func syncIfNeeded(currentUser: User?) async {
        guard let user = currentUser ?? HistoryPlanResolver.cachedUser(defaults: defaults) else { return }
        await processQueue(for: user)
    }

    private func processQueue(for user: User) async {
        guard reachability.isConnected else { return }
        guard !isSyncInFlight else { return }

        isSyncInFlight = true
        defer { isSyncInFlight = false }

        while true {
            let batch: [HistorySyncOperation]
            do {
                batch = try localStorage.pendingOperations(userId: user.id, limit: maxBatchSize)
            } catch {
                if AppConfig.isDebugLoggingEnabled {
                    print("[ParkingHistorySyncService] Unable to load queue: \(error.localizedDescription)")
                }
                return
            }

            guard !batch.isEmpty else {
                retryTask?.cancel()
                retryTask = nil
                return
            }

            do {
                try await processBatch(batch, userId: user.id)
            } catch {
                let attempt = (try? localStorage.registerFailure(for: batch.map(\.id))) ?? 1
                if AppConfig.isDebugLoggingEnabled {
                    print("[ParkingHistorySyncService] Batch sync failed (attempt \(attempt)): \(error.localizedDescription)")
                }
                scheduleRetry(for: user.id, attempt: attempt)
                return
            }
        }
    }

    private func processBatch(_ batch: [HistorySyncOperation], userId: UUID) async throws {
        let upsertOps = batch.filter { $0.operationType == .upsert }
        let deleteOps = batch.filter { $0.operationType == .delete }

        if !upsertOps.isEmpty {
            let uniqueRecordIDs = Array(Set(upsertOps.map(\.recordId)))
            let events = try localStorage.events(userId: userId, recordIDs: uniqueRecordIDs)
            if !events.isEmpty {
                try await remoteBackup.upsert(events: events)
                try localStorage.markSynced(recordIDs: events.map { $0.id.uuidString })
            }
            try localStorage.removeOperations(operationIDs: upsertOps.map(\.id))
        }

        if !deleteOps.isEmpty {
            let uniqueRecordIDs = Array(Set(deleteOps.map(\.recordId)))
            try await remoteBackup.deleteEvents(userId: userId, recordIDs: uniqueRecordIDs)
            try localStorage.removeOperations(operationIDs: deleteOps.map(\.id))
        }
    }

    private func processPendingCloudWipeIfNeeded(for user: User) async {
        guard isCloudWipePending(for: user.id) else { return }
        guard reachability.isConnected else { return }

        do {
            try await remoteBackup.deleteAllBackups(userId: user.id)
            setCloudWipePending(false, for: user.id)
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                print("[ParkingHistorySyncService] Cloud wipe failed: \(error.localizedDescription)")
            }
            scheduleRetry(for: user.id, attempt: 1)
        }
    }

    private func scheduleRetry(for userId: UUID, attempt: Int) {
        retryTask?.cancel()
        let safeAttempt = max(1, attempt)
        let delaySeconds = min(300, Int(pow(2.0, Double(min(safeAttempt, 6)))) * 5)

        retryTask = Task { [userId] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            let user = resolvedUser(for: userId, explicitUser: nil)
            await syncIfNeeded(currentUser: user)
        }
    }

    private func syncCachedUserIfNeeded() async {
        guard let user = HistoryPlanResolver.cachedUser(defaults: defaults) else { return }
        await syncIfNeeded(currentUser: user)
    }

    private func resolvedUser(for userId: UUID, explicitUser: User?) -> User? {
        if let explicitUser, explicitUser.id == userId {
            return explicitUser
        }
        guard
            let cached = HistoryPlanResolver.cachedUser(defaults: defaults),
            cached.id == userId
        else {
            return nil
        }
        return cached
    }

    private func storedPlan(for userId: UUID) -> HistoryRetentionPlan? {
        guard let raw = defaults.string(forKey: "\(planKeyPrefix)\(userId.uuidString)") else {
            return nil
        }
        return HistoryRetentionPlan(rawValue: raw)
    }

    private func storePlan(_ plan: HistoryRetentionPlan, for userId: UUID) {
        defaults.set(plan.rawValue, forKey: "\(planKeyPrefix)\(userId.uuidString)")
    }

    private func isCloudWipePending(for userId: UUID) -> Bool {
        defaults.bool(forKey: "\(pendingCloudWipePrefix)\(userId.uuidString)")
    }

    private func setCloudWipePending(_ isPending: Bool, for userId: UUID) {
        defaults.set(isPending, forKey: "\(pendingCloudWipePrefix)\(userId.uuidString)")
    }
}
