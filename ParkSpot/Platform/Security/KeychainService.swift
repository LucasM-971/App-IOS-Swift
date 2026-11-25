// KeychainService.swift
import Foundation
import Security

nonisolated enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedData
    case unhandledError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Keychain item not found.".psLocalized
        case .unexpectedData:
            return "Unexpected Keychain data format.".psLocalized
        case .unhandledError(let s):
            return String(format: "Keychain OSStatus: %@".psLocalized, "\(s)")
        }
    }
}

nonisolated final class KeychainService: KeychainServiceProtocol {

    private let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    func set(_ value: String, for key: KeychainKey) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.unexpectedData }
        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        let status = SecItemUpdate(baseQuery(for: key) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandledError(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unhandledError(status)
        }
    }

    func get(_ key: KeychainKey) throws -> String {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.itemNotFound }
        guard status == errSecSuccess      else { throw KeychainError.unhandledError(status) }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw KeychainError.unexpectedData }
        return value
    }

    func delete(_ key: KeychainKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound
        else { throw KeychainError.unhandledError(status) }
    }

    func clearAll() throws {
        for key in KeychainKey.allCases { try delete(key) }
    }

    private func baseQuery(for key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    "com.parkspot.app",
            kSecAttrAccount as String:    key.rawValue,
            kSecAttrAccessible as String: accessibility
        ]
    }
}
// NOTE: CaseIterable est declare directement sur l'enum KeychainKey dans Interfaces.swift
