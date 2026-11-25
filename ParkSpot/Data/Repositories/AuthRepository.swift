// AuthRepository.swift
import Foundation
import Combine
import OSLog
#if canImport(StoreKit)
import StoreKit
#endif

enum AuthRepositoryError: LocalizedError {
    case emailConfirmationRequired(email: String)

    var errorDescription: String? {
        switch self {
        case .emailConfirmationRequired(let email):
            if email.isEmpty {
                return "auth.signup.confirmation_required_no_email".psLocalized
            } else {
                return String(
                    format: "auth.signup.confirmation_required_with_email %@".psLocalized,
                    email
                )
            }
        }
    }
}

final class AuthRepository: AuthRepositoryProtocol {

    private let logger = Logger(subsystem: "com.parkspot.app", category: "auth")

    private let network: NetworkRequesting
    private let keychain: KeychainServiceProtocol
    private let defaults: UserDefaults
    private let userSubject = CurrentValueSubject<User?, Never>(nil)
    private let sessionRestoreSubject = CurrentValueSubject<Bool, Never>(false)
    private let cachedUserKey = "parkspot.auth.cachedUser.v1"
    private let resetPasswordLastAttemptAtKey = "parkspot.auth.resetPassword.lastAttemptAt"
    private let resetPasswordCooldownSeconds: TimeInterval = 30
    private static var premiumProductIDs: Set<String> {
        AppConfig.premiumProductIDs
    }

    static func shouldThrottlePasswordReset(
        now: TimeInterval,
        lastAttempt: TimeInterval,
        cooldown: TimeInterval
    ) -> Bool {
        guard lastAttempt > 0 else { return false }
        return (now - lastAttempt) < cooldown
    }

    var currentUser: AnyPublisher<User?, Never> {
        userSubject.eraseToAnyPublisher()
    }

    var didFinishInitialSessionRestore: AnyPublisher<Bool, Never> {
        sessionRestoreSubject.eraseToAnyPublisher()
    }

    init(network: NetworkRequesting, keychain: KeychainServiceProtocol, defaults: UserDefaults = .standard) {
        self.network  = network
        self.keychain = keychain
        self.defaults = defaults
        restoreSession()
    }

    func signUp(email: String, password: String, displayName: String) async throws -> User {
        trackMetric("signup.attempt")
        let body = RegisterRequestDTO(
            email: email, password: password, displayName: displayName,
            gdprConsent: true, consentDate: .now
        )
        let endpoint = Endpoint(path: "/auth/register", method: .post,
                                body: body, requiresAuth: false)
        do {
            let response: APIResponse<RegisterResponseDTO> = try await network.request(endpoint)

            if response.data.requiresEmailConfirmation == true {
                throw AuthRepositoryError.emailConfirmationRequired(email: response.data.confirmationEmail ?? email)
            }

            guard
                let accessToken = response.data.accessToken,
                let refreshToken = response.data.refreshToken,
                let user = response.data.user,
                !accessToken.isEmpty,
                !refreshToken.isEmpty
            else {
                throw APIError.requestFailed(500, "Réponse d'inscription invalide.")
            }

            let authResponse = AuthResponseDTO(
                accessToken: accessToken,
                refreshToken: refreshToken,
                user: user
            )
            let signedUpUser = try handleAuthResponse(authResponse)
            trackMetric("signup.success")
            return signedUpUser
        } catch APIError.notFound {
            trackMetric("signup.failure.not_found")
            if AppConfig.allowLocalDebugAuthFallback {
                #if DEBUG
                return try localDebugAuth(email: email, displayName: displayName)
                #else
                throw APIError.notFound
                #endif
            }
            throw APIError.notFound
        } catch APIError.requestFailed(let code, let message) where code == 404 {
            trackMetric("signup.failure.not_found")
            if AppConfig.allowLocalDebugAuthFallback {
                #if DEBUG
                return try localDebugAuth(email: email, displayName: displayName)
                #else
                throw APIError.requestFailed(code, message)
                #endif
            }
            throw APIError.requestFailed(code, message)
        } catch {
            trackMetric("signup.failure")
            throw error
        }
    }

    func confirmSignUp(email: String, code: String) async throws -> User {
        struct Body: Encodable {
            let email: String
            let code: String
        }

        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanEmail.isEmpty else {
            throw ValidationError.invalidEmail
        }
        guard !cleanCode.isEmpty else {
            throw APIError.badRequest("Code de confirmation manquant.")
        }

        let endpoint = Endpoint(
            path: "/auth/register/confirm",
            method: .post,
            body: Body(email: cleanEmail, code: cleanCode),
            requiresAuth: false
        )

        let response: APIResponse<AuthResponseDTO> = try await network.request(endpoint)
        return try handleAuthResponse(response.data)
    }

    func cancelSignUp(email: String) async throws {
        struct Body: Encodable {
            let email: String
        }

        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanEmail.isEmpty else {
            throw ValidationError.invalidEmail
        }

        let endpoint = Endpoint(
            path: "/auth/register",
            method: .delete,
            body: Body(email: cleanEmail),
            requiresAuth: false
        )

        let _: APIResponse<EmptyResponse> = try await network.request(endpoint)
    }

    func signIn(email: String, password: String) async throws -> User {
        trackMetric("signin.attempt")
        let body = LoginRequestDTO(email: email, password: password)
        let endpoint = Endpoint(path: "/auth/login", method: .post,
                                body: body, requiresAuth: false)
        do {
            let response: APIResponse<AuthResponseDTO> = try await network.request(endpoint)
            let signedInUser = try handleAuthResponse(response.data)
            trackMetric("signin.success")
            return signedInUser
        } catch APIError.notFound {
            trackMetric("signin.failure.not_found")
            if AppConfig.allowLocalDebugAuthFallback {
                #if DEBUG
                let fallbackName = email.split(separator: "@").first.map(String.init) ?? "Utilisateur"
                return try localDebugAuth(email: email, displayName: fallbackName)
                #else
                throw APIError.notFound
                #endif
            }
            throw APIError.notFound
        } catch APIError.requestFailed(let code, let message) where code == 404 {
            trackMetric("signin.failure.not_found")
            if AppConfig.allowLocalDebugAuthFallback {
                #if DEBUG
                let fallbackName = email.split(separator: "@").first.map(String.init) ?? "Utilisateur"
                return try localDebugAuth(email: email, displayName: fallbackName)
                #else
                throw APIError.requestFailed(code, message)
                #endif
            }
            throw APIError.requestFailed(code, message)
        } catch {
            trackMetric("signin.failure")
            throw error
        }
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> User {
        struct Body: Encodable {
            let idToken: String
            let nonce: String

            enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
                case nonce
            }
        }

        struct Response: Decodable {
            let accessToken: String
            let refreshToken: String?
        }

        let cleanIdToken = idToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNonce = nonce.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanIdToken.isEmpty else {
            throw APIError.badRequest("Jeton Apple manquant.")
        }

        guard !cleanNonce.isEmpty else {
            throw APIError.badRequest("Nonce Apple manquant.")
        }

        let endpoint = Endpoint(
            path: "/auth/apple",
            method: .post,
            body: Body(
                idToken: cleanIdToken,
                nonce: cleanNonce
            ),
            requiresAuth: false
        )
        let response: APIResponse<Response>
        do {
            response = try await network.request(endpoint)
        } catch {
            throw error
        }

        return try await signInWithOAuthTokens(
            accessToken: response.data.accessToken,
            refreshToken: response.data.refreshToken
        )
    }

    func signInWithOAuthTokens(accessToken: String, refreshToken: String?) async throws -> User {
        let cleanAccessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRefreshToken = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanAccessToken.isEmpty else {
            throw APIError.unauthorized
        }

        if let cleanRefreshToken, !cleanRefreshToken.isEmpty {
            do {
                return try await establishSessionFromRefreshToken(cleanRefreshToken)
            } catch {
                if AppConfig.isDebugLoggingEnabled {
                    logger.debug("OAuth refresh normalization failed, falling back to callback access token: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        guard looksLikeJWT(cleanAccessToken) else {
            try? keychain.delete(.authToken)
            try? keychain.delete(.refreshToken)
            try? keychain.delete(.userId)
            clearCachedUser()
            await MainActor.run { userSubject.send(nil) }
            throw APIError.badRequest("OAuth session token invalid.")
        }

        try keychain.set(cleanAccessToken, for: .authToken)
        if let cleanRefreshToken, !cleanRefreshToken.isEmpty {
            try keychain.set(cleanRefreshToken, for: .refreshToken)
        }

        do {
            let endpoint = Endpoint(path: "/auth/me", method: .get)
            let response: APIResponse<UserDTO> = try await network.request(endpoint)
            let user = response.data.toDomain()
            try? keychain.set(user.id.uuidString, for: .userId)
            cacheUser(user)
            await MainActor.run { userSubject.send(user) }
            scheduleLocalPremiumReconciliation()
            return user
        } catch {
            try? keychain.delete(.authToken)
            try? keychain.delete(.refreshToken)
            try? keychain.delete(.userId)
            clearCachedUser()
            await MainActor.run { userSubject.send(nil) }
            throw error
        }
    }

    func requestPasswordReset(email: String, redirectTo: URL) async throws -> PasswordResetRequestResult {
        trackMetric("password_reset.attempt")
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanEmail.isEmpty else {
            throw ValidationError.invalidEmail
        }

        let now = Date().timeIntervalSince1970
        let lastAttempt = defaults.double(forKey: resetPasswordLastAttemptAtKey)
        if Self.shouldThrottlePasswordReset(now: now, lastAttempt: lastAttempt, cooldown: resetPasswordCooldownSeconds) {
            trackMetric("password_reset.rate_limited.local")
            throw APIError.requestFailed(429, "auth.password_reset.rate_limit".psLocalized)
        }
        defaults.set(now, forKey: resetPasswordLastAttemptAtKey)

        struct Body: Encodable {
            let email: String
            let redirectTo: String
        }

        let endpoint = Endpoint(
            path: "/auth/recover",
            method: .post,
            body: Body(email: cleanEmail, redirectTo: redirectTo.absoluteString),
            requiresAuth: false
        )
        do {
            let response: APIResponse<PasswordResetRequestResponseDTO> = try await network.request(endpoint)
            trackMetric("password_reset.success")
            let message =
                response.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (response.message ?? "")
                : "auth.password_reset.email_sent".psLocalized
            return PasswordResetRequestResult(
                message: message,
                requiresEmailConfirmationCode: response.data.requiresEmailConfirmation == true
            )
        } catch APIError.requestFailed(let code, let message) where code == 429 {
            trackMetric("password_reset.rate_limited.remote")
            throw APIError.requestFailed(429, message ?? "auth.password_reset.rate_limit_minutes".psLocalized)
        } catch APIError.badRequest(let message) {
            trackMetric("password_reset.failure.bad_request")
            throw APIError.badRequest(message ?? "auth.password_reset.error".psLocalized)
        } catch {
            trackMetric("password_reset.failure")
            throw error
        }
    }

    func confirmEmailCodeBeforePasswordReset(email: String, code: String, redirectTo: URL) async throws -> String {
        struct Body: Encodable {
            let email: String
            let code: String
            let redirectTo: String
        }

        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEmail.isEmpty else {
            throw ValidationError.invalidEmail
        }
        guard !cleanCode.isEmpty else {
            throw APIError.badRequest("Code de confirmation manquant.")
        }

        let endpoint = Endpoint(
            path: "/auth/recover/confirm-email",
            method: .post,
            body: Body(
                email: cleanEmail,
                code: cleanCode,
                redirectTo: redirectTo.absoluteString
            ),
            requiresAuth: false
        )

        let response: APIResponse<EmailCodeVerificationForPasswordResetResponseDTO> = try await network
            .request(endpoint)
        return response.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (response.message ?? "")
            : "auth.password_reset.success".psLocalized
    }

    func updatePasswordUsingRecoveryToken(newPassword: String) async throws {
        let trimmed = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else {
            throw ValidationError.weakPassword
        }

        guard (try? keychain.get(.authToken)).flatMap({ $0.isEmpty ? nil : $0 }) != nil else {
            throw APIError.unauthorized
        }

        struct Body: Encodable { let newPassword: String }
        let recoveryEndpoint = Endpoint(
            path: "/auth/password/recovery",
            method: .put,
            body: Body(newPassword: trimmed)
        )
        let _: APIResponse<EmptyResponse> = try await network.request(recoveryEndpoint)

        // Refresh user snapshot after password update.
        let profileEndpoint = Endpoint(path: "/auth/me", method: .get)
        let response: APIResponse<UserDTO> = try await network.request(profileEndpoint)
        let user = response.data.toDomain()
        cacheUser(user)
        await MainActor.run { userSubject.send(user) }
    }

    func updateEmail(_ newEmail: String, redirectTo: URL) async throws -> EmailChangeRequestResult {
        struct UpdateEmailBody: Encodable {
            let newEmail: String
            let redirectTo: String
        }

        let cleanEmail = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanEmail.isEmpty else {
            throw ValidationError.invalidEmail
        }

        let endpoint = Endpoint(
            path: "/auth/email",
            method: .put,
            body: UpdateEmailBody(
                newEmail: cleanEmail,
                redirectTo: redirectTo.absoluteString
            )
        )

        let response: APIResponse<EmailChangeRequestResponseDTO> = try await network.request(endpoint)
        let message =
            response.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (response.message ?? "")
            : "Un code de confirmation a ete envoye a la nouvelle adresse."

        return EmailChangeRequestResult(
            message: message,
            pendingEmail: response.data.pendingEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (response.data.pendingEmail ?? cleanEmail)
                : cleanEmail,
            requiresEmailConfirmationCode: response.data.requiresEmailConfirmation == true
        )
    }

    func confirmEmailChange(newEmail: String, code: String) async throws -> EmailChangeConfirmationResult {
        struct Body: Encodable {
            let newEmail: String
            let code: String
        }

        let cleanEmail = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEmail.isEmpty else {
            throw ValidationError.invalidEmail
        }
        guard !cleanCode.isEmpty else {
            throw APIError.badRequest("Code de confirmation manquant.")
        }

        let endpoint = Endpoint(
            path: "/auth/email/confirm",
            method: .post,
            body: Body(newEmail: cleanEmail, code: cleanCode)
        )

        let response: APIResponse<EmailChangeConfirmationResponseDTO> = try await network.request(endpoint)

        if let user = response.data.user?.toDomain() {
            cacheUser(user)
            await MainActor.run { userSubject.send(user) }
        }

        let message =
            response.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (response.message ?? "")
            : "Adresse e-mail mise a jour."

        return EmailChangeConfirmationResult(
            message: message,
            requiresCurrentEmailConfirmation: response.data.requiresCurrentEmailConfirmation == true
        )
    }

    func updatePassword(currentPassword: String, newPassword: String) async throws {
        struct UpdatePasswordBody: Encodable {
            let currentPassword: String
            let newPassword: String
        }

        let endpoint = Endpoint(
            path: "/auth/password",
            method: .put,
            body: UpdatePasswordBody(currentPassword: currentPassword, newPassword: newPassword)
        )
        let _: APIResponse<EmptyResponse> = try await network.request(endpoint)
    }

    func updateDisplayName(_ displayName: String) async throws -> User {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError.emptyDisplayName
        }

        // Local-first: update immediately so UI never depends on remote availability.
        let current = userSubject.value ?? loadCachedUser() ?? User(email: "", displayName: trimmed)
        var updated = current
        updated.displayName = trimmed
        cacheUser(updated)
        await MainActor.run { userSubject.send(updated) }

        // Best-effort remote sync (non-blocking, no user-facing failure if endpoint is missing).
        struct Body: Encodable { let displayName: String }
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                let endpoint = Endpoint(path: "/auth/profile", method: .put, body: Body(displayName: trimmed))
                let response: APIResponse<UserDTO> = try await self.network.request(endpoint)
                let remoteUser = response.data.toDomain()
                self.cacheUser(remoteUser)
                await MainActor.run { self.userSubject.send(remoteUser) }
            } catch {
                // Keep local value; remote can sync later.
                if AppConfig.isDebugLoggingEnabled {
                    self.logger.debug("updateDisplayName sync distant ignorée: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        return updated
    }

    func updatePremiumStatus(
        _ isPremium: Bool,
        sourceProductID: String?,
        sourceTransactionID: String?
    ) async throws {
        // Mise à jour locale optimiste avec statut cohérent (status/statusId + isPremium).
        let previousUser = userSubject.value ?? loadCachedUser()
        let optimisticUser = previousUser.map {
            appliedLocalPremiumState(
                to: $0,
                isPremium: isPremium,
                sourceProductID: sourceProductID
            )
        }
        if let optimisticUser {
            cacheUser(optimisticUser)
            await MainActor.run { userSubject.send(optimisticUser) }
        }

        // Synchronisation distante en best-effort pour la persistance côté serveur.
        struct Body: Encodable {
            let isPremium: Bool
            let productId: String?
            let transactionId: String?
        }

        let endpoint = Endpoint(
            path: "/auth/premium",
            method: .put,
            body: Body(
                isPremium: isPremium,
                productId: sourceProductID,
                transactionId: sourceTransactionID
            )
        )
        do {
            let response: APIResponse<UserDTO> = try await network.request(endpoint)
            let updatedUser = response.data.toDomain()
            cacheUser(updatedUser)
            await MainActor.run { userSubject.send(updatedUser) }
        } catch {
            // Rollback sur les erreurs métier/validation pour éviter de laisser
            // un compte localement premium alors que le backend a refusé l'attribution.
            if shouldRollbackOptimisticPremiumUpdate(isPremium: isPremium, after: error),
               let previousUser {
                cacheUser(previousUser)
                await MainActor.run { userSubject.send(previousUser) }
            }
            throw error
        }
    }

    func signOut() async throws {
        let endpoint = Endpoint(path: "/auth/logout", method: .post)
        _ = try? await (network.request(endpoint) as APIResponse<EmptyResponse>)
        try keychain.delete(.authToken)
        try keychain.delete(.refreshToken)
        try keychain.delete(.userId)
        clearCachedUser()
        await MainActor.run { userSubject.send(nil) }
    }

    func refreshToken() async throws {
        let refresh = try keychain.get(.refreshToken)
        _ = try await establishSessionFromRefreshToken(refresh)
    }

    func deleteAccount() async throws {
        let endpoint = Endpoint(path: "/auth/account", method: .delete)
        let _: APIResponse<EmptyResponse> = try await network.request(endpoint)
        try keychain.clearAll()
        clearCachedUser()
        await MainActor.run { userSubject.send(nil) }
    }

    func exportAllUserData() async throws -> UserDataExportPayload {
        let endpoint = Endpoint(path: "/auth/export", method: .get)
        let response: APIResponse<ExportDataResponseDTO> = try await network.request(endpoint)
        return UserDataExportPayload(
            fileName: response.data.fileName,
            contentType: response.data.contentType,
            content: response.data.content,
            generatedAt: response.data.generatedAt
        )
    }

    @discardableResult
    private func handleAuthResponse(_ dto: AuthResponseDTO) throws -> User {
        try keychain.set(dto.accessToken,  for: .authToken)
        try keychain.set(dto.refreshToken, for: .refreshToken)
        try keychain.set(dto.user.id,      for: .userId)
        let user = dto.user.toDomain()
        cacheUser(user)
        userSubject.send(user)
        scheduleLocalPremiumReconciliation()
        return user
    }

    private func establishSessionFromRefreshToken(_ refreshToken: String) async throws -> User {
        struct RefreshBody: Encodable { let refreshToken: String }

        let cleanRefreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRefreshToken.isEmpty else {
            throw APIError.unauthorized
        }

        let endpoint = Endpoint(
            path: "/auth/refresh",
            method: .post,
            body: RefreshBody(refreshToken: cleanRefreshToken),
            requiresAuth: false
        )
        let response: APIResponse<AuthResponseDTO> = try await network.request(endpoint)
        return try handleAuthResponse(response.data)
    }

    private func restoreSession() {
        Task {
            defer {
                sessionRestoreSubject.send(true)
            }

            guard let token = try? keychain.get(.authToken), !token.isEmpty else {
                clearCachedUser()
                await MainActor.run { userSubject.send(nil) }
                return
            }

            // Nettoie les anciens tokens debug/non-JWT pour éviter l'erreur backend
            // "unsupported JWT".
            guard looksLikeJWT(token) else {
                try? keychain.delete(.authToken)
                try? keychain.delete(.refreshToken)
                try? keychain.delete(.userId)
                clearCachedUser()
                await MainActor.run { userSubject.send(nil) }
                return
            }

            // Hydrate UI immediately to avoid false "logged out" flicker at launch.
            if let cached = loadCachedUser() {
                await MainActor.run { userSubject.send(cached) }
                scheduleLocalPremiumReconciliation()
            }

            do {
                let endpoint = Endpoint(path: "/auth/me", method: .get)
                let response: APIResponse<UserDTO> = try await network.request(endpoint)
                let user = response.data.toDomain()
                try? keychain.set(user.id.uuidString, for: .userId)
                cacheUser(user)
                await MainActor.run { userSubject.send(user) }
                scheduleLocalPremiumReconciliation()
            } catch {
                // If token is stale, try a refresh once before disconnecting.
                if isAuthFailure(error) {
                    do {
                        try await refreshToken()
                        let endpoint = Endpoint(path: "/auth/me", method: .get)
                        let response: APIResponse<UserDTO> = try await network.request(endpoint)
                        let user = response.data.toDomain()
                        try? keychain.set(user.id.uuidString, for: .userId)
                        cacheUser(user)
                        await MainActor.run { userSubject.send(user) }
                        scheduleLocalPremiumReconciliation()
                    } catch {
                        // Only force logout on confirmed auth failures.
                        if isAuthFailure(error) {
                            try? keychain.delete(.authToken)
                            try? keychain.delete(.refreshToken)
                            try? keychain.delete(.userId)
                            clearCachedUser()
                            await MainActor.run { userSubject.send(nil) }
                        }
                    }
                }
            }
        }
    }

    private func scheduleLocalPremiumReconciliation() {
        Task(priority: .utility) { [weak self] in
            await self?.reconcileLocalPremiumEntitlementIfNeeded()
        }
    }

    private func reconcileLocalPremiumEntitlementIfNeeded() async {
        guard let current = userSubject.value ?? loadCachedUser() else { return }
        guard !current.isPremium else { return }
        guard let entitlement = await activeStoreKitPremiumEntitlement() else { return }
        do {
            try await updatePremiumStatus(
                true,
                sourceProductID: entitlement.productID,
                sourceTransactionID: String(entitlement.id)
            )
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                logger.debug("reconcileLocalPremiumEntitlementIfNeeded sync distante échouée: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func activeStoreKitPremiumEntitlement() async -> Transaction? {
        #if canImport(StoreKit)
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard Self.premiumProductIDs.contains(transaction.productID) else { continue }
            guard isStoreKitPremiumEntitlementOwnedByCurrentUser(transaction) else { continue }
            guard transaction.revocationDate == nil else { continue }
            if transaction.isUpgraded { continue }
            return transaction
        }
        #endif
        return nil
    }

    #if canImport(StoreKit)
    private func isStoreKitPremiumEntitlementOwnedByCurrentUser(_ transaction: Transaction) -> Bool {
        guard let rawUserId = try? keychain.get(.userId) else { return true }
        let normalizedUserId = rawUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentUserId = UUID(uuidString: normalizedUserId) else { return true }

        guard let appAccountToken = transaction.appAccountToken else {
            // Achats legacy/non attribués: ils restent restaurables, puis le backend
            // verrouille la transaction au premier compte app qui la revendique.
            return true
        }

        return appAccountToken == currentUserId
    }
    #endif

    private func isAuthFailure(_ error: Error) -> Bool {
        if case APIError.unauthorized = error { return true }
        if case APIError.forbidden = error { return true }
        if case APIError.requestFailed(let code, _) = error, code == 401 { return true }
        return false
    }

    private func looksLikeJWT(_ token: String) -> Bool {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty }
    }

    private func shouldRollbackOptimisticPremiumUpdate(isPremium: Bool, after error: Error) -> Bool {
        guard isPremium else { return true }

        switch error {
        case APIError.badRequest,
             APIError.unauthorized,
             APIError.forbidden,
             APIError.notFound,
             APIError.conflict,
             APIError.unprocessable:
            return true
        case APIError.requestFailed(let code, _):
            return (400...499).contains(code)
        default:
            return false
        }
    }

    private func appliedLocalPremiumState(
        to user: User,
        isPremium: Bool,
        sourceProductID: String?
    ) -> User {
        var updated = user
        updated.isPremium = isPremium

        guard isPremium else {
            updated.status = "free"
            updated.statusId = 1
            return updated
        }

        if isMonthlyPremiumProduct(sourceProductID) {
            updated.status = "paid_monthly"
            updated.statusId = 2
        } else {
            updated.status = "paid_lifetime"
            updated.statusId = 3
        }
        return updated
    }

    private func isMonthlyPremiumProduct(_ productID: String?) -> Bool {
        guard let productID else { return false }
        let normalized = productID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == AppConfig.premiumMonthlyProductID.lowercased() {
            return true
        }
        return normalized.contains("monthly") || normalized.contains("month")
    }

    private func cacheUser(_ user: User) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        defaults.set(data, forKey: cachedUserKey)
    }

    private func loadCachedUser() -> User? {
        guard let data = defaults.data(forKey: cachedUserKey) else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    private func clearCachedUser() {
        defaults.removeObject(forKey: cachedUserKey)
    }

    private func trackMetric(_ key: String) {
        let fullKey = "parkspot.metrics.auth.\(key)"
        defaults.set(defaults.integer(forKey: fullKey) + 1, forKey: fullKey)
    }

    #if DEBUG
    private func localDebugAuth(email: String, displayName: String) throws -> User {
        guard AppConfig.allowLocalDebugAuthFallback else {
            logger.fault("Tentative d'auth debug locale bloquée (flag désactivé)")
            assertionFailure("localDebugAuth appelé sans PARKSPOT_ALLOW_LOCAL_DEBUG_AUTH=true")
            throw APIError.forbidden
        }

        let user = User(email: email, displayName: displayName)
        // Ne jamais stocker de faux tokens: ils provoquent des erreurs backend
        // du type "unsupported JWT" dès qu'un endpoint protégé est appelé.
        try? keychain.delete(.authToken)
        try? keychain.delete(.refreshToken)
        try? keychain.set(user.id.uuidString, for: .userId)
        userSubject.send(user)
        logger.notice("Session debug locale créée pour \(email, privacy: .private(mask: .hash))")
        return user
    }
    #endif
}
