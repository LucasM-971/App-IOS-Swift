// NetworkClient.swift
// Secure HTTP client – JWT Bearer auth, automatic token refresh, SSL pinning hook

import Foundation
import CryptoKit
import OSLog
import Security

// MARK: – HTTP Method
final class NetworkClient: NSObject, NetworkRequesting {

    let logger = Logger(subsystem: "com.parkspot.app", category: "network")

    private let baseURL: URL
    private let keychain: KeychainServiceProtocol
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60
        // Disable caching of sensitive responses
        config.urlCache                   = nil
        config.requestCachePolicy         = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
        self.baseURL  = URL(string: AppConfig.apiBaseURL)!
    }

    // MARK: – Generic request
    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        do {
            return try await performRequest(endpoint)
        } catch let error as APIError where shouldAttemptTokenRefresh(for: endpoint, after: error) {
            guard await refreshAuthTokenIfPossible() else {
                clearStoredAuthSession()
                throw APIError.unauthorized
            }

            do {
                return try await performRequest(endpoint)
            } catch let retryError as APIError where isAuthFailure(retryError) {
                clearStoredAuthSession()
                throw APIError.unauthorized
            }
        }
    }

    private func performRequest<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let urlRequest = try buildRequest(endpoint)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let urlError as URLError {
            throw mapNetworkError(urlError)
        } catch {
            throw APIError.unknown(error)
        }
        try validateResponse(response, data: data)

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy  = .iso8601
            decoder.keyDecodingStrategy   = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }

    private func mapNetworkError(_ error: URLError) -> APIError {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .internationalRoamingOff,
             .dataNotAllowed,
             .cannotLoadFromNetwork:
            return .networkUnavailable
        case .cannotFindHost,
             .dnsLookupFailed:
            return .hostNotFound
        case .cannotConnectToHost:
            return .cannotConnectHost
        case .timedOut:
            return .requestTimedOut
        default:
            return .unknown(error)
        }
    }

    // MARK: – Build URLRequest
    private func buildRequest(_ endpoint: Endpoint) throws -> URLRequest {
        let normalizedPath = endpoint.path.hasPrefix("/")
            ? String(endpoint.path.dropFirst())
            : endpoint.path

        guard var components = URLComponents(url: baseURL.appendingPathComponent(normalizedPath),
                                            resolvingAgainstBaseURL: true)
        else { throw APIError.invalidURL }

        components.queryItems = endpoint.queryItems
        guard let url = components.url else { throw APIError.invalidURL }

        var request         = URLRequest(url: url)
        request.httpMethod  = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Attach Bearer token
        if endpoint.requiresAuth,
           let token = try? keychain.get(.authToken).trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Encode body
        if let body = endpoint.body {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy  = .iso8601
            encoder.keyEncodingStrategy   = .convertToSnakeCase
            request.httpBody = try encoder.encode(body)
        }

        return request
    }

    // MARK: – Validate HTTP response
    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }

        let serverMessage: String? = {
            guard
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = obj["message"] as? String,
                !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return message
        }()

        switch http.statusCode {
        case 200...299: return
        case 400:
            throw APIError.badRequest(serverMessage)
        case 401:
            if let serverMessage {
                throw APIError.requestFailed(http.statusCode, serverMessage)
            }
            throw APIError.unauthorized
        case 403:       throw APIError.forbidden
        case 404:
            if let serverMessage {
                throw APIError.requestFailed(http.statusCode, serverMessage)
            }
            throw APIError.notFound
        case 409:       throw APIError.conflict(serverMessage)
        case 422:       throw APIError.unprocessable(serverMessage)
        case 500...599:
            if let serverMessage {
                throw APIError.requestFailed(http.statusCode, serverMessage)
            }
            throw APIError.serverError(http.statusCode)
        default:        throw APIError.requestFailed(http.statusCode, serverMessage)
        }
    }

    private func shouldAttemptTokenRefresh(for endpoint: Endpoint, after error: APIError) -> Bool {
        endpoint.requiresAuth && isAuthFailure(error)
    }

    private func isAuthFailure(_ error: APIError) -> Bool {
        if case .unauthorized = error { return true }
        if case .requestFailed(let code, _) = error, code == 401 { return true }
        return false
    }

    private func refreshAuthTokenIfPossible() async -> Bool {
        guard
            let refreshToken = try? keychain.get(.refreshToken).trimmingCharacters(in: .whitespacesAndNewlines),
            !refreshToken.isEmpty
        else {
            return false
        }

        struct RefreshBody: Encodable {
            let refreshToken: String
        }

        let endpoint = Endpoint(
            path: "/auth/refresh",
            method: .post,
            body: RefreshBody(refreshToken: refreshToken),
            requiresAuth: false
        )

        do {
            let response: APIResponse<AuthResponseDTO> = try await performRequest(endpoint)
            guard looksLikeJWT(response.data.accessToken) else {
                return false
            }

            try keychain.set(response.data.accessToken, for: .authToken)
            try keychain.set(response.data.refreshToken, for: .refreshToken)
            try keychain.set(response.data.user.id, for: .userId)
            return true
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                logger.debug("Token refresh failed: \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
    }

    private func clearStoredAuthSession() {
        try? keychain.delete(.authToken)
        try? keychain.delete(.refreshToken)
        try? keychain.delete(.userId)
    }

    private func looksLikeJWT(_ token: String) -> Bool {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty }
    }

}

// MARK: – URLSessionDelegate (Certificate Pinning hook)
