import Foundation

enum HistoryPlanResolver {
    private static let cachedUserKey = "parkspot.auth.cachedUser.v1"

    static func resolvePlan(for user: User?) -> HistoryRetentionPlan {
        guard let user else { return .free }
        return isPremium(user) ? .premium : .free
    }

    static func resolvePlan(for userId: UUID, defaults: UserDefaults = .standard) -> HistoryRetentionPlan {
        guard
            let data = defaults.data(forKey: cachedUserKey),
            let user = try? JSONDecoder().decode(User.self, from: data),
            user.id == userId
        else {
            return .free
        }
        return resolvePlan(for: user)
    }

    static func cachedUser(defaults: UserDefaults = .standard) -> User? {
        guard let data = defaults.data(forKey: cachedUserKey) else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    static func isPremium(_ user: User) -> Bool {
        if user.statusId == 1 { return false }
        if normalizedStatus(user.status) == "free" { return false }

        if user.statusId == 2 || user.statusId == 3 { return true }
        if let normalized = normalizedStatus(user.status),
           normalized == "paid"
            || normalized == "premium"
            || normalized == "paid_monthly"
            || normalized == "paid_lifetime" {
            return true
        }

        return user.isPremium
    }

    private static func normalizedStatus(_ value: String?) -> String? {
        guard let value else { return nil }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
