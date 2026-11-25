import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Thème visuel Premium (clair/sombre)
#if canImport(UIKit)
struct PremiumTheme {

    // Fond global
    static var background: Color {
        Color(UIColor { t in
            t.userInterfaceStyle == .dark
            ? UIColor(hex: "0A0A0F")
            : UIColor.systemGroupedBackground
        })
    }

    // Fond des cartes
    static var cardBackground: Color {
        Color(UIColor { t in
            t.userInterfaceStyle == .dark
            ? UIColor(hex: "1C1C1E")
            : UIColor.secondarySystemGroupedBackground
        })
    }

    // Bordure de carte
    static var cardBorder: Color {
        Color(UIColor { t in
            t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.06)
            : UIColor.black.withAlphaComponent(0.06)
        })
    }

    // Couleurs texte
    static var textPrimary: Color { Color(UIColor.label) }
    static var textSecondary: Color { Color(UIColor.secondaryLabel) }
    static var textTertiary: Color { Color(UIColor.tertiaryLabel) }

    // Séparateurs
    static var separator: Color {
        Color(UIColor { t in
            t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.04)
            : UIColor.black.withAlphaComponent(0.06)
        })
    }

    // Couleurs d'accent (identiques clair/sombre)
    static let gold = Color(hex: "FFD700")
    static let blue = Color(hex: "007AFF")
    static let green = Color(hex: "34C759")
    static let orange = Color(hex: "FF9500")
    static let red = Color(hex: "FF3B30")
    static let purple = Color(hex: "AF52DE")
    static let teal = Color(hex: "00C7BE")

    // Utilitaires de couleur pour respecter le design system
    static let transparent = Color.clear
    static let textOnAccent = Color.white

    static var closeButtonFill: Color {
        Color(UIColor.tertiarySystemFill)
    }
}

// MARK: - Extension utilitaire UIColor(hex:)
extension UIColor {
    /// Initialise une couleur UIKit à partir d'une chaîne hexadécimale RGB.
    convenience init(hex: String, alpha: Double = 1.0) {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt(cleaned, radix: 16) ?? 0

        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: CGFloat(max(0, min(1, alpha)))
        )
    }
}

#else

struct PremiumTheme {
    static let background = Color.black.opacity(0.96)
    static let cardBackground = Color.white.opacity(0.08)
    static let cardBorder = Color.white.opacity(0.12)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.75)
    static let textTertiary = Color.white.opacity(0.55)
    static let separator = Color.white.opacity(0.14)

    static let gold = Color.yellow
    static let blue = Color.blue
    static let green = Color.green
    static let orange = Color.orange
    static let red = Color.red
    static let purple = Color.purple
    static let teal = Color.teal

    static let transparent = Color.clear
    static let textOnAccent = Color.white
    static let closeButtonFill = Color.white.opacity(0.14)
}

#endif
