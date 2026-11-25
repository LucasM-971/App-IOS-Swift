// SettingsView.swift
// User settings + full RGPD controls (export, delete account)

#if canImport(UIKit)

    import SwiftUI
    import PhotosUI
    import Photos
    import UIKit
    import CoreLocation
    import UserNotifications
    import Combine

    extension Notification.Name {
        static let settingsViewDidAppear = Notification.Name("settingsViewDidAppear")
        static let settingsViewDidDisappear = Notification.Name("settingsViewDidDisappear")
    }

    struct SettingsView: View {
        @EnvironmentObject private var authSession: AuthSession
        @EnvironmentObject private var router: AppRouter

        @State private var notificationsActives: Bool = true
        @State private var showProfileEditor: Bool = false
        @State private var showZoneNamingView: Bool = false
        @State private var showNotificationSettings: Bool = false
        @State private var showPremiumSheet: Bool = false
        @State private var showAboutView: Bool = false
        @State private var showPrivacyPolicy: Bool = false
        @State private var showTermsOfUse: Bool = false
        @State private var showExportSheet: Bool = false
        @State private var showDeleteConfirm: Bool = false
        @State private var showLoginRequiredForZonesAlert: Bool = false
        @State private var showSignOutConfirm: Bool = false
        @State private var isDeleting: Bool = false
        @State private var isExportingData: Bool = false
        @State private var deleteErrorMessage: String?
        @State private var exportPayloadText: String = ""
        @State private var exportJSONFileURL: URL?
        @State private var exportParkingCSVFileURL: URL?
        @State private var exportErrorMessage: String?
        @State private var debugMetrics: [DebugMetricItem] = []
        @State private var showResetMetricsConfirm: Bool = false
        @State private var debugNotificationStatus: String?
        @State private var debugAutoParkingStatus: String?
        @State private var showBackgroundLocationPrompt = false
        @AppStorage(AppLanguage.defaultsLanguageKey) private var appLanguageCode = AppLanguage.system.rawValue
        @AppStorage(AppLanguage.defaultsUserOverrideEnabledKey) private var languageOverrideEnabled = false
        @AppStorage("settings.autoParkingDetectionEnabled") private var autoParkingDetectionEnabled = false
        @AppStorage("settings.autoDepartureEnabled") private var autoDepartureEnabled = false
        @AppStorage("debug.onboarding.forceVisible") private var debugOnboardingForceVisible = false
        @AppStorage("debug.onboarding.startStage") private var debugOnboardingStartStage = ""
        @AppStorage("debug.onboarding.startPage") private var debugOnboardingStartPage = 0
        @AppStorage("debug.requiredSettings.forcePage") private var debugRequiredSettingsForcePage =
            false

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        MinimalSectionHeader(title: "settings.section.profile".psLocalized)

                        MinimalProfileCard(
                            displayName: authSession.currentUser?.displayName ?? "User".psLocalized,
                            isLoggedIn: authSession.currentUser != nil,
                            profilePhotoData: authSession.profilePhotoData,
                            onEditProfile: {
                                if authSession.currentUser != nil {
                                    showProfileEditor = true
                                } else {
                                    router.navigateToAuthFromSettings()
                                }
                            }
                        )

                        MinimalSectionHeader(title: "settings.section.language".psLocalized)

                        LanguageSettingsCard(selection: languageSelection)

                        MinimalSectionHeader(
                            title: "settings.section.notifications".psLocalized)

                        MinimalPreferencesCard(
                            notificationsActives: $notificationsActives,
                            backgroundParkingAssistanceEnabled: Binding(
                                get: { autoParkingDetectionEnabled || autoDepartureEnabled },
                                set: { enabled in
                                    if enabled {
                                        showBackgroundLocationPrompt = true
                                    } else {
                                        autoParkingDetectionEnabled = false
                                        autoDepartureEnabled = false
                                        NotificationCenter.default.post(
                                            name: .autoParkingSettingsDidChange,
                                            object: nil
                                        )
                                    }
                                }
                            ),
                            onManageAlerts: {
                                guard let user = authSession.currentUser else {
                                    showLoginRequiredForZonesAlert = true
                                    return
                                }

                                if hasPremiumAccess(user) {
                                    showNotificationSettings = true
                                } else {
                                    showPremiumSheet = true
                                }
                            },
                            onManageZones: {
                                guard let user = authSession.currentUser else {
                                    showLoginRequiredForZonesAlert = true
                                    return
                                }

                                if hasPremiumAccess(user) {
                                    showZoneNamingView = true
                                } else {
                                    showPremiumSheet = true
                                }
                            }
                        )

                        MinimalSectionHeader(title: "settings.section.premium".psLocalized)

                        MinimalActionCard {
                            Button {
                                showPremiumSheet = true
                            } label: {
                                MinimalActionRow(
                                    icon: "star.fill",
                                    title: "settings.go_premium".psLocalized)
                            }
                            .buttonStyle(.plain)
                        }

                        MinimalSectionHeader(title: "settings.section.privacy".psLocalized)

                        MinimalActionCard {
                            Button {
                                showPrivacyPolicy = true
                            } label: {
                                MinimalActionRow(
                                    icon: "hand.raised.fill",
                                    title: "settings.privacy_policy".psLocalized)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 44)

                            Button {
                                showTermsOfUse = true
                            } label: {
                                MinimalActionRow(
                                    icon: "doc.text.fill",
                                    title: "settings.terms".psLocalized)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 44)

                            Button {
                                Task { await exportUserData() }
                            } label: {
                                MinimalActionRow(
                                    icon: "arrow.down.doc.fill",
                                    title: "settings.export_data".psLocalized)
                            }
                            .buttonStyle(.plain)

                            if authSession.currentUser != nil {
                                Divider().padding(.leading, 44)

                                Button {
                                    showDeleteConfirm = true
                                } label: {
                                    MinimalActionRow(
                                        icon: "trash.fill",
                                        title: "settings.delete_account".psLocalized,
                                        titleColor: .red)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        MinimalSectionHeader(title: "settings.section.support".psLocalized)

                        MinimalActionCard {
                            Link(destination: URL(string: "mailto:\(AppConfig.supportEmail)")!) {
                                MinimalActionRow(
                                    icon: "envelope.fill",
                                    title: "settings.contact_dpo".psLocalized)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 44)

                            Button {
                                showAboutView = true
                            } label: {
                                MinimalActionRow(
                                    icon: "info.circle.fill",
                                    title: "settings.about".psLocalized)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 44)

                            if authSession.currentUser != nil {
                                Button(role: .destructive) {
                                    showSignOutConfirm = true
                                } label: {
                                    MinimalActionRow(
                                        icon: "rectangle.portrait.and.arrow.right",
                                        title: "settings.sign_out".psLocalized,
                                        titleColor: .red)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button {
                                    router.navigateToAuthFromSettings()
                                } label: {
                                    MinimalActionRow(
                                        icon: "person.crop.circle.badge.plus",
                                        title: "Se connecter".psLocalized)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        #if DEBUG
                            MinimalSectionHeader(title: "Debug".psLocalized)

                            MinimalActionCard {
                                if debugMetrics.isEmpty {
                                    Text("Aucune métrique locale".psLocalized)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 44)
                                        .padding(.vertical, 10)
                                } else {
                                    ForEach(debugMetrics) { metric in
                                        HStack(spacing: 12) {
                                            Image(systemName: "chart.bar.fill")
                                                .foregroundStyle(.blue)
                                                .frame(width: 20)

                                            Text(metric.key)
                                                .font(.footnote)
                                                .foregroundStyle(Color(UIColor.label))

                                            Spacer(minLength: 12)

                                            Text("\(metric.value)")
                                                .font(.footnote.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)

                                        if metric.id != debugMetrics.last?.id {
                                            Divider().padding(.leading, 44)
                                        }
                                    }
                                }

                                Divider().padding(.leading, 44)

                                Button {
                                    refreshDebugMetrics()
                                } label: {
                                    MinimalActionRow(
                                        icon: "arrow.clockwise",
                                        title: "Rafraîchir métriques".psLocalized)
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    openRequiredSettingsDebugPage()
                                } label: {
                                    MinimalActionRow(
                                        icon: "exclamationmark.shield.fill",
                                        title: "Ouvrir page Action requise debug")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    openOnboardingDebug(stage: "intro", page: 0)
                                } label: {
                                    MinimalActionRow(
                                        icon: "1.circle.fill",
                                        title: "Test onboarding: 1/5 Welcome")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    openOnboardingDebug(stage: "intro", page: 1)
                                } label: {
                                    MinimalActionRow(
                                        icon: "2.circle.fill",
                                        title: "Test onboarding: 2/5 Instant directions")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    openOnboardingDebug(stage: "intro", page: 2)
                                } label: {
                                    MinimalActionRow(
                                        icon: "3.circle.fill",
                                        title: "Test onboarding: 3/5 Smart guidance")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    openOnboardingDebug(stage: "intro", page: 3)
                                } label: {
                                    MinimalActionRow(
                                        icon: "4.circle.fill",
                                        title: "Test onboarding: 4/5 Never forget")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    openOnboardingDebug(stage: "postIntroChoice")
                                } label: {
                                    MinimalActionRow(
                                        icon: "5.circle.fill",
                                        title: "Test onboarding: 5/5 Create account")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    disableOnboardingDebugOverride()
                                } label: {
                                    MinimalActionRow(
                                        icon: "xmark.circle",
                                        title: "Disable onboarding debug override")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    router.navigateToAuthFromSettings(mode: .signIn)
                                } label: {
                                    MinimalActionRow(
                                        icon: "person.crop.circle.badge.checkmark",
                                        title: "Ouvrir page Auth (connexion)")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    router.navigateToAuthFromSettings(mode: .signUp)
                                } label: {
                                    MinimalActionRow(
                                        icon: "person.crop.circle.badge.plus",
                                        title: "Ouvrir page Auth (inscription)")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    router.navigateToSignedOutConfirmation()
                                } label: {
                                    MinimalActionRow(
                                        icon: "checkmark.circle",
                                        title: "Ouvrir page Déconnexion confirmée")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    router.navigateToEmailConfirmation(email: "debug@parkspot.app")
                                } label: {
                                    MinimalActionRow(
                                        icon: "envelope.badge",
                                        title: "Ouvrir page Confirmation e-mail")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    router.navigateToEmailVerifiedSuccess()
                                } label: {
                                    MinimalActionRow(
                                        icon: "checkmark.seal",
                                        title: "Ouvrir page E-mail vérifié")
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    showPremiumSheet = true
                                } label: {
                                    MinimalActionRow(
                                        icon: "star.circle.fill",
                                        title: "Ouvrir paywall Premium (debug)".psLocalized)
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    UserDefaults.standard.set(
                                        true, forKey: "parkspot.premium.upsell.forceNext.v1")
                                    debugNotificationStatus =
                                        "Popup premium free forcée. Retournez sur l'accueil."
                                } label: {
                                    MinimalActionRow(
                                        icon: "bubble.left.and.bubble.right.fill",
                                        title: String(
                                            localized: "Forcer popup premium free (debug)"))
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    sendParkingExpiryDebugNotification()
                                } label: {
                                    MinimalActionRow(
                                        icon: "timer",
                                        title: "Tester notif expiration".psLocalized)
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    triggerAutoParkingDebugDetection(bypassFilters: true)
                                } label: {
                                    MinimalActionRow(
                                        icon: "car.fill",
                                        title: "Tester auto-parking (sans filtre)".psLocalized)
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    triggerAutoParkingDebugDetection(bypassFilters: false)
                                } label: {
                                    MinimalActionRow(
                                        icon: "exclamationmark.triangle.fill",
                                        title: "Tester auto-parking (avec filtre)".psLocalized)
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    sendAutoParkingPromptDebugNotification()
                                } label: {
                                    MinimalActionRow(
                                        icon: "bell.badge",
                                        title: "Tester notif auto-parking".psLocalized)
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    simulateCarPlayTurnedOffDebug()
                                } label: {
                                    MinimalActionRow(
                                        icon: "car.rear.and.tire.marks",
                                        title: "Debug: carplay turned off".psLocalized)
                                }
                                .buttonStyle(.plain)

                                Divider().padding(.leading, 44)

                                Button {
                                    runAutoParkingCurrentGPSDebugScenario()
                                } label: {
                                    MinimalActionRow(
                                        icon: "location.fill",
                                        title: "Tester auto-parking (GPS actuel)".psLocalized
                                    )
                                }
                                .buttonStyle(.plain)

                                if let debugNotificationStatus, !debugNotificationStatus.isEmpty {
                                    Divider().padding(.leading, 44)

                                    Text(debugNotificationStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 44)
                                        .padding(.vertical, 10)
                                }

                                if let debugAutoParkingStatus, !debugAutoParkingStatus.isEmpty {
                                    Divider().padding(.leading, 44)

                                    Text(debugAutoParkingStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 44)
                                        .padding(.vertical, 10)
                                }

                                Divider().padding(.leading, 44)

                                Button(role: .destructive) {
                                    showResetMetricsConfirm = true
                                } label: {
                                    MinimalActionRow(
                                        icon: "trash.fill",
                                        title: "Réinitialiser métriques".psLocalized,
                                        titleColor: .red)
                                }
                                .buttonStyle(.plain)
                            }
                        #endif
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .background(Color(UIColor.systemGroupedBackground))
                .navigationTitle("settings.title".psLocalized)
                .navigationBarTitleDisplayMode(.inline)
                .tint(.blue)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color(.systemBackground), for: .navigationBar)
                .onAppear {
                    NotificationCenter.default.post(name: .settingsViewDidAppear, object: nil)
                    #if DEBUG
                        refreshDebugMetrics()
                    #endif
                }
                .onDisappear {
                    NotificationCenter.default.post(name: .settingsViewDidDisappear, object: nil)
                }
                .navigationDestination(isPresented: $showProfileEditor) {
                    ProfileEditView()
                }
                .navigationDestination(isPresented: $showZoneNamingView) {
                    if let userId = authSession.currentUser?.id {
                        ZoneNamingView(userId: userId)
                    } else {
                        Text("Utilisateur non connecté".psLocalized)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationDestination(isPresented: $showNotificationSettings) {
                    NotificationSettingsView()
                }
                .navigationDestination(isPresented: $showAboutView) {
                    AboutView()
                }
                .navigationDestination(isPresented: $showPrivacyPolicy) {
                    PrivacyPolicyView()
                }
                .navigationDestination(isPresented: $showTermsOfUse) {
                    TermsOfUseView()
                }
                .sheet(isPresented: $showPremiumSheet) {
                    PremiumView()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.hidden)
                        .interactiveDismissDisabled(false)
                }
                .sheet(isPresented: $showExportSheet) {
                    NavigationStack {
                        ScrollView {
                            Text(exportPayloadText)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle("settings.export_data".psLocalized)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.visible, for: .navigationBar)
                        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("map.close".psLocalized) { showExportSheet = false }
                                    .foregroundStyle(.blue)
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                if let exportJSONFileURL {
                                    Menu {
                                        ShareLink(
                                            item: exportJSONFileURL,
                                            preview: SharePreview(
                                                exportJSONFileURL.lastPathComponent,
                                                image: Image(systemName: "doc.text")))

                                        if let exportParkingCSVFileURL {
                                            ShareLink(
                                                item: exportParkingCSVFileURL,
                                                preview: SharePreview(
                                                    exportParkingCSVFileURL.lastPathComponent,
                                                    image: Image(systemName: "tablecells")))
                                        }
                                    } label: {
                                        Image(systemName: "square.and.arrow.up")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
                .alert(
                    "Suppression impossible".psLocalized,
                    isPresented: Binding(
                        get: { deleteErrorMessage != nil },
                        set: { if !$0 { deleteErrorMessage = nil } }
                    )
                ) {
                    Button("OK".psLocalized) { deleteErrorMessage = nil }
                } message: {
                    Text(deleteErrorMessage ?? "")
                }
                .alert(
                    "Export impossible".psLocalized,
                    isPresented: Binding(
                        get: { exportErrorMessage != nil },
                        set: { if !$0 { exportErrorMessage = nil } }
                    )
                ) {
                    Button("OK".psLocalized) { exportErrorMessage = nil }
                } message: {
                    Text(exportErrorMessage ?? "")
                }
                .alert("Réinitialiser les métriques ?".psLocalized, isPresented: $showResetMetricsConfirm) {
                    Button("Réinitialiser".psLocalized, role: .destructive) {
                        resetDebugMetrics()
                        refreshDebugMetrics()
                    }
                    Button("common.cancel".psLocalized, role: .cancel) {}
                } message: {
                    Text(
                        "Cela supprime toutes les clés UserDefaults commençant par parkspot.metrics.".psLocalized
                    )
                }
                .alert("Background location".psLocalized, isPresented: $showBackgroundLocationPrompt) {
                    Button("Continue".psLocalized) {
                        enableBackgroundParkingAssistance()
                    }
                    Button("Not now".psLocalized, role: .cancel) {
                        autoParkingDetectionEnabled = false
                        autoDepartureEnabled = false
                    }
                } message: {
                    Text("MosiMap needs your location to save where you parked and help you return to your car. Background location is optional and only used for automatic parking detection and reminders.".psLocalized)
                }
                .alert(
                    "settings.delete_account".psLocalized, isPresented: $showDeleteConfirm
                ) {
                    Button("settings.delete_account_confirm".psLocalized, role: .destructive)
                    {
                        Task { await deleteAccount() }
                    }
                    Button("common.cancel".psLocalized, role: .cancel) {}
                } message: {
                    Text("settings.delete_account_message".psLocalized)
                }
                .alert(
                    localizedOrFallback("Connexion", fallback: "Connexion"),
                    isPresented: $showLoginRequiredForZonesAlert
                ) {
                    Button(localizedOrFallback("common.cancel", fallback: "Annuler"), role: .cancel)
                    {}
                    Button(localizedOrFallback("Se connecter", fallback: "Se connecter")) {
                        router.navigateToAuthFromSettings()
                    }
                } message: {
                    Text(
                        localizedOrFallback(
                            "settings.login_required_message",
                            fallback:
                                "Vous devez vous connecter pour accéder à cette fonctionnalité."
                        )
                    )
                }
                .alert(
                    localizedOrFallback("settings.sign_out", fallback: "Se déconnecter"),
                    isPresented: $showSignOutConfirm
                ) {
                    Button(localizedOrFallback("common.cancel", fallback: "Annuler"), role: .cancel)
                    {}
                    Button(
                        localizedOrFallback("settings.sign_out", fallback: "Se déconnecter"),
                        role: .destructive
                    ) {
                        Task {
                            await authSession.signOut()
                            router.navigateToSignedOutConfirmation()
                        }
                    }
                } message: {
                    Text("Voulez-vous vraiment vous déconnecter ?".psLocalized)
                }
                .overlay {
                    ZStack {
                        if isDeleting {
                            ProgressView("settings.deleting".psLocalized)
                                .padding(20)
                                .background(
                                    .regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        if isExportingData {
                            ProgressView("Préparation de l'export…".psLocalized)
                                .padding(20)
                                .background(
                                    .regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
        }

        private var languageSelection: Binding<String> {
            Binding(
                get: {
                    languageOverrideEnabled ? appLanguageCode : AppLanguage.system.rawValue
                },
                set: { newValue in
                    let shouldOverrideSystemLanguage = newValue != AppLanguage.system.rawValue
                    appLanguageCode = newValue
                    languageOverrideEnabled = shouldOverrideSystemLanguage
                    UserDefaults.standard.set(newValue, forKey: AppLanguage.defaultsLanguageKey)
                    UserDefaults.standard.set(
                        shouldOverrideSystemLanguage,
                        forKey: AppLanguage.defaultsUserOverrideEnabledKey
                    )
                    NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
                }
            )
        }

        private func enableBackgroundParkingAssistance() {
            autoParkingDetectionEnabled = true
            autoDepartureEnabled = true

            let locationService = DIContainer.shared.locationService
            locationService.requestAuthorization()
            locationService.requestAlwaysAuthorizationIfNeeded()
            NotificationCenter.default.post(name: .autoParkingSettingsDidChange, object: nil)
        }

        private func exportUserData() async {
            await MainActor.run {
                isExportingData = true
                exportErrorMessage = nil
            }

            defer {
                Task { @MainActor in
                    isExportingData = false
                }
            }

            do {
                let payload = try await authSession.exportAllUserData()
                let mergedPayload = mergeRemoteExportWithLocalSnapshot(payload.content)
                let jsonFileURL = try writeExportFile(
                    fileName: payload.fileName,
                    content: mergedPayload,
                    fileExtension: "json"
                )
                let parkingCSVFileURL = try makeParkingSessionsCSVFileIfPossible(
                    from: mergedPayload,
                    baseFileName: payload.fileName
                )

                await MainActor.run {
                    exportPayloadText = mergedPayload
                    exportJSONFileURL = jsonFileURL
                    exportParkingCSVFileURL = parkingCSVFileURL
                    showExportSheet = true
                }
            } catch {
                await MainActor.run {
                    exportErrorMessage = error.localizedDescription
                }
            }
        }

        private func mergeRemoteExportWithLocalSnapshot(_ remotePayload: String) -> String {
            guard
                let data = remotePayload.data(using: .utf8),
                var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                return remotePayload
            }

            object["localDeviceSnapshot"] = localExportSnapshot()

            guard
                let merged = try? JSONSerialization.data(
                    withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                let text = String(data: merged, encoding: .utf8)
            else {
                return remotePayload
            }

            return text
        }

        private func localExportSnapshot() -> [String: Any] {
            [
                "capturedAt": ISO8601DateFormatter().string(from: Date()),
                "app": [
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                        ?? "unknown",
                    "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                        ?? "unknown",
                ],
                "device": [
                    "systemName": UIDevice.current.systemName,
                    "systemVersion": UIDevice.current.systemVersion,
                    "locale": Locale.current.identifier,
                    "timeZone": TimeZone.current.identifier,
                ],
                "appSettings": [
                    "notificationsEnabled": notificationsActives
                ],
                "session": [
                    "isAuthenticated": authSession.isAuthenticated,
                    "hasProfilePhoto": authSession.profilePhotoData != nil,
                ],
                "metrics": UserDefaults.standard.dictionaryRepresentation()
                    .filter { $0.key.hasPrefix("parkspot.metrics.") },
            ]
        }

        private func writeExportFile(fileName: String, content: String, fileExtension: String)
            throws
            -> URL
        {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ParkSpotExports", isDirectory: true)
            try FileManager.default.createDirectory(
                at: tempRoot,
                withIntermediateDirectories: true
            )

            let baseName = URL(fileURLWithPath: fileName)
                .deletingPathExtension()
                .lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let safeBaseName = baseName.isEmpty ? "parkspot-export" : baseName
            let exportURL =
                tempRoot
                .appendingPathComponent(safeBaseName)
                .appendingPathExtension(fileExtension)

            guard let data = content.data(using: .utf8) else {
                throw APIError.badRequest("Impossible de sérialiser l'export en UTF-8.".psLocalized)
            }

            try data.write(to: exportURL, options: .atomic)
            return exportURL
        }

        private func makeParkingSessionsCSVFileIfPossible(
            from jsonText: String, baseFileName: String
        )
            throws -> URL?
        {
            guard let csv = parkingSessionsCSV(from: jsonText) else {
                return nil
            }

            let csvBaseName =
                URL(fileURLWithPath: baseFileName)
                .deletingPathExtension()
                .lastPathComponent + "-parking-sessions"
            return try writeExportFile(fileName: csvBaseName, content: csv, fileExtension: "csv")
        }

        private func parkingSessionsCSV(from jsonText: String) -> String? {
            guard
                let data = jsonText.data(using: .utf8),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let sessions = object["parkingSessions"] as? [[String: Any]],
                !sessions.isEmpty
            else {
                return nil
            }

            let columns = [
                "id", "userId", "latitude", "longitude", "address", "note", "parkingLevel", "zone",
                "startTime", "endTime", "maxDuration", "isApproximate",
            ]

            var lines: [String] = [columns.joined(separator: ",")]
            for row in sessions {
                let values = columns.map { key in
                    csvEscapedString(row[key])
                }
                lines.append(values.joined(separator: ","))
            }

            return lines.joined(separator: "\n")
        }

        private func csvEscapedString(_ value: Any?) -> String {
            let raw: String
            switch value {
            case let number as NSNumber:
                raw = number.stringValue
            case let text as String:
                raw = text
            case .none:
                raw = ""
            default:
                raw = String(describing: value ?? "")
            }

            let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        private func openOnboardingDebug(stage: String, page: Int = 0) {
            UserDefaults.standard.set(false, forKey: "app.hasCompletedWelcome")
            debugOnboardingForceVisible = true
            debugOnboardingStartStage = stage
            debugOnboardingStartPage = page
            router.navigateTo(.onboarding)
            debugNotificationStatus = String(
                format: "Intro debug ouverte (%@).".psLocalized,
                stage
            )
        }

        private func openRequiredSettingsDebugPage() {
            debugRequiredSettingsForcePage = true
            router.navigateTo(.main)
            debugNotificationStatus = "Page Action requise debug ouverte.".psLocalized
        }

        private func disableOnboardingDebugOverride() {
            debugOnboardingForceVisible = false
            debugOnboardingStartStage = ""
            debugOnboardingStartPage = 0
            debugNotificationStatus = "Override intro debug désactivé.".psLocalized
        }

        private func refreshDebugMetrics() {
            let metrics = UserDefaults.standard.dictionaryRepresentation()
                .filter { $0.key.hasPrefix("parkspot.metrics.") }
                .map { key, value -> DebugMetricItem in
                    let intValue: Int
                    if let asInt = value as? Int {
                        intValue = asInt
                    } else if let asDouble = value as? Double {
                        intValue = Int(asDouble)
                    } else {
                        intValue = 0
                    }
                    return DebugMetricItem(id: key, key: key, value: intValue)
                }
                .sorted { $0.key < $1.key }

            debugMetrics = metrics
        }

        private func resetDebugMetrics() {
            let defaults = UserDefaults.standard
            let keys = defaults.dictionaryRepresentation().keys.filter {
                $0.hasPrefix("parkspot.metrics.")
            }
            keys.forEach { defaults.removeObject(forKey: $0) }
        }

        private func sendParkingExpiryDebugNotification() {
            sendDebugNotification(kind: .parkingExpired)
        }

        private func triggerAutoParkingDebugDetection(
            bypassFilters: Bool,
            coordinate: Coordinate = Coordinate(latitude: 48.8566, longitude: 2.3522),
            confidence: Double = 0.91
        ) {
            let source = bypassFilters
                ? "settings-debug-auto-parking-without-filter"
                : "settings-debug-auto-parking-with-filter"

            let userInfo: [AnyHashable: Any] = [
                AutoParkingNotificationPayloadStore.latitudeUserInfoKey: coordinate.latitude,
                AutoParkingNotificationPayloadStore.longitudeUserInfoKey: coordinate.longitude,
                AutoParkingNotificationPayloadStore.confidenceUserInfoKey: confidence,
                AutoParkingNotificationPayloadStore.sourceUserInfoKey: source,
                "parkspot.autoParking.debugBypassFilters": bypassFilters,
            ]

            NotificationCenter.default.post(
                name: .autoParkingDebugDetectionInjected,
                object: nil,
                userInfo: userInfo
            )

            debugAutoParkingStatus = bypassFilters
                ? "AutoParking TEST: sans filtre injecté ✅ (confirmation immédiate)".psLocalized
                : "AutoParking TEST: avec filtre injecté ✅ (détection + marche simulée + notif)".psLocalized
        }

        private func sendAutoParkingPromptDebugNotification(
            coordinate: Coordinate = Coordinate(latitude: 48.8566, longitude: 2.3522),
            confidence: Double = 0.91,
            source: String = "settings-debug-auto-parking",
            triggerInAppPendingState: Bool = false
        ) {
            let center = UNUserNotificationCenter.current()

            if let appDelegate = UIApplication.shared.delegate as? UNUserNotificationCenterDelegate
            {
                center.delegate = appDelegate
            }

            let userInfo: [AnyHashable: Any] = [
                AutoParkingNotificationPayloadStore.latitudeUserInfoKey: coordinate.latitude,
                AutoParkingNotificationPayloadStore.longitudeUserInfoKey: coordinate.longitude,
                AutoParkingNotificationPayloadStore.confidenceUserInfoKey: confidence,
                AutoParkingNotificationPayloadStore.sourceUserInfoKey: source,
            ]

            AutoParkingNotificationPayloadStore.store(
                title: "Parking detected".psLocalized,
                body: "Debug auto-parking".psLocalized,
                userInfo: userInfo
            )

            let content = UNMutableNotificationContent()
            content.title = "Parking detected".psLocalized
            content.body = "Debug: did you park your car?".psLocalized
            content.sound = .default
            content.threadIdentifier = AutoParkingNotificationPayloadStore.threadIdentifier
            content.userInfo = userInfo

            let identifier = "parkspot.auto-parking.confirmation.debug.\(UUID().uuidString)"
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )

            center.add(request) { error in
                Task { @MainActor in
                    if let error {
                        debugNotificationStatus = String(
                            format: "Échec notif auto-parking: %@".psLocalized,
                            error.localizedDescription
                        )
                    } else {
                        debugNotificationStatus = "Notif auto-parking planifiée ✅ (1s)".psLocalized
                        if triggerInAppPendingState {
                            NotificationCenter.default.post(
                                name: .autoParkingNotificationOpened,
                                object: nil
                            )
                            debugNotificationStatus = "Notif auto-parking planifiée ✅ + état in-app injecté".psLocalized
                        }
                    }
                }
            }
        }

        private func runAutoParkingCurrentGPSDebugScenario() {
            Task {
                await MainActor.run {
                    debugAutoParkingStatus = "AutoParking TEST GPS: récupération position en cours…".psLocalized
                }

                guard let coordinate = await fetchCurrentCoordinateForAutoParkingDebug() else {
                    await MainActor.run {
                        debugAutoParkingStatus = "AutoParking TEST GPS: position indisponible. Vérifiez le GPS puis réessayez.".psLocalized
                    }
                    return
                }

                await MainActor.run {
                    let confidence = 0.92
                    injectAutoParkingPendingStateForDebug(
                        coordinate: coordinate,
                        confidence: confidence,
                        source: "settings-debug-auto-parking-current-gps"
                    )
                    debugAutoParkingStatus = String(
                        format: "AutoParking TEST GPS: état in-app injecté (sans notif) lat=%@, lon=%@".psLocalized,
                        String(format: "%.5f", coordinate.latitude),
                        String(format: "%.5f", coordinate.longitude)
                    )
                }
            }
        }

        private func simulateCarPlayTurnedOffDebug() {
            CarPlayConnectionStateStore.setConnected(false)
            CarPlaySceneDelegate.debugSimulateCarPlayTurnedOff()
            debugNotificationStatus = "carplay turned off simulé ✅".psLocalized
        }

        private func injectAutoParkingPendingStateForDebug(
            coordinate: Coordinate,
            confidence: Double,
            source: String
        ) {
            let userInfo: [AnyHashable: Any] = [
                AutoParkingNotificationPayloadStore.latitudeUserInfoKey: coordinate.latitude,
                AutoParkingNotificationPayloadStore.longitudeUserInfoKey: coordinate.longitude,
                AutoParkingNotificationPayloadStore.confidenceUserInfoKey: confidence,
                AutoParkingNotificationPayloadStore.sourceUserInfoKey: source,
            ]

            AutoParkingNotificationPayloadStore.store(
                title: "Parking detected".psLocalized,
                body: "Debug auto-parking (no notification)".psLocalized,
                userInfo: userInfo
            )

            NotificationCenter.default.post(
                name: .autoParkingNotificationOpened,
                object: nil
            )

            debugNotificationStatus = "AutoParking debug GPS: aucun envoi de notif (état in-app uniquement)".psLocalized
        }

        private func fetchCurrentCoordinateForAutoParkingDebug(timeoutSeconds: UInt64 = 8) async
            -> Coordinate?
        {
            let locationService = DIContainer.shared.locationService
            locationService.requestAuthorization()
            locationService.requestAlwaysAuthorizationIfNeeded()
            locationService.startUpdating()

            return await withTaskGroup(of: Coordinate?.self) { group in
                group.addTask {
                    let streamTask = Task<Coordinate?, Never> { @MainActor in
                        for await sample in locationService.currentLocationSample.values {
                            return sample.coordinate
                        }
                        return nil
                    }
                    return await streamTask.value
                }

                group.addTask {
                    try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                    return nil
                }

                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
        }

        private func sendDebugNotification(kind: SettingsDebugNotificationKind) {
            let center = UNUserNotificationCenter.current()

            // Sécurité: ré-attache le delegate pour assurer l'affichage en foreground.
            if let appDelegate = UIApplication.shared.delegate as? UNUserNotificationCenterDelegate
            {
                center.delegate = appDelegate
            }

            center.getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    scheduleDebugNotification(center: center, kind: kind)
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        if granted {
                            scheduleDebugNotification(center: center, kind: kind)
                        } else {
                            Task { @MainActor in
                                debugNotificationStatus = "Notifications refusées".psLocalized
                            }
                        }
                    }
                case .denied:
                    Task { @MainActor in
                            debugNotificationStatus = "Notifications désactivées dans iOS".psLocalized
                    }
                @unknown default:
                    Task { @MainActor in
                        debugNotificationStatus = "État notifications inconnu".psLocalized
                    }
                }
            }
        }

        private func scheduleDebugNotification(
            center: UNUserNotificationCenter, kind: SettingsDebugNotificationKind
        ) {
            let debugPrefix = "parkspot.debug.test."
            center.getPendingNotificationRequests { pending in
                let ids =
                    pending
                    .map(\.identifier)
                    .filter { $0.hasPrefix(debugPrefix) }
                if !ids.isEmpty {
                    center.removePendingNotificationRequests(withIdentifiers: ids)
                }
            }

            let descriptor = kind.descriptor
            let content = UNMutableNotificationContent()
            content.title = descriptor.title
            content.body = descriptor.body
            content.sound = .default
            content.threadIdentifier = descriptor.threadIdentifier
            content.userInfo["parkspot.smartAway.source"] = descriptor.source
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
            }

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let identifier = "parkspot.debug.test.\(kind.rawValue).\(UUID().uuidString)"
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: trigger
            )

            center.add(request) { error in
                Task { @MainActor in
                    if let error {
                        debugNotificationStatus = String(
                            format: "Échec notif %@: %@".psLocalized,
                            descriptor.label,
                            error.localizedDescription
                        )
                    } else {
                        debugNotificationStatus = String(
                            format: "Notif %@ programmée (1s)".psLocalized,
                            descriptor.label
                        )
                    }
                }

                guard error == nil else { return }
                center.getPendingNotificationRequests { requests in
                    let isScheduled = requests.contains(where: { $0.identifier == identifier })
                    Task { @MainActor in
                        if isScheduled {
                            debugNotificationStatus = String(
                                format: "Notif %@ planifiée ✅ (1s). Si rien n'apparaît: vérifier Réglages iOS > Notifications > MosiMap (Bannières).".psLocalized,
                                descriptor.label
                            )
                        } else {
                            debugNotificationStatus = "Notif ajoutée mais non retrouvée dans la file d'attente.".psLocalized
                        }
                    }
                }
            }
        }

        private enum SettingsDebugNotificationKind: String {
            case parkingExpired

            var descriptor:
                (
                    title: String, body: String, threadIdentifier: String, source: String,
                    label: String
                )
            {
                switch self {
                case .parkingExpired:
                    return (
                        title: "⏰ Timer ended".psLocalized,
                        body: "Expiry simulation: your parking session has expired.".psLocalized,
                        threadIdentifier: "parkspot.parking.expiry",
                        source: "settings-debug-parking-expired",
                        label: "expiration".psLocalized
                    )
                }
            }
        }

        private func runAutoParkingDebugScenario(expectMatch: Bool) {
            let now = Date()
            let samples =
                expectMatch
                ? makeAutoParkingMatchSamples(base: now)
                : makeAutoParkingRejectSamples(base: now)

            let heuristic = AutoParkingDetectionHeuristic(
                configuration: AutoParkingHeuristicConfiguration(
                    stationaryRadiusMeters: 28,
                    minimumStationarySamples: 3,
                    minimumStationaryDuration: AppConfig.autoParkingConfirmationDelay,
                    minimumDrivingDistance: 240,
                    maximumGapBetweenDriveAndStop: 90,
                    maxPostDriveDriftMeters: 140,
                    maxWalkingLikeDriftBeforeStationary: 30,
                    minimumApproachSamplesNearStop: 1,
                    minimumConfidence: max(0.74, AppConfig.autoParkingMinimumConfidence)
                )
            )

            let result = heuristic.evaluate(
                samples: samples,
                bluetoothDisconnectAt: nil,
                now: now
            )

            if let result {
                let confidence = Int((result.confidence * 100).rounded())
                debugAutoParkingStatus = String(
                    format: "AutoParking TEST: détecté ✅ • conf=%d%% • source=%@".psLocalized,
                    confidence,
                    result.triggerSource
                )
            } else {
                debugAutoParkingStatus =
                    expectMatch
                    ? "AutoParking TEST: non détecté ❌ (scénario attendu: succès)".psLocalized
                    : "AutoParking TEST: rejeté ✅ (scénario attendu: rejet)".psLocalized
            }
        }

        private func makeAutoParkingMatchSamples(base: Date) -> [LocationSample] {
            let anchor = Coordinate(latitude: 48.8566, longitude: 2.3522)
            let driveOffsets: [Double] = [0, 90, 180, 290, 410, 540]

            let driving = driveOffsets.enumerated().map { idx, meters in
                LocationSample(
                    coordinate: offsetCoordinate(from: anchor, northMeters: meters, eastMeters: 0),
                    accuracy: 10,
                    date: base.addingTimeInterval(-180 + Double(idx * 16)),
                    speed: 8.2
                )
            }

            let parked = offsetCoordinate(from: anchor, northMeters: 540, eastMeters: 0)
            let stable: [LocationSample] = [
                LocationSample(
                    coordinate: parked, accuracy: 8, date: base.addingTimeInterval(-94), speed: 0.10
                ),
                LocationSample(
                    coordinate: offsetCoordinate(from: parked, northMeters: 1, eastMeters: 2),
                    accuracy: 9, date: base.addingTimeInterval(-72), speed: 0.12),
                LocationSample(
                    coordinate: offsetCoordinate(from: parked, northMeters: -1, eastMeters: -2),
                    accuracy: 8, date: base.addingTimeInterval(-50), speed: 0.08),
                LocationSample(
                    coordinate: offsetCoordinate(from: parked, northMeters: 2, eastMeters: 1),
                    accuracy: 8, date: base.addingTimeInterval(-28), speed: 0.06),
                LocationSample(
                    coordinate: parked, accuracy: 7, date: base.addingTimeInterval(-6), speed: 0.04),
            ]

            return driving + stable
        }

        private func makeAutoParkingRejectSamples(base: Date) -> [LocationSample] {
            let anchor = Coordinate(latitude: 48.8566, longitude: 2.3522)
            let traffic: [LocationSample] = [
                LocationSample(
                    coordinate: anchor, accuracy: 12, date: base.addingTimeInterval(-180),
                    speed: 3.2),
                LocationSample(
                    coordinate: offsetCoordinate(from: anchor, northMeters: 35, eastMeters: 0),
                    accuracy: 12, date: base.addingTimeInterval(-152), speed: 3.0),
                LocationSample(
                    coordinate: offsetCoordinate(from: anchor, northMeters: 66, eastMeters: 0),
                    accuracy: 11, date: base.addingTimeInterval(-124), speed: 2.9),
                LocationSample(
                    coordinate: offsetCoordinate(from: anchor, northMeters: 84, eastMeters: 0),
                    accuracy: 11, date: base.addingTimeInterval(-96), speed: 2.8),
                LocationSample(
                    coordinate: offsetCoordinate(from: anchor, northMeters: 96, eastMeters: 0),
                    accuracy: 11, date: base.addingTimeInterval(-70), speed: 2.6),
            ]

            let noisyStop: [LocationSample] = [
                LocationSample(
                    coordinate: offsetCoordinate(from: anchor, northMeters: 98, eastMeters: 0),
                    accuracy: 10, date: base.addingTimeInterval(-56), speed: 0.25),
                LocationSample(
                    coordinate: offsetCoordinate(from: anchor, northMeters: 100, eastMeters: 5),
                    accuracy: 10, date: base.addingTimeInterval(-42), speed: 0.30),
                LocationSample(
                    coordinate: offsetCoordinate(from: anchor, northMeters: 103, eastMeters: 8),
                    accuracy: 11, date: base.addingTimeInterval(-28), speed: 0.22),
                LocationSample(
                    coordinate: offsetCoordinate(from: anchor, northMeters: 107, eastMeters: 12),
                    accuracy: 11, date: base.addingTimeInterval(-14), speed: 0.18),
                LocationSample(
                    coordinate: offsetCoordinate(from: anchor, northMeters: 111, eastMeters: 16),
                    accuracy: 10, date: base.addingTimeInterval(-2), speed: 0.21),
            ]

            return traffic + noisyStop
        }

        private func offsetCoordinate(
            from origin: Coordinate, northMeters: Double, eastMeters: Double
        ) -> Coordinate {
            let metersPerDegreeLat = 111_320.0
            let latRadians = origin.latitude * .pi / 180
            let metersPerDegreeLon = max(1, metersPerDegreeLat * cos(latRadians))

            return Coordinate(
                latitude: origin.latitude + (northMeters / metersPerDegreeLat),
                longitude: origin.longitude + (eastMeters / metersPerDegreeLon)
            )
        }

        private func localizedOrFallback(_ key: String, fallback: String) -> String {
            let value = key.psLocalized
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == key {
                return fallback
            }
            return value
        }

        private func hasPremiumAccess(_ user: User) -> Bool {
            if user.statusId == 1 { return false }
            if normalizedStatus(user.status) == "free" { return false }

            if user.statusId == 2 || user.statusId == 3 { return true }
            if let normalized = normalizedStatus(user.status),
                normalized == "paid"
                    || normalized == "premium"
                    || normalized == "paid_monthly"
                    || normalized == "paid_lifetime"
            {
                return true
            }

            return user.isPremium
        }

        private func normalizedStatus(_ value: String?) -> String? {
            guard let value else { return nil }
            return
                value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
        }

        private func deleteAccount() async {
            guard let userId = authSession.currentUser?.id else { return }
            let deleteDataUseCase = DIContainer.shared.makeDeleteUserDataUseCase()
            await MainActor.run {
                isDeleting = true
                deleteErrorMessage = nil
            }
            do {
                try await deleteDataUseCase.execute(userId: userId)
                await MainActor.run {
                    router.navigateTo(.auth)
                    isDeleting = false
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    let message = error.localizedDescription.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    deleteErrorMessage =
                        message.isEmpty
                        ? "La suppression du compte a échoué. Réessayez.".psLocalized
                        : message
                }
            }
        }

    }

    private struct DebugMetricItem: Identifiable {
        let id: String
        let key: String
        let value: Int
    }

    private struct MinimalSectionHeader: View {
        let title: String

        var body: some View {
            Text(title.psLocalized)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)
        }
    }

    private struct MinimalProfileCard: View {
        let displayName: String
        let isLoggedIn: Bool
        let profilePhotoData: Data?
        let onEditProfile: () -> Void

        var body: some View {
            VStack(spacing: 14) {
                ZStack(alignment: .bottom) {
                    if let profilePhotoData, let image = UIImage(data: profilePhotoData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                            .foregroundStyle(.gray.opacity(0.55))
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(isLoggedIn ? .green : .gray)
                            .frame(width: 8, height: 8)
                        Text(
                            isLoggedIn
                                ? "settings.status.connected".psLocalized
                                : "settings.status.guest".psLocalized
                        )
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(isLoggedIn ? .green : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(Capsule())
                    .offset(y: 10)
                }
                .padding(.bottom, 8)

                Text(displayName)
                    .font(.title3)
                    .fontWeight(.bold)

                Button(action: onEditProfile) {
                    Text(
                        isLoggedIn
                            ? "settings.edit_profile".psLocalized
                            : "Se connecter".psLocalized
                    )
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.blue)
                    .background(
                        Color.blue.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .modifier(MinimalCardModifier())
        }
    }

    private struct MinimalPreferencesCard: View {
        @Binding var notificationsActives: Bool
        @Binding var backgroundParkingAssistanceEnabled: Bool
        let onManageAlerts: () -> Void
        let onManageZones: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "bell.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)

                    Text("settings.parking_alerts".psLocalized)
                        .font(.subheadline)

                    Spacer()

                    HStack(spacing: 10) {
                        Button("settings.manage".psLocalized, action: onManageAlerts)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.blue.opacity(0.12))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.blue.opacity(0.25), lineWidth: 1)
                            )
                            .buttonStyle(.plain)

                        Toggle("", isOn: $notificationsActives)
                            .labelsHidden()
                            .tint(.green)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)

                Divider().padding(.leading, 44)

                HStack(spacing: 12) {
                    Image(systemName: "car.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Background parking assistance".psLocalized)
                                .font(.subheadline)
                                .lineLimit(1)
                                .layoutPriority(1)

                            Text("Beta".psLocalized)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.blue.opacity(0.12))
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color.blue.opacity(0.24), lineWidth: 1)
                                )
                                .fixedSize()
                        }

                        Text("Requires Location: Always".psLocalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $backgroundParkingAssistanceEnabled)
                        .labelsHidden()
                        .tint(.green)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)

                Divider().padding(.leading, 44)

                HStack(spacing: 12) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)

                    Text("Frequent zones".psLocalized)
                        .font(.subheadline)

                    Spacer()

                    Button("settings.manage".psLocalized, action: onManageZones)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.blue.opacity(0.12))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.blue.opacity(0.25), lineWidth: 1)
                        )
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .padding(.vertical, 4)
            .modifier(MinimalCardModifier())
        }
    }

    private struct LanguageSettingsCard: View {
        @Binding var selection: String

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                Text("settings.language".psLocalized)
                    .font(.subheadline)

                Spacer(minLength: 12)

                Picker("settings.language".psLocalized, selection: $selection) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .modifier(MinimalCardModifier())
        }
    }

    private struct MinimalActionCard<Content: View>: View {
        @ViewBuilder let content: Content

        var body: some View {
            VStack(spacing: 0) {
                content
            }
            .padding(.vertical, 4)
            .modifier(MinimalCardModifier())
        }
    }

    private struct MinimalActionRow: View {
        let icon: String
        let title: String
        var titleColor: Color = .primary

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                Text(title.psLocalized)
                    .font(.subheadline)
                    .foregroundStyle(titleColor)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    private struct ProfileEditView: View {
        @EnvironmentObject private var authSession: AuthSession

        @State private var selectedPhotoItem: PhotosPickerItem?
        @State private var displayName: String = ""
        @State private var currentEmail: String = ""
        @State private var infoMessage: String?
        @State private var errorMessage: String?
        @State private var isSaving: Bool = false

        var body: some View {
            Form {
                Section("Photo de profil".psLocalized) {
                    HStack(spacing: 14) {
                        avatarView

                        PhotosPicker(
                            selection: $selectedPhotoItem, matching: .images,
                            photoLibrary: .shared()
                        ) {
                            Text("Changer la photo".psLocalized)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.blue.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                }

                Section("Nom et prénom".psLocalized) {
                    TextField("Nom complet".psLocalized, text: $displayName)
                        .textInputAutocapitalization(.words)

                    Button {
                        Task { await saveDisplayName() }
                    } label: {
                        Text("Enregistrer le nom".psLocalized)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.blue)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSaving
                    )
                    .opacity(
                        (displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSaving) ? 0.55 : 1.0)
                }

                Section("Email".psLocalized) {
                    NavigationLink {
                        ChangeEmailPage(currentEmail: currentEmail)
                    } label: {
                        SettingsNavigationRow(
                            title: "settings.edit_email".psLocalized,
                            subtitle: currentEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                                ? "Add a new address then confirm the code received."
                                : currentEmail
                        )
                    }
                }

                Section("Password".psLocalized) {
                    NavigationLink {
                        PasswordResetRequestPage(initialEmail: currentEmail)
                    } label: {
                        SettingsNavigationRow(
                            title: "settings.edit_password".psLocalized,
                            subtitle:
                                "Receive a secure link to choose a new password."
                        )
                    }
                }

                if let infoMessage {
                    Section {
                        Text(infoMessage)
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Edit Profile".psLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .onAppear {
                displayName = authSession.currentUser?.displayName ?? ""
                currentEmail = authSession.currentUser?.email ?? ""
            }
            .onChange(of: authSession.currentUser?.email) { _, updatedEmail in
                guard let updatedEmail, !updatedEmail.isEmpty else { return }
                currentEmail = updatedEmail
            }
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task { await applyPhoto(item) }
            }
        }

        @ViewBuilder
        private var avatarView: some View {
            if let data = authSession.profilePhotoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.gray.opacity(0.6))
            }
        }

        private func applyPhoto(_ item: PhotosPickerItem) async {
            errorMessage = nil
            infoMessage = nil

            guard let data = try? await item.loadTransferable(type: Data.self) else {
                errorMessage = "settings.photo_load_failed".psLocalized
                return
            }

            authSession.updateProfilePhoto(data)
            infoMessage = "settings.photo_updated".psLocalized
        }

        private func saveDisplayName() async {
            let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }

            await MainActor.run {
                isSaving = true
                errorMessage = nil
                infoMessage = nil
            }

            do {
                try await authSession.updateDisplayName(value)
                await MainActor.run {
                    infoMessage = "settings.display_name_updated".psLocalized
                    isSaving = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }

    private struct SettingsNavigationRow: View {
        let title: String
        let subtitle: String

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.psLocalized)
                    .foregroundStyle(.primary)

                Text(subtitle.psLocalized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 2)
        }
    }

    private struct ChangeEmailPage: View {
        @EnvironmentObject private var authSession: AuthSession
        @Environment(\.dismiss) private var dismiss

        @State private var currentEmail: String
        @State private var newEmail: String = ""
        @State private var infoMessage: String?
        @State private var errorMessage: String?
        @State private var isSaving: Bool = false
        @State private var pendingConfirmationEmail = ""
        @State private var showConfirmationCodePage = false

        init(currentEmail: String) {
            _currentEmail = State(initialValue: currentEmail)
        }

        var body: some View {
            Form {
                Section("Current Email".psLocalized) {
                    Text(currentEmailDisplayValue)
                        .foregroundStyle(currentEmail.isEmpty ? .secondary : .primary)
                }

                Section {
                    TextField("settings.email_placeholder".psLocalized, text: $newEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("settings.new_email".psLocalized)
                } footer: {
                    Text(
                        "A confirmation code will be sent to the new address to validate the change in the app."
                    )
                }

                Section {
                    Button {
                        Task { await saveEmail() }
                    } label: {
                        Group {
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Text("Send Code".psLocalized)
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.blue)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSendButtonDisabled)
                    .opacity(isSendButtonDisabled ? 0.55 : 1.0)
                }

                if let infoMessage {
                    Section {
                        Text(infoMessage)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("settings.edit_email_title".psLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .navigationDestination(isPresented: $showConfirmationCodePage) {
                ChangeEmailConfirmationCodePage(
                    email: pendingConfirmationEmail,
                    onEmailConfirmed: {
                        dismiss()
                    }
                )
                    .environmentObject(authSession)
            }
            .onAppear {
                currentEmail = authSession.currentUser?.email ?? currentEmail
            }
            .onChange(of: authSession.currentUser?.email) { _, updatedEmail in
                guard let updatedEmail, !updatedEmail.isEmpty else { return }
                currentEmail = updatedEmail
            }
        }

        private var currentEmailDisplayValue: String {
            let trimmed = currentEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "No email address available.".psLocalized : trimmed
        }

        private var isSendButtonDisabled: Bool {
            let trimmedNewEmail = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCurrentEmail = currentEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedNewEmail.isEmpty
                || isSaving
                || trimmedNewEmail.lowercased() == trimmedCurrentEmail.lowercased()
        }

        private func saveEmail() async {
            let value = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else { return }

            guard value != currentEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            else {
                await MainActor.run {
                    errorMessage = "Enter an email address different from the current one.".psLocalized
                    infoMessage = nil
                }
                return
            }

            await MainActor.run {
                isSaving = true
                errorMessage = nil
                infoMessage = nil
            }

            do {
                let result = try await authSession.updateEmail(value)
                await MainActor.run {
                    infoMessage = result.message
                    pendingConfirmationEmail = result.pendingEmail
                    showConfirmationCodePage = result.requiresEmailConfirmationCode
                    isSaving = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }

    private struct ChangeEmailConfirmationCodePage: View {
        let email: String
        let onEmailConfirmed: () -> Void

        @EnvironmentObject private var authSession: AuthSession
        @Environment(\.dismiss) private var dismiss

        @State private var code = ""
        @State private var infoMessage: String?
        @State private var errorMessage: String?
        @State private var isSubmitting = false

        var body: some View {
            Form {
                Section {
                    Text(
                        String(
                            format: "A confirmation code has been sent to %@. Enter it here to confirm the email change directly in the app.".psLocalized,
                            email
                        )
                    )
                    .font(.footnote)
                }

                Section("Confirmation Code".psLocalized) {
                    TextField("123456", text: $code)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                }

                Section {
                    Button {
                        Task { await submitCode() }
                    } label: {
                        Group {
                            if isSubmitting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Validate Code".psLocalized)
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.blue)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        isSubmitting || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .opacity(
                        (isSubmitting
                            || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            ? 0.55 : 1.0
                    )
                }

                if let infoMessage {
                    Section {
                        Text(infoMessage)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Confirmation Code".psLocalized)
            .navigationBarTitleDisplayMode(.inline)
        }

        private func submitCode() async {
            await MainActor.run {
                errorMessage = nil
                infoMessage = nil
                isSubmitting = true
            }

            do {
                let result = try await authSession.confirmEmailChange(
                    newEmail: email,
                    code: code
                )

                // Ensure local auth snapshot (/auth/me via refresh token) is up to date.
                try await authSession.refreshCurrentUserSession()

                let refreshedEmail = await MainActor.run {
                    authSession.currentUser?.email
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() ?? ""
                }
                let expectedEmail = email
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard refreshedEmail == expectedEmail else {
                    throw APIError.badRequest(
                        "The OTP code was validated but the email has not yet been applied. Please try again.".psLocalized
                    )
                }

                await MainActor.run {
                    infoMessage = result.message
                    code = ""
                    dismiss()
                    onEmailConfirmed()
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }

    private struct PasswordResetRequestPage: View {
        @EnvironmentObject private var authSession: AuthSession

        @State private var email: String
        @State private var infoMessage: String?
        @State private var errorMessage: String?
        @State private var isSubmitting: Bool = false
        @State private var pendingConfirmationEmail = ""
        @State private var showConfirmationCodePage = false

        init(initialEmail: String) {
            _email = State(initialValue: initialEmail)
        }

        var body: some View {
            Form {
                Section {
                    Text(
                        "Enter your email address and we'll send you a secure link to set a new password."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("Email Address".psLocalized) {
                    Text(
                        email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "settings.email_placeholder".psLocalized : email
                    )
                    .foregroundStyle(
                        email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? .secondary : .primary
                    )
                }

                Section {
                    Button {
                        Task { await sendPasswordResetLink() }
                    } label: {
                        Group {
                            if isSubmitting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Send Reset Link".psLocalized)
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.blue)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSubmitting
                    )
                    .opacity(
                        (email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSubmitting)
                            ? 0.55 : 1.0
                    )
                }

                if let infoMessage {
                    Section {
                        Text(infoMessage)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Réinitialiser le mot de passe".psLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .onAppear {
                email = authSession.currentUser?.email ?? email
            }
            .navigationDestination(isPresented: $showConfirmationCodePage) {
                PasswordResetEmailConfirmationCodeView(email: pendingConfirmationEmail)
            }
        }

        private func sendPasswordResetLink() async {
            await MainActor.run {
                isSubmitting = true
                errorMessage = nil
                infoMessage = nil
            }

            do {
                let result = try await authSession.requestPasswordReset(email: email)
                await MainActor.run {
                    infoMessage = result.message
                    if result.requiresEmailConfirmationCode {
                        pendingConfirmationEmail = email.trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        showConfirmationCodePage = true
                    }
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }

    private struct MinimalCardModifier: ViewModifier {
        func body(content: Content) -> some View {
            content
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 3)
        }
    }

    private enum SettingsAlert: Identifiable {
        case choosePhoto
        case photoAccessDenied
        case deleteAccount
        case success(String)
        case error(String)

        var id: String {
            switch self {
            case .choosePhoto:
                return "choosePhoto"
            case .photoAccessDenied:
                return "photoAccessDenied"
            case .deleteAccount:
                return "deleteAccount"
            case .success(let message):
                return "success-\(message)"
            case .error(let message):
                return "error-\(message)"
            }
        }
    }

    private struct SettingsRow: View {
        let title: String
        var subtitle: String? = nil
        let systemImage: String
        let tint: Color
        var titleColor: Color = .primary
        var showsChevron: Bool = true

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.psLocalized)
                        .foregroundStyle(titleColor)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle.psLocalized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
    }

    struct NotificationSettingsView: View {
        @AppStorage(AppConfig.parkingWarning1EnabledKey) private var warning1Enabled = true
        @AppStorage(AppConfig.parkingWarning2EnabledKey) private var warning2Enabled = true
        @AppStorage(AppConfig.parkingWarning1MinutesKey) private var warning1Minutes = AppConfig
            .defaultParkingWarning1Minutes
        @AppStorage(AppConfig.parkingWarning2MinutesKey) private var warning2Minutes = AppConfig
            .defaultParkingWarning2Minutes
        @State private var debugStatusMessage: String?
        private let notificationService: NotificationServiceProtocol = DIContainer.shared
            .notificationService
        private var configuredAlertsSummary: String {
            var parts: [String] = []
            if warning1Enabled {
                parts.append(
                    String(format: "Reminder at %d min".psLocalized, warning1Minutes)
                )
            }
            if warning2Enabled {
                parts.append(
                    String(format: "Final warning at %d min".psLocalized, warning2Minutes)
                )
            }

            if parts.isEmpty {
                return "No alert enabled".psLocalized
            }
            return parts.joined(separator: " • ")
        }

        var body: some View {
            List {
                Section {
                    HStack(spacing: 10) {
                        alertStatusTile(
                            title: "Alert 1",
                            isEnabled: warning1Enabled,
                            minutes: warning1Minutes,
                            color: .blue,
                            icon: "1.circle.fill"
                        )
                        alertStatusTile(
                            title: "Alert 2",
                            isEnabled: warning2Enabled,
                            minutes: warning2Minutes,
                            color: .orange,
                            icon: "2.circle.fill"
                        )
                    }
                } header: {
                    Text("Overview".psLocalized)
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "1.circle.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Alert 1".psLocalized)
                                .font(.subheadline.weight(.semibold))
                            Text("Reminder".psLocalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $warning1Enabled)
                            .labelsHidden()
                            .tint(.green)
                    }
                    if warning1Enabled {
                        ClockStyleMinutesPicker(totalMinutes: $warning1Minutes)
                    }
                } header: {
                    Text("Configuration".psLocalized)
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "2.circle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Alert 2".psLocalized)
                                .font(.subheadline.weight(.semibold))
                            Text("Final warning".psLocalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $warning2Enabled)
                            .labelsHidden()
                            .tint(.green)
                    }
                    if warning2Enabled {
                        ClockStyleMinutesPicker(totalMinutes: $warning2Minutes)
                    }
                } footer: {
                    if !warning1Enabled && !warning2Enabled {
                        Text("Enable at least one alert to be notified before expiration.".psLocalized)
                    } else {
                        Text(configuredAlertsSummary)
                    }
                }

                #if DEBUG
                    Section("Debug notifications".psLocalized) {
                        Button("Test alert 1 (1s)".psLocalized) {
                            sendDebugNotification(kind: .warning1)
                        }

                        Button("Test alert 2 (1s)".psLocalized) {
                            sendDebugNotification(kind: .warning2)
                        }

                        Button("Test expiration (1s)".psLocalized) {
                            sendDebugNotification(kind: .expired)
                        }

                        if let debugStatusMessage, !debugStatusMessage.isEmpty {
                            Text(debugStatusMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                #endif
            }
            .navigationTitle("settings.notifications_title".psLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .listStyle(.insetGrouped)
            .onAppear {
                notificationService.syncPendingAlertsWithPreferences()
            }
            .onChange(of: warning1Enabled) { _, _ in
                notificationService.syncPendingAlertsWithPreferences()
            }
            .onChange(of: warning2Enabled) { _, _ in
                notificationService.syncPendingAlertsWithPreferences()
            }
            .onChange(of: warning1Minutes) { _, _ in
                notificationService.syncPendingAlertsWithPreferences()
            }
            .onChange(of: warning2Minutes) { _, _ in
                notificationService.syncPendingAlertsWithPreferences()
            }
        }

        private func alertStatusTile(
            title: String,
            isEnabled: Bool,
            minutes: Int,
            color: Color,
            icon: String
        ) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                    Text(title.psLocalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(isEnabled ? String(format: "%d min", minutes) : "Off".psLocalized)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }

        #if DEBUG
            private func sendDebugNotification(kind: DebugNotificationKind) {
                let center = UNUserNotificationCenter.current()
                center.getNotificationSettings { settings in
                    switch settings.authorizationStatus {
                    case .authorized, .provisional, .ephemeral:
                        scheduleDebugNotification(center: center, kind: kind)
                    case .notDetermined:
                        center.requestAuthorization(options: [.alert, .sound, .badge]) {
                            granted, _ in
                            if granted {
                                scheduleDebugNotification(center: center, kind: kind)
                            } else {
                                Task { @MainActor in
                                    debugStatusMessage = "Notifications denied".psLocalized
                                }
                            }
                        }
                    case .denied:
                        Task { @MainActor in
                            debugStatusMessage = "Notifications disabled in iOS settings".psLocalized
                        }
                    @unknown default:
                        Task { @MainActor in
                            debugStatusMessage = "Unknown notification status".psLocalized
                        }
                    }
                }
            }

            private func scheduleDebugNotification(
                center: UNUserNotificationCenter, kind: DebugNotificationKind
            ) {
                let prefix = "parkspot.debug.notification-settings."
                center.getPendingNotificationRequests { pending in
                    let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
                    if !ids.isEmpty {
                        center.removePendingNotificationRequests(withIdentifiers: ids)
                    }
                }

                let descriptor = kind.descriptor
                let content = UNMutableNotificationContent()
                content.title = descriptor.title
                content.body = descriptor.body
                content.sound = .default
                content.threadIdentifier = descriptor.threadIdentifier
                content.userInfo["parkspot.smartAway.source"] = descriptor.source
                if #available(iOS 15.0, *) {
                    content.interruptionLevel = .timeSensitive
                }

                let identifier = "\(prefix)\(kind.rawValue).\(UUID().uuidString)"
                let request = UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                )

                center.add(request) { error in
                    Task { @MainActor in
                        if let error {
                            debugStatusMessage = String(
                                format: "Notification failed (%@): %@".psLocalized,
                                descriptor.label,
                                error.localizedDescription
                            )
                        } else {
                            debugStatusMessage = String(
                                format: "Notification scheduled (%@) ✅ (1s)".psLocalized,
                                descriptor.label
                            )
                        }
                    }
                }
            }

            private enum DebugNotificationKind: String {
                case warning1
                case warning2
                case expired

                var descriptor:
                    (
                        title: String, body: String, threadIdentifier: String, source: String,
                        label: String
                    )
                {
                    switch self {
                    case .warning1:
                        return (
                            title: "⚠️ Alert 1".psLocalized,
                            body: "Test notification: alert 1 before expiration.".psLocalized,
                            threadIdentifier: "parkspot.parking.warning1",
                            source: "settings-notif-debug-warning1",
                            label: "alert 1".psLocalized
                        )
                    case .warning2:
                        return (
                            title: "🚨 Alert 2".psLocalized,
                            body: "Test notification: alert 2 before expiration.".psLocalized,
                            threadIdentifier: "parkspot.parking.warning2",
                            source: "settings-notif-debug-warning2",
                            label: "alert 2".psLocalized
                        )
                    case .expired:
                        return (
                            title: "⏰ Parking expired".psLocalized,
                            body: "Test notification: timer expired.".psLocalized,
                            threadIdentifier: "parkspot.parking.expired",
                            source: "settings-notif-debug-expired",
                            label: "expired".psLocalized
                        )
                    }
                }
            }
        #endif
    }

    private struct ClockStyleMinutesPicker: View {
        @Binding var totalMinutes: Int

        private var hoursBinding: Binding<Int> {
            Binding(
                get: { totalMinutes / 60 },
                set: { newHours in
                    let mins = totalMinutes % 60
                    totalMinutes = clampMinutes((newHours * 60) + mins)
                }
            )
        }

        private var minutesBinding: Binding<Int> {
            Binding(
                get: { totalMinutes % 60 },
                set: { newMinutes in
                    let hrs = totalMinutes / 60
                    totalMinutes = clampMinutes((hrs * 60) + newMinutes)
                }
            )
        }

        var body: some View {
            VStack(spacing: 10) {
                Text(formattedDuration(totalMinutes))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)

                HStack(spacing: 0) {
                    Picker("Hours".psLocalized, selection: hoursBinding) {
                        ForEach(0...3, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipped()

                    Text("h")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)

                    Picker("Minutes".psLocalized, selection: minutesBinding) {
                        ForEach(0...59, id: \.self) { value in
                            Text(String(format: "%02d", value)).tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipped()

                    Text("min".psLocalized)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.systemGray6))
                )
            }
            .padding(.vertical, 4)
        }

        private func clampMinutes(_ value: Int) -> Int {
            min(max(value, 1), 180)
        }

        private func formattedDuration(_ minutes: Int) -> String {
            let h = minutes / 60
            let m = minutes % 60
            if h > 0 {
                return "\(h) h \(String(format: "%02d", m))"
            }
            return "\(m) min"
        }
    }

    struct AboutView: View {
        var body: some View {
            List {
                Section {
                    LabeledContent("settings.version".psLocalized, value: "1.0.0")
                    LabeledContent("settings.build".psLocalized, value: "100")
                    LabeledContent(
                        "settings.data_hosted".psLocalized,
                        value: "settings.eu".psLocalized)
                }
            }
            .navigationTitle("settings.about".psLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        }
    }

    private struct ShareSheet: UIViewControllerRepresentable {
        let activityItems: [Any]

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }

        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context)
        {}
    }

    private struct EditNameSheet: View {
        @Environment(\.dismiss) private var dismiss
        @State var name: String
        let onSave: (String) -> Void

        init(currentName: String, onSave: @escaping (String) -> Void) {
            _name = State(initialValue: currentName)
            self.onSave = onSave
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section("settings.display_name".psLocalized) {
                        TextField("settings.your_name".psLocalized, text: $name)
                            .textInputAutocapitalization(.words)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .tint(.blue)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color(.systemBackground), for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.cancel".psLocalized) { dismiss() }.foregroundStyle(
                            .blue)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.save".psLocalized) {
                            let value = name
                            dismiss()
                            onSave(value)
                        }
                        .foregroundStyle(.blue)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private struct QuickZonePreset: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let color: Color
    }

    struct ZoneNamingView: View {
        let userId: UUID

        @State private var zones: [FrequentZone] = []
        @State private var selectedZoneId: UUID?
        @State private var zone: FrequentZone?
        @State private var customName: String = "Other".psLocalized
        @State private var isDetailsEnabled: Bool = false
        @State private var zoneDetails: String = ""
        @State private var zoneLandmarkLevel: String = ""
        @State private var isTimerEnabled: Bool = false
        @State private var timerMinutes: Int = 60
        @State private var showCustomTimerPicker: Bool = false
        @State private var pickerHours: Int = 1
        @State private var pickerMinutes: Int = 0
        @State private var zoneAddress: String = "Unknown address".psLocalized
        @State private var isResolvingAddress: Bool = false
        @State private var isRefreshingZones: Bool = false
        @State private var pendingDeletionZone: FrequentZone?

        private let service = DIContainer.shared.frequentZoneService
        private let quickPresets: [QuickZonePreset] = [
            .init(
                title: "Home", symbol: "house.fill", color: DesignColors.accentBlue.opacity(0.18)),
            .init(
                title: "Shopping", symbol: "cart.fill",
                color: DesignColors.accentOrange.opacity(0.20)),
            .init(
                title: "Gym", symbol: "dumbbell.fill",
                color: DesignColors.accentGreen.opacity(0.20)),
            .init(title: "Station", symbol: "tram.fill", color: Color.red.opacity(0.18)),
        ]
        private let durationPresets = ["30m", "1h", "1h30", "2h", "+"]
        private let quickPresetColumns: [GridItem] = [GridItem(.flexible()), GridItem(.flexible())]
        private static let zoneVisitDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter
        }()

        var body: some View {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    if zones.isEmpty {
                        ContentUnavailableView(
                            "No frequent zones",
                            systemImage: "mappin.slash",
                            description: Text("There are no more zones to configure.".psLocalized)
                        )
                        .foregroundStyle(DesignColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    } else {
                        zoneSelectorSection

                        if let zone {
                            zoneMainCard(for: zone)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .refreshable {
                await refreshZonesFromDatabase()
            }
            .background(DesignColors.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .tint(DesignColors.accentBlue)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(DesignColors.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await refreshZonesFromDatabase()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshingZones)
                    .accessibilityLabel("Refresh zones".psLocalized)
                }
            }
            .onAppear(perform: loadZone)
            .sheet(isPresented: $showCustomTimerPicker) {
                customTimerPickerSheet
            }
            .confirmationDialog(
                "Delete this zone?".psLocalized,
                isPresented: Binding(
                    get: { pendingDeletionZone != nil },
                    set: { if !$0 { pendingDeletionZone = nil } }
                ), presenting: pendingDeletionZone
            ) { zone in
                Button("Cancel".psLocalized, role: .cancel) {}
                Button("Delete".psLocalized, role: .destructive) {
                    Task {
                        await service.deleteZone(zoneId: zone.id, userId: userId)
                    }

                    zones.removeAll { $0.id == zone.id }
                    if selectedZoneId == zone.id {
                        selectedZoneId = zones.first?.id
                    }
                    pendingDeletionZone = nil
                    loadZone()
                }
            } message: { zone in
                Text(String(format: "The zone \"%@\" will be permanently deleted.".psLocalized, zone.name))
            }
        }

        private var zonesOverviewCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(DesignColors.accentBlue.opacity(0.16))
                            .frame(width: 34, height: 34)

                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DesignColors.accentBlue)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zone management".psLocalized)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DesignColors.textPrimary)

                        Text(
                            String(
                                format: "Configured zones: %d".psLocalized,
                                zones.count
                            )
                        )
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DesignColors.textSecondary)
                    }

                    Spacer(minLength: 8)
                }

                Text("Choose a zone to edit its name, details, and maximum duration.".psLocalized)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(DesignColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .saveParkingCardStyle()
        }

        private var zoneSelectorSection: some View {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("ZONE SELECTION")
                    .padding(.horizontal, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(zones) { item in
                            zoneSelectorCard(for: item)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 1)
                }
            }
        }

        private func zoneSelectorCard(for item: FrequentZone) -> some View {
            let isSelected = item.id == selectedZoneId

            return Button {
                selectedZoneId = item.id
                applyZone(item)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(
                                isSelected ? DesignColors.accentBlue : DesignColors.textSecondary)

                        Text(normalizedZoneName(item.name))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DesignColors.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(String(format: "%d visits".psLocalized, item.visits))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DesignColors.textSecondary)

                    Text(
                        String(
                            format: "Last visit: %@".psLocalized,
                            Self.zoneVisitDateFormatter.string(from: item.lastVisitedAt)
                        )
                    )
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(DesignColors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 195, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    isSelected
                        ? DesignColors.accentBlue.opacity(0.18)
                        : DesignColors.buttonBackground
                )
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isSelected ? DesignColors.accentBlue : DesignColors.buttonBorder,
                            lineWidth: 1)
                )
                .shadow(color: DesignColors.buttonShadow, radius: 3, y: 1)
            }
            .buttonStyle(.plain)
        }

        private func zoneMainCard(for zone: FrequentZone) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                zoneAddressSection

                Divider()
                    .opacity(0.08)
                    .padding(.horizontal, 16)

                zoneConfigurationSection
            }
            .saveParkingCardStyle()
        }

        private var zoneAddressSection: some View {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("ZONE ADDRESS")
                    .padding(.top, 14)
                    .padding(.horizontal, 16)

                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(DesignColors.accentBlue.opacity(0.18))
                            .frame(width: 34, height: 34)

                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DesignColors.accentBlue)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(isResolvingAddress ? "Searching address…".psLocalized : zoneAddress)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DesignColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 14)
            }
        }

        private var zoneConfigurationSection: some View {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("QUICK NAMES")
                    .padding(.top, 14)
                    .padding(.horizontal, 16)

                LazyVGrid(columns: quickPresetColumns, spacing: 8) {
                    ForEach(quickPresets) { preset in
                        quickPresetButton(for: preset)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                sectionTitle("CUSTOM NAME")
                    .padding(.top, 14)
                    .padding(.horizontal, 16)

                customNameField
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                Divider()
                    .opacity(0.08)
                    .padding(.top, 16)
                    .padding(.horizontal, 16)

                HStack(spacing: 8) {
                    sectionTitle("ADD DETAILS")

                    Spacer()

                    Toggle("", isOn: $isDetailsEnabled)
                        .labelsHidden()
                        .tint(DesignColors.accentBlue)
                        .onChange(of: isDetailsEnabled) { _, enabled in
                            handleDetailsToggleChange(enabled)
                        }
                }
                .padding(.top, 14)
                .padding(.horizontal, 16)

                if isDetailsEnabled {
                    sectionTitle("DETAILS")
                        .padding(.top, 12)
                        .padding(.horizontal, 16)

                    detailsField
                        .padding(.horizontal, 14)
                        .padding(.top, 8)

                    NiveauCard(selectedNiveau: landmarkLevelBinding)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)

                    if !zoneLandmarkLevel.isEmpty {
                        Text(
                            String(
                                format: "settings.selected_landmark_format".psLocalized,
                                zoneLandmarkLevel)
                        )
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(DesignColors.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                }

                Divider()
                    .opacity(0.08)
                    .padding(.top, 16)
                    .padding(.horizontal, 16)

                HStack(spacing: 10) {
                    Text("MAX DURATION".psLocalized)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(DesignColors.textSecondary)

                    Spacer()

                    Toggle("", isOn: $isTimerEnabled)
                        .labelsHidden()
                        .tint(DesignColors.accentOrange)
                        .onChange(of: isTimerEnabled) { _, enabled in
                            handleTimerToggleChange(enabled)
                        }
                }
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, isTimerEnabled ? 8 : 0)

                if isTimerEnabled {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(durationPresets, id: \.self) { preset in
                                DurationChip(
                                    title: preset,
                                    isSelected: isDurationPresetSelected(preset),
                                    onTap: { selectDurationPreset(preset) }
                                )
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .padding(.bottom, 8)

                    Text(
                        String(
                            format: "Selected duration: %@".psLocalized,
                            formattedDuration(timerMinutes)
                        )
                    )
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DesignColors.textSecondary)
                        .padding(.horizontal, 16)
                }

                Button {
                    pendingDeletionZone = zone
                } label: {
                    Label("Delete this zone".psLocalized, systemImage: "trash.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color.red.opacity(0.95))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.red.opacity(0.14))
                        .cornerRadius(13)
                        .overlay(
                            RoundedRectangle(cornerRadius: 13)
                                .stroke(Color.red.opacity(0.28), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .disabled(zone == nil)
            }
        }

        private func sectionTitle(_ text: String) -> some View {
            Text(text.psLocalized)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(DesignColors.textSecondary)
        }

        private var landmarkLevelBinding: Binding<String> {
            Binding(
                get: { zoneLandmarkLevel },
                set: { newValue in
                    persistLevelMarker(newValue)
                }
            )
        }

        private func quickPresetButton(for preset: QuickZonePreset) -> some View {
            Button {
                customName = preset.title
                saveNameIfNeeded()
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(preset.color)
                            .frame(width: 34, height: 34)

                        Image(systemName: preset.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(
                                isQuickPresetSelected(preset)
                                    ? DesignColors.accentBlue : DesignColors.textSecondary)
                    }

                    Text(preset.title.psLocalized)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(
                            isQuickPresetSelected(preset)
                                ? DesignColors.textPrimary : DesignColors.textSecondary
                        )
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 56)
                .background(
                    isQuickPresetSelected(preset)
                        ? DesignColors.accentBlue.opacity(0.20)
                        : DesignColors.buttonBackground
                )
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isQuickPresetSelected(preset)
                                ? DesignColors.accentBlue : DesignColors.buttonBorder,
                            lineWidth: 1.2
                        )
                )
                .shadow(color: DesignColors.buttonShadow, radius: 3, y: 1)
            }
            .buttonStyle(.plain)
        }

        private var customNameField: some View {
            HStack(spacing: 8) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DesignColors.textSecondary)

                TextField("Custom name".psLocalized, text: $customName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DesignColors.textPrimary)
                    .onChange(of: customName) { _, _ in
                        saveNameIfNeeded()
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(DesignColors.buttonBackground)
            .cornerRadius(13)
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(DesignColors.buttonBorder, lineWidth: 1)
            )
            .shadow(color: DesignColors.buttonShadow, radius: 3, y: 1)
        }

        private var detailsField: some View {
            ZStack(alignment: .topLeading) {
                if zoneDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Add a detail…".psLocalized)
                        .font(.system(size: 15))
                        .foregroundColor(DesignColors.textTertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }

                TextEditor(text: $zoneDetails)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(DesignColors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 110)
                    .background(Color.clear)
                    .onChange(of: zoneDetails) { _, _ in
                        saveDetailsIfNeeded()
                    }
            }
            .background(DesignColors.buttonBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DesignColors.buttonBorder, lineWidth: 1)
            )
            .shadow(color: DesignColors.buttonShadow, radius: 3, y: 1)
        }

        private func isQuickPresetSelected(_ preset: QuickZonePreset) -> Bool {
            customName.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(preset.title) == .orderedSame
        }

        private func loadZone() {
            let allZones = service.zones(for: userId)
            applyLoadedZones(allZones)
        }

        private func applyLoadedZones(_ allZones: [FrequentZone]) {
            zones = allZones

            if let selectedZoneId,
                let selected = allZones.first(where: { $0.id == selectedZoneId })
            {
                applyZone(selected)
            } else if let first = allZones.first {
                selectedZoneId = first.id
                applyZone(first)
            } else {
                selectedZoneId = nil
                zone = nil
                customName = "Other".psLocalized
                zoneDetails = ""
                zoneLandmarkLevel = ""
                isDetailsEnabled = false
                isTimerEnabled = false
                timerMinutes = 60
                pickerHours = 1
                pickerMinutes = 0
                zoneAddress = "Unknown address".psLocalized
                isResolvingAddress = false
            }
        }

        private func refreshZonesFromDatabase() async {
            await MainActor.run {
                isRefreshingZones = true
            }

            let refreshedZones = await service.refreshZonesFromDatabase(for: userId)

            await MainActor.run {
                applyLoadedZones(refreshedZones)
                isRefreshingZones = false
            }
        }

        private func applyZone(_ selectedZone: FrequentZone) {
            zone = selectedZone
            customName = normalizedZoneName(selectedZone.name).isEmpty ? "Other".psLocalized : normalizedZoneName(selectedZone.name)
            zoneDetails = selectedZone.details ?? ""
            zoneLandmarkLevel = selectedZone.landmarkLevel ?? ""
            isDetailsEnabled =
                !(selectedZone.details?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ?? true)
            isTimerEnabled = (selectedZone.preferredDurationMinutes ?? 0) > 0
            timerMinutes = max(selectedZone.preferredDurationMinutes ?? 60, 5)
            pickerHours = timerMinutes / 60
            pickerMinutes = timerMinutes % 60

            resolveAddress(for: selectedZone.center)
        }

        private func normalizedZoneName(_ name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.caseInsensitiveCompare("Zone fréquente") == .orderedSame {
                return "Frequent zone".psLocalized
            }
            return trimmed
        }

        private func updateZoneInCollection(_ updatedZone: FrequentZone) {
            if let index = zones.firstIndex(where: { $0.id == updatedZone.id }) {
                zones[index] = updatedZone
            }
            zone = updatedZone
        }

        private func saveNameIfNeeded() {
            guard let zone else { return }
            Task {
                await service.renameZone(zoneId: zone.id, name: customName, userId: userId)
            }

            var updated = zone
            let cleaned = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                updated.name = cleaned
                updateZoneInCollection(updated)
            }
        }

        private func saveDetailsIfNeeded() {
            guard let zone, isDetailsEnabled else { return }
            Task {
                await service.setZoneDetails(zoneId: zone.id, details: zoneDetails, userId: userId)
            }

            var updated = zone
            let cleaned = zoneDetails.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.details = cleaned.isEmpty ? nil : cleaned
            updateZoneInCollection(updated)
        }

        private func handleDetailsToggleChange(_ enabled: Bool) {
            guard let zone else {
                isDetailsEnabled = false
                return
            }

            if enabled {
                // Do not persist anything just by enabling.
                // Details are only saved when user edits while switch is ON.
                return
            }

            zoneDetails = ""
            Task {
                await service.setZoneDetails(zoneId: zone.id, details: nil, userId: userId)
            }
            var updated = zone
            updated.details = nil
            updateZoneInCollection(updated)
        }

        private func persistLevelMarker(_ rawLevel: String) {
            let cleaned = rawLevel.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = cleaned.isEmpty ? nil : cleaned

            zoneLandmarkLevel = normalized ?? ""
            guard let zone else { return }

            let current = zone.landmarkLevel?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current != normalized else {
                return
            }

            Task {
                await service.setZoneLandmarkLevel(zoneId: zone.id, level: normalized, userId: userId)
            }
            var updated = zone
            updated.landmarkLevel = normalized
            updateZoneInCollection(updated)
        }

        private func selectDurationPreset(_ preset: String) {
            switch preset {
            case "30m": timerMinutes = 30
            case "1h": timerMinutes = 60
            case "1h30": timerMinutes = 90
            case "2h": timerMinutes = 120
            case "+":
                pickerHours = timerMinutes / 60
                pickerMinutes = timerMinutes % 60
                showCustomTimerPicker = true
                return
            default:
                return
            }

            persistTimerIfNeeded()
        }

        private func isDurationPresetSelected(_ preset: String) -> Bool {
            switch preset {
            case "30m": return timerMinutes == 30
            case "1h": return timerMinutes == 60
            case "1h30": return timerMinutes == 90
            case "2h": return timerMinutes == 120
            case "+": return ![30, 60, 90, 120].contains(timerMinutes)
            default: return false
            }
        }

        private func handleTimerToggleChange(_ enabled: Bool) {
            guard let zone else {
                isTimerEnabled = false
                return
            }

            if enabled {
                persistTimerIfNeeded()
                return
            }

            Task {
                await service.setPreferredDuration(zoneId: zone.id, minutes: nil, userId: userId)
            }
            var updated = zone
            updated.preferredDurationMinutes = nil
            updateZoneInCollection(updated)
        }

        private func persistTimerIfNeeded() {
            guard let zone, isTimerEnabled else { return }
            let clamped = min(max(timerMinutes, 5), 12 * 60)
            timerMinutes = clamped
            Task {
                await service.setPreferredDuration(zoneId: zone.id, minutes: clamped, userId: userId)
            }
            var updated = zone
            updated.preferredDurationMinutes = clamped
            updateZoneInCollection(updated)
        }

        private func formattedDuration(_ minutes: Int) -> String {
            let h = minutes / 60
            let m = minutes % 60
            if h > 0 && m > 0 { return "\(h) h \(m) min" }
            if h > 0 { return "\(h) h" }
            return "\(m) min"
        }

        private var customTimerPickerSheet: some View {
            NavigationStack {
                VStack(spacing: 10) {
                    HStack(spacing: 0) {
                        Picker("Hours".psLocalized, selection: $pickerHours) {
                            ForEach(0..<13, id: \.self) { value in
                                Text(String(format: "%d h".psLocalized, value)).tag(value)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)

                        Picker("Minutes".psLocalized, selection: $pickerMinutes) {
                            ForEach(Array(stride(from: 0, through: 55, by: 5)), id: \.self) {
                                value in
                                Text(String(format: "%02d min", value)).tag(value)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: 180)

                    Text(
                        String(
                            format: "Selected duration: %@".psLocalized,
                            "\(pickerHours) h \(String(format: "%02d", pickerMinutes))"
                        )
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .navigationTitle("Custom duration".psLocalized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color(.systemBackground), for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel".psLocalized) { showCustomTimerPicker = false }
                            .foregroundStyle(DesignColors.accentBlue)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done".psLocalized) {
                            timerMinutes = max((pickerHours * 60) + pickerMinutes, 5)
                            persistTimerIfNeeded()
                            showCustomTimerPicker = false
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignColors.accentBlue)
                    }
                }
            }
            .presentationDetents([.height(320)])
        }

        private func resolveAddress(for coordinate: Coordinate) {
            isResolvingAddress = true
            let geocoder = CLGeocoder()
            let location = CLLocation(
                latitude: coordinate.latitude, longitude: coordinate.longitude)

            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                defer { isResolvingAddress = false }

                guard let placemark = placemarks?.first else {
                    zoneAddress = streetViewFallbackAddress(for: coordinate)
                    return
                }

                let line1Parts = [placemark.subThoroughfare, placemark.thoroughfare]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                let line2Parts = [placemark.postalCode, placemark.locality]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }

                let line1 = line1Parts.joined(separator: " ")
                let line2 = line2Parts.joined(separator: " ")
                let zone = placemark.subLocality
                let country = placemark.country

                let composed = [line1, line2, zone, country]
                    .compactMap { value -> String? in
                        guard let value,
                            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { return nil }
                        return value
                    }
                    .joined(separator: ", ")

                zoneAddress = composed.isEmpty ? streetViewFallbackAddress(for: coordinate) : composed
            }
        }

        private func streetViewFallbackAddress(for coordinate: Coordinate) -> String {
            let lat = String(
                format: "%.5f",
                locale: Locale(identifier: "en_US_POSIX"),
                coordinate.latitude
            )
            let lon = String(
                format: "%.5f",
                locale: Locale(identifier: "en_US_POSIX"),
                coordinate.longitude
            )
            return "Street View: \(lat), \(lon)"
        }
    }

    extension View {
        fileprivate func saveParkingCardStyle() -> some View {
            self
                .background(DesignColors.cardBackground)
                .cornerRadius(18)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(DesignColors.cardBorder, lineWidth: 0.5)
                )
        }
    }

#else

    import SwiftUI

    struct SettingsView: View {
        var body: some View {
            Text("Settings unavailable on this platform".psLocalized)
                .foregroundStyle(.secondary)
                .padding()
        }
    }

#endif
