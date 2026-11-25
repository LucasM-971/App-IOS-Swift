// CarLocationIndicator.swift
// Shows directional arrow and distance to parked car (AirTag-style)

import SwiftUI
import CoreLocation

struct CarLocationIndicator: View {
    let userCoordinate: Coordinate?
    let carCoordinate: Coordinate
    let userHeading: CLHeading?

    var body: some View {
        VStack(spacing: 12) {
            // Directional arrow + distance
            HStack(spacing: 12) {
                // Arrow pointing to car
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.psAccentBlue)
                    .shadow(color: .psAccentBlue.opacity(0.3), radius: 8, x: 0, y: 0)
                    .rotationEffect(.degrees(bearingAngle))
                    // FIX: smooth animation — avoids visual jumps during updates
                    .animation(
                        .interactiveSpring(response: 0.2, dampingFraction: 0.86),
                        value: bearingAngle
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Clique sur moi !".psLocalized)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.psDarkTextSecondary)
                    Text(distanceString)
                        .font(.title3.weight(.bold))
                        .foregroundColor(.psDarkTextPrimary)
                        // FIX: smooth numeric transition
                        .contentTransition(.numericText())
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.psAccentBlue.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.psAccentBlue.opacity(0.12), lineWidth: 1)
                    )
            )

            // Compass accuracy indicator (if heading available)
            if userHeading != nil {
                HStack(spacing: 4) {
                    Image(systemName: "location.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Text("Compas actif".psLocalized)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    // FIX: shows "---" if userCoordinate is nil or distance is infinite/NaN
                    Text(distanceMeters.flatMap { $0.isFinite ? "\(Int($0))m" : nil } ?? "---")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
    }

    // FIX: returns Double? instead of Double — avoids showing "0 m" when
    // userCoordinate is nil.
    private var distanceMeters: Double? {
        guard let user = userCoordinate,
              user.isValidGeoCoordinate,
              carCoordinate.isValidGeoCoordinate else {
            return nil
        }

        let userCL = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let carCL = CLLocation(latitude: carCoordinate.latitude, longitude: carCoordinate.longitude)
        return userCL.distance(from: carCL)
    }

    private var distanceString: String {
        guard let meters = distanceMeters else { return "---" }
        if meters < 1000 {
            return String(format: "%.0f m", meters)
        } else {
            return String(format: "%.2f km", meters / 1000)
        }
    }

    private var bearingAngle: Double {
        guard let user = userCoordinate,
              user.isValidGeoCoordinate,
              carCoordinate.isValidGeoCoordinate,
              let heading = userHeading else {
            return 0
        }

        let userLat = user.latitude * .pi / 180
        let userLon = user.longitude * .pi / 180
        let carLat = carCoordinate.latitude * .pi / 180
        let carLon = carCoordinate.longitude * .pi / 180

        let dLon = carLon - userLon
        let y = sin(dLon) * cos(carLat)
        let x = cos(userLat) * sin(carLat) - sin(userLat) * cos(carLat) * cos(dLon)

        // Absolute bearing normalized in [0, 360]
        let absoluteBearing = (atan2(y, x) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)

        // FIX: trueHeading is -1 when compass is not calibrated —
        // fallback to magneticHeading to avoid incorrect direction.
        let deviceHeading = heading.trueHeading > 0
            ? heading.trueHeading
            : heading.magneticHeading

        guard deviceHeading.isFinite else { return 0 }

        // FIX: relative angle normalized in [-180, 180] so SwiftUI
        // always animates on the shortest path (avoids 350° rotations).
        var relative = absoluteBearing - deviceHeading
        relative = (relative + 360).truncatingRemainder(dividingBy: 360)
        if relative > 180 { relative -= 360 }
        return relative.isFinite ? relative : 0
    }
}

#Preview {
    CarLocationIndicator(
        userCoordinate: Coordinate(latitude: 48.8566, longitude: 2.3522),
        carCoordinate: Coordinate(latitude: 48.8600, longitude: 2.3550),
        userHeading: nil
    )
    .padding()
}