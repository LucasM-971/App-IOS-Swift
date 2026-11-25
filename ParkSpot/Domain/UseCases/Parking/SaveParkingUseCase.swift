import Foundation
import Combine

final class SaveParkingUseCase {
    private static let fallbackLocationMaxAge: TimeInterval = 12 * 60 * 60

    private let parkingRepo: ParkingRepositoryProtocol
    private let locationService: LocationServiceProtocol
    private let notificationService: NotificationServiceProtocol
    private let widgetDataStore: ParkingWidgetDataStore
    private let lastKnownLocationStore: LastKnownLocationStore
    private let reachability: NetworkReachabilityMonitor?
    private let photoStorage: PhotoStorageProtocol

    init(
        parkingRepo: ParkingRepositoryProtocol,
        locationService: LocationServiceProtocol,
        notificationService: NotificationServiceProtocol,
        widgetDataStore: ParkingWidgetDataStore = .shared,
        lastKnownLocationStore: LastKnownLocationStore = .shared,
        reachability: NetworkReachabilityMonitor? = nil,
        photoStorage: PhotoStorageProtocol
    ) {
        self.parkingRepo = parkingRepo
        self.locationService = locationService
        self.notificationService = notificationService
        self.widgetDataStore = widgetDataStore
        self.lastKnownLocationStore = lastKnownLocationStore
        self.reachability = reachability
        self.photoStorage = photoStorage
    }

    func execute(
        userId: UUID,
        coordinate: Coordinate?,
        note: String?,
        parkingLevel: String?,
        maxDuration: TimeInterval?,
        zone: ParkingZone,
        photoData: Data? = nil,
        address: String? = nil,
        allowsPremiumWidgetSurfaces: Bool = false
    ) async throws -> ParkingSession {

        let resolvedCoordinate: Coordinate
        let isApproximate: Bool

        if let coordinate {
            resolvedCoordinate = coordinate
            isApproximate = false
        } else if let lastKnown = lastKnownLocationStore.load(maxAge: Self.fallbackLocationMaxAge) {
            resolvedCoordinate = lastKnown.coordinate
            isApproximate = true
        } else {
            throw SaveParkingUseCaseError.noLocationAvailable
        }

        let sessionId = UUID()
        
        // 1. Build initial session (instant)
        // Secondary data like photo and reverse-geocoded address will be updated in background.
        let session = ParkingSession(
            id: sessionId,
            userId: userId,
            coordinate: resolvedCoordinate,
            address: address, // Pre-resolved address from UI
            photoPath: nil,
            note: note,
            parkingLevel: parkingLevel,
            maxDuration: maxDuration,
            zone: zone,
            isApproximate: isApproximate
        )

        // 2. Persist local first (offline-first architecture ensures this is instant)
        let initialSaved = try await parkingRepo.save(session)

        if initialSaved.maxDuration != nil {
            try? await notificationService.scheduleAlert(for: initialSaved)
        }

        // 3. Heavy/External tasks in background
        Task { [
            widgetDataStore,
            locationService,
            reachability,
            photoStorage,
            parkingRepo,
            allowsPremiumWidgetSurfaces
        ] in
            
            // Background Address Resolution
            var finalAddress = address
            if finalAddress == nil && reachability?.isConnected != false {
                finalAddress = try? await locationService.reverseGeocode(resolvedCoordinate)
            }
            
            // Background Photo Save
            var finalPhotoPath: String? = nil
            if let photoData {
                finalPhotoPath = try? await photoStorage.save(imageData: photoData, for: sessionId)
            }
            
            // If we have updates, save them back to repo
            var updatedSession = initialSaved
            var needsUpdate = false
            if let finalAddress {
                updatedSession.address = finalAddress
                needsUpdate = true
            }
            if let finalPhotoPath {
                updatedSession.photoPath = finalPhotoPath
                needsUpdate = true
            }
            
            if needsUpdate {
                _ = try? await parkingRepo.save(updatedSession)
            }

            guard allowsPremiumWidgetSurfaces else {
                widgetDataStore.clear()
                if #available(iOS 16.2, *) {
                    await LiveActivityService.shared.endAllActivities()
                }
                return
            }

            widgetDataStore.save(session: updatedSession)

            if #available(iOS 16.2, *) {
                try? await LiveActivityService.shared.start(for: updatedSession)
            }
        }

        return initialSaved
    }
}

enum SaveParkingUseCaseError: LocalizedError {
    case noLocationAvailable

    var errorDescription: String? {
        switch self {
        case .noLocationAvailable:
            return "Aucune position GPS disponible (directe ou dernière connue).".psLocalized
        }
    }
}
