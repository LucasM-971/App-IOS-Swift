import Foundation
import CryptoKit
import OSLog
import Security

enum APIError: LocalizedError {
    case invalidURL
    case badRequest(String?)
    case unauthorized          // 401 – triggers token refresh
    case forbidden             // 403
    case notFound              // 404
    case conflict(String?)
    case unprocessable(String?)
    case requestFailed(Int, String?)
    case serverError(Int)      // 5xx
    case decodingFailed(Error)
    case networkUnavailable
    case hostNotFound
    case cannotConnectHost
    case requestTimedOut
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:             return "Invalid URL.".psLocalized
        case .badRequest(let message):
            return message?.isEmpty == false ? message : "Invalid request.".psLocalized
        case .unauthorized:           return "Session expired - please sign in again.".psLocalized
        case .forbidden:              return "Access denied.".psLocalized
        case .notFound:               return "Resource not found.".psLocalized
        case .conflict(let message):
            return message?.isEmpty == false ? message : "Data conflict.".psLocalized
        case .unprocessable(let message):
            return message?.isEmpty == false ? message : "Invalid data.".psLocalized
        case .requestFailed(let code, let message):
            if let message, !message.isEmpty { return message }
            return String(format: "Request error (%d).".psLocalized, code)
        case .serverError(let c):     return String(format: "Server error (%d).".psLocalized, c)
        case .decodingFailed(let e):  return String(format: "Decoding error: %@".psLocalized, e.localizedDescription)
        case .networkUnavailable:     return "No internet connection.".psLocalized
        case .hostNotFound:           return String(format: "Server not found. Check the API URL: %@".psLocalized, AppConfig.apiBaseURL)
        case .cannotConnectHost:      return "Unable to reach the server.".psLocalized
        case .requestTimedOut:        return "The server is taking too long to respond.".psLocalized
        case .unknown(let e):         return e.localizedDescription
        }
    }
}
