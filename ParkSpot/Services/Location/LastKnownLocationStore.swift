// LastKnownLocationStore.swift
// Persistance locale du dernier point GPS fiable (App Group, hors-ligne)

import Foundation

struct LastKnownLocationStore {
    static let shared = LastKnownLocationStore()

    private enum Keys {
        static let latitude = "lastKnown.latitude"
        static let longitude = "lastKnown.longitude"
        static let accuracy = "lastKnown.accuracy"
        static let date = "lastKnown.date"
    }

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: "group.com.parkspot.app")) {
        self.defaults = defaults
    }

    init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName)
    }

    /// Sauvegarde atomique du dernier point GPS jugé fiable.
    func save(_ coordinate: Coordinate, accuracy: Double) {
        defaults?.set(coordinate.latitude, forKey: Keys.latitude)
        defaults?.set(coordinate.longitude, forKey: Keys.longitude)
        defaults?.set(accuracy, forKey: Keys.accuracy)
        defaults?.set(Date(), forKey: Keys.date)
    }

    /// Recharge le dernier point GPS fiable, avec son horodatage.
    func load(maxAge: TimeInterval? = nil, now: Date = Date()) -> (coordinate: Coordinate, accuracy: Double, date: Date)? {
        guard let defaults,
              let date = defaults.object(forKey: Keys.date) as? Date,
              defaults.object(forKey: Keys.latitude) != nil,
              defaults.object(forKey: Keys.longitude) != nil,
              defaults.object(forKey: Keys.accuracy) != nil else {
            return nil
        }

        let coordinate = Coordinate(
            latitude: defaults.double(forKey: Keys.latitude),
            longitude: defaults.double(forKey: Keys.longitude)
        )
        let accuracy = defaults.double(forKey: Keys.accuracy)

        guard coordinate.isValidGeoCoordinate,
              accuracy.isFinite,
              accuracy > 0 else {
            return nil
        }

        if let maxAge, now.timeIntervalSince(date) > maxAge {
            return nil
        }

        return (coordinate, accuracy, date)
    }

    func clear() {
        defaults?.removeObject(forKey: Keys.latitude)
        defaults?.removeObject(forKey: Keys.longitude)
        defaults?.removeObject(forKey: Keys.accuracy)
        defaults?.removeObject(forKey: Keys.date)
    }
}
