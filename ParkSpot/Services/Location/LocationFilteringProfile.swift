import Foundation
import CoreLocation
import Combine
import UIKit

enum LocationFilteringProfile {
    case significant
    case balanced
    case navigation
    case precisionNavigation

    var preferredMaximumAccuracy: CLLocationAccuracy {
        switch self {
        case .significant:
            return 80
        case .balanced:
            return 45
        case .navigation:
            return 30
        case .precisionNavigation:
            return 22
        }
    }

    var hardMaximumAccuracy: CLLocationAccuracy {
        switch self {
        case .significant:
            return 120
        case .balanced:
            return 65
        case .navigation:
            return 45
        case .precisionNavigation:
            return 35
        }
    }

    var reliableAccuracyThreshold: CLLocationAccuracy {
        switch self {
        case .significant:
            return 55
        case .balanced:
            return 24
        case .navigation:
            return 16
        case .precisionNavigation:
            return 12
        }
    }

    var smoothingWindow: TimeInterval {
        switch self {
        case .significant:
            return 0
        case .balanced:
            return 5
        case .navigation:
            return 4
        case .precisionNavigation:
            return 4
        }
    }

    var maxHistoryCount: Int {
        switch self {
        case .significant:
            return 1
        case .balanced:
            return 4
        case .navigation:
            return 5
        case .precisionNavigation:
            return 6
        }
    }

    var minimumStableClusterCount: Int {
        switch self {
        case .significant:
            return 1
        case .balanced:
            return 2
        case .navigation, .precisionNavigation:
            return 3
        }
    }

    var maximumAccuracyRegression: CLLocationAccuracy {
        switch self {
        case .significant:
            return 24
        case .balanced:
            return 18
        case .navigation:
            return 12
        case .precisionNavigation:
            return 10
        }
    }

    var staleAcceptanceInterval: TimeInterval {
        switch self {
        case .significant:
            return 8
        case .balanced:
            return 4
        case .navigation:
            return 2.5
        case .precisionNavigation:
            return 2
        }
    }

    var maximumSmoothingSpeed: CLLocationSpeed {
        switch self {
        case .significant:
            return 0
        case .balanced:
            return 3.5
        case .navigation:
            return 4.5
        case .precisionNavigation:
            return 3.2
        }
    }

    var enablesSmoothing: Bool {
        switch self {
        case .significant:
            return false
        case .balanced, .navigation, .precisionNavigation:
            return true
        }
    }

    func clusterSpreadLimit(for bestAccuracy: CLLocationAccuracy) -> CLLocationDistance {
        let minimumSpread: CLLocationDistance
        let maximumSpread: CLLocationDistance
        let multiplier: Double

        switch self {
        case .significant:
            return .greatestFiniteMagnitude
        case .balanced:
            minimumSpread = 6
            maximumSpread = 18
            multiplier = 0.9
        case .navigation:
            minimumSpread = 5
            maximumSpread = 12
            multiplier = 0.75
        case .precisionNavigation:
            minimumSpread = 4
            maximumSpread = 9
            multiplier = 0.7
        }

        return min(maximumSpread, max(minimumSpread, bestAccuracy * multiplier))
    }
}
