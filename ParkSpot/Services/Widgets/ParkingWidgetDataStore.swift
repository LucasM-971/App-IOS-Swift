import Foundation
import WidgetKit

// MARK: - ParkingWidgetData (legacy iOS widget)
/// Ancien modèle de données du widget iOS, conservé pour compatibilité.
struct ParkingWidgetData: Codable {
    let address: String
    let city: String?
    let startTime: Date?
    let endTime: Date?
    let distanceText: String?
    let parkingLevel: String?
    let note: String?
}

// MARK: - ParkingWidgetDataStore
/// Store historique iOS + pont vers le nouveau `WatchParkingDataStore`.
final class ParkingWidgetDataStore {
    static let shared = ParkingWidgetDataStore()

    /// Clé historique du widget iOS.
    private let legacyKey = "active_parking_widget_data"
    /// App Group historique, gardé pour migration douce.
    private let legacyDefaults = UserDefaults(suiteName: "group.com.parkspot.app")

    private init() {}

    /// Enregistre une session active pour les widgets iOS historiques et la Watch.
    func save(session: ParkingSession, distanceText: String? = nil) {
        let cleanedLevel = sanitizeTechnicalRateToken(in: session.parkingLevel)
        let cleanedNote = sanitizeTechnicalRateToken(in: session.note)

        let legacyData = ParkingWidgetData(
            address: session.address ?? "Saved location".psLocalized,
            city: nil,
            startTime: session.startTime,
            endTime: session.maxDuration.map {
                session.startTime.addingTimeInterval($0)
            },
            distanceText: distanceText,
            parkingLevel: cleanedLevel,
            note: cleanedNote
        )

        if let encoded = try? JSONEncoder().encode(legacyData) {
            legacyDefaults?.set(encoded, forKey: legacyKey)
        }

        // Pont vers le nouveau modèle unifié Watch.
        syncToWatch(
            session: session,
            distanceMeters: parseMeters(from: distanceText),
            distanceLabel: distanceText
        )
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Enregistre explicitement avec une distance en mètres.
    func save(session: ParkingSession, distanceMeters: Double?) {
        let formattedDistance: String?
        if let distanceMeters, distanceMeters.isFinite {
            formattedDistance = distanceMeters < 1000
                ? "\(Int(distanceMeters.rounded())) m"
                : String(format: "%.1f km", distanceMeters / 1000)
        } else {
            formattedDistance = nil
        }

        save(session: session, distanceText: formattedDistance)
    }

    /// Efface la session active partagée.
    func clear() {
        legacyDefaults?.removeObject(forKey: legacyKey)
        clearWatch()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Efface uniquement les données de widgets iPhone sans toucher l'état Watch.
    func clearLegacyWidgetData() {
        legacyDefaults?.removeObject(forKey: legacyKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Charge la session active historique iOS (legacy).
    func load() -> ParkingWidgetData? {
        guard let data = legacyDefaults?.data(forKey: legacyKey) else { return nil }
        return try? JSONDecoder().decode(ParkingWidgetData.self, from: data)
    }

    /// Synchronise la session dans le nouveau store Watch.
    func syncToWatch(
        session: ParkingSession,
        distanceMeters: Double? = nil,
        distanceLabel: String? = nil
    ) {
        let watchData = WatchParkingData(
            address: session.address ?? "Saved location".psLocalized,
            fullAddress: session.address ?? "Saved location".psLocalized,
            zoneType: session.zone.rawValue,
            startTime: session.startTime,
            endTime: session.maxDuration.map {
                session.startTime.addingTimeInterval($0)
            },
            distanceMeters: distanceMeters,
            distanceLabel: distanceLabel,
            parkingLevel: sanitizeTechnicalRateToken(in: session.parkingLevel),
            isActive: session.isActive,
            latitude: session.coordinate.latitude,
            longitude: session.coordinate.longitude
        )

        WatchParkingDataStore.shared.save(watchData)
    }

    /// Efface les données Watch (fin de session).
    func clearWatch() {
        WatchParkingDataStore.shared.clear()
    }

    /// Met à jour uniquement la distance dans le store Watch.
    func updateWatchDistance(_ meters: Double) {
        guard let current = WatchParkingDataStore.shared.load() else { return }

        let updated = WatchParkingData(
            address: current.address,
            fullAddress: current.fullAddress,
            zoneType: current.zoneType,
            startTime: current.startTime,
            endTime: current.endTime,
            distanceMeters: meters,
            distanceLabel: nil,
            parkingLevel: current.parkingLevel,
            isActive: current.isActive,
            latitude: current.latitude,
            longitude: current.longitude
        )

        WatchParkingDataStore.shared.save(updated)
    }

    /// Nettoie les jetons techniques de type `IPS_RATE_*` dans les champs texte.
    private func sanitizeTechnicalRateToken(in value: String?) -> String? {
        guard let value else { return nil }
        let patterns = [
            #"\s*\[\[(?:I?PS)_RATE_[A-Z]{3}:[0-9]+(?:[\.,][0-9]+)?\]\]"#,
            #"\s*(?:I?PS)_RATE_[A-Z]{3}:[0-9]+(?:[\.,][0-9]+)?"#
        ]

        var cleaned = value
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Convertit une distance texte historique (ex: "420 m", "1.2 km") en mètres.
    private func parseMeters(from text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        let normalized = text.lowercased().replacingOccurrences(of: ",", with: ".")
        let number = normalized
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .joined()

        guard let value = Double(number) else { return nil }
        return normalized.contains("km") ? value * 1000 : value
    }
}
