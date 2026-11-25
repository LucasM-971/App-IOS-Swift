import SwiftUI
import AppIntents
import CoreLocation
import Combine
import UIKit

/// Priorité d'exécution pour filtrer ce qui reste autorisé en arrière-plan.
enum BackgroundWorkPriority {
    case critical
    case normal
}
