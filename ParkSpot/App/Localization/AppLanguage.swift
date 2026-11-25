import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
	case system
	case english
	case french
	case german
	case spanish

	var id: String { rawValue }

	static let defaultsLanguageKey = "app.language"
	static let defaultsUserOverrideEnabledKey = "app.language.userOverrideEnabled"
	static let fallbackLocaleIdentifier = "en"
	static let supportedLocaleIdentifiers: Set<String> = ["fr", "en", "de", "es"]
	private static let globalLanguageDefaultsKey = "AppleLanguages"
	private static let globalLocaleDefaultsKey = "AppleLocale"
	private static let localeLanguageCodeKey = NSLocale.Key.languageCode.rawValue
	private static let localeScriptCodeKey = NSLocale.Key.scriptCode.rawValue
	private static let localeCountryCodeKey = NSLocale.Key.countryCode.rawValue

	var displayName: String {
		switch self {
		case .system: return "language.system".psLocalized
		case .english: return "language.english".psLocalized
		case .french: return "language.french".psLocalized
		case .german: return "language.german".psLocalized
		case .spanish: return "language.spanish".psLocalized
		}
	}

	var localeIdentifier: String {
		switch self {
		case .system:
			return AppLanguage.systemResolvedLocaleIdentifier()
		case .english:
			return AppLanguage.runtimeLocaleIdentifier(for: "en")
		case .french:
			return AppLanguage.runtimeLocaleIdentifier(for: "fr")
		case .german:
			return AppLanguage.runtimeLocaleIdentifier(for: "de")
		case .spanish:
			return AppLanguage.runtimeLocaleIdentifier(for: "es")
		}
	}

	static func systemPreferredLocaleIdentifier(preferredLanguageIdentifiers: [String]? = nil) -> String {
		let languageIdentifiers = preferredLanguageIdentifiers ?? systemLanguageIdentifiers()
		return resolvedSupportedLanguageCode(from: languageIdentifiers) ?? fallbackLocaleIdentifier
	}

	static func systemResolvedLocaleIdentifier(
		preferredLanguageIdentifiers: [String]? = nil,
		defaults: UserDefaults = .standard
	) -> String {
		let languageCode = systemPreferredLocaleIdentifier(
			preferredLanguageIdentifiers: preferredLanguageIdentifiers
		)
		return runtimeLocaleIdentifier(
			for: languageCode,
			systemLocaleIdentifier: systemLocaleIdentifier(defaults: defaults)
		)
	}

	static func resolvedLocaleIdentifier(savedCode: String, overrideEnabled: Bool) -> String {
		guard overrideEnabled,
		      let language = AppLanguage(rawValue: savedCode),
		      language != .system else {
			return systemResolvedLocaleIdentifier()
		}

		return language.localeIdentifier
	}

	static func seedAutomaticDefaultsForFreshInstall(defaults: UserDefaults = .standard) {
		defaults.set(AppLanguage.system.rawValue, forKey: defaultsLanguageKey)
		defaults.set(false, forKey: defaultsUserOverrideEnabledKey)
	}

	static func systemLanguageIdentifiers(defaults: UserDefaults = .standard) -> [String] {
		if let globalDomain = defaults.persistentDomain(forName: UserDefaults.globalDomain),
		   let identifiers = globalDomain[globalLanguageDefaultsKey] as? [String],
		   !identifiers.isEmpty {
			return identifiers
		}

		return Locale.preferredLanguages
	}

	static func systemLocaleIdentifier(defaults: UserDefaults = .standard) -> String {
		if let globalDomain = defaults.persistentDomain(forName: UserDefaults.globalDomain),
		   let identifier = globalDomain[globalLocaleDefaultsKey] as? String,
		   !identifier.isEmpty {
			return identifier
		}

		return Locale.autoupdatingCurrent.identifier
	}

	static func runtimeLocaleIdentifier(
		for identifier: String,
		systemLocaleIdentifier: String? = nil
	) -> String {
		let resolvedLanguageCode = resolvedSupportedLanguageCode(from: identifier)
			?? fallbackLocaleIdentifier
		let templateIdentifier = systemLocaleIdentifier ?? self.systemLocaleIdentifier()
		return localeIdentifier(languageCode: resolvedLanguageCode, matching: templateIdentifier)
	}

	static func localeIdentifier(languageCode: String, matching templateIdentifier: String) -> String {
		let resolvedLanguageCode = resolvedSupportedLanguageCode(from: languageCode)
			?? fallbackLocaleIdentifier
		let languageLocale = Locale(identifier: resolvedLanguageCode)
		let templateLocale = Locale(identifier: templateIdentifier)

		var mergedComponents: [String: String] = [
			localeLanguageCodeKey: languageLocale.language.languageCode?.identifier ?? resolvedLanguageCode
		]

		if let scriptCode = languageLocale.language.script?.identifier {
			mergedComponents[localeScriptCodeKey] = scriptCode
		}

		if let countryCode = templateLocale.region?.identifier {
			mergedComponents[localeCountryCodeKey] = countryCode
		}

		return Locale.identifier(fromComponents: mergedComponents)
	}

	static func resolvedSupportedLanguageCode(from identifiers: [String]) -> String? {
		for identifier in identifiers {
			if let resolvedIdentifier = resolvedSupportedLanguageCode(from: identifier) {
				return resolvedIdentifier
			}
		}

		return nil
	}

	static func resolvedSupportedLanguageCode(from identifier: String) -> String? {
		let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()

		if normalized.hasPrefix("en") { return "en" }
		if normalized.hasPrefix("fr") { return "fr" }
		if normalized.hasPrefix("de") { return "de" }
		if normalized.hasPrefix("es") { return "es" }

		return nil
	}
}

extension Notification.Name {
	static let appLanguageDidChange = Notification.Name("parkspot.appLanguageDidChange")
}
