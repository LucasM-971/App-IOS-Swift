import UIKit
import UserNotifications
import CarPlay
import CoreLocation

struct AutoParkingNotificationPayload {
    let title: String
    let body: String
    let coordinate: Coordinate
    let confidence: Double
    let source: String?
}

enum AutoParkingNotificationPayloadStore {
    static let threadIdentifier = "parkspot.auto-parking.confirmation"
    static let sourceUserInfoKey = "parkspot.autoParking.source"
    static let latitudeUserInfoKey = "parkspot.autoParking.latitude"
    static let longitudeUserInfoKey = "parkspot.autoParking.longitude"
    static let confidenceUserInfoKey = "parkspot.autoParking.confidence"

    private static let defaultsKey = "parkspot.autoParking.pendingPayload.v1"
    private static let titleKey = "title"
    private static let bodyKey = "body"
    private static let sourceKey = "source"
    private static let latitudeKey = "latitude"
    private static let longitudeKey = "longitude"
    private static let confidenceKey = "confidence"

    static func store(title: String, body: String, userInfo: [AnyHashable: Any]) {
        let latitude = userInfo[latitudeUserInfoKey] as? Double
        let longitude = userInfo[longitudeUserInfoKey] as? Double
        let confidence = userInfo[confidenceUserInfoKey] as? Double
        let source = userInfo[sourceUserInfoKey] as? String

        guard let latitude, let longitude else { return }

        var payload: [String: Any] = [
            titleKey: title,
            bodyKey: body,
            latitudeKey: latitude,
            longitudeKey: longitude,
            confidenceKey: confidence ?? 0
        ]

        if let source {
            payload[sourceKey] = source
        }

        UserDefaults.standard.set(payload, forKey: defaultsKey)
    }

    static func consume() -> AutoParkingNotificationPayload? {
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        guard let payload = UserDefaults.standard.dictionary(forKey: defaultsKey) else {
            return nil
        }

        guard let latitude = payload[latitudeKey] as? Double,
              let longitude = payload[longitudeKey] as? Double else {
            return nil
        }

        let title = payload[titleKey] as? String ?? ""
        let body = payload[bodyKey] as? String ?? ""
        let confidence = payload[confidenceKey] as? Double ?? 0
        let source = payload[sourceKey] as? String

        return AutoParkingNotificationPayload(
            title: title,
            body: body,
            coordinate: Coordinate(latitude: latitude, longitude: longitude),
            confidence: confidence,
            source: source
        )
    }
}
