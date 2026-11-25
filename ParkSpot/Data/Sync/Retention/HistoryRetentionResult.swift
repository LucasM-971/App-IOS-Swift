import Foundation

struct HistoryRetentionResult: Equatable {
    let removedLocalCount: Int
    let enqueuedCloudDeleteCount: Int
}
