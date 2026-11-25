// HomeViewModel.swift
import Foundation
import Combine
import CoreLocation
@preconcurrency import WatchConnectivity
@preconcurrency import UserNotifications

enum HomeLocalizationMode: String, CaseIterable, Identifiable {
    case gps
    case map
    case bluetooth
    case sensorTracker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gps: return "home.mode.gps".psLocalized
        case .map: return "home.mode.map".psLocalized
        case .bluetooth: return "home.mode.bluetooth".psLocalized
        case .sensorTracker: return "home.mode.sensor_tracker".psLocalized
        }
    }

    var icon: String {
        switch self {
        case .gps: return "location"
        case .map: return "map"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .sensorTracker: return "gyroscope"
        }
    }

    var isUserSelectable: Bool {
        switch self {
        case .gps, .map:
            return true
        case .bluetooth, .sensorTracker:
            return false
        }
    }
}

enum AlternativeSystemsPolicy: String, CaseIterable {
    case alwaysActive
    case batteryAware
    case disabled
}

@MainActor
private final class WatchParkingSyncBridge: NSObject, WCSessionDelegate {
    static let shared = WatchParkingSyncBridge()

    private var pendingContext: [String: Any]?

    func activateIfNeeded() {
        guard WCSession.isSupported() else {
            return
        }
        let session = WCSession.default
        if session.delegate == nil {
            session.delegate = self
        }
        if session.activationState == .notActivated {
            session.activate()
        } else if session.activationState == .activated {
            flushPendingContext(through: session)
        }
    }

    func send(_ context: [String: Any]) {
        guard WCSession.isSupported() else {
            return
        }
        let session = WCSession.default
        if session.delegate == nil {
            session.delegate = self
        }

        guard session.activationState == .activated else {
            pendingContext = context
            if session.activationState == .notActivated {
                session.activate()
            }
            return
        }

        guard canSend(to: session) else {
            pendingContext = context
            return
        }

        sendActivatedContext(context, through: session)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            self.flushPendingContext(through: session)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            session.activate()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.flushPendingContext(through: session)
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.flushPendingContext(through: session)
        }
    }

    private func flushPendingContext(through session: WCSession) {
        guard let pendingContext else { return }
        self.pendingContext = nil
        guard canSend(to: session) else { return }
        sendActivatedContext(pendingContext, through: session)
    }

    private func canSend(to session: WCSession) -> Bool {
        session.isPaired
    }

    private func sendActivatedContext(_ context: [String: Any], through session: WCSession) {
        do {
            try session.updateApplicationContext(context)
        } catch {
            session.transferUserInfo(context)
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {

    private static let guestSessionUserId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let autoParkingDetectionEnabledKey = "settings.autoParkingDetectionEnabled"
    private static let pendingAutoParkingDetectionDefaultsKey = "parkspot.autoParking.pendingDetection.v1"
    private static let pendingAutoParkingConfirmationDefaultsKey = "parkspot.autoParking.pendingConfirmation.v1"
    private static let fallbackLocationMaxAge: TimeInterval = 12 * 60 * 60

    struct SmartAwaySaveFormPrefill {
        let note: String
        let parkingLevel: String
        let zone: ParkingZone
        let maxDuration: TimeInterval?
    }

    private struct PersistedAutoParkingSnapshot: Codable {
        let latitude: Double
        let longitude: Double
        let confidence: Double
        let stationaryDuration: TimeInterval
        let clusterRadius: Double
        let triggerSource: String
        let detectedAt: Date

        init(snapshot: AutoParkingDetectionSnapshot) {
            latitude = snapshot.coordinate.latitude
            longitude = snapshot.coordinate.longitude
            confidence = snapshot.confidence
            stationaryDuration = snapshot.stationaryDuration
            clusterRadius = snapshot.clusterRadius
            triggerSource = snapshot.triggerSource
            detectedAt = snapshot.detectedAt
        }

        var snapshot: AutoParkingDetectionSnapshot {
            AutoParkingDetectionSnapshot(
                coordinate: Coordinate(latitude: latitude, longitude: longitude),
                confidence: confidence,
                stationaryDuration: stationaryDuration,
                clusterRadius: clusterRadius,
                triggerSource: triggerSource,
                detectedAt: detectedAt
            )
        }

        private enum CodingKeys: String, CodingKey {
            case latitude
            case longitude
            case confidence
            case stationaryDuration
            case clusterRadius
            case triggerSource
            case detectedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            latitude = try container.decode(Double.self, forKey: .latitude)
            longitude = try container.decode(Double.self, forKey: .longitude)
            confidence = try container.decode(Double.self, forKey: .confidence)
            stationaryDuration = try container.decode(TimeInterval.self, forKey: .stationaryDuration)
            clusterRadius = try container.decode(Double.self, forKey: .clusterRadius)
            triggerSource = try container.decode(String.self, forKey: .triggerSource)
            detectedAt = try container.decodeIfPresent(Date.self, forKey: .detectedAt) ?? .now
        }
    }

    @Published var activeSession: ParkingSession? {
        didSet {
            applyForegroundLocationModeIfUpdating()
        }
    }
    @Published var userCoordinate: Coordinate?
    @Published private(set) var mapUserCoordinate: Coordinate?
    @Published var userLocationAccuracy: Double?
    @Published var userHeading: CLHeading?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var showSaveSheet: Bool = false
    @Published var isLocationDenied: Bool = false
    @Published var locationAuthorizationStatus: LocationAuthStatus = .notDetermined
    @Published var locationAccuracyAuthorization: LocationAccuracyAuthorization = .unknown
    @Published var predictedDuration: TimeInterval?
    @Published var predictionConfidence: Double?
    @Published var predictionSampleCount: Int?
    @Published var predictionContextProfile: String?
    @Published var isPredictionAnomalous: Bool = false
    @Published var predictionConservativeDuration: TimeInterval?
    @Published var predictionAggressiveDuration: TimeInterval?
    @Published var predictionFreshnessDays: Int?
    @Published var predictionExplanation: String?
    @Published var frequentZoneNameSuggestion: String?
    @Published var calendarSuggestedDuration: TimeInterval?
    @Published var calendarSuggestedTitle: String?
    @Published var pendingAutoEndDeadline: Date?
    @Published private var forcedDurationForNextSave: TimeInterval?
    @Published var parkingRiskAssessment: ParkingRiskAssessment?
    @Published var lastCommunityRiskReportAt: Date?
    @Published var selectedLocalizationMode: HomeLocalizationMode = .gps
    @Published var alternativeSystemsPolicy: AlternativeSystemsPolicy = .alwaysActive
    @Published var pendingAutoParkingConfirmation: AutoParkingDetectionSnapshot?
    @Published private(set) var temporaryAutoParkingDetectionCoordinate: Coordinate?
    @Published private var pendingAutoParkingAddress: String?
    @Published var currentAddress: String?
    @Published var showSmartAwayInAppAlert: Bool = false
    @Published var smartAwayInAppAlertTitle: String?
    @Published var smartAwayInAppAlertBody: String?
    @Published var pendingCarPlayDisconnectPrompt: CarPlayDisconnectNotificationPayload?
    @Published var pendingCarPlayDisconnectDirectSave: Bool = false

    private let saveParkingUseCase:        SaveParkingUseCase
    private let endParkingUseCase:         EndParkingUseCase
    private let fetchActiveSessionUseCase: FetchActiveSessionUseCase
    private let fetchHistoryUseCase:       FetchHistoryUseCase
    private let photoStorage:              PhotoStorageProtocol
    private let locationService:           LocationServiceProtocol
    private let notificationService:       NotificationServiceProtocol
    private let liveActivityService:       LiveActivityService
    private let sharedParkingDataManager:  SharedParkingDataManager
    private let predictionService:         PredictionService
    private let frequentZoneService:       FrequentZoneService
    private let keychain:                  KeychainServiceProtocol
    private let reachability:              NetworkReachabilityMonitor
    private let providedCarBluetoothService: BluetoothMonitoringServiceProtocol?
    private let providedDepartureDetectionService: DepartureDetectionService?
    private let calendarService:           CalendarService
    private let riskZoneService:           RiskZoneService
    private var userId:                    UUID?
    private var didFinishInitialAuthRestore = false
    private var hasPremiumWidgetsAccess = false
    private var hasFrequentZonesAccess = false
    private var hasPremiumSmartDetectionAccess = false
    private var cancellables = Set<AnyCancellable>()
    private var autoEndTask: Task<Void, Never>?
    private var autoEndToken = UUID()
    private var forcedFrequentZoneForNextSave: FrequentZone?
    private var pendingSmartAwaySaveFormPrefill: SmartAwaySaveFormPrefill?
    private var pendingAutoParkingSaveCoordinate: Coordinate?
    private var isLocationUpdating = false
    private var isAppActive = true
    private var startupWarmupTask: Task<Void, Never>?
    private var autoParkingStartTask: Task<Void, Never>?
    private var didSetupDepartureDetection = false
    private var isAutoParkingMonitoringActive = false
    private var pendingAutoParkingNotificationDetection: AutoParkingDetectionSnapshot?
    private var isAutoParkingNotificationScheduling = false
    private var autoParkingWalkAwayStreak = 0
    private var lastAutoParkingWalkAwayDistance: Double?
    private var lastAutoParkingWalkAwayDetectionCoordinate: Coordinate?
    private var lastAcceptedLocationSample: LocationSample?
    private var lastMapLocationSample: LocationSample?
    private let autoParkingWalkAwayConfirmationPolicy = AutoParkingWalkAwayConfirmationPolicy()
    private var lastSmartAwayAlertAt: Date?
    private var lastSmartAwayRiskLevel: ForgetCarRiskLevel?
    private var lastSmartAwaySessionId: UUID?
    private var lastSmartAwayEvaluationAt: Date?
    private var lastSmartAwayEvaluationCoordinate: Coordinate?
    private var lastSmartAwayDistanceMeters: Double?
    private var lastWatchSyncedSessionId: UUID?
    private var lastWatchDistanceSyncAt: Date?
    private var lastWatchDistanceMeters: Double?
    private var isActiveSessionLoadInFlight = false
    private var shouldReloadActiveSessionAfterCurrentLoad = false
    private var lastFrequentZoneNotificationZoneId: UUID?
    private let isSmartAwayAlertEnabled: Bool = false
    private let smartAwayMaximumAcceptedAccuracyMeters: Double = 85
    private let smartAwayMinimumEvaluationInterval: TimeInterval = 12
    private let smartAwayMinimumEvaluationDistanceMeters: Double = 18
    private let frequentZoneNotificationMaximumAccuracyMeters: Double = 120
    @Published var debugAutoParkingStatus: String?
    @Published var debugSmartAwayStatus: String?
    private lazy var carBluetoothService: BluetoothMonitoringServiceProtocol =
        providedCarBluetoothService ?? DIContainer.shared.carBluetoothService
    private lazy var departureDetectionService: DepartureDetectionService =
        providedDepartureDetectionService ?? DIContainer.shared.departureDetectionService
    private var autoParkingHeuristicConfiguration: AutoParkingHeuristicConfiguration {
        let stationaryDuration = AppConfig.autoParkingConfirmationDelay
        return AutoParkingHeuristicConfiguration(
            stationaryRadiusMeters: 28,
            minimumStationarySamples: 3,
            minimumStationaryDuration: stationaryDuration,
            minimumDrivingDistance: 240,
            maximumGapBetweenDriveAndStop: 90,
            maxPostDriveDriftMeters: 140,
            maxWalkingLikeDriftBeforeStationary: 30,
            minimumApproachSamplesNearStop: 1,
            minimumConfidence: max(0.74, AppConfig.autoParkingMinimumConfidence)
        )
    }
    private lazy var autoParkingDetectionCoordinator = AutoParkingDetectionCoordinator(
        locationService: locationService,
        bluetoothService: carBluetoothService,
        heuristic: AutoParkingDetectionHeuristic(
            configuration: autoParkingHeuristicConfiguration
        ),
        shouldMonitor: { [weak self] in
            self?.shouldMonitorAutoParking ?? false
        },
        onConfirmed: { [weak self] detection in
            await self?.handleConfirmedAutoParking(detection)
        }
    )

    var isAutoParkingDetectionEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: Self.autoParkingDetectionEnabledKey) == nil {
                return false
            }
            return defaults.bool(forKey: Self.autoParkingDetectionEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoParkingDetectionEnabledKey)
            configureAutoParkingDetectionIfNeeded()
        }
    }

    var isAutoDepartureEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "settings.autoDepartureEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "settings.autoDepartureEnabled") }
    }

    var shouldShowAlwaysLocationPrompt: Bool {
        guard isBackgroundParkingAssistanceEnabled else { return false }
        return locationAuthorizationStatus.needsAlwaysUpgrade
            || locationAuthorizationStatus.isDeniedOrRestricted
    }

    var shouldShowAlwaysAndPreciseLocationPrompt: Bool {
        switch locationAuthorizationStatus {
        case .notDetermined:
            return false
        case .authorizedAlways:
            return locationAccuracyAuthorization == .reducedAccuracy
        case .authorized, .authorizedWhenInUse, .denied, .restricted:
            return true
        }
    }

    var autoDepartureRadius: Double {
        get {
            let r = UserDefaults.standard.object(forKey: "settings.autoDepartureRadius") as? Double ?? 200
            return min(max(r, 80), 500)
        }
        set { UserDefaults.standard.set(min(max(newValue, 80), 500), forKey: "settings.autoDepartureRadius") }
    }

    init(
        userId: UUID? = nil,
        saveParkingUseCase:        SaveParkingUseCase?        = nil,
        endParkingUseCase:         EndParkingUseCase?         = nil,
        fetchActiveSessionUseCase: FetchActiveSessionUseCase? = nil,
        fetchHistoryUseCase:       FetchHistoryUseCase?       = nil,
        photoStorage:              PhotoStorageProtocol?      = nil,
        locationService:           LocationServiceProtocol?   = nil,
        notificationService:       NotificationServiceProtocol? = nil,
        liveActivityService:       LiveActivityService?       = nil,
        sharedParkingDataManager:  SharedParkingDataManager?  = nil,
        predictionService:         PredictionService?         = nil,
        frequentZoneService:       FrequentZoneService?       = nil,
        keychainService:           KeychainServiceProtocol?   = nil,
        reachability:              NetworkReachabilityMonitor? = nil,
        carBluetoothService:       BluetoothMonitoringServiceProtocol? = nil,
        departureDetectionService: DepartureDetectionService? = nil,
        calendarService:           CalendarService?           = nil,
        riskZoneService:           RiskZoneService?           = nil
    ) {
        let container = DIContainer.shared
        let resolvedKeychain = keychainService ?? container.keychainService

        self.userId                    = userId ?? Self.resolvePersistedUserId(from: resolvedKeychain)
        self.saveParkingUseCase        = saveParkingUseCase ?? container.makeSaveParkingUseCase()
        self.endParkingUseCase         = endParkingUseCase ?? container.makeEndParkingUseCase()
        self.fetchActiveSessionUseCase = fetchActiveSessionUseCase ?? container.makeFetchActiveSessionUseCase()
        self.fetchHistoryUseCase       = fetchHistoryUseCase ?? container.makeFetchHistoryUseCase()
        self.photoStorage             = photoStorage ?? container.photoStorage
        self.locationService           = locationService ?? container.locationService
        self.notificationService       = notificationService ?? container.notificationService
        self.liveActivityService       = liveActivityService ?? .shared
        self.sharedParkingDataManager  = sharedParkingDataManager ?? .shared
        self.predictionService         = predictionService ?? container.predictionService
        self.frequentZoneService       = frequentZoneService ?? container.frequentZoneService
        self.keychain                  = resolvedKeychain
        self.reachability              = reachability ?? container.networkReachabilityMonitor
        self.providedCarBluetoothService = carBluetoothService
        self.providedDepartureDetectionService = departureDetectionService
        self.calendarService           = calendarService ?? container.calendarService
        self.riskZoneService           = riskZoneService ?? container.riskZoneService
        let storedMode = HomeLocalizationMode(rawValue: UserDefaults.standard.string(forKey: "settings.findCar.localizationMode") ?? "gps") ?? .gps
        self.selectedLocalizationMode = storedMode.isUserSelectable ? storedMode : .gps
        if !storedMode.isUserSelectable {
            UserDefaults.standard.set(HomeLocalizationMode.gps.rawValue, forKey: "settings.findCar.localizationMode")
        }
        self.alternativeSystemsPolicy  = AlternativeSystemsPolicy(rawValue: UserDefaults.standard.string(forKey: "settings.findCar.alternativeSystemsPolicy") ?? "alwaysActive") ?? .alwaysActive
        let cachedPremium = cachedPremiumAccess()
        self.hasPremiumWidgetsAccess = cachedPremium
        self.hasFrequentZonesAccess = cachedPremium
        self.hasPremiumSmartDetectionAccess = cachedPremium
        WatchParkingDataStore.shared.setWidgetAccessEnabled(cachedPremium)
        activateWatchSessionIfNeeded()
        setupPremiumAccessObserver()
        setupLocationObserver()
        setupAutoParkingPreferenceObserver()
        setupAutoParkingDebugDetectionObserver()
        setupSmartAwayNotificationObserver()
        setupAutoParkingNotificationObserver()
        setupCarPlayDisconnectNotificationObserver()
        setupCarPlayDisconnectSaveActionObserver()
        setupIntelligenceResetObserver()
        setupAuthRestoreObserver()
        cancelPendingSmartAwayNotifications()
        restorePersistedPendingAutoParkingStateIfNeeded()
        restorePendingSmartAwayNotificationIfNeeded()
        restorePendingAutoParkingFromNotificationIfNeeded()
        restorePendingCarPlayDisconnectPromptIfNeeded()
        restorePendingCarPlayDisconnectDirectSaveIfNeeded()
    }

    deinit {
        autoEndTask?.cancel()
        startupWarmupTask?.cancel()
        autoParkingStartTask?.cancel()
    }

    func setLocalizationMode(_ mode: HomeLocalizationMode) {
        let nextMode: HomeLocalizationMode = mode.isUserSelectable ? mode : .gps
        selectedLocalizationMode = nextMode
        UserDefaults.standard.set(nextMode.rawValue, forKey: "settings.findCar.localizationMode")
    }

    func setAlternativeSystemsPolicy(_ policy: AlternativeSystemsPolicy) {
        alternativeSystemsPolicy = policy
        UserDefaults.standard.set(policy.rawValue, forKey: "settings.findCar.alternativeSystemsPolicy")
    }

    func updateUserId(_ id: UUID?) {
        let effectiveId = id ?? (didFinishInitialAuthRestore ? Self.resolvePersistedUserId(from: keychain) : nil)
        let userChanged = userId != effectiveId
        userId = effectiveId

        if userChanged {
            configureAutoParkingDetectionIfNeeded()
        }
        Task { await loadActiveSession() }
    }

    func requestLocationAccess() {
        locationService.requestAuthorization()
        startLocationUpdatesIfNeeded()
        configureAutoParkingDetectionIfNeeded()
    }

    func requestAlwaysLocationAccess() {
        locationService.requestAlwaysAuthorizationIfNeeded()
    }

    func refreshLocationAccessState() {
        locationService.refreshAuthorizationStatus()
    }

    func onDisappear() {
        startupWarmupTask?.cancel()
        stopLocationUpdatesIfNeeded()
        configureAutoParkingDetectionIfNeeded()
    }

    func setAppActive(_ isActive: Bool) {
        guard isAppActive != isActive else { return }
        isAppActive = isActive

        if isActive {
            Task { await loadActiveSession() }
            startLocationUpdatesIfNeeded()
            configureAutoParkingDetectionIfNeeded()
            configureDepartureMonitoringIfNeeded()
        } else {
            // Sécurité: ne jamais auto-clôturer un parking quand l'app est en arrière-plan.
            cancelPendingAutoEnd()
            if didSetupDepartureDetection {
                departureDetectionService.stopMonitoring()
            }
            startupWarmupTask?.cancel()
            stopLocationUpdatesIfNeeded()
            configureAutoParkingDetectionIfNeeded()
        }
    }

    func onAppear() {
        requestLocationAccess()
        Task { await loadActiveSession() }

        startupWarmupTask?.cancel()
        startupWarmupTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.isAppActive else { return }
            await self.refreshIntelligence()
            guard !Task.isCancelled, self.isAppActive else { return }
            await self.refreshCalendarSuggestion()
            guard !Task.isCancelled, self.isAppActive else { return }
            self.refreshParkingRiskAssessment(for: self.userCoordinate)
        }
    }

    func loadActiveSession() async {
        if isActiveSessionLoadInFlight {
            shouldReloadActiveSessionAfterCurrentLoad = true
            return
        }

        isActiveSessionLoadInFlight = true
        defer {
            isActiveSessionLoadInFlight = false
            if shouldReloadActiveSessionAfterCurrentLoad {
                shouldReloadActiveSessionAfterCurrentLoad = false
                Task { await self.loadActiveSession() }
            }
        }

        let resolvedUserId = resolvedUserIdForSessionLookup()

        guard let resolvedUserId else {
            // Prevent false "reset" while AuthRepository is still restoring tokens/user.
            guard didFinishInitialAuthRestore else { return }
            restoreAnonymousActiveSessionIfAvailable()
            return
        }

        if userId == nil {
            userId = resolvedUserId
        }

        // 1. Chargement local immédiat pour l'instantanéité
        if let localActive = try? await fetchActiveSessionUseCase.execute(userId: resolvedUserId, forceLocal: true) {
            guard resolvedUserIdForSessionLookup() == resolvedUserId else { return }
            activeSession = localActive
            syncLiveActivity()
            configureDepartureMonitoringIfNeeded()
            configureAutoParkingDetectionIfNeeded()
        }

        guard didFinishInitialAuthRestore else { return }

        // 2. Refresh distant en arrière-plan, sans bloquer l'UI d'enregistrement.
        errorMessage = nil
        
        do {
            let session = try await fetchActiveSessionUseCase.execute(userId: resolvedUserId)
            guard resolvedUserIdForSessionLookup() == resolvedUserId else { return }
            if session != activeSession {
                activeSession = session
                if session != nil {
                    clearPersistedPendingAutoParkingState()
                    pendingAutoParkingNotificationDetection = nil
                    pendingAutoParkingConfirmation = nil
                    temporaryAutoParkingDetectionCoordinate = nil
                    resetAutoParkingWalkAwayTracking()
                    syncLiveActivity()
                    configureDepartureMonitoringIfNeeded()
                    configureAutoParkingDetectionIfNeeded()
                }
            }
        } catch {
            // Ne pas afficher d'erreur pour les timeouts au démarrage si on a déjà une session locale.
            // Cela évite l'alerte "The server is taking too long" qui bloque l'utilisateur.
            if isAuthenticationFailure(error) {
                userId = nil
                if activeSession == nil {
                    restoreAnonymousActiveSessionIfAvailable()
                }
                return
            }
            if activeSession == nil && !isCancellationLikeError(error) {
                errorMessage = error.localizedDescription
            }
        }
    }

    func saveParking(note: String? = nil, parkingLevel: String? = nil,
                     maxDuration: TimeInterval? = nil, zone: ParkingZone = .unknown,
                     photoData: Data? = nil,
                     detectedCoordinate: Coordinate? = nil,
                     address: String? = nil) async -> Bool {

        errorMessage = nil
        
        guard let userId = resolvedUserIdForSessionLookup() else {
            return await saveParkingAnonymously(
                note: note,
                parkingLevel: parkingLevel,
                maxDuration: maxDuration,
                zone: zone,
                photoData: photoData,
                detectedCoordinate: detectedCoordinate,
                address: address
            )
        }
        if self.userId == nil {
            self.userId = userId
        }

        do {
            activeSession = try await saveParkingUseCase.execute(
                userId: userId, coordinate: detectedCoordinate ?? userCoordinate,
                note: note, parkingLevel: parkingLevel,
                maxDuration: maxDuration, zone: zone,
                photoData: photoData,
                address: address,
                allowsPremiumWidgetSurfaces: hasPremiumWidgetsAccess
            )
            
            // Fermer l'écran immédiatement car le save local est fait.
            // On fait le reste en tâche de fond pour que ce soit instantané pour l'utilisateur.
            showSaveSheet = false
            
            Task {
                clearPersistedPendingAutoParkingState()
                if detectedCoordinate != nil {
                    dismissPendingAutoParkingSuggestion()
                }
                syncLiveActivity()
                configureDepartureMonitoringIfNeeded()
                configureAutoParkingDetectionIfNeeded()
                await refreshIntelligence()
            }
            
            return true
        } catch is CancellationError {
            return false
        } catch {
            if isCancellationLikeError(error) {
                return false
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func endParking(userInitiated: Bool = false) async {
        guard let sessionId = activeSession?.id else { return }

        if isAnonymousSession(activeSession) {
            await endAnonymousParkingSession(userInitiated: userInitiated)
            return
        }

        errorMessage = nil
        do {
            _ = try await endParkingUseCase.execute(sessionId: sessionId)
            
            // Mise à jour immédiate de l'état local
            activeSession = nil
            
            Task {
                syncLiveActivity()
                if didSetupDepartureDetection {
                    departureDetectionService.stopMonitoring()
                }
                autoEndTask?.cancel()
                pendingAutoEndDeadline = nil
                configureAutoParkingDetectionIfNeeded()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshCalendarSuggestion() async {
        if let suggestion = await calendarService.nextEventSuggestion(maxWindowHours: 8) {
            calendarSuggestedTitle = suggestion.eventTitle
            calendarSuggestedDuration = suggestion.duration
        } else {
            calendarSuggestedTitle = nil
            calendarSuggestedDuration = nil
        }
    }

    func dismissCalendarSuggestion() {
        calendarSuggestedDuration = nil
        calendarSuggestedTitle = nil
    }

    func prepareSuggestionsForSave() async {
        await refreshIntelligence()
        await refreshCalendarSuggestion()
    }

    func suggestedDurationForSaveForm() -> TimeInterval? {
        if let calendarSuggestedDuration { return calendarSuggestedDuration }
        if let predictedDuration, shouldAutoApplyPrediction { return predictedDuration }
        guard hasFrequentZonesAccess else { return nil }
        if let userId,
           let coordinate = userCoordinate,
           let zone = frequentZoneService.bestZone(for: coordinate, userId: userId),
           let mins = zone.preferredDurationMinutes {
            return TimeInterval(mins * 60)
        }
        return nil
    }

    func consumeSuggestedDurationForSaveForm() -> TimeInterval? {
        if let forced = forcedDurationForNextSave {
            forcedDurationForNextSave = nil
            return forced
        }
        return suggestedDurationForSaveForm()
    }

    func shouldAutoEnableSuggestedDurationForSaveForm() -> Bool {
        if let forcedZone = forcedFrequentZoneForNextSave {
            return (forcedZone.preferredDurationMinutes ?? 0) > 0
        }

        if calendarSuggestedDuration != nil {
            return false
        }

        if predictedDuration != nil, shouldAutoApplyPrediction {
            return false
        }

        guard hasFrequentZonesAccess else {
            return false
        }

        if let userId,
           let coordinate = userCoordinate,
           let zone = frequentZoneService.bestZone(for: coordinate, userId: userId),
           let mins = zone.preferredDurationMinutes,
           mins > 0 {
            return true
        }

        return false
    }

    func requestUsePredictionFromHome() {
        guard let predictedDuration else { return }
        forcedDurationForNextSave = predictedDuration
    }

    func requestUseFrequentZoneShortcutFromHome(_ zone: FrequentZone) {
        guard hasFrequentZonesAccess else {
            forcedFrequentZoneForNextSave = nil
            forcedDurationForNextSave = nil
            return
        }
        forcedFrequentZoneForNextSave = zone
        forcedDurationForNextSave = nil
    }

    func consumeFrequentZoneShortcutForSaveForm() -> FrequentZone? {
        guard hasFrequentZonesAccess else {
            forcedFrequentZoneForNextSave = nil
            forcedDurationForNextSave = nil
            return nil
        }
        let zone = forcedFrequentZoneForNextSave
        forcedFrequentZoneForNextSave = nil
        forcedDurationForNextSave = nil
        return zone
    }

    func suggestionSourceDescription() -> String? {
        if let title = calendarSuggestedTitle, calendarSuggestedDuration != nil {
            return String(format: "Source: Calendrier (%@)".psLocalized, title)
        }
        if predictedDuration != nil, shouldAutoApplyPrediction {
            return String(format: "Source: IA (confiance %@)".psLocalized, predictionConfidenceLabel)
        }
        guard hasFrequentZonesAccess else { return nil }
        if let userId,
           let coordinate = userCoordinate,
           let zone = frequentZoneService.bestZone(for: coordinate, userId: userId),
           zone.preferredDurationMinutes != nil {
            return String(format: "Source: Zone fréquente (%@)".psLocalized, zone.name)
        }
        return nil
    }

    func suggestedFrequentZoneName(for coordinate: Coordinate?) -> String? {
        guard hasFrequentZonesAccess, let userId, let coordinate else { return nil }
        return frequentZoneService.suggestedZoneName(for: coordinate, userId: userId)
    }

    func nearbyFrequentZones(for coordinate: Coordinate?) -> [FrequentZone] {
        guard hasFrequentZonesAccess, let userId, let coordinate else { return [] }
        return frequentZoneService.nearbyZones(for: coordinate, userId: userId, limit: 3)
    }

    func refreshParkingRiskAssessment(for coordinate: Coordinate?) {
        guard let coordinate else {
            parkingRiskAssessment = nil
            return
        }
        parkingRiskAssessment = riskZoneService.evaluateRisk(for: coordinate)
    }

    func resolveCurrentAddress(for coordinate: Coordinate) async {
        currentAddress = nil
        do {
            currentAddress = try await locationService.reverseGeocode(coordinate)
        } catch {
            currentAddress = nil
        }
    }

    @discardableResult
    func reportRiskZone(category: RiskZoneCategory, note: String? = nil) -> Bool {
        guard let coordinate = userCoordinate else { return false }
        _ = riskZoneService.addCommunitySignal(coordinate: coordinate, category: category, notes: note)
        lastCommunityRiskReportAt = .now
        refreshParkingRiskAssessment(for: coordinate)
        return true
    }

    var predictionConfidenceLabel: String {
        guard let confidence = predictionConfidence else { return "--" }
        return "\(Int(confidence * 100))%"
    }

    var shouldAutoApplyPrediction: Bool {
        guard let confidence = predictionConfidence else { return false }
        return confidence >= 0.58 && !isPredictionAnomalous
    }

    var predictionConfidenceTier: PredictionConfidenceTier {
        guard let confidence = predictionConfidence else { return .low }
        if confidence >= 0.75 { return .high }
        if confidence >= 0.55 { return .medium }
        return .low
    }

    func registerPredictionFeedbackIfNeeded(
        selectedDuration: TimeInterval,
        selectedZone: ParkingZone,
        coordinate: Coordinate?
    ) {
        guard let userId,
              let suggested = predictedDuration else { return }

        let context = ParkingSession(
            userId: userId,
            coordinate: coordinate ?? userCoordinate ?? .zero,
            zone: selectedZone
        )

        predictionService.registerTimerCorrection(
            selectedDuration: selectedDuration,
            suggestedDuration: suggested,
            context: context,
            userId: userId
        )
    }

    func cancelPendingAutoEnd() {
        autoEndToken = UUID()
        autoEndTask?.cancel()
        pendingAutoEndDeadline = nil
    }

    func resetIntelligenceLearning() async {
        guard let userId else { return }
        _ = predictionService.resetLearnedCorrections(for: userId)
        await refreshIntelligence()
    }

    private func setupIntelligenceResetObserver() {
        NotificationCenter.default.publisher(for: .intelligenceLearningDidReset)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                guard let resetUserId = notification.userInfo?[IntelligenceResetUserInfoKey.userId] as? UUID,
                      resetUserId == self.userId else { return }
                Task { await self.refreshIntelligence() }
            }
            .store(in: &cancellables)
    }

    private func setupAutoParkingPreferenceObserver() {
        NotificationCenter.default.publisher(for: .autoParkingSettingsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureAutoParkingDetectionIfNeeded()
                self?.configureDepartureMonitoringIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func saveParkingAnonymously(
        note: String?,
        parkingLevel: String?,
        maxDuration: TimeInterval?,
        zone: ParkingZone,
        photoData: Data?,
        detectedCoordinate: Coordinate?,
        address: String? = nil
    ) async -> Bool {
        let resolvedCoordinate: Coordinate
        let isApproximate: Bool

        if let detectedCoordinate {
            resolvedCoordinate = detectedCoordinate
            isApproximate = false
        } else if let coordinate = userCoordinate {
            resolvedCoordinate = coordinate
            isApproximate = false
        } else if let lastKnown = LastKnownLocationStore.shared.load(maxAge: Self.fallbackLocationMaxAge) {
            resolvedCoordinate = lastKnown.coordinate
            isApproximate = true
        } else {
            errorMessage = SaveParkingUseCaseError.noLocationAvailable.localizedDescription
            return false
        }

        let sessionId = UUID()
        
        // On crée la session immédiatement pour un retour instantané.
        // Les données "lourdes" (photo, adresse) seront mises à jour en tâche de fond si nécessaire.
        let session = ParkingSession(
            id: sessionId,
            userId: Self.guestSessionUserId,
            coordinate: resolvedCoordinate,
            address: address, // Utilise l'adresse pré-résolue si fournie
            photoPath: nil,    // Sera mis à jour plus tard si photoData présent
            note: note,
            parkingLevel: parkingLevel,
            maxDuration: maxDuration,
            zone: zone,
            isSynced: true,
            isApproximate: isApproximate
        )

        activeSession = session
        clearPersistedPendingAutoParkingState()
        if detectedCoordinate != nil {
            dismissPendingAutoParkingSuggestion()
        }
        
        // Persistence locale immédiate
        sharedParkingDataManager.saveAnonymousActiveSession(session)

        if session.maxDuration != nil {
            try? await notificationService.scheduleAlert(for: session)
        }
        
        // Tâches secondaires en arrière-plan
        Task { [weak self, photoStorage, locationService, reachability] in
            guard let self else { return }
            
            var finalAddress = address
            if finalAddress == nil && reachability.isConnected {
                finalAddress = try? await locationService.reverseGeocode(resolvedCoordinate)
            }
            
            var finalPhotoPath: String? = nil
            if let photoData {
                finalPhotoPath = try? await photoStorage.save(imageData: photoData, for: sessionId)
            }
            
            // Si on a récupéré des infos supp, on met à jour la session
            if finalAddress != nil || finalPhotoPath != nil {
                var updated = session
                if let finalAddress { updated.address = finalAddress }
                if let finalPhotoPath { updated.photoPath = finalPhotoPath }
                
                await MainActor.run {
                    if self.activeSession?.id == sessionId {
                        self.activeSession = updated
                        self.sharedParkingDataManager.saveAnonymousActiveSession(updated)
                    }
                }
            }
            
            await MainActor.run {
                self.syncLiveActivity()
                self.configureDepartureMonitoringIfNeeded()
                self.configureAutoParkingDetectionIfNeeded()
            }
        }

        showSaveSheet = false
        return true
    }

    private func restoreAnonymousActiveSessionIfAvailable() {
        if let locallyPersisted = sharedParkingDataManager.loadAnonymousActiveSession() {
            activeSession = locallyPersisted
            syncLiveActivity()
            configureDepartureMonitoringIfNeeded()
            configureAutoParkingDetectionIfNeeded()
            return
        }
        // NOTE:
        // Never reconstruct an anonymous app session from the shared widget payload.
        // `parkspot_active_session` can represent a previous authenticated user state
        // and restoring it here creates a ghost parking session when the user is
        // currently logged out.
        syncLiveActivity()
        configureDepartureMonitoringIfNeeded()
        configureAutoParkingDetectionIfNeeded()
    }

    private func isAnonymousSession(_ session: ParkingSession?) -> Bool {
        guard let session else { return false }
        return session.userId == Self.guestSessionUserId
    }

    private func endAnonymousParkingSession(userInitiated: Bool) async {
        let endedSession = activeSession

        if let photoPath = activeSession?.photoPath {
            try? await photoStorage.delete(path: photoPath)
        }

        activeSession = nil
        sharedParkingDataManager.clearAnonymousActiveSession()
        syncLiveActivity()
        if didSetupDepartureDetection {
            departureDetectionService.stopMonitoring()
        }
        autoEndTask?.cancel()
        pendingAutoEndDeadline = nil
        configureAutoParkingDetectionIfNeeded()

        if userInitiated, let endedSession {
            NotificationCenter.default.post(
                name: NSNotification.Name.parkingSessionEnded,
                object: endedSession
            )
        }
    }

    private func configureAutoParkingDetectionIfNeeded() {
        guard shouldMonitorAutoParking else {
            locationService.setBackgroundParkingAssistanceActive(false)
            autoParkingStartTask?.cancel()
            autoParkingStartTask = nil
            isAutoParkingMonitoringActive = false
            autoParkingDetectionCoordinator.stop()
            return
        }

        locationService.setBackgroundParkingAssistanceActive(true)
        locationService.requestAlwaysAuthorizationIfNeeded()
        startLocationUpdatesIfNeeded()
        guard !isAutoParkingMonitoringActive, autoParkingStartTask == nil else { return }

        autoParkingStartTask = Task(priority: .utility) { [weak self] in
            defer { self?.autoParkingStartTask = nil }
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled, self.shouldMonitorAutoParking else { return }
            self.autoParkingDetectionCoordinator.start()
            self.isAutoParkingMonitoringActive = true
        }
    }

    private var shouldMonitorAutoParking: Bool {
        isAutoParkingDetectionEnabled && activeSession == nil
    }

    var pendingAutoParkingDetectionForUI: AutoParkingDetectionSnapshot? {
        pendingAutoParkingNotificationDetection
    }

    var hasAutoParkingPremiumAccess: Bool {
        true
    }

    var pendingAutoParkingAddressForUI: String {
        if let pendingAutoParkingAddress,
           !pendingAutoParkingAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return pendingAutoParkingAddress
        }

        if let coordinate = (pendingAutoParkingNotificationDetection ?? pendingAutoParkingConfirmation)?.coordinate {
            return fallbackAutoParkingAddress(for: coordinate)
        }

        return String(localized: "home.saved_position")
    }

    var unfilteredAutoParkingAddressForUI: String {
        guard let coordinate = currentUnfilteredAutoParkingCoordinate else {
            return String(localized: "home.saved_position")
        }
        return fallbackAutoParkingAddress(for: coordinate)
    }

    var canUseUnfilteredAutoParkingDetectionForUI: Bool {
        currentUnfilteredAutoParkingCoordinate != nil
    }

    private func handleConfirmedAutoParking(_ detection: AutoParkingDetectionSnapshot) async {
        guard activeSession == nil else { return }
        guard pendingAutoParkingConfirmation == nil else { return }
        setPendingAutoParkingNotificationDetection(detection)

        if let lastAcceptedLocationSample {
            evaluateAutoParkingNotificationTriggerIfNeeded(with: lastAcceptedLocationSample, previousSample: nil)
        }

        let requiredDistance = autoParkingWalkAwayConfirmationPolicy.requiredWalkAwayDistance(for: detection)
        debugAutoParkingStatus =
            "AutoParking détecté • en attente éloignement à pied > \(Int(requiredDistance.rounded()))m"
    }

    func confirmPendingAutoParkingSuggestion() {
        guard let detection = pendingAutoParkingConfirmation else { return }
        pendingAutoParkingNotificationDetection = nil
        pendingAutoParkingConfirmation = nil
        temporaryAutoParkingDetectionCoordinate = nil
        pendingAutoParkingAddress = nil
        clearPersistedPendingAutoParkingState()
        pendingAutoParkingSaveCoordinate = detection.coordinate
        showSaveSheet = true
        debugAutoParkingStatus = "AutoParking confirmé • ouverture de la fiche d'enregistrement"
    }

    func openPendingAutoParkingSuggestionInSaveSheet() {
        guard let detection = pendingAutoParkingConfirmation else { return }
        pendingAutoParkingSaveCoordinate = detection.coordinate
        showSaveSheet = true
        debugAutoParkingStatus = "AutoParking • ouverture de la fiche d'enregistrement"
    }

    func openPendingAutoParkingDetectionInSaveSheet() {
        guard let detection = pendingAutoParkingNotificationDetection ?? pendingAutoParkingConfirmation else {
            return
        }
        pendingAutoParkingSaveCoordinate = detection.coordinate
        showSaveSheet = true
        debugAutoParkingStatus = "AutoParking pending • ouverture de la fiche d'enregistrement"
    }

    func dismissPendingAutoParkingSuggestion() {
        pendingAutoParkingNotificationDetection = nil
        pendingAutoParkingConfirmation = nil
        temporaryAutoParkingDetectionCoordinate = nil
        pendingAutoParkingAddress = nil
        resetAutoParkingWalkAwayTracking()
        clearPersistedPendingAutoParkingState()
        debugAutoParkingStatus = "AutoParking ignoré par l'utilisateur"
    }

    private func setPendingAutoParkingConfirmation(_ detection: AutoParkingDetectionSnapshot) {
        resetAutoParkingWalkAwayTracking()
        pendingAutoParkingConfirmation = detection
        temporaryAutoParkingDetectionCoordinate = detection.coordinate
        pendingAutoParkingAddress = fallbackAutoParkingAddress(for: detection.coordinate)
        persistPendingAutoParkingConfirmation(detection)
        clearPersistedPendingAutoParkingNotificationDetection()

        Task { [weak self] in
            await self?.resolvePendingAutoParkingAddress(for: detection)
        }
    }

    private func resolvePendingAutoParkingAddress(for detection: AutoParkingDetectionSnapshot) async {
        let resolved = try? await locationService.reverseGeocode(detection.coordinate)
        let normalized = resolved?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard pendingAutoParkingConfirmation?.coordinate == detection.coordinate else { return }

        if let normalized, !normalized.isEmpty {
            pendingAutoParkingAddress = normalized
        }
    }

    private func setPendingAutoParkingNotificationDetection(_ detection: AutoParkingDetectionSnapshot) {
        resetAutoParkingWalkAwayTracking()
        lastAutoParkingWalkAwayDetectionCoordinate = detection.coordinate
        pendingAutoParkingNotificationDetection = detection
        temporaryAutoParkingDetectionCoordinate = detection.coordinate
        pendingAutoParkingAddress = fallbackAutoParkingAddress(for: detection.coordinate)
        persistPendingAutoParkingNotificationDetection(detection)

        Task { [weak self] in
            await self?.resolvePendingAutoParkingDetectionAddress(for: detection)
        }
    }

    private func resolvePendingAutoParkingDetectionAddress(for detection: AutoParkingDetectionSnapshot) async {
        let resolved = try? await locationService.reverseGeocode(detection.coordinate)
        let normalized = resolved?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard pendingAutoParkingNotificationDetection?.coordinate == detection.coordinate else { return }
        guard pendingAutoParkingConfirmation == nil else { return }

        if let normalized, !normalized.isEmpty {
            pendingAutoParkingAddress = normalized
        }
    }

    private var currentUnfilteredAutoParkingCoordinate: Coordinate? {
        let coordinate = userCoordinate ?? mapUserCoordinate ?? lastAcceptedLocationSample?.coordinate
        guard coordinate?.isValidGeoCoordinate == true else { return nil }
        return coordinate
    }

    private func fallbackAutoParkingAddress(for coordinate: Coordinate) -> String {
        String(
            format: "%.5f, %.5f",
            locale: Locale(identifier: "en_US_POSIX"),
            coordinate.latitude,
            coordinate.longitude
        )
    }

    func useCurrentGPSAsUnfilteredAutoParkingDetection() {
        guard let coordinate = currentUnfilteredAutoParkingCoordinate else { return }
        pendingAutoParkingSaveCoordinate = coordinate
        showSaveSheet = true
        debugAutoParkingStatus = "AutoParking debug • ouverture avec position GPS actuelle"
    }

    func consumeAutoParkingDetectedCoordinateForSave() -> Coordinate? {
        defer { pendingAutoParkingSaveCoordinate = nil }
        return pendingAutoParkingSaveCoordinate
    }

    func preferredAutoParkingDetectedCoordinateForSave() -> Coordinate? {
        pendingAutoParkingSaveCoordinate
    }

    func prepareSmartAwaySaveFormPrefill() {
        cancelPendingAutoEnd()
        showSmartAwayInAppAlert = false
        pendingSmartAwaySaveFormPrefill = nil
        guard let session = activeSession else { return }

        pendingSmartAwaySaveFormPrefill = SmartAwaySaveFormPrefill(
            note: session.note ?? "",
            parkingLevel: session.parkingLevel ?? "",
            zone: session.zone,
            maxDuration: session.maxDuration
        )
    }

    func consumeSmartAwaySaveFormPrefill() -> SmartAwaySaveFormPrefill? {
        defer { pendingSmartAwaySaveFormPrefill = nil }
        return pendingSmartAwaySaveFormPrefill
    }

    @discardableResult
    func reRegisterActiveParkingFromSmartAway(
        note: String?,
        parkingLevel: String?,
        maxDuration: TimeInterval?,
        zone: ParkingZone,
        photoData: Data?,
        detectedCoordinate: Coordinate? = nil,
        address: String? = nil
    ) async -> Bool {
        guard let currentSession = activeSession else {
            return await saveParking(
                note: note,
                parkingLevel: parkingLevel,
                maxDuration: maxDuration,
                zone: zone,
                photoData: photoData,
                detectedCoordinate: detectedCoordinate,
                address: address
            )
        }

        let targetCoordinate = detectedCoordinate ?? userCoordinate ?? currentSession.coordinate

        let effectivePhotoData: Data?
        if let photoData {
            effectivePhotoData = photoData
        } else if let photoPath = currentSession.photoPath {
            effectivePhotoData = try? await photoStorage.load(path: photoPath)
        } else {
            effectivePhotoData = nil
        }

        cancelPendingAutoEnd()
        showSmartAwayInAppAlert = false

        if isAnonymousSession(currentSession) {
            let previousPhotoPath = currentSession.photoPath
            let saved = await saveParkingAnonymously(
                note: note,
                parkingLevel: parkingLevel,
                maxDuration: maxDuration,
                zone: zone,
                photoData: effectivePhotoData,
                detectedCoordinate: targetCoordinate,
                address: address
            )

            if saved {
                if let previousPhotoPath,
                   previousPhotoPath != activeSession?.photoPath {
                    try? await photoStorage.delete(path: previousPhotoPath)
                }
                debugSmartAwayStatus = "SmartAway: position ré-enregistrée"
            }
            return saved
        }

        guard let resolvedUserId = resolvedUserIdForSessionLookup() else {
            errorMessage = "Impossible de retrouver l'utilisateur connecté.".psLocalized
            return false
        }

        if userId == nil {
            userId = resolvedUserId
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await endParkingUseCase.execute(sessionId: currentSession.id)
            let saved = try await saveParkingUseCase.execute(
                userId: resolvedUserId,
                coordinate: targetCoordinate,
                note: note,
                parkingLevel: parkingLevel,
                maxDuration: maxDuration,
                zone: zone,
                photoData: effectivePhotoData,
                address: address,
                allowsPremiumWidgetSurfaces: hasPremiumWidgetsAccess
            )

            activeSession = saved
            clearPersistedPendingAutoParkingState()
            syncLiveActivity()
            configureDepartureMonitoringIfNeeded()
            configureAutoParkingDetectionIfNeeded()
            await refreshIntelligence()
            debugSmartAwayStatus = "SmartAway: position ré-enregistrée"
            return true
        } catch is CancellationError {
            return false
        } catch {
            if isCancellationLikeError(error) {
                return false
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func inferZone(for coordinate: Coordinate) -> ParkingZone {
        let inferredZone: ParkingZone
        if hasFrequentZonesAccess,
           let userId,
           let frequentZone = frequentZoneService.bestZone(for: coordinate, userId: userId) {
            inferredZone = frequentZone.parkingType
        } else {
            inferredZone = .unknown
        }
        return inferredZone
    }

    private func refreshIntelligence() async {
        guard let userId else {
            predictedDuration = nil
            predictionConfidence = nil
            frequentZoneNameSuggestion = nil
            return
        }
        do {
            let history = try await fetchHistoryUseCase.execute(userId: userId, page: 0, pageSize: 120)
            if let prediction = predictionService.predictDuration(from: history, target: activeSession, userId: userId) {
                predictedDuration = prediction.suggestedDuration
                predictionConfidence = prediction.confidence
                predictionSampleCount = prediction.basedOnCount
                predictionContextProfile = prediction.contextProfile
                isPredictionAnomalous = prediction.isAnomalous
                predictionConservativeDuration = prediction.conservativeDuration
                predictionAggressiveDuration = prediction.aggressiveDuration
                predictionFreshnessDays = prediction.freshnessDays
                predictionExplanation = prediction.explanation
            } else {
                predictedDuration = nil
                predictionConfidence = nil
                predictionSampleCount = nil
                predictionContextProfile = nil
                isPredictionAnomalous = false
                predictionConservativeDuration = nil
                predictionAggressiveDuration = nil
                predictionFreshnessDays = nil
                predictionExplanation = nil
            }
            if hasFrequentZonesAccess {
                _ = await frequentZoneService.updateFromHistory(history, userId: userId)
                frequentZoneNameSuggestion = suggestedFrequentZoneName(for: userCoordinate ?? activeSession?.coordinate)
            } else {
                frequentZoneNameSuggestion = nil
            }
        } catch {
            if AppConfig.isDebugLoggingEnabled {
                print("[HomeViewModel] intelligence refresh failed: \(error.localizedDescription)")
            }
        }
    }

    private func configureDepartureMonitoringIfNeeded() {
        guard isAutoDepartureEnabled,
              let session = activeSession,
              session.endTime == nil else {
            if didSetupDepartureDetection {
                departureDetectionService.stopMonitoring()
            }
            return
        }

        setupDepartureDetectionIfNeeded()
        departureDetectionService.startMonitoring(
            sessionId: session.id,
            center: session.coordinate,
            radius: autoDepartureRadius
        )
    }

    private func setupDepartureDetectionIfNeeded() {
        guard !didSetupDepartureDetection else { return }
        didSetupDepartureDetection = true

        departureDetectionService.departureEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self,
                      self.isAutoDepartureEnabled,
                      self.isAppActive else { return }
                self.scheduleAutoEndWithUndoWindow()
            }
            .store(in: &cancellables)
    }

    private func triggerSmartAwayAlertIfNeeded(distanceMeters: Double? = nil, source: String) {
        guard isSmartAwayAlertEnabled else { return }
        guard let session = activeSession, session.endTime == nil else { return }

        if lastSmartAwaySessionId != session.id {
            lastSmartAwaySessionId = session.id
            lastSmartAwayAlertAt = nil
            lastSmartAwayRiskLevel = nil
        }

        let now = Date()
        let effectiveDistance = distanceMeters ?? distanceMetersToCar()
        let risk = forgetCarRiskLevel(now: now, distanceMeters: effectiveDistance)
        let cooldown = smartAwayCooldown(for: risk)

        if let lastSmartAwayAlertAt,
           now.timeIntervalSince(lastSmartAwayAlertAt) < cooldown {
            debugSmartAwayStatus = "SmartAway en cooldown"
            return
        }

        let roundedDistance = Int((effectiveDistance ?? 0).rounded())
        let title: String
        let body: String

        if risk == .high {
            title = "Potentially forgotten car".psLocalized
            if roundedDistance > 0 {
                body = String(format: "You are about %dm away from your saved car location.".psLocalized, roundedDistance)
            } else {
                body = "You are moving away from your saved car location.".psLocalized
            }
        } else {
            title = "Parking reminder".psLocalized
            if roundedDistance > 0 {
                body = String(format: "You are moving away (≈%dm). Check your car if needed.".psLocalized, roundedDistance)
            } else {
                body = "You are moving away. Check your car if needed.".psLocalized
            }
        }

        smartAwayInAppAlertTitle = title
        smartAwayInAppAlertBody = body
        showSmartAwayInAppAlert = true

        lastSmartAwayAlertAt = now
        lastSmartAwayRiskLevel = risk

        Task { [weak self] in
            guard let self else { return }
            let scheduled = await self.scheduleSmartAwayNotification(
                title: title,
                body: body,
                risk: risk,
                source: source
            )

            await MainActor.run {
                if scheduled {
                    self.debugSmartAwayStatus =
                        "SmartAway notif envoyée • source=\(source) • risque=\(risk == .high ? "high" : "medium")"
                } else {
                    self.debugSmartAwayStatus =
                        "SmartAway in-app uniquement • source=\(source)"
                }
            }
        }
    }

    private func scheduleSmartAwayNotification(
        title: String,
        body: String,
        risk: ForgetCarRiskLevel,
        source: String
    ) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await currentNotificationAuthorizationStatus(center: center)

        switch status {
        case .denied:
            return false
        case .notDetermined:
            let granted = await requestNotificationAuthorization(center: center)
            if !granted { return false }
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            return false
        }

        let identifier = smartAwayNotificationIdentifier(for: risk)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "parkspot.smart-away"
        content.userInfo = [
            SmartAwayNotificationPayloadStore.sourceUserInfoKey: source
        ]
        if #available(iOS 15.0, *) {
            content.interruptionLevel = risk == .high ? .timeSensitive : .active
        }

        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        return await withCheckedContinuation { continuation in
            center.add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private enum ForgetCarRiskLevel: Int {
        case medium
        case high
    }

    private func forgetCarRiskLevel(now: Date = .now, distanceMeters: Double? = nil) -> ForgetCarRiskLevel {
        guard let session = activeSession else { return .medium }

        var score = 0.0
        let elapsed = now.timeIntervalSince(session.startTime)

        if elapsed <= 15 * 60 {
            score += 0.34
        } else if elapsed <= 45 * 60 {
            score += 0.22
        } else {
            score += 0.10
        }

        score += autoDepartureRadius >= 220 ? 0.28 : 0.18
        score += (session.maxDuration == nil) ? 0.20 : 0.08
        score += (session.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? 0.10 : 0.02
        score += (session.parkingLevel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? 0.08 : 0.02
        score += session.zone == .unknown ? 0.08 : 0.03

        if let predictedDuration {
            let elapsedVsPredicted = elapsed / max(predictedDuration, 1)
            if elapsedVsPredicted >= 1.0 {
                score += 0.22
            } else if elapsedVsPredicted >= 0.75 {
                score += 0.14
            } else if elapsedVsPredicted >= 0.55 {
                score += 0.08
            }

            if session.maxDuration == nil {
                score += 0.06
            }
        }

        if let confidence = predictionConfidence {
            if confidence >= 0.78 {
                score += 0.08
            } else if confidence >= 0.62 {
                score += 0.05
            }
        }

        if isPredictionAnomalous {
            score += 0.06
        }

        if let profile = predictionContextProfile?.lowercased(),
           profile.contains("weekend") || profile.contains("soir") {
            score += 0.04
        }

        if let distanceMeters {
            if distanceMeters >= 260 {
                score += 0.24
            } else if distanceMeters >= 170 {
                score += 0.16
            } else {
                score += 0.08
            }
        }

        return score >= 0.68 ? .high : .medium
    }

    private func smartAwayCooldown(for risk: ForgetCarRiskLevel) -> TimeInterval {
        let base: TimeInterval
        switch risk {
        case .high:
            base = 5 * 60
        case .medium:
            base = 12 * 60
        }
        return isPowerConstrained ? base * 1.8 : base
    }

    private func shouldEvaluateSmartAway(with coordinate: Coordinate, now: Date) -> Bool {
        if let lastSmartAwayEvaluationAt {
            let minimumInterval = isPowerConstrained
                ? smartAwayMinimumEvaluationInterval * 1.8
                : smartAwayMinimumEvaluationInterval
            let enoughTime = now.timeIntervalSince(lastSmartAwayEvaluationAt) >= minimumInterval

            let enoughDistance: Bool
            if let lastSmartAwayEvaluationCoordinate {
                let previous = CLLocation(
                    latitude: lastSmartAwayEvaluationCoordinate.latitude,
                    longitude: lastSmartAwayEvaluationCoordinate.longitude
                )
                let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                enoughDistance = current.distance(from: previous) >= smartAwayMinimumEvaluationDistanceMeters
            } else {
                enoughDistance = true
            }

            if !enoughTime && !enoughDistance {
                return false
            }
        }

        lastSmartAwayEvaluationAt = now
        lastSmartAwayEvaluationCoordinate = coordinate
        return true
    }

    private func smartAwayNotificationIdentifier(for risk: ForgetCarRiskLevel) -> String {
        let sessionPart = activeSession?.id.uuidString ?? "unknown"
        let riskPart = (risk == .high) ? "high" : "medium"
        return "parkspot.smart-away.\(sessionPart).\(riskPart)"
    }

#if DEBUG
    func debugRunAutoParkingHeuristic(samples: [LocationSample], bluetoothDisconnectAt: Date? = nil, now: Date = .now) -> AutoParkingDetectionSnapshot? {
        let heuristic = AutoParkingDetectionHeuristic(configuration: autoParkingHeuristicConfiguration)
        let result = heuristic.evaluate(samples: samples, bluetoothDisconnectAt: bluetoothDisconnectAt, now: now)

        if let result {
            debugAutoParkingStatus = "Heuristic match • conf=\(Int((result.confidence * 100).rounded()))% • source=\(result.triggerSource)"
        } else {
            debugAutoParkingStatus = "Heuristic: aucun match"
        }

        if AppConfig.isDebugLoggingEnabled {
            print("[AutoParking][Debug] samples=\(samples.count) matched=\(result != nil)")
        }

        return result
    }

    func debugForceSmartAwayNotification(distanceMeters: Double = 220, source: String = "debug-manual") {
        triggerSmartAwayAlertIfNeeded(distanceMeters: distanceMeters, source: source)
    }

    func debugResetSmartAwayCooldown() {
        lastSmartAwayAlertAt = nil
        lastSmartAwayRiskLevel = nil
        lastSmartAwaySessionId = activeSession?.id
        lastSmartAwayEvaluationAt = nil
        lastSmartAwayEvaluationCoordinate = nil
        lastSmartAwayDistanceMeters = nil
        debugSmartAwayStatus = "SmartAway cooldown reset"
    }
#endif

    private func scheduleAutoEndWithUndoWindow() {
        guard isAppActive else { return }
        autoEndTask?.cancel()
        let token = UUID()
        autoEndToken = token
        let deadline = Date().addingTimeInterval(30)
        pendingAutoEndDeadline = deadline

        autoEndTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.autoEndToken == token else { return }
            self.pendingAutoEndDeadline = nil
            await self.endParking()
        }
    }

    private func syncLiveActivity() {
        guard let session = activeSession,
              session.endTime == nil
        else {
            clearPremiumWidgetSurfaces()
            return
        }

        let hasTimer = (session.maxDuration ?? 0) > 0
        let maxDuration = hasTimer ? (session.maxDuration ?? 0) : 0
        let endDate = session.startTime.addingTimeInterval(maxDuration)
        let timerStillActive = hasTimer && endDate > Date()
        let activityEndDate = timerStillActive ? endDate : Date().addingTimeInterval(7 * 24 * 3600)
        let distanceMeters = distanceMetersToCar()
        let savedPositionFallback = "home.saved_position".psLocalized

        if lastWatchSyncedSessionId != session.id {
            lastWatchSyncedSessionId = session.id
            lastWatchDistanceSyncAt = nil
            lastWatchDistanceMeters = nil
        }

        syncWatchParkingSurface(
            session: session,
            distanceMeters: distanceMeters,
            timerStillActive: timerStillActive,
            endDate: endDate,
            fallbackAddress: savedPositionFallback
        )

        guard hasPremiumWidgetsAccess else {
            clearPremiumWidgetSurfaces(includeWatch: false)
            return
        }

        Task {
            let savedCarFallback = "home.saved_car_fallback".psLocalized

            if #available(iOS 16.2, *) {
                do {
                    try await liveActivityService.requestLiveActivity(
                        sessionId: session.id,
                        startDate: session.startTime,
                        endDate: activityEndDate,
                        address: session.address ?? savedCarFallback,
                        zone: session.zone.rawValue,
                        parkingLevel: session.parkingLevel,
                        note: session.note,
                        latitude: session.coordinate.latitude,
                        longitude: session.coordinate.longitude,
                        distanceText: formattedDistance,
                        maxDurationMinutes: timerStillActive ? session.maxDuration.map { Int($0 / 60) } : nil,
                        hasTimer: timerStillActive
                    )
                } catch {
                    print("[LiveActivity] request failed: \(error)")
                    if timerStillActive {
                        try? await liveActivityService.requestLiveActivity(
                            sessionId: session.id,
                            startDate: session.startTime,
                            endDate: Date().addingTimeInterval(7 * 24 * 3600),
                            address: session.address ?? savedCarFallback,
                            zone: session.zone.rawValue,
                            parkingLevel: session.parkingLevel,
                            note: session.note,
                            latitude: session.coordinate.latitude,
                            longitude: session.coordinate.longitude,
                            distanceText: formattedDistance,
                            maxDurationMinutes: nil,
                            hasTimer: false
                        )
                    }
                }

                if timerStillActive {
                    LiveActivityUpdateTimer.shared.startUpdating(
                        sessionId: session.id,
                        endDate: activityEndDate,
                        address: session.address ?? savedCarFallback,
                        zone: session.zone.rawValue,
                        parkingLevel: session.parkingLevel,
                        note: session.note,
                        latitude: session.coordinate.latitude,
                        longitude: session.coordinate.longitude,
                        distanceText: formattedDistance,
                        maxDurationMinutes: session.maxDuration.map { Int($0 / 60) },
                        hasTimer: true
                    )
                } else {
                    LiveActivityUpdateTimer.shared.stopUpdating()
                }
            }

            let widgetSession = SharedParkingSession(
                id: session.id.uuidString,
                address: session.address ?? savedPositionFallback,
                zone: session.zone.rawValue,
                parkingLevel: session.parkingLevel,
                note: session.note,
                startDate: session.startTime,
                endDate: endDate,
                userLatitude: session.coordinate.latitude,
                userLongitude: session.coordinate.longitude,
                maxDurationMinutes: timerStillActive ? session.maxDuration.map { Int($0 / 60) } : nil,
                hasTimer: timerStillActive
            )
            sharedParkingDataManager.saveActiveSession(widgetSession)
            ParkingWidgetDataStore.shared.save(session: session, distanceText: formattedDistance)
        }
    }

    private func clearPremiumWidgetSurfaces(includeWatch: Bool = true) {
        lastSmartAwaySessionId = nil
        lastSmartAwayAlertAt = nil
        lastSmartAwayRiskLevel = nil
        lastSmartAwayEvaluationAt = nil
        lastSmartAwayEvaluationCoordinate = nil
        lastSmartAwayDistanceMeters = nil
        lastWatchSyncedSessionId = nil
        lastWatchDistanceSyncAt = nil
        lastWatchDistanceMeters = nil

        Task {
            sharedParkingDataManager.clearActiveSession()
            if includeWatch {
                ParkingWidgetDataStore.shared.clear()
                syncWatchParkingPayload(nil)
            } else {
                ParkingWidgetDataStore.shared.clearLegacyWidgetData()
            }

            guard #available(iOS 16.2, *) else { return }
            LiveActivityUpdateTimer.shared.stopUpdating()
            await liveActivityService.endAllActivities()
        }
    }

    private func activateWatchSessionIfNeeded() {
        WatchParkingSyncBridge.shared.activateIfNeeded()
    }

    private func syncWatchParkingSurface(
        session: ParkingSession,
        distanceMeters: Double?,
        timerStillActive: Bool,
        endDate: Date,
        fallbackAddress: String
    ) {
        ParkingWidgetDataStore.shared.syncToWatch(
            session: session,
            distanceMeters: distanceMeters,
            distanceLabel: formattedDistance
        )
        syncWatchParkingPayload(
            makeWatchParkingPayload(
                session: session,
                distanceText: formattedDistance,
                distanceMeters: distanceMeters,
                hasTimer: timerStillActive,
                endDate: endDate,
                fallbackAddress: fallbackAddress
            )
        )
    }

    private func makeWatchParkingPayload(
        session: ParkingSession,
        distanceText: String?,
        distanceMeters: Double?,
        hasTimer: Bool,
        endDate: Date,
        fallbackAddress: String
    ) -> [String: Any] {
        [
            "isActive": true,
            "address": session.address ?? fallbackAddress,
            "fullAddress": session.address ?? fallbackAddress,
            "zoneType": session.zone.rawValue,
            "startTime": session.startTime.timeIntervalSince1970,
            "endTime": hasTimer ? endDate.timeIntervalSince1970 : 0,
            "hasEndTime": hasTimer,
            "distanceText": distanceText ?? "",
            "distanceMeters": distanceMeters ?? 0,
            "hasDistance": distanceMeters != nil,
            "parkingLevel": session.parkingLevel ?? "",
            "note": session.note ?? "",
            "latitude": session.coordinate.latitude,
            "longitude": session.coordinate.longitude,
            "allowsWidgetSurfaces": hasPremiumWidgetsAccess,
            "updatedAt": Date().timeIntervalSince1970
        ]
    }

    private func syncWatchParkingPayload(_ payload: [String: Any]?) {
        var effectivePayload = payload ?? [
            "isActive": false
        ]
        effectivePayload["allowsWidgetSurfaces"] = hasPremiumWidgetsAccess
        effectivePayload["updatedAt"] = Date().timeIntervalSince1970
        WatchParkingSyncBridge.shared.send(effectivePayload)
    }

    /// Synchronise la distance en temps réel vers la Watch sans surcharger WatchConnectivity.
    private func syncWatchDistanceIfNeeded(with sample: LocationSample) {
        guard let session = activeSession, session.endTime == nil else { return }

        let user = CLLocation(latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude)
        let car = CLLocation(latitude: session.coordinate.latitude, longitude: session.coordinate.longitude)
        let distanceMeters = user.distance(from: car)
        let now = Date()

        if lastWatchSyncedSessionId != session.id {
            lastWatchSyncedSessionId = session.id
            lastWatchDistanceSyncAt = nil
            lastWatchDistanceMeters = nil
        }

        if let lastSyncAt = lastWatchDistanceSyncAt,
           let lastDistance = lastWatchDistanceMeters {
            let elapsed = now.timeIntervalSince(lastSyncAt)
            let delta = abs(distanceMeters - lastDistance)
            // Garde-fou: push si > 20s ou si la distance a changé d'au moins 12m.
            if elapsed < 20, delta < 12 {
                return
            }
        }

        let hasTimer = (session.maxDuration ?? 0) > 0
        let endDate = session.startTime.addingTimeInterval(hasTimer ? (session.maxDuration ?? 0) : 0)
        let timerStillActive = hasTimer && endDate > now
        let fallbackAddress = "home.saved_position".psLocalized

        ParkingWidgetDataStore.shared.updateWatchDistance(distanceMeters)
        syncWatchParkingPayload(
            makeWatchParkingPayload(
                session: session,
                distanceText: formattedDistance,
                distanceMeters: distanceMeters,
                hasTimer: timerStillActive,
                endDate: endDate,
                fallbackAddress: fallbackAddress
            )
        )

        lastWatchDistanceSyncAt = now
        lastWatchDistanceMeters = distanceMeters
    }

    private func setupPremiumAccessObserver() {
        DIContainer.shared.authRepository.currentUser
            .receive(on: DispatchQueue.main)
            .sink { [weak self] user in
                guard let self else { return }
                if user == nil, !self.didFinishInitialAuthRestore {
                    return
                }
                if let authenticatedId = user?.id {
                    self.userId = authenticatedId
                } else if self.userId == nil {
                    self.userId = Self.resolvePersistedUserId(from: self.keychain)
                }
                let effectiveUser = user ?? self.loadCachedUser()
                let isPremium = self.hasPremiumAccess(effectiveUser)
                self.hasPremiumWidgetsAccess = isPremium
                self.hasFrequentZonesAccess = isPremium
                self.hasPremiumSmartDetectionAccess = isPremium
                WatchParkingDataStore.shared.setWidgetAccessEnabled(isPremium)
                self.configureAutoParkingDetectionIfNeeded()
                self.configureDepartureMonitoringIfNeeded()
                self.syncLiveActivity()
                if !isPremium {
                    self.lastSmartAwayAlertAt = nil
                }
            }
            .store(in: &cancellables)
    }

    private func loadCachedUser() -> User? {
        guard let data = UserDefaults.standard.data(forKey: "parkspot.auth.cachedUser.v1") else {
            return nil
        }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    private func cachedPremiumAccess() -> Bool {
        guard let cachedUser = loadCachedUser() else {
            return false
        }
        if let userId, cachedUser.id != userId {
            return false
        }
        return hasPremiumAccess(cachedUser)
    }

    private func setupAuthRestoreObserver() {
        DIContainer.shared.authRepository.didFinishInitialSessionRestore
            .receive(on: DispatchQueue.main)
            .sink { [weak self] didFinish in
                guard let self else { return }
                self.didFinishInitialAuthRestore = didFinish
                guard didFinish else { return }
                Task { await self.loadActiveSession() }
            }
            .store(in: &cancellables)
    }

    private static func resolvePersistedUserId(from keychain: KeychainServiceProtocol) -> UUID? {
        guard let value = try? keychain.get(.userId) else { return nil }
        return UUID(uuidString: value)
    }

    private func resolvedUserIdForSessionLookup() -> UUID? {
        if let userId {
            return userId
        }
        guard didFinishInitialAuthRestore else { return nil }
        return Self.resolvePersistedUserId(from: keychain)
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
            || normalized == "paid_lifetime" {
            return true
        }

        return user.isPremium
    }

    private func normalizedStatus(_ value: String?) -> String? {
        guard let value else { return nil }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func isCancellationLikeError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }

        switch apiError {
        case .unauthorized, .forbidden:
            return true
        case .requestFailed(let code, let message):
            return code == 401 || (message ?? "").localizedCaseInsensitiveContains("jwt")
        default:
            return false
        }
    }

    private func setupLocationObserver() {
        locationService.currentLocationSample
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                self?.consumeLocationSample(sample)
            }
            .store(in: &cancellables)

        locationService.currentHeading
            .throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] heading in self?.userHeading = heading }
            .store(in: &cancellables)

        locationService.authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.locationAuthorizationStatus = status
                self?.isLocationDenied = status.isDeniedOrRestricted
            }
            .store(in: &cancellables)

        locationService.accuracyAuthorization
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.locationAccuracyAuthorization = status
            }
            .store(in: &cancellables)
    }

    private var isBackgroundParkingAssistanceEnabled: Bool {
        isAutoParkingDetectionEnabled || isAutoDepartureEnabled
    }

    private func setupAutoParkingDebugDetectionObserver() {
        NotificationCenter.default.publisher(for: .autoParkingDebugDetectionInjected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAutoParkingDebugDetection(notification.userInfo)
            }
            .store(in: &cancellables)
    }

    private func handleAutoParkingDebugDetection(_ userInfo: [AnyHashable: Any]?) {
#if DEBUG
        guard let userInfo,
              let latitude = userInfo[AutoParkingNotificationPayloadStore.latitudeUserInfoKey] as? Double,
              let longitude = userInfo[AutoParkingNotificationPayloadStore.longitudeUserInfoKey] as? Double
        else {
            return
        }

        let confidence = userInfo[AutoParkingNotificationPayloadStore.confidenceUserInfoKey] as? Double ?? 0.9
        let source = userInfo[AutoParkingNotificationPayloadStore.sourceUserInfoKey] as? String
            ?? "settings-debug-auto-parking-current-gps"
        let bypassFilters = userInfo["parkspot.autoParking.debugBypassFilters"] as? Bool ?? false

        let detection = AutoParkingDetectionSnapshot(
            coordinate: Coordinate(latitude: latitude, longitude: longitude),
            confidence: confidence,
            stationaryDuration: 0,
            clusterRadius: 0,
            triggerSource: source
        )

        let percent = Int((confidence * 100).rounded())

        if bypassFilters {
            pendingAutoParkingNotificationDetection = nil
            clearPersistedPendingAutoParkingNotificationDetection()
            setPendingAutoParkingConfirmation(detection)
            debugAutoParkingStatus =
                "AutoParking détecté (debug) • sans filtre • confirmation immédiate • conf=\(percent)%"
            return
        }

        pendingAutoParkingConfirmation = nil
        setPendingAutoParkingNotificationDetection(detection)

        let walkedLatitude = detection.coordinate.latitude + (220.0 / 111_320.0)
        let simulatedWalkingSample = LocationSample(
            coordinate: Coordinate(latitude: walkedLatitude, longitude: detection.coordinate.longitude),
            accuracy: 8,
            date: .now,
            speed: 1.22
        )

        let simulatedPreviousSample = LocationSample(
            coordinate: detection.coordinate,
            accuracy: 8,
            date: Date().addingTimeInterval(-180),
            speed: 0.2
        )

        evaluateAutoParkingNotificationTriggerIfNeeded(
            with: simulatedWalkingSample,
            previousSample: simulatedPreviousSample
        )

        debugAutoParkingStatus =
            "AutoParking détecté (debug) • avec filtre • marche simulée • notif en cours • conf=\(percent)%"
#else
        _ = userInfo
#endif
    }

    private func setupSmartAwayNotificationObserver() {
        NotificationCenter.default.publisher(for: .smartAwayNotificationOpened)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.restorePendingSmartAwayNotificationIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func restorePendingSmartAwayNotificationIfNeeded() {
        guard let payload = SmartAwayNotificationPayloadStore.consume() else { return }
        smartAwayInAppAlertTitle = payload.title
        smartAwayInAppAlertBody = payload.body
        showSmartAwayInAppAlert = true
        debugSmartAwayStatus = "SmartAway • notif ouverte"
    }

    private func setupAutoParkingNotificationObserver() {
        NotificationCenter.default.publisher(for: .autoParkingNotificationOpened)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.restorePendingAutoParkingFromNotificationIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func setupCarPlayDisconnectNotificationObserver() {
        NotificationCenter.default.publisher(for: .carPlayDisconnectNotificationOpened)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.restorePendingCarPlayDisconnectPromptIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func setupCarPlayDisconnectSaveActionObserver() {
        NotificationCenter.default.publisher(for: .carPlayDisconnectNotificationSaveRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.restorePendingCarPlayDisconnectDirectSaveIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func restorePendingAutoParkingFromNotificationIfNeeded() {
        guard pendingAutoParkingConfirmation == nil,
              let payload = AutoParkingNotificationPayloadStore.consume() else {
            return
        }

        let detection = AutoParkingDetectionSnapshot(
            coordinate: payload.coordinate,
            confidence: payload.confidence,
            stationaryDuration: 0,
            clusterRadius: 0,
            triggerSource: payload.source ?? "notification"
        )
        setPendingAutoParkingConfirmation(detection)

        if AppConfig.isDebugLoggingEnabled {
            let percent = Int((payload.confidence * 100).rounded())
            print("[AutoParking] notification opened confidence=\(percent)% source=\(payload.source ?? "notification")")
        }

        debugAutoParkingStatus = "AutoParking • notif ouverte, confirmation prête"
    }

    private func restorePersistedPendingAutoParkingStateIfNeeded() {
        if pendingAutoParkingConfirmation == nil,
           let restoredConfirmation = loadPersistedPendingAutoParkingSnapshot(
            forKey: Self.pendingAutoParkingConfirmationDefaultsKey
           ) {
            setPendingAutoParkingConfirmation(restoredConfirmation)
            resetAutoParkingWalkAwayTracking()
            debugAutoParkingStatus = "AutoParking • proposition restaurée"
            return
        }

        if pendingAutoParkingNotificationDetection == nil,
           let restoredDetection = loadPersistedPendingAutoParkingSnapshot(
            forKey: Self.pendingAutoParkingDetectionDefaultsKey
           ) {
            setPendingAutoParkingNotificationDetection(restoredDetection)
            resetAutoParkingWalkAwayTracking()
            debugAutoParkingStatus = "AutoParking détecté • proposition en attente"
        }
    }

    private func persistPendingAutoParkingNotificationDetection(_ detection: AutoParkingDetectionSnapshot) {
        persistPendingAutoParkingSnapshot(detection, forKey: Self.pendingAutoParkingDetectionDefaultsKey)
    }

    private func persistPendingAutoParkingConfirmation(_ detection: AutoParkingDetectionSnapshot) {
        persistPendingAutoParkingSnapshot(detection, forKey: Self.pendingAutoParkingConfirmationDefaultsKey)
    }

    private func persistPendingAutoParkingSnapshot(_ detection: AutoParkingDetectionSnapshot, forKey key: String) {
        guard let data = try? JSONEncoder().encode(PersistedAutoParkingSnapshot(snapshot: detection)) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func loadPersistedPendingAutoParkingSnapshot(forKey key: String) -> AutoParkingDetectionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let payload = try? JSONDecoder().decode(PersistedAutoParkingSnapshot.self, from: data) else {
            return nil
        }
        return payload.snapshot
    }

    private func clearPersistedPendingAutoParkingState() {
        clearPersistedPendingAutoParkingNotificationDetection()
        UserDefaults.standard.removeObject(forKey: Self.pendingAutoParkingConfirmationDefaultsKey)
    }

    private func clearPersistedPendingAutoParkingNotificationDetection() {
        UserDefaults.standard.removeObject(forKey: Self.pendingAutoParkingDetectionDefaultsKey)
    }

    private func restorePendingCarPlayDisconnectPromptIfNeeded() {
        guard pendingCarPlayDisconnectPrompt == nil,
              let payload = CarPlayDisconnectNotificationPayloadStore.consume() else {
            return
        }

        pendingCarPlayDisconnectPrompt = payload
    }

    private func restorePendingCarPlayDisconnectDirectSaveIfNeeded() {
        if CarPlayDisconnectNotificationPayloadStore.consumeSaveRequested() {
            pendingCarPlayDisconnectDirectSave = true
        }
    }

    func dismissPendingCarPlayDisconnectPrompt() {
        pendingCarPlayDisconnectPrompt = nil
    }

    func consumePendingCarPlayDisconnectDirectSave() {
        pendingCarPlayDisconnectDirectSave = false
    }

    private func scheduleAutoParkingConfirmationNotification(for detection: AutoParkingDetectionSnapshot) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await currentNotificationAuthorizationStatus(center: center)

        switch status {
        case .denied:
            return false
        case .notDetermined:
            let granted = await requestNotificationAuthorization(center: center)
            if !granted { return false }
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            return false
        }

        let userInfo: [AnyHashable: Any] = [
            AutoParkingNotificationPayloadStore.latitudeUserInfoKey: detection.coordinate.latitude,
            AutoParkingNotificationPayloadStore.longitudeUserInfoKey: detection.coordinate.longitude,
            AutoParkingNotificationPayloadStore.confidenceUserInfoKey: detection.confidence,
            AutoParkingNotificationPayloadStore.sourceUserInfoKey: detection.triggerSource
        ]

        let title = "Parking detected".psLocalized
        let confidence = Int((detection.confidence * 100).rounded())
        let body = String(format: "You are walking away. Did you park your car? (%d%%)".psLocalized, confidence)

        AutoParkingNotificationPayloadStore.store(title: title, body: body, userInfo: userInfo)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = AutoParkingNotificationPayloadStore.threadIdentifier
        content.userInfo = userInfo

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let identifier = "parkspot.auto-parking.confirmation.\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        return await withCheckedContinuation { continuation in
            center.add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func currentNotificationAuthorizationStatus(center: UNUserNotificationCenter) async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func requestNotificationAuthorization(center: UNUserNotificationCenter) async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func scheduleFrequentZoneNotification(for zone: FrequentZone) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await currentNotificationAuthorizationStatus(center: center)

        switch status {
        case .denied:
            return false
        case .notDetermined:
            let granted = await requestNotificationAuthorization(center: center)
            if !granted { return false }
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            return false
        }

        let identifier = "parkspot.frequent-zone.\(zone.id.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        let cleanName = zone.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = UNMutableNotificationContent()
        content.title = "Frequent zone detected".psLocalized
        content.body = cleanName.isEmpty || cleanName == "Zone fréquente" || cleanName == "Frequent zone"
            ? "You have arrived in one of your frequent zones.".psLocalized
            : String(format: "You have arrived in your frequent zone \"%@\".".psLocalized, cleanName)
        content.sound = .default
        content.threadIdentifier = "parkspot.frequent-zone"
        content.userInfo = [
            "zoneId": zone.id.uuidString,
            "zoneName": cleanName
        ]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        return await withCheckedContinuation { continuation in
            center.add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func consumeLocationSample(_ sample: LocationSample) {
        updateMapUserCoordinate(with: sample)
        guard shouldAcceptLocationSample(sample) else { return }

        let previousAcceptedSample = lastAcceptedLocationSample

        lastAcceptedLocationSample = sample
        userCoordinate = sample.coordinate
        userLocationAccuracy = sample.accuracy > 0 ? sample.accuracy : nil
        refreshParkingRiskAssessment(for: sample.coordinate)
        evaluateFrequentZoneNotificationIfNeeded(with: sample)
        syncWatchDistanceIfNeeded(with: sample)
        evaluateAutoParkingNotificationTriggerIfNeeded(with: sample, previousSample: previousAcceptedSample)
        evaluateSmartAwayFromCarIfNeeded(with: sample)
    }

    private func updateMapUserCoordinate(with sample: LocationSample) {
        guard sample.accuracy >= 0, sample.coordinate.isValidGeoCoordinate else { return }

        guard let lastMapLocationSample else {
            self.lastMapLocationSample = sample
            mapUserCoordinate = sample.coordinate
            return
        }

        let previous = CLLocation(
            latitude: lastMapLocationSample.coordinate.latitude,
            longitude: lastMapLocationSample.coordinate.longitude
        )
        let current = CLLocation(
            latitude: sample.coordinate.latitude,
            longitude: sample.coordinate.longitude
        )

        let movedDistance = previous.distance(from: current)
        let elapsed = sample.date.timeIntervalSince(lastMapLocationSample.date)
        let accuracyImproved =
            sample.accuracy > 0
            && lastMapLocationSample.accuracy > 0
            && sample.accuracy + 4 < lastMapLocationSample.accuracy

        let movementUpdate = movedDistance >= 0.75 || (movedDistance >= 0.25 && elapsed >= 0.75)
        guard movementUpdate || accuracyImproved else { return }

        self.lastMapLocationSample = sample
        mapUserCoordinate = sample.coordinate
    }

    private func evaluateFrequentZoneNotificationIfNeeded(with sample: LocationSample) {
        guard hasFrequentZonesAccess,
              activeSession == nil,
              let userId,
              sample.accuracy > 0,
              sample.accuracy <= frequentZoneNotificationMaximumAccuracyMeters,
              let frequentZone = frequentZoneService.bestZone(for: sample.coordinate, userId: userId) else {
            lastFrequentZoneNotificationZoneId = nil
            return
        }

        guard lastFrequentZoneNotificationZoneId != frequentZone.id else { return }
        lastFrequentZoneNotificationZoneId = frequentZone.id

        Task { [weak self] in
            guard let self else { return }
            let scheduled = await self.scheduleFrequentZoneNotification(for: frequentZone)
            await MainActor.run {
                self.debugAutoParkingStatus = scheduled
                    ? "Frequent zone detected • notification sent"
                    : "Frequent zone detected • in-app only"
            }
        }
    }

    private func evaluateAutoParkingNotificationTriggerIfNeeded(
        with sample: LocationSample,
        previousSample: LocationSample?
    ) {
        guard activeSession == nil else {
            pendingAutoParkingNotificationDetection = nil
            temporaryAutoParkingDetectionCoordinate = nil
            resetAutoParkingWalkAwayTracking()
            clearPersistedPendingAutoParkingState()
            return
        }
        guard pendingAutoParkingConfirmation == nil else { return }
        guard let detection = pendingAutoParkingNotificationDetection else { return }
        guard !isAutoParkingNotificationScheduling else { return }
        guard sample.accuracy > 0, sample.accuracy <= 55 else {
            resetAutoParkingWalkAwayTracking()
            return
        }

        let detectionCoordinateChanged = {
            guard let last = lastAutoParkingWalkAwayDetectionCoordinate else { return true }
            return abs(last.latitude - detection.coordinate.latitude) > 0.000_001
                || abs(last.longitude - detection.coordinate.longitude) > 0.000_001
        }()
        if detectionCoordinateChanged {
            resetAutoParkingWalkAwayTracking()
            lastAutoParkingWalkAwayDetectionCoordinate = detection.coordinate
        }

        let decision = autoParkingWalkAwayConfirmationPolicy.evaluate(
            detection: detection,
            sample: sample,
            previousSample: previousSample,
            previousDistance: lastAutoParkingWalkAwayDistance
        )

        switch decision.action {
        case .clearCandidate(let reason):
            clearPendingAutoParkingNotificationDetection(reason: reason)
            return
        case .resetProgress:
            resetAutoParkingWalkAwayTracking()
            return
        case .waiting:
            return
        case .countProgress:
            break
        }

        let distanceFromParked = decision.distanceFromParked
        lastAutoParkingWalkAwayDistance = distanceFromParked
        autoParkingWalkAwayStreak += 1
        guard autoParkingWalkAwayStreak >= 3 else { return }

        isAutoParkingNotificationScheduling = true
        Task { [weak self] in
            guard let self else { return }
            let scheduled = await self.scheduleAutoParkingConfirmationNotification(for: detection)

            await MainActor.run {
                self.isAutoParkingNotificationScheduling = false

                guard self.pendingAutoParkingNotificationDetection?.coordinate == detection.coordinate else {
                    return
                }

                self.pendingAutoParkingNotificationDetection = nil
                self.temporaryAutoParkingDetectionCoordinate = nil
                self.resetAutoParkingWalkAwayTracking()
                self.clearPersistedPendingAutoParkingNotificationDetection()

                if !scheduled {
                    self.setPendingAutoParkingConfirmation(detection)
                    self.debugAutoParkingStatus =
                        "AutoParking détecté • notif indisponible, confirmation affichée dans l'app"
                    return
                }

                if AppConfig.isDebugLoggingEnabled {
                    let percent = Int((detection.confidence * 100).rounded())
                    let dStr = distanceFromParked.isFinite ? "\(Int(distanceFromParked.rounded()))" : "inf"
                    print("[AutoParking] notification queued confidence=\(percent)% source=\(detection.triggerSource) distance=\(dStr)m")
                }

                let dBodyStr = distanceFromParked.isFinite ? " (\(Int(distanceFromParked.rounded()))m)" : ""
                self.debugAutoParkingStatus =
                    "AutoParking détecté • notif envoyée après éloignement\(dBodyStr)"
            }
        }
    }

    private func clearPendingAutoParkingNotificationDetection(reason: String) {
        pendingAutoParkingNotificationDetection = nil
        if pendingAutoParkingConfirmation == nil {
            temporaryAutoParkingDetectionCoordinate = nil
        }
        resetAutoParkingWalkAwayTracking()
        clearPersistedPendingAutoParkingNotificationDetection()
        debugAutoParkingStatus = "AutoParking candidature annulée • \(reason)"
    }

    private func resetAutoParkingWalkAwayTracking() {
        autoParkingWalkAwayStreak = 0
        lastAutoParkingWalkAwayDistance = nil
        lastAutoParkingWalkAwayDetectionCoordinate = nil
    }

    private func evaluateSmartAwayFromCarIfNeeded(with sample: LocationSample) {
        guard isSmartAwayAlertEnabled else { return }
        guard let session = activeSession, session.endTime == nil else { return }
        guard sample.accuracy > 0, sample.accuracy <= smartAwayMaximumAcceptedAccuracyMeters else { return }

        let parked = CLLocation(latitude: session.coordinate.latitude, longitude: session.coordinate.longitude)
        let current = CLLocation(latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude)
        let distanceFromCar = current.distance(from: parked)
        let previousDistance = lastSmartAwayDistanceMeters
        lastSmartAwayDistanceMeters = distanceFromCar

        let threshold = max(autoDepartureRadius * 0.72, 120)
        guard distanceFromCar >= threshold else { return }

        if let previousDistance,
           distanceFromCar <= previousDistance + 8 {
            return
        }

        guard shouldEvaluateSmartAway(with: sample.coordinate, now: sample.date) else { return }
        triggerSmartAwayAlertIfNeeded(distanceMeters: distanceFromCar, source: "location-distance")
    }

    private func shouldAcceptLocationSample(_ sample: LocationSample) -> Bool {
        guard sample.accuracy >= 0 else { return false }
        guard let lastAcceptedLocationSample else { return true }

        let previous = CLLocation(
            latitude: lastAcceptedLocationSample.coordinate.latitude,
            longitude: lastAcceptedLocationSample.coordinate.longitude
        )
        let current = CLLocation(
            latitude: sample.coordinate.latitude,
            longitude: sample.coordinate.longitude
        )

        let movedDistance = previous.distance(from: current)
        if movedDistance >= 12 {
            return true
        }

        if sample.accuracy > 0, lastAcceptedLocationSample.accuracy > 0 {
            let improvedByMargin = sample.accuracy + 15 < lastAcceptedLocationSample.accuracy
            let improvedByRatio = sample.accuracy <= lastAcceptedLocationSample.accuracy * 0.7
            if improvedByMargin || improvedByRatio {
                return true
            }
        }

        return sample.date.timeIntervalSince(lastAcceptedLocationSample.date) >= 4
    }

    private func startLocationUpdatesIfNeeded() {
        guard !isLocationUpdating else { return }
        isLocationUpdating = true
        locationService.requestTemporaryFullAccuracyIfNeeded()
        locationService.startUpdating()
        applyForegroundLocationModeIfUpdating()
    }

    private func stopLocationUpdatesIfNeeded() {
        guard isLocationUpdating else { return }
        guard !shouldMonitorAutoParking else { return }
        isLocationUpdating = false
        locationService.stopUpdating()
    }

    private func applyForegroundLocationModeIfUpdating() {
        guard isLocationUpdating, isAppActive else { return }
        locationService.setPreferredLocationMode(activeSession == nil ? .balanced : .precisionNavigation)
    }

    var formattedDistance: String {
        guard let d = distanceMetersToCar() else { return "--" }
        let measurement = Measurement(value: d, unit: UnitLength.meters)
        let formatter = MeasurementFormatter()
        formatter.locale = .current
        formatter.unitStyle = .short
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = d < 1000 ? 0 : 1
        return formatter.string(from: measurement)
    }

    var estimatedWalkTime: String {
        guard let d = distanceMetersToCar() else { return "--" }
        let min = Int((d / 80).rounded(.up))
        return min < 1 ? "< 1 min" : "\(min) min"
    }

    /// Retourne la distance en mètres entre l'utilisateur et la voiture active.
    private func distanceMetersToCar() -> Double? {
        guard let user = userCoordinate, let car = activeSession?.coordinate else { return nil }
        return haversine(from: user, to: car)
    }

    private func haversine(from a: Coordinate, to b: Coordinate) -> Double {
        let R = 6371000.0
        let lat1 = a.latitude  * .pi / 180
        let lat2 = b.latitude  * .pi / 180
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat/2) * sin(dLat/2) + cos(lat1) * cos(lat2) * sin(dLon/2) * sin(dLon/2)
        return R * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    private var isPowerConstrained: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.isLowPowerModeEnabled
            || processInfo.thermalState == .serious
            || processInfo.thermalState == .critical
    }

    private func cancelPendingSmartAwayNotifications() {
        let prefix = "parkspot.smart-away."
        let threadIdentifier = "parkspot.smart-away"

        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let identifiers = requests
                .filter {
                    $0.identifier.hasPrefix(prefix)
                        || $0.content.threadIdentifier == threadIdentifier
                }
                .map(\.identifier)

            guard !identifiers.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        }

        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let identifiers = notifications
                .filter {
                    $0.request.identifier.hasPrefix(prefix)
                        || $0.request.content.threadIdentifier == threadIdentifier
                }
                .map { $0.request.identifier }

            guard !identifiers.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
}

enum PredictionConfidenceTier {
    case high
    case medium
    case low
}

extension Notification.Name {
    static let intelligenceLearningDidReset = Notification.Name("parkspot.intelligenceLearningDidReset")
    static let autoParkingDebugDetectionInjected = Notification.Name("parkspot.autoParkingDebugDetectionInjected")
    static let autoParkingSettingsDidChange = Notification.Name("parkspot.autoParkingSettingsDidChange")
}

enum IntelligenceResetUserInfoKey {
    static let userId = "userId"
}
