// SharedParkingDataManager+AnonymousSession.swift
// Session active locale des utilisateurs anonymes/free (app uniquement, hors widget).

import Foundation

private let anonymousSessionDataKey = "parkspot_anonymous_active_session_v1"

private struct AnonymousSessionEnvelope: Codable {
    let version: Int
    let source: String
    let session: ParkingSession

    init(session: ParkingSession) {
        self.version = 1
        self.source = "explicit_user_save"
        self.session = session
    }
}

extension SharedParkingDataManager {
    /// Persiste une session active locale (hors widget) pour les utilisateurs anonymes/free.
    func saveAnonymousActiveSession(_ session: ParkingSession) {
        do {
            let payload = AnonymousSessionEnvelope(session: session)
            let encoded = try JSONEncoder().encode(payload)
            UserDefaults.standard.set(encoded, forKey: anonymousSessionDataKey)
        } catch {
            print("[SharedParkingDataManager] Failed to save anonymous session: \(error)")
        }
    }

    /// Restaure la session active locale d'un utilisateur anonyme/free.
    func loadAnonymousActiveSession() -> ParkingSession? {
        guard let data = UserDefaults.standard.data(forKey: anonymousSessionDataKey) else {
            return nil
        }

        do {
            let payload = try JSONDecoder().decode(AnonymousSessionEnvelope.self, from: data)
            let session = payload.session
            return session.endTime == nil ? session : nil
        } catch {
            // Legacy payloads (raw ParkingSession) are intentionally ignored and cleared.
            // They can come from older builds that reconstructed guest sessions from
            // shared widget state, causing ghost sessions when users are logged out.
            UserDefaults.standard.removeObject(forKey: anonymousSessionDataKey)
            return nil
        }
    }

    func clearAnonymousActiveSession() {
        UserDefaults.standard.removeObject(forKey: anonymousSessionDataKey)
    }
}
