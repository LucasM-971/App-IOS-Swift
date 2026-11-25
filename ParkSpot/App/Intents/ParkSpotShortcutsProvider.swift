import SwiftUI
import AppIntents
import CoreLocation
import Combine
import UIKit

struct ParkSpotShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveCarWithSiriIntent(),
            phrases: [
                "I parked my car in \(.applicationName)",
                "Save my car in \(.applicationName)"
            ],
            shortTitle: "Park my car",
            systemImageName: "car.fill"
        )
    }
}
