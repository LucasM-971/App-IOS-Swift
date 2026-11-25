// RootView.swift
// Renders the correct top-level screen based on AppRouter state

import Combine
import CoreLocation
import SwiftUI
import UIKit
import UserNotifications

struct RootView: View {
    private enum BootstrapTiming {
        static let minimumLaunchDelayNs: UInt64 = 40_000_000
        static let maximumBootstrapWaitNs: UInt64 = 450_000_000
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authSession: AuthSession
    @AppStorage("app.hasCompletedWelcome") private var hasCompletedWelcome = false
    @AppStorage("debug.requiredSettings.forcePage") private var debugForceRequiredSettingsPage = false
    @State private var isShowingLaunchScreen = true
    @State private var didStartBootstrap = false
    @State private var manuallyDismissedRequiredSettingsGate = false
    @StateObject private var requiredSettingsGate = RequiredSettingsGate()

    var body: some View {
        rootContent
            .transition(.opacity)
            .task {
                guard !didStartBootstrap else { return }
                didStartBootstrap = true
                await bootstrapApp()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, !isShowingLaunchScreen else { return }
                manuallyDismissedRequiredSettingsGate = false
                Task {
                    await requiredSettingsGate.refresh()
                }
            }
            .onChange(of: authSession.currentUser?.id) { _, _ in
                guard !isShowingLaunchScreen else { return }
                syncRoute()
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if isShowingLaunchScreen {
            LaunchLoadingView()
        } else if shouldPresentRequiredSettingsGate {
            requiredSettingsView
        } else {
            routeContent
        }
    }

    private var shouldPresentRequiredSettingsGate: Bool {
        #if DEBUG
            if debugForceRequiredSettingsPage {
                return true
            }
        #endif

        if manuallyDismissedRequiredSettingsGate {
            return false
        }

        guard requiredSettingsGate.shouldBlockApp else { return false }

        switch router.currentRoute {
        case .main:
            return true
        case .onboarding, .auth, .signedOutConfirmation, .emailConfirmation, .emailVerifiedSuccess:
            return false
        }
    }

    private var requiredSettingsView: some View {
        RequiredSettingsView(
            missingRequirements: missingRequirementsForDisplay,
            isDebugForced: debugForceRequiredSettingsPage,
            onOpenSettings: requiredSettingsGate.openAppSettings,
            onRefresh: {
                Task {
                    await requiredSettingsGate.refresh()
                }
            },
            onDisableDebugOverride: {
                debugForceRequiredSettingsPage = false
                manuallyDismissedRequiredSettingsGate = true
                Task {
                    await requiredSettingsGate.refresh()
                }
            }
        )
    }

    private var missingRequirementsForDisplay: [RequiredSettingIssue] {
        #if DEBUG
            if debugForceRequiredSettingsPage, requiredSettingsGate.missingRequirements.isEmpty {
                return [.locationPermissionDenied]
            }
        #endif

        return requiredSettingsGate.missingRequirements
    }

    @ViewBuilder
    private var routeContent: some View {
        switch router.currentRoute {
        case .onboarding:
            OnboardingView()
        case .auth:
            AuthView()
        case .signedOutConfirmation:
            SignedOutConfirmationView()
        case .emailConfirmation(let email):
            EmailConfirmationView(email: email)
        case .emailVerifiedSuccess:
            EmailVerifiedSuccessView()
        case .main:
            MainTabView()
        }
    }

    private func bootstrapApp() async {
        if authSession.didFinishInitialLoad {
            await requiredSettingsGate.refresh()
            await MainActor.run {
                syncRoute()
                withAnimation(.easeInOut(duration: 0.2)) {
                    isShowingLaunchScreen = false
                }
            }
            return
        }

        async let minimumDelay: Void = {
            try? await Task.sleep(nanoseconds: BootstrapTiming.minimumLaunchDelayNs)
        }()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await authSession.waitUntilInitialRouteCanBeResolved()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: BootstrapTiming.maximumBootstrapWaitNs)
            }
            _ = await group.next()
            group.cancelAll()
        }

        _ = await minimumDelay

        await requiredSettingsGate.refresh()
        await MainActor.run {
            syncRoute()
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingLaunchScreen = false
            }
        }
    }

    private func syncRoute() {
        if case .emailConfirmation = router.currentRoute {
            return
        }

        if authSession.isLogged {
            if router.currentRoute != .main {
                router.navigateTo(.main)
            }
            return
        }

        // First launch: keep the user on welcome screen.
        guard hasCompletedWelcome else {
            if router.currentRoute != .onboarding {
                router.navigateTo(.onboarding)
            }
            return
        }

        // Logged out after onboarding: default to app in guest mode.
        if router.currentRoute == .onboarding {
            router.navigateTo(.main)
        }
    }
}

@MainActor
private final class RequiredSettingsGate: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var missingRequirements: [RequiredSettingIssue] = []

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
    }

    var shouldBlockApp: Bool {
        false
    }

    func refresh() async {
        var nextRequirements: [RequiredSettingIssue] = []
        let authorizationStatus = locationManager.authorizationStatus
        let locationServicesEnabled = await readLocationServicesEnabled()

        if !locationServicesEnabled {
            nextRequirements.append(.locationServicesDisabled)
        }

        switch authorizationStatus {
        case .authorizedWhenInUse:
            nextRequirements.append(.locationAlwaysRequired)
        case .denied, .restricted:
            if locationServicesEnabled {
                nextRequirements.append(.locationPermissionDenied)
            }
        case .notDetermined, .authorizedAlways:
            break
        @unknown default:
            break
        }

        if locationServicesEnabled,
            authorizationStatus.isLocationAuthorized,
            locationManager.accuracyAuthorization == .reducedAccuracy
        {
            nextRequirements.append(.preciseLocationRequired)
        }

        let notificationStatus = await currentNotificationStatus()
        switch notificationStatus {
        case .denied:
            nextRequirements.append(.notificationsDisabled)
        case .authorized, .notDetermined, .provisional, .ephemeral:
            break
        @unknown default:
            break
        }

        missingRequirements = nextRequirements
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task {
            await refresh()
        }
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
            UIApplication.shared.canOpenURL(url)
        else {
            return
        }

        UIApplication.shared.open(url)
    }

    private func currentNotificationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    nonisolated private func readLocationServicesEnabled() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            CLLocationManager.locationServicesEnabled()
        }.value
    }
}

private enum RequiredSettingIssue: String, Identifiable {
    case locationServicesDisabled
    case locationPermissionDenied
    case locationAlwaysRequired
    case preciseLocationRequired
    case notificationsDisabled

    var id: String { rawValue }

    var affectsLocation: Bool {
        switch self {
        case .locationServicesDisabled, .locationPermissionDenied, .locationAlwaysRequired,
            .preciseLocationRequired:
            return true
        case .notificationsDisabled:
            return false
        }
    }

    var instructionSteps: [RequiredSettingsStep] {
        switch self {
        case .locationServicesDisabled:
            return [
                RequiredSettingsStep(
                    id: "location-services",
                    symbolName: "location.slash.fill",
                    tint: Color(hex: "1D9BF0"),
                    title: "Turn on Location Services"
                )
            ]
        case .locationPermissionDenied:
            return [
                RequiredSettingsStep(
                    id: "parkspot-location-menu",
                    symbolName: "location.square.fill",
                    tint: Color(hex: "2F80FF"),
                    title: "Select Location"
                ),
                RequiredSettingsStep(
                    id: "parkspot-location-authorization",
                    symbolName: "checkmark.circle.fill",
                    tint: Color(hex: "2F80FF"),
                    title: "Choose Always or While Using"
                ),
                RequiredSettingsStep(
                    id: "parkspot-location-precise",
                    symbolName: "scope",
                    tint: Color(hex: "2F80FF"),
                    title: "Turn on Precise Location"
                )
            ]
        case .locationAlwaysRequired:
            return [
                RequiredSettingsStep(
                    id: "parkspot-location-menu",
                    symbolName: "location.square.fill",
                    tint: Color(hex: "2F80FF"),
                    title: "Select Location"
                ),
                RequiredSettingsStep(
                    id: "parkspot-location-always",
                    symbolName: "checkmark.circle.fill",
                    tint: Color(hex: "2F80FF"),
                    title: "Choose Always"
                )
            ]
        case .preciseLocationRequired:
            return [
                RequiredSettingsStep(
                    id: "parkspot-location-menu",
                    symbolName: "location.square.fill",
                    tint: Color(hex: "2F80FF"),
                    title: "Select Location"
                ),
                RequiredSettingsStep(
                    id: "parkspot-location-precise",
                    symbolName: "scope",
                    tint: Color(hex: "2F80FF"),
                    title: "Turn on Precise Location"
                )
            ]
        case .notificationsDisabled:
            return [
                RequiredSettingsStep(
                    id: "parkspot-notifications",
                    symbolName: "bell.badge.fill",
                    tint: Color(hex: "FF9F0A"),
                    title: "Turn on Notifications"
                )
            ]
        }
    }
}

private struct RequiredSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme

    let missingRequirements: [RequiredSettingIssue]
    let isDebugForced: Bool
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void
    let onDisableDebugOverride: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let metrics = RequiredSettingsLayoutMetrics(
                size: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets,
                includesDebugAction: isDebugForced
            )

            ZStack {
                backgroundLayer

                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                    Spacer(minLength: metrics.topSpacer)
                    RequiredSettingsHero(isDarkMode: isDarkMode, scale: metrics.heroScale)
                    copySection(metrics: metrics)
                    stepsSection(metrics: metrics)
                    actionsSection(metrics: metrics)
                    Spacer(minLength: metrics.bottomSpacer)
                }
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.horizontal, metrics.horizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                #if DEBUG
                    if isDebugForced {
                        VStack {
                            HStack {
                                Spacer()
                                Button(action: onDisableDebugOverride) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(primaryTextColor)
                                        .frame(width: 44, height: 44)
                                        .background(panelFill, in: Circle())
                                        .overlay {
                                            Circle()
                                                .stroke(panelStroke, lineWidth: 1)
                                        }
                                }
                                .accessibilityLabel("Close debug page".psLocalized)
                            }
                            Spacer()
                        }
                        .padding(.top, max(12, proxy.safeAreaInsets.top + 6))
                        .padding(.horizontal, 20)
                    }
                #endif
            }
        }
    }

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var locationIsRequired: Bool {
        missingRequirements.contains(where: \.affectsLocation)
    }

    private var notificationsAreRequired: Bool {
        missingRequirements.contains(.notificationsDisabled)
    }

    private var instructionSteps: [RequiredSettingsStep] {
        missingRequirements
            .flatMap(\.instructionSteps)
            .reduce(into: [RequiredSettingsStep]()) { partialResult, step in
                guard !partialResult.contains(where: { $0.id == step.id }) else { return }
                partialResult.append(step)
            }
    }

    private var headlineText: String {
        switch (locationIsRequired, notificationsAreRequired) {
        case (true, true):
            return "ParkSpot needs your precise location and notifications for parking guidance and reminders.".psLocalized
        case (true, false):
            return "ParkSpot needs your precise location to save your car accurately and guide you back.".psLocalized
        case (false, true):
            return "ParkSpot needs notifications for parking reminders.".psLocalized
        case (false, false):
            return "ParkSpot needs a few permissions to continue.".psLocalized
        }
    }

    private var pageBackground: Color {
        isDarkMode ? Color(hex: "0B1220") : Color(hex: "F8FAFD")
    }

    private var panelFill: Color {
        isDarkMode ? Color.white.opacity(0.05) : Color.white.opacity(0.88)
    }

    private var panelStroke: Color {
        isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var primaryTextColor: Color {
        isDarkMode ? .white : Color(hex: "1A1D27")
    }

    private var secondaryTextColor: Color {
        isDarkMode ? Color.white.opacity(0.72) : Color(hex: "707887")
    }

    private var actionButtonGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: "5CAEFF"), Color(hex: "2F80FF")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    pageBackground,
                    isDarkMode ? Color(hex: "111B30") : Color(hex: "EEF4FF"),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color("BrandBlue").opacity(isDarkMode ? 0.16 : 0.12))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: 140, y: -220)
        }
    }

    private func copySection(metrics: RequiredSettingsLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.copySpacing) {
            Text("Required action".psLocalized)
                .font(.system(size: metrics.eyebrowFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(Color("BrandBlue"))

            Text(headlineText)
                .font(.system(size: metrics.headlineFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(primaryTextColor)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.86)
                .fixedSize(horizontal: false, vertical: true)

            Text("Go to Settings, then:".psLocalized)
                .font(.system(size: metrics.bodyFontSize, weight: .medium, design: .rounded))
                .foregroundStyle(secondaryTextColor)
        }
    }

    private func stepsSection(metrics: RequiredSettingsLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.stepGroupSpacing) {
            ForEach(Array(instructionSteps.enumerated()), id: \.element.id) { index, step in
                VStack(alignment: .leading, spacing: metrics.stepGroupSpacing) {
                    RequiredSettingsStepRow(step: step, isDarkMode: isDarkMode, metrics: metrics)
                    if index < instructionSteps.count - 1 {
                        Rectangle()
                            .fill(panelStroke)
                            .frame(height: 1)
                            .padding(.leading, metrics.dividerLeadingPadding)
                    }
                }
            }
        }
        .padding(.horizontal, metrics.cardHorizontalPadding)
        .padding(.vertical, metrics.cardVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
                .fill(panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(isDarkMode ? 0.16 : 0.04),
            radius: metrics.cardShadowRadius,
            y: metrics.cardShadowY
        )
    }

    private func actionsSection(metrics: RequiredSettingsLayoutMetrics) -> some View {
        VStack(spacing: metrics.actionSpacing) {
            Button(action: onOpenSettings) {
                Text("Settings".psLocalized)
                    .font(.system(size: metrics.primaryButtonFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, metrics.primaryButtonVerticalPadding)
            }
            .background(actionButtonGradient, in: Capsule())
            .shadow(
                color: Color("BrandBlue").opacity(isDarkMode ? 0.26 : 0.14),
                radius: metrics.buttonShadowRadius,
                y: metrics.buttonShadowY
            )

            Button(action: onRefresh) {
                Text("Check again".psLocalized)
                    .font(.system(size: metrics.secondaryButtonFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondaryTextColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, metrics.secondaryButtonVerticalPadding)
            }

            if isDebugForced {
                Button(action: onDisableDebugOverride) {
                    Text("Close debug page".psLocalized)
                        .font(.system(size: metrics.secondaryButtonFontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, metrics.secondaryButtonVerticalPadding)
                }
            }
        }
    }
}

private struct RequiredSettingsLayoutMetrics {
    let sectionSpacing: CGFloat
    let topSpacer: CGFloat
    let bottomSpacer: CGFloat
    let horizontalPadding: CGFloat
    let heroScale: CGFloat
    let copySpacing: CGFloat
    let eyebrowFontSize: CGFloat
    let headlineFontSize: CGFloat
    let bodyFontSize: CGFloat
    let stepGroupSpacing: CGFloat
    let cardHorizontalPadding: CGFloat
    let cardVerticalPadding: CGFloat
    let cardCornerRadius: CGFloat
    let cardShadowRadius: CGFloat
    let cardShadowY: CGFloat
    let stepRowSpacing: CGFloat
    let stepIconSize: CGFloat
    let stepIconCornerRadius: CGFloat
    let stepIconFontSize: CGFloat
    let stepTextFontSize: CGFloat
    let dividerLeadingPadding: CGFloat
    let actionSpacing: CGFloat
    let primaryButtonFontSize: CGFloat
    let primaryButtonVerticalPadding: CGFloat
    let secondaryButtonFontSize: CGFloat
    let secondaryButtonVerticalPadding: CGFloat
    let buttonShadowRadius: CGFloat
    let buttonShadowY: CGFloat

    init(size: CGSize, safeAreaInsets: EdgeInsets, includesDebugAction: Bool) {
        let height = size.height
        let tight = height < 700 || includesDebugAction
        let compact = height < 820 || includesDebugAction

        sectionSpacing = tight ? 12 : (compact ? 15 : 18)
        topSpacer = max(
            safeAreaInsets.top + (tight ? 8 : (compact ? 14 : 24)),
            height * (tight ? 0.035 : (compact ? 0.05 : 0.07))
        )
        bottomSpacer = max(safeAreaInsets.bottom + 4, tight ? 8 : 12)
        horizontalPadding = tight ? 22 : 28
        heroScale = tight ? 0.66 : (compact ? 0.74 : 0.82)
        copySpacing = tight ? 7 : 9
        eyebrowFontSize = tight ? 13 : 14
        headlineFontSize = tight ? 23 : (compact ? 25 : 27)
        bodyFontSize = tight ? 15 : 16
        stepGroupSpacing = tight ? 7 : 9
        cardHorizontalPadding = tight ? 13 : 15
        cardVerticalPadding = tight ? 12 : 14
        cardCornerRadius = compact ? 18 : 20
        cardShadowRadius = tight ? 10 : 14
        cardShadowY = tight ? 5 : 7
        stepRowSpacing = tight ? 12 : 14
        stepIconSize = tight ? 34 : 38
        stepIconCornerRadius = tight ? 11 : 13
        stepIconFontSize = tight ? 15 : 16
        stepTextFontSize = tight ? 15 : 16
        dividerLeadingPadding = stepIconSize + stepRowSpacing
        actionSpacing = tight ? 4 : 6
        primaryButtonFontSize = tight ? 17 : 18
        primaryButtonVerticalPadding = tight ? 12 : 14
        secondaryButtonFontSize = tight ? 13 : 14
        secondaryButtonVerticalPadding = tight ? 4 : 6
        buttonShadowRadius = tight ? 10 : 14
        buttonShadowY = tight ? 5 : 7
    }
}

private struct RequiredSettingsStep: Identifiable {
    let id: String
    let symbolName: String
    let tint: Color
    let title: LocalizedStringKey
}

private struct RequiredSettingsHero: View {
    let isDarkMode: Bool
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                ForEach([94.0, 68.0, 42.0], id: \.self) { size in
                    Circle()
                        .stroke(
                            Color(hex: "5CAEFF").opacity(ringOpacity(for: size)),
                            lineWidth: 10 * scale
                        )
                        .frame(width: size * scale, height: size * scale)
                }

                Circle()
                    .fill(isDarkMode ? Color.white : Color.black)
                    .frame(width: 14 * scale, height: 14 * scale)

                Capsule()
                    .fill(isDarkMode ? Color.white : Color.black)
                    .frame(width: 48 * scale, height: 6 * scale)
                    .rotationEffect(.degrees(-42))
                    .offset(x: 12 * scale, y: -16 * scale)
            }
            .frame(width: 108 * scale, height: 108 * scale)
            .offset(x: 20 * scale, y: -2 * scale)

            ZStack {
                Circle()
                    .fill(Color(hex: "FFD75E"))
                    .frame(width: 48 * scale, height: 48 * scale)

                Circle()
                    .stroke(isDarkMode ? Color(hex: "131722") : Color.black, lineWidth: 4 * scale)
                    .frame(width: 48 * scale, height: 48 * scale)

                Image(systemName: "car.fill")
                    .font(.system(size: 20 * scale, weight: .black))
                    .foregroundStyle(isDarkMode ? Color(hex: "131722") : Color.black)
            }
            .offset(x: 0, y: 10 * scale)
        }
        .frame(width: 130 * scale, height: 112 * scale, alignment: .leading)
    }

    private func ringOpacity(for size: Double) -> Double {
        isDarkMode ? 0.52 : 0.95
    }
}

private struct RequiredSettingsStepRow: View {
    let step: RequiredSettingsStep
    let isDarkMode: Bool
    let metrics: RequiredSettingsLayoutMetrics

    var body: some View {
        HStack(alignment: .center, spacing: metrics.stepRowSpacing) {
            RoundedRectangle(cornerRadius: metrics.stepIconCornerRadius, style: .continuous)
                .fill(step.tint.opacity(isDarkMode ? 0.18 : 0.12))
                .frame(width: metrics.stepIconSize, height: metrics.stepIconSize)
                .overlay {
                    Image(systemName: step.symbolName)
                        .font(.system(size: metrics.stepIconFontSize, weight: .semibold))
                        .foregroundStyle(step.tint)
                }

            Text(step.title)
                .font(.system(size: metrics.stepTextFontSize, weight: .medium, design: .rounded))
                .foregroundStyle(isDarkMode ? Color.white : Color(hex: "1A1D27"))
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

private extension CLAuthorizationStatus {
    var isLocationAuthorized: Bool {
        self == .authorizedAlways || self == .authorizedWhenInUse
    }
}
