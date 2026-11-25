import Foundation
import CoreLocation
import Combine

final class VehicleProfileStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let key = "vehicle.profile.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> VehicleProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(VehicleProfile.self, from: data)
    }

    func save(_ profile: VehicleProfile) {
        guard let data = try? encoder.encode(profile) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
