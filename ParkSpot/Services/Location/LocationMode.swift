import Foundation
import CoreLocation
import Combine
import UIKit

/// Modes énergétiques de localisation.
/// On monte en précision uniquement lorsque c'est nécessaire.
enum LocationMode {
    case off
    case significant
    case balanced
    case navigation
    case precisionNavigation
}

extension LocationMode {
    var filteringProfile: LocationFilteringProfile {
        switch self {
        case .off, .significant:
            return .significant
        case .balanced:
            return .balanced
        case .navigation:
            return .navigation
        case .precisionNavigation:
            return .precisionNavigation
        }
    }
}
