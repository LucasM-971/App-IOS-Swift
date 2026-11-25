// HomeView.swift
// Main screen – map + bottom sheet, matches the approved design

#if canImport(UIKit)
import UIKit
import MapKit
import SwiftUI

struct HomeView: View {

    @EnvironmentObject private var authSession: AuthSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var vm: HomeViewModel

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
        latitudinalMeters: 800,
        longitudinalMeters: 800
    )
    @State private var showSaveSheet = false
    @State private var showPremiumSheet = false
    @State private var showPremiumUpsellPopup = false
    @State private var showEndAlert = false
    @State private var showErrorAlert = false
    @State private var showFindMyCarFullScreen = false
    @State private var manualSaveCoordinate: Coordinate?
    @State private var findCarTargetCoordinate: Coordinate?
    @State private var findCarDestinationName: String?
    @AppStorage("parkspot.map.is3DEnabled.v1") private var is3DMapEnabled = false
    @State private var isSheetExpanded = false
    @State private var lastRegionCenterUpdate: CLLocationCoordinate2D?
    @State private var isMapAutoFollowingUser = true
    @State private var mapViewportCommand = 0
    @State private var isViewVisible = false
    @AppStorage("parkspot.premium.upsell.lastShownAt.v1") private var premiumUpsellLastShownAt:
        Double = 0
    @AppStorage("parkspot.premium.upsell.appearCount.v1") private var premiumUpsellAppearCount:
        Int = 0

    init() {
        _vm = StateObject(wrappedValue: HomeViewModel())
    }

    var body: some View {
        contentWithPremiumOverlay
    }

    private var baseLayout: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                // MARK: – Map (full screen)
                mapLayer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: isActiveSessionExpandedFullscreen ? 1.2 : 0)

                if isActiveSessionExpandedFullscreen {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea()
                            .opacity(0.55)

                        Color.black
                            .opacity(0.24)
                            .ignoresSafeArea()
                    }
                    .transition(.opacity)

                    Color.clear
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                isSheetExpanded = false
                            }
                        }
                }

                // MARK: – Bottom Sheet (overlay)
                bottomSheet(containerWidth: proxy.size.width)

                if shouldShowAlwaysLocationBanner {
                    VStack {
                        AlwaysLocationPermissionBanner(
                            isSettingsRequired: vm.locationAuthorizationStatus.isDeniedOrRestricted,
                            onAction: handleAlwaysLocationPromptAction
                        )
                        .padding(.horizontal, 14)
                        .padding(.top, max(proxy.safeAreaInsets.top, 12) + 8)

                        Spacer(minLength: 0)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
                }
            }
            .animation(
                .spring(response: 0.3, dampingFraction: 0.85),
                value: isActiveSessionExpandedFullscreen
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: shouldShowAlwaysLocationBanner)
        }
    }

    private var contentWithLifecycle: some View {
        baseLayout
            .onAppear {
                isViewVisible = true
                EnergyManager.shared.transition(to: .foregroundIdle)
                vm.updateUserId(authSession.currentUser?.id)
                vm.setAppActive(true)
                openPendingCarPlaySaveSheetIfNeeded()
                vm.onAppear()
            }
            .onDisappear {
                isViewVisible = false
                EnergyManager.shared.transition(to: .background)
                vm.setAppActive(false)
                vm.onDisappear()
            }
    }

    private var contentWithObservers: some View {
        contentWithLifecycle
            .onChange(of: scenePhase) { _, phase in
                EnergyManager.shared.transition(
                    to: phase == .active ? .foregroundIdle : .background)
                vm.setAppActive(phase == .active)
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsViewDidAppear)) { _ in
                vm.setAppActive(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsViewDidDisappear)) { _ in
                guard isViewVisible, scenePhase == .active else { return }
                vm.setAppActive(true)
            }
            .onChange(of: authSession.currentUser?.id) { _, id in
                vm.updateUserId(id)
            }
            .onChange(of: vm.errorMessage) { _, message in
                showErrorAlert = message != nil
            }
            .onChange(of: vm.showSaveSheet) { _, shouldShow in
                if showSaveSheet != shouldShow {
                    showSaveSheet = shouldShow
                }
            }
            .onChange(of: showSaveSheet) { _, isPresented in
                if !isPresented {
                    vm.showSaveSheet = false
                    manualSaveCoordinate = nil
                }
            }
            .onChange(of: vm.pendingCarPlayDisconnectDirectSave) { _, shouldOpenSave in
                guard shouldOpenSave else { return }
                openPendingCarPlaySaveSheetIfNeeded()
            }
            .onChange(of: showFindMyCarFullScreen) { _, isPresented in
                vm.setAppActive(!isPresented)
            }
    }

    private var contentWithPresentations: some View {
        contentWithObservers
            .sheet(isPresented: $showSaveSheet) {
                SaveParkingSheet(vm: vm, manualCoordinate: manualSaveCoordinate)
            }
            .sheet(isPresented: $showPremiumSheet) {
                PremiumView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .interactiveDismissDisabled(false)
            }
            .fullScreenCover(
                isPresented: $showFindMyCarFullScreen,
                onDismiss: {
                    findCarTargetCoordinate = nil
                    findCarDestinationName = nil
                }
            ) {
                if let coordinate = findCarTargetCoordinate {
                    GuidanceScreen(
                        carCoordinate: coordinate,
                        destinationName: findCarDestinationName ?? vm.activeSession?.address
                    )
                } else {
                    Color.clear.ignoresSafeArea()
                }
            }
    }

    private var contentWithAlerts: some View {
        contentWithPresentations
            .alert(
                "common.error".psLocalized, isPresented: $showErrorAlert,
                presenting: vm.errorMessage
            ) { _ in
                Button("common.ok".psLocalized) { vm.errorMessage = nil }
            } message: { (message: String) in
                Text(message)
            }
            .alert(
                "Parking detected".psLocalized,
                isPresented: Binding(
                    get: { vm.pendingAutoParkingConfirmation != nil },
                    set: { _ in }
                ),
                presenting: vm.pendingAutoParkingConfirmation
            ) { detection in
                Button("Yes".psLocalized) {
                    vm.confirmPendingAutoParkingSuggestion()
                }
                Button("No".psLocalized, role: .cancel) {
                    vm.dismissPendingAutoParkingSuggestion()
                }
            } message: { detection in
                let confidence = Int((detection.confidence * 100).rounded())
                Text(
                    String(
                        format: "We detected that you just parked. Confirm saving this location? (confidence %d%%)".psLocalized,
                        confidence
                    )
                )
            }
            .alert(
                vm.smartAwayInAppAlertTitle ?? "Alert".psLocalized, isPresented: $vm.showSmartAwayInAppAlert
            ) {
                Button("common.ok".psLocalized) {
                    vm.showSmartAwayInAppAlert = false
                }
            } message: {
                Text(vm.smartAwayInAppAlertBody ?? "")
            }
            .alert(
                vm.pendingCarPlayDisconnectPrompt?.title.isEmpty == false
                    ? (vm.pendingCarPlayDisconnectPrompt?.title ?? "CarPlay")
                    : "CarPlay",
                isPresented: Binding(
                    get: { vm.pendingCarPlayDisconnectPrompt != nil },
                    set: { _ in }
                ),
                presenting: vm.pendingCarPlayDisconnectPrompt
            ) { _ in
                Button("Save".psLocalized) {
                    vm.dismissPendingCarPlayDisconnectPrompt()
                    showSaveSheet = true
                }
                Button("common.cancel".psLocalized, role: .cancel) {
                    vm.dismissPendingCarPlayDisconnectPrompt()
                }
            } message: { payload in
                Text(payload.body)
            }
    }

    private var contentWithPremiumOverlay: some View {
        contentWithAlerts
            .overlay {
                if showPremiumUpsellPopup {
                    FreeUserPremiumUpsellPopup(
                        onDismiss: dismissPremiumUpsell,
                        onOpenPremium: openPremiumFromUpsell
                    )
                }
            }
    }

    private func triggerPremiumUpsellIfNeeded() {
        guard authSession.currentUser != nil else { return }
        guard !hasPremiumAccess(authSession.currentUser) else { return }
        guard !showPremiumUpsellPopup else { return }
        guard !showPremiumSheet else { return }
        guard !showSaveSheet else { return }
        guard !showFindMyCarFullScreen else { return }
        guard vm.activeSession == nil else { return }
        guard !showEndAlert, !showErrorAlert else { return }
        guard vm.pendingAutoParkingConfirmation == nil else { return }

        premiumUpsellAppearCount += 1

        let now = Date().timeIntervalSince1970
        let minAppearInterval = 4
        let cooldown: TimeInterval = 60 * 60 * 18
        let reachedAppearInterval = premiumUpsellAppearCount % minAppearInterval == 0
        let cooldownPassed =
            premiumUpsellLastShownAt == 0 || (now - premiumUpsellLastShownAt) >= cooldown

        guard reachedAppearInterval, cooldownPassed else { return }

        premiumUpsellLastShownAt = now
        withAnimation {
            showPremiumUpsellPopup = true
        }
    }

    private func openSaveSheetFromMapCenter() {
        manualSaveCoordinate = nil

        if vm.userCoordinate == nil {
            manualSaveCoordinate = Coordinate(
                latitude: region.center.latitude,
                longitude: region.center.longitude
            )
        }

        showSaveSheet = true
    }

    private func dismissPremiumUpsell() {
        withAnimation {
            showPremiumUpsellPopup = false
        }
    }

    private func openPremiumFromUpsell() {
        dismissPremiumUpsell()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            showPremiumSheet = true
        }
    }

    private func openPendingCarPlaySaveSheetIfNeeded() {
        guard vm.pendingCarPlayDisconnectDirectSave else { return }
        vm.consumePendingCarPlayDisconnectDirectSave()
        vm.dismissPendingCarPlayDisconnectPrompt()
        showSaveSheet = true
    }

    private func hasPremiumAccess(_ user: User?) -> Bool {
        guard let user else { return false }
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

    // MARK: – Map Layer
    private var mapLayer: some View {
        HomeCustomMapView(
            region: $region,
            is3DEnabled: $is3DMapEnabled,
            isAutoFollowingUser: $isMapAutoFollowingUser,
            viewportCommand: mapViewportCommand,
            annotations: mapAnnotations,
            profilePhotoData: authSession.profilePhotoData,
            userHeading: vm.userHeading,
            guidanceRoute: guidanceRoute,
            uncertaintyCenter: uncertaintyCenter,
            uncertaintyRadiusMeters: uncertaintyRadiusMeters
        )
        .opacity(isDarkMode ? 1 : 0.98)
        .ignoresSafeArea()
        .onChange(of: vm.userCoordinate) { _, coord in
            guard isMapAutoFollowingUser else { return }
            guard let coord else { return }
            let target = CLLocationCoordinate2D(
                latitude: coord.latitude,
                longitude: coord.longitude
            )

            if let previous = lastRegionCenterUpdate {
                let moved = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(
                        from: CLLocation(latitude: target.latitude, longitude: target.longitude))
                guard moved >= 60 else { return }
            }

            lastRegionCenterUpdate = target
            mapViewportCommand += 1
            region.center = target
        }
        .overlay {
            if vm.activeSession == nil && vm.userCoordinate == nil {
                ManualMapCenterMarker()
            }
        }
        .overlay(alignment: .topTrailing) { mapControls }
    }

    private var guidanceRoute: [CLLocationCoordinate2D] {
        guard let user = vm.userCoordinate,
            user.isValidGeoCoordinate,
            let car = vm.activeSession?.coordinate,
            car.isValidGeoCoordinate
        else { return [] }
        return [
            CLLocationCoordinate2D(latitude: user.latitude, longitude: user.longitude),
            CLLocationCoordinate2D(latitude: car.latitude, longitude: car.longitude),
        ]
    }

    private var uncertaintyCenter: CLLocationCoordinate2D? {
        guard vm.selectedLocalizationMode != .bluetooth else { return nil }
        guard let session = vm.activeSession, session.isApproximate else { return nil }
        return CLLocationCoordinate2D(
            latitude: session.coordinate.latitude, longitude: session.coordinate.longitude)
    }

    private var uncertaintyRadiusMeters: Double? {
        guard let session = vm.activeSession, session.isApproximate else { return nil }
        return 80
    }

    private var mapAnnotations: [MapPin] {
        var items: [MapPin] = []

        if let session = vm.activeSession {
            if session.zone.isUndergroundType {
                items.append(
                    MapPin(
                        id: "car-zone-\(session.id.uuidString)",
                        coordinate: CLLocationCoordinate2D(
                            latitude: session.coordinate.latitude,
                            longitude: session.coordinate.longitude
                        ),
                        kind: .undergroundZone
                    )
                )
            }

            items.append(
                MapPin(
                    id: "car-\(session.id.uuidString)",
                    coordinate: CLLocationCoordinate2D(
                        latitude: session.coordinate.latitude,
                        longitude: session.coordinate.longitude
                    ),
                    kind: .car
                )
            )
        }

        if let user = vm.userCoordinate {
            items.append(
                MapPin(
                    id: "user-location",
                    coordinate: CLLocationCoordinate2D(
                        latitude: user.latitude,
                        longitude: user.longitude
                    ),
                    kind: .user
                )
            )
        }

        return items
    }

    // MARK: – Map controls
    private var mapControls: some View {
        VStack(spacing: 8) {
            MapModeControlButton(is3DEnabled: $is3DMapEnabled)
            MapControlButton(icon: "location.fill") {
                guard let coord = vm.userCoordinate else { return }
                isMapAutoFollowingUser = true
                mapViewportCommand += 1
                withAnimation {
                    region.center = CLLocationCoordinate2D(
                        latitude: coord.latitude, longitude: coord.longitude
                    )
                }
            }
            MapControlButton(icon: "minus") { zoomOut() }
            MapControlButton(icon: "plus") { zoomIn() }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, shouldShowAlwaysLocationBanner ? 178 : 60)
        .padding(.trailing, 14)
    }

    // MARK: – Bottom Sheet
    private func bottomSheet(containerWidth: CGFloat) -> some View {
        let hasActiveSession = vm.activeSession != nil
        let cornerRadius: CGFloat = hasActiveSession ? (isSheetExpanded ? 20 : 32) : 32
        let maxSheetWidth = containerWidth * 0.95
        let expandedSheetWidth = containerWidth * 0.98
        let targetSheetWidth =
            hasActiveSession
            ? (isSheetExpanded ? expandedSheetWidth : maxSheetWidth)
            : min(400, maxSheetWidth)

        return VStack(spacing: 0) {
            if hasActiveSession {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isSheetExpanded.toggle()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(hasActiveSession ? activeSessionHandleColor : Color(.systemGray4))
                            .frame(width: isSheetExpanded ? 44 : 36, height: 5)

                        HStack(spacing: 4) {
                            Image(systemName: isSheetExpanded ? "chevron.compact.down" : "chevron.compact.up")
                                .font(.system(size: 10, weight: .bold))

                            Text((isSheetExpanded ? "home.swipe_to_close" : "home.swipe_to_open").psLocalized)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(activeSessionToggleColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel((isSheetExpanded ? "home.collapse_details" : "home.show_details").psLocalized)
            } else {
                Capsule()
                    .fill(Color(.systemGray4))
                    .frame(width: 36, height: 4)
                    .padding(.top, 7)
                    .padding(.bottom, 6)
            }

            if let session = vm.activeSession {
                ActiveSessionContent(
                    session: session,
                    vm: vm,
                    isExpanded: isSheetExpanded,
                    airTagDisabled: isUndergroundMode,
                    onCollapse: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            isSheetExpanded = false
                        }
                    },
                    onEnd: { showEndAlert = true },
                    onNavigate: { openMapsNavigation(to: session.coordinate) },
                    onFindCar: {
                        findCarTargetCoordinate = session.coordinate
                        findCarDestinationName = session.address
                        showFindMyCarFullScreen = true
                    }
                )
            } else {
                let quickZones = vm.nearbyFrequentZones(for: vm.userCoordinate)
                NoSessionContent(
                    onSave: { openSaveSheetFromMapCenter() },
                    onQuickSaveWithZone: { zone in
                        vm.requestUseFrequentZoneShortcutFromHome(zone)
                        openSaveSheetFromMapCenter()
                    },
                    quickZones: quickZones,
                    showAutoParkingPending: shouldShowAutoParkingPendingInNoSession,
                    autoParkingPendingAddress: vm.pendingAutoParkingAddressForUI,
                    onOpenAutoParkingPending: { vm.openPendingAutoParkingDetectionInSaveSheet() },
                    onDismissAutoParkingPending: { vm.dismissPendingAutoParkingSuggestion() },
                    unfilteredAutoParkingAddress: vm.unfilteredAutoParkingAddressForUI,
                    canUseUnfilteredAutoParkingDetection: vm.canUseUnfilteredAutoParkingDetectionForUI,
                    onUseUnfilteredAutoParkingDetection: {
                        vm.useCurrentGPSAsUnfilteredAutoParkingDetection()
                    },
                    isUsingManualLocation: vm.userCoordinate == nil,
                    containerWidth: targetSheetWidth
                )
            }
        }
        .frame(width: targetSheetWidth, alignment: .top)
        .padding(.top, hasActiveSession ? 2 : 4)
        .padding(.bottom, hasActiveSession ? 0 : 0)
        .background(
            hasActiveSession
                ? activeSessionSheetBackgroundColor
                : noSessionSheetBackgroundColor,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    hasActiveSession ? activeSessionSheetBorderColor : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(
            color: .black.opacity(hasActiveSession ? 0.24 : 0.08),
            radius: hasActiveSession ? 16 : 10, y: -3
        )
        .frame(
            maxHeight: hasActiveSession
                ? activeSessionSheetHeight
                : noSessionSheetHeight,
            alignment: .top
        )
        .clipped()
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, hasActiveSession ? 5 : 14)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isSheetExpanded)
        .gesture(
            hasActiveSession
                ? DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        if value.translation.height < -40 {
                            isSheetExpanded = true
                        } else if value.translation.height > 40 {
                            isSheetExpanded = false
                        }
                    } : nil
        )
        .alert("home.end_parking_confirm_title".psLocalized, isPresented: $showEndAlert) {
            Button("home.end_parking".psLocalized, role: .destructive) {
                Task { await vm.endParking(userInitiated: true) }
            }
            Button("common.cancel".psLocalized, role: .cancel) {}
        }
    }

    // MARK: – Navigation
    private func handleAlwaysLocationPromptAction() {
        if vm.locationAuthorizationStatus.isDeniedOrRestricted {
            openAppSettings()
        } else {
            vm.requestAlwaysLocationAccess()
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func openMapsNavigation(to coordinate: Coordinate) {
        guard coordinate.isValidGeoCoordinate else { return }
        guard
            let url = URL(
                string:
                    "maps://?daddr=\(coordinate.latitude),\(coordinate.longitude)&dirflg=w"
            )
        else {
            return
        }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    private func zoomIn() {
        var span = region.span
        span.latitudeDelta = max(span.latitudeDelta / 2, 0.0005)
        span.longitudeDelta = max(span.longitudeDelta / 2, 0.0005)
        guard span.latitudeDelta.isFinite, span.longitudeDelta.isFinite else { return }
        mapViewportCommand += 1
        region.span = span
    }
    private func zoomOut() {
        var span = region.span
        span.latitudeDelta = min(span.latitudeDelta * 2, 180)
        span.longitudeDelta = min(span.longitudeDelta * 2, 180)
        guard span.latitudeDelta.isFinite, span.longitudeDelta.isFinite else { return }
        mapViewportCommand += 1
        region.span = span
    }

    private var isUndergroundMode: Bool {
        vm.activeSession?.zone.isUndergroundType == true
    }

    private var isActiveSessionExpandedFullscreen: Bool {
        vm.activeSession != nil && isSheetExpanded
    }

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var activeSessionHandleColor: Color {
        isDarkMode ? Color.white.opacity(0.30) : Color(.systemGray3)
    }

    private var activeSessionToggleColor: Color {
        isDarkMode ? Color.white.opacity(0.62) : Color(hex: "8E8E93")
    }

    private var activeSessionSheetBackgroundColor: Color {
        isDarkMode
            ? Color(red: 0.15, green: 0.15, blue: 0.17)
            : Color(.systemBackground)
    }

    private var noSessionSheetBackgroundColor: Color {
        isDarkMode
            ? Color(red: 0.15, green: 0.15, blue: 0.17)
            : Color(.systemBackground)
    }

    private var activeSessionSheetBorderColor: Color {
        Color.clear
    }

    private var activeSessionSheetHeight: CGFloat {
        guard let session = vm.activeSession else { return 220 }
        let hasTimer = (session.maxDuration ?? 0) > 0
        let hasPendingAutoEnd = vm.pendingAutoEndDeadline != nil

        if isSheetExpanded {
            let screenHeight = UIScreen.main.bounds.height
            let expandedHeight = screenHeight * 0.90
            let maxAllowed = screenHeight * 0.95
            return min(expandedHeight, maxAllowed)
        }

        var compactHeight: CGFloat = 212
        if hasTimer { compactHeight += 32 }
        if hasPendingAutoEnd { compactHeight += 40 }
        if isUndergroundMode { compactHeight += 14 }

        let maxAllowedCompact = UIScreen.main.bounds.height * 0.62
        return min(compactHeight, maxAllowedCompact)
    }

    private var noSessionSheetHeight: CGFloat {
        let quickZoneCount = min(vm.nearbyFrequentZones(for: vm.userCoordinate).count, 2)
        var base: CGFloat = quickZoneCount > 0 ? 148 : 104
        if quickZoneCount > 0 {
            base += CGFloat(quickZoneCount) * 44
            base += 14
        }
        if shouldShowAutoParkingPendingInNoSession {
            base += 70
        }
#if DEBUG
        if !shouldShowAutoParkingPendingInNoSession {
            base += 58
        }
#endif
        if vm.userCoordinate == nil {
            base += 14
        }
        return min(base, quickZoneCount > 0 ? 398 : 328)
    }

    private var shouldShowAutoParkingPendingInNoSession: Bool {
        vm.pendingAutoParkingDetectionForUI != nil
            && vm.pendingAutoParkingConfirmation == nil
            && vm.activeSession == nil
            && !showPremiumUpsellPopup
    }

    private var shouldShowAlwaysLocationBanner: Bool {
        vm.shouldShowAlwaysLocationPrompt
            && !showPremiumUpsellPopup
            && !showSaveSheet
            && !showFindMyCarFullScreen
            && !isActiveSessionExpandedFullscreen
    }
}

private struct AlwaysLocationPermissionBanner: View {
    let isSettingsRequired: Bool
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color(hex: "2563EB"))
                .frame(width: 34, height: 34)
                .background(Color(hex: "2563EB").opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("home.location_always_required_title".psLocalized)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(UIColor.label))
                        .lineLimit(2)
                        .minimumScaleFactor(0.88)

                    Text(
                        (isSettingsRequired
                            ? "home.location_always_required_settings_message"
                            : "home.location_always_required_message").psLocalized
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(UIColor.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: onAction) {
                    Label(
                        (isSettingsRequired
                            ? "home.location_open_settings"
                            : "home.location_always_enable").psLocalized,
                        systemImage: isSettingsRequired ? "gearshape.fill" : "location.fill"
                    )
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(hex: "2563EB"), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    (isSettingsRequired
                        ? "home.location_open_settings"
                        : "home.location_always_enable").psLocalized
                )
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(
            Color(UIColor.systemBackground).opacity(0.96),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(UIColor.separator).opacity(0.26), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

private struct AutoParkingPendingBanner: View {
    let address: String
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("home.probably_parked_at".psLocalized)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .lineLimit(1)

                        Text(address)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.white)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 4)
                }
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("home.dismiss_auto_parking_suggestion".psLocalized)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color(hex: "1D4ED8"), Color(hex: "2563EB")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }
}

private struct TemporaryAutoParkingDebugButton: View {
    let address: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "location.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.blue)
                    .frame(width: 22, height: 22)
                    .background(Color.blue.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("home.probably_parked_at".psLocalized)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(UIColor.secondaryLabel))
                        .lineLimit(1)

                    Text(address)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(UIColor.label))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                Color(UIColor.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.blue.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel("home.probably_parked_at".psLocalized)
    }
}

private struct FreeUserPremiumUpsellPopup: View {
    let onDismiss: () -> Void
    let onOpenPremium: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.yellow)

                    Text("Passez Premium")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(UIColor.label))
                        .lineLimit(1)

                    Spacer(minLength: 10)

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(UIColor.secondaryLabel))
                            .frame(width: 28, height: 28)
                            .background(Color(UIColor.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Text("Retrouvez votre voiture plus vite, sans pub, avec des alertes avancées.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(UIColor.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    upsellBullet("Aucune publicité")
                    upsellBullet("Historique étendu et sauvegarde cloud")
                    upsellBullet("Fonctions intelligentes avancées")
                }

                HStack(spacing: 10) {
                    Button("Plus tard") {
                        onDismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(UIColor.secondaryLabel))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        Color(UIColor.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .buttonStyle(.plain)

                    Button("Voir Premium") {
                        onOpenPremium()
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "2563EB"), Color(hex: "1D4ED8")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .frame(maxWidth: 360)
            .background(
                Color(UIColor.systemBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(UIColor.separator).opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func upsellBullet(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)

            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(UIColor.label))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}

private struct PhotoPreviewFullscreenView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            ZoomableImageView(image: image)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(18)
            }
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.backgroundColor = .black
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])

        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        if uiView.zoomScale != 1.0 {
            uiView.setZoomScale(1.0, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}

// MARK: – Active session bottom sheet content
private struct ActiveSessionContent: View {
    @Environment(\.colorScheme) private var colorScheme

    let session: ParkingSession
    let vm: HomeViewModel
    let isExpanded: Bool
    let airTagDisabled: Bool
    let onCollapse: () -> Void
    let onEnd: () -> Void
    let onNavigate: () -> Void
    let onFindCar: () -> Void

    @State private var sessionPhoto: UIImage?
    @State private var showPhotoSheet = false
    @State private var showPhotoPreview = false
    @State private var didFinishPhotoLoad = false
    @State private var collapseDragOffset: CGFloat = 0
    private let photoStorage = DIContainer.shared.photoStorage

    private enum ExpandedLayoutVariant {
        case regular
        case compact
        case tight

        var sectionSpacing: CGFloat {
            switch self {
            case .regular: return 14
            case .compact: return 10
            case .tight: return 8
            }
        }

        var gridSpacing: CGFloat {
            switch self {
            case .regular: return 12
            case .compact: return 10
            case .tight: return 8
            }
        }

        var contentHorizontalPadding: CGFloat {
            switch self {
            case .regular: return 18
            case .compact: return 16
            case .tight: return 14
            }
        }

        var contentTopPadding: CGFloat {
            switch self {
            case .regular: return 8
            case .compact: return 6
            case .tight: return 4
            }
        }

        var contentBottomPadding: CGFloat {
            switch self {
            case .regular: return 20
            case .compact: return 14
            case .tight: return 12
            }
        }

        var badgeDotSize: CGFloat { self == .tight ? 7 : 8 }

        var badgeFontSize: CGFloat {
            switch self {
            case .regular: return 12
            case .compact: return 11
            case .tight: return 10
            }
        }

        var badgeHorizontalPadding: CGFloat {
            switch self {
            case .regular: return 14
            case .compact: return 12
            case .tight: return 10
            }
        }

        var badgeVerticalPadding: CGFloat {
            switch self {
            case .regular: return 8
            case .compact: return 7
            case .tight: return 6
            }
        }

        var headerSpacing: CGFloat { self == .regular ? 6 : 4 }

        var addressFontSize: CGFloat {
            switch self {
            case .regular: return 27
            case .compact: return 23
            case .tight: return 21
            }
        }

        var addressLineLimit: Int { self == .regular ? 3 : 2 }

        var dateFontSize: CGFloat {
            switch self {
            case .regular: return 15
            case .compact: return 14
            case .tight: return 13
            }
        }

        var approximateFontSize: CGFloat { self == .regular ? 11 : 10 }

        var approximateHorizontalPadding: CGFloat {
            switch self {
            case .regular: return 9
            case .compact: return 8
            case .tight: return 7
            }
        }

        var approximateVerticalPadding: CGFloat { self == .regular ? 5 : 4 }

        var heroCornerRadius: CGFloat { self == .tight ? 20 : 24 }

        var heroHeight: CGFloat {
            switch self {
            case .regular: return 136
            case .compact: return 118
            case .tight: return 102
            }
        }

        var heroDecorLargeSize: CGFloat {
            switch self {
            case .regular: return 152
            case .compact: return 130
            case .tight: return 112
            }
        }

        var heroDecorLargeOffsetX: CGFloat {
            switch self {
            case .regular: return 84
            case .compact: return 72
            case .tight: return 62
            }
        }

        var heroDecorLargeOffsetY: CGFloat {
            switch self {
            case .regular: return 34
            case .compact: return 28
            case .tight: return 24
            }
        }

        var heroDecorSmallSize: CGFloat {
            switch self {
            case .regular: return 104
            case .compact: return 88
            case .tight: return 72
            }
        }

        var heroDecorSmallOffsetX: CGFloat {
            switch self {
            case .regular: return 122
            case .compact: return 104
            case .tight: return 88
            }
        }

        var heroDecorSmallOffsetY: CGFloat {
            switch self {
            case .regular: return -34
            case .compact: return -28
            case .tight: return -22
            }
        }

        var heroContentSpacing: CGFloat {
            switch self {
            case .regular: return 14
            case .compact: return 12
            case .tight: return 10
            }
        }

        var heroHorizontalPadding: CGFloat {
            switch self {
            case .regular: return 14
            case .compact: return 12
            case .tight: return 11
            }
        }

        var heroIconCircleSize: CGFloat {
            switch self {
            case .regular: return 64
            case .compact: return 56
            case .tight: return 48
            }
        }

        var heroIconSize: CGFloat {
            switch self {
            case .regular: return 22
            case .compact: return 19
            case .tight: return 17
            }
        }

        var heroTitleFontSize: CGFloat {
            switch self {
            case .regular: return 11
            case .compact: return 10
            case .tight: return 9
            }
        }

        var heroValueFontSize: CGFloat {
            switch self {
            case .regular: return 42
            case .compact: return 34
            case .tight: return 29
            }
        }

        var heroUnitFontSize: CGFloat {
            switch self {
            case .regular: return 18
            case .compact: return 16
            case .tight: return 13
            }
        }

        var heroSubtitleFontSize: CGFloat {
            switch self {
            case .regular: return 12
            case .compact: return 11
            case .tight: return 10
            }
        }

        var heroSubtitleLineLimit: Int { self == .tight ? 1 : 2 }

        var shareLabel: String {
            self == .regular ? "home.share_car_location".psLocalized : "home.share_location".psLocalized
        }

        var shareCircleSize: CGFloat { self == .tight ? 22 : 24 }
        var shareIconSize: CGFloat { self == .tight ? 10 : 11 }

        var shareTextFontSize: CGFloat {
            switch self {
            case .regular: return 12
            case .compact: return 11
            case .tight: return 11
            }
        }

        var shareHorizontalPadding: CGFloat { self == .regular ? 12 : 10 }
        var shareVerticalPadding: CGFloat { self == .regular ? 7 : 6 }
        var shareCornerRadius: CGFloat { self == .tight ? 10 : 11 }

        var buttonHeight: CGFloat {
            switch self {
            case .regular: return 46
            case .compact: return 42
            case .tight: return 40
            }
        }

        var buttonFontSize: CGFloat {
            switch self {
            case .regular: return 15
            case .compact: return 14
            case .tight: return 13
            }
        }

        var cardInnerSpacing: CGFloat {
            switch self {
            case .regular: return 12
            case .compact: return 10
            case .tight: return 8
            }
        }

        var cardIconBoxSize: CGFloat {
            switch self {
            case .regular: return 40
            case .compact: return 36
            case .tight: return 32
            }
        }

        var cardIconSize: CGFloat {
            switch self {
            case .regular: return 16
            case .compact: return 15
            case .tight: return 14
            }
        }

        var cardTitleFontSize: CGFloat {
            switch self {
            case .regular: return 12
            case .compact: return 11
            case .tight: return 10
            }
        }

        var cardHorizontalPadding: CGFloat {
            switch self {
            case .regular: return 14
            case .compact: return 12
            case .tight: return 11
            }
        }

        var cardVerticalPadding: CGFloat {
            switch self {
            case .regular: return 14
            case .compact: return 12
            case .tight: return 11
            }
        }

        var fullWidthCardMinHeight: CGFloat {
            switch self {
            case .regular: return 122
            case .compact: return 102
            case .tight: return 88
            }
        }

        var gridCardMinHeight: CGFloat {
            switch self {
            case .regular: return 146
            case .compact: return 118
            case .tight: return 102
            }
        }

        var gridCardMinimumWidth: CGFloat {
            switch self {
            case .regular: return 150
            case .compact: return 138
            case .tight: return 126
            }
        }

        var infoCardValueReduction: CGFloat {
            switch self {
            case .regular: return 0
            case .compact: return 2
            case .tight: return 4
            }
        }

        var noteFontSize: CGFloat {
            switch self {
            case .regular: return 15
            case .compact: return 14
            case .tight: return 13
            }
        }

        var noteLineLimit: Int {
            switch self {
            case .regular: return 4
            case .compact: return 3
            case .tight: return 2
            }
        }

        var timerIconSize: CGFloat {
            switch self {
            case .regular: return 10
            case .compact: return 9
            case .tight: return 8
            }
        }

        var timerLabelFontSize: CGFloat {
            switch self {
            case .regular: return 11
            case .compact: return 10
            case .tight: return 9
            }
        }

        var timerValueFontSize: CGFloat {
            switch self {
            case .regular: return 20
            case .compact: return 18
            case .tight: return 16
            }
        }

        var timerHorizontalPadding: CGFloat {
            switch self {
            case .regular: return 14
            case .compact: return 12
            case .tight: return 11
            }
        }

        var timerVerticalPadding: CGFloat {
            switch self {
            case .regular: return 10
            case .compact: return 8
            case .tight: return 7
            }
        }

        var photoIconBoxSize: CGFloat {
            switch self {
            case .regular: return 24
            case .compact: return 22
            case .tight: return 20
            }
        }

        var photoIconSize: CGFloat {
            switch self {
            case .regular: return 14
            case .compact: return 13
            case .tight: return 12
            }
        }

        var photoTitleFontSize: CGFloat {
            switch self {
            case .regular: return 15
            case .compact: return 14
            case .tight: return 13
            }
        }

        var photoStatusFontSize: CGFloat {
            switch self {
            case .regular: return 13
            case .compact: return 12
            case .tight: return 11
            }
        }

        var photoThumbnailSize: CGFloat {
            switch self {
            case .regular: return 44
            case .compact: return 38
            case .tight: return 34
            }
        }

        var photoHorizontalPadding: CGFloat {
            switch self {
            case .regular: return 12
            case .compact: return 11
            case .tight: return 10
            }
        }

        var photoVerticalPadding: CGFloat {
            switch self {
            case .regular: return 9
            case .compact: return 8
            case .tight: return 7
            }
        }
    }

    private struct ExpandedPriceInfoItem: Identifiable {
        let id: String
        let icon: String
        let title: String
        let value: String
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if isExpanded {
                    ViewThatFits(in: .vertical) {
                        expandedContent(layout: .regular)
                        expandedContent(layout: .compact)
                        expandedContent(layout: .tight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .offset(y: collapseDragOffset)
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.84), value: collapseDragOffset)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .local)
                            .onChanged { value in
                                let verticalDrag = value.translation.height
                                let horizontalDrag = abs(value.translation.width)

                                guard verticalDrag > 0 else {
                                    if collapseDragOffset != 0 {
                                        collapseDragOffset = 0
                                    }
                                    return
                                }

                                guard verticalDrag > horizontalDrag * 0.85 else { return }

                                collapseDragOffset = min(108, verticalDrag * 0.56)
                            }
                            .onEnded { value in
                                let verticalDrag = value.translation.height
                                let horizontalDrag = abs(value.translation.width)

                                let projectedDrag = max(verticalDrag, value.predictedEndTranslation.height)
                                let shouldCollapse =
                                    projectedDrag > 86
                                    && verticalDrag > horizontalDrag * 0.85

                                if shouldCollapse {
                                    collapseDragOffset = 0
                                    onCollapse()
                                } else {
                                    withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.88)) {
                                        collapseDragOffset = 0
                                    }
                                }
                            }
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("home.car_parked".psLocalized.uppercased(with: .current))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(contentMutedTextColor)
                            .tracking(1.2)

                        Text(session.address ?? "home.saved_position".psLocalized)
                            .font(.system(size: 19, weight: .heavy, design: .rounded))
                            .foregroundStyle(contentPrimaryTextColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        if session.isApproximate {
                            Text("home.approximate_position".psLocalized)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                        }

                        HStack(spacing: 10) {
                            Text(session.startTime.formatted(date: .omitted, time: .shortened))
                                .monospacedDigit()

                            Circle()
                                .fill(contentSecondaryTextColor.opacity(0.55))
                                .frame(width: 4, height: 4)

                            Text(session.zone.localizedName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(zoneBadgeTextColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(zoneBadgeColor, in: Capsule())
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(contentSecondaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if (session.maxDuration ?? 0) > 0 {
                            TimerProgressBar(session: session, isCompact: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        HStack(spacing: 12) {
                            actionButton(
                                title: "home.start_guidance".psLocalized,
                                systemImage: "figure.walk",
                                foreground: navigationButtonForeground,
                                background: startButtonBackground,
                                border: startButtonBorder,
                                action: onFindCar
                            )

                            actionButton(
                                title: "home.end_parking".psLocalized,
                                systemImage: "stop.fill",
                                foreground: endButtonForeground,
                                background: endButtonBackground,
                                border: endButtonBorder,
                                action: onEnd
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        if let deadline = vm.pendingAutoEndDeadline {
                            AutoEndCountdownBanner(deadline: deadline) {
                                vm.cancelPendingAutoEnd()
                            }
                        }

                        if airTagDisabled {
                            Text("home.underground_guidance_available".psLocalized)
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .foregroundStyle(contentPrimaryTextColor)
        }
        .task(id: session.photoPath) {
            await loadSessionPhotoIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await loadSessionPhotoIfNeeded() }
        }
        .sheet(isPresented: $showPhotoSheet) {
            if let sessionPhoto {
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: sessionPhoto)
                        .resizable()
                        .scaledToFit()
                        .padding()
                }
            }
        }
        .fullScreenCover(isPresented: $showPhotoPreview) {
            if let sessionPhoto {
                PhotoPreviewFullscreenView(image: sessionPhoto)
            }
        }
    }

    @ViewBuilder
    private func expandedContent(layout: ExpandedLayoutVariant) -> some View {
        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
            HStack(spacing: 8) {
                Circle()
                    .fill(parkingStatusAccent)
                    .frame(width: layout.badgeDotSize, height: layout.badgeDotSize)

                Text(parkingStatusLabel)
                    .font(.system(size: layout.badgeFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(parkingStatusTextColor)
            }
            .padding(.horizontal, layout.badgeHorizontalPadding)
            .padding(.vertical, layout.badgeVerticalPadding)
            .background(parkingStatusBackground, in: Capsule())

            VStack(alignment: .leading, spacing: layout.headerSpacing) {
                Text(session.address ?? "home.saved_position".psLocalized)
                    .font(.system(size: layout.addressFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(contentPrimaryTextColor)
                    .lineLimit(layout.addressLineLimit)
                    .minimumScaleFactor(0.72)

                Text(savedAtLabel)
                    .font(.system(size: layout.dateFontSize, weight: .medium))
                    .foregroundStyle(contentSecondaryTextColor)
                    .monospacedDigit()

                if session.isApproximate {
                    Text("home.approximate_position".psLocalized)
                        .font(.system(size: layout.approximateFontSize, weight: .semibold))
                        .foregroundStyle(Color(hex: "FF9500"))
                        .padding(.horizontal, layout.approximateHorizontalPadding)
                        .padding(.vertical, layout.approximateVerticalPadding)
                        .background(
                            Color(hex: "FF9500").opacity(isDarkMode ? 0.22 : 0.14),
                            in: Capsule()
                        )
                }
            }

            Button(action: onFindCar) {
                ZStack {
                    RoundedRectangle(cornerRadius: layout.heroCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "177DFF"), Color(hex: "3A8DFF")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: layout.heroCornerRadius, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                        )

                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: layout.heroDecorLargeSize, height: layout.heroDecorLargeSize)
                        .offset(x: layout.heroDecorLargeOffsetX, y: layout.heroDecorLargeOffsetY)

                    Circle()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: layout.heroDecorSmallSize, height: layout.heroDecorSmallSize)
                        .offset(x: layout.heroDecorSmallOffsetX, y: layout.heroDecorSmallOffsetY)

                    HStack(spacing: layout.heroContentSpacing) {
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: layout.heroIconCircleSize, height: layout.heroIconCircleSize)
                            .overlay(
                                Image(systemName: "arrow.up")
                                    .font(.system(size: layout.heroIconSize, weight: .medium))
                                    .foregroundStyle(.white)
                                    .rotationEffect(.degrees(directionRotation))
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("home.distance_to_cover".psLocalized)
                                .font(.system(size: layout.heroTitleFontSize, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.72))
                                .tracking(0.6)

                            HStack(alignment: .lastTextBaseline, spacing: 6) {
                                Text(distanceCardValue)
                                    .font(.system(size: layout.heroValueFontSize, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .contentTransition(.numericText())
                                    .minimumScaleFactor(0.72)

                                Text(distanceCardUnit)
                                    .font(.system(size: layout.heroUnitFontSize, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.9))
                            }

                            Text(distanceCardSubtitle)
                                .font(.system(size: layout.heroSubtitleFontSize, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.72))
                                .lineLimit(layout.heroSubtitleLineLimit)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, layout.heroHorizontalPadding)
                }
                .frame(maxWidth: .infinity, minHeight: layout.heroHeight)
                .shadow(color: Color(hex: "177DFF").opacity(0.16), radius: 14, y: 8)
            }
            .buttonStyle(.plain)

            if let level = normalizedParkingLevel {
                LazyVGrid(
                    columns: infoGridColumns(for: layout),
                    spacing: layout.gridSpacing
                ) {
                    expandedInfoCard(
                        icon: "figure.walk",
                        iconTint: Color(hex: "1DBA84"),
                        iconBackground: Color(hex: "1DBA84").opacity(isDarkMode ? 0.18 : 0.10),
                        title: "home.walk_time_uppercase".psLocalized,
                        value: vm.estimatedWalkTime,
                        valueColor: Color(hex: "10B981"),
                        layout: layout
                    )

                    expandedInfoCard(
                        icon: "building.2",
                        iconTint: Color(hex: "5E6B88"),
                        iconBackground: Color(hex: "C9D3E5").opacity(isDarkMode ? 0.16 : 0.34),
                        title: "home.level_marker_uppercase".psLocalized,
                        value: level,
                        valueColor: contentPrimaryTextColor,
                        layout: layout
                    )
                }
            } else {
                expandedInfoCard(
                    icon: "figure.walk",
                    iconTint: Color(hex: "1DBA84"),
                    iconBackground: Color(hex: "1DBA84").opacity(isDarkMode ? 0.18 : 0.10),
                    title: "home.walk_time_uppercase".psLocalized,
                    value: vm.estimatedWalkTime,
                    valueColor: Color(hex: "10B981"),
                    fullWidth: true,
                    layout: layout
                )
            }

            if let singlePriceCard = parkingPriceInfoItems.first, parkingPriceInfoItems.count == 1 {
                expandedInfoCard(
                    icon: singlePriceCard.icon,
                    iconTint: Color(hex: "C17B2B"),
                    iconBackground: Color(hex: "F2EBDD").opacity(isDarkMode ? 0.16 : 0.50),
                    title: singlePriceCard.title,
                    value: singlePriceCard.value,
                    valueColor: Color(hex: "C17B2B"),
                    fullWidth: true,
                    layout: layout
                )
            } else if !parkingPriceInfoItems.isEmpty {
                LazyVGrid(
                    columns: infoGridColumns(for: layout),
                    spacing: layout.gridSpacing
                ) {
                    ForEach(parkingPriceInfoItems) { item in
                        expandedInfoCard(
                            icon: item.icon,
                            iconTint: Color(hex: "C17B2B"),
                            iconBackground: Color(hex: "F2EBDD").opacity(isDarkMode ? 0.16 : 0.50),
                            title: item.title,
                            value: item.value,
                            valueColor: Color(hex: "C17B2B"),
                            layout: layout
                        )
                    }
                }
            }

            if cleanNote != nil {
                expandedNoteCard(layout: layout)
            }

            if let endDate = session.timerEndDate,
                let duration = session.maxDuration,
                duration > 0
            {
                expandedTimerRow(endDate: endDate, duration: duration, layout: layout)
            }

            if shouldShowPhotoRow {
                photoDetailRow(layout: layout)
            }

            ShareLink(item: shareCoordinatesMessage) {
                HStack(spacing: layout.gridSpacing) {
                    Circle()
                        .fill(Color.accentColor.opacity(isDarkMode ? 0.24 : 0.12))
                        .frame(width: layout.shareCircleSize, height: layout.shareCircleSize)
                        .overlay(
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: layout.shareIconSize, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        )

                    Text(layout.shareLabel)
                        .font(.system(size: layout.shareTextFontSize, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: layout.shareIconSize, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, layout.shareHorizontalPadding)
                .padding(.vertical, layout.shareVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: layout.shareCornerRadius, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: layout.shareCornerRadius, style: .continuous)
                        .stroke(Color(uiColor: .separator).opacity(isDarkMode ? 0.22 : 0.12), lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)

            if let deadline = vm.pendingAutoEndDeadline {
                AutoEndCountdownBanner(deadline: deadline) {
                    vm.cancelPendingAutoEnd()
                }
            }
        }
        .padding(.horizontal, layout.contentHorizontalPadding)
        .padding(.bottom, layout.contentBottomPadding)
        .padding(.top, layout.contentTopPadding)
    }

    private func infoGridColumns(for layout: ExpandedLayoutVariant) -> [GridItem] {
        [
            GridItem(.adaptive(minimum: layout.gridCardMinimumWidth), spacing: layout.gridSpacing)
        ]
    }

    private var sessionDivider: some View {
        Rectangle()
            .fill(separatorColor)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private func sessionDetailRow(
        icon: String,
        iconColor: Color,
        iconBackground: Color,
        title: String,
        value: String,
        valueColor: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconBackground)
                )

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(contentPrimaryTextColor)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        foreground: Color,
        background: Color,
        border: Color,
        height: CGFloat = 46,
        fontSize: CGFloat = 15,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: fontSize, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .foregroundStyle(foreground)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(border, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
    }

    private func expandedInfoCard(
        icon: String,
        iconTint: Color,
        iconBackground: Color,
        title: String,
        value: String,
        valueColor: Color,
        valueSize: CGFloat = 20,
        valueWeight: Font.Weight = .semibold,
        fullWidth: Bool = false,
        layout: ExpandedLayoutVariant = .regular
    ) -> some View {
        let adjustedValueSize = max(14, valueSize - layout.infoCardValueReduction)

        return VStack(alignment: .leading, spacing: layout.cardInnerSpacing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(iconBackground)
                .frame(width: layout.cardIconBoxSize, height: layout.cardIconBoxSize)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: layout.cardIconSize, weight: .semibold))
                        .foregroundStyle(iconTint)
                )

            VStack(alignment: .leading, spacing: max(4, layout.cardInnerSpacing - 6)) {
                Text(title)
                    .font(.system(size: layout.cardTitleFontSize, weight: .semibold))
                    .foregroundStyle(contentMutedTextColor)
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(value)
                    .font(.system(size: adjustedValueSize, weight: valueWeight, design: .rounded))
                    .foregroundStyle(valueColor)
                    .lineLimit(fullWidth ? 3 : 2)
                    .minimumScaleFactor(0.66)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, layout.cardHorizontalPadding)
        .padding(.vertical, layout.cardVerticalPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: fullWidth ? layout.fullWidthCardMinHeight : layout.gridCardMinHeight,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(expandedCardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(expandedCardBorderColor, lineWidth: 1)
        )
    }

    private func expandedNoteCard(layout: ExpandedLayoutVariant = .regular) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: "F2EBDD").opacity(isDarkMode ? 0.16 : 0.50))
                .frame(width: layout.cardIconBoxSize, height: layout.cardIconBoxSize)
                .overlay(
                    Image(systemName: "note.text")
                        .font(.system(size: layout.cardIconSize, weight: .semibold))
                        .foregroundStyle(Color(hex: "C17B2B"))
                )

            VStack(alignment: .leading, spacing: max(4, layout.cardInnerSpacing - 6)) {
                Text("home.note_uppercase".psLocalized)
                    .font(.system(size: layout.cardTitleFontSize, weight: .semibold))
                    .foregroundStyle(contentMutedTextColor)
                    .tracking(0.5)

                Text(noteCardValue)
                    .font(.system(size: layout.noteFontSize, weight: cleanNote == nil ? .medium : .regular, design: .rounded))
                    .foregroundStyle(noteCardTextColor)
                    .lineLimit(layout.noteLineLimit)
                    .minimumScaleFactor(0.9)
            }
        }
        .padding(.horizontal, layout.cardHorizontalPadding)
        .padding(.vertical, layout.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(expandedCardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(expandedCardBorderColor, lineWidth: 1)
        )
    }

    private func expandedTimerRow(
        endDate: Date,
        duration: TimeInterval,
        layout: ExpandedLayoutVariant = .regular
    ) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = max(0, endDate.timeIntervalSince(timeline.date))
            let progress = max(0, min(remaining / duration, 1))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: layout.timerIconSize, weight: .medium))
                        .foregroundStyle(Color(hex: "FF9500"))

                    Text("home.time_left".psLocalized)
                        .font(.system(size: layout.timerLabelFontSize, weight: .medium))
                        .foregroundStyle(Color(hex: "FF9500"))

                    Spacer(minLength: 4)

                    Text(ParkingCountdownFormatter.string(until: endDate, now: timeline.date))
                        .font(.system(size: layout.timerValueFontSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(hex: "FF9500"))
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(hex: "E5E5EA"))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color(hex: "FF9500"))
                            .frame(width: proxy.size.width * progress, height: 3)
                    }
                }
                .frame(height: 3)
            }
            .padding(.horizontal, layout.timerHorizontalPadding)
            .padding(.vertical, layout.timerVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(isDarkMode ? 0.22 : 0.12), lineWidth: 0.8)
            )
        }
    }

    @ViewBuilder
    private func photoDetailRow(layout: ExpandedLayoutVariant = .regular) -> some View {
        Button {
            if sessionPhoto != nil {
                showPhotoPreview = true
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "camera")
                    .font(.system(size: layout.photoIconSize, weight: .semibold))
                    .foregroundStyle(Color(red: 0.54, green: 0.77, blue: 1.0))
                    .frame(width: layout.photoIconBoxSize, height: layout.photoIconBoxSize)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.blue.opacity(0.14))
                    )

                Text("home.photo".psLocalized)
                    .font(.system(size: layout.photoTitleFontSize, weight: .semibold))
                    .foregroundStyle(contentPrimaryTextColor)

                Spacer(minLength: 8)

                if let sessionPhoto {
                    Image(uiImage: sessionPhoto)
                        .resizable()
                        .scaledToFill()
                        .frame(width: layout.photoThumbnailSize, height: layout.photoThumbnailSize)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Text("home.view".psLocalized)
                        .font(.system(size: layout.photoStatusFontSize, weight: .bold))
                        .foregroundStyle(shareAccentColor)
                } else {
                    Text("Loading…")
                        .font(.system(size: layout.photoStatusFontSize, weight: .semibold))
                        .foregroundStyle(contentMutedTextColor)
                }
            }
            .padding(.horizontal, layout.photoHorizontalPadding)
            .padding(.vertical, layout.photoVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var normalizedParkingLevel: String? {
        guard let level = session.parkingLevel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !level.isEmpty
        else { return nil }
        return level
    }

    private var statusBadgeTitle: String {
        session.zone == .free ? "Free" : session.zone.localizedName
    }

    private var statusBadgeBackground: Color {
        if session.zone.isFreePricing && !session.zone.isUndergroundType && !session.zone.isResidentType {
            return isDarkMode ? Color(hex: "1C3A25") : Color(hex: "E8F5E9")
        }
        return isDarkMode ? Color.white.opacity(0.14) : Color(hex: "F2F2F7")
    }

    private var statusBadgeForeground: Color {
        if session.zone.isFreePricing && !session.zone.isUndergroundType && !session.zone.isResidentType {
            return Color(hex: "2E7D32")
        }
        return contentSecondaryTextColor
    }

    private var distanceValueMeters: Double? {
        guard let user = vm.userCoordinate,
            user.isValidGeoCoordinate,
            session.coordinate.isValidGeoCoordinate
        else { return nil }

        let userCL = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let carCL = CLLocation(
            latitude: session.coordinate.latitude, longitude: session.coordinate.longitude)
        return userCL.distance(from: carCL)
    }

    private var distanceString: String {
        guard let distance = distanceValueMeters, distance.isFinite else { return "0 m" }
        if distance < 1000 {
            return "\(Int(distance.rounded())) m"
        }
        return String(format: "%.2f km", distance / 1000)
    }

    private var distanceCardValue: String {
        guard let distance = distanceValueMeters, distance.isFinite else { return "--" }
        if distance < 1000 {
            return "\(Int(distance.rounded()))"
        }
        return String(format: "%.1f", distance / 1000)
    }

    private var distanceCardUnit: String {
        guard let distance = distanceValueMeters else { return "m" }
        return distance < 1000 ? "m" : "km"
    }

    private var distanceCardSubtitle: String {
        guard let distance = distanceValueMeters else {
            return "home.tap_to_start_guidance".psLocalized
        }

        if distance <= 20 {
            return "home.you_are_nearby".psLocalized
        }

        if distance <= 120 {
            return "home.you_are_approaching_car".psLocalized
        }

        return "home.tap_to_start_guidance".psLocalized
    }

    private var directionRotation: Double {
        guard let user = vm.userCoordinate,
            user.isValidGeoCoordinate,
            session.coordinate.isValidGeoCoordinate,
            let heading = vm.userHeading
        else { return 0 }

        let userLat = user.latitude * .pi / 180
        let userLon = user.longitude * .pi / 180
        let carLat = session.coordinate.latitude * .pi / 180
        let carLon = session.coordinate.longitude * .pi / 180

        let dLon = carLon - userLon
        let y = sin(dLon) * cos(carLat)
        let x = cos(userLat) * sin(carLat) - sin(userLat) * cos(carLat) * cos(dLon)
        let absoluteBearing = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)

        let deviceHeading = heading.trueHeading > 0 ? heading.trueHeading : heading.magneticHeading
        guard deviceHeading.isFinite else { return 0 }

        var relative = absoluteBearing - deviceHeading
        relative = (relative + 360).truncatingRemainder(dividingBy: 360)
        if relative > 180 { relative -= 360 }
        return relative.isFinite ? relative : 0
    }

    private var sessionDateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let datePart = formatter.string(from: session.startTime)
        let timePart = session.startTime.formatted(date: .omitted, time: .shortened)
        return "\(datePart) \(timePart)"
    }

    private var savedAtLabel: String {
        String(
            format: "home.saved_at_format".psLocalized,
            session.startTime.formatted(date: .omitted, time: .shortened)
        )
    }

    private var parkingStatusLabel: String {
        "home.parked_here".psLocalized
    }

    private var parkingStatusAccent: Color {
        session.zone.isPaidPricing ? Color.orange : Color.green
    }

    private var parkingStatusTextColor: Color {
        session.zone.isPaidPricing ? Color.orange : Color.green
    }

    private var parkingStatusBackground: Color {
        session.zone.isPaidPricing
            ? Color.orange.opacity(isDarkMode ? 0.14 : 0.10)
            : Color.green.opacity(isDarkMode ? 0.14 : 0.10)
    }

    private var zoneBadgeColor: Color {
        if isDarkMode {
            if session.zone.isUndergroundType { return Color(red: 0.05, green: 0.22, blue: 0.31) }
            if session.zone.isResidentType { return Color(red: 0.19, green: 0.16, blue: 0.41) }
            if session.zone.isPaidPricing { return Color(red: 0.34, green: 0.22, blue: 0.05) }
            if session.zone.isFreePricing { return Color(red: 0.06, green: 0.27, blue: 0.14) }
            return Color.white.opacity(0.12)
        }

        if session.zone.isUndergroundType { return Color(red: 0.86, green: 0.93, blue: 0.98) }
        if session.zone.isResidentType { return Color(red: 0.93, green: 0.89, blue: 0.98) }
        if session.zone.isPaidPricing { return Color(red: 0.99, green: 0.94, blue: 0.84) }
        if session.zone.isFreePricing { return Color(red: 0.87, green: 0.95, blue: 0.89) }
        return Color.black.opacity(0.06)
    }

    private var zoneBadgeTextColor: Color {
        if isDarkMode {
            if session.zone.isUndergroundType { return Color(red: 0.49, green: 0.80, blue: 1.0) }
            if session.zone.isResidentType { return Color(red: 0.75, green: 0.55, blue: 0.98) }
            if session.zone.isPaidPricing { return Color(red: 0.98, green: 0.68, blue: 0.20) }
            if session.zone.isFreePricing { return Color(red: 0.18, green: 0.86, blue: 0.40) }
            return Color.white.opacity(0.72)
        }

        if session.zone.isUndergroundType { return Color(red: 0.21, green: 0.53, blue: 0.74) }
        if session.zone.isResidentType { return Color(red: 0.47, green: 0.34, blue: 0.74) }
        if session.zone.isPaidPricing { return Color(red: 0.75, green: 0.43, blue: 0.10) }
        if session.zone.isFreePricing { return Color(red: 0.09, green: 0.55, blue: 0.26) }
        return Color.black.opacity(0.58)
    }

    private var paidHourlyRate: Double? {
        guard session.zone.isPaidPricing,
            let note = session.note
        else { return nil }
        let pattern = #"\[\[PS_RATE_EUR:([0-9]+(?:[\.,][0-9]+)?)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: note, range: NSRange(note.startIndex..., in: note)),
            let valueRange = Range(match.range(at: 1), in: note)
        else {
            return nil
        }
        return Double(note[valueRange].replacingOccurrences(of: ",", with: "."))
    }

    private var totalPaidPrice: Double? {
        guard let rate = paidHourlyRate else { return nil }
        let endDate = session.endTime ?? Date()
        let elapsed = max(0, endDate.timeIntervalSince(session.startTime))
        return rate * (elapsed / 3600)
    }

    private var parkingPriceInfoItems: [ExpandedPriceInfoItem] {
        var items: [ExpandedPriceInfoItem] = []

        if let rate = paidHourlyRate {
            items.append(
                ExpandedPriceInfoItem(
                    id: "rate",
                    icon: "banknote",
                    title: "home.rate_uppercase".psLocalized,
                    value: "\(formatCurrency(rate))/h"
                )
            )
        }

        if let total = totalPaidPrice {
            items.append(
                ExpandedPriceInfoItem(
                    id: "current-price",
                    icon: "creditcard",
                    title: "home.parking_price_uppercase".psLocalized,
                    value: formatCurrency(total)
                )
            )
        }

        return items
    }

    private var cleanNote: String? {
        guard let note = session.note else { return nil }
        let cleaned =
            note
            .replacingOccurrences(
                of: #"\s*\[\[PS_RATE_EUR:[0-9]+(?:[\.,][0-9]+)?\]\]"#, with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private var noteCardValue: String {
        cleanNote ?? ""
    }

    private var noteCardTextColor: Color {
        cleanNote == nil ? contentSecondaryTextColor : contentPrimaryTextColor.opacity(0.84)
    }

    private var normalizedPhotoPath: String? {
        guard let rawPath = session.photoPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty
        else { return nil }
        return rawPath
    }

    private var shouldShowPhotoRow: Bool {
        sessionPhoto != nil || (normalizedPhotoPath != nil && !didFinishPhotoLoad)
    }

    private func formatCurrency(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = .current
        formatter.currencyCode = Locale.current.currency?.identifier ?? "EUR"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }

    private func loadSessionPhotoIfNeeded() async {
        guard let photoPath = normalizedPhotoPath else {
            sessionPhoto = nil
            didFinishPhotoLoad = true
            return
        }

        didFinishPhotoLoad = false
        defer { didFinishPhotoLoad = true }

        for attempt in 0..<4 {
            if let data = try? await photoStorage.load(path: photoPath),
                let image = UIImage(data: data)
            {
                sessionPhoto = image
                return
            }

            guard attempt < 3 else { break }
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        sessionPhoto = nil
    }

    private var shareLatitude: String {
        formatCoordinate(session.coordinate.latitude)
    }

    private var shareLongitude: String {
        formatCoordinate(session.coordinate.longitude)
    }

    private var shareCoordinatesMessage: String {
        """
        \("home.share_car_position_prefix".psLocalized)
        https://maps.apple.com/?ll=\(shareLatitude),\(shareLongitude)&q=\("home.share_car_query".psLocalized)
        """
    }

    private var shareBackground: Color {
        isDarkMode
            ? Color(red: 0.10, green: 0.12, blue: 0.18)
            : Color(red: 0.91, green: 0.95, blue: 1.0)
    }

    private var shareBorder: Color {
        isDarkMode ? Color.white.opacity(0.14) : Color.blue.opacity(0.24)
    }

    private var shareIconBackground: Color {
        isDarkMode ? Color.blue.opacity(0.22) : Color.blue.opacity(0.14)
    }

    private var shareAccentColor: Color {
        Color(red: 0.53, green: 0.76, blue: 1.0)
    }

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var contentPrimaryTextColor: Color {
        isDarkMode ? Color.white : Color.black.opacity(0.90)
    }

    private var contentSecondaryTextColor: Color {
        isDarkMode ? Color.white.opacity(0.56) : Color.black.opacity(0.58)
    }

    private var contentMutedTextColor: Color {
        isDarkMode ? Color.white.opacity(0.40) : Color.black.opacity(0.40)
    }

    private var separatorColor: Color {
        isDarkMode ? Color.white.opacity(0.07) : Color.black.opacity(0.08)
    }

    private var expandedCardBackgroundColor: Color {
        isDarkMode
            ? Color(uiColor: .secondarySystemBackground)
            : Color(uiColor: .secondarySystemBackground)
    }

    private var expandedCardBorderColor: Color {
        Color(uiColor: .separator).opacity(isDarkMode ? 0.22 : 0.10)
    }

    private var detailCardBackgroundColor: Color {
        isDarkMode ? Color(red: 0.10, green: 0.10, blue: 0.12) : Color(.systemGray6)
    }

    private var detailCardBorderColor: Color {
        isDarkMode ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
    }

    private var navigationButtonForeground: Color {
        .white
    }

    private var navigationButtonBackground: Color {
        Color(red: 0.09, green: 0.49, blue: 0.97)
    }

    private var navigationButtonBorder: Color {
        isDarkMode
            ? Color(red: 0.20, green: 0.62, blue: 1.0) : Color(red: 0.05, green: 0.40, blue: 0.90)
    }

    private var startButtonBackground: Color {
        .psAccentBlue
    }

    private var startButtonBorder: Color {
        isDarkMode
            ? Color(red: 0.20, green: 0.62, blue: 1.0)
            : Color(red: 0.05, green: 0.40, blue: 0.90)
    }

    private var endButtonForeground: Color {
        Color(red: 0.86, green: 0.17, blue: 0.20)
    }

    private var endButtonBackground: Color {
        isDarkMode
            ? Color(red: 0.25, green: 0.05, blue: 0.07) : Color(red: 1.0, green: 0.93, blue: 0.94)
    }

    private var endButtonBorder: Color {
        isDarkMode
            ? Color(red: 0.47, green: 0.10, blue: 0.14) : Color(red: 0.91, green: 0.58, blue: 0.61)
    }

    private func formatCoordinate(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

// MARK: – No active session content
private struct NoSessionContent: View {
    let onSave: () -> Void
    let onQuickSaveWithZone: (FrequentZone) -> Void
    let quickZones: [FrequentZone]
    let showAutoParkingPending: Bool
    let autoParkingPendingAddress: String
    let onOpenAutoParkingPending: () -> Void
    let onDismissAutoParkingPending: () -> Void
    let unfilteredAutoParkingAddress: String
    let canUseUnfilteredAutoParkingDetection: Bool
    let onUseUnfilteredAutoParkingDetection: () -> Void
    let isUsingManualLocation: Bool
    let containerWidth: CGFloat

    private var controlMaxWidth: CGFloat {
        max(180, containerWidth * 0.6)
    }

    private func localizedQuickZoneName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("Zone fréquente") == .orderedSame {
            return "Frequent zone"
        }
        return trimmed.isEmpty ? "Frequent zone" : trimmed
    }

    var body: some View {
        VStack(spacing: 10) {
            if !quickZones.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("home.quick_zones_shortcuts".psLocalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(quickZones.prefix(2))) { zone in
                        Button {
                            onQuickSaveWithZone(zone)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "star.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.white)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(localizedQuickZoneName(zone.name))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)

                                    if let preferred = zone.preferredDurationMinutes, preferred > 0
                                    {
                                        Text(
                                            String(
                                                format: String(
                                                    localized: "home.quick_timer_format"),
                                                formatDuration(preferred)
                                            )
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.9))
                                    } else {
                                        Text("home.quick_no_timer".psLocalized)
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.9))
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(zoneColor(zone.name))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                .frame(maxWidth: controlMaxWidth, alignment: .leading)
            }

            if showAutoParkingPending {
                AutoParkingPendingBanner(
                    address: autoParkingPendingAddress,
                    onOpen: onOpenAutoParkingPending,
                    onDismiss: onDismissAutoParkingPending
                )
                .frame(maxWidth: controlMaxWidth)
            }

#if DEBUG
            if !showAutoParkingPending {
                TemporaryAutoParkingDebugButton(
                    address: unfilteredAutoParkingAddress,
                    isEnabled: canUseUnfilteredAutoParkingDetection,
                    action: onUseUnfilteredAutoParkingDetection
                )
                .frame(maxWidth: controlMaxWidth)
            }
#endif

            Button(action: onSave) {
                Label("home.i_parked_my_car".psLocalized, systemImage: "car.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: controlMaxWidth)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .padding(.bottom, 10)

            if isUsingManualLocation {
                Text("Using the map center while GPS is unavailable")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.bottom, 0)
    }

    private func formatDuration(_ totalMinutes: Int) -> String {
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return String(format: "%02d h  %02d m", h, m)
    }

    private func zoneColor(_ zoneName: String) -> Color {
        let zoneColors: [String: Color] = [
            "Maison": Color(red: 0.8, green: 0.6, blue: 0.2),
            "Travail": Color(red: 0.2, green: 0.5, blue: 0.8),
            "Courses": Color(red: 0.9, green: 0.4, blue: 0.2),
            "Sport": Color(red: 0.6, green: 0.2, blue: 0.8),
            "École": Color(red: 0.2, green: 0.7, blue: 0.4),
            "Gare": Color(red: 0.8, green: 0.2, blue: 0.3),
            "Proches": Color(red: 0.4, green: 0.6, blue: 0.8),
            "Autre": Color(red: 0.6, green: 0.6, blue: 0.6),
        ]
        return zoneColors[zoneName] ?? Color.blue
    }
}

extension ParkingSession {
    fileprivate var timerEndDate: Date? {
        guard let maxDuration, maxDuration > 0 else { return nil }
        return startTime.addingTimeInterval(maxDuration)
    }
}

private enum ParkingCountdownFormatter {
    static func string(until endDate: Date, now: Date) -> String {
        let remaining = max(0, Int(endDate.timeIntervalSince(now)))
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct ParkingCountdownText: View {
    let endDate: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(ParkingCountdownFormatter.string(until: endDate, now: timeline.date))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

private struct AutoEndCountdownBanner: View {
    let deadline: Date
    let onCancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { timeline in
            let remaining = max(0, Int(deadline.timeIntervalSince(timeline.date)))

            HStack {
                Label(
                    String(format: "home.auto_end_in_seconds_format".psLocalized, remaining),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.orange)
                Spacer()
                Button("Annuler") {
                    onCancel()
                }
                .font(.caption.weight(.semibold))
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: – Timer Progress Bar
private struct TimerProgressBar: View {
    @Environment(\.colorScheme) private var colorScheme

    let session: ParkingSession
    var isCompact: Bool = true

    private func progress(at now: Date) -> Double {
        guard let duration = session.maxDuration, duration > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(session.startTime)
        return min(Swift.max(elapsed / duration, 0), 1.0)
    }

    var body: some View {
        if let endDate = session.timerEndDate {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let p = progress(at: timeline.date)
                let remainingText = ParkingCountdownFormatter.string(
                    until: endDate, now: timeline.date)

                VStack(alignment: .leading, spacing: isCompact ? 6 : 5) {
                    HStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundStyle(.orange)
                                .frame(width: 14, height: 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(timerIconBackgroundColor)
                                )

                            Text("Temps restant")
                                .font(.system(size: isCompact ? 8 : 7, weight: .bold))
                                .foregroundStyle(.orange)
                        }

                        Spacer(minLength: 4)

                        Text(remainingText)
                            .font(
                                .system(size: isCompact ? 20 : 16, weight: .heavy, design: .rounded)
                            )
                            .foregroundStyle(.orange)
                            .monospacedDigit()
                            .minimumScaleFactor(0.8)
                            .lineLimit(1)
                    }

                    GeometryReader { proxy in
                        let width = max(9, proxy.size.width * p)
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(timerTrackColor)
                                .frame(height: 3)
                            Capsule()
                                .fill(Color.orange)
                                .frame(width: width, height: 3)
                        }
                    }
                    .frame(height: 3)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, isCompact ? 6 : 5)
                .background(
                    RoundedRectangle(cornerRadius: isCompact ? 9 : 7, style: .continuous)
                        .fill(timerCardBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: isCompact ? 9 : 7, style: .continuous)
                        .stroke(timerBorderColor, lineWidth: 1)
                )
            }
        }
    }

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var timerCardBackgroundColor: Color {
        isDarkMode
            ? Color(red: 0.13, green: 0.13, blue: 0.15)
            : Color(red: 0.95, green: 0.95, blue: 0.96)
    }

    private var timerTrackColor: Color {
        isDarkMode ? Color.white.opacity(0.09) : Color.black.opacity(0.12)
    }

    private var timerBorderColor: Color {
        isDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.08)
    }

    private var timerIconBackgroundColor: Color {
        isDarkMode ? Color.orange.opacity(0.18) : Color.orange.opacity(0.12)
    }
}

// MARK: – Car Pin View
private struct CarPinView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "car.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("home.my_car".psLocalized)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.blue, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .blue.opacity(0.4), radius: 4, y: 2)

            Triangle()
                .fill(Color.blue)
                .frame(width: 12, height: 8)
        }
    }
}

// MARK: – User location pin
private struct UserLocationPinView: View {
    let profilePhotoData: Data?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.18))
                .frame(width: 34, height: 34)

            if let profilePhotoData,
                let image = UIImage(data: profilePhotoData)
            {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            } else {
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.blue.opacity(0.9), lineWidth: 1.5))
            }
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}

// MARK: – Map control button
private struct MapControlButton: View {
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .foregroundColor(.primary)
        }
        .frame(width: 38, height: 38)
    }
}

private struct MapModeControlButton: View {
    @Binding var is3DEnabled: Bool

    var body: some View {
        Button {
            is3DEnabled.toggle()
        } label: {
            Text(is3DEnabled ? "3D" : "2D")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .foregroundColor(.primary)
        }
        .frame(width: 38, height: 38)
        .accessibilityLabel((is3DEnabled ? "Basculer en 2D" : "Basculer en 3D").psLocalized)
    }
}

private struct ManualMapCenterMarker: View {
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.blue)
                .shadow(color: .black.opacity(0.28), radius: 8, y: 3)

            Text("Map center".psLocalized)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.black.opacity(0.42), in: Capsule())
        }
        .offset(y: -22)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: – Map annotation helper
private struct MapPin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let kind: MapPinKind
}

private enum MapPinKind {
    case car
    case user
    case undergroundZone
}

private struct HomeCustomMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var is3DEnabled: Bool
    @Binding var isAutoFollowingUser: Bool
    let viewportCommand: Int
    let annotations: [MapPin]
    let profilePhotoData: Data?
    let userHeading: CLHeading?
    let guidanceRoute: [CLLocationCoordinate2D]
    let uncertaintyCenter: CLLocationCoordinate2D?
    let uncertaintyRadiusMeters: Double?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.overrideUserInterfaceStyle = .unspecified
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.setRegion(region, animated: false)
        applyMapConfiguration(on: mapView)
        context.coordinator.lastApplied3DMode = is3DEnabled
        context.coordinator.lastRequestedSpan = region.span
        context.coordinator.lastViewportCommand = viewportCommand
        context.coordinator.installInteractionTracking(on: mapView)
        context.coordinator.syncAnnotations(on: mapView)
        context.coordinator.syncGuidanceOverlays(on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        mapView.overrideUserInterfaceStyle = .unspecified
        context.coordinator.installInteractionTracking(on: mapView)

        if context.coordinator.lastApplied3DMode != is3DEnabled {
            applyMapConfiguration(on: mapView)
            context.coordinator.lastApplied3DMode = is3DEnabled
        }

        let centerDistance = approximateDistanceMeters(
            from: mapView.region.center, to: region.center)
        let spanWasRequested = context.coordinator.didRequestNewSpan(region.span)
        let viewportCommandChanged = context.coordinator.didReceiveViewportCommand(viewportCommand)
        let canApplyViewportUpdate =
            viewportCommandChanged
            || (isAutoFollowingUser && !context.coordinator.hasRecentUserInteraction)

        let latitudeDeltaDiff = abs(mapView.region.span.latitudeDelta - region.span.latitudeDelta)
        let longitudeDeltaDiff = abs(
            mapView.region.span.longitudeDelta - region.span.longitudeDelta)
        let zoomTolerance = 0.0001

        let shouldUpdateCenter = canApplyViewportUpdate && centerDistance > 2
        let shouldUpdateZoom =
            canApplyViewportUpdate
            && (
                is3DEnabled
                    ? spanWasRequested
                    : (latitudeDeltaDiff > zoomTolerance || longitudeDeltaDiff > zoomTolerance)
            )

        if shouldUpdateCenter || shouldUpdateZoom {
            if is3DEnabled {
                let current = mapView.camera
                let targetDistance =
                    shouldUpdateZoom
                    ? max(220, min(2000, region.span.latitudeDelta * 111_000 * 1.25))
                    : current.centerCoordinateDistance
                let targetCenter =
                    shouldUpdateCenter ? region.center : current.centerCoordinate
                let camera = MKMapCamera(
                    lookingAtCenter: targetCenter,
                    fromDistance: targetDistance,
                    pitch: 64,
                    heading: current.heading == 0 ? 22 : current.heading
                )
                mapView.setCamera(camera, animated: false)
            } else {
                var targetRegion = region
                if !shouldUpdateCenter {
                    targetRegion.center = mapView.region.center
                }
                mapView.setRegion(targetRegion, animated: false)
            }
        }
        context.coordinator.syncAnnotations(on: mapView)
        context.coordinator.syncGuidanceOverlays(on: mapView)
    }

    private var resolvedUserHeadingDegrees: CLLocationDirection? {
        guard let userHeading, userHeading.headingAccuracy >= 0 else { return nil }
        let value = userHeading.trueHeading >= 0
            ? userHeading.trueHeading
            : userHeading.magneticHeading
        return value.isFinite ? value : nil
    }

    private func applyMapConfiguration(on mapView: MKMapView) {
        let processInfo = ProcessInfo.processInfo
        let isPowerConstrained =
            processInfo.isLowPowerModeEnabled || processInfo.thermalState == .serious
            || processInfo.thermalState == .critical
        let canUse3D = is3DEnabled && !isPowerConstrained

        if #available(iOS 16.0, *) {
            if canUse3D {
                let config = MKStandardMapConfiguration(
                    elevationStyle: .realistic,
                    emphasisStyle: .default
                )
                config.pointOfInterestFilter = .excludingAll
                config.showsTraffic = false
                mapView.preferredConfiguration = config
            } else {
                let config = MKStandardMapConfiguration(
                    elevationStyle: .flat, emphasisStyle: .default)
                config.pointOfInterestFilter = .excludingAll
                config.showsTraffic = false
                mapView.preferredConfiguration = config
            }
        } else {
            mapView.mapType = .standard
            mapView.pointOfInterestFilter = .excludingAll
            mapView.showsTraffic = false
        }

        mapView.showsBuildings = canUse3D
        mapView.isPitchEnabled = canUse3D
        mapView.isRotateEnabled = canUse3D

        if canUse3D {
            let desiredDistance = max(220, min(2000, region.span.latitudeDelta * 111_000 * 1.25))
            let current = mapView.camera
            let camera = MKMapCamera(
                lookingAtCenter: mapView.region.center,
                fromDistance: desiredDistance,
                pitch: 64,
                heading: current.heading == 0 ? 22 : current.heading
            )
            mapView.setCamera(camera, animated: true)
        } else if mapView.camera.pitch > 0 {
            let current = mapView.camera
            let camera = MKMapCamera(
                lookingAtCenter: mapView.region.center,
                fromDistance: current.centerCoordinateDistance,
                pitch: 0,
                heading: 0
            )
            mapView.setCamera(camera, animated: true)
        }
    }

    private func approximateDistanceMeters(
        from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D
    ) -> Double {
        let dLat = (a.latitude - b.latitude) * 111_000
        let dLon =
            (a.longitude - b.longitude) * 111_000
            * max(cos(((a.latitude + b.latitude) * 0.5) * .pi / 180), 0.1)
        return sqrt((dLat * dLat) + (dLon * dLon))
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: HomeCustomMapView
        var lastApplied3DMode: Bool?
        var lastRequestedSpan: MKCoordinateSpan?
        var lastViewportCommand = 0
        private var annotationCache: [String: HomeCustomAnnotation] = [:]
        private var guidanceRouteUnderlay: MKPolyline?
        private var guidancePolyline: MKPolyline?
        private var guidancePolylineIsWalkingRoute = false
        private var activeGuidanceDirections: MKDirections?
        private var pendingGuidanceRouteSignature: String?
        private var renderedGuidanceRouteSignature: String?
        private var failedGuidanceRouteSignature: String?
        private var failedGuidanceRouteAt: Date?
        private var uncertaintyCircle: MKCircle?
        private var cachedCarPinImage: UIImage?
        private var cachedUndergroundPinImage: UIImage?
        private var lastGuidanceRouteSignature: String?
        private var lastWalkingRouteRequestAt: Date?
        private var lastWalkingRouteOrigin: CLLocationCoordinate2D?
        private var lastUncertaintySignature: String?
        private var lastAnnotationSignature: String?
        private let failedGuidanceRouteRetryInterval: TimeInterval = 8
        private let minimumWalkingRouteRefreshInterval: TimeInterval = 28
        private let minimumWalkingRouteRefreshDistanceMeters: CLLocationDistance = 35
        private var trackedGestureIDs = Set<ObjectIdentifier>()
        private var lastUserInteractionAt: Date?

        var hasRecentUserInteraction: Bool {
            lastUserInteractionAt.map { Date().timeIntervalSince($0) < 0.9 } == true
        }

        init(parent: HomeCustomMapView) {
            self.parent = parent
        }

        func installInteractionTracking(on mapView: MKMapView) {
            installGestureTracking(in: mapView)
        }

        private func installGestureTracking(in view: UIView) {
            for recognizer in view.gestureRecognizers ?? [] {
                let id = ObjectIdentifier(recognizer)
                guard !trackedGestureIDs.contains(id) else { continue }
                recognizer.addTarget(self, action: #selector(mapGestureDidChange(_:)))
                trackedGestureIDs.insert(id)
            }

            for subview in view.subviews {
                installGestureTracking(in: subview)
            }
        }

        @objc private func mapGestureDidChange(_ recognizer: UIGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            markUserInteraction()
        }

        func didReceiveViewportCommand(_ command: Int) -> Bool {
            defer { lastViewportCommand = command }
            return command != lastViewportCommand
        }

        func didRequestNewSpan(_ span: MKCoordinateSpan) -> Bool {
            defer { lastRequestedSpan = span }
            guard let previous = lastRequestedSpan else { return true }
            return abs(previous.latitudeDelta - span.latitudeDelta) > 0.00001
                || abs(previous.longitudeDelta - span.longitudeDelta) > 0.00001
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            installInteractionTracking(on: mapView)

            if hasActiveUserGesture(in: mapView) {
                markUserInteraction()
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            installInteractionTracking(on: mapView)

            if hasActiveUserGesture(in: mapView) {
                markUserInteraction()
            }

            let nextRegion = mapView.region
            let centerDistance = parent.approximateDistanceMeters(
                from: parent.region.center,
                to: nextRegion.center
            )
            let spanChanged =
                abs(parent.region.span.latitudeDelta - nextRegion.span.latitudeDelta) > 0.00001
                || abs(parent.region.span.longitudeDelta - nextRegion.span.longitudeDelta) > 0.00001

            guard centerDistance > 1 || spanChanged else { return }

            DispatchQueue.main.async { [weak self] in
                self?.parent.region = nextRegion
            }
        }

        private func hasActiveUserGesture(in view: UIView) -> Bool {
            if (view.gestureRecognizers ?? []).contains(where: { recognizer in
                recognizer.state == .began || recognizer.state == .changed
            }) {
                return true
            }

            return view.subviews.contains { hasActiveUserGesture(in: $0) }
        }

        private func markUserInteraction() {
            lastUserInteractionAt = Date()
            parent.isAutoFollowingUser = false
        }

        func syncAnnotations(on mapView: MKMapView) {
            let nextSignature = annotationSignature()
            if nextSignature == lastAnnotationSignature {
                syncUserHeading(on: mapView)
                return
            }
            lastAnnotationSignature = nextSignature

            let activeIDs = Set(parent.annotations.map(\.id))

            for id in annotationCache.keys where !activeIDs.contains(id) {
                if let ann = annotationCache[id] {
                    mapView.removeAnnotation(ann)
                }
                annotationCache.removeValue(forKey: id)
            }

            for pin in parent.annotations {
                if let existing = annotationCache[pin.id] {
                    let dist = CLLocation(
                        latitude: existing.coordinate.latitude,
                        longitude: existing.coordinate.longitude
                    )
                    .distance(
                        from: CLLocation(
                            latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude))
                    if dist > 2 {
                        existing.coordinate = pin.coordinate
                    }
                    if pin.kind == .user {
                        existing.profilePhotoData = parent.profilePhotoData
                        existing.headingDegrees = parent.resolvedUserHeadingDegrees
                    }
                } else {
                    let ann = HomeCustomAnnotation(
                        id: pin.id,
                        coordinate: pin.coordinate,
                        kind: {
                            switch pin.kind {
                            case .car:
                                return .car
                            case .user:
                                return .user
                            case .undergroundZone:
                                return .undergroundZone
                            }
                        }(),
                        profilePhotoData: pin.kind == .user ? parent.profilePhotoData : nil,
                        headingDegrees: pin.kind == .user ? parent.resolvedUserHeadingDegrees : nil
                    )
                    annotationCache[pin.id] = ann
                    mapView.addAnnotation(ann)
                }
            }

            syncUserHeading(on: mapView)
        }

        private func annotationSignature() -> String {
            let elements = parent.annotations
                .sorted(by: { $0.id < $1.id })
                .map { pin in
                    let lat = (pin.coordinate.latitude * 10000).rounded() / 10000
                    let lon = (pin.coordinate.longitude * 10000).rounded() / 10000
                    return "\(pin.id)-\(lat)-\(lon)-\(String(describing: pin.kind))"
                }
                .joined(separator: "|")

            return elements + "#photo:\(photoDataSignature(parent.profilePhotoData))"
        }

        func syncGuidanceOverlays(on mapView: MKMapView) {
            syncWalkingRoute(on: mapView)

            let uncertaintySignature = uncertaintySignature(
                center: parent.uncertaintyCenter, radius: parent.uncertaintyRadiusMeters)
            if uncertaintySignature == lastUncertaintySignature {
                return
            }
            lastUncertaintySignature = uncertaintySignature

            if let center = parent.uncertaintyCenter,
                let radius = parent.uncertaintyRadiusMeters
            {
                if let existing = uncertaintyCircle {
                    mapView.removeOverlay(existing)
                }
                let circle = MKCircle(center: center, radius: radius)
                uncertaintyCircle = circle
                mapView.addOverlay(circle)
            } else if let existing = uncertaintyCircle {
                mapView.removeOverlay(existing)
                uncertaintyCircle = nil
            }
        }

        private func guidanceRouteSignature(_ route: [CLLocationCoordinate2D]) -> String {
            guard route.count >= 2,
                let first = route.first,
                let last = route.last
            else {
                return "none"
            }

            let fLat = (first.latitude * 10000).rounded() / 10000
            let fLon = (first.longitude * 10000).rounded() / 10000
            let lLat = (last.latitude * 10000).rounded() / 10000
            let lLon = (last.longitude * 10000).rounded() / 10000
            return "\(route.count)-\(fLat)-\(fLon)-\(lLat)-\(lLon)"
        }

        private func uncertaintySignature(center: CLLocationCoordinate2D?, radius: Double?)
            -> String
        {
            guard let center, let radius else { return "none" }
            let lat = (center.latitude * 10000).rounded() / 10000
            let lon = (center.longitude * 10000).rounded() / 10000
            let roundedRadius = (radius / 5).rounded() * 5
            return "\(lat)-\(lon)-\(roundedRadius)"
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.14)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.45)
                renderer.lineWidth = 1.5
                renderer.lineDashPattern = [6, 4]
                return renderer
            }

            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                let isGuidanceUnderlay = guidanceRouteUnderlay.map { $0 === polyline } ?? false
                let isCurrentGuidance = guidancePolyline.map { $0 === polyline } ?? false
                if isGuidanceUnderlay {
                    renderer.strokeColor = guidancePolylineIsWalkingRoute
                        ? UIColor.white.withAlphaComponent(0.92)
                        : UIColor.white.withAlphaComponent(0.58)
                    renderer.lineWidth = guidancePolylineIsWalkingRoute ? 10 : 6
                    renderer.lineCap = .round
                    renderer.lineJoin = .round
                    if !guidancePolylineIsWalkingRoute {
                        renderer.lineDashPattern = [8, 6]
                    }
                    renderer.alpha = 0.9
                } else if isCurrentGuidance && guidancePolylineIsWalkingRoute {
                    renderer.strokeColor = UIColor.systemBlue
                    renderer.lineWidth = 6.25
                    renderer.lineCap = .round
                    renderer.lineJoin = .round
                    renderer.alpha = 0.95
                } else {
                    renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.72)
                    renderer.lineWidth = 3
                    renderer.lineDashPattern = [8, 6]
                    renderer.alpha = 0.85
                }
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let ann = annotation as? HomeCustomAnnotation else { return nil }

            switch ann.kind {
            case .user:
                let id = "user-pin"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? HomeUserAnnotationView
                    ?? HomeUserAnnotationView(annotation: ann, reuseIdentifier: id)
                v.annotation = ann
                v.update(profilePhotoData: ann.profilePhotoData)
                v.update(headingDegrees: screenHeadingDegrees(for: ann, on: mapView))
                return v
            case .car:
                let id = "car-pin-3d"
                let v =
                    mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: ann, reuseIdentifier: id)
                v.annotation = ann
                if let cachedCarPinImage {
                    v.image = cachedCarPinImage
                } else {
                    let image = make3DCarPin()
                    cachedCarPinImage = image
                    v.image = image
                }
                v.displayPriority = .required
                v.centerOffset = CGPoint(x: 0, y: -10)
                return v
            case .undergroundZone:
                let id = "underground-zone"
                let v =
                    mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: ann, reuseIdentifier: id)
                v.annotation = ann
                if let cachedUndergroundPinImage {
                    v.image = cachedUndergroundPinImage
                } else {
                    let image = makeUndergroundZonePin()
                    cachedUndergroundPinImage = image
                    v.image = image
                }
                v.displayPriority = .defaultLow
                v.centerOffset = .zero
                return v
            }
        }

        private func photoDataSignature(_ data: Data?) -> Int {
            guard let data, !data.isEmpty else { return 0 }
            let first = Int(data.first ?? 0)
            let midIndex = data.index(data.startIndex, offsetBy: data.count / 2)
            let mid = Int(data[midIndex])
            let last = Int(data.last ?? 0)
            return (data.count * 31) ^ (first << 16) ^ (mid << 8) ^ last
        }

        private func syncWalkingRoute(on mapView: MKMapView) {
            let routeSignature = guidanceRouteSignature(parent.guidanceRoute)

            guard parent.guidanceRoute.count >= 2,
                let user = parent.guidanceRoute.first,
                let car = parent.guidanceRoute.last,
                GuidanceRouteGuardrails.isValid(user),
                GuidanceRouteGuardrails.isValid(car)
            else {
                if lastGuidanceRouteSignature != "none" {
                    lastGuidanceRouteSignature = "none"
                    pendingGuidanceRouteSignature = nil
                    renderedGuidanceRouteSignature = nil
                    failedGuidanceRouteSignature = nil
                    failedGuidanceRouteAt = nil
                    lastWalkingRouteRequestAt = nil
                    lastWalkingRouteOrigin = nil
                    activeGuidanceDirections?.cancel()
                    activeGuidanceDirections = nil
                    removeGuidancePolyline(from: mapView)
                }
                return
            }

            guard let directDistance = GuidanceRouteGuardrails.straightLineDistance(
                from: user,
                to: car
            ),
                directDistance <= GuidanceRouteGuardrails.maximumWalkingRouteDistanceMeters
            else {
                activeGuidanceDirections?.cancel()
                activeGuidanceDirections = nil
                pendingGuidanceRouteSignature = nil
                renderedGuidanceRouteSignature = nil
                failedGuidanceRouteSignature = nil
                failedGuidanceRouteAt = nil
                lastWalkingRouteRequestAt = nil
                lastWalkingRouteOrigin = nil
                lastGuidanceRouteSignature = routeSignature
                removeGuidancePolyline(from: mapView)
                return
            }

            if guidancePolyline == nil {
                let fallbackPolyline = directGuidancePolyline(from: user, to: car)
                replaceGuidancePolyline(fallbackPolyline, isWalkingRoute: false, on: mapView)
                if parent.isAutoFollowingUser {
                    focusGuidanceRoute(fallbackPolyline, on: mapView, animated: true)
                }
            }

            let recentlyFailed =
                routeSignature == failedGuidanceRouteSignature
                && failedGuidanceRouteAt.map {
                    Date().timeIntervalSince($0) < failedGuidanceRouteRetryInterval
                } == true
            guard routeSignature != pendingGuidanceRouteSignature,
                routeSignature != renderedGuidanceRouteSignature,
                !recentlyFailed,
                shouldRefreshWalkingRoute(from: user, signature: routeSignature)
            else { return }

            lastGuidanceRouteSignature = routeSignature
            lastWalkingRouteRequestAt = Date()
            lastWalkingRouteOrigin = user
            requestWalkingGuidanceRoute(
                from: user,
                to: car,
                signature: routeSignature,
                mapView: mapView
            )
        }

        private func shouldRefreshWalkingRoute(
            from user: CLLocationCoordinate2D,
            signature: String
        ) -> Bool {
            if guidancePolyline == nil
                || (renderedGuidanceRouteSignature == nil && lastWalkingRouteRequestAt == nil)
            {
                return true
            }

            if signature == lastGuidanceRouteSignature {
                return false
            }

            let now = Date()
            let enoughTime = lastWalkingRouteRequestAt.map {
                now.timeIntervalSince($0) >= minimumWalkingRouteRefreshInterval
            } ?? true
            let enoughDistance = lastWalkingRouteOrigin.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: CLLocation(latitude: user.latitude, longitude: user.longitude))
                    >= minimumWalkingRouteRefreshDistanceMeters
            } ?? true

            return enoughTime || enoughDistance
        }

        private func requestWalkingGuidanceRoute(
            from user: CLLocationCoordinate2D,
            to car: CLLocationCoordinate2D,
            signature: String,
            mapView: MKMapView
        ) {
            activeGuidanceDirections?.cancel()
            pendingGuidanceRouteSignature = signature
            failedGuidanceRouteSignature = nil
            failedGuidanceRouteAt = nil

            if guidancePolyline == nil {
                let fallbackPolyline = directGuidancePolyline(from: user, to: car)
                replaceGuidancePolyline(fallbackPolyline, isWalkingRoute: false, on: mapView)
                if parent.isAutoFollowingUser {
                    focusGuidanceRoute(fallbackPolyline, on: mapView, animated: true)
                }
            }

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: user))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: car))
            request.transportType = .walking
            request.requestsAlternateRoutes = false

            let directions = MKDirections(request: request)
            activeGuidanceDirections = directions

            directions.calculate { [weak self, weak mapView] response, _ in
                DispatchQueue.main.async {
                    guard let self,
                        let mapView,
                        self.pendingGuidanceRouteSignature == signature
                    else { return }

                    self.pendingGuidanceRouteSignature = nil
                    self.activeGuidanceDirections = nil

                    guard let route = response?.routes.first else {
                        self.failedGuidanceRouteSignature = signature
                        self.failedGuidanceRouteAt = Date()
                        self.renderedGuidanceRouteSignature = nil
                        if self.guidancePolyline == nil || !self.guidancePolylineIsWalkingRoute {
                            self.replaceGuidancePolyline(
                                self.directGuidancePolyline(from: user, to: car),
                                isWalkingRoute: false,
                                on: mapView
                            )
                        }
                        return
                    }

                    let shouldFocusRoute =
                        self.guidancePolyline == nil && self.parent.isAutoFollowingUser
                    self.replaceGuidancePolyline(route.polyline, isWalkingRoute: true, on: mapView)
                    self.renderedGuidanceRouteSignature = signature
                    self.failedGuidanceRouteSignature = nil
                    self.failedGuidanceRouteAt = nil
                    if shouldFocusRoute {
                        self.focusGuidanceRoute(route.polyline, on: mapView, animated: true)
                    }
                }
            }
        }

        private func replaceGuidancePolyline(
            _ polyline: MKPolyline,
            isWalkingRoute: Bool,
            on mapView: MKMapView
        ) {
            removeGuidancePolyline(from: mapView)
            let underlay = copyPolyline(polyline)
            guidanceRouteUnderlay = underlay
            guidancePolyline = polyline
            guidancePolylineIsWalkingRoute = isWalkingRoute
            mapView.addOverlay(underlay, level: .aboveRoads)
            mapView.addOverlay(polyline, level: .aboveLabels)
        }

        private func directGuidancePolyline(
            from user: CLLocationCoordinate2D,
            to car: CLLocationCoordinate2D
        ) -> MKPolyline {
            let coordinates = [user, car]
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }

        private func removeGuidancePolyline(from mapView: MKMapView) {
            if let guidanceRouteUnderlay {
                mapView.removeOverlay(guidanceRouteUnderlay)
                self.guidanceRouteUnderlay = nil
            }

            if let guidancePolyline {
                mapView.removeOverlay(guidancePolyline)
                self.guidancePolyline = nil
                guidancePolylineIsWalkingRoute = false
            }
        }

        private func copyPolyline(_ polyline: MKPolyline) -> MKPolyline {
            var coordinates = Array(
                repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                count: polyline.pointCount
            )
            polyline.getCoordinates(
                &coordinates,
                range: NSRange(location: 0, length: polyline.pointCount)
            )
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }

        private func focusGuidanceRoute(
            _ polyline: MKPolyline,
            on mapView: MKMapView,
            animated: Bool
        ) {
            mapView.setVisibleMapRect(
                polyline.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 130, left: 46, bottom: 310, right: 92),
                animated: animated
            )
        }

        private func syncUserHeading(on mapView: MKMapView) {
            guard let userAnnotation = annotationCache["user-location"],
                userAnnotation.kind == .user
            else { return }

            userAnnotation.headingDegrees = parent.resolvedUserHeadingDegrees
            guard let view = mapView.view(for: userAnnotation) as? HomeUserAnnotationView else {
                return
            }

            view.update(profilePhotoData: userAnnotation.profilePhotoData)
            view.update(headingDegrees: screenHeadingDegrees(for: userAnnotation, on: mapView))
        }

        private func screenHeadingDegrees(
            for annotation: HomeCustomAnnotation,
            on mapView: MKMapView
        ) -> CLLocationDirection? {
            guard let heading = annotation.headingDegrees else { return nil }
            return (heading - mapView.camera.heading + 360).truncatingRemainder(dividingBy: 360)
        }

        private func makeUndergroundZonePin() -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 132, height: 132))
            return renderer.image { _ in
                UIColor.systemBlue.withAlphaComponent(0.16).setFill()
                UIBezierPath(ovalIn: CGRect(x: 10, y: 10, width: 112, height: 112)).fill()

                UIColor.systemBlue.withAlphaComponent(0.28).setStroke()
                let midRing = UIBezierPath(ovalIn: CGRect(x: 24, y: 24, width: 84, height: 84))
                midRing.lineWidth = 2
                midRing.stroke()

                UIColor.systemBlue.withAlphaComponent(0.35).setStroke()
                let outerRing = UIBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 116, height: 116))
                outerRing.lineWidth = 1.5
                outerRing.stroke()
            }
        }

        private func make3DCarPin() -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 52, height: 48))
            return renderer.image { ctx in
                let cg = ctx.cgContext
                let cs = CGColorSpaceCreateDeviceRGB()

                UIColor.black.withAlphaComponent(0.28).setFill()
                UIBezierPath(ovalIn: CGRect(x: 8, y: 41, width: 36, height: 5)).fill()

                cg.saveGState()
                UIBezierPath(
                    roundedRect: CGRect(x: 2, y: 20, width: 48, height: 18), cornerRadius: 6
                ).addClip()
                if let grad = CGGradient(
                    colorsSpace: cs,
                    colors: [UIColor.systemBlue.cgColor, UIColor.systemIndigo.cgColor] as CFArray,
                    locations: [0, 1])
                {
                    cg.drawLinearGradient(
                        grad, start: CGPoint(x: 2, y: 20), end: CGPoint(x: 50, y: 38), options: [])
                }
                cg.restoreGState()

                cg.saveGState()
                UIBezierPath(
                    roundedRect: CGRect(x: 14, y: 8, width: 24, height: 13), cornerRadius: 4
                ).addClip()
                if let roofGrad = CGGradient(
                    colorsSpace: cs,
                    colors: [
                        UIColor(red: 0.24, green: 0.50, blue: 0.94, alpha: 1).cgColor,
                        UIColor.systemIndigo.cgColor,
                    ] as CFArray,
                    locations: [0, 1])
                {
                    cg.drawLinearGradient(
                        roofGrad, start: CGPoint(x: 14, y: 8), end: CGPoint(x: 38, y: 21),
                        options: [])
                }
                cg.restoreGState()

                UIColor(white: 0.96, alpha: 0.55).setFill()
                UIBezierPath(
                    roundedRect: CGRect(x: 16, y: 10, width: 8, height: 8), cornerRadius: 2
                ).fill()
                UIBezierPath(
                    roundedRect: CGRect(x: 28, y: 10, width: 8, height: 8), cornerRadius: 2
                ).fill()

                UIColor(white: 0.1, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: 3, y: 29, width: 14, height: 11)).fill()
                UIBezierPath(ovalIn: CGRect(x: 35, y: 29, width: 14, height: 11)).fill()
                UIColor(white: 0.82, alpha: 0.9).setFill()
                UIBezierPath(ovalIn: CGRect(x: 7, y: 32, width: 6, height: 6)).fill()
                UIBezierPath(ovalIn: CGRect(x: 39, y: 32, width: 6, height: 6)).fill()

                UIColor.white.withAlphaComponent(0.95).setFill()
                UIBezierPath(
                    roundedRect: CGRect(x: 3, y: 23, width: 6, height: 4), cornerRadius: 1.5
                ).fill()
                UIColor.systemRed.withAlphaComponent(0.9).setFill()
                UIBezierPath(
                    roundedRect: CGRect(x: 43, y: 23, width: 6, height: 4), cornerRadius: 1.5
                ).fill()

                UIColor.white.withAlphaComponent(0.2).setFill()
                UIBezierPath(
                    roundedRect: CGRect(x: 2, y: 20, width: 48, height: 5), cornerRadius: 3
                ).fill()

                let tail = UIBezierPath()
                tail.move(to: CGPoint(x: 20, y: 38))
                tail.addLine(to: CGPoint(x: 26, y: 47))
                tail.addLine(to: CGPoint(x: 32, y: 38))
                tail.close()
                UIColor.systemIndigo.setFill()
                tail.fill()
            }
        }
    }
}

private final class HomeUserAnnotationView: MKAnnotationView {
    private enum Metrics {
        static let annotationSize = CGSize(width: 76, height: 76)
        static let pulseSize = CGSize(width: 46, height: 46)
        static let puckSize = CGSize(width: 30, height: 30)
        static let dotSize = CGSize(width: 22, height: 22)
        static let fieldOfViewRadius: CGFloat = 44
        static let fieldOfViewHalfAngle = CGFloat(25 * Double.pi / 180)
    }

    private let directionContainer = UIView()
    private let fieldOfViewLayer = CAShapeLayer()
    private let pulseCircle = UIView()
    private let puckContainer = UIView()
    private let puckDot = UIView()
    private var lastPhotoSignature: Int?
    private var displayedHeadingDegrees: CLLocationDirection?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        directionContainer.bounds = CGRect(origin: .zero, size: bounds.size)
        directionContainer.center = center
        fieldOfViewLayer.frame = directionContainer.bounds

        let localCenter = CGPoint(
            x: directionContainer.bounds.midX,
            y: directionContainer.bounds.midY
        )
        let startAngle = -CGFloat.pi / 2 - Metrics.fieldOfViewHalfAngle
        let endAngle = -CGFloat.pi / 2 + Metrics.fieldOfViewHalfAngle

        let path = UIBezierPath()
        path.move(to: localCenter)
        path.addArc(
            withCenter: localCenter,
            radius: Metrics.fieldOfViewRadius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        path.close()
        fieldOfViewLayer.path = path.cgPath

        pulseCircle.bounds = CGRect(origin: .zero, size: Metrics.pulseSize)
        pulseCircle.center = center
        pulseCircle.layer.cornerRadius = Metrics.pulseSize.width / 2

        puckContainer.bounds = CGRect(origin: .zero, size: Metrics.puckSize)
        puckContainer.center = center
        puckContainer.layer.cornerRadius = Metrics.puckSize.width / 2

        puckDot.bounds = CGRect(origin: .zero, size: Metrics.dotSize)
        puckDot.center = CGPoint(x: Metrics.puckSize.width / 2, y: Metrics.puckSize.height / 2)
        puckDot.layer.cornerRadius = Metrics.dotSize.width / 2
    }

    func update(profilePhotoData: Data?) {
        let signature = photoDataSignature(profilePhotoData)
        guard signature != lastPhotoSignature else { return }
        lastPhotoSignature = signature
    }

    func update(headingDegrees: CLLocationDirection?) {
        guard let headingDegrees, headingDegrees.isFinite else {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
            ) {
                self.directionContainer.alpha = 0.28
            }
            return
        }

        let nextHeading = unwrappedHeadingDegrees(toward: headingDegrees)
        displayedHeadingDegrees = nextHeading
        let transform = CGAffineTransform(rotationAngle: CGFloat(nextHeading * .pi / 180))

        if window == nil {
            directionContainer.alpha = 1
            directionContainer.transform = transform
        } else {
            UIView.animate(
                withDuration: 0.24,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
            ) {
                self.directionContainer.alpha = 1
                self.directionContainer.transform = transform
            }
        }
    }

    private func configure() {
        guard subviews.isEmpty else { return }

        bounds = CGRect(origin: .zero, size: Metrics.annotationSize)
        centerOffset = .zero
        canShowCallout = false
        collisionMode = .circle
        displayPriority = .required
        backgroundColor = .clear
        isOpaque = false

        directionContainer.backgroundColor = .clear
        directionContainer.isOpaque = false
        directionContainer.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        fieldOfViewLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.20).cgColor
        fieldOfViewLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.34).cgColor
        fieldOfViewLayer.lineWidth = 1
        directionContainer.layer.addSublayer(fieldOfViewLayer)

        pulseCircle.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.14)
        pulseCircle.layer.borderWidth = 1
        pulseCircle.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.22).cgColor

        puckContainer.backgroundColor = .white
        puckContainer.layer.shadowColor = UIColor.black.cgColor
        puckContainer.layer.shadowOpacity = 0.18
        puckContainer.layer.shadowRadius = 5
        puckContainer.layer.shadowOffset = CGSize(width: 0, height: 2)

        puckDot.backgroundColor = .systemBlue

        puckContainer.addSubview(puckDot)
        addSubview(directionContainer)
        addSubview(pulseCircle)
        addSubview(puckContainer)
    }

    private func photoDataSignature(_ data: Data?) -> Int {
        guard let data, !data.isEmpty else { return 0 }
        let first = Int(data.first ?? 0)
        let midIndex = data.index(data.startIndex, offsetBy: data.count / 2)
        let mid = Int(data[midIndex])
        let last = Int(data.last ?? 0)
        return (data.count * 31) ^ (first << 16) ^ (mid << 8) ^ last
    }

    private func unwrappedHeadingDegrees(toward target: CLLocationDirection) -> CLLocationDirection {
        let normalizedTarget = normalizeDegrees(target)
        guard let current = displayedHeadingDegrees else { return normalizedTarget }

        let normalizedCurrent = normalizeDegrees(current)
        var delta = normalizedTarget - normalizedCurrent
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return current + delta
    }

    private func normalizeDegrees(_ value: CLLocationDirection) -> CLLocationDirection {
        (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
}

private final class HomeCustomAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case user
        case car
        case undergroundZone
    }

    let id: String
    let kind: Kind
    var profilePhotoData: Data?
    var headingDegrees: CLLocationDirection?
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(
        id: String,
        coordinate: CLLocationCoordinate2D,
        kind: Kind,
        profilePhotoData: Data?,
        headingDegrees: CLLocationDirection?
    ) {
        self.id = id
        self.coordinate = coordinate
        self.kind = kind
        self.profilePhotoData = profilePhotoData
        self.headingDegrees = headingDegrees
    }
}

#else

import SwiftUI

struct HomeView: View {
    var body: some View {
        Text("Home is not available on this platform")
    }
}

#endif
