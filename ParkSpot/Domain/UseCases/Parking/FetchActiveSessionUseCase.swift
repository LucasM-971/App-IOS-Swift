import Foundation
import Combine

final class FetchActiveSessionUseCase {
    private let parkingRepo: ParkingRepositoryProtocol

    init(parkingRepo: ParkingRepositoryProtocol) {
        self.parkingRepo = parkingRepo
    }

    func execute(userId: UUID, forceLocal: Bool = false) async throws -> ParkingSession? {
        try await parkingRepo.fetchActiveSession(for: userId, forceLocal: forceLocal)
    }
}
