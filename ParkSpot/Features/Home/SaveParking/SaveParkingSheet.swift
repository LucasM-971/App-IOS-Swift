// SaveParkingSheet.swift
// New design: Full-screen dark mode form with map snapshot, cards, and minimal interactions
// Design system: OLED dark mode (0A0A0F), cards (1C1C1E), accent colors (007AFF, FF9500, 34C759)

import SwiftUI
import MapKit
import CoreLocation
import UIKit
import Combine

// MARK: - Extension Color(hex:)
extension Color {
    /// Initialise une couleur à partir d'une chaîne hexadécimale (ex: "007AFF")
    init(hex: String) {
        let scanner = Scanner(string: hex)
        scanner.currentIndex = hex.hasPrefix("#") ? hex.index(after: hex.startIndex) : hex.startIndex
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let red = Double((rgb >> 16) & 0xFF) / 255.0
        let green = Double((rgb >> 8) & 0xFF) / 255.0
        let blue = Double(rgb & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}

// MARK: - Design System Colors
struct DesignColors {
    static let background = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 10/255, green: 10/255, blue: 15/255, alpha: 1)
            : UIColor(red: 244/255, green: 244/255, blue: 248/255, alpha: 1)
    })
    static let cardBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 1)
            : .white
    })
    static let textPrimary = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .white : UIColor(red: 20/255, green: 20/255, blue: 24/255, alpha: 1)
    })
    static let textSecondary = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 142/255, green: 142/255, blue: 147/255, alpha: 1)
            : UIColor(red: 108/255, green: 108/255, blue: 112/255, alpha: 1)
    })
    static let textTertiary = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 90/255, green: 90/255, blue: 94/255, alpha: 1)
            : UIColor(red: 148/255, green: 148/255, blue: 152/255, alpha: 1)
    })
    static let accentBlue = Color(hex: "007AFF")
    static let accentOrange = Color(hex: "FF9500")
    static let accentGreen = Color(hex: "34C759")
    static let cardBorder = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor.black.withAlphaComponent(0.07)
    })
    static let buttonBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor(red: 236/255, green: 238/255, blue: 244/255, alpha: 1)
    })
    static let buttonBorder = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.12)
    })
    static let buttonShadow = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.15)
            : UIColor.black.withAlphaComponent(0.08)
    })
}

enum SaveLocationStatus {
    case gps
    case manual
    case approximate

    var label: String {
        switch self {
        case .gps: return "GPS"
        case .manual: return "Manual"
        case .approximate: return "Approx."
        }
    }

    var tint: Color {
        switch self {
        case .gps: return DesignColors.accentGreen
        case .manual: return DesignColors.accentBlue
        case .approximate: return DesignColors.accentOrange
        }
    }
}

struct SaveParkingSheet: View {

    private enum Field: Hashable {
        case parkingLevel
        case note
        case hourlyRate
    }

    @ObservedObject var vm: HomeViewModel
    let manualCoordinate: Coordinate?
    @Environment(\.dismiss) private var dismiss

    @State private var note:         String   = ""
    @State private var parkingLevel: String   = ""
    @State private var zone:         ParkingZone = .free
    @State private var hourlyRateText: String = ""
    @State private var photoData: Data? = nil
    @State private var timerTotalMinutes: Int = 0
    @State private var pickerHours: Int = 0
    @State private var pickerMinutes: Int = 0
    @State private var setTimer:     Bool     = false
    @State private var hours:        Double   = 1
    @State private var minutes:      Double   = 0
    @State private var isFrequentZoneShortcutMode: Bool = false
    @State private var frequentZoneShortcutName: String?
    @State private var hasInitializedSuggestedTimer: Bool = false
    @State private var isSmartAwayReRegisterMode: Bool = false
    @State private var showPhotoPicker: Bool = false
    @State private var showPhotoPreview: Bool = false
    @State private var showCameraUnavailableAlert: Bool = false
    @State private var locationOptimizer = LocationOptimizer()
    @State private var optimizedParkingLocation: ParkedLocation?
    @FocusState private var focusedField: Field?

    var body: some View {
        newDesignBody
    }

    private var autoDetectedParkingCoordinate: Coordinate? {
        vm.preferredAutoParkingDetectedCoordinateForSave()
    }

    private var bestOptimizedParkingLocation: ParkedLocation? {
        guard let candidate = optimizedParkingLocation ?? locationOptimizer.currentBestLocation else {
            return nil
        }

        guard candidate.horizontalAccuracy > 0 else { return candidate }

        if let currentAccuracy = vm.userLocationAccuracy,
           currentAccuracy > 0,
           candidate.horizontalAccuracy > currentAccuracy + 1 {
            return nil
        }

        return candidate
    }

    private var explicitParkingCoordinateForSave: Coordinate? {
        autoDetectedParkingCoordinate
            ?? manualCoordinate
            ?? vm.userCoordinate
            ?? bestOptimizedParkingLocation?.coordinate
    }

    private var resolvedParkingCoordinate: Coordinate? {
        explicitParkingCoordinateForSave
            ?? LastKnownLocationStore.shared.load()?.coordinate
    }

    private var locationStatus: SaveLocationStatus? {
        if manualCoordinate != nil || autoDetectedParkingCoordinate != nil {
            return .manual
        }

        if bestOptimizedParkingLocation != nil || vm.userCoordinate != nil {
            return .gps
        }

        if LastKnownLocationStore.shared.load() != nil {
            return .approximate
        }

        return nil
    }

    // MARK: - New Design Body
    private var newDesignBody: some View {
        ZStack(alignment: .bottom) {
            // 1. Map Snapshot Background
            MapSnapshotBackgroundView(coordinate: resolvedParkingCoordinate)
                .ignoresSafeArea()

            // 2. Main Content
            VStack(spacing: 0) {
                // Header
                SheetHeaderView(
                    locationStatus: locationStatus
                )

                // Address Bar
                if let coord = resolvedParkingCoordinate {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(vm.currentAddress ?? String(format: "Lat %.5f, Lon %.5f", coord.latitude, coord.longitude))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(DesignColors.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(DesignColors.background)
                    .task(id: "\(coord.latitude),\(coord.longitude)") {
                        await vm.resolveCurrentAddress(for: coord)
                    }
                }

                // Scrollable Cards
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        if !isFrequentZoneShortcutMode {
                            PricingCard(
                                selectedZone: $zone
                            )

                            ZoneTypeCard(
                                selectedZone: $zone
                            )
                        }

                        if zone.isPaidPricing {
                            TariffCard(
                                hourlyRateText: $hourlyRateText,
                                currencySymbol: tariffCurrencySymbol
                            )
                        }

                        NiveauCard(
                            selectedNiveau: $parkingLevel
                        )

                        DetailOptionalCard(
                            detailText: $note
                        )

                        if !isFrequentZoneShortcutMode {
                            TimerCard(
                                hours: $hours,
                                minutes: $minutes,
                                pickerHours: $pickerHours,
                                pickerMinutes: $pickerMinutes,
                                timerTotalMinutes: $timerTotalMinutes,
                                setTimer: $setTimer
                            )
                        }

                        PhotoCard(
                            photoData: $photoData,
                            onTapCapture: { presentCameraIfAvailable() },
                            onTapPreview: { showPhotoPreview = true }
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .scrollDismissesKeyboard(.interactively)

                // Bottom CTA
                BottomCTAView(
                    isLoading: vm.isLoading,
                    canSave: resolvedParkingCoordinate != nil,
                    onCancel: { dismiss() },
                    onSave: { performSave() }
                )
            }
            .background(DesignColors.background)
        }
        .onAppear {
            startParkingLocationOptimizationIfNeeded()

            if let smartAwayPrefill = vm.consumeSmartAwaySaveFormPrefill() {
                applySmartAwayPrefill(smartAwayPrefill)
                return
            }

            isSmartAwayReRegisterMode = false
            let shouldAutoEnableSuggestedTimer = vm.shouldAutoEnableSuggestedDurationForSaveForm()
            if let forcedZone = vm.consumeFrequentZoneShortcutForSaveForm() {
                isFrequentZoneShortcutMode = true
                frequentZoneShortcutName = forcedZone.name
                zone = forcedZone.parkingType
                if parkingLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let level = forcedZone.landmarkLevel?.trimmingCharacters(in: .whitespacesAndNewlines)
                    parkingLevel = (level?.isEmpty == false) ? (level ?? forcedZone.name) : forcedZone.name
                }
                if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let details = forcedZone.details?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !details.isEmpty {
                    note = details
                }
            }
            applySuggestedTimerIfNeeded(autoEnable: shouldAutoEnableSuggestedTimer)
        }
        .onReceive(locationOptimizer.results.receive(on: DispatchQueue.main)) { result in
            updateOptimizedParkingLocation(from: result)
        }
        .onDisappear {
            locationOptimizer.stopOptimization()
        }
        .sheet(isPresented: $showPhotoPicker) {
            SaveParkingCameraPicker(selectedImage: capturedPhotoBinding)
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showPhotoPreview) {
            if let previewImage = photoPreviewImage {
                PhotoPreviewFullscreenView(image: previewImage)
            }
        }
        .tint(DesignColors.accentBlue)
        .alert("Camera unavailable", isPresented: $showCameraUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device cannot access the camera right now.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                HStack(spacing: 0) {
                    Button(action: focusPreviousInput) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 56, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Champ précédent")

                    Button(action: focusNextInput) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 56, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Champ suivant")

                    Spacer(minLength: 0)

                    Button(action: dismissKeyboard) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 24, weight: .semibold))
                            .frame(width: 56, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fermer le clavier")
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(.systemGray5))
                )
            }
        }
    }

}

private struct SaveParkingCameraPicker: UIViewControllerRepresentable {
    @Binding var selectedImage: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: SaveParkingCameraPicker

        init(parent: SaveParkingCameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.selectedImage = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private struct CalendarSuggestionView: View {
    let title: String
    let duration: TimeInterval
    let onApply: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Suggestion calendrier".psLocalized, systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.indigo)
                Spacer()
                Button("Ignorer".psLocalized, action: onDismiss)
                    .font(.caption)
            }

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Button {
                onApply()
            } label: {
                Text(String(format: "save_parking.use_duration_format".psLocalized, durationText))
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var durationText: String {
        let totalMinutes = max(0, Int(duration / 60))
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return "\(h) h \(m) min"
        }
        return "\(m) min"
    }
}

// MARK: - New Component Views

/// 1. Map Snapshot Background View (non-interactive)
struct MapSnapshotBackgroundView: View {
    let coordinate: Coordinate?
    @State private var mapImage: UIImage? = nil
    @State private var lookAroundScene: MKLookAroundScene?

    var body: some View {
        ZStack {
            // Fallback gradient if no snapshot
            LinearGradient(
                colors: [Color(hex: "1a2744"), Color(hex: "0d1b35")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Street-level Look Around if available
            if #available(iOS 17.0, *), let lookAroundScene {
                LookAroundPreview(initialScene: lookAroundScene)
                    .frame(height: 160)
            }

            // Map snapshot fallback
            else if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 160)
            }

            // Gradient overlay to fade into black background
            LinearGradient(
                colors: [.clear, DesignColors.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 160)
        }
        .frame(height: 160)
        .onAppear {
            generateSnapshot()
        }
        .onChange(of: coordinate) { _, _ in
            generateSnapshot()
        }
    }

    private func generateSnapshot() {
        guard let coordinate else { return }

        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)

        if #available(iOS 17.0, *) {
            Task {
                let request = MKLookAroundSceneRequest(coordinate: center)
                if let scene = try? await request.scene {
                    await MainActor.run {
                        self.lookAroundScene = scene
                        self.mapImage = nil
                    }
                    return
                }
                await MainActor.run {
                    self.lookAroundScene = nil
                }
                generateMapSnapshot(center: center)
            }
            return
        }

        generateMapSnapshot(center: center)
    }

    private func generateMapSnapshot(center: CLLocationCoordinate2D) {
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: UIScreen.main.bounds.width, height: 160)
        options.scale = UIScreen.main.scale

        MKMapSnapshotter(options: options).start { snapshot, error in
            if let snapshot = snapshot?.image {
                DispatchQueue.main.async {
                    self.mapImage = snapshot
                }
            }
        }
    }
}

/// 2. Sheet Header View (Annuler | Enregistrer | GPS Badge)
struct SheetHeaderView: View {
    let locationStatus: SaveLocationStatus?
    @State private var pulseAnimation = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Enregistrer")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(DesignColors.textPrimary)

                HStack {
                    Spacer()
                    if let locationStatus {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(locationStatus.tint)
                                .frame(width: 6, height: 6)
                                .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                                .animation(
                                    pulseAnimation
                                    ? .easeInOut(duration: 1).repeatForever()
                                    : .default,
                                    value: pulseAnimation
                                )

                            Text("\(locationStatus.label) ✓")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(locationStatus.tint)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(locationStatus.tint.opacity(0.15))
                        .cornerRadius(20)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()
                .opacity(0.06)
        }
        .background(DesignColors.background)
        .onAppear {
            pulseAnimation = true
        }
        .onDisappear {
            pulseAnimation = false
        }
    }
}

/// 4. Zone Type Card
// MARK: - Zone Helpers
private enum ZoneModifier {
    case none
    case underground
    case resident
    case covered
    case publicParking
    case surface
    case other
}

private enum ZonePricing {
    case none
    case free
    case paid
}

private func makeZone(pricing: ZonePricing, modifier: ZoneModifier) -> ParkingZone {
    switch (pricing, modifier) {
    case (.none, .none): return .unknown
    case (.none, .underground): return .underground
    case (.none, .resident): return .resident
    case (.none, .covered): return .covered
    case (.none, .publicParking): return .publicParking
    case (.none, .surface): return .surface
    case (.none, .other): return .other
    case (.free, .none): return .free
    case (.paid, .none): return .paid
    case (.free, .underground): return .freeUnderground
    case (.paid, .underground): return .paidUnderground
    case (.free, .resident): return .freeResident
    case (.paid, .resident): return .paidResident
    case (.free, .covered): return .freeCovered
    case (.paid, .covered): return .paidCovered
    case (.free, .publicParking): return .freePublicParking
    case (.paid, .publicParking): return .paidPublicParking
    case (.free, .surface): return .freeSurface
    case (.paid, .surface): return .paidSurface
    case (.free, .other): return .freeOther
    case (.paid, .other): return .paidOther
    }
}

struct ZoneTypeCard: View {
    @Binding var selectedZone: ParkingZone

    private var selectedModifier: ZoneModifier {
        if selectedZone.isUndergroundType { return .underground }
        if selectedZone.isResidentType { return .resident }
        switch selectedZone {
        case .covered, .freeCovered, .paidCovered:
            return .covered
        case .publicParking, .freePublicParking, .paidPublicParking:
            return .publicParking
        case .surface, .freeSurface, .paidSurface:
            return .surface
        case .other, .freeOther, .paidOther:
            return .other
        default:
            return .none
        }
    }

    private var selectedPricing: ZonePricing {
        switch selectedZone {
        case .free,
            .freeResident,
            .freeUnderground,
            .freeCovered,
            .freePublicParking,
            .freeSurface,
            .freeOther:
            return .free
        case .paid,
            .paidResident,
            .paidUnderground,
            .paidCovered,
            .paidPublicParking,
            .paidSurface,
            .paidOther:
            return .paid
        default:
            return .none
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("TYPE DE ZONE".psLocalized)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(DesignColors.textSecondary)
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // Zone modifiers (can combine with free/paid)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ZonePillView(
                    symbolName: "building.2.fill",
                    name: ParkingZone.underground.localizedName,
                    isSelected: selectedModifier == .underground,
                    onTap: {
                        selectedZone = makeZone(
                            pricing: selectedPricing,
                            modifier: selectedModifier == .underground ? .none : .underground
                        )
                    }
                )

                ZonePillView(
                    symbolName: "house.fill",
                    name: ParkingZone.resident.localizedName,
                    isSelected: selectedModifier == .resident,
                    onTap: {
                        selectedZone = makeZone(
                            pricing: selectedPricing,
                            modifier: selectedModifier == .resident ? .none : .resident
                        )
                    }
                )

                ZonePillView(
                    symbolName: "building.fill",
                    name: ParkingZone.covered.localizedName,
                    isSelected: selectedModifier == .covered,
                    onTap: {
                        selectedZone = makeZone(
                            pricing: selectedPricing,
                            modifier: selectedModifier == .covered ? .none : .covered
                        )
                    }
                )

                ZonePillView(
                    symbolName: "person.3.fill",
                    name: ParkingZone.publicParking.localizedName,
                    isSelected: selectedModifier == .publicParking,
                    onTap: {
                        selectedZone = makeZone(
                            pricing: selectedPricing,
                            modifier: selectedModifier == .publicParking ? .none : .publicParking
                        )
                    }
                )

                ZonePillView(
                    symbolName: "sun.max.fill",
                    name: ParkingZone.surface.localizedName,
                    isSelected: selectedModifier == .surface,
                    onTap: {
                        selectedZone = makeZone(
                            pricing: selectedPricing,
                            modifier: selectedModifier == .surface ? .none : .surface
                        )
                    }
                )

                ZonePillView(
                    symbolName: "ellipsis.circle.fill",
                    name: ParkingZone.other.localizedName,
                    isSelected: selectedModifier == .other,
                    onTap: {
                        selectedZone = makeZone(
                            pricing: selectedPricing,
                            modifier: selectedModifier == .other ? .none : .other
                        )
                    }
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(DesignColors.cardBackground)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(DesignColors.cardBorder, lineWidth: 0.5)
        )
    }
}

/// 4. Pricing Card
struct PricingCard: View {
    @Binding var selectedZone: ParkingZone

    private var selectedModifier: ZoneModifier {
        if selectedZone.isUndergroundType { return .underground }
        if selectedZone.isResidentType { return .resident }
        switch selectedZone {
        case .covered, .freeCovered, .paidCovered:
            return .covered
        case .publicParking, .freePublicParking, .paidPublicParking:
            return .publicParking
        case .surface, .freeSurface, .paidSurface:
            return .surface
        case .other, .freeOther, .paidOther:
            return .other
        default:
            return .none
        }
    }

    private var isPaidSelected: Bool {
        selectedPricing == .paid
    }

    private var isFreeSelected: Bool {
        selectedPricing == .free
    }

    private var selectedPricing: ZonePricing {
        switch selectedZone {
        case .free,
            .freeResident,
            .freeUnderground,
            .freeCovered,
            .freePublicParking,
            .freeSurface,
            .freeOther:
            return .free
        case .paid,
            .paidResident,
            .paidUnderground,
            .paidCovered,
            .paidPublicParking,
            .paidSurface,
            .paidOther:
            return .paid
        default:
            return .none
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("TARIFICATION")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(DesignColors.textSecondary)
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // Pricing pills (mutually exclusive)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ZonePillView(
                    symbolName: "parkingsign",
                    name: ParkingZone.free.localizedName,
                    isSelected: isFreeSelected,
                    onTap: {
                        selectedZone = makeZone(
                            pricing: isFreeSelected ? .none : .free,
                            modifier: selectedModifier
                        )
                    }
                )

                ZonePillView(
                    symbolName: "creditcard.fill",
                    name: ParkingZone.paid.localizedName,
                    isSelected: isPaidSelected,
                    onTap: {
                        selectedZone = makeZone(
                            pricing: isPaidSelected ? .none : .paid,
                            modifier: selectedModifier
                        )
                    }
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(DesignColors.cardBackground)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(DesignColors.cardBorder, lineWidth: 0.5)
        )
    }
}

/// Zone Pill Component
struct ZonePillView: View {
    let symbolName: String
    let name: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill((isSelected ? DesignColors.accentBlue.opacity(0.22) : DesignColors.buttonBackground))
                        .frame(width: 34, height: 34)

                    Image(systemName: symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isSelected ? DesignColors.accentBlue : DesignColors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isSelected ? DesignColors.textPrimary : DesignColors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer()
            }
            .frame(height: 56)
            .padding(.horizontal, 12)
            .background(
                isSelected ?
                DesignColors.accentBlue.opacity(0.2) :
                DesignColors.buttonBackground
            )
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isSelected ? DesignColors.accentBlue : DesignColors.buttonBorder,
                        lineWidth: 1.5
                    )
            )
            .shadow(color: DesignColors.buttonShadow, radius: 3, y: 1)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

/// 5. Niveau Card
struct NiveauCard: View {
    @Binding var selectedNiveau: String
    @State private var isManualEntrySelected = false

    private let levels = ["-2", "-1", "0", "+1", "+2"]
    private var trimmedSelectedNiveau: String {
        selectedNiveau.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("LEVEL / LANDMARK".psLocalized)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(DesignColors.textSecondary)
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // Grille niveaux
            HStack(spacing: 8) {
                ForEach(levels, id: \.self) { level in
                    Button {
                        selectedNiveau = level
                        isManualEntrySelected = false
                    } label: {
                        Text(level)
                            .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundColor(isPresetSelected(level) ? DesignColors.textPrimary : DesignColors.textSecondary)
                        .background(isPresetSelected(level) ? DesignColors.accentBlue : DesignColors.buttonBackground)
                        .cornerRadius(13)
                        .overlay(
                            RoundedRectangle(cornerRadius: 13)
                                .stroke(isPresetSelected(level) ? DesignColors.accentBlue : DesignColors.buttonBorder, lineWidth: 1)
                        )
                        .shadow(color: DesignColors.buttonShadow, radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPresetSelected(level))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            // Manual entry field (same style as détail input zone)
            ZStack(alignment: .leading) {
                if selectedNiveau.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Add a floor or landmark".psLocalized)
                        .font(.system(size: 15))
                        .foregroundColor(DesignColors.textTertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }

                TextField("", text: $selectedNiveau)
                    .font(.system(size: 15))
                    .foregroundColor(DesignColors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .onChange(of: selectedNiveau) { _, _ in
                        syncManualSelectionState()
                    }
            }
            .background(DesignColors.buttonBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DesignColors.buttonBorder, lineWidth: 1)
            )
            .shadow(color: DesignColors.buttonShadow, radius: 3, y: 1)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(DesignColors.cardBackground)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(DesignColors.cardBorder, lineWidth: 0.5)
        )
        .onAppear {
            syncManualSelectionState()
        }
    }

    private func isPresetSelected(_ level: String) -> Bool {
        !isManualEntrySelected && trimmedSelectedNiveau == level
    }

    private func syncManualSelectionState() {
        let trimmed = trimmedSelectedNiveau
        isManualEntrySelected = !trimmed.isEmpty && !levels.contains(trimmed)
    }
}

/// 5b. Tarif Card (visible uniquement si parking payant)
struct TariffCard: View {
    @Binding var hourlyRateText: String
    let currencySymbol: String
    @FocusState private var isManualFieldFocused: Bool
    @State private var isManualEntrySelected = false

    private let presetValues: [String] = ["0,5", "1", "2", "5"]
    private var trimmedHourlyRateText: String {
        hourlyRateText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isManualHighlightActive: Bool {
        isManualEntrySelected && !trimmedHourlyRateText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TARIF")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(DesignColors.textSecondary)
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "banknote")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isManualHighlightActive ? .white : DesignColors.accentBlue)

                    TextField("Tarif horaire (\(currencySymbol)/h)", text: $hourlyRateText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isManualHighlightActive ? .white : DesignColors.textPrimary)
                        .focused($isManualFieldFocused)
                        .onChange(of: hourlyRateText) { _, newValue in
                            guard isManualFieldFocused else { return }
                            isManualEntrySelected = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }

                    Text("\(currencySymbol)/h")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isManualHighlightActive ? Color.white.opacity(0.82) : DesignColors.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(isManualHighlightActive ? DesignColors.accentBlue : DesignColors.buttonBackground)
                .cornerRadius(13)
                .overlay(
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(isManualHighlightActive ? DesignColors.accentBlue : DesignColors.buttonBorder, lineWidth: 1)
                )
                .shadow(
                    color: isManualHighlightActive ? DesignColors.accentBlue.opacity(0.28) : DesignColors.buttonShadow,
                    radius: 3,
                    y: 1
                )

                HStack(spacing: 8) {
                    ForEach(presetValues, id: \.self) { value in
                        Button {
                            hourlyRateText = value
                            isManualEntrySelected = false
                            isManualFieldFocused = false
                        } label: {
                            Text("\(value) \(currencySymbol)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(isPresetSelected(value) ? .white : DesignColors.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    isPresetSelected(value)
                                    ? DesignColors.accentBlue
                                    : DesignColors.buttonBackground
                                )
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(isPresetSelected(value) ? DesignColors.accentBlue : DesignColors.buttonBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Montant par heure")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(DesignColors.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(DesignColors.cardBackground)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(DesignColors.cardBorder, lineWidth: 0.5)
        )
        .onAppear {
            syncManualSelectionState()
        }
    }

    private func isPresetSelected(_ value: String) -> Bool {
        !isManualEntrySelected && normalized(value) == normalized(hourlyRateText)
    }

    private func syncManualSelectionState() {
        guard !trimmedHourlyRateText.isEmpty else {
            isManualEntrySelected = false
            return
        }
        isManualEntrySelected = !presetValues.contains { normalized($0) == normalized(hourlyRateText) }
    }

    private func normalized(_ value: String) -> Double? {
        let clean = value
            .replacingOccurrences(of: currencySymbol, with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(clean)
    }
}

/// 6. Timer Card
struct TimerCard: View {
    private struct DurationChipItem: Hashable {
        let id: String
        let title: String
        let minutes: Int?
        let opensCustomPicker: Bool
    }

    @Binding var hours: Double
    @Binding var minutes: Double
    @Binding var pickerHours: Int
    @Binding var pickerMinutes: Int
    @Binding var timerTotalMinutes: Int
    @Binding var setTimer: Bool
    @State private var showCustomPicker = false

    private let presetDurations: [(title: String, minutes: Int)] = [
        ("30m", 30),
        ("1h", 60),
        ("1h30", 90),
        ("2h", 120)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Text("DURÉE MAX")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(DesignColors.textSecondary)

                Spacer()

                Toggle("", isOn: $setTimer)
                    .labelsHidden()
                    .tint(DesignColors.accentOrange)
            }
            .padding(.top, 14)
            .padding(.horizontal, 16)
            .padding(.bottom, setTimer ? 8 : 14)

            if setTimer {
                // Duration chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(displayedDurationPresets, id: \.id) { preset in
                            DurationChip(
                                title: preset.title,
                                isSelected: isDurationSelected(preset),
                                onTap: { selectDuration(preset) }
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 10)

                Spacer().frame(height: 14)
            }
        }
        .background(DesignColors.cardBackground)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(DesignColors.cardBorder, lineWidth: 0.5)
        )
        .sheet(isPresented: $showCustomPicker) {
            customPickerSheet
        }
        .onChange(of: setTimer) { _, enabled in
            if !enabled {
                showCustomPicker = false
            }
        }
    }

    private var displayedDurationPresets: [DurationChipItem] {
        let totalMinutes = selectedDurationMinutes
        let hasCustomDuration = totalMinutes > 0 && !presetDurations.contains(where: { $0.minutes == totalMinutes })

        let firstChip = DurationChipItem(
            id: "slot-30m-or-custom",
            title: hasCustomDuration ? formattedChipDuration(totalMinutes) : "30m",
            minutes: hasCustomDuration ? totalMinutes : 30,
            opensCustomPicker: false
        )

        let otherPresets: [DurationChipItem] = [
            DurationChipItem(id: "preset-1h", title: "1h", minutes: 60, opensCustomPicker: false),
            DurationChipItem(id: "preset-1h30", title: "1h30", minutes: 90, opensCustomPicker: false),
            DurationChipItem(id: "preset-2h", title: "2h", minutes: 120, opensCustomPicker: false)
        ]

        let customPickerChip = DurationChipItem(
            id: "custom-picker",
            title: "+",
            minutes: nil,
            opensCustomPicker: true
        )

        return [firstChip] + otherPresets + [customPickerChip]
    }

    private var selectedDurationMinutes: Int {
        Int(hours * 60 + minutes)
    }

    private func isDurationSelected(_ preset: DurationChipItem) -> Bool {
        guard !preset.opensCustomPicker, let presetMinutes = preset.minutes else {
            return false
        }
        return selectedDurationMinutes == presetMinutes
    }

    private func selectDuration(_ preset: DurationChipItem) {
        if preset.opensCustomPicker {
            showCustomPicker = true
            return
        }

        guard let presetMinutes = preset.minutes else { return }

        hours = Double(presetMinutes / 60)
        minutes = Double(presetMinutes % 60)
        pickerHours = presetMinutes / 60
        pickerMinutes = presetMinutes % 60
        timerTotalMinutes = presetMinutes
        setTimer = true
    }

    private func formattedChipDuration(_ totalMinutes: Int) -> String {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 && minutes > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }

    var customPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    Picker("Heures", selection: $pickerHours) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text("\(hour) h").tag(hour)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)

                    Picker("Minutes", selection: $pickerMinutes) {
                        ForEach(0..<60, id: \.self) { minute in
                            Text(String(format: "%02d m", minute)).tag(minute)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 180)

            }
            .padding(.horizontal, 12)
            .navigationTitle("Durée personnalisée")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { showCustomPicker = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Valider") {
                        hours = Double(pickerHours)
                        minutes = Double(pickerMinutes)
                        timerTotalMinutes = pickerHours * 60 + pickerMinutes
                        setTimer = timerTotalMinutes > 0
                        showCustomPicker = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(320)])
    }

}

/// Détail (facultatif)
struct DetailOptionalCard: View {
    @Binding var detailText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DÉTAIL (FACULTATIF)")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(DesignColors.textSecondary)
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            ZStack(alignment: .topLeading) {
                if detailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Ajouter un détail…")
                        .font(.system(size: 15))
                        .foregroundColor(DesignColors.textTertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }

                TextEditor(text: $detailText)
                    .font(.system(size: 15))
                    .foregroundColor(DesignColors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 92, maxHeight: 120)
                    .background(Color.clear)
            }
            .background(DesignColors.buttonBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DesignColors.buttonBorder, lineWidth: 1)
            )
            .shadow(color: DesignColors.buttonShadow, radius: 3, y: 1)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(DesignColors.cardBackground)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(DesignColors.cardBorder, lineWidth: 0.5)
        )
    }
}

/// Duration Chip Component
struct DurationChip: View {
    let title: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: title == "+" ? 44 : 64)
                .frame(height: 44)
                .foregroundColor(isSelected ? Color.white : DesignColors.textPrimary)
                .background(isSelected ? DesignColors.accentOrange : DesignColors.cardBackground)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? DesignColors.accentOrange : DesignColors.buttonBorder, lineWidth: 1.2)
                )
                .shadow(color: DesignColors.buttonShadow, radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }
}

/// 7. Photo Card
struct PhotoCard: View {
    @Binding var photoData: Data?
    let onTapCapture: () -> Void
    let onTapPreview: () -> Void

    private var previewImage: UIImage? {
        guard let photoData else { return nil }
        return UIImage(data: photoData)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("PHOTO (FACULTATIF)")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(DesignColors.textSecondary)
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            HStack(spacing: 12) {
                Button(action: {
                    if previewImage != nil {
                        onTapPreview()
                    } else {
                        onTapCapture()
                    }
                }) {
                    ZStack {
                        if let previewImage {
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color.black.opacity(0.18))
                                )

                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(7)
                                .background(Color.black.opacity(0.35), in: Capsule())
                        } else {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(DesignColors.accentBlue.opacity(0.15))
                                .frame(width: 56, height: 56)
                                .overlay(
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(DesignColors.accentBlue)
                                )
                        }
                    }
                }
                .buttonStyle(.plain)

                Button(action: onTapCapture) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((previewImage == nil ? "Photographier le repère" : "Photo prête").psLocalized)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(DesignColors.textPrimary)
                            Text(
                                previewImage == nil
                                ? "Stockée jusqu'à la fin du parking".psLocalized
                                : "Touchez l’aperçu pour l’agrandir".psLocalized
                            )
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(DesignColors.textSecondary)
                        }

                        Spacer()

                        Image(systemName: previewImage == nil ? "chevron.right" : "camera.fill")
                            .font(.system(size: 16))
                            .foregroundColor(DesignColors.textTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(DesignColors.buttonBackground)
                    .cornerRadius(13)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(DesignColors.buttonBorder, lineWidth: 1)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    )
                    .shadow(color: DesignColors.buttonShadow, radius: 3, y: 1)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(DesignColors.cardBackground)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(DesignColors.cardBorder, lineWidth: 0.5)
        )
    }
}

private struct PhotoPreviewFullscreenView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            ZoomableImageView(image: image)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(18)
            }
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.backgroundColor = .black
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])

        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        if uiView.zoomScale != 1.0 {
            uiView.setZoomScale(1.0, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}

/// 8. Bottom CTA View
struct BottomCTAView: View {
    let isLoading: Bool
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.06)

            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("Annuler")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DesignColors.textSecondary)
                        .frame(width: 100)
                        .frame(height: 54)
                        .background(DesignColors.buttonBackground)
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(DesignColors.buttonBorder, lineWidth: 1)
                        )
                        .shadow(color: DesignColors.buttonShadow, radius: 4, y: 1)
                }

                Button(action: onSave) {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                            Text("Enregistrer ma voiture")
                                .font(.system(size: 16, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .foregroundColor(DesignColors.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(canSave ? DesignColors.accentBlue : Color.white.opacity(0.1))
                .foregroundColor(DesignColors.textPrimary)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(canSave ? DesignColors.accentBlue : DesignColors.buttonBorder, lineWidth: 1)
                )
                .shadow(color: DesignColors.accentBlue.opacity(0.4), radius: 20, y: 4)
                .disabled(!canSave || isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 34)
        }
        .background(DesignColors.background)
    }
}

// MARK: - SaveParkingSheet Helper Methods Extension
extension SaveParkingSheet {

    private func startParkingLocationOptimizationIfNeeded() {
        guard manualCoordinate == nil else { return }
        guard autoDetectedParkingCoordinate == nil else { return }
        optimizedParkingLocation = nil
        locationOptimizer.startOptimization()
    }

    private func updateOptimizedParkingLocation(from result: LocationOptimizationResult) {
        switch result {
        case .optimizing:
            if let currentBest = locationOptimizer.currentBestLocation {
                optimizedParkingLocation = currentBest
            }
        case .success(let location), .requiresManualAdjustment(let location):
            optimizedParkingLocation = location
        case .timedOut(let location):
            if let location {
                optimizedParkingLocation = location
            }
        case .failedAuthorization:
            break
        }
    }

    private func applySuggestedTimerIfNeeded(autoEnable: Bool) {
        guard !hasInitializedSuggestedTimer else { return }
        hasInitializedSuggestedTimer = true

        guard let suggestedDuration = vm.consumeSuggestedDurationForSaveForm() else { return }
        let rawMinutes = suggestedDuration / 60
        guard rawMinutes.isFinite else { return }

        let suggestedMinutes = Int(rawMinutes.rounded())
        let clampedMinutes = min(max(suggestedMinutes, 1), 12 * 60)

        timerTotalMinutes = clampedMinutes
        hours = Double(clampedMinutes / 60)
        minutes = Double(clampedMinutes % 60)
        pickerHours = clampedMinutes / 60
        pickerMinutes = clampedMinutes % 60
        setTimer = autoEnable && clampedMinutes > 0
    }

    private func applySmartAwayPrefill(_ prefill: HomeViewModel.SmartAwaySaveFormPrefill) {
        isSmartAwayReRegisterMode = true
        isFrequentZoneShortcutMode = false
        frequentZoneShortcutName = nil

        zone = prefill.zone
        parkingLevel = prefill.parkingLevel

        let (cleanNote, extractedRate) = cleanNoteAndExtractPaidRate(from: prefill.note)
        note = cleanNote
        hourlyRateText = extractedRate.map(formatRateForStorage) ?? ""

        applyTimer(duration: prefill.maxDuration, autoEnable: true)
        hasInitializedSuggestedTimer = true
    }

    private func applyTimer(duration: TimeInterval?, autoEnable: Bool) {
        guard let duration, (duration / 60).isFinite else {
            timerTotalMinutes = 0
            hours = 0
            minutes = 0
            pickerHours = 0
            pickerMinutes = 0
            setTimer = false
            return
        }

        let durationMinutes = Int((duration / 60).rounded())
        let clampedMinutes = min(max(durationMinutes, 1), 12 * 60)

        timerTotalMinutes = clampedMinutes
        hours = Double(clampedMinutes / 60)
        minutes = Double(clampedMinutes % 60)
        pickerHours = clampedMinutes / 60
        pickerMinutes = clampedMinutes % 60
        setTimer = autoEnable && clampedMinutes > 0
    }
    
    private func performSave() {
        var duration: TimeInterval? = nil
        if setTimer {
            let totalMinutes = max(1, Int(hours * 60 + minutes))
            duration = TimeInterval(totalMinutes * 60)
        }

        let baseNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNote = noteIncludingPaidRate(from: baseNote)
        let autoDetectedCoordinate = vm.consumeAutoParkingDetectedCoordinateForSave()
        let explicitSaveCoordinate = autoDetectedCoordinate
            ?? manualCoordinate
            ?? vm.userCoordinate
            ?? bestOptimizedParkingLocation?.coordinate
        let saveCoordinate = explicitSaveCoordinate
            ?? LastKnownLocationStore.shared.load()?.coordinate

        Task {
            if let duration {
                vm.registerPredictionFeedbackIfNeeded(
                    selectedDuration: duration,
                    selectedZone: zone,
                    coordinate: saveCoordinate
                )
            }

            let normalizedLevel = parkingLevel.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalLevel = normalizedLevel.isEmpty ? nil : normalizedLevel

            let success: Bool
            if isSmartAwayReRegisterMode {
                success = await vm.reRegisterActiveParkingFromSmartAway(
                    note: finalNote,
                    parkingLevel: finalLevel,
                    maxDuration: duration,
                    zone: zone,
                    photoData: photoData,
                    detectedCoordinate: explicitSaveCoordinate,
                    address: vm.currentAddress
                )
            } else {
                success = await vm.saveParking(
                    note: finalNote,
                    parkingLevel: finalLevel,
                    maxDuration: duration,
                    zone: zone,
                    photoData: photoData,
                    detectedCoordinate: explicitSaveCoordinate,
                    address: vm.currentAddress
                )
            }
            if success {
                await MainActor.run {
                    dismiss()
                }
            }
        }
    }

    private var capturedPhotoBinding: Binding<UIImage?> {
        Binding<UIImage?>(
            get: {
                guard let photoData else { return nil }
                return UIImage(data: photoData)
            },
            set: { image in
                photoData = image?.jpegData(compressionQuality: 0.82)
            }
        )
    }

    private var photoPreviewImage: UIImage? {
        guard let photoData else { return nil }
        return UIImage(data: photoData)
    }

    private func presentCameraIfAvailable() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showPhotoPicker = true
        } else {
            showCameraUnavailableAlert = true
        }
    }

    private var tariffCurrencySymbol: String {
        Locale.autoupdatingCurrent.currencySymbol
        ?? Locale.current.currencySymbol
        ?? Locale.autoupdatingCurrent.currency?.identifier
        ?? Locale.current.currency?.identifier
        ?? "EUR"
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func focusPreviousInput() {
        KeyboardFocusNavigator.move(.previous)
    }

    private func focusNextInput() {
        KeyboardFocusNavigator.move(.next)
    }

    private func noteIncludingPaidRate(from baseNote: String) -> String? {
        let cleanedBase = baseNote
            .replacingOccurrences(of: #"\s*\[\[PS_RATE_EUR:[0-9]+(?:[\.,][0-9]+)?\]\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

                guard zone.isPaidPricing,
              let rate = normalizedHourlyRate(from: hourlyRateText) else {
            return cleanedBase.isEmpty ? nil : cleanedBase
        }

        let marker = "[[PS_RATE_EUR:\(formatRateForStorage(rate))]]"
        return cleanedBase.isEmpty ? marker : "\(cleanedBase) \(marker)"
    }

    private func cleanNoteAndExtractPaidRate(from rawNote: String) -> (String, Double?) {
        let pattern = #"\[\[PS_RATE_EUR:([0-9]+(?:[\.,][0-9]+)?)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (rawNote.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        var extractedRate: Double?
        if let match = regex.firstMatch(in: rawNote, range: NSRange(rawNote.startIndex..., in: rawNote)),
           let valueRange = Range(match.range(at: 1), in: rawNote) {
            extractedRate = Double(rawNote[valueRange].replacingOccurrences(of: ",", with: "."))
        }

        let cleaned = rawNote
            .replacingOccurrences(of: #"\s*\[\[PS_RATE_EUR:[0-9]+(?:[\.,][0-9]+)?\]\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (cleaned, extractedRate)
    }

    private func normalizedHourlyRate(from rawText: String) -> Double? {
        let normalized = rawText
            .replacingOccurrences(of: tariffCurrencySymbol, with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    private func formatRateForStorage(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    
}

private enum KeyboardFocusDirection {
    case previous
    case next
}

private enum KeyboardFocusNavigator {
    static func move(_ direction: KeyboardFocusDirection) {
        guard let window = keyWindow else { return }
        let responders = orderedResponders(in: window)
        guard !responders.isEmpty else { return }

        guard let currentIndex = responders.firstIndex(where: { $0.isFirstResponder }) else {
            (direction == .next ? responders.first : responders.last)?.becomeFirstResponder()
            return
        }

        let targetIndex = direction == .next ? (currentIndex + 1) : (currentIndex - 1)
        guard responders.indices.contains(targetIndex) else { return }
        responders[targetIndex].becomeFirstResponder()
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private static func orderedResponders(in root: UIView) -> [UIView] {
        collectEditableResponders(in: root)
            .filter { $0.window != nil && !$0.isHidden && $0.alpha > 0.01 }
            .sorted { lhs, rhs in
                let lhsFrame = lhs.convert(lhs.bounds, to: root)
                let rhsFrame = rhs.convert(rhs.bounds, to: root)

                if abs(lhsFrame.minY - rhsFrame.minY) > 2 {
                    return lhsFrame.minY < rhsFrame.minY
                }
                return lhsFrame.minX < rhsFrame.minX
            }
    }

    private static func collectEditableResponders(in view: UIView) -> [UIView] {
        var responders: [UIView] = []

        if let textField = view as? UITextField, textField.isEnabled {
            responders.append(textField)
        } else if let textView = view as? UITextView, textView.isEditable {
            responders.append(textView)
        }

        for subview in view.subviews {
            responders.append(contentsOf: collectEditableResponders(in: subview))
        }

        return responders
    }
}
