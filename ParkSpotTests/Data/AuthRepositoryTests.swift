import XCTest
import Combine
@testable import ParkSpot

@MainActor
final class AuthRepositoryTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    func testUpdatePremiumStatusRollsBackOptimisticUpgradeOnConflict() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let keychain = FakeKeychainService(seed: [
            .authToken: Self.jwtLikeAccessToken,
            .refreshToken: "refresh",
        ])
        let freeUser = TestUserPayload.free(email: "free@example.com")
        let network = FakeNetworkClient { endpoint in
            switch endpoint.path {
            case "/auth/me":
                return try Self.makeUserResponseData(user: freeUser)
            case "/auth/premium":
                throw APIError.conflict("Cet achat est deja lie a un autre compte ParkSpot.")
            default:
                throw APIError.notFound
            }
        }

        let sut = AuthRepository(network: network, keychain: keychain, defaults: defaults)
        try await waitForUserLoad(from: sut, matchingEmail: freeUser.email)

        do {
            try await sut.updatePremiumStatus(
                true,
                sourceProductID: AppConfig.premiumLifetimeProductID,
                sourceTransactionID: "tx-conflict-1"
            )
            XCTFail("The optimistic premium update should have failed with a conflict.")
        } catch let error as APIError {
            guard case .conflict = error else {
                return XCTFail("Unexpected API error: \(error)")
            }
        }

        let cachedUser = try XCTUnwrap(Self.loadCachedUser(from: defaults))
        XCTAssertFalse(cachedUser.isPremium)
        XCTAssertEqual(cachedUser.status, "free")
        XCTAssertEqual(cachedUser.statusId, 1)
    }

    func testUpdatePremiumStatusKeepsOptimisticUpgradeOnTransientFailure() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let keychain = FakeKeychainService(seed: [
            .authToken: Self.jwtLikeAccessToken,
            .refreshToken: "refresh",
        ])
        let freeUser = TestUserPayload.free(email: "offline@example.com")
        let network = FakeNetworkClient { endpoint in
            switch endpoint.path {
            case "/auth/me":
                return try Self.makeUserResponseData(user: freeUser)
            case "/auth/premium":
                throw APIError.networkUnavailable
            default:
                throw APIError.notFound
            }
        }

        let sut = AuthRepository(network: network, keychain: keychain, defaults: defaults)
        try await waitForUserLoad(from: sut, matchingEmail: freeUser.email)

        do {
            try await sut.updatePremiumStatus(
                true,
                sourceProductID: AppConfig.premiumLifetimeProductID,
                sourceTransactionID: "tx-offline-1"
            )
            XCTFail("The premium sync should fail when the network is unavailable.")
        } catch let error as APIError {
            guard case .networkUnavailable = error else {
                return XCTFail("Unexpected API error: \(error)")
            }
        }

        let cachedUser = try XCTUnwrap(Self.loadCachedUser(from: defaults))
        XCTAssertTrue(cachedUser.isPremium)
        XCTAssertEqual(cachedUser.status, "paid_lifetime")
        XCTAssertEqual(cachedUser.statusId, 3)
    }

    private func waitForUserLoad(from repository: AuthRepository, matchingEmail email: String) async throws {
        let expectation = expectation(description: "Wait for initial user load")
        repository.currentUser
            .sink { user in
                if user?.email == email {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await fulfillment(of: [expectation], timeout: 2.0)
        cancellables.removeAll()
    }

    private static func loadCachedUser(from defaults: UserDefaults) -> User? {
        guard let data = defaults.data(forKey: "parkspot.auth.cachedUser.v1") else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    private static let jwtLikeAccessToken = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.signature"

    private static func makeUserResponseData(user: TestUserPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(EncodableAPIResponse(data: user, message: nil, success: true))
    }
}

private struct EncodableAPIResponse<T: Encodable>: Encodable {
    let data: T
    let message: String?
    let success: Bool
}

private struct TestUserPayload: Encodable {
    let id: String
    let email: String
    let displayName: String
    let isPremium: Bool
    let status: String
    let statusId: Int
    let createdAt: Date

    static func free(email: String) -> TestUserPayload {
        TestUserPayload(
            id: UUID().uuidString,
            email: email,
            displayName: "Test User",
            isPremium: false,
            status: "free",
            statusId: 1,
            createdAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
    }
}

private final class FakeNetworkClient: NetworkRequesting {
    private let handler: (Endpoint) throws -> Data

    init(handler: @escaping (Endpoint) throws -> Data) {
        self.handler = handler
    }

    func request<T>(_ endpoint: Endpoint) async throws -> T where T: Decodable {
        let data = try handler(endpoint)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

private final class FakeKeychainService: KeychainServiceProtocol {
    private var storage: [KeychainKey: String]

    init(seed: [KeychainKey: String] = [:]) {
        self.storage = seed
    }

    func set(_ value: String, for key: KeychainKey) throws {
        storage[key] = value
    }

    func get(_ key: KeychainKey) throws -> String {
        guard let value = storage[key] else {
            throw KeychainError.itemNotFound
        }
        return value
    }

    func delete(_ key: KeychainKey) throws {
        storage[key] = nil
    }

    func clearAll() throws {
        storage.removeAll()
    }
}
