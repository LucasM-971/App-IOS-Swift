// DIContainer.swift
// Lightweight dependency injection – assembles and owns all service instances
// Use constructor injection in ViewModels/UseCases; container only at composition root

import Foundation
import CoreLocation
import Combine

// MARK: - Intelligence Models/Services (inlined for target availability)

final class DIContainer {

    // MARK: – Singleton composition root
    static let shared = DIContainer()
    private init() {}

    // MARK: – Core Services (lazy singletons)
    lazy var keychainService: KeychainServiceProtocol = KeychainService()

    lazy var encryptionService: EncryptionService = EncryptionService(keychain: keychainService)

    lazy var networkClient: NetworkClient = NetworkClient(keychain: keychainService)
    lazy var networkReachabilityMonitor: NetworkReachabilityMonitor = NetworkReachabilityMonitor()

    // MARK: – Data Sources
    lazy var localParkingDataSource: LocalParkingDataSource =
        LocalParkingDataSource(encryption: encryptionService)

    lazy var remoteParkingDataSource: RemoteParkingDataSource =
        RemoteParkingDataSource(network: networkClient)

    lazy var remoteFrequentZoneDataSource: RemoteFrequentZoneDataSource =
        RemoteFrequentZoneDataSource(network: networkClient)

    // MARK: – Repositories (protocol types for testability)
    private lazy var parkingRepositoryImpl: ParkingRepository =
        ParkingRepository(
            local: localParkingDataSource,
            remote: remoteParkingDataSource,
            reachability: networkReachabilityMonitor
        )

    lazy var parkingRepository: ParkingRepositoryProtocol = parkingRepositoryImpl

    lazy var authRepository: AuthRepositoryProtocol =
        AuthRepository(network: networkClient, keychain: keychainService)

    // MARK: – Services
    lazy var locationService: LocationServiceProtocol = LocationService()

    lazy var deadReckoningService: DeadReckoningService = DeadReckoningService(
        headingPublisher: locationService.currentHeading
    )

    lazy var notificationService: NotificationServiceProtocol = NotificationService()

    lazy var photoStorage: PhotoStorageProtocol =
        PhotoStorageService(encryption: encryptionService)

    lazy var carBluetoothService = CarBluetoothService()

    // MARK: – Intelligence Services
    lazy var predictionService = PredictionService()
    lazy var frequentZoneService = FrequentZoneService(remoteDataSource: remoteFrequentZoneDataSource)
    lazy var departureDetectionService = DepartureDetectionService()
    lazy var calendarService = CalendarService()
    lazy var riskZoneService = RiskZoneService()

    // MARK: – Use Cases (factory methods – new instance each time)
    func makeSaveParkingUseCase() -> SaveParkingUseCase {
        SaveParkingUseCase(
            parkingRepo: parkingRepository,
            locationService: locationService,
            notificationService: notificationService,
            lastKnownLocationStore: .shared,
            reachability: networkReachabilityMonitor,
            photoStorage: photoStorage
        )
    }

    func makeEndParkingUseCase() -> EndParkingUseCase {
        EndParkingUseCase(
            parkingRepo: parkingRepository,
            notificationService: notificationService,
            photoStorage: photoStorage
        )
    }

    func makeFetchActiveSessionUseCase() -> FetchActiveSessionUseCase {
        FetchActiveSessionUseCase(parkingRepo: parkingRepository)
    }

    func makeFetchHistoryUseCase() -> FetchHistoryUseCase {
        FetchHistoryUseCase(parkingRepo: parkingRepository)
    }

    func makeDeleteUserDataUseCase() -> DeleteUserDataUseCase {
        DeleteUserDataUseCase(
            parkingRepo: parkingRepository,
            authRepo: authRepository,
            keychain: keychainService,
            photoStorage: photoStorage
        )
    }
}
