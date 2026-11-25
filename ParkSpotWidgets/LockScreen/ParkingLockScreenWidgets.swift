import SwiftUI
import WidgetKit

// MARK: - Entry Timeline
/// Entry unique des complications Watch.
struct WatchEntry: TimelineEntry {
    let date: Date
    let data: WatchParkingData
    let hasPremiumWidgetAccess: Bool
}

// MARK: - Provider
/// Provider WidgetKit qui lit la session parking partagée.
struct WatchComplicationProvider: TimelineProvider {
    private let store = WatchParkingDataStore.shared

    func placeholder(in context: Context) -> WatchEntry {
        WatchEntry(date: .now, data: .placeholder, hasPremiumWidgetAccess: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(
            WatchEntry(
                date: .now,
                data: store.load() ?? .placeholder,
                hasPremiumWidgetAccess: store.isWidgetAccessEnabled
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        let data = store.load() ?? .placeholder
        let hasPremiumWidgetAccess = store.isWidgetAccessEnabled
        let entry = WatchEntry(date: .now, data: data, hasPremiumWidgetAccess: hasPremiumWidgetAccess)
        let policy: TimelineReloadPolicy

        if hasPremiumWidgetAccess, let end = data.endTime, data.isActive {
            // Refresh toutes les minutes si un timer est actif.
            let nextMinute = Calendar.current.date(byAdding: .minute, value: 1, to: .now) ?? .now
            policy = end > nextMinute ? .after(nextMinute) : .after(end)
        } else {
            // Refresh toutes les 15 minutes si pas de timer.
            policy = .after(Date().addingTimeInterval(900))
        }

        completion(Timeline(entries: [entry], policy: policy))
    }
}

private struct CountdownText: View {
    let endDate: Date
    let font: Font
    let color: Color

    var body: some View {
        let now = Date()
        let upperBound = max(now, endDate)

        Text(timerInterval: now...upperBound, countsDown: true)
            .font(font)
            .foregroundColor(color)
            .monospacedDigit()
    }
}

// MARK: - Circulaire Timer
/// Complication circulaire "Temps restant".
struct CircularTimerView: View {
    let entry: WatchEntry

    /// Progression restante de l'anneau (1 = plein, 0 = terminé).
    private var progress: Double {
        max(0, min(1, 1 - entry.data.progressPercent))
    }

    var body: some View {
        if entry.hasPremiumWidgetAccess {
            ZStack {
                // Anneau de fond.
                Circle()
                    .stroke(Color.orange.opacity(0.15), lineWidth: 4)

                // Anneau de progression.
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.orange,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                // Contenu central (timer ou icône voiture).
                VStack(spacing: 1) {
                    if entry.data.isActive, let end = entry.data.endTime {
                        CountdownText(
                            endDate: end,
                            font: .system(size: 18, weight: .black, design: .rounded),
                            color: .orange
                        )
                    } else {
                        Image(systemName: "car.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.blue)
                    }
                }
            }
            .widgetLabel {
                Text(entry.data.isActive ? "Time left".widgetLocalized : "MosiMap")
                    .foregroundColor(.secondary)
            }
        } else {
            PremiumCircularWidgetView(accent: .orange)
                .widgetLabel {
                    Text("Premium")
                        .foregroundColor(.secondary)
                }
        }
    }
}

// MARK: - Circulaire Distance
/// Complication circulaire "Distance".
struct CircularDistanceView: View {
    let entry: WatchEntry

    var body: some View {
        if entry.hasPremiumWidgetAccess {
            ZStack {
                // Anneau de fond.
                Circle()
                    .stroke(Color.blue.opacity(0.15), lineWidth: 4)

                // Arc décoratif quand une session est active.
                if entry.data.isActive {
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(
                            Color.blue,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }

                // Icône + distance.
                VStack(spacing: 1) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                    Text(entry.data.distanceText)
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.6)
                }
            }
            .widgetLabel {
                Text("Distance")
                    .foregroundColor(.secondary)
            }
        } else {
            PremiumCircularWidgetView(accent: .blue)
                .widgetLabel {
                    Text("Premium")
                        .foregroundColor(.secondary)
                }
        }
    }
}

// MARK: - Rectangulaire
/// Complication rectangulaire complète (voiture + timer + zone + distance).
struct RectangularView: View {
    let entry: WatchEntry

    var body: some View {
        if entry.hasPremiumWidgetAccess {
            HStack(spacing: 10) {
                // Icône véhicule.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "car.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    // Titre.
                    Text(entry.data.isActive ? "MosiMap · Active".widgetLocalized : "MosiMap")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    // Timer actif ou adresse.
                    if entry.data.isActive, let end = entry.data.endTime {
                        CountdownText(
                            endDate: end,
                            font: .system(size: 18, weight: .black, design: .rounded),
                            color: .orange
                        )
                    } else {
                        Text(entry.data.address)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }

                    // Distance + zone.
                    HStack(spacing: 4) {
                        Text(entry.data.distanceText)
                        Text("·")
                        Text(englishZoneLabel(entry.data.zoneType))
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)
            }
        } else {
            PremiumRectangularWidgetView()
        }
    }
    private func englishZoneLabel(_ zoneType: String) -> String {
        let normalized = zoneType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalized {
        case "payant", "paid":
            return "Paid".widgetLocalized
        case "gratuit", "free":
            return "Free".widgetLocalized
        case "souterrain", "underground":
            return "Underground".widgetLocalized
        case "surface", "street":
            return "Street".widgetLocalized
        case "inconnu", "unknown":
            return "Unknown".widgetLocalized
        default:
            return zoneType
        }
    }
}

// MARK: - Inline
/// Complication inline "Parking actif" + timer.
struct InlineView: View {
    let entry: WatchEntry

    var body: some View {
        if entry.hasPremiumWidgetAccess {
            if entry.data.isActive, let end = entry.data.endTime {
                HStack(spacing: 4) {
                    Image(systemName: "car.fill")
                        .foregroundColor(.orange)
                    Text("Active parking")
                    CountdownText(
                        endDate: end,
                        font: .body.monospacedDigit(),
                        color: .orange
                    )
                }
            } else {
                Label("No active parking", systemImage: "car")
                    .foregroundColor(.secondary)
            }
        } else {
            Label("MosiMap Premium", systemImage: "lock.fill")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Premium Lock
private struct PremiumCircularWidgetView: View {
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.18), lineWidth: 4)

            VStack(spacing: 2) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(accent)

                Text("PRO")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundColor(.white)
            }
        }
    }
}

private struct PremiumRectangularWidgetView: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.2))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.orange)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("MosiMap Premium")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("Widgets Watch")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Bundle widgets
/// Bundle principal des complications Watch MosiMap.
@main
struct MosiMapWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        CircularTimerWidget()
        CircularDistanceWidget()
        RectangularWidget()
        InlineWidget()

#if os(iOS)
        // Conservation du Live Activity iPhone existant.
        if #available(iOSApplicationExtension 16.2, *) {
            ParkingLiveActivityWidget()
        }
#endif
    }
}

private extension String {
    var widgetLocalized: String {
        NSLocalizedString(self, comment: "")
    }
}

/// Widget circulaire du timer.
struct CircularTimerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MosiMap.Circular.Timer", provider: WatchComplicationProvider()) { entry in
            CircularTimerView(entry: entry)
                .mosiMapWidgetBackground()
        }
        .configurationDisplayName("Timer parking")
        .description("Time remaining before expiry.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// Widget circulaire de la distance.
struct CircularDistanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MosiMap.Circular.Distance", provider: WatchComplicationProvider()) { entry in
            CircularDistanceView(entry: entry)
                .mosiMapWidgetBackground()
        }
        .configurationDisplayName("Car distance")
        .description("Distance to your car.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// Widget rectangulaire de synthèse.
struct RectangularWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MosiMap.Rectangular", provider: WatchComplicationProvider()) { entry in
            RectangularView(entry: entry)
                .mosiMapWidgetBackground()
        }
        .configurationDisplayName("Parking")
        .description("Car, timer, and distance.")
        .supportedFamilies([.accessoryRectangular])
    }
}

/// Widget inline discret.
struct InlineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MosiMap.Inline", provider: WatchComplicationProvider()) { entry in
            InlineView(entry: entry)
                .mosiMapWidgetBackground()
        }
        .configurationDisplayName("Timer inline")
        .description("Discreet timer on the watch face.")
        .supportedFamilies([.accessoryInline])
    }
}

// MARK: - Compatibilité fond widget
private extension View {
    /// Applique un fond noir compatible selon la version de plateforme.
    @ViewBuilder
    func mosiMapWidgetBackground() -> some View {
#if os(watchOS)
        if #available(watchOSApplicationExtension 10.0, *) {
            self.containerBackground(.black, for: .widget)
        } else {
            self.background(Color.black)
        }
#else
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(.black, for: .widget)
        } else {
            self.background(Color.black)
        }
#endif
    }
}

// MARK: - Données mock previews
private extension WatchEntry {
    /// Données actives de démonstration.
    static let mockActive = WatchEntry(
        date: .now,
        data: WatchParkingData(
            address: "N Portal Ave",
            fullAddress: "N Portal Ave, 10341, Cupertino",
            zoneType: "Payant",
            startTime: .now.addingTimeInterval(-1800),
            endTime: .now.addingTimeInterval(3600),
            distanceMeters: 280,
            parkingLevel: "B2",
            isActive: true,
            latitude: 37.3346,
            longitude: -122.0090
        ),
        hasPremiumWidgetAccess: true
    )

    /// Données inactives de démonstration.
    static let mockIdle = WatchEntry(date: .now, data: .placeholder, hasPremiumWidgetAccess: true)
    static let mockLocked = WatchEntry(date: .now, data: .placeholder, hasPremiumWidgetAccess: false)
}

#Preview("Circular Timer") {
    CircularTimerView(entry: .mockActive)
        .padding()
        .background(Color.black)
}

#Preview("Circular Distance") {
    CircularDistanceView(entry: .mockActive)
        .padding()
        .background(Color.black)
}

#Preview("Rectangular") {
    RectangularView(entry: .mockActive)
        .padding()
        .background(Color.black)
}

#Preview("Inline") {
    InlineView(entry: .mockActive)
        .padding()
        .background(Color.black)
}

#Preview("Watch Active Placeholder") {
    RectangularView(entry: .mockIdle)
        .padding()
        .background(Color.black)
}

#Preview("Premium Locked") {
    RectangularView(entry: .mockLocked)
        .padding()
        .background(Color.black)
}
