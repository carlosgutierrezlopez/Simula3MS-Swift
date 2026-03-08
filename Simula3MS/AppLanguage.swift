import Foundation

enum AppLanguageSelection: String, CaseIterable, Identifiable {
    case automatic
    case spanish
    case english
    case galician

    var id: String { rawValue }

    var languageCode: String {
        switch self {
        case .automatic:
            return Self.detectSystemLanguageCode()
        case .spanish:
            return "es"
        case .english:
            return "en"
        case .galician:
            return "gl"
        }
    }

    var usesAppleLanguagesOverride: Bool {
        appleLanguagesOverrideCode != nil
    }

    var appleLanguagesOverrideCode: String? {
        switch self {
        case .automatic:
            return nil
        case .spanish:
            return "es"
        case .english:
            return "en"
        case .galician:
            return "gl"
        }
    }

    static func detectSystemLanguageCode() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let code = preferred.lowercased()

        if code.hasPrefix("gl") {
            return "gl"
        }
        if code.hasPrefix("en") {
            return "en"
        }
        if code.hasPrefix("es") {
            return "es"
        }
        return "en"
    }
}

enum L10n {
    static func tr(_ key: String, languageSelectionRaw: String) -> String {
        let selection = AppLanguageSelection(rawValue: languageSelectionRaw) ?? .automatic
        return tr(key, languageCode: selection.languageCode)
    }

    static func tr(_ key: String, languageCode: String) -> String {
        // 1) idioma solicitado
        if let bundle = localizedBundle(for: languageCode) {
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            if value != key {
                return value
            }
        }

        // 2) fallback inglés
        if languageCode != "en", let bundle = localizedBundle(for: "en") {
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            if value != key {
                return value
            }
        }

        // 3) fallback castellano
        if languageCode != "es", let bundle = localizedBundle(for: "es") {
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            if value != key {
                return value
            }
        }

        return key
    }

    private static func localizedBundle(for languageCode: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}
