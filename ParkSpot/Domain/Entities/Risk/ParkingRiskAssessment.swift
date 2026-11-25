import Foundation
import CoreLocation
import Combine

struct ParkingRiskAssessment {
    let score: Int
    let level: ParkingRiskLevel
    let matchingCategories: [RiskZoneCategory]
    let nearbySignals: [RiskZoneSignal]
    let openDataMatches: Int
    let communityMatches: Int
}
