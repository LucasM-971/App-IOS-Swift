import Foundation
import Combine

final class DeleteUserDataUseCase {
    private let parkingRepo: ParkingRepositoryProtocol
    private let authRepo: AuthRepositoryProtocol
    private let keychain: KeychainServiceProtocol
    private let photoStorage: PhotoStorageProtocol

    init(
        parkingRepo: ParkingRepositoryProtocol,
        authRepo: AuthRepositoryProtocol,
        keychain: KeychainServiceProtocol,
        photoStorage: PhotoStorageProtocol
    ) {
        self.parkingRepo = parkingRepo
        self.authRepo = authRepo
        self.keychain = keychain
        self.photoStorage = photoStorage
    }

    /// Full account + data deletion – RGPD Article 17
    func execute(userId: UUID) async throws {
        // Try full remote deletion first.
        do {
            try await parkingRepo.deleteAllData(for: userId)
            try await authRepo.deleteAccount()
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                print("[DeleteUserDataUseCase] Remote delete failed: \(error.localizedDescription)")
            }
        }

        // Always clear local auth/session state so the button is functional in-app.
        try? await authRepo.signOut()
        try keychain.clearAll()
    }
}
