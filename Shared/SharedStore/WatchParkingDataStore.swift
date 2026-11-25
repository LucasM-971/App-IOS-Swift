// WatchParkingDataStore.swift
// Partage les données de session entre iOS et watchOS via App Group.

import Foundation
import WidgetKit

// MARK: - WatchParkingData
/// Modèle de données unifié pour les complications et l'app watchOS.
struct WatchParkingData: Codable {
    /// Adresse courte affichée en priorité.
    let address: String
    /// Adresse complète affichée dans les détails.
    let fullAddress: String
    /// Type de zone: Gratuit / Payant / Souterrain / etc.
    let zoneType: String
    /// Date de démarrage du stationnement.
    let startTime: Date
    /// Date de fin du timer (nil si pas de minuteur).
    let endTime: Date?
    /// Distance entre l'utilisateur et le véhicule, en mètres.
    let distanceMeters: Double?
    /// Libellé de distance déjà formaté par l'iPhone lorsque la mesure brute n'est pas disponible.
    let distanceLabel: String?
    /// Niveau de parking éventuel (B2, +1, etc.).
    let parkingLevel: String?
    /// Statut global de session active.
    let isActive: Bool
    /// Latitude optionnelle pour ouvrir Apple Maps depuis la Watch.
    let latitude: Double?
    /// Longitude optionnelle pour ouvrir Apple Maps depuis la Watch.
    let longitude: Double?

    init(
        address: String,
        fullAddress: String,
        zoneType: String,
        startTime: Date,
        endTime: Date?,
        distanceMeters: Double?,
        distanceLabel: String? = nil,
        parkingLevel: String?,
        isActive: Bool,
        latitude: Double?,
        longitude: Double?
    ) {
        self.address = address
        self.fullAddress = fullAddress
        self.zoneType = zoneType
        self.startTime = startTime
        self.endTime = endTime
        self.distanceMeters = distanceMeters
        self.distanceLabel = distanceLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.parkingLevel = parkingLevel
        self.isActive = isActive
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Nombre de secondes restantes si un timer est défini.
    var remainingSeconds: Int? {
        guard let end = endTime else { return nil }
        let diff = end.timeIntervalSinceNow
        guard diff.isFinite else { return 0 }
        return max(0, Int(diff))
    }

    /// Progression consommée du timer entre 0 et 1.
    var progressPercent: Double {
        guard let end = endTime else { return 0 }
        let total = end.timeIntervalSince(startTime)
        guard total > 0, total.isFinite else { return 0 }
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed.isFinite else { return 0 }
        return min(max(elapsed / total, 0), 1)
    }

    /// Distance formatée en m/km pour l'affichage.
    var distanceText: String {
        if let distanceLabel, !distanceLabel.isEmpty {
            return distanceLabel
        }
        guard let d = distanceMeters, d.isFinite else { return "--" }
        return d < 1000 ? "\(Int(d.rounded())) m" : String(format: "%.1f km", d / 1000)
    }

    /// Valeur de démonstration utilisée en placeholder/previews.
    static let placeholder = WatchParkingData(
        address: "No car".sharedLocalized,
        fullAddress: "No active session".sharedLocalized,
        zoneType: "--",
        startTime: .now,
        endTime: nil,
        distanceMeters: nil,
        distanceLabel: nil,
        parkingLevel: nil,
        isActive: false,
        latitude: nil,
        longitude: nil
    )
}

// MARK: - WatchParkingDataStore
/// Store centralisé pour lire/écrire les données partagées entre iOS, Watch et WidgetKit.
final class WatchParkingDataStore {
    static let shared = WatchParkingDataStore()

    /// Clé principale (nouveau format watch).
    private let key = "watch.active.parking"
    /// Flag de droit Premium pour afficher les widgets / complications Watch.
    private let widgetAccessKey = "watch.widgets.premium.enabled"
    /// App Group demandé pour la synchro iOS ↔ watchOS.
    private let appGroup = "group.com.mosimap.shared"

    /// Compatibilité ascendante: ancien App Group déjà présent dans le projet.
    private let legacyAppGroup = "group.com.parkspot.app"
    /// Compatibilité ascendante: ancienne clé du widget existant.
    private let legacyKey = "active_parking_widget_data"

    /// UserDefaults principal lié au nouvel App Group.
    private lazy var defaults = UserDefaults(suiteName: appGroup)
    /// UserDefaults de secours pour migration douce depuis l'existant.
    private lazy var legacyDefaults = UserDefaults(suiteName: legacyAppGroup)

    private init() {}

    /// iOS / WatchConnectivity: enregistre la session active.
    func save(_ data: WatchParkingData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults?.set(encoded, forKey: key)

        // Écriture de compatibilité pour ne pas casser les écrans historiques.
        legacyDefaults?.set(encoded, forKey: key)

        // Rafraîchit immédiatement toutes les timelines WidgetKit.
        WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: .watchParkingDataDidChange, object: nil)
    }

    /// Fin de session: supprime les données partagées.
    func clear() {
        defaults?.removeObject(forKey: key)
        legacyDefaults?.removeObject(forKey: key)
        legacyDefaults?.removeObject(forKey: legacyKey)
        WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: .watchParkingDataDidChange, object: nil)
    }

    /// Watch / Widget: lit la session active.
    func load() -> WatchParkingData? {
        // Lecture standard (nouvelle clé / nouvel App Group).
        if let data = defaults?.data(forKey: key),
           let decoded = try? JSONDecoder().decode(WatchParkingData.self, from: data) {
            return decoded
        }

        // Lecture de secours (nouvelle clé / ancien App Group).
        if let data = legacyDefaults?.data(forKey: key),
           let decoded = try? JSONDecoder().decode(WatchParkingData.self, from: data) {
            return decoded
        }

        // Migration douce depuis l'ancien format widget.
        if let legacy = loadLegacyWidgetFormat() {
            save(legacy)
            return legacy
        }

        return nil
    }

    /// Indique si une session est active.
    var isActive: Bool { load()?.isActive ?? false }

    /// Autorise l'affichage des widgets / complications Watch réservés Premium.
    var isWidgetAccessEnabled: Bool {
        defaults?.bool(forKey: widgetAccessKey)
            ?? legacyDefaults?.bool(forKey: widgetAccessKey)
            ?? false
    }

    /// Met à jour le droit Premium utilisé par les widgets Watch.
    func setWidgetAccessEnabled(_ isEnabled: Bool) {
        defaults?.set(isEnabled, forKey: widgetAccessKey)
        legacyDefaults?.set(isEnabled, forKey: widgetAccessKey)
        WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: .watchParkingDataDidChange, object: nil)
    }

    /// Décode l'ancien format utilisé par le widget iOS existant.
    private func loadLegacyWidgetFormat() -> WatchParkingData? {
        guard let data = legacyDefaults?.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode(LegacyParkingWidgetData.self, from: data)
        else {
            return nil
        }

        let address = legacy.address.isEmpty ? "Saved location".sharedLocalized : legacy.address
        let fullAddress = [legacy.address, legacy.city].compactMap { value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }.joined(separator: ", ")

        return WatchParkingData(
            address: address,
            fullAddress: fullAddress.isEmpty ? address : fullAddress,
            zoneType: "Unknown".sharedLocalized,
            startTime: legacy.startTime ?? .now,
            endTime: legacy.endTime,
            distanceMeters: parseMeters(from: legacy.distanceText),
            distanceLabel: legacy.distanceText,
            parkingLevel: legacy.parkingLevel,
            isActive: true,
            latitude: nil,
            longitude: nil
        )
    }

    /// Convertit une distance texte historique (ex: "320 m", "1.2 km") en mètres.
    private func parseMeters(from text: String?) -> Double? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let normalized = raw.lowercased().replacingOccurrences(of: ",", with: ".")
        let numberText = normalized
            .components(separatedBy: CharacterSet(charactersIn: "0123456789." ).inverted)
            .joined()

        guard let value = Double(numberText) else { return nil }
        if normalized.contains("km") { return value * 1000 }
        return value
    }
}

extension Notification.Name {
    static let watchParkingDataDidChange = Notification.Name("watchParkingDataDidChange")
}

private extension String {
    var sharedLocalized: String {
        NSLocalizedString(self, comment: "")
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Legacy format
/// Ancien format de données iOS widget conservé pour migration de compatibilité.
private struct LegacyParkingWidgetData: Codable {
    let address: String
    let city: String?
    let startTime: Date?
    let endTime: Date?
    let distanceText: String?
    let parkingLevel: String?
    let note: String?
}
