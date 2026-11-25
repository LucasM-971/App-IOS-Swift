// AppDelegate.swift
// Handles push-notification registration and deep links

import UIKit
import UserNotifications
import CarPlay
import CoreLocation

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerNotificationCategories()
        registerForPushNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let configuration = UISceneConfiguration(
                name: "CarPlay Configuration",
                sessionRole: connectingSceneSession.role
            )
            configuration.delegateClass = CarPlaySceneDelegate.self
            return configuration
        }

        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }

    // MARK: – Push Notifications
    private func registerForPushNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }

            case .notDetermined:
                // Best-effort silent opt-in on first launch (no blocking system prompt).
                center.requestAuthorization(options: [.provisional, .alert, .sound, .badge]) { granted, _ in
                    guard granted else { return }
                    DispatchQueue.main.async {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }

            case .denied:
                break

            @unknown default:
                break
            }
        }
    }

    private func registerNotificationCategories() {
        let saveAction = UNNotificationAction(
            identifier: CarPlayDisconnectNotificationCategory.saveActionIdentifier,
            title: "Oui".psLocalized,
            options: [.foreground]
        )
        let cancelAction = UNNotificationAction(
            identifier: CarPlayDisconnectNotificationCategory.cancelActionIdentifier,
            title: "Non".psLocalized,
            options: []
        )

        let carPlayCategory = UNNotificationCategory(
            identifier: CarPlayDisconnectNotificationCategory.identifier,
            actions: [saveAction, cancelAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([carPlayCategory])
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        NotificationCenter.default.post(name: .didReceiveDeviceToken, object: token)
    }
}

// MARK: – UNUserNotificationCenterDelegate
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let content = request.content
        if isSmartAwayNotification(content: content, identifier: request.identifier) {
            let source = content.userInfo[SmartAwayNotificationPayloadStore.sourceUserInfoKey] as? String
            SmartAwayNotificationPayloadStore.store(
                title: content.title,
                body: content.body,
                source: source
            )

            NotificationCenter.default.post(
                name: .smartAwayNotificationOpened,
                object: nil
            )
        } else if isAutoParkingNotification(content: content, identifier: request.identifier) {
            AutoParkingNotificationPayloadStore.store(
                title: content.title,
                body: content.body,
                userInfo: content.userInfo
            )
            NotificationCenter.default.post(
                name: .autoParkingNotificationOpened,
                object: nil
            )
        } else if isCarPlayDisconnectNotification(content: content, identifier: request.identifier) {
            if response.actionIdentifier == CarPlayDisconnectNotificationCategory.saveActionIdentifier {
                CarPlayDisconnectNotificationPayloadStore.markSaveRequested()
                NotificationCenter.default.post(
                    name: .carPlayDisconnectNotificationSaveRequested,
                    object: nil
                )
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                CarPlayDisconnectNotificationPayloadStore.store(title: content.title, body: content.body)
                NotificationCenter.default.post(
                    name: .carPlayDisconnectNotificationOpened,
                    object: nil
                )
            }
        }

        completionHandler()
    }

    private func isSmartAwayNotification(content: UNNotificationContent, identifier: String) -> Bool {
        if identifier.hasPrefix("parkspot.smart-away.") {
            return true
        }
        if content.threadIdentifier.hasPrefix("parkspot.smart-away") {
            return true
        }
        return false
    }

    private func isAutoParkingNotification(content: UNNotificationContent, identifier: String) -> Bool {
        if identifier.hasPrefix("parkspot.auto-parking.confirmation") {
            return true
        }
        if content.threadIdentifier == AutoParkingNotificationPayloadStore.threadIdentifier {
            return true
        }
        return false
    }

    private func isCarPlayDisconnectNotification(content: UNNotificationContent, identifier: String) -> Bool {
        if identifier.hasPrefix("parkspot.carplay.disconnect") {
            return true
        }
        if content.threadIdentifier == CarPlayDisconnectNotificationPayloadStore.threadIdentifier {
            return true
        }
        if let marker = content.userInfo[CarPlayDisconnectNotificationPayloadStore.markerUserInfoKey] as? Bool,
           marker {
            return true
        }
        return false
    }
}

extension Notification.Name {
    static let didReceiveDeviceToken = Notification.Name("didReceiveDeviceToken")
    static let smartAwayNotificationOpened = Notification.Name("parkspot.smartAwayNotificationOpened")
    static let autoParkingNotificationOpened = Notification.Name("parkspot.autoParkingNotificationOpened")
    static let carPlayDisconnectNotificationOpened = Notification.Name("parkspot.carPlayDisconnectNotificationOpened")
    static let carPlayDisconnectNotificationSaveRequested = Notification.Name("parkspot.carPlayDisconnectNotificationSaveRequested")
}
