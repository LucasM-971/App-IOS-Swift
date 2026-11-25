import XCTest

@MainActor
final class Phase1AuthRepositoryTests: XCTestCase {

    func testSignInSuccessPersistsTokensAndUser() async throws {
        let network = MockNetwork()
        let keychain = MockKeychain()
        let suite = "Phase1AuthRepositoryTests.signin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let userDTO = try makeUserDTO(
            id: UUID().uuidString,
            email: "user@test.com",
            displayName: "User",
            isPremium: false,
            status: "free",
            statusId: 1,
            createdAt: Date()
        )
        network.responses["/auth/login"] = APIResponse(
            data: AuthResponseDTO(accessToken: "access", refreshToken: "refresh", user: userDTO),
            message: nil,
            success: true
        )

        let sut = AuthRepository(network: network, keychain: keychain, defaults: defaults)
        let user = try await sut.signIn(email: "user@test.com", password: "password123")

        XCTAssertEqual(user.email, "user@test.com")
        XCTAssertEqual(try keychain.get(.authToken), "access")
        XCTAssertEqual(try keychain.get(.refreshToken), "refresh")
    }

    func testSignInPropagatesUnauthorizedError() async {
        let network = MockNetwork()
        let keychain = MockKeychain()
        let suite = "Phase1AuthRepositoryTests.unauthorized.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        network.errors["/auth/login"] = APIError.unauthorized
        let sut = AuthRepository(network: network, keychain: keychain, defaults: defaults)

        do {
            _ = try await sut.signIn(email: "user@test.com", password: "bad")
            XCTFail("Expected unauthorized error")
        } catch APIError.unauthorized {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPasswordResetIsLocallyThrottled() async {
        let network = MockNetwork()
        let keychain = MockKeychain()
        let suite = "Phase1AuthRepositoryTests.reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Date().timeIntervalSince1970 - 10, forKey: "parkspot.auth.resetPassword.lastAttemptAt")

        let sut = AuthRepository(network: network, keychain: keychain, defaults: defaults)

        do {
            _ = try await sut.requestPasswordReset(
                email: "user@test.com",
                redirectTo: URL(string: "parkspot://reset")!
            )
            XCTFail("Expected local rate limit")
        } catch APIError.requestFailed(let code, _) {
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOAuthSignInNormalizesSessionUsingRefreshTokenWhenAvailable() async throws {
        let network = MockNetwork()
        let keychain = MockKeychain()
        let suite = "Phase1AuthRepositoryTests.oauthRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let userDTO = try makeUserDTO(
            id: UUID().uuidString,
            email: "apple@test.com",
            displayName: "Apple User",
            isPremium: false,
            status: "free",
            statusId: 1,
            createdAt: Date()
        )
        network.responses["/auth/refresh"] = APIResponse(
            data: AuthResponseDTO(
                accessToken: "normalized.jwt.token",
                refreshToken: "normalized-refresh",
                user: userDTO
            ),
            message: nil,
            success: true
        )

        let sut = AuthRepository(network: network, keychain: keychain, defaults: defaults)
        let user = try await sut.signInWithOAuthTokens(
            accessToken: "callback-access-token",
            refreshToken: "callback-refresh-token"
        )

        XCTAssertEqual(user.email, "apple@test.com")
        XCTAssertEqual(try keychain.get(.authToken), "normalized.jwt.token")
        XCTAssertEqual(try keychain.get(.refreshToken), "normalized-refresh")
        XCTAssertEqual(network.requestedPaths, ["/auth/refresh"])
    }

}

@MainActor
func makeUserDTO(
    id: String,
    email: String,
    displayName: String,
    isPremium: Bool,
    status: String,
    statusId: Int,
    createdAt: Date
) throws -> UserDTO {
    let payload: [String: Any] = [
        "id": id,
        "email": email,
        "displayName": displayName,
        "isPremium": isPremium,
        "status": status,
        "statusId": statusId,
        "createdAt": ISO8601DateFormatter().string(from: createdAt),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(UserDTO.self, from: data)
}
