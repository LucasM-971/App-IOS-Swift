// EncryptionService.swift
// AES-256-GCM encryption for local files and sensitive fields
// Uses CryptoKit (iOS 13+) – no third-party dependency

import Foundation
import CryptoKit

nonisolated enum EncryptionError: LocalizedError {
    case keyGenerationFailed
    case encryptionFailed
    case decryptionFailed
    case invalidKeyData

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Impossible de générer la clé de chiffrement.".psLocalized
        case .encryptionFailed:
            return "Échec du chiffrement des données.".psLocalized
        case .decryptionFailed:
            return "Échec du déchiffrement – données corrompues ou clé invalide.".psLocalized
        case .invalidKeyData:
            return "Données de clé invalides.".psLocalized
        }
    }
}

nonisolated final class EncryptionService {

    private let keychain: KeychainServiceProtocol

    init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
    }

    // MARK: – Encrypt
    func encrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateKey()
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else { throw EncryptionError.encryptionFailed }
            return combined
        } catch {
            throw EncryptionError.encryptionFailed
        }
    }

    // MARK: – Decrypt
    func decrypt(_ data: Data) throws -> Data {
        guard data.count >= 28 else {
            throw EncryptionError.decryptionFailed
        }

        let key = try getOrCreateKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw EncryptionError.decryptionFailed
        }
    }

    // MARK: – Encrypt String
    func encrypt(_ string: String) throws -> Data {
        guard let data = string.data(using: .utf8) else { throw EncryptionError.encryptionFailed }
        return try encrypt(data)
    }

    // MARK: – Decrypt to String
    func decryptToString(_ data: Data) throws -> String {
        let decrypted = try decrypt(data)
        guard let string = String(data: decrypted, encoding: .utf8) else {
            throw EncryptionError.decryptionFailed
        }
        return string
    }

    // MARK: – Key management
    /// Returns existing key from Keychain or generates a new one (first launch)
    private func getOrCreateKey() throws -> SymmetricKey {
        do {
            let keyString = try keychain.get(.encryptionKey)
            if let keyData = Data(base64Encoded: keyString),
               [16, 24, 32].contains(keyData.count) {
                return SymmetricKey(data: keyData)
            }

            // Legacy/corrupted key format: rotate to a valid key.
            try? keychain.delete(.encryptionKey)
            return try createAndPersistKey()
        } catch KeychainError.itemNotFound {
            return try createAndPersistKey()
        } catch APIError.notFound {
            return try createAndPersistKey()
        } catch {
            // Important: do not rotate the key on arbitrary Keychain errors,
            // otherwise encrypted local data can become unreadable.
            throw error
        }
    }

    private func createAndPersistKey() throws -> SymmetricKey {
        // Generate new 256-bit key
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try keychain.set(keyData.base64EncodedString(), for: .encryptionKey)
        return newKey
    }
}
