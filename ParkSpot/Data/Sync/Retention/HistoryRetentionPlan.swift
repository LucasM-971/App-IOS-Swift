import Foundation

enum HistoryRetentionPlan: String, Codable, Equatable {
    case free
    case premium

    var retentionDays: Int {
        switch self {
        case .free: return 7
        case .premium: return 90
        }
    }

    var cloudBackupEnabled: Bool {
        true
    }
}
