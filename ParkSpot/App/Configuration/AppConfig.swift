// AppConfig.swift
// Read from Info.plist / environment – never hardcode secrets in source

import Foundation

enum AppConfig {

    private static let defaultAPIBaseURL = "https://example.invalid/functions/v1"
    private static let defaultPasswordResetRedirectURL = "parkspot://reset-password"
    private static let defaultChangeEmailRedirectURL = "parkspot://change-email"

    private static func isPlaceholderValue(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        let uppercased = trimmed.uppercased()
        return uppercased.contains("YOUR_PROJECT")
            || uppercased.contains("YOUR_SUPABASE")
            || trimmed.contains("example.invalid")
    }

    private static func configValue(_ key: String) -> String {
        if let envValue = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envValue.isEmpty,
           !isPlaceholderValue(envValue) {
            return envValue
        }

        if let plistValue = Bundle.main.infoDictionary?[key] as? String {
            let trimmed = plistValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               !trimmed.hasPrefix("$("),
               trimmed != "__UNSET__",
               !isPlaceholderValue(trimmed) {
                return trimmed
            }
        }

        return ""
    }

    private static func validatedWebURLString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host,
            !host.isEmpty
        else {
            return nil
        }

        return trimmed
    }

    private static func validatedRedirectURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.contains("://"),
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme,
            !scheme.isEmpty
        else {
            return nil
        }

        let hasDestination =
            (components.host?.isEmpty == false) ||
            !components.path.isEmpty ||
            components.queryItems?.isEmpty == false ||
            components.fragment?.isEmpty == false

        guard hasDestination else { return nil }
        return URL(string: trimmed)
    }

    private static func validatedStoreKitProductID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // App Store Connect product IDs are tokens (letters/digits/._-),
        // not pure numeric Apple IDs shown in App Store Connect UI.
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{2,}$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        let isPurelyNumeric = trimmed.range(of: #"^\d+$"#, options: .regularExpression) != nil
        guard !isPurelyNumeric else {
            return nil
        }
        return trimmed
    }

    // MARK: – API
    /// Set PARKSPOT_API_URL in scheme's environment variables or Info.plist
    static var apiBaseURL: String {
        validatedWebURLString(configValue("PARKSPOT_API_URL")) ?? defaultAPIBaseURL
    }

    /// Custom URL scheme used by OAuth callback.
    static var oauthCallbackScheme: String {
        configValue("PARKSPOT_OAUTH_CALLBACK_SCHEME").isEmpty
            ? "parkspot"
            : configValue("PARKSPOT_OAUTH_CALLBACK_SCHEME")
    }

    /// Full callback URL sent to Supabase OAuth providers.
    static var oauthCallbackURL: String {
        "\(oauthCallbackScheme)://auth-callback"
    }

    /// Redirect URL used by Supabase password recovery emails.
    static var passwordResetRedirectURL: URL {
        validatedRedirectURL(configValue("PARKSPOT_PASSWORD_RESET_REDIRECT_URL"))
            ?? URL(string: defaultPasswordResetRedirectURL)!
    }

    /// Redirect URL used by Supabase email-change confirmation links.
    static var changeEmailRedirectURL: URL {
        validatedRedirectURL(configValue("PARKSPOT_CHANGE_EMAIL_REDIRECT_URL"))
            ?? URL(string: defaultChangeEmailRedirectURL)!
    }

    /// Optional endpoint for advanced mechanic chat responses.
    /// If empty, app uses local on-device reasoning only.
    static var aiMechanicChatEndpoint: String {
        validatedWebURLString(configValue("PARKSPOT_AI_MECHANIC_ENDPOINT")) ?? ""
    }

    /// Optional bearer token for mechanic chat endpoint.
    static var aiMechanicChatAPIKey: String {
        configValue("PARKSPOT_AI_MECHANIC_API_KEY")
    }

    /// Optional external provider endpoint for full vehicle history reports
    /// (carVertical-style aggregator via your backend/proxy).
    static var vehicleHistoryProviderEndpoint: String {
        validatedWebURLString(configValue("PARKSPOT_VEHICLE_HISTORY_ENDPOINT")) ?? ""
    }

    /// Optional API key for external vehicle history provider.
    static var vehicleHistoryProviderAPIKey: String {
        configValue("PARKSPOT_VEHICLE_HISTORY_API_KEY")
    }

    /// Safety switch: keep false for real backend testing/release.
    /// Set to true only for explicit offline auth debug scenarios.
    static var allowLocalDebugAuthFallback: Bool {
        #if DEBUG
        return Bundle.main.infoDictionary?["PARKSPOT_ALLOW_LOCAL_DEBUG_AUTH"] as? Bool ?? false
        #else
        return false
        #endif
    }

    // MARK: – Maps
    static var googleMapsAPIKey: String {
        configValue("GOOGLE_MAPS_API_KEY")
    }

    // MARK: – Premium (StoreKit)
    static var premiumMonthlyProductID: String {
        let value = configValue("PARKSPOT_PREMIUM_MONTHLY_PRODUCT_ID")
        return validatedStoreKitProductID(value) ?? "com.mosimap.premium.monthly"
    }

    static var premiumLifetimeProductID: String {
        let value = configValue("PARKSPOT_PREMIUM_LIFETIME_PRODUCT_ID")
        return validatedStoreKitProductID(value) ?? "com.mosimap.premium.lifetime"
    }

    static var premiumProductIDs: Set<String> {
        Set([premiumMonthlyProductID, premiumLifetimeProductID])
    }

    // MARK: – Feature Flags
    static var isDebugLoggingEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: – Transport Security
    /// Comma-separated list of hosts that must be TLS pinned.
    /// Example: "api.parkspot.app,YOUR_PROJECT.supabase.co"
    static var tlsPinnedHosts: [String] {
        let configured = configValue("PARKSPOT_TLS_PINNED_HOSTS")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        if !configured.isEmpty {
            return Array(Set(configured))
        }

        let fallbackHosts = [
            URL(string: apiBaseURL)?.host?.lowercased()
        ].compactMap { $0 }

        return Array(Set(fallbackHosts))
    }

    /// Comma-separated SHA-256 hashes (hex) of DER certificates.
    /// Example: "ab12...,cd34..."
    static var tlsPinnedCertificateSHA256: [String] {
        configValue("PARKSPOT_TLS_PINNED_CERT_SHA256")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Enforce TLS pinning only when at least one certificate hash is configured.
    /// In DEBUG, enforcement can be toggled from Info.plist with PARKSPOT_ENFORCE_TLS_PINNING.
    static var enforceTLSPinning: Bool {
        #if DEBUG
        return Bundle.main.infoDictionary?["PARKSPOT_ENFORCE_TLS_PINNING"] as? Bool
            ?? !tlsPinnedCertificateSHA256.isEmpty
        #else
        return !tlsPinnedCertificateSHA256.isEmpty
        #endif
    }

    // MARK: – RGPD
    static var privacyPolicyURL: URL {
        URL(string: validatedWebURLString(configValue("PARKSPOT_PRIVACY_POLICY_URL")) ?? "https://mosimap.com/privacy")!
    }

    static var termsURL: URL {
        URL(string: validatedWebURLString(configValue("PARKSPOT_TERMS_URL")) ?? "https://mosimap.com/terms")!
    }

    static var dataRequestEmail: String {
        let configured = configValue("PARKSPOT_DATA_REQUEST_EMAIL")
        return configured.isEmpty ? "privacy@mosimap.com" : configured
    }

    static var supportEmail: String {
        let configured = configValue("PARKSPOT_SUPPORT_EMAIL")
        return configured.isEmpty ? "support@mosimap.com" : configured
    }

    // MARK: – Notifications
    static let parkingWarning1MinutesKey = "parkspot.notifications.warning1.minutes"
    static let parkingWarning2MinutesKey = "parkspot.notifications.warning2.minutes"
    static let parkingWarning1EnabledKey = "parkspot.notifications.warning1.enabled"
    static let parkingWarning2EnabledKey = "parkspot.notifications.warning2.enabled"
    static let parkingAlertsDefaultsVersionKey = "parkspot.notifications.defaults.version"

    static let defaultParkingWarning1Minutes = 30
    static let defaultParkingWarning2Minutes = 10

    static let alternatingParkingEnabledKey = "parkspot.alternatingParking.enabled"
    static let alternatingParkingRuleIdKey = "parkspot.alternatingParking.ruleId"
    static let alternatingParkingWeekdaysKey = "parkspot.alternatingParking.weekdaysCSV"
    static let alternatingParkingEveningHourKey = "parkspot.alternatingParking.evening.hour"
    static let alternatingParkingEveningMinuteKey = "parkspot.alternatingParking.evening.minute"
    static let alternatingParkingMorningHourKey = "parkspot.alternatingParking.morning.hour"
    static let alternatingParkingMorningMinuteKey = "parkspot.alternatingParking.morning.minute"

    static var parkingExpiryWarning1: TimeInterval {
        let mins = UserDefaults.standard.integer(forKey: parkingWarning1MinutesKey)
        let safeMins = mins > 0 ? mins : defaultParkingWarning1Minutes
        return TimeInterval(safeMins * 60)
    }

    static var parkingExpiryWarning2: TimeInterval {
        let mins = UserDefaults.standard.integer(forKey: parkingWarning2MinutesKey)
        let safeMins = mins > 0 ? mins : defaultParkingWarning2Minutes
        return TimeInterval(safeMins * 60)
    }

    static var isParkingWarning1Enabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: parkingWarning1EnabledKey) == nil { return true }
        return defaults.bool(forKey: parkingWarning1EnabledKey)
    }

    static var isParkingWarning2Enabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: parkingWarning2EnabledKey) == nil { return true }
        return defaults.bool(forKey: parkingWarning2EnabledKey)
    }

    static func applyParkingAlertsDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let currentVersion = defaults.integer(forKey: parkingAlertsDefaultsVersionKey)
        guard currentVersion < 1 else { return }

        defaults.set(true, forKey: parkingWarning1EnabledKey)
        defaults.set(true, forKey: parkingWarning2EnabledKey)
        defaults.set(defaultParkingWarning1Minutes, forKey: parkingWarning1MinutesKey)
        defaults.set(defaultParkingWarning2Minutes, forKey: parkingWarning2MinutesKey)
        defaults.set(1, forKey: parkingAlertsDefaultsVersionKey)
    }

    // MARK: – Auto Parking Detection
    static let autoParkingConfidenceKey = "parkspot.autoParking.minimumConfidence"
    static let autoParkingConfirmationDelayKey = "parkspot.autoParking.confirmationDelaySeconds"

    static var autoParkingMinimumConfidence: Double {
        let value = UserDefaults.standard.double(forKey: autoParkingConfidenceKey)
        return value > 0 ? value : 0.74
    }

    static var autoParkingConfirmationDelay: TimeInterval {
        let value = UserDefaults.standard.double(forKey: autoParkingConfirmationDelayKey)
        return value > 0 ? min(max(value, 20), 45) : 24
    }
}
