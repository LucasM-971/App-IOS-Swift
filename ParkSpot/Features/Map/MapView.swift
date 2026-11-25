import Combine
import MapKit
import SafariServices
import SwiftUI
import UIKit

struct MapView: View {
    @StateObject private var vm = ParkingMapViewModel()
    @State private var showingFilters = false
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var router: AppRouter
    @State private var showPremiumSheet = false
    @AppStorage("parkspot.map.is3DEnabled.v1") private var is3DMapEnabled = false

    var body: some View {
        NavigationStack {
            ZStack {
                ParkingExplorerMap(
                    region: $vm.region,
                    is3DEnabled: $is3DMapEnabled,
                    parkings: vm.visibleParkings,
                    routePolyline: vm.selectedRoutePolyline,
                    onRegionChange: { vm.handleRegionChange($0) },
                    onSelectParking: { vm.presentParking($0) }
                )
                .ignoresSafeArea()

                overlayContent

                if shouldShowParkingAccessGate {
                    ParkingAccessGatePopup(
                        isSignedOut: authSession.currentUser == nil,
                        onPrimaryAction: handleParkingAccessGatePrimaryAction
                    )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .navigationTitle("tabs.parking".psLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .sheet(isPresented: $showingFilters) {
                ParkingFiltersSheet(
                    filters: $vm.filters,
                    onReset: vm.resetFilters
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showPremiumSheet) {
                PremiumView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .interactiveDismissDisabled(false)
            }
            .overlay(alignment: .bottom) {
                if vm.isLoading {
                    loadingPill
                        .padding(.bottom, 24)
                }
            }
            .overlay {
                if let parking = vm.presentedParking {
                    ParkingDetailPopup(
                        parking: parking,
                        onClose: { vm.dismissPresentedParking() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert(
                "common.error".psLocalized,
                isPresented: Binding(
                    get: { vm.errorMessage != nil },
                    set: { visible in
                        if !visible {
                            vm.errorMessage = nil
                        }
                    }
                )
            ) {
                Button("common.ok".psLocalized) {
                    vm.errorMessage = nil
                }
            } message: {
                Text(vm.errorMessage ?? "map.load_error".psLocalized)
            }
            .onAppear {
                vm.onAppear()
            }
            .onDisappear {
                vm.onDisappear()
            }
        }
    }

    private var shouldShowParkingAccessGate: Bool {
        guard let user = authSession.currentUser else { return true }
        return !HistoryPlanResolver.isPremium(user)
    }

    private func handleParkingAccessGatePrimaryAction() {
        if authSession.currentUser == nil {
            router.navigateTo(.auth)
            return
        }

        showPremiumSheet = true
    }

    private var overlayContent: some View {
        VStack(spacing: 14) {
            HStack {
                Spacer()
                compactControls
            }

            Spacer()

            if vm.shouldShowEmptyState {
                emptyStateCard
                    .padding(.bottom, 96)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var compactControls: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Button {
                showingFilters = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    Text("map.filters".psLocalized)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            VStack(spacing: 8) {
                ParkingMapModeControlButton(is3DEnabled: $is3DMapEnabled)

                ParkingMapControlButton(
                    icon: "location.fill",
                    accessibilityLabel: "map.center_on_me".psLocalized
                ) {
                    vm.recenterOnUser()
                }
                .disabled(vm.userCoordinate == nil)
                .opacity(vm.userCoordinate == nil ? 0.45 : 1)

                ParkingMapControlButton(
                    icon: "plus",
                    accessibilityLabel: "map.zoom_in".psLocalized
                ) {
                    vm.zoomIn()
                }
                ParkingMapControlButton(
                    icon: "minus",
                    accessibilityLabel: "map.zoom_out".psLocalized
                ) {
                    vm.zoomOut()
                }
            }
            .padding(6)
            .background(
                .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "parkingsign.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(vm.emptyStateTitle)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("map.adjust_filters_hint".psLocalized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var loadingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("map.loading_parkings".psLocalized)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct ParkingAccessGatePopup: View {
    let isSignedOut: Bool
    let onPrimaryAction: () -> Void

    private var titleText: String {
        isSignedOut ? "Sign in required".psLocalized : "Premium access required".psLocalized
    }

    private var subtitleText: String {
        "Parking page locked".psLocalized
    }

    private var descriptionText: String {
        if isSignedOut {
            return "You need to sign in to access the Parking page. Create an account or log in to unlock nearby parking search, filters, and full map interactions.".psLocalized
        }

        return "The Parking page is reserved for Premium users. Upgrade to unlock nearby parking search, filters, and full map interactions.".psLocalized
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.blue, in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(titleText)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(subtitleText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                Text(descriptionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    premiumGateBullet("Search parking spots around you")
                    premiumGateBullet("Use the map filters and controls")
                    premiumGateBullet("Open parking details and manage sessions")
                }

                Button(action: onPrimaryAction) {
                    Text(isSignedOut ? "Sign in".psLocalized : "Upgrade to Premium".psLocalized)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "2563EB"), Color(hex: "1D4ED8")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            .padding(.horizontal, 20)
        }
    }

    private func premiumGateBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 16, weight: .semibold))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
private final class ParkingMapViewModel: ObservableObject {
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
        latitudinalMeters: 4_000,
        longitudinalMeters: 4_000
    )
    @Published var filters = ParkingMapFilters() {
        didSet {
            guard oldValue != filters else { return }
            applyFilters()
            if oldValue.radius != filters.radius {
                scheduleRefresh(force: true)
            }
        }
    }
    @Published private(set) var allParkings: [ParkingMapSpot] = []
    @Published private(set) var visibleParkings: [ParkingMapSpot] = []
    @Published var presentedParking: ParkingMapSpot?
    @Published var userCoordinate: Coordinate?
    @Published private(set) var selectedRoutePolyline: MKPolyline?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let locationService: LocationServiceProtocol
    private let discoveryService = ParkingDiscoveryService()
    private var cancellables = Set<AnyCancellable>()
    private var presentedParkingAddressTask: Task<Void, Never>?
    private var selectedRouteTask: Task<Void, Never>?
    private var selectedRouteSignature: String?
    private var fetchedParkings: [ParkingMapSpot] = []
    private var hasStarted = false
    private var hasCenteredOnUser = false
    private var refreshTask: Task<Void, Never>?
    private var refreshToken = UUID()
    private var lastLoadedQuery: ParkingQuerySignature?

    init(locationService: LocationServiceProtocol? = nil) {
        self.locationService = locationService ?? DIContainer.shared.locationService
        bindLocation()
    }

    var shouldShowEmptyState: Bool {
        !isLoading && visibleParkings.isEmpty
    }

    var visibleCountText: String {
        String.localizedStringWithFormat(
            "map.visible_count_format".psLocalized,
            visibleParkings.count,
            allParkings.count
        )
    }

    var summarySubtitle: String {
        String.localizedStringWithFormat(
            "map.radius.center_format".psLocalized,
            filters.radius.title
        )
    }

    var emptyStateTitle: String {
        return "map.no_results_title".psLocalized
    }

    var activeFilterPills: [FilterPill] {
        var pills: [FilterPill] = [
            FilterPill(
                id: "radius",
                title: filters.radius.title,
                systemImage: "scope"
            )
        ]

        if filters.type != .all {
            pills.append(
                FilterPill(
                    id: "type",
                    title: filters.type.displayName,
                    systemImage: filters.type.systemImage
                )
            )
        }

        if filters.pricing != .all {
            pills.append(
                FilterPill(
                    id: "pricing",
                    title: filters.pricing.displayName,
                    systemImage: filters.pricing == .free ? "eurosign.circle" : "creditcard.fill"
                )
            )
        }

        return pills
    }

    func onAppear() {
        locationService.requestAuthorization()
        locationService.requestTemporaryFullAccuracyIfNeeded()
        locationService.startUpdating()
        locationService.setPreferredLocationMode(.navigation)

        if !hasStarted {
            hasStarted = true
            scheduleRefresh(force: true)
        } else if fetchedParkings.isEmpty {
            scheduleRefresh(force: true)
        }
    }

    func onDisappear() {
        refreshTask?.cancel()
        presentedParkingAddressTask?.cancel()
        selectedRouteTask?.cancel()
        locationService.stopUpdating()
    }

    func resetFilters() {
        filters = ParkingMapFilters()
    }

    func recenterOnUser() {
        guard let userCoordinate else { return }

        region = MKCoordinateRegion(
            center: userCoordinate.coordinate2D,
            latitudinalMeters: filters.radius.meters * 1.6,
            longitudinalMeters: filters.radius.meters * 1.6
        )
        scheduleRefresh(force: true)
    }

    func zoomIn() {
        zoom(by: 0.65)
    }

    func zoomOut() {
        zoom(by: 1.45)
    }

    func presentParking(_ parking: ParkingMapSpot) {
        presentedParking = parking
        resolvePresentedParkingDetailsIfNeeded(for: parking)
        refreshSelectedRoute(to: parking)
    }

    func dismissPresentedParking() {
        presentedParkingAddressTask?.cancel()
        selectedRouteTask?.cancel()
        selectedRoutePolyline = nil
        selectedRouteSignature = nil
        presentedParking = nil
    }

    private func resolvePresentedParkingDetailsIfNeeded(for parking: ParkingMapSpot) {
        presentedParkingAddressTask?.cancel()

        if parking.source == .overpass {
            guard parking.needsOSMEnrichment else { return }
        } else {
            guard !parking.hasDisplayableAddress else { return }
        }

        presentedParkingAddressTask = Task { [weak self] in
            guard let self else { return }

            if parking.source == .overpass {
                guard !Task.isCancelled else { return }

                let resolvedDetails = try? await self.resolveOSMDetails(for: parking)
                guard !Task.isCancelled,
                    let resolvedDetails,
                    resolvedDetails.hasAnyValue
                else {
                    return
                }

                self.applyResolvedOSMDetails(resolvedDetails, toParkingID: parking.id)
                return
            }

            if parking.source == .overpass {
                return
            } else {
                let resolvedAddress = try? await self.locationService.reverseGeocode(parking.coordinate)
                guard !Task.isCancelled,
                    let sanitizedAddress = self.sanitizedAddress(resolvedAddress)
                else {
                    return
                }

                self.applyResolvedAddress(sanitizedAddress, toParkingID: parking.id)
            }
        }
    }

    private func resolveOSMDetails(for parking: ParkingMapSpot) async throws -> OSMResolvedParkingDetails {
        if let sourceURL = parking.sourceURL,
            let lookupID = osmLookupID(from: sourceURL),
            let lookupDetails = try await fetchOSMLookupDetails(for: lookupID),
            lookupDetails.hasAnyValue
        {
            var details = lookupDetails
            if details.officialImageURL == nil,
                let commonsCategory = details.commonsCategory
            {
                details.officialImageURL = try? await fetchCommonsCategoryImageURL(
                    named: commonsCategory
                )
            }
            if details.address == nil {
                details.address = try await fetchOSMReverseAddress(for: parking.coordinate)
            }
            return details
        }

        return OSMResolvedParkingDetails(
            address: try await fetchOSMReverseAddress(for: parking.coordinate)
        )
    }

    private func osmLookupID(from sourceURL: URL) -> String? {
        let parts = sourceURL.path
            .split(separator: "/")
            .map(String.init)

        guard parts.count >= 2 else { return nil }

        let type = parts[parts.count - 2].lowercased()
        let id = parts[parts.count - 1]
        guard !id.isEmpty else { return nil }

        switch type {
        case "node":
            return "N\(id)"
        case "way":
            return "W\(id)"
        case "relation":
            return "R\(id)"
        default:
            return nil
        }
    }

    private func fetchOSMLookupDetails(for lookupID: String) async throws -> OSMResolvedParkingDetails? {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/lookup")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "extratags", value: "1"),
            URLQueryItem(name: "osm_ids", value: lookupID)
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("ParkSpot/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            return nil
        }

        let decoded = try JSONDecoder().decode([OSMGeocodingResponse].self, from: data)
        guard let first = decoded.first else { return nil }
        return resolvedOSMDetails(from: first)
    }

    private func fetchOSMReverseAddress(for coordinate: Coordinate) async throws -> String? {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude))
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("ParkSpot/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            return nil
        }

        let decoded = try JSONDecoder().decode(OSMGeocodingResponse.self, from: data)
        return formattedOSMAddress(from: decoded)
    }

    private func fetchCommonsCategoryImageURL(named category: String) async throws -> URL? {
        let normalizedCategory =
            category.hasPrefix("Category:") ? category : "Category:\(category)"

        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "categorymembers"),
            URLQueryItem(name: "gcmtitle", value: normalizedCategory),
            URLQueryItem(name: "gcmtype", value: "file"),
            URLQueryItem(name: "gcmlimit", value: "6"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime"),
            URLQueryItem(name: "iiurlwidth", value: "900")
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("ParkSpot/1.0 (iOS parking discovery)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            return nil
        }

        let decoded = try JSONDecoder().decode(CommonsCategoryImageResponse.self, from: data)
        return decoded.query?.pages?.values
            .compactMap { page in
                page.imageinfo?.first(where: { $0.isDisplayableImage })?.bestURL
            }
            .first
    }

    private func formattedOSMAddress(from response: OSMGeocodingResponse) -> String? {
        let street = [response.address?.houseNumber, response.address?.road]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")

        let locality = [
            response.address?.postcode,
            response.address?.city,
            response.address?.town,
            response.address?.village,
            response.address?.municipality,
            response.address?.county,
            response.address?.state
        ]
        .compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        .joined(separator: " ")

        let parts = [street, locality].filter { !$0.isEmpty }
        if !parts.isEmpty {
            return parts.joined(separator: ", ")
        }

        guard let displayName = response.displayName else { return nil }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolvedOSMDetails(from response: OSMGeocodingResponse) -> OSMResolvedParkingDetails {
        let extra = response.extratags ?? [:]

        return OSMResolvedParkingDetails(
            address: formattedOSMAddress(from: response),
            operatorName: firstNonEmpty(extra["operator"], extra["brand"], response.name),
            capacity: firstNonEmpty(extra["capacity"]),
            openingHours: firstNonEmpty(extra["opening_hours"]),
            maxStay: firstNonEmpty(extra["maxstay"], extra["maxstay:conditional"]),
            phoneNumber: firstNonEmpty(extra["phone"], extra["contact:phone"]),
            website: normalizedURL(from: firstNonEmpty(extra["website"], extra["contact:website"], extra["url"])),
            officialImageURL: resolvedOfficialImageURL(from: extra),
            levels: firstNonEmpty(extra["levels"], extra["level"]),
            accessDescription: firstNonEmpty(extra["access"]),
            commonsCategory: wikimediaCommonsCategoryName(
                from: firstNonEmpty(extra["wikimedia_commons"], extra["wikimedia:commons"])
            )
        )
    }

    private func normalizedURL(from rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else {
            return nil
        }

        if let url = URL(string: rawValue), url.scheme != nil {
            return url
        }

        return URL(string: "https://\(rawValue)")
    }

    private func resolvedOfficialImageURL(from tags: [String: String]) -> URL? {
        let candidates = [
            tags["image"],
            tags["image:0"],
            tags["image:1"],
            tags["contact:image"],
            tags["photo"],
            tags["wikimedia_commons"],
            tags["wikimedia:commons"]
        ]

        for candidate in candidates {
            if let imageURL = resolvedParkingImageURL(from: candidate) {
                return imageURL
            }
        }

        return nil
    }

    private func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func sanitizedAddress(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return trimmed
    }

    private func applyResolvedAddress(_ address: String, toParkingID parkingID: String) {
        fetchedParkings = fetchedParkings.map { parking in
            parking.id == parkingID ? parking.withResolvedAddress(address) : parking
        }
        allParkings = allParkings.map { parking in
            parking.id == parkingID ? parking.withResolvedAddress(address) : parking
        }
        visibleParkings = visibleParkings.map { parking in
            parking.id == parkingID ? parking.withResolvedAddress(address) : parking
        }

        if let presentedParking, presentedParking.id == parkingID {
            self.presentedParking = presentedParking.withResolvedAddress(address)
        }
    }

    private func applyResolvedOSMDetails(_ details: OSMResolvedParkingDetails, toParkingID parkingID: String) {
        fetchedParkings = fetchedParkings.map { parking in
            parking.id == parkingID ? parking.withResolvedOSMDetails(details) : parking
        }
        allParkings = allParkings.map { parking in
            parking.id == parkingID ? parking.withResolvedOSMDetails(details) : parking
        }
        visibleParkings = visibleParkings.map { parking in
            parking.id == parkingID ? parking.withResolvedOSMDetails(details) : parking
        }

        if let presentedParking, presentedParking.id == parkingID {
            self.presentedParking = presentedParking.withResolvedOSMDetails(details)
        }
    }

    func handleRegionChange(_ newRegion: MKCoordinateRegion) {
        let nextCenter = Coordinate(
            latitude: newRegion.center.latitude,
            longitude: newRegion.center.longitude
        )
        let currentCenter = Coordinate(
            latitude: region.center.latitude,
            longitude: region.center.longitude
        )

        let centerMoved = distanceBetween(currentCenter, nextCenter) > 120
        let zoomChanged =
            abs(region.span.latitudeDelta - newRegion.span.latitudeDelta) > 0.01
            || abs(region.span.longitudeDelta - newRegion.span.longitudeDelta) > 0.01

        guard centerMoved || zoomChanged else { return }

        region = newRegion
        scheduleRefresh(force: false)
    }

    private func bindLocation() {
        locationService.currentLocationSample
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                guard let self else { return }

                userCoordinate = sample.coordinate
                if let presentedParking {
                    refreshSelectedRoute(to: presentedParking)
                }

                if !hasCenteredOnUser {
                    hasCenteredOnUser = true
                    region = MKCoordinateRegion(
                        center: sample.coordinate.coordinate2D,
                        latitudinalMeters: filters.radius.meters * 1.6,
                        longitudinalMeters: filters.radius.meters * 1.6
                    )
                    scheduleRefresh(force: true)
                } else {
                    applyFilters()
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleRefresh(force: Bool) {
        let query = currentQuerySignature
        guard force || shouldReload(for: query) else { return }

        refreshTask?.cancel()

        let token = UUID()
        refreshToken = token

        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.loadParkings(for: query, token: token)
        }
    }

    private var currentQuerySignature: ParkingQuerySignature {
        ParkingQuerySignature(
            center: Coordinate(
                latitude: region.center.latitude,
                longitude: region.center.longitude
            ),
            radiusMeters: filters.radius.meters
        )
    }

    private func shouldReload(for query: ParkingQuerySignature) -> Bool {
        guard let lastLoadedQuery else { return true }

        if abs(lastLoadedQuery.radiusMeters - query.radiusMeters) > 1 {
            return true
        }

        return distanceBetween(lastLoadedQuery.center, query.center)
            > max(220, query.radiusMeters * 0.22)
    }

    private func loadParkings(for query: ParkingQuerySignature, token: UUID) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let queryRegion = MKCoordinateRegion(
                center: query.center.coordinate2D,
                latitudinalMeters: query.radiusMeters * 2.1,
                longitudinalMeters: query.radiusMeters * 2.1
            )

            let parkings = try await discoveryService.fetchParkings(in: queryRegion)

            guard !Task.isCancelled, token == refreshToken else { return }

            lastLoadedQuery = query
            fetchedParkings = parkings
            applyFilters()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, token == refreshToken else { return }

            if fetchedParkings.isEmpty {
                errorMessage = "map.load_error".psLocalized
            }
        }
    }

    private func applyFilters() {
        let reference =
            userCoordinate
            ?? Coordinate(
                latitude: region.center.latitude,
                longitude: region.center.longitude
            )

        let ranked =
            fetchedParkings
            .map { $0.withDistance(from: reference) }
            .sorted(by: { lhs, rhs in
                switch (lhs.distanceMeters, rhs.distanceMeters) {
                case (let left?, let right?) where left != right:
                    return left < right
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    if lhs.source != rhs.source {
                        return lhs.source.sortOrder < rhs.source.sortOrder
                    }
                    return lhs.titleDisplay.localizedCaseInsensitiveCompare(rhs.titleDisplay)
                        == .orderedAscending
                }
            })

        allParkings = ranked
        visibleParkings = ranked.filter { parking in
            parking.accessLevel != .privateAccess
                && filters.type.matches(parking)
                && filters.pricing.matches(parking.pricing)
        }

        if let presentedParking,
            !visibleParkings.contains(where: { $0.id == presentedParking.id })
        {
            selectedRouteTask?.cancel()
            selectedRoutePolyline = nil
            selectedRouteSignature = nil
            self.presentedParking = nil
        }
    }

    private func refreshSelectedRoute(to parking: ParkingMapSpot) {
        guard let userCoordinate,
              userCoordinate.isValidGeoCoordinate,
              parking.coordinate.isValidGeoCoordinate else {
            selectedRouteTask?.cancel()
            selectedRoutePolyline = nil
            selectedRouteSignature = nil
            return
        }

        let signature = routeSignature(from: userCoordinate, to: parking.coordinate)
        guard signature != selectedRouteSignature else { return }

        selectedRouteTask?.cancel()
        selectedRouteSignature = signature

        let fallbackPolyline = directRoutePolyline(from: userCoordinate, to: parking.coordinate)
        selectedRoutePolyline = fallbackPolyline

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: userCoordinate.coordinate2D))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: parking.coordinate.coordinate2D))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        selectedRouteTask = Task { [weak self] in
            do {
                let response = try await MKDirections(request: request).calculate()
                guard !Task.isCancelled,
                      let self,
                      self.selectedRouteSignature == signature else {
                    return
                }

                guard let route = response.routes.first(where: { route in
                    route.transportType.contains(.walking)
                        && route.distance.isFinite
                        && route.distance > 0
                        && route.polyline.pointCount >= 2
                }) else {
                    self.selectedRoutePolyline = fallbackPolyline
                    return
                }

                self.selectedRoutePolyline = route.polyline
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.selectedRouteSignature == signature else {
                    return
                }

                self.selectedRoutePolyline = fallbackPolyline
            }
        }
    }

    private func directRoutePolyline(from user: Coordinate, to destination: Coordinate) -> MKPolyline {
        let coordinates = [user.coordinate2D, destination.coordinate2D]
        return MKPolyline(coordinates: coordinates, count: coordinates.count)
    }

    private func routeSignature(from user: Coordinate, to destination: Coordinate) -> String {
        [
            roundedRouteCoordinate(user.latitude),
            roundedRouteCoordinate(user.longitude),
            roundedRouteCoordinate(destination.latitude),
            roundedRouteCoordinate(destination.longitude)
        ].joined(separator: ":")
    }

    private func roundedRouteCoordinate(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func zoom(by factor: Double) {
        let nextLatitudeDelta = min(max(region.span.latitudeDelta * factor, 0.0012), 1.5)
        let nextLongitudeDelta = min(max(region.span.longitudeDelta * factor, 0.0012), 1.5)

        region = MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(
                latitudeDelta: nextLatitudeDelta,
                longitudeDelta: nextLongitudeDelta
            )
        )
    }

}

private struct OSMGeocodingResponse: Decodable {
    let displayName: String?
    let name: String?
    let address: OSMGeocodingAddress?
    let extratags: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case name
        case address
        case extratags
    }
}

private struct OSMGeocodingAddress: Decodable {
    let houseNumber: String?
    let road: String?
    let postcode: String?
    let city: String?
    let town: String?
    let village: String?
    let municipality: String?
    let county: String?
    let state: String?

    private enum CodingKeys: String, CodingKey {
        case houseNumber = "house_number"
        case road
        case postcode
        case city
        case town
        case village
        case municipality
        case county
        case state
    }
}

private struct CommonsCategoryImageResponse: Decodable {
    let query: Query?

    struct Query: Decodable {
        let pages: [String: Page]?
    }

    struct Page: Decodable {
        let imageinfo: [ImageInfo]?
    }

    struct ImageInfo: Decodable {
        let url: URL?
        let thumburl: URL?
        let mime: String?

        var bestURL: URL? {
            thumburl ?? url
        }

        var isDisplayableImage: Bool {
            guard let mime else { return bestURL?.hasDisplayableImagePathExtension == true }
            return mime.hasPrefix("image/")
                && !mime.localizedCaseInsensitiveContains("svg")
        }
    }
}

private struct OSMResolvedParkingDetails {
    var address: String?
    let operatorName: String?
    let capacity: String?
    let openingHours: String?
    let maxStay: String?
    let phoneNumber: String?
    let website: URL?
    var officialImageURL: URL?
    let levels: String?
    let accessDescription: String?
    let commonsCategory: String?

    init(
        address: String? = nil,
        operatorName: String? = nil,
        capacity: String? = nil,
        openingHours: String? = nil,
        maxStay: String? = nil,
        phoneNumber: String? = nil,
        website: URL? = nil,
        officialImageURL: URL? = nil,
        levels: String? = nil,
        accessDescription: String? = nil,
        commonsCategory: String? = nil
    ) {
        self.address = address
        self.operatorName = operatorName
        self.capacity = capacity
        self.openingHours = openingHours
        self.maxStay = maxStay
        self.phoneNumber = phoneNumber
        self.website = website
        self.officialImageURL = officialImageURL
        self.levels = levels
        self.accessDescription = accessDescription
        self.commonsCategory = commonsCategory
    }

    var hasAnyValue: Bool {
        address != nil
            || operatorName != nil
            || capacity != nil
            || openingHours != nil
            || maxStay != nil
            || phoneNumber != nil
            || website != nil
            || officialImageURL != nil
            || levels != nil
            || accessDescription != nil
            || commonsCategory != nil
    }
}

private struct ParkingExplorerMap: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var is3DEnabled: Bool
    let parkings: [ParkingMapSpot]
    let routePolyline: MKPolyline?
    let onRegionChange: (MKCoordinateRegion) -> Void
    let onSelectParking: (ParkingMapSpot) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.overrideUserInterfaceStyle = .unspecified
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .none
        mapView.setRegion(region, animated: false)

        applyMapConfiguration(on: mapView)
        context.coordinator.lastApplied3DMode = is3DEnabled

        context.coordinator.syncAnnotations(on: mapView)
        context.coordinator.syncRouteOverlay(on: mapView, shouldFocus: false)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        mapView.overrideUserInterfaceStyle = .unspecified
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .none

        if context.coordinator.lastApplied3DMode != is3DEnabled {
            applyMapConfiguration(on: mapView)
            context.coordinator.lastApplied3DMode = is3DEnabled
        }

        let shouldUpdateCenter =
            distanceBetween(
                Coordinate(
                    latitude: mapView.region.center.latitude,
                    longitude: mapView.region.center.longitude),
                Coordinate(latitude: region.center.latitude, longitude: region.center.longitude)
            ) > 2

        let shouldUpdateSpan =
            abs(mapView.region.span.latitudeDelta - region.span.latitudeDelta) > 0.0005
            || abs(mapView.region.span.longitudeDelta - region.span.longitudeDelta) > 0.0005

        if shouldUpdateCenter || shouldUpdateSpan {
            context.coordinator.isApplyingExternalRegion = true

            if is3DEnabled {
                let current = mapView.camera
                let targetDistance = max(220, min(2000, region.span.latitudeDelta * 111_000 * 1.25))
                let targetCenter = shouldUpdateCenter ? region.center : current.centerCoordinate
                let camera = MKMapCamera(
                    lookingAtCenter: targetCenter,
                    fromDistance: targetDistance,
                    pitch: 64,
                    heading: current.heading == 0 ? 22 : current.heading
                )
                mapView.setCamera(camera, animated: false)
            } else {
                mapView.setRegion(region, animated: false)
            }
        }

        context.coordinator.syncAnnotations(on: mapView)
        context.coordinator.syncRouteOverlay(on: mapView, shouldFocus: true)
    }

    private func applyMapConfiguration(on mapView: MKMapView) {
        let processInfo = ProcessInfo.processInfo
        let isPowerConstrained =
            processInfo.isLowPowerModeEnabled || processInfo.thermalState == .serious
            || processInfo.thermalState == .critical
        let canUse3D = is3DEnabled && !isPowerConstrained

        if #available(iOS 16.0, *) {
            if canUse3D {
                let configuration = MKStandardMapConfiguration(
                    elevationStyle: .realistic,
                    emphasisStyle: .default
                )
                configuration.pointOfInterestFilter = .excludingAll
                configuration.showsTraffic = false
                mapView.preferredConfiguration = configuration
            } else {
                let configuration = MKStandardMapConfiguration(
                    elevationStyle: .flat,
                    emphasisStyle: .default
                )
                configuration.pointOfInterestFilter = .excludingAll
                configuration.showsTraffic = false
                mapView.preferredConfiguration = configuration
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

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ParkingExplorerMap
        var isApplyingExternalRegion = false
        var lastApplied3DMode: Bool?
        private var annotationCache: [String: ParkingExplorerAnnotation] = [:]
        private var renderedRouteSignature: String?
        private var routeUnderlay: MKPolyline?
        private var routeOverlay: MKPolyline?

        init(parent: ParkingExplorerMap) {
            self.parent = parent
        }

        func syncAnnotations(on mapView: MKMapView) {
            let visibleIDs = Set(parent.parkings.map(\.id))
            let userID = ParkingExplorerAnnotation.userIdentifier

            for (id, annotation) in annotationCache where !visibleIDs.contains(id) {
                mapView.removeAnnotation(annotation)
                annotationCache.removeValue(forKey: id)
            }

            if let userAnnotation = annotationCache[userID] {
                mapView.removeAnnotation(userAnnotation)
                annotationCache.removeValue(forKey: userID)
            }

            for parking in parent.parkings {
                if let annotation = annotationCache[parking.id] {
                    annotation.coordinate = parking.coordinate.coordinate2D
                    annotation.title = parking.titleDisplay
                    annotation.subtitle = parking.address
                    annotation.parking = parking
                } else {
                    let annotation = ParkingExplorerAnnotation(parking: parking)
                    annotationCache[parking.id] = annotation
                    mapView.addAnnotation(annotation)
                }
            }
        }

        func syncRouteOverlay(on mapView: MKMapView, shouldFocus: Bool) {
            guard let nextRoute = parent.routePolyline,
                  nextRoute.pointCount >= 2 else {
                if renderedRouteSignature != nil {
                    renderedRouteSignature = nil
                    removeRouteOverlay(from: mapView)
                }
                return
            }

            let signature = routeSignature(nextRoute)
            guard signature != renderedRouteSignature else { return }

            renderedRouteSignature = signature
            replaceRouteOverlay(nextRoute, on: mapView)
            if shouldFocus {
                focusRoute(nextRoute, on: mapView, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if isApplyingExternalRegion {
                isApplyingExternalRegion = false
                return
            }

            parent.region = mapView.region
            parent.onRegionChange(mapView.region)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            defer {
                if let annotation = view.annotation {
                    mapView.deselectAnnotation(annotation, animated: false)
                }
            }

            if let cluster = view.annotation as? MKClusterAnnotation {
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
                return
            }

            guard let annotation = view.annotation as? ParkingExplorerAnnotation,
                let parking = annotation.parking
            else {
                return
            }

            parent.onSelectParking(parking)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)
            let isUnderlay = routeUnderlay.map { $0 === polyline } ?? false

            renderer.strokeColor = isUnderlay
                ? UIColor.white.withAlphaComponent(0.92)
                : UIColor.systemBlue.withAlphaComponent(0.96)
            renderer.lineWidth = isUnderlay ? 10 : 6
            renderer.lineCap = .round
            renderer.lineJoin = .round
            renderer.alpha = isUnderlay ? 0.9 : 0.96
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let identifier = "parking-cluster"
                let view =
                    (mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                        as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: identifier)
                view.annotation = cluster
                view.markerTintColor = .systemGray
                view.glyphText = "\(cluster.memberAnnotations.count)"
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                return view
            }

            guard let annotation = annotation as? ParkingExplorerAnnotation else { return nil }

            let identifier = annotation.kind == .user ? "parking-user" : "parking-spot"
            let view =
                (mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = false
            view.titleVisibility = .hidden
            view.subtitleVisibility = .hidden

            switch annotation.kind {
            case .user:
                view.markerTintColor = .systemBlue
                view.glyphImage = UIImage(systemName: "location.fill")
                view.clusteringIdentifier = nil
                view.displayPriority = .required
            case .parking:
                guard let parking = annotation.parking else { return view }
                view.markerTintColor = parking.markerTintUIColor
                view.glyphImage = UIImage(systemName: parking.markerSystemImage)
                view.clusteringIdentifier = "parking-cluster"
                view.displayPriority = .defaultHigh
            }

            return view
        }

        private func replaceRouteOverlay(_ polyline: MKPolyline, on mapView: MKMapView) {
            removeRouteOverlay(from: mapView)

            let underlay = copyPolyline(polyline)
            routeUnderlay = underlay
            routeOverlay = polyline
            mapView.addOverlay(underlay, level: .aboveRoads)
            mapView.addOverlay(polyline, level: .aboveLabels)
        }

        private func removeRouteOverlay(from mapView: MKMapView) {
            if let routeUnderlay {
                mapView.removeOverlay(routeUnderlay)
                self.routeUnderlay = nil
            }

            if let routeOverlay {
                mapView.removeOverlay(routeOverlay)
                self.routeOverlay = nil
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

        private func focusRoute(_ polyline: MKPolyline, on mapView: MKMapView, animated: Bool) {
            isApplyingExternalRegion = true
            mapView.setVisibleMapRect(
                polyline.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 120, left: 44, bottom: 330, right: 88),
                animated: animated
            )
        }

        private func routeSignature(_ polyline: MKPolyline) -> String {
            guard polyline.pointCount >= 2 else { return "none" }

            var coordinates = Array(
                repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                count: polyline.pointCount
            )
            polyline.getCoordinates(
                &coordinates,
                range: NSRange(location: 0, length: polyline.pointCount)
            )

            guard let first = coordinates.first,
                  let last = coordinates.last else {
                return "none"
            }

            let firstLat = roundedRouteCoordinate(first.latitude)
            let firstLon = roundedRouteCoordinate(first.longitude)
            let lastLat = roundedRouteCoordinate(last.latitude)
            let lastLon = roundedRouteCoordinate(last.longitude)
            return "\(polyline.pointCount):\(firstLat):\(firstLon):\(lastLat):\(lastLon)"
        }

        private func roundedRouteCoordinate(_ value: CLLocationDegrees) -> String {
            String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
    }
}

private struct ParkingFiltersSheet: View {
    @Binding var filters: ParkingMapFilters
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("map.filter_type".psLocalized) {
                    Picker("map.filter_type".psLocalized, selection: $filters.type) {
                        ForEach(ParkingTypeFilter.allCases) { type in
                            Label(type.displayName, systemImage: type.systemImage).tag(type)
                        }
                    }
                }

                Section("map.filter_tariff".psLocalized) {
                    Picker("map.filter_tariff".psLocalized, selection: $filters.pricing) {
                        ForEach(ParkingPricingFilter.allCases) { pricing in
                            Text(pricing.displayName).tag(pricing)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("map.filter_radius".psLocalized) {
                    Picker("map.filter_radius".psLocalized, selection: $filters.radius) {
                        ForEach(ParkingRadiusOption.allCases) { radius in
                            Text(radius.title).tag(radius)
                        }
                    }
                }
            }
            .navigationTitle("map.filters_title".psLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("map.filters_reset".psLocalized) {
                        onReset()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.ok".psLocalized) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ParkingDetailPopup: View {
    let parking: ParkingMapSpot
    let onClose: () -> Void
    @State private var inAppLink: ParkingInAppLink?

    private enum PopupLayout: Equatable {
        case regular
        case compact
        case tight

        var heroHeight: CGFloat {
            switch self {
            case .regular: return 150
            case .compact: return 132
            case .tight: return 112
            }
        }

        var contentSpacing: CGFloat {
            switch self {
            case .regular: return 16
            case .compact: return 12
            case .tight: return 8
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .regular: return 16
            case .compact: return 14
            case .tight: return 12
            }
        }

        var bottomPadding: CGFloat {
            switch self {
            case .regular: return 16
            case .compact: return 14
            case .tight: return 12
            }
        }

        var titleSize: CGFloat {
            switch self {
            case .regular: return 22
            case .compact: return 20
            case .tight: return 18
            }
        }

        var titleLineLimit: Int { self == .tight ? 1 : 2 }
        var addressLineLimit: Int { self == .regular ? 3 : (self == .compact ? 2 : 1) }
        var quickFactLimit: Int { self == .regular ? 3 : 2 }
        var informationRowLimit: Int { self == .regular ? 4 : (self == .compact ? 3 : 2) }
        var infoValueLineLimit: Int { self == .regular ? 2 : 1 }
        var calloutLineLimit: Int { self == .regular ? 2 : 1 }
        var showsCallout: Bool { self == .regular }
        var showsSecondaryActions: Bool { self != .tight }
    }

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = max(
                260,
                proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom - 24
            )
            let maxCardHeight = min(availableHeight, max(260, proxy.size.height * 0.82))
            let layout = popupLayout(maxHeight: maxCardHeight)

            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    popupCard(layout: layout)
                        .padding(.horizontal, 12)
                        .padding(.bottom, max(12, proxy.safeAreaInsets.bottom + 8))
                }
            }
        }
        .sheet(item: $inAppLink) { link in
            ParkingSafariSheet(url: link.url)
        }
    }

    private func popupCard(layout: PopupLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.28))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 10)

            popupBody(layout: layout)
        }
        .frame(maxWidth: 430)
        .background(
            Color(.systemBackground),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
    }

    private func popupLayout(maxHeight: CGFloat) -> PopupLayout {
        if estimatedHeight(for: .regular) <= maxHeight {
            return .regular
        }

        if estimatedHeight(for: .compact) <= maxHeight {
            return .compact
        }

        return .tight
    }

    private func estimatedHeight(for layout: PopupLayout) -> CGFloat {
        let quickFactCount = min(parking.quickFacts.count, layout.quickFactLimit)
        let quickFactRows = quickFactCount == 0 ? 0 : (quickFactCount + 1) / 2
        let infoRowCount = min(parking.informationRows.count, layout.informationRowLimit)
        let hasCallout = layout.showsCallout && bestSummaryLine != nil
        let hasSecondaryActions = layout.showsSecondaryActions && (parking.website != nil || parking.sourceURL != nil)

        var height: CGFloat = 27
        height += layout.heroHeight
        height += layout.contentSpacing
        height += 29
        height += layout == .regular ? 12 : 8
        height += CGFloat(layout.titleLineLimit) * 25
        height += layout == .regular ? 12 : 8
        height += CGFloat(layout.addressLineLimit) * 21

        if quickFactRows > 0 {
            height += layout.contentSpacing
            height += CGFloat(quickFactRows) * 56
            height += CGFloat(max(0, quickFactRows - 1)) * 8
        }

        if hasCallout {
            height += layout.contentSpacing
            height += CGFloat(layout.calloutLineLimit) * 22 + 20
        }

        if infoRowCount > 0 {
            height += layout.contentSpacing
            height += 14
            height += CGFloat(infoRowCount) * (layout.infoValueLineLimit == 1 ? 50 : 62)
            height += CGFloat(infoRowCount) * 8
        }

        height += layout.contentSpacing
        height += 48
        if hasSecondaryActions {
            height += 58
        }

        height += layout.bottomPadding
        height += 4
        return height
    }

    private func popupBody(layout: PopupLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.contentSpacing) {
            ZStack(alignment: .topTrailing) {
                ParkingHeroPreview(parking: parking, height: layout.heroHeight)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.black.opacity(0.34), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(layout == .tight ? 8 : 10)
            }

            popupContent(layout: layout)
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.bottom, layout.bottomPadding)
    }

    private func popupContent(layout: PopupLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.contentSpacing) {
            headerSection(layout: layout)

            if !parking.quickFacts.isEmpty {
                ParkingQuickFactsSummary(facts: Array(parking.quickFacts.prefix(layout.quickFactLimit)))
            }

            if layout.showsCallout, let summaryLine = bestSummaryLine {
                ParkingDetailCallout(text: summaryLine, lineLimit: layout.calloutLineLimit)
            }

            if !parking.informationRows.isEmpty {
                detailsSection(layout: layout)
            }

            actionButtons(layout: layout)
        }
        .padding(.vertical, 2)
    }

    private func headerSection(layout: PopupLayout) -> some View {
        VStack(alignment: .leading, spacing: layout == .regular ? 12 : 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    detailBadges
                }

                VStack(alignment: .leading, spacing: 8) {
                    detailBadges
                }
            }

            Text(parking.titleDisplay)
                .font(.system(size: layout.titleSize, weight: .black, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(layout.titleLineLimit)
                .minimumScaleFactor(0.8)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(parking.markerTintColor)
                    .frame(width: 22, height: 22)

                Text(parking.addressDisplay)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(layout.addressLineLimit)
                    .minimumScaleFactor(0.82)
            }
        }
    }

    @ViewBuilder
    private var detailBadges: some View {
        DetailBadge(
            title: parking.primaryTypeDisplay,
            tint: parking.markerTintColor,
            systemImage: parking.primaryTypeSystemImage
        )

        if parking.pricing != .unknown {
            DetailBadge(
                title: parking.pricing.displayName,
                tint: parking.pricing.tintColor,
                systemImage: parking.pricing.systemImage
            )
        }
    }

    private func detailsSection(layout: PopupLayout) -> some View {
        let rows = Array(parking.informationRows.prefix(layout.informationRowLimit))

        return VStack(alignment: .leading, spacing: 8) {
            Text("map.detail.about".psLocalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                ParkingInfoRow(row: row, valueLineLimit: layout.infoValueLineLimit)
            }
        }
    }

    private func actionButtons(layout: PopupLayout) -> some View {
        VStack(spacing: 10) {
            Button {
                openDirections(to: parking)
            } label: {
                Label(
                    "map.directions".psLocalized,
                    systemImage: "arrow.triangle.turn.up.right.diamond.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ParkingActionButtonStyle(tint: .blue, isPrimary: true))

            if layout.showsSecondaryActions, parking.website != nil || parking.sourceURL != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        secondaryActionButtons
                    }

                    VStack(spacing: 10) {
                        secondaryActionButtons
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var secondaryActionButtons: some View {
        if let website = parking.website {
            Button {
                openInApp(website)
            } label: {
                Label(
                    "map.detail.website".psLocalized,
                    systemImage: "safari.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ParkingActionButtonStyle(tint: .secondary))
        }

        if let sourceURL = parking.sourceURL {
            Button {
                openInApp(sourceURL)
            } label: {
                Label("OpenStreetMap", systemImage: "map.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ParkingActionButtonStyle(tint: .indigo))
        }
    }

    private var bestSummaryLine: String? {
        let parts = [
            parking.operatorName,
            parking.openingHours,
            parking.capacity.map { "\($0) pl." },
        ]
        .compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        .prefix(2)

        let summary = parts.joined(separator: " · ")
        return summary.isEmpty ? nil : summary
    }

    private func openDirections(to parking: ParkingMapSpot) {
        guard parking.coordinate.isValidGeoCoordinate else { return }
        let destination = MKMapItem(
            placemark: MKPlacemark(coordinate: parking.coordinate.coordinate2D)
        )
        destination.name = parking.titleDisplay
        MKMapItem.openMaps(
            with: [destination],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
        )
    }

    private func openInApp(_ url: URL?) {
        guard let url else { return }
        inAppLink = ParkingInAppLink(url: url)
    }
}

private struct ParkingHeroPreview: View {
    let parking: ParkingMapSpot
    var height: CGFloat = 126
    @State private var lookAroundScene: MKLookAroundScene?
    @State private var remoteImage: UIImage?
    @State private var isLoadingRemoteImage = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let remoteImage {
                    Image(uiImage: remoteImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    fallbackPreview
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.36)],
                startPoint: .center,
                endPoint: .bottom
            )

            if isLoadingRemoteImage {
                ProgressView()
                    .tint(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.28), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(height: min(height, UIScreen.main.bounds.height * 0.22))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: "\(parking.id)-\(parking.officialImageURL?.absoluteString ?? "lookaround")") {
            await loadHeroVisual()
        }
    }

    @ViewBuilder
    private var fallbackPreview: some View {
        if #available(iOS 17.0, *), let lookAroundScene {
            LookAroundPreview(initialScene: lookAroundScene)
        } else {
            placeholderView
        }
    }

    private func loadHeroVisual() async {
        await MainActor.run {
            remoteImage = nil
            lookAroundScene = nil
            isLoadingRemoteImage = parking.officialImageURL != nil
        }

        if let url = parking.officialImageURL,
            let image = await Self.forceLoadImage(from: url)
        {
            await MainActor.run {
                remoteImage = image
                isLoadingRemoteImage = false
            }
            return
        }

        await MainActor.run {
            isLoadingRemoteImage = false
        }
        await renderPreview()
    }

    private static func forceLoadImage(from url: URL) async -> UIImage? {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 12
        )
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("ParkSpot/1.0 (iOS parking image preview)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let httpResponse = response as? HTTPURLResponse,
            200..<300 ~= httpResponse.statusCode,
            let image = UIImage(data: data)
        else {
            return nil
        }

        return image
    }

    private func renderPreview() async {
        let center = parking.coordinate.coordinate2D

        if #available(iOS 17.0, *) {
            let request = MKLookAroundSceneRequest(coordinate: center)
            if let scene = try? await request.scene {
                await MainActor.run {
                    self.lookAroundScene = scene
                }
                return
            }
        }

        await MainActor.run {
            self.lookAroundScene = nil
        }
    }

    @ViewBuilder
    private var placeholderView: some View {
        LinearGradient(
            colors: [
                parking.markerTintColor.opacity(0.92),
                Color.black.opacity(0.55),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: parking.primaryTypeSystemImage)
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}

private struct ParkingInAppLink: Identifiable {
    let url: URL

    var id: String { url.absoluteString }
}

private struct ParkingSafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = .systemBlue
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct ParkingMapControlButton: View {
    let icon: String
    let accessibilityLabel: String
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
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ParkingMapModeControlButton: View {
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
        .buttonStyle(.plain)
        .accessibilityLabel(
            (is3DEnabled ? "Basculer en 2D" : "Basculer en 3D").psLocalized
        )
    }
}

private struct SourceLegendChip: View {
    let source: ParkingDataSource

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: source.systemImage)
            Text(source.displayName)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(source.tintColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(source.tintColor.opacity(0.12), in: Capsule())
    }
}

private struct FilterPillView: View {
    let pill: FilterPill

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: pill.systemImage)
            Text(pill.title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct DetailBadge: View {
    let title: String
    let tint: Color
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title.psLocalized)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct ParkingQuickFactsSummary: View {
    let facts: [ParkingQuickFact]

    var body: some View {
        if !facts.isEmpty {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 142), spacing: 8),
                ],
                spacing: 8
            ) {
                ForEach(facts) { fact in
                    ParkingQuickFactLabel(fact: fact)
                }
            }
        }
    }
}

private struct ParkingQuickFactLabel: View {
    let fact: ParkingQuickFact

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: fact.systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(fact.tint)
                .frame(width: 28, height: 28)
                .background(fact.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(fact.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(fact.value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ParkingQuickFact: Identifiable {
    let id: String
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
}

private struct ParkingDetailCallout: View {
    let text: String
    var lineLimit: Int = 2

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 24)

            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .minimumScaleFactor(0.82)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ParkingInfoRow: View {
    let row: ParkingInfoItem
    var valueLineLimit: Int = 2

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 30, height: 30)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(row.value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(valueLineLimit)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ParkingActionButtonStyle: ButtonStyle {
    let tint: Color
    var isPrimary: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isPrimary ? .white : tint)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(
                isPrimary
                    ? AnyShapeStyle(tint.opacity(configuration.isPressed ? 0.85 : 1))
                    : AnyShapeStyle(.regularMaterial),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isPrimary
                            ? Color.clear : tint.opacity(configuration.isPressed ? 0.3 : 0.18),
                        lineWidth: 1
                    )
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct FilterPill: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
}

private struct ParkingMapFilters: Equatable {
    var type: ParkingTypeFilter = .all
    var pricing: ParkingPricingFilter = .all
    var radius: ParkingRadiusOption = .oneKilometer
}

private struct ParkingMapSpot: Identifiable, Hashable {
    let id: String
    let source: ParkingDataSource
    let coordinate: Coordinate
    let title: String
    let address: String?
    let facilityKind: ParkingFacilityKind
    let accessLevel: ParkingAccessLevel
    let pricing: ParkingPricing
    let operatorName: String?
    let capacity: String?
    let openingHours: String?
    let maxStay: String?
    let phoneNumber: String?
    let website: URL?
    let sourceURL: URL?
    let officialImageURL: URL?
    let levels: String?
    let accessDescription: String?
    var distanceMeters: Double?

    var titleDisplay: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "map.detail.default_title".psLocalized : trimmed
    }

    var hasDisplayableAddress: Bool {
        normalizedAddress != nil
    }

    var needsOSMEnrichment: Bool {
        source == .overpass
            && (normalizedAddress == nil
                || operatorName == nil
                || capacity == nil
                || openingHours == nil
                || maxStay == nil
                || phoneNumber == nil
                || website == nil
                || officialImageURL == nil
                || levels == nil)
    }

    var addressDisplay: String {
        normalizedAddress ?? "map.detail.no_address".psLocalized
    }

    var displayableAddress: String? {
        normalizedAddress
    }

    private var normalizedAddress: String? {
        guard let address else { return nil }

        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return trimmed
    }

    var primaryTypeDisplay: String {
        if facilityKind != .other {
            return facilityKind.displayName
        }

        switch accessLevel {
        case .publicAccess:
            return "map.type.public".psLocalized
        case .privateAccess:
            return "map.type.private".psLocalized
        case .restricted:
            return accessDescription ?? "map.access.unknown".psLocalized
        case .unknown:
            return "map.type.other".psLocalized
        }
    }

    var primaryTypeSystemImage: String {
        if facilityKind != .other {
            switch facilityKind {
            case .surface:
                return "parkingsign.circle.fill"
            case .underground:
                return "arrow.down.circle.fill"
            case .covered:
                return "building.2.fill"
            case .other:
                return facilityKind.systemImage
            }
        }

        switch accessLevel {
        case .publicAccess:
            return "parkingsign.circle.fill"
        case .privateAccess:
            return "lock.circle.fill"
        case .restricted:
            return "exclamationmark.shield.fill"
        case .unknown:
            return "parkingsign.circle"
        }
    }

    var directionsURL: URL? {
        URL(string: "https://maps.apple.com/?daddr=\(coordinate.latitude),\(coordinate.longitude)&dirflg=w")
    }

    var lookAroundURL: URL? {
        URL(string: "https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)")
    }

    var distanceLabel: String {
        guard let distanceMeters else { return "--" }
        if distanceMeters >= 1_000 {
            return String.localizedStringWithFormat(
                "map.distance_km_format".psLocalized,
                distanceMeters / 1_000
            )
        }
        return String.localizedStringWithFormat(
            "map.distance_m_format".psLocalized,
            distanceMeters
        )
    }

    var markerSystemImage: String {
        if facilityKind != .other {
            switch facilityKind {
            case .surface:
                return "parkingsign.circle.fill"
            case .underground:
                return "arrow.down.circle.fill"
            case .covered:
                return "building.2.fill"
            case .other:
                return facilityKind.systemImage
            }
        }

        switch accessLevel {
        case .publicAccess:
            return "parkingsign.circle.fill"
        case .privateAccess:
            return "lock.circle.fill"
        case .restricted:
            return "exclamationmark.shield.fill"
        case .unknown:
            return "parkingsign.circle"
        }
    }

    var markerTintColor: Color {
        switch pricing {
        case .free:
            return .green
        case .paid:
            return .orange
        case .unknown:
            return .gray
        }
    }

    var markerTintUIColor: UIColor {
        UIColor(markerTintColor)
    }

    var quickFacts: [ParkingQuickFact] {
        var facts: [ParkingQuickFact] = [
            ParkingQuickFact(
                id: "distance",
                title: "map.detail.distance".psLocalized,
                value: distanceLabel,
                systemImage: "figure.walk",
                tint: .blue
            )
        ]

        if let capacity, !capacity.isEmpty {
            facts.append(
                ParkingQuickFact(
                    id: "capacity",
                    title: "map.detail.capacity".psLocalized,
                    value: capacity,
                    systemImage: "car.2.fill",
                    tint: .indigo
                )
            )
        } else if pricing != .unknown {
            facts.append(
                ParkingQuickFact(
                    id: "price",
                    title: "map.detail.price".psLocalized,
                    value: pricing.displayName,
                    systemImage: pricing.systemImage,
                    tint: pricing.tintColor
                )
            )
        }

        return facts
    }

    var informationRows: [ParkingInfoItem] {
        var rows: [ParkingInfoItem] = []

        if let operatorName, !operatorName.isEmpty {
            rows.append(
                ParkingInfoItem(
                    title: "map.detail.operator".psLocalized,
                    value: operatorName,
                    systemImage: "building.2.fill"
                )
            )
        }

        if let capacity, !capacity.isEmpty {
            rows.append(
                ParkingInfoItem(
                    title: "map.detail.capacity".psLocalized,
                    value: capacity,
                    systemImage: "car.2.fill"
                )
            )
        }

        if let openingHours, !openingHours.isEmpty {
            rows.append(
                ParkingInfoItem(
                    title: "map.detail.hours".psLocalized,
                    value: openingHours,
                    systemImage: "clock.fill"
                )
            )
        }

        if let maxStay, !maxStay.isEmpty {
            rows.append(
                ParkingInfoItem(
                    title: "map.detail.maxstay".psLocalized,
                    value: maxStay,
                    systemImage: "timer"
                )
            )
        }

        if let levels, !levels.isEmpty {
            rows.append(
                ParkingInfoItem(
                    title: "map.detail.levels".psLocalized,
                    value: levels,
                    systemImage: "square.3.layers.3d.top.filled"
                )
            )
        }

        if let accessDescription, !accessDescription.isEmpty {
            rows.append(
                ParkingInfoItem(
                    title: "map.detail.access".psLocalized,
                    value: accessDescription,
                    systemImage: "person.text.rectangle"
                )
            )
        }

        if let phoneNumber, !phoneNumber.isEmpty {
            rows.append(
                ParkingInfoItem(
                    title: "map.detail.phone".psLocalized,
                    value: phoneNumber,
                    systemImage: "phone.fill"
                )
            )
        }

        return rows
    }

    func withDistance(from reference: Coordinate) -> ParkingMapSpot {
        var copy = self
        copy.distanceMeters = distanceBetween(reference, coordinate)
        return copy
    }

    func withResolvedAddress(_ address: String) -> ParkingMapSpot {
        ParkingMapSpot(
            id: id,
            source: source,
            coordinate: coordinate,
            title: title,
            address: address,
            facilityKind: facilityKind,
            accessLevel: accessLevel,
            pricing: pricing,
            operatorName: operatorName,
            capacity: capacity,
            openingHours: openingHours,
            maxStay: maxStay,
            phoneNumber: phoneNumber,
            website: website,
            sourceURL: sourceURL,
            officialImageURL: officialImageURL,
            levels: levels,
            accessDescription: accessDescription,
            distanceMeters: distanceMeters
        )
    }

    func withResolvedOSMDetails(_ details: OSMResolvedParkingDetails) -> ParkingMapSpot {
        ParkingMapSpot(
            id: id,
            source: source,
            coordinate: coordinate,
            title: title,
            address: details.address ?? address,
            facilityKind: facilityKind,
            accessLevel: accessLevel,
            pricing: pricing,
            operatorName: details.operatorName ?? operatorName,
            capacity: details.capacity ?? capacity,
            openingHours: details.openingHours ?? openingHours,
            maxStay: details.maxStay ?? maxStay,
            phoneNumber: details.phoneNumber ?? phoneNumber,
            website: details.website ?? website,
            sourceURL: sourceURL,
            officialImageURL: details.officialImageURL ?? officialImageURL,
            levels: details.levels ?? levels,
            accessDescription: details.accessDescription ?? accessDescription,
            distanceMeters: distanceMeters
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ParkingMapSpot, rhs: ParkingMapSpot) -> Bool {
        lhs.id == rhs.id
    }
}

private struct ParkingInfoItem: Hashable {
    let title: String
    let value: String
    let systemImage: String
}

private enum ParkingDataSource: String, Hashable {
    case apple
    case overpass

    var displayName: String {
        switch self {
        case .apple:
            return "map.source.apple".psLocalized
        case .overpass:
            return "map.source.overpass".psLocalized
        }
    }

    var systemImage: String {
        switch self {
        case .apple:
            return "apple.logo"
        case .overpass:
            return "globe.europe.africa.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .apple:
            return .blue
        case .overpass:
            return .green
        }
    }

    var tintUIColor: UIColor {
        switch self {
        case .apple:
            return .systemBlue
        case .overpass:
            return .systemGreen
        }
    }

    var sortOrder: Int {
        switch self {
        case .apple:
            return 0
        case .overpass:
            return 1
        }
    }
}

private enum ParkingFacilityKind: String, Hashable {
    case surface
    case underground
    case covered
    case other

    var displayName: String {
        switch self {
        case .surface:
            return "map.type.surface".psLocalized
        case .underground:
            return "map.type.underground".psLocalized
        case .covered:
            return "map.type.covered".psLocalized
        case .other:
            return "map.type.other".psLocalized
        }
    }

    var systemImage: String {
        switch self {
        case .surface:
            return "sun.max.fill"
        case .underground:
            return "arrow.down.to.line.compact"
        case .covered:
            return "building.2.crop.circle"
        case .other:
            return "parkingsign"
        }
    }
}

private enum ParkingAccessLevel: Hashable {
    case publicAccess
    case privateAccess
    case restricted
    case unknown
}

private enum ParkingPricing: Hashable {
    case free
    case paid
    case unknown

    var displayName: String {
        switch self {
        case .free:
            return "map.price_free".psLocalized
        case .paid:
            return "map.price_paid".psLocalized
        case .unknown:
            return "map.tariff_unknown".psLocalized
        }
    }

    var tintColor: Color {
        switch self {
        case .free:
            return .green
        case .paid:
            return .orange
        case .unknown:
            return .gray
        }
    }

    var systemImage: String {
        switch self {
        case .free:
            return "eurosign.circle.fill"
        case .paid:
            return "creditcard.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
}

private enum ParkingTypeFilter: String, CaseIterable, Identifiable {
    case all
    case surface
    case underground
    case covered
    case publicParking
    case other

    static let allCases: [ParkingTypeFilter] = [
        .all,
        .surface,
        .underground,
        .covered,
        .publicParking,
        .other,
    ]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "map.type.all".psLocalized
        case .surface:
            return "map.type.surface".psLocalized
        case .underground:
            return "map.type.underground".psLocalized
        case .covered:
            return "map.type.covered".psLocalized
        case .publicParking:
            return "map.type.public".psLocalized
        case .other:
            return "map.type.other".psLocalized
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "line.3.horizontal.decrease.circle"
        case .surface:
            return "sun.max.fill"
        case .underground:
            return "arrow.down.to.line.compact"
        case .covered:
            return "building.2.fill"
        case .publicParking:
            return "person.3.fill"
        case .other:
            return "parkingsign"
        }
    }

    func matches(_ parking: ParkingMapSpot) -> Bool {
        switch self {
        case .all:
            return true
        case .surface:
            return parking.facilityKind == .surface
        case .underground:
            return parking.facilityKind == .underground
        case .covered:
            return parking.facilityKind == .covered
        case .publicParking:
            return parking.accessLevel == .publicAccess
        case .other:
            return parking.facilityKind == .other && parking.accessLevel == .unknown
        }
    }
}

private enum ParkingPricingFilter: String, CaseIterable, Identifiable {
    case all
    case free
    case paid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "map.pricing.all".psLocalized
        case .free:
            return "map.pricing.free".psLocalized
        case .paid:
            return "map.pricing.paid".psLocalized
        }
    }

    func matches(_ pricing: ParkingPricing) -> Bool {
        switch self {
        case .all:
            return true
        case .free:
            return pricing == .free
        case .paid:
            return pricing == .paid
        }
    }
}

private enum ParkingRadiusOption: Double, CaseIterable, Identifiable {
    case fiveHundredMeters = 500
    case oneKilometer = 1_000
    case threeKilometers = 3_000
    case fiveKilometers = 5_000
    case tenKilometers = 10_000

    var id: Double { rawValue }
    var meters: Double { rawValue }

    var title: String {
        if meters >= 1_000 {
            return "\(Int(meters / 1_000)) km"
        }
        return "\(Int(meters)) m"
    }
}

private struct ParkingQuerySignature: Equatable {
    let center: Coordinate
    let radiusMeters: Double
}

private final class ParkingExplorerAnnotation: NSObject, MKAnnotation {
    enum Kind: Hashable {
        case user
        case parking
    }

    static let userIdentifier = "__parking_user__"

    let id: String
    let kind: Kind
    @objc dynamic var coordinate: CLLocationCoordinate2D
    dynamic var title: String?
    dynamic var subtitle: String?
    var parking: ParkingMapSpot?

    init(parking: ParkingMapSpot) {
        self.id = parking.id
        self.kind = .parking
        self.coordinate = parking.coordinate.coordinate2D
        self.title = parking.titleDisplay
        self.subtitle = parking.address
        self.parking = parking
    }

    private init(userCoordinate: CLLocationCoordinate2D) {
        self.id = Self.userIdentifier
        self.kind = .user
        self.coordinate = userCoordinate
        self.title = "map.my_position".psLocalized
        self.subtitle = nil
        self.parking = nil
    }

    static func user(coordinate: CLLocationCoordinate2D) -> ParkingExplorerAnnotation {
        ParkingExplorerAnnotation(userCoordinate: coordinate)
    }
}

private struct ParkingDiscoveryService {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration)
    }()

    func fetchParkings(in region: MKCoordinateRegion) async throws -> [ParkingMapSpot] {
        async let appleResults = fetchAppleParkings(in: region)
        async let overpassResults = fetchOverpassParkings(in: region)

        var combined: [ParkingMapSpot] = []
        var firstError: Error?

        do {
            combined += try await appleResults
        } catch {
            firstError = error
        }

        do {
            combined += try await overpassResults
        } catch {
            firstError = firstError ?? error
        }

        let deduplicated = deduplicate(parkings: combined)

        if deduplicated.isEmpty, let firstError {
            throw firstError
        }

        return deduplicated
    }

    private func fetchAppleParkings(in region: MKCoordinateRegion) async throws -> [ParkingMapSpot]
    {
        let request = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.parking])

        let response = try await MKLocalSearch(request: request).start()

        return response.mapItems.compactMap { item in
            guard let name = item.name ?? formattedAddress(for: item.placemark) else { return nil }
            guard shouldIncludeAppleParking(item: item, resolvedName: name) else { return nil }

            let address = formattedAddress(for: item.placemark)
            let kind = inferAppleFacilityKind(name: name, address: address)

            let coordinate = Coordinate(
                latitude: item.placemark.coordinate.latitude,
                longitude: item.placemark.coordinate.longitude
            )

            return ParkingMapSpot(
                id:
                    "apple-\(coordinate.latitude.formattedID)-\(coordinate.longitude.formattedID)-\(name.normalizedIdentifier)",
                source: .apple,
                coordinate: coordinate,
                title: name,
                address: address,
                facilityKind: kind,
                accessLevel: .publicAccess,
                pricing: .unknown,
                operatorName: nil,
                capacity: nil,
                openingHours: nil,
                maxStay: nil,
                phoneNumber: item.phoneNumber,
                website: item.url,
                sourceURL: nil,
                officialImageURL: nil,
                levels: nil,
                accessDescription: "map.type.public".psLocalized,
                distanceMeters: nil
            )
        }
    }

    private func fetchOverpassParkings(in region: MKCoordinateRegion) async throws
        -> [ParkingMapSpot]
    {
        guard let request = overpassRequest(for: region) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)

        return decoded.elements.compactMap { element in
            guard let coordinate = element.coordinate else { return nil }

            let tags = element.tags ?? [:]
            guard shouldIncludeOSMParking(tags: tags) else { return nil }
            let title = resolvedOSMTitle(from: tags)
            let accessLevel = resolvedAccessLevel(from: tags["access"])
            let accessDescription = resolvedAccessDescription(from: tags["access"])

            return ParkingMapSpot(
                id: "osm-\(element.type)-\(element.id)",
                source: .overpass,
                coordinate: Coordinate(latitude: coordinate.lat, longitude: coordinate.lon),
                title: title,
                address: formattedAddress(from: tags),
                facilityKind: resolvedFacilityKind(from: tags),
                accessLevel: accessLevel,
                pricing: resolvedPricing(from: tags["fee"]),
                operatorName: firstNonEmpty(
                    tags["operator"],
                    tags["brand"]
                ),
                capacity: tags["capacity"],
                openingHours: tags["opening_hours"],
                maxStay: firstNonEmpty(tags["maxstay"], tags["maxstay:conditional"]),
                phoneNumber: firstNonEmpty(tags["phone"], tags["contact:phone"]),
                website: normalizedURL(
                    from: firstNonEmpty(tags["website"], tags["contact:website"], tags["url"])),
                sourceURL: URL(
                    string: "https://www.openstreetmap.org/\(element.type)/\(element.id)"),
                officialImageURL: resolvedOfficialImageURL(from: tags),
                levels: firstNonEmpty(tags["levels"], tags["level"]),
                accessDescription: accessDescription,
                distanceMeters: nil
            )
        }
    }

    private func deduplicate(parkings: [ParkingMapSpot]) -> [ParkingMapSpot] {
        var seen = Set<String>()
        return parkings.filter { parking in
            let key =
                "\(parking.source.rawValue)-\(parking.coordinate.latitude.formattedID)-\(parking.coordinate.longitude.formattedID)-\(parking.titleDisplay.normalizedIdentifier)"
            return seen.insert(key).inserted
        }
    }

    private func overpassRequest(for region: MKCoordinateRegion) -> URLRequest? {
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return nil }

        let north = region.center.latitude + region.span.latitudeDelta / 2
        let south = region.center.latitude - region.span.latitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2
        let west = region.center.longitude - region.span.longitudeDelta / 2

        let query = """
            [out:json][timeout:25];
            (
              nwr["amenity"="parking"]["parking"!~"^(street_side|lane|layby)$"](\(south),\(west),\(north),\(east));
            );
            out center tags;
            """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = query.data(using: .utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ParkSpot/1.0 (iOS parking discovery)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func formattedAddress(for placemark: MKPlacemark) -> String? {
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")

        let locality = [placemark.postalCode, placemark.locality]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")

        let lines = [street, locality].filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: ", ")
    }

    private func inferAppleFacilityKind(name: String, address: String?) -> ParkingFacilityKind {
        let text = [name, address]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if text.contains("underground") || text.contains("souterrain") {
            return .underground
        }

        if text.contains("garage") || text.contains("covered") || text.contains("couvert") {
            return .covered
        }

        return .surface
    }

    private func shouldIncludeAppleParking(item: MKMapItem, resolvedName: String) -> Bool {
        let searchable = normalizedSearchText(
            resolvedName,
            formattedAddress(for: item.placemark),
            item.placemark.title
        )

        let excludedPhrases = [
            "parking space",
            "parking spot",
            "car space",
            "place de parking",
            "emplacement de parking",
            "emplacement",
            "stationnement minute",
            "drop off",
            "pickup only",
        ]

        return !excludedPhrases.contains(where: searchable.contains)
    }

    private func resolvedOSMTitle(from tags: [String: String]) -> String {
        firstNonEmpty(tags["name"], tags["operator"], tags["brand"])
            ?? "map.detail.default_title".psLocalized
    }

    private func shouldIncludeOSMParking(tags: [String: String]) -> Bool {
        if tags["amenity"]?.lowercased() == "parking_space" {
            return false
        }

        let parkingKind = tags["parking"]?.lowercased()
        if ["street_side", "lane", "layby"].contains(parkingKind) {
            return false
        }

        let searchable = normalizedSearchText(
            tags["name"],
            tags["description"],
            tags["operator"]
        )

        let excludedPhrases = [
            "parking space",
            "parking spot",
            "car space",
            "place de parking",
            "emplacement de parking",
            "emplacement",
        ]

        return !excludedPhrases.contains(where: searchable.contains)
    }

    private func resolvedFacilityKind(from tags: [String: String]) -> ParkingFacilityKind {
        let parkingValue = tags["parking"]?.lowercased()
        let covered = tags["covered"]?.lowercased()

        if parkingValue == "underground" {
            return .underground
        }

        if covered == "yes"
            || parkingValue == "multi-storey"
            || parkingValue == "garage_boxes"
            || parkingValue == "rooftop"
        {
            return .covered
        }

        if parkingValue == "surface"
            || parkingValue == "open_air"
            || parkingValue == nil
        {
            return .surface
        }

        return .other
    }

    private func resolvedAccessLevel(from rawValue: String?) -> ParkingAccessLevel {
        guard let rawValue = rawValue?.lowercased() else { return .unknown }

        switch rawValue {
        case "yes", "public", "permissive":
            return .publicAccess
        case "private":
            return .privateAccess
        case "customers", "permit", "residents", "delivery", "destination", "no":
            return .restricted
        default:
            return .unknown
        }
    }

    private func resolvedAccessDescription(from rawValue: String?) -> String? {
        guard let rawValue = rawValue?.lowercased(), !rawValue.isEmpty else { return nil }

        switch rawValue {
        case "yes", "public", "permissive":
            return "map.type.public".psLocalized
        case "private":
            return "map.type.private".psLocalized
        case "customers":
            return "Customers".psLocalized
        case "residents":
            return "Residents".psLocalized
        case "permit":
            return "Permit".psLocalized
        case "delivery":
            return "Delivery only".psLocalized
        case "destination":
            return "Destination traffic".psLocalized
        case "no":
            return "Restricted".psLocalized
        default:
            return rawValue.capitalized
        }
    }

    private func resolvedPricing(from rawValue: String?) -> ParkingPricing {
        guard let rawValue = rawValue?.lowercased() else { return .unknown }

        switch rawValue {
        case "yes", "true", "1":
            return .paid
        case "no", "false", "0":
            return .free
        default:
            return .unknown
        }
    }

    private func formattedAddress(from tags: [String: String]) -> String? {
        // Try structured address first
        let street = [tags["addr:housenumber"], tags["addr:street"]]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")

            let locality = [tags["addr:postcode"], tags["addr:city"]]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")

            let parts = [street, locality].filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func normalizedURL(from rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else {
            return nil
        }

        if let url = URL(string: rawValue), url.scheme != nil {
            return url
        }

        return URL(string: "https://\(rawValue)")
    }

    private func resolvedOfficialImageURL(from tags: [String: String]) -> URL? {
        let candidates = [
            tags["image"],
            tags["image:0"],
            tags["image:1"],
            tags["contact:image"],
            tags["photo"],
            tags["wikimedia_commons"],
            tags["wikimedia:commons"]
        ]

        for candidate in candidates {
            if let imageURL = resolvedParkingImageURL(from: candidate) {
                return imageURL
            }
        }

        return nil
    }

    private func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func normalizedSearchText(_ candidates: String?...) -> String {
        candidates
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }
}

private struct OverpassResponse: Decodable {
    let elements: [OverpassElement]
}

private struct OverpassElement: Decodable {
    let type: String
    let id: Int64
    let lat: Double?
    let lon: Double?
    let center: OverpassCenter?
    let tags: [String: String]?

    var coordinate: OverpassCenter? {
        if let lat, let lon {
            return OverpassCenter(lat: lat, lon: lon)
        }
        return center
    }
}

private struct OverpassCenter: Decodable {
    let lat: Double
    let lon: Double
}

private func resolvedParkingImageURL(from rawValue: String?) -> URL? {
    guard let rawValue else { return nil }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let fileName = wikimediaCommonsFileName(from: trimmed) {
        return wikimediaCommonsFileURL(for: fileName)
    }

    guard let url = URL(string: trimmed),
        let scheme = url.scheme?.lowercased(),
        ["http", "https"].contains(scheme)
    else {
        return nil
    }

    if let fileName = wikimediaCommonsFileName(from: url) {
        return wikimediaCommonsFileURL(for: fileName)
    }

    // OSM image tags often point to redirected image endpoints without a file extension.
    // The hero preview validates the payload by decoding it as UIImage, so keep the URL.
    return url
}

private func wikimediaCommonsFileName(from rawValue: String) -> String? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = trimmed.lowercased()

    if lowercased.hasPrefix("file:") {
        return trimmed.dropFirst("file:".count).trimmedNonEmptyString
    }

    if lowercased.hasPrefix("image:") {
        return trimmed.dropFirst("image:".count).trimmedNonEmptyString
    }

    if let url = URL(string: trimmed) {
        return wikimediaCommonsFileName(from: url)
    }

    return nil
}

private func wikimediaCommonsFileName(from url: URL) -> String? {
    guard url.host?.localizedCaseInsensitiveContains("commons.wikimedia.org") == true else {
        return nil
    }

    let decodedPath = url.path.removingPercentEncoding ?? url.path
    guard let range = decodedPath.range(of: "/wiki/File:", options: [.caseInsensitive]) else {
        return nil
    }

    return String(decodedPath[range.upperBound...])
        .replacingOccurrences(of: "_", with: " ")
        .trimmedNonEmptyString
}

private func wikimediaCommonsCategoryName(from rawValue: String?) -> String? {
    guard let rawValue else { return nil }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.lowercased().hasPrefix("category:") {
        let name = String(trimmed.dropFirst("category:".count))
            .replacingOccurrences(of: "_", with: " ")
            .trimmedNonEmptyString
        return name.map { "Category:\($0)" }
    }

    if let url = URL(string: trimmed) {
        return wikimediaCommonsCategoryName(from: url)
    }

    return nil
}

private func wikimediaCommonsCategoryName(from url: URL) -> String? {
    guard url.host?.localizedCaseInsensitiveContains("commons.wikimedia.org") == true else {
        return nil
    }

    let decodedPath = url.path.removingPercentEncoding ?? url.path
    guard let range = decodedPath.range(of: "/wiki/Category:", options: [.caseInsensitive]) else {
        return nil
    }

    let name = String(decodedPath[range.upperBound...])
        .replacingOccurrences(of: "_", with: " ")
        .trimmedNonEmptyString
    return name.map { "Category:\($0)" }
}

private func wikimediaCommonsFileURL(for fileName: String) -> URL? {
    let normalized = fileName
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "_")
    guard !normalized.isEmpty else { return nil }

    var allowedCharacters = CharacterSet.urlPathAllowed
    allowedCharacters.remove(charactersIn: "#?")
    guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: allowedCharacters)
    else {
        return nil
    }

    return URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)")
}

private func distanceBetween(_ lhs: Coordinate, _ rhs: Coordinate) -> Double {
    let start = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
    let end = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
    return start.distance(from: end)
}

extension Coordinate {
    fileprivate var coordinate2D: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension Double {
    fileprivate var formattedID: String {
        String(format: "%.5f", self)
    }
}

extension String {
    fileprivate var normalizedIdentifier: String {
        folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    }

    fileprivate var trimmedNonEmptyString: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Substring {
    fileprivate var trimmedNonEmptyString: String? {
        String(self).trimmedNonEmptyString
    }
}

extension URL {
    fileprivate var hasDisplayableImagePathExtension: Bool {
        let supportedExtensions = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif"]
        return supportedExtensions.contains(pathExtension.lowercased())
    }
}
