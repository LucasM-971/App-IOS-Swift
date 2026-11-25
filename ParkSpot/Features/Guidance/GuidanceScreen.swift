import SwiftUI
import CoreLocation
import Combine
import UIKit
import MapKit

/// Full-screen parking guidance with a walking route and lightweight controls.
struct GuidanceScreen: View {
    let carCoordinate: Coordinate
    let destinationName: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var vm = GuidanceViewModel()
    @State private var hasBeenFarFromCar = false
    @State private var walkingRouteDistanceMeters: Double?
    @State private var walkingRouteExpectedTravelTime: TimeInterval?
    @State private var isMapCameraLocked = true
    @State private var recenterRequest = 0

    init(carCoordinate: Coordinate, destinationName: String? = nil) {
        self.carCoordinate = carCoordinate
        self.destinationName = destinationName
    }

    var body: some View {
        let distance = vm.distanceMeters(to: carCoordinate)
        let isVeryClose = distance <= GuidanceRouteGuardrails.arrivalDistanceMeters
        let style = GuidanceVisualStyle(colorScheme: colorScheme)

        ZStack {
            GuidanceMapView(
                carCoordinate: carCoordinate,
                userLocation: vm.latestLocation,
                userHeading: vm.latestHeading,
                colorScheme: colorScheme,
                isMapCameraLocked: $isMapCameraLocked,
                recenterRequest: recenterRequest,
                walkingRouteDistanceMeters: $walkingRouteDistanceMeters,
                walkingRouteExpectedTravelTime: $walkingRouteExpectedTravelTime
            )
            .ignoresSafeArea()

            style.mapOverlay
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                guidanceInstructionBanner(isVeryClose: isVeryClose, style: style)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                Spacer()
            }

            VStack(spacing: 0) {
                Spacer()

                HStack {
                    Spacer()
                    mapFloatingControls(style: style)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 150)
            }

            VStack(spacing: 0) {
                Spacer()

                guidanceControlBar(
                    distance: walkingRouteDistanceMeters ?? distance,
                    expectedTravelTime: walkingRouteExpectedTravelTime,
                    style: style
                )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isVeryClose)
        .onChange(of: isVeryClose) { _, newValue in
            if newValue {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
        .onChange(of: distance.isFinite ? Int(distance) : -1) { _, _ in
            if !isVeryClose && distance.isFinite {
                // Subtle haptic tick as distance changes
                let generator = UISelectionFeedbackGenerator()
                generator.selectionChanged()
            }
        }
        .onAppear {
            guard carCoordinate.isValidGeoCoordinate else {
                dismiss()
                return
            }

            EnergyManager.shared.transition(to: .activeGuidance)
            vm.start(to: carCoordinate)
        }
        .onDisappear {
            vm.stop()
            EnergyManager.shared.transition(to: .foregroundIdle)
        }
        .onChange(of: vm.distanceMeters(to: carCoordinate)) { _, meters in
            guard meters.isFinite else { return }

            if meters > 20 {
                hasBeenFarFromCar = true
            }

            if hasBeenFarFromCar && meters <= 10 {
                dismiss()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                vm.handleDidEnterBackground(distanceToCar: vm.distanceMeters(to: carCoordinate))
            } else if phase == .active {
                vm.handleWillEnterForeground()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            vm.handleDidEnterBackground(distanceToCar: vm.distanceMeters(to: carCoordinate))
        }
    }

    private var destinationTitle: String {
        let normalized = destinationName?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalized, !normalized.isEmpty {
            return normalized
        }

        return "your car".psLocalized
    }

    private func guidanceInstructionBanner(
        isVeryClose: Bool,
        style: GuidanceVisualStyle
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isVeryClose ? "mappin.and.ellipse" : "arrow.up")
                .font(.system(size: isVeryClose ? 26 : 32, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(isVeryClose ? "at".psLocalized : "toward".psLocalized)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(destinationTitle)
                    .font(.system(size: 25, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.62)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(
            style.bannerBackground(isVeryClose: isVeryClose),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .shadow(color: style.panelShadow, radius: 18, y: 10)
    }

    private func mapFloatingControls(style: GuidanceVisualStyle) -> some View {
        VStack(spacing: 14) {
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                isMapCameraLocked = true
                recenterRequest += 1
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(style.controlIconForeground)
                    .frame(width: 62, height: 62)
                    .background(style.controlBackground, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(style.controlStroke, lineWidth: 1)
                    )
                    .shadow(color: style.controlShadow, radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Center on me".psLocalized)

            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                openAppleMapsWalkingRoute()
            } label: {
                Image(systemName: "map.fill")
                    .symbolRenderingMode(.palette)
                    .font(.system(size: 31, weight: .semibold))
                    .foregroundStyle(
                        Color.red,
                        Color.white
                    )
                    .frame(width: 70, height: 70)
                    .background(style.controlBackground, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(style.controlStroke, lineWidth: 1)
                    )
                    .shadow(color: style.controlShadow, radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open in Maps".psLocalized)
        }
    }

    private func openAppleMapsWalkingRoute() {
        guard carCoordinate.isValidGeoCoordinate else { return }
        let destination = MKMapItem(
            placemark: MKPlacemark(
                coordinate: CLLocationCoordinate2D(
                    latitude: carCoordinate.latitude,
                    longitude: carCoordinate.longitude
                )
            )
        )
        destination.name = destinationTitle
        MKMapItem.openMaps(
            with: [destination],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
        )
    }

    private func guidanceControlBar(
        distance: Double,
        expectedTravelTime: TimeInterval?,
        style: GuidanceVisualStyle
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(etaText(for: distance, expectedTravelTime: expectedTravelTime))
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .foregroundStyle(style.primaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)

                    Image(systemName: "figure.walk")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(red: 0.00, green: 0.51, blue: 1.0))
                }

                Text(String(format: "%@ - %@".psLocalized, distanceText(for: distance), Date().formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                dismiss()
            } label: {
                Text("Exit".psLocalized)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 66, height: 66)
                    .background(Color(red: 0.93, green: 0.20, blue: 0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit guidance".psLocalized)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(
            style.bottomBarBackground,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(style.panelStroke, lineWidth: 1)
        }
        .shadow(color: style.panelShadow, radius: 18, y: 8)
    }

    private func etaText(for distance: Double, expectedTravelTime: TimeInterval?) -> String {
        if distance.isFinite,
           distance <= GuidanceRouteGuardrails.arrivalDistanceMeters {
            return "Here".psLocalized
        }

        if let expectedTravelTime, expectedTravelTime.isFinite {
            let minutes = max(1, Int(ceil(expectedTravelTime / 60)))
            return String(format: "%d min".psLocalized, minutes)
        }

        guard distance.isFinite,
              distance <= GuidanceRouteGuardrails.maximumWalkingRouteDistanceMeters else {
            return "--"
        }
        let minutes = max(1, Int(ceil(distance / 80)))
        return String(format: "%d min".psLocalized, minutes)
    }

    private func distanceText(for distance: Double) -> String {
        guard distance.isFinite else { return "--" }
        if distance <= GuidanceRouteGuardrails.arrivalDistanceMeters {
            return "0 m"
        }
        if distance >= 100_000 {
            return String(format: "%.0f km", distance / 1000)
        }
        return distance < 1000
            ? String(format: "%.0f m", distance)
            : String(format: "%.2f km", distance / 1000)
    }
}
