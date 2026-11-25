import Foundation
import CryptoKit
import OSLog
import Security

protocol NetworkRequesting {
    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T
}
