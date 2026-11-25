import XCTest

@MainActor
final class Phase1ParkingRepositoryOfflineSyncTests: XCTestCase {

    func testSaveFallsBackToLocalStorageWhenNetworkIsUnavailable() async throws {
        let dependencies = try makeDependencies(testName: #function)
        defer { dependencies.cleanup() }

        dependencies.network.errors["/parking"] = APIError.networkUnavailable

        let session = ParkingSession(
            userId: dependencies.userId,
            coordinate: Coordinate(latitude: 48.8566, longitude: 2.3522),
            address: "Paris",
            note: "Sous-sol B2"
        )

        let saved = try await dependencies.repository.save(session)

        XCTAssertFalse(saved.isSynced)

        let localRecord = try XCTUnwrap(try dependencies.local.fetchById(session.id.uuidString))
        XCTAssertFalse(localRecord.isSynced)

        let operations = try dependencies.local.pendingSyncOperations(userId: dependencies.userId, limit: 10)
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations.first?.sessionId, session.id.uuidString)
    }

    func testSaveFallsBackToLocalStorageWhenImmediateRemoteSaveTimesOut() async throws {
        let dependencies = try makeDependencies(
            testName: #function,
            backgroundSyncTimeoutNanoseconds: 50_000_000
        )
        defer { dependencies.cleanup() }

        dependencies.network.delays["/parking"] = 2_000_000_000

        let session = ParkingSession(
            userId: dependencies.userId,
            coordinate: Coordinate(latitude: 48.8566, longitude: 2.3522),
            address: "Paris",
            note: "Hors connexion"
        )

        let saved = try await dependencies.repository.save(session)

        XCTAssertFalse(saved.isSynced)

        let localRecord = try XCTUnwrap(try dependencies.local.fetchById(session.id.uuidString))
        XCTAssertFalse(localRecord.isSynced)

        let operations = try dependencies.local.pendingSyncOperations(userId: dependencies.userId, limit: 10)
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations.first?.sessionId, session.id.uuidString)
    }

    func testOfflineEndedSessionIsSyncedWhenConnectionReturns() async throws {
        let dependencies = try makeDependencies(testName: #function)
        defer { dependencies.cleanup() }

        dependencies.network.errors["/parking"] = APIError.networkUnavailable

        let session = ParkingSession(
            userId: dependencies.userId,
            coordinate: Coordinate(latitude: 48.8566, longitude: 2.3522),
            address: "Paris",
            note: "Niveau -1"
        )

        _ = try await dependencies.repository.save(session)
        let ended = try await dependencies.repository.endSession(id: session.id)

        XCTAssertNotNil(ended.endTime)
        XCTAssertFalse(ended.isSynced)

        dependencies.network.errors["/parking"] = nil
        dependencies.network.errors["/parking/\(session.id.uuidString)/end"] = APIError.notFound
        let syncedDTO = ParkingSessionDTO(
            id: session.id.uuidString,
            userId: dependencies.userId.uuidString,
            latitude: session.coordinate.latitude,
            longitude: session.coordinate.longitude,
            address: session.address,
            note: session.note,
            parkingLevel: session.parkingLevel,
            zone: session.zone.rawValue,
            startTime: session.startTime,
            endTime: ended.endTime,
            maxDuration: session.maxDuration,
            isApproximate: false
        )
        dependencies.network.responses["/parking"] = APIResponse(data: syncedDTO, message: nil, success: true)

        await dependencies.repository.requestPendingRemoteSync(for: dependencies.userId)

        let syncedRecord = try XCTUnwrap(try dependencies.local.fetchById(session.id.uuidString))
        XCTAssertTrue(syncedRecord.isSynced)
        let syncedEndTime = try XCTUnwrap(syncedRecord.endTime)
        let endedEndTime = try XCTUnwrap(ended.endTime)
        XCTAssertLessThan(abs(syncedEndTime.timeIntervalSince(endedEndTime)), 1)

        let remainingOperations = try dependencies.local.pendingSyncOperations(userId: dependencies.userId, limit: 10)
        XCTAssertTrue(remainingOperations.isEmpty)
    }

    func testFetchHistoryFallsBackToLocalSessionsWhenRemoteFails() async throws {
        let dependencies = try makeDependencies(testName: #function)
        defer { dependencies.cleanup() }

        let endedSession = ParkingSession(
            userId: dependencies.userId,
            coordinate: Coordinate(latitude: 48.8566, longitude: 2.3522),
            address: "Paris",
            note: "Historique local",
            startTime: Date().addingTimeInterval(-600),
            endTime: Date().addingTimeInterval(-60),
            isSynced: false
        )

        let localRecord = LocalParkingRecord(
            id: endedSession.id.uuidString,
            userId: dependencies.userId.uuidString,
            latitude: endedSession.coordinate.latitude,
            longitude: endedSession.coordinate.longitude,
            encryptedAddress: try dependencies.local.encryptField(endedSession.address),
            encryptedNote: try dependencies.local.encryptField(endedSession.note),
            parkingLevel: endedSession.parkingLevel,
            zone: endedSession.zone.rawValue,
            startTime: endedSession.startTime,
            endTime: endedSession.endTime,
            maxDuration: endedSession.maxDuration,
            photoPath: endedSession.photoPath,
            isApproximate: endedSession.isApproximate,
            isSynced: false
        )
        try dependencies.local.save(localRecord)
        try dependencies.local.setPendingSyncOperation(
            ParkingSessionSyncOperation(
                userId: dependencies.userId.uuidString,
                sessionId: endedSession.id.uuidString
            )
        )

        dependencies.network.errors["/parking/history"] = APIError.networkUnavailable

        let history = try await dependencies.repository.fetchHistory(
            for: dependencies.userId,
            limit: 20,
            offset: 0
        )

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, endedSession.id)
        XCTAssertEqual(history.first?.address, endedSession.address)
        XCTAssertFalse(history.first?.isSynced ?? true)
    }

    func testFetchHistoryMergesRemotePageWithCachedLocalSessions() async throws {
        let dependencies = try makeDependencies(testName: #function)
        defer { dependencies.cleanup() }

        let localOnlySession = ParkingSession(
            userId: dependencies.userId,
            coordinate: Coordinate(latitude: 48.8570, longitude: 2.3510),
            address: "Cache local",
            note: "Disponible hors ligne",
            startTime: Date().addingTimeInterval(-3_600),
            endTime: Date().addingTimeInterval(-3_000),
            isSynced: true
        )

        let localRecord = LocalParkingRecord(
            id: localOnlySession.id.uuidString,
            userId: dependencies.userId.uuidString,
            latitude: localOnlySession.coordinate.latitude,
            longitude: localOnlySession.coordinate.longitude,
            encryptedAddress: try dependencies.local.encryptField(localOnlySession.address),
            encryptedNote: try dependencies.local.encryptField(localOnlySession.note),
            parkingLevel: localOnlySession.parkingLevel,
            zone: localOnlySession.zone.rawValue,
            startTime: localOnlySession.startTime,
            endTime: localOnlySession.endTime,
            maxDuration: localOnlySession.maxDuration,
            photoPath: localOnlySession.photoPath,
            isApproximate: localOnlySession.isApproximate,
            isSynced: true
        )
        try dependencies.local.save(localRecord)

        let remoteSession = ParkingSessionDTO(
            id: UUID().uuidString,
            userId: dependencies.userId.uuidString,
            latitude: 48.8566,
            longitude: 2.3522,
            address: "Serveur",
            note: "Historique distant",
            parkingLevel: nil,
            zone: ParkingZone.unknown.rawValue,
            startTime: Date().addingTimeInterval(-1_800),
            endTime: Date().addingTimeInterval(-1_200),
            maxDuration: nil,
            isApproximate: false
        )
        dependencies.network.responses["/parking/history"] = APIResponse(
            data: [remoteSession],
            message: nil,
            success: true
        )

        let history = try await dependencies.repository.fetchHistory(
            for: dependencies.userId,
            limit: 20,
            offset: 0
        )

        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.map(\.id), [
            UUID(uuidString: remoteSession.id) ?? UUID(),
            localOnlySession.id,
        ])
        XCTAssertEqual(history.last?.address, localOnlySession.address)
    }

    private func makeDependencies(
        testName: String,
        backgroundSyncTimeoutNanoseconds: UInt64 = 2_500_000_000
    ) throws -> ParkingRepositoryOfflineTestDependencies {
        let network = MockNetwork()
        let keychain = MockKeychain()
        let encryption = EncryptionService(keychain: keychain)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParkSpotTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)

        let local = LocalParkingDataSource(encryption: encryption, rootDirectory: root)
        let remote = RemoteParkingDataSource(network: network)
        let repository = ParkingRepository(
            local: local,
            remote: remote,
            reachability: NetworkReachabilityMonitor(startImmediately: false, initialConnectionState: true),
            defaults: UserDefaults.standard,
            backgroundSyncTimeoutNanoseconds: backgroundSyncTimeoutNanoseconds
        )

        return ParkingRepositoryOfflineTestDependencies(
            userId: UUID(),
            repository: repository,
            local: local,
            network: network,
            rootDirectory: root
        )
    }
}

struct ParkingRepositoryOfflineTestDependencies {
    let userId: UUID
    let repository: ParkingRepository
    let local: LocalParkingDataSource
    let network: MockNetwork
    let rootDirectory: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
