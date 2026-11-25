import SwiftUI
import CoreLocation
import Combine
import UIKit
import MapKit

struct GuidanceVisualStyle {
    let colorScheme: ColorScheme

    private var isDark: Bool { colorScheme == .dark }

    var mapOverlay: Color {
        isDark ? Color.black.opacity(0.14) : Color.white.opacity(0.05)
    }

    var primaryText: Color {
        isDark ? .white : Color(red: 0.08, green: 0.10, blue: 0.13)
    }

    var secondaryText: Color {
        isDark
            ? Color.white.opacity(0.64)
            : Color(red: 0.34, green: 0.39, blue: 0.45)
    }

    var bottomBarBackground: Color {
        isDark
            ? Color(red: 0.05, green: 0.05, blue: 0.06)
            : Color(uiColor: .systemBackground)
    }

    var controlBackground: Color {
        isDark
            ? Color(red: 0.06, green: 0.06, blue: 0.07)
            : Color(uiColor: .systemBackground)
    }

    var controlIconForeground: Color {
        isDark ? .white : Color(red: 0.05, green: 0.15, blue: 0.28)
    }

    var controlStroke: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    var panelStroke: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    var panelShadow: Color {
        Color.black.opacity(isDark ? 0.26 : 0.14)
    }

    var controlShadow: Color {
        Color.black.opacity(isDark ? 0.24 : 0.16)
    }

    func bannerBackground(isVeryClose: Bool) -> Color {
        if isVeryClose {
            return isDark
                ? Color(red: 0.00, green: 0.46, blue: 0.36)
                : Color(red: 0.00, green: 0.56, blue: 0.44)
        }

        return isDark
            ? Color(red: 0.00, green: 0.43, blue: 0.39)
            : Color(red: 0.00, green: 0.50, blue: 0.46)
    }
}
