import Foundation
import Combine
import CoreLocation

protocol AuthRepositoryProtocol {
    var currentUser: AnyPublisher<User?, Never> { get }
    var didFinishInitialSessionRestore: AnyPublisher<Bool, Never> { get }
    func signUp(email: String, password: String, displayName: String) async throws -> User
    func confirmSignUp(email: String, code: String) async throws -> User
    func cancelSignUp(email: String) async throws
    func signIn(email: String, password: String) async throws -> User
    func signInWithApple(idToken: String, nonce: String) async throws -> User
    func signInWithOAuthTokens(accessToken: String, refreshToken: String?) async throws -> User
    func requestPasswordReset(email: String, redirectTo: URL) async throws -> PasswordResetRequestResult
    func confirmEmailCodeBeforePasswordReset(email: String, code: String, redirectTo: URL) async throws -> String
    func updatePasswordUsingRecoveryToken(newPassword: String) async throws
    func updateEmail(_ newEmail: String, redirectTo: URL) async throws -> EmailChangeRequestResult
    func confirmEmailChange(newEmail: String, code: String) async throws -> EmailChangeConfirmationResult
    func updatePassword(currentPassword: String, newPassword: String) async throws
    func signOut() async throws
        func updateDisplayName(_ displayName: String) async throws -> User
    func refreshToken() async throws
    func deleteAccount() async throws  // RGPD
    func exportAllUserData() async throws -> UserDataExportPayload
        /// Met à jour le statut premium localement et tente une synchronisation serveur.
        /// `sourceProductID` permet de distinguer mensuel / à vie côté backend.
        func updatePremiumStatus(
            _ isPremium: Bool,
            sourceProductID: String?,
            sourceTransactionID: String?
        ) async throws
}

struct PasswordResetRequestResult: Equatable, Sendable {
    let message: String
    let requiresEmailConfirmationCode: Bool
}

struct EmailChangeRequestResult: Equatable, Sendable {
    let message: String
    let pendingEmail: String
    let requiresEmailConfirmationCode: Bool
}

struct EmailChangeConfirmationResult: Equatable, Sendable {
    let message: String
    let requiresCurrentEmailConfirmation: Bool
}

struct UserDataExportPayload: Equatable, Sendable {
    let fileName: String
    let contentType: String
    let content: String
    let generatedAt: Date
}
