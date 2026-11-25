import Foundation
import ObjectiveC.runtime

enum AppLanguageManager {
	private static var bundleAssociationKey: UInt8 = 0
	nonisolated(unsafe) private static var englishBundlePath: String? = Bundle.main.path(forResource: "en", ofType: "lproj")
	private static let languageDefaultsKey = "AppleLanguages"
	private static let localeDefaultsKey = "AppleLocale"
	nonisolated private static let defaultTableName = "Localizable"
	nonisolated private static let localizationKeyCacheLock = NSLock()
	nonisolated(unsafe) private static var localizationKeyCache: [String: Set<String>] = [:]
	nonisolated private static let selectedBundlePathLock = NSLock()
	nonisolated(unsafe) private static var selectedBundlePath: String?

	private final class RuntimeLocalizedBundle: Bundle, @unchecked Sendable {
		override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
			if let path = objc_getAssociatedObject(self, &AppLanguageManager.bundleAssociationKey) as? String,
			   let selectedBundle = Bundle(path: path) {
				let selectedValue = selectedBundle.localizedString(forKey: key, value: value, table: tableName)
				if AppLanguageManager.bundle(selectedBundle, containsLocalizationForKey: key, table: tableName) {
					return selectedValue
				}

				if let englishPath = AppLanguageManager.englishBundlePath,
				   let englishBundle = Bundle(path: englishPath) {
					let englishValue = englishBundle.localizedString(forKey: key, value: value, table: tableName)
					if AppLanguageManager.bundle(englishBundle, containsLocalizationForKey: key, table: tableName) {
						return englishValue
					}
				}
			}
			return super.localizedString(forKey: key, value: value, table: tableName)
		}
	}

	nonisolated private static func bundle(_ bundle: Bundle, containsLocalizationForKey key: String, table tableName: String?) -> Bool {
		localizationKeys(in: bundle, table: tableName)?.contains(key) == true
	}

	nonisolated private static func localizationKeys(in bundle: Bundle, table tableName: String?) -> Set<String>? {
		let resolvedTableName = tableName ?? defaultTableName
		let cacheKey = "\(bundle.bundlePath)#\(resolvedTableName)"

		localizationKeyCacheLock.lock()
		if let cachedKeys = localizationKeyCache[cacheKey] {
			localizationKeyCacheLock.unlock()
			return cachedKeys
		}
		localizationKeyCacheLock.unlock()

		guard let tableURL = bundle.url(forResource: resolvedTableName, withExtension: "strings"),
		      let dictionary = NSDictionary(contentsOf: tableURL) as? [String: String] else {
			return nil
		}

		let keys = Set(dictionary.keys)
		localizationKeyCacheLock.lock()
		localizationKeyCache[cacheKey] = keys
		localizationKeyCacheLock.unlock()
		return keys
	}

	static func clearLegacyLanguageOverrides() {
		let defaults = UserDefaults.standard
		let appDomainName = Bundle.main.bundleIdentifier ?? ""
		let appDomain = defaults.persistentDomain(forName: appDomainName) ?? [:]
		guard appDomain[languageDefaultsKey] != nil || appDomain[localeDefaultsKey] != nil else {
			return
		}

		defaults.removeObject(forKey: languageDefaultsKey)
		defaults.removeObject(forKey: localeDefaultsKey)
	}

	nonisolated static func localizedString(forKey key: String, table tableName: String? = nil) -> String {
		let selectedPath = currentSelectedBundlePath()
		if let selectedPath,
		   let selectedBundle = Bundle(path: selectedPath),
		   bundle(selectedBundle, containsLocalizationForKey: key, table: tableName) {
			return selectedBundle.localizedString(forKey: key, value: key, table: tableName)
		}

		if let englishPath = englishBundlePath,
		   let englishBundle = Bundle(path: englishPath),
		   bundle(englishBundle, containsLocalizationForKey: key, table: tableName) {
			return englishBundle.localizedString(forKey: key, value: key, table: tableName)
		}

		return key
	}

	static func apply(languageCode: String) {
		let normalized = AppLanguage.resolvedSupportedLanguageCode(from: languageCode)
			?? AppLanguage.fallbackLocaleIdentifier
		let baseCode = normalized.split(separator: "-").first.map(String.init) ?? normalized

		let preferredPath = Bundle.main.path(forResource: normalized, ofType: "lproj")
			?? Bundle.main.path(forResource: baseCode, ofType: "lproj")
			?? Bundle.main.path(forResource: AppLanguage.fallbackLocaleIdentifier, ofType: "lproj")

		setSelectedBundlePath(preferredPath)
		object_setClass(Bundle.main, RuntimeLocalizedBundle.self)
		objc_setAssociatedObject(
			Bundle.main,
			&bundleAssociationKey,
			preferredPath,
			.OBJC_ASSOCIATION_RETAIN_NONATOMIC
		)
	}

	nonisolated private static func currentSelectedBundlePath() -> String? {
		selectedBundlePathLock.lock()
		defer { selectedBundlePathLock.unlock() }
		return selectedBundlePath
	}

	nonisolated private static func setSelectedBundlePath(_ path: String?) {
		selectedBundlePathLock.lock()
		selectedBundlePath = path
		selectedBundlePathLock.unlock()
	}
}

extension String {
	nonisolated var psLocalized: String {
		AppLanguageManager.localizedString(forKey: self)
	}
}
