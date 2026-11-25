// ParkingLiveActivityAttributes.swift
// Shared ActivityAttributes for Dynamic Island and Live Activity Widget

import Foundation

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.2, *)
public struct ParkingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Adresse du stationnement (ex: "Rue de Rivoli")
        public let address: String
        /// Ville / quartier (ex: "Paris 1er")
        public let city: String
        /// true si un minuteur de stationnement est actif
        public let isTimerActive: Bool
        /// Date de fin du stationnement si minuteur actif
        public let endTime: Date?
        /// Date de début de la session
        public let startTime: Date
        /// Progression entre 0.0 et 1.0
        public let progressPercent: Double
        /// Niveau de parking (ex: "B2")
        public let parkingLevel: String?
        /// Repère texte (ex: "Place 45")
        public let note: String?

        public init(
            address: String,
            city: String,
            isTimerActive: Bool,
            endTime: Date?,
            startTime: Date,
            progressPercent: Double,
            parkingLevel: String? = nil,
            note: String? = nil
        ) {
            self.address = address
            self.city = city
            self.isTimerActive = isTimerActive
            self.endTime = endTime
            self.startTime = startTime
            self.progressPercent = progressPercent
            self.parkingLevel = parkingLevel
            self.note = note
        }

        // MARK: - Compatibilité legacy
        public var expiryDate: Date { endTime ?? startTime }
        public var timerActive: Bool { isTimerActive }
        public var remainingTimeFormatted: String {
            guard let endTime, isTimerActive else { return NSLocalizedString("Sans minuteur", comment: "") }
            let remaining = max(0, Int(endTime.timeIntervalSinceNow))
            let hours = remaining / 3600
            let minutes = (remaining % 3600) / 60
            return hours > 0 ? "\(hours)h \(minutes)min" : "\(minutes)min"
        }
        public var remainingTimeShort: String {
            guard let endTime, isTimerActive else { return "--" }
            let remaining = max(0, Int(endTime.timeIntervalSinceNow))
            let totalMinutes = remaining / 60
            return "\(totalMinutes)m"
        }
    }

    /// Identifiant unique de session (donnée statique)
    public let sessionId: UUID

    public init(sessionId: UUID) {
        self.sessionId = sessionId
    }
}

@available(iOS 16.2, *)
public typealias ParkingLiveActivityAttributes = ParkingActivityAttributes
#endif
