import Foundation
import CoreLocation
import Combine

enum VehicleType: String, Codable, CaseIterable, Identifiable {
    case car
    case bike
    case motorcycle
    case scooter
    case van

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .car: return "Voiture"
        case .bike: return "Vélo"
        case .motorcycle: return "Moto"
        case .scooter: return "Scooter"
        case .van: return "Utilitaire"
        }
    }

    var trackerLabel: String {
        switch self {
        case .car: return "auto"
        case .bike: return "vélo"
        case .motorcycle: return "moto"
        case .scooter: return "scooter"
        case .van: return "utilitaire"
        }
    }
}
