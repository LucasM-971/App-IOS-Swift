import XCTest

final class MockKeychain: KeychainServiceProtocol {
    private var store: [KeychainKey: String] = [:]

    func set(_ value: String, for key: KeychainKey) throws {
        store[key] = value
    }

    func get(_ key: KeychainKey) throws -> String {
        guard let value = store[key] else {
            throw APIError.notFound
        }
        return value
    }

    func delete(_ key: KeychainKey) throws {
        store.removeValue(forKey: key)
    }

    func clearAll() throws {
        store.removeAll()
    }
}
