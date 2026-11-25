import Foundation
import CoreLocation
import Combine

final class CalendarService {
    struct Suggestion {
        let eventTitle: String
        let eventStart: Date
        let duration: TimeInterval
    }

    func requestAccessIfNeeded() async -> Bool {
        false
    }

    func nextEventSuggestion(maxWindowHours: Double = 8) async -> Suggestion? {
        _ = maxWindowHours
        return nil
    }
}
