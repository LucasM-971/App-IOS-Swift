import SwiftUI

#if canImport(UIKit)

// MARK: - Premium main screen
struct PremiumView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = PremiumViewModel()
    @State private var didAutoRevealPrice = false

    var body: some View {
        // GeometryReader permet d'adapter l'interface à toutes les tailles d'écran.
        GeometryReader { geo in
            ZStack {
                PremiumTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 1) Fixed header
                    PremiumHeaderView(onClose: { dismiss() })

                    // 2) Scrollable main content
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            PremiumContentView(geo: geo, vm: vm)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear {
                            guard !didAutoRevealPrice else { return }
                            didAutoRevealPrice = true

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                withAnimation(.easeInOut(duration: 1.2)) {
                                    proxy.scrollTo("premium-price-card", anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task {
            await vm.bootstrap()
        }
        .tint(PremiumTheme.blue)
        .alert(
            vm.alertTitle,
            isPresented: Binding(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.clearAlert() } }
            )
        ) {
            if vm.shouldOfferSubscriptionManagement {
                Button("Manage subscription".psLocalized) {
                    Task { await vm.openSubscriptionManagement() }
                }
            }

            Button("OK", role: .cancel) { vm.clearAlert() }
        } message: {
            Text(vm.errorMessage ?? "")
                .minimumScaleFactor(0.85)
        }
    }
}

// MARK: - Header
struct PremiumHeaderView: View {
    let onClose: () -> Void

    var body: some View {
        HStack {
            // Bouton de fermeture
            Button(action: onClose) {
                ZStack {
                    Circle()
                        .fill(PremiumTheme.closeButtonFill)
                        .frame(width: 30, height: 30)
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PremiumTheme.textSecondary)
                }
            }

            Spacer()

            Text("MosiMap Premium")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(PremiumTheme.textPrimary)
                .minimumScaleFactor(0.85)
                .lineLimit(1)

            Spacer()

            // Espace miroir pour garder le titre centré
            PremiumTheme.transparent
                .frame(width: 30, height: 30)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PremiumTheme.separator)
                .frame(height: 1)
        }
    }
}

// MARK: - Contenu principal
struct PremiumContentView: View {
    let geo: GeometryProxy
    @ObservedObject var vm: PremiumViewModel
    @State private var priceCardHasLanded = false

    // Hauteur disponible après retrait d'une estimation header/footer + safe areas
    private var availableHeight: CGFloat {
        geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom - 176
    }

    // Espacement adaptatif
    private var spacing: CGFloat {
        availableHeight > 600 ? 12 : 8
    }

    // Padding vertical adaptatif
    private var vPad: CGFloat {
        availableHeight > 600 ? 16 : 10
    }

    // Mise en page compacte sur petits écrans
    private var isCompact: Bool {
        availableHeight < 560
    }

    // Coefficient global de réduction pour garantir l'affichage sur un seul écran.
    private var contentScale: CGFloat {
        let rawScale = availableHeight / 640
        return min(1.0, max(0.76, rawScale))
    }

    var body: some View {
        VStack(spacing: spacing) {
            HeroSectionView(vPad: vPad, isCompact: isCompact)

            SubscriptionBadgeView(isCompact: isCompact)
                .padding(.horizontal, 16)

            FeaturesListView(isCompact: isCompact)
                .padding(.horizontal, 16)

            PriceCardView(vm: vm, isCompact: isCompact)
                .padding(.horizontal, 16)
                .id("premium-price-card")
                .offset(y: priceCardHasLanded ? 0 : 42)
                .opacity(priceCardHasLanded ? 1 : 0.92)
                .scaleEffect(priceCardHasLanded ? 1 : 0.98)
                .animation(
                    .spring(response: 0.72, dampingFraction: 0.84, blendDuration: 0.2)
                        .delay(0.12),
                    value: priceCardHasLanded
                )

            PremiumFooterView(vm: vm)
                .padding(.horizontal, 16)
        }
        .padding(.top, vPad)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            guard !priceCardHasLanded else { return }
            priceCardHasLanded = true
        }
    }
}

// MARK: - Hero
struct HeroSectionView: View {
    let vPad: CGFloat
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 8 : 10) {
            ZStack {
                RoundedRectangle(cornerRadius: isCompact ? 15 : 18)
                    .fill(PremiumTheme.gold.opacity(0.12))
                    .frame(width: isCompact ? 54 : 64, height: isCompact ? 54 : 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: isCompact ? 15 : 18)
                            .stroke(PremiumTheme.gold.opacity(0.2), lineWidth: 0.5)
                    )

                Image(systemName: "star.fill")
                    .font(.system(size: isCompact ? 24 : 30))
                    .foregroundStyle(PremiumTheme.gold)
            }

            Text("Upgrade to Premium")
                .font(.system(size: isCompact ? 22 : 24, weight: .black))
                .foregroundStyle(PremiumTheme.textPrimary)
                .tracking(-0.5)
                .minimumScaleFactor(0.85)
                .lineLimit(1)

            Text("Everything you need to save and find your car.")
                .font(.system(size: isCompact ? 12 : 13, weight: .regular))
                .foregroundStyle(PremiumTheme.textSecondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, max(2, vPad - 6))
    }
}

// MARK: - Monthly subscription badge
struct SubscriptionBadgeView: View {
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(PremiumTheme.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text("Monthly subscription")
                    .font(.system(size: isCompact ? 12 : 13, weight: .semibold))
                    .foregroundStyle(PremiumTheme.green)
                    .minimumScaleFactor(0.85)
                    .lineLimit(1)

                Text("Auto-renewing monthly plan; cancel anytime")
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundStyle(PremiumTheme.green.opacity(0.6))
                    .minimumScaleFactor(0.85)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(isCompact ? 10 : 12)
        .background(PremiumTheme.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(PremiumTheme.green.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - Benefit model
struct PremiumFeature {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
}

// MARK: - Premium benefits
extension PremiumFeature {
    static let all: [PremiumFeature] = [
        PremiumFeature(
            icon: "circle.dashed",
            color: PremiumTheme.orange,
            title: "Live Activity & Dynamic Island",
            subtitle: "Timer visible without opening the app"
        ),
        PremiumFeature(
            icon: "square.grid.2x2.fill",
            color: PremiumTheme.blue,
            title: "Lock screen widgets",
            subtitle: "Distance and timer at a glance"
        ),
        PremiumFeature(
            icon: "parkingsign.circle.fill",
            color: PremiumTheme.teal,
            title: "Nearby parking search",
            subtitle: "Search spots, filters, and details"
        ),
        PremiumFeature(
            icon: "bolt.circle.fill",
            color: PremiumTheme.purple,
            title: "Action Button shortcut",
            subtitle: "Save your car with one press"
        ),
        PremiumFeature(
            icon: "clock.fill",
            color: PremiumTheme.green,
            title: "90-day parking history",
            subtitle: "Keep more completed parking sessions"
        ),
        PremiumFeature(
            icon: "mappin.and.ellipse",
            color: PremiumTheme.gold,
            title: "Frequent zones",
            subtitle: "Quick access to your usual spots"
        ),
        PremiumFeature(
            icon: "bell.fill",
            color: PremiumTheme.red,
            title: "Configurable alerts",
            subtitle: "Choose parking reminder timings"
        ),
        PremiumFeature(
            icon: "brain.head.profile",
            color: PremiumTheme.gold,
            title: "Smart duration suggestions",
            subtitle: "Suggested timers from your history"
        ),
        PremiumFeature(
            icon: "nosign",
            color: PremiumTheme.blue,
            title: "No ads",
            subtitle: "Premium removes in-app ads"
        )
    ]
}

// MARK: - Carte listant les avantages
struct FeaturesListView: View {
    let isCompact: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(PremiumFeature.all.enumerated()), id: \.offset) { index, feature in
                FeatureRowView(feature: feature, isCompact: isCompact)

                if index < PremiumFeature.all.count - 1 {
                    Rectangle()
                        .fill(PremiumTheme.separator.opacity(0.7))
                        .frame(height: 1)
                        .padding(.leading, 62)
                }
            }
        }
        .background(PremiumTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(PremiumTheme.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Ligne d'avantage
struct FeatureRowView: View {
    let feature: PremiumFeature
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9)
                .fill(feature.color.opacity(0.12))
                .frame(width: isCompact ? 29 : 32, height: isCompact ? 29 : 32)
                .overlay(
                    Image(systemName: feature.icon)
                        .font(.system(size: isCompact ? 12 : 14, weight: .semibold))
                        .foregroundStyle(feature.color)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title)
                    .font(.system(size: isCompact ? 12 : 13, weight: .semibold))
                    .foregroundStyle(PremiumTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(feature.subtitle)
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundStyle(PremiumTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 4)

            ZStack {
                Circle()
                    .fill(PremiumTheme.blue)
                    .frame(width: isCompact ? 18 : 20, height: isCompact ? 18 : 20)
                Image(systemName: "checkmark")
                    .font(.system(size: isCompact ? 8 : 9, weight: .bold))
                    .foregroundStyle(PremiumTheme.textOnAccent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isCompact ? 6 : 9)
    }
}

// MARK: - Carte prix + CTA
struct PriceCardView: View {
    @ObservedObject var vm: PremiumViewModel
    let isCompact: Bool

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [PremiumTheme.transparent, PremiumTheme.gold.opacity(0.5), PremiumTheme.transparent],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1.5)

            VStack(spacing: isCompact ? 10 : 12) {
                VStack(spacing: isCompact ? 8 : 10) {
                    PlanOptionCardView(
                        title: "Lifetime",
                        subtitle: "One-time payment · lifetime access",
                        price: vm.lifetimeDisplayPrice,
                        trailingLabel: vm.lifetimeSavingsBadgeText,
                        isSelected: vm.selectedPlan == .lifetime,
                        isCompact: isCompact,
                        action: { vm.selectPlan(.lifetime) }
                    )

                    PlanOptionCardView(
                        title: "Monthly",
                        subtitle: "Auto-renewing monthly subscription",
                        price: vm.monthlyDisplayPrice,
                        trailingLabel: vm.monthlyTrailingLabel,
                        isSelected: vm.selectedPlan == .monthly,
                        isCompact: isCompact,
                        action: { vm.selectPlan(.monthly) }
                    )
                }

                StoreAvailabilityStateView(vm: vm, isCompact: isCompact)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(vm.displayedPrice)
                        .font(.system(size: isCompact ? 30 : 34, weight: .black))
                        .foregroundStyle(PremiumTheme.textPrimary)
                        .tracking(-1.1)
                        .minimumScaleFactor(0.85)
                        .lineLimit(1)

                    if vm.selectedPlan == .monthly {
                        Text("/ month")
                            .font(.system(size: isCompact ? 13 : 14))
                            .foregroundStyle(PremiumTheme.textSecondary)
                            .padding(.bottom, 5)
                            .minimumScaleFactor(0.85)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await vm.purchase() }
                } label: {
                    HStack(spacing: 8) {
                        if vm.isPurchasing || vm.isStoreLoading {
                            ProgressView()
                                .tint(PremiumTheme.textOnAccent)
                        } else {
                            Image(systemName: vm.canStartPurchase ? "star.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 14))
                            Text(vm.purchaseButtonTitle)
                                .font(.system(size: 16, weight: .bold))
                                .minimumScaleFactor(0.85)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(PremiumTheme.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: isCompact ? 46 : 50)
                    .background(PremiumTheme.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .disabled(vm.isPurchasing)
                .buttonStyle(.plain)

                Text(vm.displayedPriceWithPeriod)
                    .font(.system(size: 11))
                    .foregroundStyle(PremiumTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    .lineLimit(1)

                Text(vm.includedSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(PremiumTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.82)
                    .lineLimit(2)
            }
            .padding(isCompact ? 12 : 16)
        }
        .background(PremiumTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(PremiumTheme.gold.opacity(0.25), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }
}

struct StoreAvailabilityStateView: View {
    @ObservedObject var vm: PremiumViewModel
    let isCompact: Bool

    var body: some View {
        if vm.isStoreUnavailable {
            VStack(alignment: .leading, spacing: 7) {
                Text(vm.storeIssueTitle ?? "Offers unavailable")
                    .font(.system(size: isCompact ? 12 : 13, weight: .semibold))
                    .foregroundStyle(PremiumTheme.textPrimary)

                Text(vm.storeIssueMessage ?? "Unable to load subscription products right now.")
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundStyle(PremiumTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let details = vm.storeIssueTechnicalDetails {
                    Text(details)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(PremiumTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await vm.retryLoadingProducts() }
                } label: {
                    Text("Retry")
                        .font(.system(size: isCompact ? 11 : 12, weight: .semibold))
                        .foregroundStyle(PremiumTheme.blue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(isCompact ? 9 : 11)
            .background(PremiumTheme.separator.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(PremiumTheme.cardBorder, lineWidth: 0.6)
            )
        }
    }
}

struct PlanOptionCardView: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let price: String
    let trailingLabel: String
    let isSelected: Bool
    let isCompact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: isCompact ? 13 : 14, weight: .bold))
                        .foregroundStyle(PremiumTheme.textPrimary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: isCompact ? 10 : 11))
                        .foregroundStyle(PremiumTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(price)
                        .font(.system(size: isCompact ? 14 : 15, weight: .black))
                        .foregroundStyle(PremiumTheme.textPrimary)
                        .lineLimit(1)

                    Text(trailingLabel)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSelected ? PremiumTheme.gold : PremiumTheme.textTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((isSelected ? PremiumTheme.gold : PremiumTheme.separator).opacity(0.14))
                        .clipShape(Capsule())
                        .lineLimit(1)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? PremiumTheme.blue : PremiumTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isCompact ? 9 : 10)
            .background(isSelected ? PremiumTheme.blue.opacity(0.08) : PremiumTheme.separator.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? PremiumTheme.blue.opacity(0.45) : PremiumTheme.cardBorder, lineWidth: isSelected ? 1 : 0.6)
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Footer
struct PremiumFooterView: View {
    @ObservedObject var vm: PremiumViewModel

    var body: some View {
        VStack(spacing: 10) {
            Text("MosiMap Premium renews automatically unless canceled at least 24 hours before the end of the current period. You can manage or cancel your subscription in your App Store account settings.")
                .font(.system(size: 10))
                .foregroundStyle(PremiumTheme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("We use location for core parking features and may rely on Supabase for account data, AdMob for ads, and diagnostics services. You can request deletion of your data at any time.")
                .font(.system(size: 10))
                .foregroundStyle(PremiumTheme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await vm.restorePurchases() }
            } label: {
                if vm.isRestoring {
                    ProgressView()
                        .tint(PremiumTheme.textSecondary)
                } else {
                    Text("Restore Purchases")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PremiumTheme.textSecondary)
                        .minimumScaleFactor(0.85)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 18) {
                Link("Terms of Use", destination: AppConfig.termsURL)
                Link("Privacy Policy", destination: AppConfig.privacyPolicyURL)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(PremiumTheme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PremiumTheme.separator.opacity(0.8))
                .frame(height: 1)
        }
    }
}

#Preview {
    PremiumView()
}

#else

struct PremiumView: View {
    var body: some View {
        Text("Premium unavailable on this platform")
            .foregroundStyle(.secondary)
            .padding()
    }
}

#endif
