// AuthSession.swift
// Global auth state – injected via @EnvironmentObject

import Foundation
import Combine

@MainActor
final class AuthSession: ObservableObject {
    enum IncomingAuthResult {
        case none
        case passwordRecovery
        case emailVerified
    }

    @Published private(set) var currentUser: User?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var profilePhotoData: Data?
    @Published private(set) var didFinishInitialLoad: Bool = false
    @Published private(set) var needsPasswordResetAfterRecoveryLink: Bool = false

    var isAuthenticated: Bool { currentUser != nil }
    var isLogged: Bool { isAuthenticated }

    private var cancellables = Set<AnyCancellable>()
    private let authRepo: AuthRepositoryProtocol

    private let profilePhotoKey = "parkspot.profile.photo.data"

    init(authRepo: AuthRepositoryProtocol) {
        self.authRepo = authRepo
        self.profilePhotoData = UserDefaults.standard.data(forKey: profilePhotoKey)
        authRepo.currentUser
            .receive(on: DispatchQueue.main)
            .sink { [weak self] user in
                self?.currentUser = user
            }
            .store(in: &cancellables)

        authRepo.didFinishInitialSessionRestore
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isFinished in
                self?.didFinishInitialLoad = isFinished
            }
            .store(in: &cancellables)
    }

    convenience init() {
        self.init(authRepo: DIContainer.shared.authRepository)
    }

    func signOut() async {
        try? await authRepo.signOut()
    }

    func exportAllUserData() async throws -> UserDataExportPayload {
        try await authRepo.exportAllUserData()
    }

    func updateEmail(_ newEmail: String) async throws -> EmailChangeRequestResult {
        let email = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.contains(".") else {
            throw ValidationError.invalidEmail
        }
        return try await authRepo.updateEmail(email, redirectTo: AppConfig.changeEmailRedirectURL)
    }

    func confirmEmailChange(newEmail: String, code: String) async throws -> EmailChangeConfirmationResult {
        let email = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.contains(".") else {
            throw ValidationError.invalidEmail
        }

        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw APIError.badRequest("Veuillez saisir le code de confirmation.")
        }

        return try await authRepo.confirmEmailChange(newEmail: email, code: trimmedCode)
    }

    func refreshCurrentUserSession() async throws {
        try await authRepo.refreshToken()
    }

    func confirmSignUp(email: String, code: String) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEmail.isEmpty else {
            throw ValidationError.invalidEmail
        }
        guard !trimmedCode.isEmpty else {
            throw APIError.badRequest("Veuillez saisir le code de confirmation.")
        }

        _ = try await authRepo.confirmSignUp(email: trimmedEmail, code: trimmedCode)
    }

    func cancelSignUp(email: String) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedEmail.isEmpty else {
            throw ValidationError.invalidEmail
        }
        try await authRepo.cancelSignUp(email: trimmedEmail)
    }

    func updatePassword(currentPassword: String, newPassword: String, confirmPassword: String) async throws {
        guard !currentPassword.isEmpty else { throw ValidationError.missingCurrentPassword }
        guard newPassword.count >= 8 else { throw ValidationError.weakPassword }
        guard newPassword == confirmPassword else { throw ValidationError.passwordMismatch }
        try await authRepo.updatePassword(currentPassword: currentPassword, newPassword: newPassword)
    }

    func requestPasswordReset(email: String) async throws -> PasswordResetRequestResult {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            throw ValidationError.invalidEmail
        }

        do {
            return try await authRepo.requestPasswordReset(
                email: trimmedEmail,
                redirectTo: AppConfig.passwordResetRedirectURL
            )
        } catch {
            if case APIError.notFound = error {
                throw ValidationError.unregisteredEmail
            }

            if case APIError.requestFailed(let code, _) = error, code == 404 {
                throw ValidationError.unregisteredEmail
            }

            if case APIError.badRequest(let message) = error,
               (message ?? "").localizedCaseInsensitiveContains("n'est pas inscrite") {
                throw ValidationError.unregisteredEmail
            }

            // Security-first behavior: never reveal whether an account exists.
            if shouldSilencePasswordResetError(error) {
                return PasswordResetRequestResult(
                    message: "auth.password_reset.email_sent".psLocalized,
                    requiresEmailConfirmationCode: false
                )
            }
            throw error
        }
    }

    func confirmEmailCodeBeforePasswordReset(email: String, code: String) async throws -> String {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            throw ValidationError.invalidEmail
        }

        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw APIError.badRequest("Veuillez saisir le code de confirmation.")
        }

        return try await authRepo.confirmEmailCodeBeforePasswordReset(
            email: trimmedEmail,
            code: trimmedCode,
            redirectTo: AppConfig.passwordResetRedirectURL
        )
    }

    @discardableResult
    func handleIncomingAuthURL(_ url: URL) async throws -> IncomingAuthResult {
        let params = extractAuthParams(from: url)

        guard let accessToken = params["access_token"], !accessToken.isEmpty else {
            if isEmailChangeCallback(url: url, params: params) {
                // Some Supabase email-change redirects may not carry fresh tokens.
                // Refreshing session forces /auth/me and updates currentUser.email.
                try await authRepo.refreshToken()
            }
            return .none
        }

        let refreshToken = params["refresh_token"]
        _ = try await authRepo.signInWithOAuthTokens(accessToken: accessToken, refreshToken: refreshToken)

        let isRecoveryLink = (params["type"]?.lowercased() == "recovery")
        if isRecoveryLink {
            needsPasswordResetAfterRecoveryLink = true
            return .passwordRecovery
        }

        if isEmailVerificationCallback(params: params) {
            return .emailVerified
        }

        return .none
    }

    func completePasswordReset(newPassword: String, confirmPassword: String) async throws {
        guard newPassword.count >= 8 else {
            throw ValidationError.weakPassword
        }
        guard newPassword == confirmPassword else {
            throw ValidationError.passwordMismatch
        }

        try await authRepo.updatePasswordUsingRecoveryToken(newPassword: newPassword)
        needsPasswordResetAfterRecoveryLink = false
    }

    func dismissPasswordResetFlow() {
        needsPasswordResetAfterRecoveryLink = false
    }

    func updateProfilePhoto(_ data: Data?) {
        profilePhotoData = data
        let defaults = UserDefaults.standard
        if let data {
            defaults.set(data, forKey: profilePhotoKey)
        } else {
            defaults.removeObject(forKey: profilePhotoKey)
        }
    }

    func waitUntilInitialLoad() async {
        if didFinishInitialLoad { return }

        // Bridge @Published to AsyncSequence. This is cancellation-aware: if the calling Task
        // is cancelled (e.g. bootstrap timeout), the iteration ends and this method returns.
        for await isFinished in $didFinishInitialLoad.values {
            if isFinished {
                return
            }
        }
    }

    func waitUntilInitialRouteCanBeResolved() async {
        if didFinishInitialLoad || currentUser != nil { return }

        for await state in Publishers.CombineLatest($currentUser, $didFinishInitialLoad).values {
            if state.0 != nil || state.1 {
                return
            }
        }
    }

    private func extractAuthParams(from callbackURL: URL) -> [String: String] {
        var params: [String: String] = [:]

        if let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] {
                params[item.name] = item.value
            }
        }

        if let fragment = callbackURL.fragment,
           let fragmentComponents = URLComponents(string: "https://callback.local/?\(fragment)") {
            for item in fragmentComponents.queryItems ?? [] {
                params[item.name] = item.value
            }
        }

        return params
    }

    private func shouldSilencePasswordResetError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let maskedIndicators = [
            "user not found",
            "email not found",
            "no user",
            "unknown email",
            "invalid login credentials",
            "account does not exist",
            "n'est pas inscrite",
        ]
        return maskedIndicators.contains { message.contains($0) }
    }

    private func isEmailChangeCallback(url: URL, params: [String: String]) -> Bool {
        let type = params["type"]?.lowercased() ?? ""
        if type == "email_change" {
            return true
        }

        let host = url.host?.lowercased() ?? ""
        if host == "change-email" {
            return true
        }

        return url.path.lowercased().contains("change-email")
    }

    private func isEmailVerificationCallback(params: [String: String]) -> Bool {
        let type = params["type"]?.lowercased() ?? ""
        return type == "signup"
    }

}

     extension AuthSession {
         func updateDisplayName(_ name: String) async throws {
             let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
             guard !trimmed.isEmpty else { throw ValidationError.emptyDisplayName }
             _ = try await authRepo.updateDisplayName(trimmed)
         }
     }

enum ValidationError: LocalizedError {
    case invalidEmail
    case unregisteredEmail
    case missingCurrentPassword
    case invalidCurrentPassword
    case weakPassword
    case passwordMismatch
    case emptyDisplayName

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "auth.validation.invalid_email".psLocalized
        case .unregisteredEmail:
            return "auth.validation.unregistered_email".psLocalized
        case .missingCurrentPassword:
            return "auth.validation.missing_current_password".psLocalized
        case .invalidCurrentPassword:
            return "auth.validation.invalid_current_password".psLocalized
        case .weakPassword:
            return "auth.validation.weak_password".psLocalized
        case .passwordMismatch:
            return "auth.validation.password_mismatch".psLocalized
        case .emptyDisplayName:
            return "auth.validation.empty_display_name".psLocalized
        }
    }
}
