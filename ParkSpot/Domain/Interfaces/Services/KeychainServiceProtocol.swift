import Foundation
import Combine
import CoreLocation

nonisolated protocol KeychainServiceProtocol {
    func set(_ value: String, for key: KeychainKey) throws
    func get(_ key: KeychainKey) throws -> String
    func delete(_ key: KeychainKey) throws
    func clearAll() throws
}

nonisolated enum KeychainKey: String, CaseIterable {
    case authToken        = "ps.auth.token"
    case refreshToken     = "ps.auth.refresh"
    case encryptionKey    = "ps.data.encryptionKey"
    case userId           = "ps.user.id"
}
