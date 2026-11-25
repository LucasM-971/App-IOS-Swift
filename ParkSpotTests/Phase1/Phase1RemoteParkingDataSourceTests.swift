import XCTest

@MainActor
final class Phase1RemoteParkingDataSourceTests: XCTestCase {

    func testCreateReturnsRemoteDTO() async throws {
        let network = MockNetwork()
        let sut = RemoteParkingDataSource(network: network)

        let userId = UUID()
        let dto = ParkingSessionDTO(
            id: UUID().uuidString,
            userId: userId.uuidString,
            latitude: 48.8566,
            longitude: 2.3522,
            address: "Paris",
            note: "test",
            parkingLevel: nil,
            zone: "Inconnu",
            startTime: Date(),
            endTime: nil,
            maxDuration: nil,
            isApproximate: false
        )

        network.responses["/parking"] = APIResponse(data: dto, message: nil, success: true)

        let session = ParkingSession(userId: userId, coordinate: Coordinate(latitude: 48.8566, longitude: 2.3522))
        let result = try await sut.create(session)

        XCTAssertEqual(result.id, dto.id)
        XCTAssertTrue(network.requestedPaths.contains("/parking"))
    }

    func testFetchHistoryReturnsDTOList() async throws {
        let network = MockNetwork()
        let sut = RemoteParkingDataSource(network: network)

        let userId = UUID()
        let dto = ParkingSessionDTO(
            id: UUID().uuidString,
            userId: userId.uuidString,
            latitude: 48.8566,
            longitude: 2.3522,
            address: nil,
            note: nil,
            parkingLevel: nil,
            zone: "Inconnu",
            startTime: Date(),
            endTime: nil,
            maxDuration: nil,
            isApproximate: false
        )

        network.responses["/parking/history"] = APIResponse(data: [dto], message: nil, success: true)

        let history = try await sut.fetchHistory(userId: userId, limit: 20, offset: 0)

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, dto.id)
        XCTAssertTrue(network.requestedPaths.contains("/parking/history"))
    }

    func testDeleteAllUserDataTargetsUsersDataEndpoint() async throws {
        let network = MockNetwork()
        let sut = RemoteParkingDataSource(network: network)
        let userId = UUID()
        let expectedPath = "/users/\(userId.uuidString)/data"

        network.responses[expectedPath] = APIResponse(data: EmptyResponse(), message: nil, success: true)

        try await sut.deleteAllUserData(userId: userId)

        XCTAssertTrue(network.requestedPaths.contains(expectedPath))
    }
}
