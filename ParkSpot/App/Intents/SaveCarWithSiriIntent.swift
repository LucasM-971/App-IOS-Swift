import SwiftUI
import AppIntents
import CoreLocation
import Combine
import UIKit

struct SaveCarWithSiriIntent: AppIntent {
    static var title: LocalizedStringResource = "Save my car"
    static var description = IntentDescription("Automatically saves your current parking location.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let locationProvider = await MainActor.run { OneShotLocationProvider() }
        let coordinate = try await locationProvider.currentCoordinate()

        let container = await MainActor.run { DIContainer.shared }
        let currentUserId = await MainActor.run { loadCurrentUserIdIfAvailable(from: container) }
        let hasPremiumAccess = await MainActor.run { currentUserHasPremiumAccess(userId: currentUserId) }

        guard hasPremiumAccess else {
            return .result(dialog: "This action is only available for Premium accounts.")
        }

        do {
            guard let userId = currentUserId else {
                return .result(dialog: "This action is only available for Premium accounts.")
            }

            let saveUseCase = await MainActor.run { container.makeSaveParkingUseCase() }
            _ = try await saveUseCase.execute(
                userId: userId,
                coordinate: coordinate,
                note: "Action Button",
                parkingLevel: nil,
                maxDuration: nil,
                zone: .unknown,
                photoData: nil,
                allowsPremiumWidgetSurfaces: true
            )
        } catch {
            return .result(dialog: IntentDialog("Unable to save your car right now."))
        }

        return .result(dialog: IntentDialog("Your car location has been saved."))
    }

    @MainActor
    private func loadCurrentUserIdIfAvailable(from container: DIContainer) -> UUID? {
        guard let value = try? container.keychainService.get(.userId) else {
            return nil
        }
        return UUID(uuidString: value)
    }

    @MainActor
    private func currentUserHasPremiumAccess(userId: UUID?) -> Bool {
        guard let userId else { return false }
        guard let data = UserDefaults.standard.data(forKey: "parkspot.auth.cachedUser.v1"),
              let user = try? JSONDecoder().decode(User.self, from: data) else {
            return false
        }
        guard user.id == userId else { return false }

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

    @MainActor
    private func normalizedStatus(_ value: String?) -> String? {
        guard let value else { return nil }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
