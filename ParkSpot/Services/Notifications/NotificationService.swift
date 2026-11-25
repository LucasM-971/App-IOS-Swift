// NotificationService.swift
// Schedules local UNUserNotification alerts for parking expiry

import Foundation
import UserNotifications

final class NotificationService: NotificationServiceProtocol {

    private let center = UNUserNotificationCenter.current()
    private let legacyIdentifiers = ["parking_30min", "parking_10min", "parking_expired"]
    private let warningSlotUserInfoKey = "parkspot.parking.warning.slot"
    private var lastSyncedPreferencesSignature: String?

    init() {
        cleanupLegacyParkingAlerts()
        syncPendingAlertsWithPreferences()
    }

    // MARK: – Schedule alerts: configurable warnings + expiry (0 min)
    func scheduleAlert(for session: ParkingSession) async throws {
        cleanupLegacyParkingAlerts()
        guard let maxDuration = session.maxDuration else { return }
        removeKnownAlerts(for: session.id)

        let expiry = session.startTime.addingTimeInterval(maxDuration)
        let warning1Mins = Int(AppConfig.parkingExpiryWarning1 / 60)
        let warning2Mins = Int(AppConfig.parkingExpiryWarning2 / 60)

        var alerts: [(slot: Int, warning: TimeInterval, message: String)] = []
        if AppConfig.isParkingWarning1Enabled {
            alerts.append((
                slot: 1,
                warning: AppConfig.parkingExpiryWarning1,
                message: String(format: "⚠️ Your parking session expires in %d minutes.".psLocalized, warning1Mins)
            ))
        }
        if AppConfig.isParkingWarning2Enabled {
            alerts.append((
                slot: 2,
                warning: AppConfig.parkingExpiryWarning2,
                message: String(format: "🚨 Your parking session expires in %d minutes!".psLocalized, warning2Mins)
            ))
        }
        alerts.append((
            slot: 0,
            warning: 0,
            message: "⏰ The timer has ended. Your parking session has expired.".psLocalized
        ))

        for alert in alerts {
            let warning = alert.warning
            let triggerDate = expiry.addingTimeInterval(-warning)
            guard triggerDate > .now else { continue }

            let content         = UNMutableNotificationContent()
            content.title       = "MosiMap"
            content.body        = alert.message
            content.sound       = .default
            content.badge       = 1
            content.threadIdentifier = session.id.uuidString
            content.userInfo[warningSlotUserInfoKey] = alert.slot

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: triggerDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let identifier = "\(session.id.uuidString)-\(Int(warning))"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

            try await center.add(request)
        }
    }

    // MARK: – Cancel alerts for a session
    func cancelAlert(for sessionId: UUID) {
        let sessionKey = sessionId.uuidString

        // Fast path: remove known identifiers used by this service.
        let knownIdentifiers = parkingAlertIdentifiers(for: sessionId) + legacyIdentifiers
        if !knownIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: knownIdentifiers)
            center.removeDeliveredNotifications(withIdentifiers: knownIdentifiers)
        }

        // Fallback: remove any request linked by threadIdentifier or legacy prefix.
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let identifiers = requests
                .filter {
                    $0.content.threadIdentifier == sessionKey ||
                    $0.identifier.hasPrefix("\(sessionKey)-")
                }
                .map(\.identifier)
            guard !identifiers.isEmpty else { return }
            self.center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }

        center.getDeliveredNotifications { [weak self] notifications in
            guard let self else { return }
            let identifiers = notifications
                .filter {
                    $0.request.content.threadIdentifier == sessionKey ||
                    $0.request.identifier.hasPrefix("\(sessionKey)-")
                }
                .map { $0.request.identifier }
            guard !identifiers.isEmpty else { return }
            self.center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    func syncPendingAlertsWithPreferences() {
        let preferenceSignature = makePreferencesSignature()
        if preferenceSignature == lastSyncedPreferencesSignature {
            return
        }
        lastSyncedPreferencesSignature = preferenceSignature

        let disabledSlots = disabledWarningSlots()
        let disabledSuffixes = disabledWarningIdentifierSuffixes()
        guard !disabledSlots.isEmpty || !disabledSuffixes.isEmpty else { return }

        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let identifiers = requests
                .filter { request in
                    self.isParkingAlert(threadIdentifier: request.content.threadIdentifier) &&
                    self.shouldRemoveAlert(
                        identifier: request.identifier,
                        userInfo: request.content.userInfo,
                        disabledSlots: disabledSlots,
                        disabledSuffixes: disabledSuffixes
                    )
                }
                .map(\.identifier)
            guard !identifiers.isEmpty else { return }
            self.center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }

        center.getDeliveredNotifications { [weak self] notifications in
            guard let self else { return }
            let identifiers = notifications
                .map(\.request)
                .filter { request in
                    self.isParkingAlert(threadIdentifier: request.content.threadIdentifier) &&
                    self.shouldRemoveAlert(
                        identifier: request.identifier,
                        userInfo: request.content.userInfo,
                        disabledSlots: disabledSlots,
                        disabledSuffixes: disabledSuffixes
                    )
                }
                .map(\.identifier)
            guard !identifiers.isEmpty else { return }
            self.center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    private func cleanupLegacyParkingAlerts() {
        center.removePendingNotificationRequests(withIdentifiers: legacyIdentifiers)
        center.removeDeliveredNotifications(withIdentifiers: legacyIdentifiers)
    }

    private func removeKnownAlerts(for sessionId: UUID) {
        let identifiers = parkingAlertIdentifiers(for: sessionId) + legacyIdentifiers
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func parkingAlertIdentifiers(for sessionId: UUID) -> [String] {
        let sessionKey = sessionId.uuidString
        let warnings: [TimeInterval] = [
            AppConfig.parkingExpiryWarning1,
            AppConfig.parkingExpiryWarning2,
            0
        ]

        var identifiers = Set<String>()
        for warning in warnings where warning >= 0 {
            identifiers.insert("\(sessionKey)-\(Int(warning))")
        }
        return Array(identifiers)
    }

    private func disabledWarningSlots() -> Set<Int> {
        var slots = Set<Int>()
        if !AppConfig.isParkingWarning1Enabled {
            slots.insert(1)
        }
        if !AppConfig.isParkingWarning2Enabled {
            slots.insert(2)
        }
        return slots
    }

    private func disabledWarningIdentifierSuffixes() -> Set<String> {
        var suffixes = Set<String>()
        if !AppConfig.isParkingWarning1Enabled {
            suffixes.insert("-\(Int(AppConfig.parkingExpiryWarning1))")
        }
        if !AppConfig.isParkingWarning2Enabled {
            suffixes.insert("-\(Int(AppConfig.parkingExpiryWarning2))")
        }
        return suffixes
    }

    private func isParkingAlert(threadIdentifier: String) -> Bool {
        UUID(uuidString: threadIdentifier) != nil
    }

    private func shouldRemoveAlert(
        identifier: String,
        userInfo: [AnyHashable: Any],
        disabledSlots: Set<Int>,
        disabledSuffixes: Set<String>
    ) -> Bool {
        if let slotNumber = userInfo[warningSlotUserInfoKey] as? NSNumber,
           disabledSlots.contains(slotNumber.intValue) {
            return true
        }
        return disabledSuffixes.contains(where: { identifier.hasSuffix($0) })
    }

    private func makePreferencesSignature() -> String {
        "\(AppConfig.isParkingWarning1Enabled)-\(AppConfig.isParkingWarning2Enabled)-\(Int(AppConfig.parkingExpiryWarning1))-\(Int(AppConfig.parkingExpiryWarning2))"
    }
}
