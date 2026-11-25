import Foundation
import CoreLocation
import Combine

enum RiskZoneCategory: String, Codable, CaseIterable {
    case towing
    case frequentTickets
    case roadworks

    var localizedTitle: String {
        switch self {
        case .towing:
            return "Enlèvement"
        case .frequentTickets:
            return "PV fréquents"
        case .roadworks:
            return "Travaux"
        }
    }
}
