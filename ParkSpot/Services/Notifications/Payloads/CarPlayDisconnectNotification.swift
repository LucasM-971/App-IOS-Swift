import UIKit
import UserNotifications
import CarPlay
import CoreLocation

struct CarPlayDisconnectNotificationPayload {
    let title: String
    let body: String
}

enum CarPlayDisconnectNotificationPayloadStore {
    static let threadIdentifier = "parkspot.carplay.disconnect"
    static let markerUserInfoKey = "parkspot.carplay.disconnect.marker"

    private static let defaultsKey = "parkspot.carplay.disconnect.pendingPayload.v1"
    private static let saveRequestedDefaultsKey = "parkspot.carplay.disconnect.pendingSaveRequested.v1"
    private static let titleKey = "title"
    private static let bodyKey = "body"

    static func store(title: String, body: String) {
        let payload: [String: String] = [
            titleKey: title,
            bodyKey: body
        ]
        UserDefaults.standard.set(payload, forKey: defaultsKey)
    }

    static func consume() -> CarPlayDisconnectNotificationPayload? {
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        guard let payload = UserDefaults.standard.dictionary(forKey: defaultsKey) else {
            return nil
        }

        let title = payload[titleKey] as? String ?? ""
        let body = payload[bodyKey] as? String ?? ""
        guard !title.isEmpty || !body.isEmpty else { return nil }

        return CarPlayDisconnectNotificationPayload(title: title, body: body)
    }

    static func markSaveRequested() {
        UserDefaults.standard.set(true, forKey: saveRequestedDefaultsKey)
    }

    static func consumeSaveRequested() -> Bool {
        defer { UserDefaults.standard.removeObject(forKey: saveRequestedDefaultsKey) }
        return UserDefaults.standard.bool(forKey: saveRequestedDefaultsKey)
    }
}

enum CarPlayDisconnectNotificationCategory {
    static let identifier = "parkspot.carplay.disconnect.category"
    static let saveActionIdentifier = "parkspot.carplay.disconnect.action.save"
    static let cancelActionIdentifier = "parkspot.carplay.disconnect.action.cancel"
}
