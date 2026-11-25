import XCTest
@testable import ParkSpot

final class Phase1SecurityTests: XCTestCase {
    func testAvailableAppLanguagesAreLimitedToCurrentProductLanguages() {
        let languageCodes = Set(AppLanguage.allCases.map(\.rawValue))

        XCTAssertEqual(languageCodes, ["system", "english", "french", "german", "spanish"])
    }

    func testFreshInstallLanguageDefaultsUseAutomaticWithoutOverride() {
        let suiteName = "Phase1SecurityTests.language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppLanguage.seedAutomaticDefaultsForFreshInstall(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: AppLanguage.defaultsLanguageKey),
            AppLanguage.system.rawValue
        )
        XCTAssertEqual(defaults.bool(forKey: AppLanguage.defaultsUserOverrideEnabledKey), false)
    }

    func testSystemPreferredLocaleIdentifierUsesFirstSupportedSystemLanguage() {
        let resolved = AppLanguage.systemPreferredLocaleIdentifier(
            preferredLanguageIdentifiers: ["it-IT", "de-DE", "fr-FR"]
        )

        XCTAssertEqual(resolved, "de")
    }

    func testSystemPreferredLocaleIdentifierFallsBackToEnglishWhenNoSupportedLanguageExists() {
        let resolved = AppLanguage.systemPreferredLocaleIdentifier(
            preferredLanguageIdentifiers: ["it-IT", "nl-NL"]
        )

        XCTAssertEqual(resolved, "en")
    }

    func testRuntimeLocaleIdentifierPreservesSystemRegionForOverrideLanguage() {
        let resolved = AppLanguage.runtimeLocaleIdentifier(
            for: "en",
            systemLocaleIdentifier: "fr_FR"
        )
        let locale = Locale(identifier: resolved)

        XCTAssertEqual(locale.language.languageCode?.identifier, "en")
        XCTAssertEqual(locale.region?.identifier, "FR")
    }

    func testSystemResolvedLocaleIdentifierUsesSupportedLanguageAndSystemRegion() {
        let defaults = UserDefaults(suiteName: "Phase1SecurityTests.locale.\(UUID().uuidString)")!
        defer {
            defaults.removePersistentDomain(forName: UserDefaults.globalDomain)
        }
        defaults.setPersistentDomain(["AppleLocale": "de_DE"], forName: UserDefaults.globalDomain)

        let resolved = AppLanguage.systemResolvedLocaleIdentifier(
            preferredLanguageIdentifiers: ["pt-PT", "es-ES"],
            defaults: defaults
        )
        let locale = Locale(identifier: resolved)

        XCTAssertEqual(locale.language.languageCode?.identifier, "es")
        XCTAssertEqual(locale.region?.identifier, "DE")
    }

    func testRuntimeLocaleIdentifierPreservesRegionForSupportedLanguage() {
        let resolved = AppLanguage.runtimeLocaleIdentifier(
            for: "es",
            systemLocaleIdentifier: "fr_FR"
        )
        let locale = Locale(identifier: resolved)

        XCTAssertEqual(locale.language.languageCode?.identifier, "es")
        XCTAssertEqual(locale.region?.identifier, "FR")
    }

    func testNormalizeHashRemovesSeparatorsAndLowercases() {
        let raw = "AA:BB:CC:DD"
        let normalized = NetworkClient.normalizeHash(raw)
        XCTAssertEqual(normalized, "aabbccdd")
    }

    func testAuthRepositoryErrorContainsEmailWhenProvided() {
        let err = AuthRepositoryError.emailConfirmationRequired(email: "john@doe.com")
        XCTAssertTrue(err.localizedDescription.contains("john@doe.com"))
    }

    func testPasswordResetThrottleReturnsTrueWithinCooldown() {
        let shouldThrottle = AuthRepository.shouldThrottlePasswordReset(
            now: 1_000,
            lastAttempt: 980,
            cooldown: 30
        )

        XCTAssertTrue(shouldThrottle)
    }

    func testPasswordResetThrottleReturnsFalseOutsideCooldown() {
        let shouldThrottle = AuthRepository.shouldThrottlePasswordReset(
            now: 1_000,
            lastAttempt: 960,
            cooldown: 30
        )

        XCTAssertFalse(shouldThrottle)
    }

    func testLocalParkingDataSourceRecoversWhenEncryptedStoreCannotBeDecrypted() throws {
        let keychain = MockKeychain()
        let encryption = EncryptionService(keychain: keychain)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParkSpotTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: root) }

        let corruptedStoreURL = root.appendingPathComponent("parkspot.db.json")
        try Data("not-an-encrypted-payload".utf8).write(to: corruptedStoreURL)

        do {
            let sut = LocalParkingDataSource(encryption: encryption, rootDirectory: root)
            let record = LocalParkingRecord(
                id: UUID().uuidString,
                userId: UUID().uuidString,
                latitude: 48.8566,
                longitude: 2.3522,
                encryptedAddress: nil,
                encryptedNote: nil,
                parkingLevel: "B2",
                zone: ParkingZone.unknown.rawValue,
                startTime: Date(timeIntervalSince1970: 1_710_000_000),
                endTime: nil,
                maxDuration: nil,
                photoPath: nil,
                isApproximate: false,
                isSynced: false
            )

            XCTAssertNoThrow(try sut.save(record))
            let fetched = try XCTUnwrap(try sut.fetchById(record.id))
            XCTAssertEqual(fetched.id, record.id)
            XCTAssertEqual(fetched.userId, record.userId)
        }
    }

    @MainActor
    func testAppleNativeSignInFallsBackToWebOAuthForUnsupportedJWTAlgorithmMessage() {
        let shouldFallback = AuthViewModel.shouldFallbackToAppleWebOAuth(
            for: APIError.badRequest("Unsupported JWT algorithm ES256")
        )

        XCTAssertTrue(shouldFallback)
    }

    @MainActor
    func testAppleNativeSignInFallsBackToWebOAuthForRequestFailedJWTAlgorithmMessage() {
        let shouldFallback = AuthViewModel.shouldFallbackToAppleWebOAuth(
            for: APIError.requestFailed(400, "Unsupported JWT algorithm ES256")
        )

        XCTAssertTrue(shouldFallback)
    }
}
