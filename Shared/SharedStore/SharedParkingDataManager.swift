// SharedParkingDataManager.swift
// Partage de la session active entre l'app et les widgets via l'App Group.
// Compilé dans les cibles ParkSpot et ParkSpotWidgets.
// Les méthodes propres à l'app (session anonyme) sont dans
// ParkSpot/Platform/Storage/SharedParkingDataManager+AnonymousSession.swift.

import Foundation
import CryptoKit

final class SharedParkingDataManager {
    static let shared = SharedParkingDataManager()

    private let appGroupIdentifier = "group.com.parkspot.app"
    private let sessionDataKey = "parkspot_active_session"
    private let encryptionKeyKey = "parkspot_encryption_key"

    private init() {}

    // MARK: - Public API

    func saveActiveSession(_ session: SharedParkingSession) {
        do {
            let encoded = try JSONEncoder().encode(session)
            let encrypted = try encryptData(encoded)

            if let userDefaults = UserDefaults(suiteName: appGroupIdentifier) {
                userDefaults.set(encrypted, forKey: sessionDataKey)
            }
        } catch {
            print("[SharedParkingDataManager] Failed to save session: \(error)")
        }
    }

    func loadActiveSession() -> SharedParkingSession? {
        guard let userDefaults = UserDefaults(suiteName: appGroupIdentifier),
              let encrypted = userDefaults.data(forKey: sessionDataKey) else {
            return nil
        }

        do {
            let decrypted = try decryptData(encrypted)
            let session = try JSONDecoder().decode(SharedParkingSession.self, from: decrypted)

            // Validate session is still active
            if !session.hasTimer || session.endDate > Date() {
                return session
            } else {
                clearActiveSession()
                return nil
            }
        } catch {
            print("[SharedParkingDataManager] Failed to load session: \(error)")
            return nil
        }
    }

    func clearActiveSession() {
        if let userDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            userDefaults.removeObject(forKey: sessionDataKey)
        }
    }

    // MARK: - Private Encryption/Decryption

    private func encryptData(_ data: Data) throws -> Data {
        let key = try getOrCreateEncryptionKey()
        let sealedBox = try AES.GCM.seal(data, using: key)

        guard let encryptedData = sealedBox.combined else {
            throw SharedParkingDataError.sealingFailed
        }

        return encryptedData
    }

    private func decryptData(_ encryptedData: Data) throws -> Data {
        let key = try getOrCreateEncryptionKey()
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // TODO(sécurité): la clé est stockée dans le même UserDefaults que les données.
    // À migrer vers un Keychain partagé (kSecAttrAccessGroup).
    private func getOrCreateEncryptionKey() throws -> SymmetricKey {
        let userDefaults = UserDefaults(suiteName: appGroupIdentifier)

        if let keyData = userDefaults?.data(forKey: encryptionKeyKey) {
            return SymmetricKey(data: keyData)
        } else {
            let newKey = SymmetricKey(size: .bits256)
            userDefaults?.set(newKey.withUnsafeBytes { Data($0) }, forKey: encryptionKeyKey)
            return newKey
        }
    }
}

private enum SharedParkingDataError: LocalizedError {
    case sealingFailed
    case openingFailed

    var errorDescription: String? {
        switch self {
        case .sealingFailed:
            return NSLocalizedString("Échec du chiffrement des données", comment: "")
        case .openingFailed:
            return NSLocalizedString("Échec du déchiffrement des données", comment: "")
        }
    }
}
