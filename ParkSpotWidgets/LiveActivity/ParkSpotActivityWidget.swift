#if os(iOS)
import ActivityKit
import WidgetKit
import SwiftUI
import UIKit

private struct ParkSpotLiveTheme {
    var background: Color {
        Color(uiColor: .systemBackground)
    }

    var primaryText: Color {
        .primary
    }

    var secondaryText: Color {
        .secondary
    }

    var noteBackground: Color {
        Color(uiColor: .tertiarySystemFill)
    }

    var noteText: Color {
        .primary.opacity(0.9)
    }

    var timerAccent: Color {
        Color(hex: "30D158")
    }
}

private struct CompactCountdownText: View {
    let endTime: Date
    let font: Font
    let color: Color

    var body: some View {
        let now = Date()
        let upperBound = max(now, endTime)

        Text(timerInterval: now...upperBound, countsDown: true)
            .font(font)
            .foregroundColor(color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

// MARK: - Live Activity Widget
@available(iOS 16.2, *)
struct ParkingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ParkingActivityAttributes.self) { context in
            // Lock Screen — même vue
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeadingView(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingView(context: context)
                }
            } compactLeading: {
                CompactLeadingView()
            } compactTrailing: {
                CompactTrailingView(context: context)
            } minimal: {
                MinimalView()
            }
        }
    }
}

// MARK: - Lock Screen
@available(iOS 16.2, *)
struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<ParkingActivityAttributes>

    private var theme: ParkSpotLiveTheme {
        ParkSpotLiveTheme()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ExpandedLeadingView(context: context)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            ExpandedTrailingView(context: context)
                .frame(width: 124, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(theme.background)
    }
}

// MARK: - ExpandedLeadingView
/// Colonne gauche du Live Activity expanded
@available(iOS 16.2, *)
struct ExpandedLeadingView: View {
    let context: ActivityViewContext<ParkingActivityAttributes>

    private var theme: ParkSpotLiveTheme {
        ParkSpotLiveTheme()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Header
            HStack(spacing: 7) {
                Circle()
                    .fill(Color(hex: "007AFF"))
                    .frame(width: 7, height: 7)
                Text("MosiMap · Active")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.bottom, 6)

            // Adresse
            Text(context.state.address)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(theme.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            Text(context.state.city)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.leading, 18)
        .padding(.top, 14)
    }
}

// MARK: - ExpandedTrailingView
/// État à droite du mode expanded (sans minuteur texte)
@available(iOS 16.2, *)
struct ExpandedTrailingView: View {
    let context: ActivityViewContext<ParkingActivityAttributes>

    private var theme: ParkSpotLiveTheme {
        ParkSpotLiveTheme()
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // Badge LIVE
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: "FF3B30"))
                    .frame(width: 5, height: 5)
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: "FF3B30"))
                    .kerning(0.5)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color(hex: "FF3B30").opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.bottom, 6)

            // Temps restant (sans mots minutes/seconde)
            if context.state.isTimerActive, let endTime = context.state.endTime {
                HStack {
                    Spacer(minLength: 0)
                    CompactCountdownText(
                        endTime: endTime,
                        font: .system(size: 28, weight: .black, design: .rounded),
                        color: theme.timerAccent
                    )
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Color(hex: "34C759"))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }

            ParkingLiveInfoStack(context: context)
                .padding(.top, 1)
        }
        .padding(.trailing, 18)
        .padding(.top, 14)
    }

}
private struct ParkingLiveInfoStack: View {
    let context: ActivityViewContext<ParkingActivityAttributes>

    private var theme: ParkSpotLiveTheme {
        ParkSpotLiveTheme()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let place = cleanedWidgetText(context.state.note) {
                ParkingLiveInfoRow(
                    icon: "mappin.and.ellipse",
                    text: place,
                    color: theme.noteText,
                    lineLimit: 2
                )
            }

            if let level = cleanedWidgetText(context.state.parkingLevel) {
                ParkingLiveInfoRow(
                    icon: "building.2.fill",
                    text: "Lvl. \(level)",
                    color: Color(hex: "CF7EF5")
                )
            }

            if let rate = widgetHourlyRate(from: context.state.note) {
                ParkingLiveInfoRow(
                    icon: "eurosign.circle.fill",
                    text: "\(formattedWidgetCurrency(rate))/h",
                    color: theme.timerAccent
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ParkingLiveInfoRow: View {
    let icon: String
    let text: String
    let color: Color
    var lineLimit: Int = 1

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(lineLimit)
                .minimumScaleFactor(0.75)
        }
        .foregroundColor(color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func widgetHourlyRate(from value: String?) -> Double? {
    guard let value else { return nil }
    let patterns = [
        #"\[\[(?:I?PS)_RATE_[A-Z]{3}:([0-9]+(?:[\.,][0-9]+)?)\]\]"#,
        #"(?:I?PS)_RATE_[A-Z]{3}:([0-9]+(?:[\.,][0-9]+)?)"#
    ]

    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
            let numberRange = Range(match.range(at: 1), in: value),
            let amount = Double(value[numberRange].replacingOccurrences(of: ",", with: "."))
        else {
            continue
        }

        return amount
    }

    return nil
}

private func formattedWidgetCurrency(_ amount: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.locale = Locale.current
    formatter.currencyCode = "EUR"
    formatter.maximumFractionDigits = 2
    formatter.minimumFractionDigits = 2
    return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f €", amount)
}

private func cleanedWidgetText(_ value: String?) -> String? {
    guard let value else { return nil }
    let patterns = [
        #"\s*\[\[(?:I?PS)_RATE_[A-Z]{3}:[0-9]+(?:[\.,][0-9]+)?\]\]"#,
        #"\s*(?:I?PS)_RATE_[A-Z]{3}:[0-9]+(?:[\.,][0-9]+)?"#
    ]

    var cleaned = value
    for pattern in patterns {
        cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
}

// MARK: - CompactLeadingView
@available(iOS 16.2, *)
struct CompactLeadingView: View {
    var body: some View {
        Image(systemName: "parkingsign")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Color(hex: "007AFF"))
    }
}

// MARK: - CompactTrailingView
@available(iOS 16.2, *)
struct CompactTrailingView: View {
    let context: ActivityViewContext<ParkingActivityAttributes>

    var body: some View {
        Group {
            if context.state.isTimerActive, let endTime = context.state.endTime {
                CompactCountdownText(
                    endTime: endTime,
                    font: .system(size: 9, weight: .bold, design: .rounded),
                    color: Color(hex: "30D158")
                )
            } else {
                Circle()
                    .fill(Color(hex: "34C759"))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(maxWidth: 34, alignment: .trailing)
    }
}

// MARK: - MinimalView
@available(iOS 16.2, *)
struct MinimalView: View {
    var body: some View {
        Image(systemName: "parkingsign")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(hex: "007AFF"))
            .frame(width: 24, height: 24)
            .background(Color(hex: "007AFF").opacity(0.15))
            .clipShape(Circle())
    }
}

// MARK: - Color helper
private extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        scanner.currentIndex = hex.hasPrefix("#") ? hex.index(after: hex.startIndex) : hex.startIndex
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

#endif

/*
import SwiftUI
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit

struct ParkSpotActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ParkingLiveActivityAttributes.self) { context in
            ParkingLiveLockScreenContainer(context: context)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    ExpandedParkingIslandView(context: context)
                }
            } compactLeading: {
                ParkingBadgeCircle()
            } compactTrailing: {
                if context.state.timerActive {
                    RemainingTimeText(expiryDate: context.state.expiryDate, style: .hhmm)
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(ParkingLivePalette.timerAmber)
                } else {
                    Text("Actif")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                ParkingBadgeCircle()
            }
        }
    }
}

private struct ParkingLiveLockScreenContainer: View {
    let context: ActivityViewContext<ParkingLiveActivityAttributes>

    var body: some View {
        Group {
            if context.state.timerActive {
                LockScreenTimerCard(context: context)
            } else {
                LockScreenNoTimerCard(context: context)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct LockScreenTimerCard: View {
    let context: ActivityViewContext<ParkingLiveActivityAttributes>

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text((context.state.parkingType.isPaidPricing ? "Parking payant" : "Parking gratuit").activityLocalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 8) {
                    Text(context.attributes.streetAddress)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    HStack(spacing: 6) {
                        DetailChip(icon: "car.fill", text: "\(max(0, context.state.currentDistanceMeters)) m", tint: ParkingLivePalette.distanceGreen)
                        DetailChip(icon: "building.2.fill", text: String(format: "Niv. %@".activityLocalized, context.state.floorLevel), tint: ParkingLivePalette.levelPurple)
                    }
                }

                RemainingTimeText(expiryDate: context.state.expiryDate, style: .mmss)
                    .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ParkingLivePalette.timerAmber)

                ProgressView(value: progress)
                    .tint(ParkingLivePalette.timerAmber)
            }
        }
    }

    private var progress: Double {
        let total = max(1, context.state.totalParkingDurationSeconds)
        let elapsed = max(0, total - context.state.expiryDate.timeIntervalSinceNow)
        return min(max(elapsed / total, 0), 1)
    }
}

private struct LockScreenNoTimerCard: View {
    let context: ActivityViewContext<ParkingLiveActivityAttributes>

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("Underground".activityLocalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 8) {
                    Text(context.attributes.neighborhoodOrParkingName)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    HStack(spacing: 6) {
                        DetailChip(icon: "car.fill", text: "\(max(0, context.state.currentDistanceMeters)) m", tint: ParkingLivePalette.distanceGreen)
                        DetailChip(icon: "building.2.fill", text: String(format: "Lvl. %@".activityLocalized, context.state.floorLevel), tint: ParkingLivePalette.levelPurple)
                        DetailChip(icon: "arrow.down.circle.fill", text: context.state.entranceLabel ?? "Entrance B".activityLocalized, tint: ParkingLivePalette.brandBlue)
                    }
                }

                Text("Active parking".activityLocalized)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct ExpandedParkingIslandView: View {
    let context: ActivityViewContext<ParkingLiveActivityAttributes>
    private let levels = ["-2", "-1", "RDC", "B1", "B2"]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(Date.now.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(context.attributes.neighborhoodOrParkingName)
                    .font(.caption.weight(.semibold))
            }

            ParkingBadgeCircle()

            IslandCard(title: "Position") {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 52)
                        .overlay {
                            Label("Mini map".activityLocalized, systemImage: "map")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    Text("✓ Position retrieved".activityLocalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ParkingLivePalette.distanceGreen)
                    Text(String(format: "Parking type: %@".activityLocalized, context.state.parkingType.rawValue.activityLocalized))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            IslandCard(title: "Floor") {
                HStack(spacing: 6) {
                    ForEach(levels, id: \.self) { level in
                        FloorChip(level: level, selected: selectedFloor == level)
                    }
                }
            }

            IslandCard(title: "Marker") {
                Text(context.state.landmarkNote?.isEmpty == false ? context.state.landmarkNote! : "Spot number (e.g. Spot 45, Level 1)".activityLocalized)
                    .font(.caption2)
                    .foregroundStyle(context.state.landmarkNote?.isEmpty == false ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 10) {
                ActionButton(title: "Cancel")
                ActionButton(title: "Save")
            }

            HStack {
                BottomNavItem(icon: "map")
                Spacer()
                BottomNavItem(icon: "parkingsign.circle.fill", selected: true)
                Spacer()
                BottomNavItem(icon: "person.crop.circle")
            }
            .padding(.horizontal, 12)
        }
    }

    private var selectedFloor: String {
        let floor = context.state.floorLevel.uppercased().replacingOccurrences(of: "NIV.", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch floor {
        case "B2", "-2": return "B2"
        case "B1", "-1": return "B1"
        case "RDC": return "RDC"
        default: return floor
        }
    }
}

private struct RemainingTimeText: View {
    enum Style { case hhmm, mmss }

    let expiryDate: Date
    let style: Style

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let diff = expiryDate.timeIntervalSince(timeline.date)
            let remaining = diff.isFinite ? Int(diff) : 0
            Text(format(remaining: max(0, remaining)))
        }
    }

    private func format(remaining: Int) -> String {
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        switch style {
        case .hhmm:
            return String(format: "%02d:%02d", hours, minutes)
        case .mmss:
            let totalMinutes = remaining / 60
            return String(format: "%02d:%02d", totalMinutes, seconds)
        }
    }
}

private struct ParkingBadgeCircle: View {
    var body: some View {
        Circle()
            .fill(ParkingLivePalette.brandBlue)
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: "parkingsign")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
    }
}

private struct DetailChip: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct CardContainer<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(colorScheme == .dark ? ParkingLivePalette.cardDark : .white)
            )
    }
}

private struct IslandCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.activityLocalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? ParkingLivePalette.cardDark : ParkingLivePalette.cardLight)
        )
    }
}

private struct FloorChip: View {
    let level: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.and.down")
                .font(.system(size: 9, weight: .bold))
            Text(level)
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(selected ? ParkingLivePalette.brandBlue : Color.secondary.opacity(0.15), in: Capsule())
        .foregroundStyle(selected ? .white : .secondary)
    }
}

private struct ActionButton: View {
    let title: String

    var body: some View {
        Text(title.activityLocalized)
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(ParkingLivePalette.brandBlue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(.white)
    }
}

private struct BottomNavItem: View {
    let icon: String
    var selected: Bool = false

    var body: some View {
        Image(systemName: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? ParkingLivePalette.brandBlue : .secondary)
            .frame(width: 24, height: 24)
            .background(selected ? ParkingLivePalette.brandBlue.opacity(0.15) : .clear, in: Circle())
    }
}

private enum ParkingLivePalette {
    static let brandBlue = Color(red: 0.16, green: 0.42, blue: 0.98)
    static let timerAmber = Color(red: 0.96, green: 0.57, blue: 0.14)
    static let distanceGreen = Color(red: 0.15, green: 0.72, blue: 0.35)
    static let levelPurple = Color(red: 0.53, green: 0.33, blue: 0.93)
    static let cardLight = Color(red: 0.96, green: 0.97, blue: 0.99)
    static let cardDark = Color(red: 0.16, green: 0.17, blue: 0.20)
}

private extension String {
    var activityLocalized: String {
        NSLocalizedString(self, comment: "")
    }
}
#endif

*/
