import Foundation
import Combine
import CoreLocation

protocol ParkingRepositoryProtocol {
    /// Save a new or updated parking session (offline-first)
    func save(_ session: ParkingSession) async throws -> ParkingSession
    /// Fetch the current active session for a user
    func fetchActiveSession(for userId: UUID, forceLocal: Bool) async throws -> ParkingSession?
    /// Fetch all sessions (paginated) for history
    func fetchHistory(for userId: UUID, limit: Int, offset: Int) async throws -> [ParkingSession]
    /// Mark a session as ended
    func endSession(id: UUID) async throws -> ParkingSession
    /// Hard-delete – RGPD right to erasure
    func delete(id: UUID) async throws
    /// Delete ALL data for a user – RGPD Article 17
    func deleteAllData(for userId: UUID) async throws
}
