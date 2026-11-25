// LocalParkingDataSource.swift
// Offline-first local persistence – JSON store with AES-256-GCM field-level encryption
// Replace with Core Data or SQLite for production scale

import Foundation

nonisolated final class LocalParkingDataSource {
    private struct QueuePayload: Codable {
        let version: Int
        let operations: [ParkingSessionSyncOperation]
    }

    private enum StorageVersion {
        static let current = 1
    }

    private let encryption: EncryptionService
    private let fileURL: URL
    private let queueFileURL: URL

    init(encryption: EncryptionService, rootDirectory: URL? = nil) {
        self.encryption = encryption
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // Store in Application Support (excluded from iTunes backup by default)
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = rootDirectory ?? support ?? docs
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        self.fileURL = root.appendingPathComponent("parkspot.db.json")
        self.queueFileURL = root.appendingPathComponent("parkspot.sync.queue.v1.json")

        // Mark file as not backed up to iCloud – sensitive location data
        excludeFromBackup(url: fileURL)
        excludeFromBackup(url: queueFileURL)
    }

    // MARK: – CRUD
    func save(_ record: LocalParkingRecord) throws {
        var records = try loadAll()
        records.removeAll { $0.id == record.id }
        records.append(record)
        try persist(records)
    }

    func fetchActive(userId: String) throws -> LocalParkingRecord? {
        try loadAll().first { $0.userId == userId && $0.endTime == nil }
    }

    func fetchHistory(userId: String, limit: Int, offset: Int) throws -> [LocalParkingRecord] {
        let all = try loadAll()
            .filter { $0.userId == userId }
            .sorted { $0.startTime > $1.startTime }
        return Array(all.dropFirst(offset).prefix(limit))
    }

    func fetchAllHistory(userId: String) throws -> [LocalParkingRecord] {
        try loadAll()
            .filter { $0.userId == userId }
            .sorted { $0.startTime > $1.startTime }
    }

    func fetchById(_ id: String) throws -> LocalParkingRecord? {
        try loadAll().first { $0.id == id }
    }

    func updateEndTime(id: String, endTime: Date) throws {
        var records = try loadAll()
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[idx]
        // Rebuild with endTime (struct – copy + mutate)
        records[idx] = LocalParkingRecord(
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
            isSynced: false
        )
        try persist(records)
    }

    func delete(id: String) throws {
        var records = try loadAll()
        records.removeAll { $0.id == id }
        try persist(records)
    }

    func deleteAll(userId: String) throws {
        var records = try loadAll()
        records.removeAll { $0.userId == userId }
        try persist(records)

        var queue = try loadQueueOperations()
        queue.removeAll { $0.userId == userId }
        try persistQueueOperations(queue)
    }

    func deleteEndedRecords(userId: String) throws {
        var records = try loadAll()
        records.removeAll { $0.userId == userId && $0.endTime != nil }
        try persist(records)
    }

    @discardableResult
    func deleteOlderThan(userId: String, cutoff: Date) throws -> [String] {
        var records = try loadAll()
        let removableIds = records
            .filter { $0.userId == userId && $0.endTime != nil && $0.startTime < cutoff }
            .map(\.id)

        guard !removableIds.isEmpty else { return [] }
        let removableSet = Set(removableIds)
        records.removeAll { removableSet.contains($0.id) }
        try persist(records)
        return removableIds
    }

    func markSynced(id: String) throws {
        var records = try loadAll()
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let r = records[idx]
        records[idx] = LocalParkingRecord(
            id: r.id, userId: r.userId, latitude: r.latitude, longitude: r.longitude,
            encryptedAddress: r.encryptedAddress, encryptedNote: r.encryptedNote,
            parkingLevel: r.parkingLevel, zone: r.zone, startTime: r.startTime,
            endTime: r.endTime, maxDuration: r.maxDuration, photoPath: r.photoPath,
            isApproximate: r.isApproximate,
            isSynced: true
        )
        try persist(records)
    }

    func setPendingSyncOperation(_ operation: ParkingSessionSyncOperation) throws {
        var queue = try loadQueueOperations()
        upsertPendingSyncOperation(operation, into: &queue)
        try persistQueueOperations(queue)
    }

    func pendingSyncOperations(userId: UUID, limit: Int) throws -> [ParkingSessionSyncOperation] {
        try loadQueueOperations()
            .filter { $0.userId == userId.uuidString }
            .sorted { $0.enqueuedAt < $1.enqueuedAt }
            .prefix(limit)
            .map { $0 }
    }

    func removePendingSyncOperations(operationIDs: [UUID]) throws {
        guard !operationIDs.isEmpty else { return }
        let operationSet = Set(operationIDs)
        var queue = try loadQueueOperations()
        queue.removeAll { operationSet.contains($0.id) }
        try persistQueueOperations(queue)
    }

    func removePendingSyncOperation(userId: String, sessionId: String) throws {
        var queue = try loadQueueOperations()
        queue.removeAll { $0.userId == userId && $0.sessionId == sessionId }
        try persistQueueOperations(queue)
    }

    @discardableResult
    func registerSyncFailure(for operationIDs: [UUID], at date: Date = .now) throws -> Int {
        guard !operationIDs.isEmpty else { return 0 }
        let operationSet = Set(operationIDs)
        var queue = try loadQueueOperations()
        var maxRetryCount = 0

        for index in queue.indices where operationSet.contains(queue[index].id) {
            queue[index].retryCount += 1
            queue[index].lastAttemptAt = date
            maxRetryCount = max(maxRetryCount, queue[index].retryCount)
        }

        try persistQueueOperations(queue)
        return maxRetryCount
    }

    // MARK: – Private helpers
    private func loadAll() throws -> [LocalParkingRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        // File itself is plain JSON; sensitive fields (address, note) are AES-encrypted inside
        do {
            let persistedData = try Data(contentsOf: fileURL)
            let decryptedData = try encryption.decrypt(persistedData)
            return try decodeRecords(from: decryptedData)
        } catch EncryptionError.decryptionFailed {
            // Backward-compat: support legacy plain JSON payloads then migrate to encrypted format.
            let legacyData = try Data(contentsOf: fileURL)
            if let legacyRecords = try? decodeRecords(from: legacyData) {
                try persist(legacyRecords)
                return legacyRecords
            }
            recoverUnreadableStore(at: fileURL)
            return []
        }
    }

    private func decodeRecords(from data: Data) throws -> [LocalParkingRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LocalParkingRecord].self, from: data)
    }

    private func persist(_ records: [LocalParkingRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy  = .iso8601
        encoder.outputFormatting      = .sortedKeys
        let json          = try encoder.encode(records)
        let encryptedData = try encryption.encrypt(json)
        try encryptedData.write(to: fileURL, options: [.atomic, .completeFileProtection])
        // .completeFileProtection = encrypted by iOS at rest when device locked
    }

    private func loadQueueOperations() throws -> [ParkingSessionSyncOperation] {
        guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return [] }

        do {
            let encryptedData = try Data(contentsOf: queueFileURL)
            let decryptedData = try encryption.decrypt(encryptedData)
            return try decodeQueueOperations(from: decryptedData)
        } catch EncryptionError.decryptionFailed {
            let legacyData = try Data(contentsOf: queueFileURL)
            if let queue = try? decodeQueueOperations(from: legacyData) {
                try persistQueueOperations(queue)
                return queue
            }
            recoverUnreadableStore(at: queueFileURL)
            return []
        }
    }

    private func decodeQueueOperations(from data: Data) throws -> [ParkingSessionSyncOperation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let payload = try? decoder.decode(QueuePayload.self, from: data) {
            return payload.operations
        }
        return try decoder.decode([ParkingSessionSyncOperation].self, from: data)
    }

    private func persistQueueOperations(_ operations: [ParkingSessionSyncOperation]) throws {
        let payload = QueuePayload(version: StorageVersion.current, operations: operations)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(payload)
        let encryptedData = try encryption.encrypt(json)
        try encryptedData.write(to: queueFileURL, options: [.atomic, .completeFileProtection])
    }

    private func upsertPendingSyncOperation(
        _ operation: ParkingSessionSyncOperation,
        into queue: inout [ParkingSessionSyncOperation]
    ) {
        queue.removeAll { existing in
            existing.userId == operation.userId && existing.sessionId == operation.sessionId
        }
        queue.append(operation)
    }

    private func excludeFromBackup(url: URL) {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)
    }

    private func recoverUnreadableStore(at url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }

        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent).corrupted-\(timestamp).json"
        )

        try? fileManager.removeItem(at: backupURL)
        try? fileManager.moveItem(at: url, to: backupURL)
    }

    // MARK: – Encrypt individual fields
    func encryptField(_ value: String?) throws -> Data? {
        guard let value else { return nil }
        return try encryption.encrypt(value)
    }

    func decryptField(_ data: Data?) throws -> String? {
        guard let data else { return nil }
        return try encryption.decryptToString(data)
    }
}

final class LocalParkingHistoryStorageService {
    private struct EventsPayload: Codable {
        let version: Int
        let records: [LocalParkingHistoryRecord]
    }

    private struct QueuePayload: Codable {
        let version: Int
        let operations: [HistorySyncOperation]
    }

    private enum StorageVersion {
        static let current = 1
    }

    private let encryption: EncryptionService
    private let eventsFileURL: URL
    private let queueFileURL: URL

    init(encryption: EncryptionService) {
        self.encryption = encryption

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support ?? docs
        self.eventsFileURL = root.appendingPathComponent("parkspot.history.events.v1.json")
        self.queueFileURL = root.appendingPathComponent("parkspot.history.queue.v1.json")

        excludeFromBackup(url: eventsFileURL)
        excludeFromBackup(url: queueFileURL)
    }

    func save(_ event: ParkingHistoryEvent, plan: HistoryRetentionPlan) throws {
        var records = try loadEventRecords()
        let localRecord = LocalParkingHistoryRecord(from: event)
        records.removeAll { $0.id == localRecord.id }
        records.append(localRecord)

        var queue = try loadQueueOperations()
        queue.removeAll { $0.userId == localRecord.userId && $0.recordId == localRecord.id }

        if plan.cloudBackupEnabled {
            let operationType: HistorySyncOperationType = event.deletedAt == nil ? .upsert : .delete
            upsertOperation(
                HistorySyncOperation(
                    userId: localRecord.userId,
                    recordId: localRecord.id,
                    operationType: operationType
                ),
                into: &queue
            )
        }

        if !plan.cloudBackupEnabled {
            queue.removeAll { $0.userId == localRecord.userId }
        }

        try persistEventRecords(records)
        try persistQueueOperations(queue)
    }

    func fetchHistory(userId: UUID, limit: Int, offset: Int) throws -> [ParkingHistoryEvent] {
        let all = try loadEventRecords()
            .filter { $0.userId == userId.uuidString && $0.deletedAt == nil }
            .sorted { $0.createdAt > $1.createdAt }
            .map { $0.toDomain() }

        return Array(all.dropFirst(offset).prefix(limit))
    }

    func events(userId: UUID, recordIDs: [String]) throws -> [ParkingHistoryEvent] {
        guard !recordIDs.isEmpty else { return [] }
        let ids = Set(recordIDs)
        return try loadEventRecords()
            .filter { $0.userId == userId.uuidString && ids.contains($0.id) && $0.deletedAt == nil }
            .map { $0.toDomain() }
    }

    func pendingOperations(userId: UUID, limit: Int) throws -> [HistorySyncOperation] {
        try loadQueueOperations()
            .filter { $0.userId == userId.uuidString }
            .sorted { $0.enqueuedAt < $1.enqueuedAt }
            .prefix(limit)
            .map { $0 }
    }

    func markSynced(recordIDs: [String], at date: Date = .now) throws {
        guard !recordIDs.isEmpty else { return }
        let recordIdSet = Set(recordIDs)
        var records = try loadEventRecords()
        for index in records.indices where recordIdSet.contains(records[index].id) {
            records[index].syncedAt = date
        }
        try persistEventRecords(records)
    }

    func removeOperations(operationIDs: [UUID]) throws {
        guard !operationIDs.isEmpty else { return }
        let operationSet = Set(operationIDs)
        var queue = try loadQueueOperations()
        queue.removeAll { operationSet.contains($0.id) }
        try persistQueueOperations(queue)
    }

    @discardableResult
    func registerFailure(for operationIDs: [UUID], at date: Date = .now) throws -> Int {
        guard !operationIDs.isEmpty else { return 0 }
        let operationSet = Set(operationIDs)
        var queue = try loadQueueOperations()
        var maxRetryCount = 0

        for index in queue.indices where operationSet.contains(queue[index].id) {
            queue[index].retryCount += 1
            queue[index].lastAttemptAt = date
            maxRetryCount = max(maxRetryCount, queue[index].retryCount)
        }

        try persistQueueOperations(queue)
        return maxRetryCount
    }

    func clearQueue(userId: UUID) throws {
        var queue = try loadQueueOperations()
        queue.removeAll { $0.userId == userId.uuidString }
        try persistQueueOperations(queue)
    }

    @discardableResult
    func enqueueUpsertsForRecentEvents(userId: UUID, withinDays retentionDays: Int, now: Date = .now) throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(1, retentionDays), to: now) ?? now
        let recentRecords = try loadEventRecords().filter {
            $0.userId == userId.uuidString && $0.deletedAt == nil && $0.createdAt >= cutoff
        }

        guard !recentRecords.isEmpty else { return 0 }
        var queue = try loadQueueOperations()
        for record in recentRecords {
            upsertOperation(
                HistorySyncOperation(
                    userId: userId.uuidString,
                    recordId: record.id,
                    operationType: .upsert
                ),
                into: &queue
            )
        }
        try persistQueueOperations(queue)
        return recentRecords.count
    }

    func applyRetention(
        userId: UUID,
        retentionDays: Int,
        plan: HistoryRetentionPlan,
        now: Date = .now
    ) throws -> HistoryRetentionResult {
        let effectiveDays = max(1, retentionDays)
        let cutoff = Calendar.current.date(byAdding: .day, value: -effectiveDays, to: now) ?? now
        let userIdString = userId.uuidString

        var records = try loadEventRecords()
        let removable = records.filter {
            $0.userId == userIdString && $0.createdAt < cutoff
        }
        let removedIds = removable.map(\.id)
        let removedIdSet = Set(removedIds)

        var queue = try loadQueueOperations()
        if plan.cloudBackupEnabled {
            for recordId in removedIds {
                upsertOperation(
                    HistorySyncOperation(
                        userId: userIdString,
                        recordId: recordId,
                        operationType: .delete
                    ),
                    into: &queue
                )
            }
        } else {
            queue.removeAll { $0.userId == userIdString }
        }

        if !removedIdSet.isEmpty {
            records.removeAll { removedIdSet.contains($0.id) }
        }

        try persistEventRecords(records)
        try persistQueueOperations(queue)
        return HistoryRetentionResult(
            removedLocalCount: removedIds.count,
            enqueuedCloudDeleteCount: plan.cloudBackupEnabled ? removedIds.count : 0
        )
    }

    private func loadEventRecords() throws -> [LocalParkingHistoryRecord] {
        guard FileManager.default.fileExists(atPath: eventsFileURL.path) else { return [] }

        do {
            let encryptedData = try Data(contentsOf: eventsFileURL)
            let decryptedData = try encryption.decrypt(encryptedData)
            return try decodeEventRecords(from: decryptedData)
        } catch EncryptionError.decryptionFailed {
            let legacyData = try Data(contentsOf: eventsFileURL)
            if let records = try? decodeEventRecords(from: legacyData) {
                try persistEventRecords(records)
                return records
            }
            recoverUnreadableStore(at: eventsFileURL)
            return []
        }
    }

    private func decodeEventRecords(from data: Data) throws -> [LocalParkingHistoryRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let payload = try? decoder.decode(EventsPayload.self, from: data) {
            return payload.records
        }
        return try decoder.decode([LocalParkingHistoryRecord].self, from: data)
    }

    private func persistEventRecords(_ records: [LocalParkingHistoryRecord]) throws {
        let payload = EventsPayload(version: StorageVersion.current, records: records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(payload)
        let encrypted = try encryption.encrypt(json)
        try encrypted.write(to: eventsFileURL, options: [.atomic, .completeFileProtection])
    }

    private func loadQueueOperations() throws -> [HistorySyncOperation] {
        guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return [] }

        do {
            let encryptedData = try Data(contentsOf: queueFileURL)
            let decryptedData = try encryption.decrypt(encryptedData)
            return try decodeQueueOperations(from: decryptedData)
        } catch EncryptionError.decryptionFailed {
            let legacyData = try Data(contentsOf: queueFileURL)
            if let queue = try? decodeQueueOperations(from: legacyData) {
                try persistQueueOperations(queue)
                return queue
            }
            recoverUnreadableStore(at: queueFileURL)
            return []
        }
    }

    private func decodeQueueOperations(from data: Data) throws -> [HistorySyncOperation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let payload = try? decoder.decode(QueuePayload.self, from: data) {
            return payload.operations
        }
        return try decoder.decode([HistorySyncOperation].self, from: data)
    }

    private func persistQueueOperations(_ operations: [HistorySyncOperation]) throws {
        let payload = QueuePayload(version: StorageVersion.current, operations: operations)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(payload)
        let encrypted = try encryption.encrypt(json)
        try encrypted.write(to: queueFileURL, options: [.atomic, .completeFileProtection])
    }

    private func upsertOperation(_ operation: HistorySyncOperation, into queue: inout [HistorySyncOperation]) {
        queue.removeAll { existing in
            existing.userId == operation.userId && existing.recordId == operation.recordId
        }
        queue.append(operation)
    }

    private func excludeFromBackup(url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private func recoverUnreadableStore(at url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }

        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent).corrupted-\(timestamp).json"
        )

        try? fileManager.removeItem(at: backupURL)
        try? fileManager.moveItem(at: url, to: backupURL)
    }
}
