import UIKit
import UserNotifications
import CarPlay
import CoreLocation

struct SmartAwayNotificationPayload {
    let title: String
    let body: String
    let source: String?
}

enum SmartAwayNotificationPayloadStore {
    static let sourceUserInfoKey = "parkspot.smartAway.source"
    private static let defaultsKey = "parkspot.smartAway.pendingPayload.v1"
    private static let titleKey = "title"
    private static let bodyKey = "body"
    private static let sourceKey = "source"

    static func store(title: String, body: String, source: String?) {
        var payload: [String: String] = [
            titleKey: title,
            bodyKey: body
        ]
        if let source {
            payload[sourceKey] = source
        }
        UserDefaults.standard.set(payload, forKey: defaultsKey)
    }

    static func consume() -> SmartAwayNotificationPayload? {
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        guard let payload = UserDefaults.standard.dictionary(forKey: defaultsKey) else {
            return nil
        }

        let title = payload[titleKey] as? String ?? ""
        let body = payload[bodyKey] as? String ?? ""
        let source = payload[sourceKey] as? String
        guard !title.isEmpty || !body.isEmpty else { return nil }
        return SmartAwayNotificationPayload(title: title, body: body, source: source)
    }
}
