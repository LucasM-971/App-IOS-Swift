// ParkSpotApp.swift
// Entry point – configure DI container, appearance, and launch

import SwiftUI
import AppIntents
import CoreLocation
import Combine
import UIKit

@main
struct ParkSpotApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private static let installMarkerKey = "app.install.marker.v1"

    // MARK: – App Delegate for push notifications / lifecycle
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: – Root environment objects
    @StateObject private var appRouter   = AppRouter()
    @StateObject private var authSession: AuthSession
    @AppStorage(AppLanguage.defaultsLanguageKey) private var appLanguageCode = AppLanguage.system.rawValue
    @AppStorage(AppLanguage.defaultsUserOverrideEnabledKey) private var languageOverrideEnabled = false
    @State private var lastAppliedLocaleIdentifier: String
    @State private var languageRefreshToken = UUID()
    @State private var didRunInitialSetup = false

    init() {
        let isFreshInstall = Self.resetSessionIfFreshInstall()
        if isFreshInstall {
            AppLanguage.seedAutomaticDefaultsForFreshInstall()
        }

        _authSession = StateObject(wrappedValue: AuthSession())

        AppConfig.applyParkingAlertsDefaultsIfNeeded()
        AppLanguageManager.clearLegacyLanguageOverrides()

        let defaults = UserDefaults.standard
        let savedCode = defaults.string(forKey: AppLanguage.defaultsLanguageKey) ?? AppLanguage.system.rawValue
        let overrideEnabled = defaults.object(forKey: AppLanguage.defaultsUserOverrideEnabledKey) as? Bool ?? false

		let initialLocaleIdentifier = AppLanguage.resolvedLocaleIdentifier(
			savedCode: savedCode,
			overrideEnabled: overrideEnabled
		)

        AppLanguageManager.apply(languageCode: initialLocaleIdentifier)
        _lastAppliedLocaleIdentifier = State(initialValue: initialLocaleIdentifier)
    }

    private static func resetSessionIfFreshInstall() -> Bool {
        let defaults = UserDefaults.standard
        let existingInstallMarker = defaults.string(forKey: installMarkerKey)
        let hasAppDefaults = defaults
            .dictionaryRepresentation()
            .keys
            .contains { $0.hasPrefix("parkspot.") || $0.hasPrefix("app.") }

        guard existingInstallMarker != nil else {
            if !hasAppDefaults {
                let keychain = KeychainService()
                try? keychain.delete(.authToken)
                try? keychain.delete(.refreshToken)
                try? keychain.delete(.userId)
            }
            defaults.set(UUID().uuidString, forKey: installMarkerKey)
            return !hasAppDefaults
        }

        return false
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appRouter)
                .environmentObject(authSession)
                .environment(\.locale, Locale(identifier: lastAppliedLocaleIdentifier))
                .id("\(lastAppliedLocaleIdentifier)-\(languageRefreshToken.uuidString)")
                .onAppear {
                    performInitialAppSetup()
                }
                .onOpenURL { url in
                    Task {
                        do {
                            let authResult = try await authSession.handleIncomingAuthURL(url)
                            await MainActor.run {
                                switch authResult {
                                case .passwordRecovery:
                                    appRouter.navigateTo(.auth)
                                case .emailVerified:
                                    appRouter.navigateToEmailVerifiedSuccess()
                                case .none:
                                    break
                                }
                            }
                        } catch {
                            if AppConfig.isDebugLoggingEnabled {
                                print("[Auth] Deep link ignored: \(error.localizedDescription)")
                            }
                        }
                    }
                }
                .onChange(of: appLanguageCode) { _, _ in
                    refreshLanguageRuntimeIfNeeded()
                }
                .onChange(of: languageOverrideEnabled) { _, _ in
                    refreshLanguageRuntimeIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: .appLanguageDidChange)) { _ in
                    refreshLanguageRuntimeIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    refreshLanguageRuntimeIfNeeded()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            if !languageOverrideEnabled {
                refreshLanguageRuntimeIfNeeded()
            }
        }
    }

	private var resolvedLocaleIdentifier: String {
		let defaults = UserDefaults.standard
		let savedCode = defaults.string(forKey: AppLanguage.defaultsLanguageKey) ?? appLanguageCode
		let overrideEnabled = defaults.object(forKey: AppLanguage.defaultsUserOverrideEnabledKey) as? Bool
			?? languageOverrideEnabled

		return AppLanguage.resolvedLocaleIdentifier(
			savedCode: savedCode,
			overrideEnabled: overrideEnabled
		)
	}

    private func performInitialAppSetup() {
        guard !didRunInitialSetup else { return }
        didRunInitialSetup = true

        refreshLanguageRuntimeIfNeeded(forceRebuild: false)
        configureAppearance()

        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 180_000_000)
            await MainActor.run {
                configureEnergyManager()
                configureBackgroundShutdownManager()
            }
        }
    }

    private func configureEnergyManager() {
        let container = DIContainer.shared
        EnergyManager.shared.configure(
            location: container.locationService as? LocationService,
            bluetooth: container.carBluetoothService
        )
    }

    private func configureBackgroundShutdownManager() {
        let container = DIContainer.shared
        BackgroundShutdownManager.shared.setup(
            locationService: container.locationService as? LocationService
        )
    }

    private func refreshLanguageRuntimeIfNeeded(forceRebuild: Bool = true) {
        let nextLocaleIdentifier = resolvedLocaleIdentifier
        let localeDidChange = nextLocaleIdentifier != lastAppliedLocaleIdentifier

        AppLanguageManager.apply(languageCode: nextLocaleIdentifier)
        lastAppliedLocaleIdentifier = nextLocaleIdentifier

        guard forceRebuild, localeDidChange else { return }
        languageRefreshToken = UUID()
    }

    // MARK: – Global UIKit appearance
    private func configureAppearance() {
        let navBar = UINavigationBarAppearance()
        navBar.configureWithOpaqueBackground()
        navBar.backgroundColor       = .systemBackground
        navBar.titleTextAttributes   = [.foregroundColor: UIColor.label]
        navBar.largeTitleTextAttributes = [.foregroundColor: UIColor.label]
        UINavigationBar.appearance().standardAppearance   = navBar
        UINavigationBar.appearance().scrollEdgeAppearance = navBar

        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = .systemBackground

        let selectedColor = UIColor(named: "BrandBlue") ?? .systemBlue
        let normalColor = UIColor.secondaryLabel

        tabBar.stackedLayoutAppearance.selected.iconColor = selectedColor
        tabBar.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]
        tabBar.stackedLayoutAppearance.normal.iconColor = normalColor
        tabBar.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: normalColor]

        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar
    }

}

// MARK: - Siri Shortcuts
