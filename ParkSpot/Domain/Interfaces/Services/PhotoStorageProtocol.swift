import Foundation
import Combine
import CoreLocation

protocol PhotoStorageProtocol {
    /// Encrypt and save photo, returns local path
    func save(imageData: Data, for sessionId: UUID) async throws -> String
    /// Load and decrypt photo
    func load(path: String) async throws -> Data
    func delete(path: String) async throws
}
