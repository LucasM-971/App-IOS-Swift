// PhotoStorageService.swift
// Encrypts photos with AES-256-GCM before writing to disk
// Stored in Application Support (not in Photos library, not backed up)

import Foundation

final class PhotoStorageService: PhotoStorageProtocol {

    private let encryption: EncryptionService
    private let directory: URL

    init(encryption: EncryptionService) {
        self.encryption = encryption
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.directory = support.appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: – Save encrypted photo, return relative path
    func save(imageData: Data, for sessionId: UUID) async throws -> String {
        let fileName  = "\(sessionId.uuidString).enc"
        let fileURL   = directory.appendingPathComponent(fileName)
        let encrypted = try encryption.encrypt(imageData)
        try encrypted.write(to: fileURL, options: [.atomic, .completeFileProtection])
        excludeFromBackup(url: fileURL)
        return fileName
    }

    // MARK: – Load and decrypt
    func load(path: String) async throws -> Data {
        let fileURL   = directory.appendingPathComponent(path)
        let encrypted = try Data(contentsOf: fileURL)
        return try encryption.decrypt(encrypted)
    }

    // MARK: – Delete photo
    func delete(path: String) async throws {
        let fileURL = directory.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func excludeFromBackup(url: URL) {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)
    }
}
