import Foundation
import CryptoKit
import OSLog
import Security

enum HTTPMethod: String {
    case get    = "GET"
    case post   = "POST"
    case put    = "PUT"
    case patch  = "PATCH"
    case delete = "DELETE"
}

struct Endpoint {
    let path: String
    let method: HTTPMethod
    var queryItems: [URLQueryItem]?
    var body: Encodable?
    var requiresAuth: Bool = true
}
