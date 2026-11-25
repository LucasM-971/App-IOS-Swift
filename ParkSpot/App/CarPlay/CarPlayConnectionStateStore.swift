import UIKit
import UserNotifications
import CarPlay
import CoreLocation

enum CarPlayConnectionStateStore {
    private static let defaultsKey = "parkspot.carplay.isConnected.v1"

    static func setConnected(_ isConnected: Bool) {
        UserDefaults.standard.set(isConnected, forKey: defaultsKey)
    }

    static var isConnected: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
