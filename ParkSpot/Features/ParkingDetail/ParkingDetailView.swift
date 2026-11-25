// ParkingDetailView.swift
// Full detail screen for a parking session with map snapshot, photo, note

import SwiftUI
import MapKit
import UIKit

struct ParkingDetailView: View {

    let session: ParkingSession
    @State private var mapSnapshot: UIImage?
    @State private var sessionPhoto: UIImage?
    @State private var showExportSheet = false
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var showPhotoSheet = false
    @State private var exportError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private let photoStorage = DIContainer.shared.photoStorage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: – Map snapshot
                mapSnapshotView
                    .frame(height: 220)
                    .clipped()

                VStack(alignment: .leading, spacing: 20) {

                    // Address + zone
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.address ?? "Saved location".psLocalized)
                            .font(.title2.bold())
                        ZoneBadge(zone: session.zone)
                        if session.isApproximate {
                            Text("Approximate location".psLocalized)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                        }
                    }

                    Divider()

                    // Time info
                    DetailSection(title: "Times") {
                        DetailRow(icon: "clock",        label: "Arrival",   value: ParkingDetailDateFormatter.dateTime(session.startTime, locale: locale))
                        if let end = session.endTime {
                            DetailRow(icon: "clock.badge.checkmark", label: "Departure", value: ParkingDetailDateFormatter.dateTime(end, locale: locale))
                            DetailRow(icon: "timer", label: "Duration", value: durationString(from: session.startTime, to: end))
                        }
                    }

                    // Parking details
                    if session.parkingLevel != nil
                        || displayNote != nil
                        || paidHourlyRate != nil
                        || currentPaidPrice != nil
                        || estimatedPaidPrice != nil
                        || session.maxDuration != nil
                    {
                        Divider()
                        DetailSection(title: "Information") {
                            if let level = session.parkingLevel {
                                DetailRow(icon: "arrow.down.to.line", label: "Level", value: level)
                            }
                            if let duration = session.maxDuration {
                                DetailRow(icon: "timer", label: "Timer", value: durationString(from: duration))
                            }
                            if let rate = paidHourlyRate {
                                DetailRow(icon: "banknote", label: "Rate", value: "\(rate.localizedCurrency)/h")
                            }
                            if let price = currentPaidPrice {
                                DetailRow(icon: "creditcard", label: "Parking price", value: price.localizedCurrency)
                            }
                            if let estimated = estimatedPaidPrice {
                                DetailRow(icon: "timer", label: "Estimated max price", value: estimated.localizedCurrency)
                            }
                            if let note = displayNote {
                                DetailRow(icon: "note.text", label: "Note", value: note)
                            }
                        }
                    }

                    if let sessionPhoto {
                        Divider()
                        DetailSection(title: "Parking photo") {
                            Image(uiImage: sessionPhoto)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: 210)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .onTapGesture { showPhotoSheet = true }
                        }
                    }

                    // Coordinates
                    Divider()
                    DetailSection(title: "GPS coordinates") {
                        DetailRow(icon: "location", label: "Latitude",  value: String(format: "%.6f", session.coordinate.latitude))
                        DetailRow(icon: "location", label: "Longitude", value: String(format: "%.6f", session.coordinate.longitude))
                    }

                    // Navigate button
                    Divider()
                    Button {
                        openWalkingDirections(to: session.coordinate, name: session.address)
                    } label: {
                        Label("Open in Maps".psLocalized, systemImage: "map")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            .foregroundColor(.blue)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Details".psLocalized)
        .navigationBarTitleDisplayMode(.inline)
        .tint(.blue)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showExportSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export".psLocalized)
                    }
                }
                .accessibilityLabel("Export PDF".psLocalized)
            }
        }
        .task {
            await generateSnapshot()
            await loadSessionPhoto()
        }
        .sheet(isPresented: $showExportSheet) {
            ParkingSessionPDFExportSheet(
                session: session,
                mapSnapshot: mapSnapshot,
                sessionPhoto: sessionPhoto
            ) { url in
                exportURL = url
                showShareSheet = true
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportURL {
                ParkingDetailShareSheet(activityItems: [exportURL])
            }
        }
        .sheet(isPresented: $showPhotoSheet) {
            if let sessionPhoto {
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: sessionPhoto)
                        .resizable()
                        .scaledToFit()
                        .padding()
                }
            }
        }
        .alert("Export failed".psLocalized, isPresented: .constant(exportError != nil)) {
            Button("OK".psLocalized) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: – Map snapshot
    private var mapSnapshotView: some View {
        Group {
            if let img = mapSnapshot {
                Image(uiImage: img)
                    .resizable().scaledToFill()
            } else {
                Color(.systemGray5)
                    .overlay(ProgressView())
            }
        }
    }

    private func generateSnapshot() async {
        let options   = MKMapSnapshotter.Options()
        let center    = CLLocationCoordinate2D(
            latitude:  session.coordinate.latitude,
            longitude: session.coordinate.longitude
        )
        options.region = MKCoordinateRegion(center: center,
                                            latitudinalMeters: 400,
                                            longitudinalMeters: 400)
        options.pointOfInterestFilter = .excludingAll
        options.size   = CGSize(width: UIScreen.main.bounds.width, height: 220)
        options.scale  = UIScreen.main.scale

        let snapshotter = MKMapSnapshotter(options: options)
        if let snapshot = try? await snapshotter.start() {
            mapSnapshot = imageByAddingCarPin(to: snapshot, coordinate: center)
        }
    }

    private func imageByAddingCarPin(
        to snapshot: MKMapSnapshotter.Snapshot,
        coordinate: CLLocationCoordinate2D
    ) -> UIImage {
        let baseImage = snapshot.image
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = baseImage.scale
        rendererFormat.opaque = false

        let renderer = UIGraphicsImageRenderer(size: baseImage.size, format: rendererFormat)
        let pinPoint = snapshot.point(for: coordinate)
        let pinSize = CGSize(width: 50, height: 64)
        let pinOrigin = CGPoint(
            x: pinPoint.x - pinSize.width / 2,
            y: pinPoint.y - pinSize.height + 2
        )

        return renderer.image { context in
            baseImage.draw(at: .zero)
            drawCarPin(in: context.cgContext, origin: pinOrigin, size: pinSize)
        }
    }

    private func drawCarPin(in context: CGContext, origin: CGPoint, size: CGSize) {
        let pinRect = CGRect(origin: origin, size: size)
        let circleDiameter = min(size.width, size.height * 0.58)
        let circleRect = CGRect(
            x: pinRect.midX - circleDiameter / 2,
            y: pinRect.minY,
            width: circleDiameter,
            height: circleDiameter
        )
        let tipY = pinRect.maxY
        let tailTopY = circleRect.maxY - 1
        let tailHalfWidth: CGFloat = 11

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: UIColor.black.withAlphaComponent(0.18).cgColor)

        let pinPath = UIBezierPath()
        pinPath.append(UIBezierPath(ovalIn: circleRect))
        pinPath.move(to: CGPoint(x: pinRect.midX, y: tipY))
        pinPath.addLine(to: CGPoint(x: pinRect.midX - tailHalfWidth, y: tailTopY))
        pinPath.addLine(to: CGPoint(x: pinRect.midX + tailHalfWidth, y: tailTopY))
        pinPath.close()

        UIColor.systemBlue.setFill()
        pinPath.fill()
        context.restoreGState()

        if let carImage = UIImage(
            systemName: "car.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            let iconSize = CGSize(width: 20, height: 16)
            let iconRect = CGRect(
                x: circleRect.midX - iconSize.width / 2,
                y: circleRect.midY - iconSize.height / 2 + 1,
                width: iconSize.width,
                height: iconSize.height
            )
            carImage.draw(in: iconRect)
        }
    }

    private func loadSessionPhoto() async {
        guard let path = session.photoPath else { return }
        guard let data = try? await photoStorage.load(path: path) else { return }
        sessionPhoto = UIImage(data: data)
    }

    private func openWalkingDirections(to coordinate: Coordinate, name: String?) {
        guard coordinate.isValidGeoCoordinate else { return }
        let destination = MKMapItem(
            placemark: MKPlacemark(
                coordinate: CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            )
        )
        destination.name = name ?? "Parked car".psLocalized
        MKMapItem.openMaps(
            with: [destination],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
        )
    }

    private func durationString(from start: Date, to end: Date) -> String {
        let diff    = end.timeIntervalSince(start)
        let hours   = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60
        if hours > 0 {
            return String(format: "common.duration_h_m_spaced_format".psLocalized, hours, minutes)
        }
        return String(format: "common.duration_m_format".psLocalized, minutes)
    }

    private func durationString(from duration: TimeInterval) -> String {
        let safe = max(0, Int(duration))
        let hours = safe / 3600
        let minutes = (safe % 3600) / 60
        if hours > 0 {
            return String(format: "common.duration_h_m_spaced_format".psLocalized, hours, minutes)
        }
        return String(format: "common.duration_m_format".psLocalized, minutes)
    }

    private var paidHourlyRate: Double? {
        guard session.zone.isPaidPricing,
              let note = session.note else { return nil }
        let pattern = #"\[\[PS_RATE_EUR:([0-9]+(?:[\.,][0-9]+)?)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: note, range: NSRange(note.startIndex..., in: note)),
              let valueRange = Range(match.range(at: 1), in: note) else {
            return nil
        }
        return Double(note[valueRange].replacingOccurrences(of: ",", with: "."))
    }

    private var currentPaidPrice: Double? {
        guard session.zone.isPaidPricing,
              let rate = paidHourlyRate else { return nil }
        let endDate = session.endTime ?? Date()
        let elapsed = max(0, endDate.timeIntervalSince(session.startTime))
        return rate * (elapsed / 3600)
    }

    private var estimatedPaidPrice: Double? {
        guard session.zone.isPaidPricing,
              let rate = paidHourlyRate,
              let maxDuration = session.maxDuration else { return nil }
        return rate * (maxDuration / 3600)
    }

    private var displayNote: String? {
        guard let note = session.note else { return nil }
        let cleaned = note
            .replacingOccurrences(of: #"\s*\[\[PS_RATE_EUR:[0-9]+(?:[\.,][0-9]+)?\]\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private struct ParkingSessionPDFExportSheet: View {
    let session: ParkingSession
    let mapSnapshot: UIImage?
    let sessionPhoto: UIImage?
    let onPDFReady: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var category: ExpenseCategory = .personal
    @State private var hourlyRateText: String = ""
    @State private var isExporting = false
    @State private var localError: String?

    private var durationHours: Double {
        let end = session.endTime ?? Date()
        let duration = max(0, end.timeIntervalSince(session.startTime))
        return duration / 3600
    }

    private var hourlyRate: Double {
        let normalized = hourlyRateText.replacingOccurrences(of: ",", with: ".")
        return Double(normalized) ?? 0
    }

    private var currencySymbol: String {
        Locale.current.currencySymbol
        ?? Locale.autoupdatingCurrent.currencySymbol
        ?? Locale.current.currency?.identifier
        ?? Locale.autoupdatingCurrent.currency?.identifier
        ?? "EUR"
    }

    private var vatRate: Double {
        session.zone.isPaidPricing ? 0.20 : 0
    }

    private var subTotal: Double {
        hourlyRate * durationHours
    }

    private var vatAmount: Double {
        subTotal * vatRate
    }

    private var totalAmount: Double {
        subTotal + vatAmount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Category".psLocalized) {
                    Picker("Usage".psLocalized, selection: $category) {
                        ForEach(ExpenseCategory.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Cost calculation".psLocalized) {
                    TextField(String(format: "Hourly rate (%@/h)".psLocalized, currencySymbol), text: $hourlyRateText)
                        .keyboardType(.decimalPad)
                    LabeledContent("Duration".psLocalized) {
                        Text(durationDisplay(from: session.startTime, to: session.endTime ?? Date()))
                    }
                    LabeledContent("Estimated subtotal".psLocalized) {
                        Text(subTotal.localizedCurrency)
                    }
                    LabeledContent("VAT".psLocalized) {
                        if vatRate > 0 {
                            Text("\(Int(vatRate * 100))% • \(vatAmount.localizedCurrency)")
                        } else {
                            Text("None".psLocalized)
                        }
                    }
                    LabeledContent("Estimated total".psLocalized) {
                        Text(totalAmount.localizedCurrency)
                            .fontWeight(.semibold)
                    }
                }

                Section {
                    Text(sessionPhoto == nil
                        ? "The PDF includes the address, duration, estimated cost, and map. Compatible with Spendesk, N2F, and Expensify.".psLocalized
                        : "The PDF includes the address, duration, estimated cost, map, and photo. Compatible with Spendesk, N2F, and Expensify.".psLocalized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Official export".psLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .tint(.blue)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .alert("Error".psLocalized, isPresented: .constant(localError != nil)) {
                Button("OK".psLocalized) { localError = nil }
            } message: {
                Text(localError ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".psLocalized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        exportPDF()
                    } label: {
                        if isExporting {
                            ProgressView()
                        } else {
                            Text("Export".psLocalized)
                        }
                    }
                    .disabled(isExporting)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    HStack(spacing: 0) {
                        Button(action: focusPreviousInput) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 22, weight: .semibold))
                                .frame(width: 56, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Previous field".psLocalized)

                        Button(action: focusNextInput) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 22, weight: .semibold))
                                .frame(width: 56, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Next field".psLocalized)

                        Spacer(minLength: 0)

                        Button(action: dismissKeyboard) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 24, weight: .semibold))
                                .frame(width: 56, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close keyboard".psLocalized)
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

    private func durationDisplay(from start: Date, to end: Date) -> String {
        let diff = max(0, end.timeIntervalSince(start))
        let h = Int(diff) / 3600
        let m = (Int(diff) % 3600) / 60
        return h > 0 ? "\(h)h \(m)min" : "\(m) min"
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

    private func exportPDF() {
        isExporting = true
        defer { isExporting = false }

        do {
            let url = try ParkingSessionPDFBuilder.build(
                session: session,
                category: category,
                estimatedCost: totalAmount,
                vatRate: vatRate,
                mapImage: mapSnapshot,
                photoImage: sessionPhoto,
                locale: locale
            )
            dismiss()
            onPDFReady(url)
        } catch {
            localError = error.localizedDescription
        }
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

private enum ExpenseCategory: String, CaseIterable, Identifiable {
    case personal
    case business

    var id: String { rawValue }

    var label: String {
        switch self {
        case .personal: return "Personal".psLocalized
        case .business: return "Business".psLocalized
        }
    }
}

private enum ParkingSessionPDFBuilder {
    static func build(
        session: ParkingSession,
        category: ExpenseCategory,
        estimatedCost: Double,
        vatRate: Double,
        mapImage: UIImage?,
        photoImage: UIImage?,
        locale: Locale
    ) throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 @ 72 dpi
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "MosiMap - Parking Session",
            kCGPDFContextAuthor as String: "MosiMap"
        ]

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let filename = "MosiMap_Session_\(session.id.uuidString.prefix(8)).pdf"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        try renderer.writePDF(to: outputURL) { context in
            context.beginPage()

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold)
            ]
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .regular)
            ]
            let boldAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold)
            ]

            var y: CGFloat = 36
            ("Official parking receipt".psLocalized as NSString)
                .draw(at: CGPoint(x: 30, y: y), withAttributes: titleAttrs)
            y += 34

            ("Expense-report compatible: Spendesk • N2F • Expensify".psLocalized as NSString)
                .draw(at: CGPoint(x: 30, y: y), withAttributes: bodyAttrs)
            y += 26

            let end = session.endTime ?? Date()
            let duration = durationText(from: session.startTime, to: end)
            let vatText = vatRate > 0
                ? "\(Int(vatRate * 100))%"
                : "None".psLocalized
            let address = session.address ?? "Saved location".psLocalized

            let lines: [(String, String)] = [
                ("Session ID".psLocalized, session.id.uuidString),
                ("Category".psLocalized, category.label),
                ("Address".psLocalized, address),
                ("Start".psLocalized, ParkingDetailDateFormatter.dateTime(session.startTime, locale: locale)),
                ("End".psLocalized, ParkingDetailDateFormatter.dateTime(end, locale: locale)),
                ("Duration".psLocalized, duration),
                ("Estimated cost".psLocalized, estimatedCost.localizedCurrency),
                ("VAT".psLocalized, vatText),
                ("Coordinates".psLocalized, String(format: "%.6f, %.6f", session.coordinate.latitude, session.coordinate.longitude))
            ]

            for (key, value) in lines {
                ("\(key):" as NSString)
                    .draw(at: CGPoint(x: 30, y: y), withAttributes: boldAttrs)
                let valueRect = CGRect(x: 165, y: y, width: pageRect.width - 195, height: 40)
                (value as NSString).draw(in: valueRect, withAttributes: bodyAttrs)
                y += key == "Address".psLocalized ? 30 : 22
            }

            y += 8
            if let mapImage {
                let mapRect = CGRect(x: 30, y: y, width: pageRect.width - 60, height: 180)
                drawImage(mapImage, in: mapRect)
                y += 192
            }

            if let photoImage {
                let photoRect = CGRect(x: 30, y: y, width: pageRect.width - 60, height: 180)
                drawImage(photoImage, in: photoRect)
                y += 192
            }

            let footer = String(format: "Document generated on %@ via MosiMap".psLocalized, ParkingDetailDateFormatter.dateTime(Date(), locale: locale))
            (footer as NSString).draw(
                at: CGPoint(x: 30, y: min(y + 20, pageRect.height - 30)),
                withAttributes: bodyAttrs
            )
        }

        return outputURL
    }

    private static func drawImage(_ image: UIImage, in rect: CGRect) {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            image.draw(in: rect)
            return
        }
        let widthRatio = rect.width / sourceSize.width
        let heightRatio = rect.height / sourceSize.height
        let scale = min(widthRatio, heightRatio)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = CGRect(
            x: rect.minX + (rect.width - drawSize.width) / 2,
            y: rect.minY + (rect.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect)
    }

    private static func durationText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)min" : "\(m) min"
    }
}

private extension Double {
    var localizedCurrency: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = .current
        formatter.currencyCode = Locale.current.currency?.identifier ?? "EUR"
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.2f", self)
    }
}

private struct ParkingDetailShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum ParkingDetailDateFormatter {
    static func dateTime(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: – Detail Section
private struct DetailSection<Content: View>: View {
    let title:   LocalizedStringKey
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}

// MARK: – Detail Row
private struct DetailRow: View {
    let icon:  String
    let label: LocalizedStringKey
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)

            Spacer(minLength: 8)

            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }
}

// MARK: – Zone badge (shared)
struct ZoneBadge: View {
    let zone: ParkingZone
    var color: Color {
        if zone.isUndergroundType { return .purple }
        if zone.isResidentType { return .blue }
        if zone.isPaidPricing { return .orange }
        if zone.isFreePricing { return .green }
        return .secondary
    }
    var body: some View {
        Text(zone.localizedName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundColor(color)
    }
}
