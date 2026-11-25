import Foundation
import Combine
import StoreKit

#if canImport(UIKit)
import UIKit

// Notification quand le statut Premium change
extension NSNotification.Name {
    static let premiumStatusChanged = NSNotification.Name("PremiumStatusChanged")
}

enum PremiumPlan: CaseIterable {
    case lifetime
    case monthly

    var productId: String {
        switch self {
        case .lifetime:
            return AppConfig.premiumLifetimeProductID
        case .monthly:
            return AppConfig.premiumMonthlyProductID
        }
    }

    var fallbackDisplayPrice: String {
        switch self {
        case .lifetime:
            return "€14.99"
        case .monthly:
            return "€2.99"
        }
    }
}

// MARK: - ViewModel de la page Premium
@MainActor
final class PremiumViewModel: ObservableObject {
    @Published var isPremium: Bool = false {
        didSet {
            if isPremium != oldValue {
                // Notifier que le statut premium a changé
                NotificationCenter.default.post(
                    name: NSNotification.Name.premiumStatusChanged,
                    object: nil,
                    userInfo: ["isPremium": isPremium]
                )
            }
        }
    }
    @Published var alertTitle: String = "Information"
    @Published var isPurchasing: Bool = false
    @Published var isRestoring: Bool = false
    @Published var errorMessage: String?
    @Published var selectedPlan: PremiumPlan = .monthly
    @Published var shouldOfferSubscriptionManagement: Bool = false
    @Published private(set) var hasLifetimeEntitlement: Bool = false
    @Published private(set) var productsByPlan: [PremiumPlan: Product] = [:]
    @Published private(set) var isStoreLoading: Bool = false
    @Published private(set) var storeIssueTitle: String?
    @Published private(set) var storeIssueMessage: String?
    @Published private(set) var storeIssueTechnicalDetails: String?

    // Tâche d'écoute des transactions live
    private var updatesTask: Task<Void, Never>?

    init() {
        // Au démarrage, on écoute les transactions et on vérifie les droits actuels.
        listenForTransactions()
        Task { await checkCurrentEntitlements(syncToBackend: false) }
    }

    deinit {
        // Nettoyage de la tâche d'écoute pour éviter les fuites.
        updatesTask?.cancel()
    }

    // Prix principal affiché sur la carte
    var displayedPrice: String {
        guard let product = productsByPlan[selectedPlan] else {
            return selectedPlan.fallbackDisplayPrice
        }
        return normalizedDisplayPrice(for: product, includeCurrencySymbol: true) ?? selectedPlan.fallbackDisplayPrice
    }

    // Prix complet affiché en bas du CTA
    var displayedPriceWithPeriod: String {
        switch selectedPlan {
        case .lifetime:
            return "One-time payment · lifetime access"
        case .monthly:
            let price = displayedPrice
            return "Auto-renewing monthly subscription · \(price) / month"
        }
    }

    var includedSummary: String {
        "Includes widgets, map tools, shortcuts, 90-day history, frequent zones, alerts, smart duration suggestions, and no ads."
    }

    var lifetimeDisplayPrice: String {
        guard let product = productsByPlan[.lifetime] else {
            return PremiumPlan.lifetime.fallbackDisplayPrice
        }
        return normalizedDisplayPrice(for: product, includeCurrencySymbol: true) ?? PremiumPlan.lifetime.fallbackDisplayPrice
    }

    var monthlyDisplayPrice: String {
        guard let product = productsByPlan[.monthly] else {
            return PremiumPlan.monthly.fallbackDisplayPrice
        }
        return normalizedDisplayPrice(for: product, includeCurrencySymbol: true) ?? PremiumPlan.monthly.fallbackDisplayPrice
    }

    var lifetimeSavingsBadgeText: String {
        guard
            let monthly = productsByPlan[.monthly],
            let lifetime = productsByPlan[.lifetime]
        else {
            return "MOST POPULAR"
        }

        let monthlyCostForOneYear = monthly.price * 12
        guard monthlyCostForOneYear > 0 else { return "MOST POPULAR" }

        let savingsRatio = max(0, (monthlyCostForOneYear - lifetime.price) / monthlyCostForOneYear)
        let savingsPercent = Int((savingsRatio as NSDecimalNumber).doubleValue * 100)
        return savingsPercent > 0 ? "SAVE \(savingsPercent)%" : "MOST POPULAR"
    }

    var isStoreUnavailable: Bool {
        !isStoreLoading && productsByPlan[selectedPlan] == nil
    }

    var canStartPurchase: Bool {
        if selectedPlan == .monthly && hasLifetimeEntitlement {
            return false
        }
        return !isStoreLoading && !isPurchasing && productsByPlan[selectedPlan] != nil
    }

    var purchaseButtonTitle: String {
        if isStoreLoading { return "Loading..." }
        if selectedPlan == .monthly && hasLifetimeEntitlement {
            return "Included with lifetime access"
        }
        if canStartPurchase {
            switch selectedPlan {
            case .lifetime:
                return "Unlock lifetime access"
            case .monthly:
                return "Subscribe"
            }
        }
        switch selectedPlan {
        case .lifetime:
            return "Lifetime offer unavailable"
        case .monthly:
            return "Monthly offer unavailable"
        }
    }

    var monthlyTrailingLabel: String {
        hasLifetimeEntitlement ? "INCLUDED" : "AUTO-RENEW"
    }

    // MARK: - Chargement du produit
    func loadProducts() async {
        isStoreLoading = true
        storeIssueTitle = nil
        storeIssueMessage = nil
        storeIssueTechnicalDetails = nil
        do {
            let ids = PremiumPlan.allCases.map(\.productId)
            let products = try await Product.products(for: ids)

            var mapped: [PremiumPlan: Product] = [:]
            for plan in PremiumPlan.allCases {
                if let product = products.first(where: { $0.id == plan.productId }) {
                    mapped[plan] = product
                }
            }
            productsByPlan = mapped
            let missingPlans = PremiumPlan.allCases.filter { mapped[$0] == nil }
            if mapped.isEmpty {
                storeIssueTitle = "Offers unavailable"
                storeIssueMessage = "Unable to load subscription products right now."
                storeIssueTechnicalDetails = "No App Store Connect product matches the configured identifiers."
            } else if !missingPlans.isEmpty {
                let missingNames = missingPlans.map(planDisplayName).joined(separator: ", ")
                let missingIDs = missingPlans.map(\.productId).joined(separator: ", ")
                let loadedIDs = mapped.values.map(\.id).sorted().joined(separator: ", ")

                storeIssueTitle = "Partially unavailable"
                storeIssueMessage = "Some offers are currently unavailable: \(missingNames)."
                storeIssueTechnicalDetails = "Missing IDs: \(missingIDs)\nLoaded IDs: \(loadedIDs)"
            }
        } catch {
            showAlert(
                title: "Offers unavailable",
                message: userFacingMessage(for: error, fallback: "Unable to load subscription products.")
            )
            storeIssueTitle = "Offers unavailable"
            storeIssueMessage = "Unable to load subscription products right now."
            storeIssueTechnicalDetails = error.localizedDescription
        }
        isStoreLoading = false
    }

    // MARK: - Achat
    func purchase() async {
        errorMessage = nil

        if selectedPlan == .monthly, let lifetimeEntitlement = await activeEntitlement(for: .lifetime) {
            hasLifetimeEntitlement = true
            selectedPlan = .lifetime
            let purchaseDate = lifetimeEntitlement.purchaseDate.formatted(date: .abbreviated, time: .shortened)
            showAlert(
                title: "Monthly plan unavailable",
                message: "You already have lifetime access on this Apple account.\nLifetime purchase date: \(purchaseDate)\nTransaction: \(lifetimeEntitlement.id)"
            )
            return
        }

        if let existingEntitlement = await activeEntitlement(for: selectedPlan) {
            // Force une resynchronisation App Store pour éviter les faux positifs
            // quand l'historique sandbox vient d'être réinitialisé.
            do {
                try await AppStore.sync()
            } catch {
                if AppConfig.isDebugLoggingEnabled {
                    print("AppStore.sync() échoué avant vérification entitlement: \(error.localizedDescription)")
                }
            }

            if let confirmedEntitlement = await activeEntitlement(for: selectedPlan) {
                isPremium = true
                do {
                    try await updateSupabasePremiumStatus(
                        isPremium: true,
                        sourceProductID: selectedPlan.productId,
                        sourceTransactionID: String(confirmedEntitlement.id)
                    )
                    let purchaseDate = confirmedEntitlement.purchaseDate.formatted(date: .abbreviated, time: .shortened)
                    showAlert(
                            title: "Already active",
                            message: "The \(planDisplayName(selectedPlan)) offer is already active on this Apple account.\nProduct: \(confirmedEntitlement.productID)\nPurchase date: \(purchaseDate)\nTransaction: \(confirmedEntitlement.id)"
                    )
                } catch {
                    showAlert(
                        title: "Already active (sync failed)",
                        message: "The \(planDisplayName(selectedPlan)) offer is active on Apple, but backend sync failed.\n\(error.localizedDescription)"
                    )
                }
                return
            }

            if AppConfig.isDebugLoggingEnabled {
                print("Entitlement initial invalidé après AppStore.sync() (tx: \(existingEntitlement.id))")
            }
        }

        var productToPurchase = productsByPlan[selectedPlan]
        let shouldPromptMonthlyCancellation: Bool
        if selectedPlan == .lifetime {
            shouldPromptMonthlyCancellation = await hasActiveMonthlyEntitlement()
        } else {
            shouldPromptMonthlyCancellation = false
        }

        if productToPurchase == nil && !isStoreLoading {
            await loadProducts()
            productToPurchase = productsByPlan[selectedPlan]
        }

        if productToPurchase == nil {
            do {
                let singleFetch = try await Product.products(for: [selectedPlan.productId])
                if let fetchedProduct = singleFetch.first {
                    productsByPlan[selectedPlan] = fetchedProduct
                    productToPurchase = fetchedProduct
                } else {
                    storeIssueTitle = "Offer unavailable"
                    storeIssueMessage = "No App Store product was found for the \(planDisplayName(selectedPlan)) offer."
                    storeIssueTechnicalDetails = "Product ID: \(selectedPlan.productId)"
                }
            } catch {
                storeIssueTitle = "Offer unavailable"
                storeIssueMessage = "Unable to load the \(planDisplayName(selectedPlan)) offer."
                storeIssueTechnicalDetails = error.localizedDescription
            }
        }

        guard let product = productToPurchase else {
            let storeMessage = storeIssueMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = "The \(planDisplayName(selectedPlan)) offer is not available right now."
            let reason = (storeMessage?.isEmpty == false) ? storeMessage! : fallback
            showAlert(
                title: "Offer unavailable",
                message: "\(reason)\nProduct ID: \(selectedPlan.productId)"
            )
            return
        }

        isPurchasing = true

        defer { isPurchasing = false }

        do {
            var purchaseOptions = Set<Product.PurchaseOption>()
            if let currentUserId = currentAppUserId() {
                purchaseOptions.insert(.appAccountToken(currentUserId))
            }

            let result = try await product.purchase(options: purchaseOptions)
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    isPremium = true
                    do {
                        try await updateSupabasePremiumStatus(
                            isPremium: true,
                            sourceProductID: transaction.productID,
                            sourceTransactionID: String(transaction.id)
                        )
                        if transaction.productID == PremiumPlan.lifetime.productId,
                           shouldPromptMonthlyCancellation {
                            showAlert(
                                title: "Lifetime access active".psLocalized,
                                message: "Lifetime access is now active. Your monthly subscription may still renew until you cancel it in your Apple account settings. Open subscription settings to cancel the monthly plan and avoid future renewals.".psLocalized,
                                offersSubscriptionManagement: true
                            )
                            return
                        }
                        showAlert(
                            title: "Purchase confirmed",
                            message: "The \(planDisplayName(selectedPlan)) offer has been activated."
                        )
                    } catch {
                        showAlert(
                            title: "Purchase confirmed (sync failed)",
                            message: "Apple confirmed the purchase, but backend sync failed.\n\(error.localizedDescription)"
                        )
                    }
                case .unverified:
                    showAlert(title: "Purchase not verified", message: "The transaction could not be verified.")
                }
            case .userCancelled:
                showAlert(
                    title: "Purchase canceled",
                    message: "The purchase was canceled or declined.\nIf no App Store screen appears, check that the product is available."
                )
            case .pending:
                showAlert(title: "Purchase pending", message: "The purchase is awaiting approval.")
            @unknown default:
                break
            }
        } catch {
            showAlert(
                title: "Purchase error",
                message: userFacingMessage(for: error, fallback: "An error occurred during purchase.")
            )
        }
    }

    // MARK: - Restauration
    func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await checkCurrentEntitlements(syncToBackend: true)
        } catch {
            showAlert(
                title: "Restore failed",
                message: userFacingMessage(for: error, fallback: "Unable to restore purchases.")
            )
        }
    }

    // MARK: - Vérification des droits actifs
    func checkCurrentEntitlements(syncToBackend: Bool = false) async {
        var preferredTransaction: Transaction?
        var foundPremium = false
        var foundLifetime = false
        let currentUserId = currentAppUserId()

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               PremiumPlan.allCases.contains(where: { $0.productId == transaction.productID }),
               transaction.revocationDate == nil,
               !transaction.isUpgraded,
               isEntitlementOwnedByCurrentUser(transaction, currentUserId: currentUserId) {
                foundPremium = true
                if transaction.productID == PremiumPlan.lifetime.productId {
                    foundLifetime = true
                    preferredTransaction = transaction
                } else if preferredTransaction == nil {
                    preferredTransaction = transaction
                }
            }
        }

        hasLifetimeEntitlement = foundLifetime
        if foundLifetime && selectedPlan == .monthly {
            selectedPlan = .lifetime
        }

        guard foundPremium, let transaction = preferredTransaction else {
            isPremium = false
            return
        }

        isPremium = true
        guard syncToBackend else { return }

        try? await updateSupabasePremiumStatus(
            isPremium: true,
            sourceProductID: transaction.productID,
            sourceTransactionID: String(transaction.id)
        )
    }

    // MARK: - Écoute des nouvelles transactions
    func listenForTransactions() {
        updatesTask?.cancel()
        updatesTask = Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self.checkCurrentEntitlements(syncToBackend: true)
                }
            }
        }
    }

    func bootstrap() async {
        await loadProducts()
        await checkCurrentEntitlements(syncToBackend: false)
    }

    func retryLoadingProducts() async {
        await loadProducts()
    }

    func clearAlert() {
        errorMessage = nil
        shouldOfferSubscriptionManagement = false
    }

    func openSubscriptionManagement() async {
        clearAlert()

        guard let scene = Self.currentWindowScene else {
            showAlert(
                title: "Unable to open subscription settings".psLocalized,
                message: "Open your Apple account settings from the App Store to manage or cancel the monthly subscription.".psLocalized
            )
            return
        }

        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            showAlert(
                title: "Unable to open subscription settings".psLocalized,
                message: String(
                    format: "Subscription settings could not be opened. Manage or cancel your monthly subscription in your Apple account settings.\n%@".psLocalized,
                    error.localizedDescription
                )
            )
        }
    }

    func selectPlan(_ plan: PremiumPlan) {
        if plan == .monthly && hasLifetimeEntitlement {
            selectedPlan = .lifetime
            showAlert(
                title: "Monthly plan blocked",
                message: "Lifetime access is already active on this Apple account, so the monthly plan is unavailable."
            )
            return
        }

        selectedPlan = plan

        guard !isStoreLoading else { return }
        guard productsByPlan[plan] == nil else { return }

        storeIssueTitle = "Offer unavailable"
        storeIssueMessage = "The \(planDisplayName(plan)) offer is not available right now."
        storeIssueTechnicalDetails = "Product ID: \(plan.productId)"
    }

    // MARK: - Synchronisation du statut premium côté backend
    private func updateSupabasePremiumStatus(
        isPremium: Bool,
        sourceProductID: String?,
        sourceTransactionID: String?
    ) async throws {
        try await DIContainer.shared.authRepository.updatePremiumStatus(
            isPremium,
            sourceProductID: sourceProductID,
            sourceTransactionID: sourceTransactionID
        )
    }

    // MARK: - Helpers
    private func normalizedDisplayPrice(for product: Product, includeCurrencySymbol: Bool) -> String? {
        let raw = product.displayPrice.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = raw.lowercased()

        // Cas d'erreur observé: "IPS_RATE_EUR:2.00"
        if lowered.contains("ips_rate_") {
            let amount = raw.split(separator: ":").last.map(String.init) ?? "1.99"
            let decimalAmount = amount.replacingOccurrences(of: ".", with: ",")
            return includeCurrencySymbol ? "\(decimalAmount) $" : decimalAmount
        }

        if includeCurrencySymbol {
            return raw
        }

        return raw
            .replacingOccurrences(of: "€", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func userFacingMessage(for error: Error, fallback: String) -> String {
        let technical = error.localizedDescription
        let lowered = technical.lowercased()

        if lowered.contains("ips_rate_") {
            return "The price could not be loaded. Check your App Store Connect configuration and try again."
        }

        if technical.isEmpty {
            return fallback
        }

        return "\(fallback)\n\(technical)"
    }

    private func activeEntitlement(for plan: PremiumPlan) async -> Transaction? {
        let currentUserId = currentAppUserId()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productID == plan.productId else { continue }
            guard transaction.revocationDate == nil else { continue }
            guard !transaction.isUpgraded else { continue }
            guard isEntitlementOwnedByCurrentUser(transaction, currentUserId: currentUserId) else { continue }
            return transaction
        }
        return nil
    }

    private func hasActiveMonthlyEntitlement() async -> Bool {
        await activeEntitlement(for: .monthly) != nil
    }

    private func isEntitlementOwnedByCurrentUser(
        _ transaction: Transaction,
        currentUserId: UUID?
    ) -> Bool {
        guard let currentUserId else {
            // Sans session app, on garde le comportement StoreKit standard.
            return true
        }

        // Isolation stricte par compte applicatif :
        // une transaction sans appAccountToken n'est pas rattachée au user courant.
        return transaction.appAccountToken == currentUserId
    }

    private func currentAppUserId() -> UUID? {
        guard let raw = try? DIContainer.shared.keychainService.get(.userId) else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: normalized)
    }

    private func showAlert(title: String, message: String) {
        showAlert(title: title, message: message, offersSubscriptionManagement: false)
    }

    private func showAlert(
        title: String,
        message: String,
        offersSubscriptionManagement: Bool
    ) {
        alertTitle = title
        errorMessage = message
        shouldOfferSubscriptionManagement = offersSubscriptionManagement
    }

    private func planDisplayName(_ plan: PremiumPlan) -> String {
        switch plan {
        case .lifetime:
            return "lifetime"
        case .monthly:
            return "monthly"
        }
    }

    private static var currentWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
    }
}

#else

enum PremiumPlan: CaseIterable {
    case lifetime
    case monthly
}

@MainActor
final class PremiumViewModel: ObservableObject {
    @Published var isPremium: Bool = false
    @Published var alertTitle: String = "Information"
    @Published var isPurchasing: Bool = false
    @Published var isRestoring: Bool = false
    @Published var errorMessage: String?
    @Published var selectedPlan: PremiumPlan = .monthly

    func bootstrap() async {}
    func restorePurchases() async {}
    func purchase() async {}
}

#endif
