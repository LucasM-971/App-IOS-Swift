import Foundation
import CoreBluetooth
import Combine
import UIKit

struct CarBluetoothDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
}

enum CarBluetoothEvent: Equatable {
    case bluetoothUnavailable
    case bluetoothReady
    case carConnected(UUID)
    case carDisconnected(UUID)
}

protocol BluetoothMonitoringServiceProtocol {
    var events: AnyPublisher<CarBluetoothEvent, Never> { get }
    var selectedCarDeviceID: UUID? { get }

    func discoverNearbyDevices(timeout: TimeInterval)
    func selectCarDevice(id: UUID)
    func clearSelectedCarDevice()
    func startMonitoring()
    func stopMonitoring()
}

/// Module 1 - Surveillance BT orientée connexion/déconnexion, sans scan continu.
final class CarBluetoothService: NSObject, BluetoothMonitoringServiceProtocol {
    private enum Keys {
        static let selectedCarUUID = "parkspot.selected_car_bt_uuid"
    }

    private let central: CBCentralManager
    private let eventSubject = PassthroughSubject<CarBluetoothEvent, Never>()
    private let discoveredDevicesSubject = CurrentValueSubject<[CarBluetoothDevice], Never>([])

    private var discoveryTimer: Timer?
    private var discoveryTimerToken: UUID?
    private var isMonitoring = false
    private var discoveredById: [UUID: CarBluetoothDevice] = [:]
    private var appLifecycleCancellables = Set<AnyCancellable>()

    var events: AnyPublisher<CarBluetoothEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    var discoveredDevices: AnyPublisher<[CarBluetoothDevice], Never> {
        discoveredDevicesSubject.eraseToAnyPublisher()
    }

    var selectedCarDeviceID: UUID? {
        guard let value = UserDefaults.standard.string(forKey: Keys.selectedCarUUID) else { return nil }
        return UUID(uuidString: value)
    }

    override init() {
        central = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        central.delegate = self
        bindLifecycleEvents()
    }

    func discoverNearbyDevices(timeout: TimeInterval = 8) {
        startTimedScan(duration: timeout)
    }

    /// Scan BLE court et borné dans le temps.
    func startTimedScan(duration: TimeInterval = 10) {
        guard UIApplication.shared.applicationState == .active else {
#if DEBUG
            print("[BT] Scan bloqué — app en background")
#endif
            return
        }

        guard central.state == .poweredOn else {
            eventSubject.send(.bluetoothUnavailable)
            return
        }

        discoveredById.removeAll()
        discoveredDevicesSubject.send([])

        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        discoveryTimer?.invalidate()
        if let discoveryTimerToken {
            TimerRegistry.shared.unregister(discoveryTimerToken)
            self.discoveryTimerToken = nil
        }
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.central.stopScan()
        }
        if let discoveryTimer {
            discoveryTimerToken = TimerRegistry.shared.register(discoveryTimer)
        }
#if DEBUG
        print("[Energy][Bluetooth] timedScan=\(duration)s")
#endif
    }

    /// Arrête explicitement le scan sans arrêter le monitoring global.
    func stopScan() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        if let discoveryTimerToken {
            TimerRegistry.shared.unregister(discoveryTimerToken)
            self.discoveryTimerToken = nil
        }
        guard central.isScanning else { return }
        central.stopScan()
#if DEBUG
        print("[BT] Scan arrêté")
#endif
    }

    func selectCarDevice(id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: Keys.selectedCarUUID)
        if isMonitoring { startMonitoring() }
    }

    func clearSelectedCarDevice() {
        UserDefaults.standard.removeObject(forKey: Keys.selectedCarUUID)
        stopMonitoring()
    }

    func startMonitoring() {
        guard central.state == .poweredOn else {
            eventSubject.send(.bluetoothUnavailable)
            return
        }
        guard let selectedCarDeviceID else { return }

        isMonitoring = true

        // Pas de scan continu: tentative de liaison directe au périphérique déjà connu.
        let candidates = central.retrievePeripherals(withIdentifiers: [selectedCarDeviceID])
        candidates.forEach { central.connect($0, options: nil) }
    }

    func stopMonitoring() {
        isMonitoring = false
        stopScan()
    }
}

extension CarBluetoothService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if UIApplication.shared.applicationState != .active {
            stopScan()
        }

        switch central.state {
        case .poweredOn:
            eventSubject.send(.bluetoothReady)
            if isMonitoring { startMonitoring() }
        default:
            eventSubject.send(.bluetoothUnavailable)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue
        guard rssi > -80 else { return }

        guard let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }

        let device = CarBluetoothDevice(id: peripheral.identifier, name: name)
        discoveredById[device.id] = device
        discoveredDevicesSubject.send(discoveredById.values.sorted { $0.name < $1.name })

        // Connexion uniquement sur signal fort et périphérique attendu.
        if isMonitoring,
           let selectedCarDeviceID,
           peripheral.identifier == selectedCarDeviceID,
           rssi > -60 {
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == selectedCarDeviceID else { return }
        eventSubject.send(.carConnected(peripheral.identifier))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == selectedCarDeviceID else { return }
        eventSubject.send(.carDisconnected(peripheral.identifier))

        guard isMonitoring, central.state == .poweredOn else { return }
        central.connect(peripheral, options: nil)
    }
}

private extension CarBluetoothService {
    /// Déclenche un scan court à l'entrée au foreground, sans timer permanent.
    func bindLifecycleEvents() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.stopScan()
            }
            .store(in: &appLifecycleCancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isMonitoring else { return }
                self.startTimedScan(duration: 8)
            }
            .store(in: &appLifecycleCancellables)
    }
}
