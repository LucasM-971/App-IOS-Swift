// SharedParkingSession.swift
// Modèle de session partagé entre l'app et les widgets.

import Foundation

struct SharedParkingSession: Codable {
    let id: String
    let address: String
    let zone: String
    let parkingLevel: String?
    let note: String?
    let startDate: Date
    let endDate: Date
    let userLatitude: Double
    let userLongitude: Double
    let maxDurationMinutes: Int?
    let hasTimer: Bool

    var formattedDistance: String {
        // Distance will be calculated in the widget based on current location
        "---"
    }

    var remainingTimeFormatted: String {
        guard hasTimer else { return NSLocalizedString("Sans minuteur", comment: "") }
        let remaining = max(0, endDate.timeIntervalSinceNow)
        guard remaining.isFinite else { return "---" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)min" : "\(minutes)min"
    }
}
