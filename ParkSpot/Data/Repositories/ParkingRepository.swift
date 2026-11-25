// ParkingRepository.swift
// Remote-first for authenticated parking history, with a small local cache for the active session only.

import Foundation
import Network

// Notification quand un parking est enregistré
extension NSNotification.Name {
    static let parkingSessionSaved = NSNotification.Name("ParkingSessionSaved")
    static let parkingSessionEnded = NSNotification.Name("ParkingSessionEnded")
}

final class ParkingRepository: ParkingRepositoryProtocol {
    private let local: LocalParkingDataSource
    private let remote: RemoteParkingDataSource
    private let reachability: NetworkReachabilityMonitor
    private let defaults: UserDefaults

    private let backgroundSyncTimeoutNanoseconds: UInt64

    private let syncBatchSize = 20
    private let syncStateLock = NSLock()

    private var isSyncInFlight = false
    private var retryTask: Task<Void, Never>?

    init(
        local: LocalParkingDataSource,
        remote: RemoteParkingDataSource,
        reachability: NetworkReachabilityMonitor = NetworkReachabilityMonitor(),
        defaults: UserDefaults = .standard,
        backgroundSyncTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.local = local
        self.remote = remote
        self.reachability = reachability
        self.defaults = defaults
        self.backgroundSyncTimeoutNanoseconds = backgroundSyncTimeoutNanoseconds

        self.reachability.onConnectionRestored = { [weak self] in
            guard let self else { return }
            Task {
                await self.syncCachedUserIfNeeded()
            }
        }
    }

    // MARK: – Save
    func save(_ session: ParkingSession) async throws -> ParkingSession {
        let pendingSession = sessionWithSyncState(session, isSynced: false)
        let pendingRecord = try toLocalRecord(pendingSession, isSynced: false)
        try local.save(pendingRecord)
        try local.setPendingSyncOperation(
            ParkingSessionSyncOperation(
                userId: pendingRecord.userId,
                sessionId: pendingRecord.id
            )
        )

        // Déclencher la synchro en arrière-plan et revenir immédiatement.
        Task { [userId = session.userId] in
            await requestPendingRemoteSync(for: userId)
        }

        postSavedNotification(for: pendingSession)
        return pendingSession
    }

    // MARK: – Active session
    func fetchActiveSession(for userId: UUID, forceLocal: Bool) async throws -> ParkingSession? {
        // On ne bloque plus sur la synchro en avant-plan.
        // On la lance en tâche de fond si besoin.
        Task {
            await requestPendingRemoteSync(for: userId)
        }

        if let pendingLocalActive = try? local.fetchActive(userId: userId.uuidString),
           pendingLocalActive.isSynced == false {
            return try toDomainEntity(pendingLocalActive)
        }

        guard !forceLocal, reachability.isConnected else {
            if let record = try? local.fetchActive(userId: userId.uuidString) {
                return try toDomainEntity(record)
            }
            return nil
        }

        do {
            // Timeout de 5 secondes pour la récupération distante de la session active
            let remoteDTO = try await withThrowingTaskGroup(of: ParkingSessionDTO?.self) { group in
                group.addTask {
                    try await self.remote.fetchActive(userId: userId)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw APIError.requestTimedOut
                }
                
                let result = try await group.next()
                group.cancelAll()
                return result ?? nil
            }
            
            guard let remoteDTO else {
                if let staleLocalSession = try? local.fetchActive(userId: userId.uuidString),
                   staleLocalSession.isSynced == false {
                    return try toDomainEntity(staleLocalSession)
                }

                if let staleLocalSession = try? local.fetchActive(userId: userId.uuidString) {
                    try? local.delete(id: staleLocalSession.id)
                }
                return nil
            }

            let cachedRecord = try? local.fetchById(remoteDTO.id)
            let normalized = normalizedSession(
                from: remoteDTO,
                fallbackUserId: userId,
                fallbackPhotoPath: cachedRecord?.photoPath
            )
            guard normalized.endTime == nil else {
                try? local.delete(id: normalized.id.uuidString)
                return nil
            }

            try? persistSyncedLocalRecord(for: normalized)
            return normalized
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                print("[ParkingRepository] Remote active session lookup failed: \(error.localizedDescription)")
            }

            if let record = try? local.fetchActive(userId: userId.uuidString) {
                return try toDomainEntity(record)
            }
            throw error
        }
    }

    // MARK: – History
    func fetchHistory(for userId: UUID, limit: Int, offset: Int) async throws -> [ParkingSession] {
        Task {
            await requestPendingRemoteSync(for: userId)
        }

        guard reachability.isConnected else {
            return paginateHistory(
                cachedHistorySessions(for: userId),
                limit: limit,
                offset: offset
            )
        }

        do {
            let remoteSessions = try await remote.fetchHistory(userId: userId, limit: limit, offset: offset)
                .map { dto in
                    let cachedRecord = try? local.fetchById(dto.id)
                    return normalizedSession(
                        from: dto,
                        fallbackUserId: userId,
                        fallbackPhotoPath: cachedRecord?.photoPath
                    )
                }

            cacheRemoteHistoryPage(remoteSessions)
            let cachedLocalSessions = cachedHistorySessions(for: userId)
            let mergedSessions = mergeSessions(
                remoteSessions,
                withLocal: cachedLocalSessions,
                limit: limit,
                offset: offset
            )

            if offset > 0, mergedSessions.isEmpty {
                return remoteSessions
            }

            return mergedSessions
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                print("[ParkingRepository] Remote history lookup failed: \(error.localizedDescription)")
            }

            return paginateHistory(
                cachedHistorySessions(for: userId),
                limit: limit,
                offset: offset
            )
        }
    }

    // MARK: – End session
    func endSession(id: UUID) async throws -> ParkingSession {
        let cachedRecord = try? local.fetchById(id.uuidString)
        let fallbackUserId = cachedRecord
            .flatMap { UUID(uuidString: $0.userId) }
            ?? HistoryPlanResolver.cachedUser(defaults: defaults)?.id
            ?? UUID()

        guard let recordToEnd = cachedRecord else {
            throw APIError.notFound
        }

        let endedRecord = localRecord(recordToEnd, endingAt: .now, isSynced: false)
        try local.save(endedRecord)
        try local.setPendingSyncOperation(
            ParkingSessionSyncOperation(
                userId: endedRecord.userId,
                sessionId: endedRecord.id
            )
        )

        let userId = UUID(uuidString: endedRecord.userId) ?? fallbackUserId
        Task {
            await requestPendingRemoteSync(for: userId)
        }

        let endedSession = try toDomainEntity(endedRecord)
        postEndedNotification(for: endedSession)
        return endedSession
    }

    // MARK: – Delete (RGPD)
    func delete(id: UUID) async throws {
        try await remote.delete(id: id)
        try? local.delete(id: id.uuidString)
    }

    func deleteAllData(for userId: UUID) async throws {
        try await remote.deleteAllUserData(userId: userId)
        try? local.deleteAll(userId: userId.uuidString)
    }

    // MARK: – Mapping
    private func toLocalRecord(_ session: ParkingSession, isSynced: Bool = false) throws -> LocalParkingRecord {
        LocalParkingRecord(
            id: session.id.uuidString,
            userId: session.userId.uuidString,
            latitude: session.coordinate.latitude,
            longitude: session.coordinate.longitude,
            encryptedAddress: try local.encryptField(session.address),
            encryptedNote: try local.encryptField(session.note),
            parkingLevel: session.parkingLevel,
            zone: session.zone.rawValue,
            startTime: session.startTime,
            endTime: session.endTime,
            maxDuration: session.maxDuration,
            photoPath: session.photoPath,
            isApproximate: session.isApproximate,
            isSynced: isSynced
        )
    }

    private func toDomainEntity(_ record: LocalParkingRecord) throws -> ParkingSession {
        ParkingSession(
            id: UUID(uuidString: record.id) ?? UUID(),
            userId: UUID(uuidString: record.userId) ?? UUID(),
            coordinate: Coordinate(latitude: record.latitude, longitude: record.longitude),
            address: try local.decryptField(record.encryptedAddress),
            note: try local.decryptField(record.encryptedNote),
            parkingLevel: record.parkingLevel,
            startTime: record.startTime,
            endTime: record.endTime,
            maxDuration: record.maxDuration,
            zone: ParkingZone(rawValue: record.zone) ?? .unknown,
            isSynced: record.isSynced,
            isApproximate: record.isApproximate
        )
    }

    func requestPendingRemoteSync(for userId: UUID) async {
        guard reachability.isConnected else { return }
        guard beginSyncIfNeeded() else { return }
        defer { endSync() }

        while true {
            let operations: [ParkingSessionSyncOperation]
            do {
                operations = try local.pendingSyncOperations(userId: userId, limit: syncBatchSize)
            } catch {
                if AppConfig.isDebugLoggingEnabled {
                    print("[ParkingRepository] Unable to load pending sync operations: \(error.localizedDescription)")
                }
                return
            }

            guard !operations.isEmpty else {
                clearRetryTask()
                return
            }

            for operation in operations {
                do {
                    // Timeout de sécurité pour éviter de bloquer la file de synchro en arrière-plan
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await self.processPendingOperation(operation)
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: self.backgroundSyncTimeoutNanoseconds)
                            throw APIError.requestTimedOut
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                } catch {
                    let attempt = (try? local.registerSyncFailure(for: [operation.id])) ?? 1
                    if AppConfig.isDebugLoggingEnabled {
                        print("[ParkingRepository] Pending sync failed (attempt \(attempt)): \(error.localizedDescription)")
                    }
                    if shouldRetrySync(after: error) {
                        scheduleRetry(for: userId, attempt: attempt)
                    }
                    return
                }
            }
        }
    }

    private func normalizedSession(
        from dto: ParkingSessionDTO,
        fallbackUserId: UUID,
        fallbackPhotoPath: String? = nil
    ) -> ParkingSession {
        return ParkingSession(
            id: UUID(uuidString: dto.id) ?? UUID(),
            userId: UUID(uuidString: dto.userId) ?? fallbackUserId,
            coordinate: Coordinate(latitude: dto.latitude, longitude: dto.longitude),
            address: dto.address,
            photoPath: fallbackPhotoPath,
            note: dto.note,
            parkingLevel: dto.parkingLevel,
            startTime: dto.startTime,
            endTime: dto.endTime,
            maxDuration: dto.maxDuration,
            zone: ParkingZone(rawValue: dto.zone) ?? .unknown,
            isSynced: true,
            isApproximate: dto.isApproximate ?? false
        )
    }

    private func processPendingOperation(_ operation: ParkingSessionSyncOperation) async throws {
        guard let localRecord = try local.fetchById(operation.sessionId) else {
            try local.removePendingSyncOperations(operationIDs: [operation.id])
            return
        }

        let session = try toDomainEntity(localRecord)
        let remoteDTO: ParkingSessionDTO

        if session.endTime != nil {
            // Si la session est terminée localement, on tente d'abord de la terminer sur le serveur.
            do {
                remoteDTO = try await remote.endSession(id: session.id)
            } catch {
                // Si la session n'existe pas encore sur le serveur (car créée offline et terminée offline),
                // on la crée directement avec sa date de fin (upsert).
                if isNotFoundError(error) {
                    remoteDTO = try await remote.create(session)
                } else {
                    throw error
                }
            }
        } else {
            // Sinon on crée/met à jour normalement.
            remoteDTO = try await remote.create(session)
        }

        let syncedSession = normalizedSession(
            from: remoteDTO,
            fallbackUserId: session.userId,
            fallbackPhotoPath: localRecord.photoPath
        )

        try persistSyncedLocalRecord(for: syncedSession)
        try local.removePendingSyncOperations(operationIDs: [operation.id])
    }

    private func persistSyncedLocalRecord(for session: ParkingSession) throws {
        let record = try toLocalRecord(session, isSynced: true)
        try local.save(record)
    }

    private func cacheRemoteHistoryPage(_ sessions: [ParkingSession]) {
        for session in sessions {
            if let existing = try? local.fetchById(session.id.uuidString),
               existing.isSynced == false {
                continue
            }

            do {
                try persistSyncedLocalRecord(for: session)
            } catch {
                if AppConfig.isDebugLoggingEnabled {
                    print("[ParkingRepository] Local history cache save failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func cachedHistorySessions(for userId: UUID) -> [ParkingSession] {
        let records: [LocalParkingRecord]
        do {
            records = try local.fetchAllHistory(userId: userId.uuidString)
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                print("[ParkingRepository] Unable to load local history cache: \(error.localizedDescription)")
            }
            return []
        }

        let cutoff = historyCutoff(for: userId)
        return records.compactMap { record in
            guard let session = try? toDomainEntity(record) else { return nil }
            guard historyReferenceDate(for: session) >= cutoff else { return nil }
            return session
        }
    }

    private func historyCutoff(for userId: UUID, now: Date = .now) -> Date {
        let retentionDays = max(1, HistoryPlanResolver.resolvePlan(for: userId, defaults: defaults).retentionDays)
        return Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) ?? .distantPast
    }

    private func historyReferenceDate(for session: ParkingSession) -> Date {
        session.endTime ?? session.startTime
    }

    private func paginateHistory(
        _ sessions: [ParkingSession],
        limit: Int,
        offset: Int
    ) -> [ParkingSession] {
        Array(
            sessions
                .sorted { $0.startTime > $1.startTime }
                .dropFirst(offset)
                .prefix(limit)
        )
    }

    private func mergeSessions(
        _ remoteSessions: [ParkingSession],
        withLocal localSessions: [ParkingSession],
        limit: Int,
        offset: Int
    ) -> [ParkingSession] {
        guard !localSessions.isEmpty else { return remoteSessions }

        var mergedById = Dictionary(uniqueKeysWithValues: remoteSessions.map { ($0.id, $0) })
        for localSession in localSessions {
            guard let remoteSession = mergedById[localSession.id] else {
                mergedById[localSession.id] = localSession
                continue
            }

            if !localSession.isSynced {
                mergedById[localSession.id] = localSession
                continue
            }

            mergedById[localSession.id] = enrichedRemoteSession(remoteSession, withLocalFallback: localSession)
        }

        return paginateHistory(Array(mergedById.values), limit: limit, offset: offset)
    }

    private func enrichedRemoteSession(
        _ remoteSession: ParkingSession,
        withLocalFallback localSession: ParkingSession
    ) -> ParkingSession {
        var enriched = remoteSession

        if enriched.photoPath == nil {
            enriched.photoPath = localSession.photoPath
        }
        if enriched.address == nil {
            enriched.address = localSession.address
        }
        if enriched.note == nil {
            enriched.note = localSession.note
        }
        if enriched.parkingLevel == nil {
            enriched.parkingLevel = localSession.parkingLevel
        }
        if enriched.endTime == nil {
            enriched.endTime = localSession.endTime
        }
        if enriched.maxDuration == nil {
            enriched.maxDuration = localSession.maxDuration
        }
        if enriched.zone == .unknown {
            enriched.zone = localSession.zone
        }
        if !enriched.isApproximate {
            enriched.isApproximate = localSession.isApproximate
        }

        return enriched
    }

    private func sessionWithSyncState(_ session: ParkingSession, isSynced: Bool) -> ParkingSession {
        ParkingSession(
            id: session.id,
            userId: session.userId,
            coordinate: session.coordinate,
            address: session.address,
            photoPath: session.photoPath,
            note: session.note,
            parkingLevel: session.parkingLevel,
            startTime: session.startTime,
            endTime: session.endTime,
            maxDuration: session.maxDuration,
            zone: session.zone,
            isSynced: isSynced,
            isApproximate: session.isApproximate
        )
    }

    private func localRecord(
        _ record: LocalParkingRecord,
        endingAt endTime: Date,
        isSynced: Bool
    ) -> LocalParkingRecord {
        LocalParkingRecord(
            id: record.id,
            userId: record.userId,
            latitude: record.latitude,
            longitude: record.longitude,
            encryptedAddress: record.encryptedAddress,
            encryptedNote: record.encryptedNote,
            parkingLevel: record.parkingLevel,
            zone: record.zone,
            startTime: record.startTime,
            endTime: endTime,
            maxDuration: record.maxDuration,
            photoPath: record.photoPath,
            isApproximate: record.isApproximate,
            isSynced: isSynced
        )
    }

    private func shouldKeepPendingLocalCopy(after error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }

        switch apiError {
        case .networkUnavailable,
             .hostNotFound,
             .cannotConnectHost,
             .requestTimedOut,
             .serverError:
            return true
        case .requestFailed(let code, _):
            return code >= 500
        case .unknown(let underlyingError as URLError):
            return isTransientNetworkError(underlyingError)
        default:
            return false
        }
    }

    private func shouldKeepPendingEndedCopy(after error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }

        switch apiError {
        case .notFound,
             .networkUnavailable,
             .hostNotFound,
             .cannotConnectHost,
             .requestTimedOut,
             .serverError:
            return true
        case .requestFailed(let code, _):
            return code == 404 || code >= 500
        case .unknown(let underlyingError as URLError):
            return isTransientNetworkError(underlyingError)
        default:
            return false
        }
    }

    private func shouldRetrySync(after error: Error) -> Bool {
        shouldKeepPendingLocalCopy(after: error)
    }

    private func isNotFoundError(_ error: Error) -> Bool {
        if case APIError.notFound = error { return true }
        if case APIError.requestFailed(let code, _) = error, code == 404 { return true }
        return false
    }

    private func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .internationalRoamingOff,
             .dataNotAllowed,
             .cannotLoadFromNetwork,
             .cannotFindHost,
             .dnsLookupFailed,
             .cannotConnectToHost,
             .timedOut:
            return true
        default:
            return false
        }
    }

    private func beginSyncIfNeeded() -> Bool {
        syncStateLock.lock()
        defer { syncStateLock.unlock() }
        guard !isSyncInFlight else { return false }
        isSyncInFlight = true
        return true
    }

    private func endSync() {
        syncStateLock.lock()
        isSyncInFlight = false
        syncStateLock.unlock()
    }

    private func scheduleRetry(for userId: UUID, attempt: Int) {
        let safeAttempt = max(1, attempt)
        let delaySeconds = min(300, Int(pow(2.0, Double(min(safeAttempt, 6)))) * 5)

        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.requestPendingRemoteSync(for: userId)
        }

        syncStateLock.lock()
        retryTask?.cancel()
        retryTask = task
        syncStateLock.unlock()
    }

    private func clearRetryTask() {
        syncStateLock.lock()
        let task = retryTask
        retryTask = nil
        syncStateLock.unlock()
        task?.cancel()
    }

    private func syncCachedUserIfNeeded() async {
        guard let user = HistoryPlanResolver.cachedUser(defaults: defaults) else { return }
        await requestPendingRemoteSync(for: user.id)
    }

    private func postSavedNotification(for session: ParkingSession) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name.parkingSessionSaved, object: session)
        }
    }

    private func postEndedNotification(for session: ParkingSession) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name.parkingSessionEnded, object: session)
        }
    }
}

enum RepositoryError: LocalizedError {
    case notFound
    var errorDescription: String? { "Enregistrement introuvable." }
}
