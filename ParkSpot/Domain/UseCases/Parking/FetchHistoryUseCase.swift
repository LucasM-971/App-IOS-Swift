import Foundation
import Combine

final class FetchHistoryUseCase {
    private let parkingRepo: ParkingRepositoryProtocol

    init(parkingRepo: ParkingRepositoryProtocol) {
        self.parkingRepo = parkingRepo
    }

    func execute(userId: UUID, page: Int = 0, pageSize: Int = 20) async throws -> [ParkingSession] {
        try await parkingRepo.fetchHistory(for: userId, limit: pageSize, offset: page * pageSize)
    }
}
