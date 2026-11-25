import SwiftUI
import AppIntents
import CoreLocation
import Combine
import UIKit

protocol EnergyLocationControlling: AnyObject {
    func setMode(_ mode: LocationMode)
    func restorePreviousMode()
}

protocol EnergyBluetoothControlling: AnyObject {
    func startTimedScan(duration: TimeInterval)
    func stopScan()
}

extension LocationService: EnergyLocationControlling {}

extension CarBluetoothService: EnergyBluetoothControlling {}
