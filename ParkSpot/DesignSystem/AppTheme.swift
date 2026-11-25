// AppTheme.swift
// Design system global pour la section véhicule et les vues associées

import SwiftUI

// MARK: - Extension utilitaire Hex + couleurs nommées
extension Color {
    /// Initialise une couleur à partir d'une valeur hexadécimale RGB (ex: 0x007AFF).
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }

    /// Initialise une couleur à partir d'une chaîne hexadécimale (ex: "#007AFF" ou "007AFF").
    init(hex: String, alpha: Double = 1.0) {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt(cleaned, radix: 16) ?? 0
        self.init(hex: value, alpha: alpha)
    }

    // MARK: Couleurs de base dark mode
    static let psDarkBackground = Color(hex: 0x0A0A0F)
    static let psDarkCard = Color(hex: 0x1C1C1E)
    static let psDarkTextPrimary = Color.white
    static let psDarkTextSecondary = Color(hex: 0x8E8E93)
    static let psDarkTextTertiary = Color(hex: 0x5A5A5E)

    // MARK: Couleurs de base light mode
    static let psLightBackground = Color(hex: 0xF2F2F7)
    static let psLightCard = Color.white
    static let psLightTextPrimary = Color(hex: 0x1C1C1E)
    static let psLightTextSecondary = Color(hex: 0x6C6C70)
    static let psLightTextTertiary = Color(hex: 0xAEAEB2)

    // MARK: Couleurs sémantiques communes
    static let psAccentBlue = Color(hex: 0x007AFF)
    static let psAccentGreen = Color(hex: 0x34C759)
    static let psAccentOrange = Color(hex: 0xFF9500)
    static let psAccentRed = Color(hex: 0xFF3B30)
    static let psAccentViolet = Color(hex: 0xAF52DE)
}

// MARK: - Thème adaptatif selon le color scheme
struct AppTheme {
    let background: Color
    let cardBackground: Color
    let cardBorder: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color

    let accentBlue: Color
    let accentGreen: Color
    let accentOrange: Color
    let accentRed: Color
    let accentViolet: Color

    let cardCornerRadius: CGFloat
    let actionCornerRadius: CGFloat
    let iconCornerRadius: CGFloat
    let sectionSpacing: CGFloat
    let horizontalPadding: CGFloat
    let cardInnerPadding: CGFloat

    let pageTitleFont: Font
    let sectionUppercaseFont: Font
    let cardTitleFont: Font
    let cardSubtitleFont: Font

    /// Retourne le thème complet selon le mode clair/sombre.
    static func from(_ colorScheme: ColorScheme) -> AppTheme {
        let isDark = colorScheme == .dark
        return AppTheme(
            background: isDark ? .psDarkBackground : .psLightBackground,
            cardBackground: isDark ? .psDarkCard : .psLightCard,
            cardBorder: isDark ? .white.opacity(0.07) : .black.opacity(0.06),
            textPrimary: isDark ? .psDarkTextPrimary : .psLightTextPrimary,
            textSecondary: isDark ? .psDarkTextSecondary : .psLightTextSecondary,
            textTertiary: isDark ? .psDarkTextTertiary : .psLightTextTertiary,
            accentBlue: .psAccentBlue,
            accentGreen: .psAccentGreen,
            accentOrange: .psAccentOrange,
            accentRed: .psAccentRed,
            accentViolet: .psAccentViolet,
            cardCornerRadius: 18,
            actionCornerRadius: 16,
            iconCornerRadius: 10,
            sectionSpacing: 12,
            horizontalPadding: 16,
            cardInnerPadding: 16,
            pageTitleFont: .system(size: 17, weight: .bold),
            sectionUppercaseFont: .system(size: 11, weight: .semibold),
            cardTitleFont: .system(size: 14, weight: .semibold),
            cardSubtitleFont: .system(size: 11)
        )
    }
}
