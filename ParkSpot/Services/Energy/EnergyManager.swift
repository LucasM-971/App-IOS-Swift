import SwiftUI
import AppIntents
import CoreLocation
import Combine
import UIKit

@MainActor
final class EnergyManager: ObservableObject {

    static let shared = EnergyManager()

    enum AppState {
        case background
        case foregroundIdle
        case mapBrowsing
        case activeGuidance
        case detection
    }

    @Published private(set) var currentState: AppState = .foregroundIdle

    private var isPowerConstrained: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.isLowPowerModeEnabled || processInfo.thermalState == .serious || processInfo.thermalState == .critical
    }

    private weak var location: EnergyLocationControlling?
    private weak var bluetooth: EnergyBluetoothControlling?
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(
        location: EnergyLocationControlling? = nil,
        bluetooth: EnergyBluetoothControlling? = nil
    ) {
        self.location = location
        self.bluetooth = bluetooth
        bindLifecycle()
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    func configure(
        location: EnergyLocationControlling?,
        bluetooth: EnergyBluetoothControlling?
    ) {
        self.location = location
        self.bluetooth = bluetooth
    }

    func transition(to state: AppState) {
        if currentState == state { return }
        currentState = state
        applyEnergyProfile(for: state)

#if DEBUG
        print("[Energy] state=\(String(describing: state))")
#endif
    }

    private func applyEnergyProfile(for state: AppState) {
        if isPowerConstrained {
            switch state {
            case .background:
                location?.setMode(.significant)
                bluetooth?.stopScan()
            case .foregroundIdle, .mapBrowsing, .detection:
                location?.setMode(.significant)
                bluetooth?.stopScan()
            case .activeGuidance:
                location?.setMode(.balanced)
                bluetooth?.startTimedScan(duration: 4)
            }
            return
        }

        switch state {
        case .background:
            location?.setMode(.significant)
            bluetooth?.stopScan()

        case .foregroundIdle:
            location?.setMode(.balanced)
            bluetooth?.stopScan()

        case .mapBrowsing:
            location?.setMode(.balanced)
            bluetooth?.stopScan()

        case .activeGuidance:
            location?.setMode(.navigation)
            bluetooth?.startTimedScan(duration: 10)

        case .detection:
            location?.setMode(.significant)
        }
    }

    private func bindLifecycle() {
        let center = NotificationCenter.default

        let backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.transition(to: .background)
            }
        }

        let foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.location?.restorePreviousMode()
            }
        }

        lifecycleObservers.append(backgroundObserver)
        lifecycleObservers.append(foregroundObserver)
    }
}
