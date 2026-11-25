// AuthView.swift
import SwiftUI
import Combine
import AuthenticationServices
import CryptoKit
import Security
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class AuthViewModel: ObservableObject {
    enum Mode { case signIn, signUp }

    @Published var mode: Mode        = .signIn
    @Published var email             = ""
    @Published var password          = ""
    @Published var displayName       = ""
    @Published var confirmPassword   = ""
    @Published var gdprAccepted      = false
    @Published var isLoading         = false
    @Published var error: String?
    @Published var requiresEmailConfirmation = false
    @Published var confirmationEmail = ""
    @Published var verificationCode  = ""

    private let authRepo: AuthRepositoryProtocol
    private let appleWebAuthenticator = AppleWebOAuthAuthenticator()
    private var currentAppleNonce: String?

    init(authRepo: AuthRepositoryProtocol) {
        self.authRepo = authRepo
    }

    convenience init() {
        self.init(authRepo: DIContainer.shared.authRepository)
    }

    var canSubmit: Bool {
        let cleanDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .signIn:  return !email.isEmpty && password.count >= 8
        case .signUp:  return !email.isEmpty && cleanDisplayName.count >= 2 && cleanDisplayName.count <= 80
                           && password.count >= 8 && password == confirmPassword && gdprAccepted
        }
    }

    func submit() async -> Bool {
        error = nil
        requiresEmailConfirmation = false
        confirmationEmail = ""
        verificationCode = ""

        guard validateInputs() else {
            return false
        }

        isLoading = true
        defer { isLoading = false }
        do {
            switch mode {
            case .signIn: _ = try await authRepo.signIn(email: email, password: password)
            case .signUp: _ = try await authRepo.signUp(email: email, password: password, displayName: displayName)
            }
            return true
        } catch let authError as AuthRepositoryError {
            switch authError {
            case .emailConfirmationRequired(let targetEmail):
                password = ""
                confirmPassword = ""
                requiresEmailConfirmation = true
                confirmationEmail = targetEmail
                return false
            }
        } catch {
            requiresEmailConfirmation = false
            confirmationEmail = ""
            self.error = error.localizedDescription
            return false
        }
    }

    func confirmSignUp() async -> Bool {
        error = nil
        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await authRepo.confirmSignUp(email: confirmationEmail, code: verificationCode)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        error = nil
        requiresEmailConfirmation = false
        confirmationEmail = ""

        let nonce = Self.generateSecureNonce()
        currentAppleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func handleAppleSignInCompletion(_ result: Result<ASAuthorization, Error>) async -> Bool {
        error = nil
        isLoading = true
        defer {
            isLoading = false
            currentAppleNonce = nil
        }

        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                throw AppleNativeSignInError.invalidCredential
            }

            guard let nonce = currentAppleNonce else {
                throw AppleNativeSignInError.invalidState
            }

            guard
                let identityTokenData = credential.identityToken,
                let identityToken = String(data: identityTokenData, encoding: .utf8),
                !identityToken.isEmpty
            else {
                throw AppleNativeSignInError.missingIdentityToken
            }

            _ = try await authRepo.signInWithApple(
                idToken: identityToken,
                nonce: nonce
            )

            if let nextDisplayName = appleDisplayName(from: credential), nextDisplayName.count >= 2 {
                _ = try? await authRepo.updateDisplayName(nextDisplayName)
            }

            return true
        } catch {
            do {
                if try await fallbackToAppleWebOAuthIfNeeded(after: error) {
                    return true
                }
            } catch {
                self.error = Self.mapAppleWebOAuthError(error).localizedDescription
                return false
            }

            self.error = Self.mapAppleSignInError(error).localizedDescription
            return false
        }
    }

    private func validateInputs() -> Bool {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName  = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .signIn:
            if cleanEmail.isEmpty {
                error = "Please enter your email.".psLocalized
                return false
            }
            if password.isEmpty {
                error = "Please enter your password.".psLocalized
                return false
            }
            return true

        case .signUp:
            if cleanName.isEmpty {
                error = "Please enter your first name.".psLocalized
                return false
            }
            if cleanName.count < 2 || cleanName.count > 80 {
                error = "First name must contain between 2 and 80 characters.".psLocalized
                return false
            }
            if cleanEmail.isEmpty {
                error = "Please enter your email.".psLocalized
                return false
            }
            if password.count < 8 {
                error = "Password must contain at least 8 characters.".psLocalized
                return false
            }
            if password != confirmPassword {
                error = "Passwords do not match.".psLocalized
                return false
            }
            if !gdprAccepted {
                error = "Please accept the privacy policy.".psLocalized
                return false
            }
            return true
        }
    }

    private func appleDisplayName(from credential: ASAuthorizationAppleIDCredential) -> String? {
        let formatter = PersonNameComponentsFormatter()
        let name = formatter.string(from: credential.fullName ?? PersonNameComponents())
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !name.isEmpty {
            return name
        }

        let typedName = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if mode == .signUp, typedName.count >= 2 {
            return typedName
        }

        return nil
    }

    private func fallbackToAppleWebOAuthIfNeeded(after error: Error) async throws -> Bool {
        guard Self.shouldFallbackToAppleWebOAuth(for: error) else {
            return false
        }

        let tokens = try await appleWebAuthenticator.authenticate()
        _ = try await authRepo.signInWithOAuthTokens(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken
        )

        let typedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .signUp, typedName.count >= 2 {
            _ = try? await authRepo.updateDisplayName(typedName)
        }

        return true
    }

    private static func mapAppleSignInError(_ error: Error) -> Error {
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled:
                return AppleNativeSignInError.cancelled
            case .invalidResponse:
                return AppleNativeSignInError.invalidCredential
            case .notInteractive:
                return AppleNativeSignInError.unavailable
            default:
                return AppleNativeSignInError.failed
            }
        }

        if case APIError.badRequest(let message) = error {
            let lowered = (message ?? "").lowercased()
            if lowered.contains("provider is not enabled") || lowered.contains("unsupported provider") {
                return AppleNativeSignInError.providerNotEnabled
            }
            if lowered.contains("nonce") {
                return AppleNativeSignInError.invalidState
            }
        }

        return error
    }

    static func shouldFallbackToAppleWebOAuth(for error: Error) -> Bool {
        if case APIError.notFound = error {
            return true
        }

        if case APIError.requestFailed(let code, _) = error, code == 404 {
            return true
        }

        if case APIError.badRequest(let message) = error,
           shouldFallbackToAppleWebOAuth(forBackendMessage: message) {
            return true
        }

        if case APIError.requestFailed(_, let message) = error,
           shouldFallbackToAppleWebOAuth(forBackendMessage: message) {
            return true
        }

        return false
    }

    private static func shouldFallbackToAppleWebOAuth(forBackendMessage message: String?) -> Bool {
        let lowered = (message ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !lowered.isEmpty else { return false }

        return lowered.contains("unsupported jwt algorithm")
            || lowered.contains("unsupported algorithm es256")
            || lowered.contains("unsupported jwt algirithme es256")
            || (lowered.contains("es256") && lowered.contains("jwt"))
            || (lowered.contains("es256") && lowered.contains("algorithm"))
            || (lowered.contains("es256") && lowered.contains("algorithme"))
    }

    private static func mapAppleWebOAuthError(_ error: Error) -> Error {
        if let sessionError = error as? ASWebAuthenticationSessionError {
            switch sessionError.code {
            case .canceledLogin:
                return AppleWebOAuthError.cancelled
            case .presentationContextNotProvided, .presentationContextInvalid:
                return AppleWebOAuthError.unavailable
            default:
                return AppleWebOAuthError.failed
            }
        }

        if case APIError.badRequest(let message) = error {
            let lowered = (message ?? "").lowercased()
            if lowered.contains("provider is not enabled") || lowered.contains("unsupported provider") {
                return AppleWebOAuthError.providerNotEnabled
            }
        }

        return error
    }

    private static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func generateSecureNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)

        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }

        return bytes.map { charset[Int($0) % charset.count] }.map(String.init).joined()
    }
}

private enum AppleNativeSignInError: LocalizedError {
    case invalidCredential
    case invalidState
    case missingIdentityToken
    case providerNotEnabled
    case unavailable
    case cancelled
    case failed

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "Invalid Apple response.".psLocalized
        case .invalidState:
            return "Apple security verification failed.".psLocalized
        case .missingIdentityToken:
            return "Unable to retrieve the Apple token.".psLocalized
        case .providerNotEnabled:
            return "Sign in with Apple is not enabled on the server.".psLocalized
        case .unavailable:
            return "Sign in with Apple is currently unavailable.".psLocalized
        case .cancelled:
            return "Sign-in was cancelled.".psLocalized
        case .failed:
            return "Unable to sign in with Apple.".psLocalized
        }
    }
}

private struct AppleOAuthTokens {
    let accessToken: String
    let refreshToken: String?
}

private enum AppleWebOAuthError: LocalizedError {
    case invalidAuthorizeURL
    case invalidCallback
    case invalidState
    case missingAccessToken
    case providerNotEnabled
    case sessionAlreadyRunning
    case unavailable
    case cancelled
    case failed

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizeURL:
            return "Invalid Apple configuration.".psLocalized
        case .invalidCallback:
            return "Invalid OAuth callback.".psLocalized
        case .invalidState:
            return "OAuth security verification failed.".psLocalized
        case .missingAccessToken:
            return "Unable to complete social sign-in.".psLocalized
        case .providerNotEnabled:
            return "Sign in with Apple is not enabled on the server.".psLocalized
        case .sessionAlreadyRunning:
            return "An Apple sign-in is already in progress.".psLocalized
        case .unavailable:
            return "Sign in with Apple is currently unavailable.".psLocalized
        case .cancelled:
            return "Sign-in was cancelled.".psLocalized
        case .failed:
            return "Unable to sign in with Apple.".psLocalized
        }
    }
}

@MainActor
private final class AppleWebOAuthAuthenticator: NSObject {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<AppleOAuthTokens, Error>?

    func authenticate() async throws -> AppleOAuthTokens {
        guard continuation == nil, session == nil else {
            throw AppleWebOAuthError.sessionAlreadyRunning
        }

        let state = AuthViewModel.generateSecureNonce()
        let authorizeURL = try Self.makeAuthorizeURL(state: state)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: AppConfig.oauthCallbackScheme
            ) { callbackURL, error in
                if let error {
                    self.resolveAuthentication(with: .failure(error))
                    return
                }

                guard let callbackURL else {
                    self.resolveAuthentication(with: .failure(AppleWebOAuthError.invalidCallback))
                    return
                }

                do {
                    let tokens = try Self.parseTokens(from: callbackURL, expectedState: state)
                    self.resolveAuthentication(with: .success(tokens))
                } catch {
                    self.resolveAuthentication(with: .failure(error))
                }
            }

            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.session = session

            guard session.start() else {
                self.resolveAuthentication(with: .failure(AppleWebOAuthError.unavailable))
                return
            }
        }
    }

    private func resolveAuthentication(with result: Result<AppleOAuthTokens, Error>) {
        let continuation = takeContinuation()
        session = nil

        guard let continuation else { return }

        switch result {
        case .success(let tokens):
            continuation.resume(returning: tokens)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func takeContinuation() -> CheckedContinuation<AppleOAuthTokens, Error>? {
        let continuation = continuation
        self.continuation = nil
        return continuation
    }

    private static func makeAuthorizeURL(state: String) throws -> URL {
        guard var components = URLComponents(string: AppConfig.apiBaseURL) else {
            throw AppleWebOAuthError.invalidAuthorizeURL
        }

        components.path = "/auth/v1/authorize"
        components.queryItems = [
            URLQueryItem(name: "provider", value: "apple"),
            URLQueryItem(name: "redirect_to", value: AppConfig.oauthCallbackURL),
            URLQueryItem(name: "state", value: state),
        ]

        guard let authorizeURL = components.url else {
            throw AppleWebOAuthError.invalidAuthorizeURL
        }

        return authorizeURL
    }

    private static func parseTokens(from callbackURL: URL, expectedState: String) throws -> AppleOAuthTokens {
        let params = extractParams(from: callbackURL)

        guard params["state"] == expectedState else {
            throw AppleWebOAuthError.invalidState
        }

        let errorDetails = [
            params["error"],
            params["error_description"],
            params["errorCode"],
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !errorDetails.isEmpty {
            if errorDetails.lowercased().contains("provider") {
                throw AppleWebOAuthError.providerNotEnabled
            }
            throw AppleWebOAuthError.failed
        }

        guard let accessToken = params["access_token"], !accessToken.isEmpty else {
            throw AppleWebOAuthError.missingAccessToken
        }

        let refreshToken = params["refresh_token"]?.nilIfEmpty
        return AppleOAuthTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    private static func extractParams(from callbackURL: URL) -> [String: String] {
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
}

extension AppleWebOAuthAuthenticator: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

        if let window = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) {
            return window
        }

        guard let fallbackScene = scenes.first else {
            preconditionFailure("Aucune UIWindowScene disponible pour presenter Apple OAuth.")
        }

        return UIWindow(windowScene: fallbackScene)
#elseif canImport(AppKit)
        if let keyWindow = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            return keyWindow
        }

        if let firstWindow = NSApplication.shared.windows.first {
            return firstWindow
        }

        return ASPresentationAnchor()
#else
        preconditionFailure("No presentation anchor available on this platform.")
#endif
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        return value
    }
}
 
