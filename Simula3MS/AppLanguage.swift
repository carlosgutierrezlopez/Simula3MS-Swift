import Foundation
import SwiftUI

enum AppLanguageSelection: String, CaseIterable, Identifiable {
    case automatic
    case arabic
    case breton
    case chineseSimplified
    case cornish
    case croatian
    case czech
    case danish
    case dutch
    case english
    case estonian
    case finnish
    case french
    case galician
    case german
    case greek
    case hebrew
    case hindi
    case irish
    case italian
    case japanese
    case korean
    case lithuanian
    case latvian
    case norwegianBokmal
    case persian
    case polish
    case portuguesePortugal
    case romanian
    case scottishGaelic
    case spanish
    case swedish
    case ukrainian
    case welsh

    var id: String { rawValue }

    static var menuCases: [AppLanguageSelection] {
        [.automatic] + allCases
            .filter { $0 != .automatic }
            .sorted { $0.menuSortKey.localizedCaseInsensitiveCompare($1.menuSortKey) == .orderedAscending }
    }

    var languageCode: String {
        switch self {
        case .automatic:
            return Self.detectSystemLanguageCode()
        case .arabic:
            return "ar"
        case .breton:
            return "br"
        case .chineseSimplified:
            return "zh-Hans"
        case .cornish:
            return "kw"
        case .croatian:
            return "hr"
        case .czech:
            return "cs"
        case .danish:
            return "da"
        case .dutch:
            return "nl"
        case .english:
            return "en"
        case .estonian:
            return "et"
        case .finnish:
            return "fi"
        case .french:
            return "fr"
        case .galician:
            return "gl"
        case .german:
            return "de"
        case .greek:
            return "el"
        case .hebrew:
            return "he"
        case .hindi:
            return "hi"
        case .irish:
            return "ga"
        case .italian:
            return "it"
        case .japanese:
            return "ja"
        case .korean:
            return "ko"
        case .lithuanian:
            return "lt"
        case .latvian:
            return "lv"
        case .norwegianBokmal:
            return "nb"
        case .persian:
            return "fa"
        case .polish:
            return "pl"
        case .portuguesePortugal:
            return "pt-PT"
        case .romanian:
            return "ro"
        case .scottishGaelic:
            return "gd"
        case .spanish:
            return "es"
        case .swedish:
            return "sv"
        case .ukrainian:
            return "uk"
        case .welsh:
            return "cy"
        }
    }

    var nativeMenuTitle: String {
        switch self {
        case .automatic:
            return ""
        case .arabic:
            return "العربية"
        case .breton:
            return "Brezhoneg"
        case .chineseSimplified:
            return "简体中文"
        case .cornish:
            return "Kernewek"
        case .croatian:
            return "Hrvatski"
        case .czech:
            return "Čeština"
        case .danish:
            return "Dansk"
        case .dutch:
            return "Nederlands"
        case .english:
            return "English"
        case .estonian:
            return "Eesti"
        case .finnish:
            return "Suomi"
        case .french:
            return "Français"
        case .galician:
            return "Galego"
        case .german:
            return "Deutsch"
        case .greek:
            return "Ελληνικά"
        case .hebrew:
            return "עברית"
        case .hindi:
            return "हिन्दी"
        case .irish:
            return "Gaeilge"
        case .italian:
            return "Italiano"
        case .japanese:
            return "日本語"
        case .korean:
            return "한국어"
        case .lithuanian:
            return "Lietuvių"
        case .latvian:
            return "Latviešu"
        case .norwegianBokmal:
            return "Norsk Bokmål"
        case .persian:
            return "فارسی"
        case .polish:
            return "Polski"
        case .portuguesePortugal:
            return "Português"
        case .romanian:
            return "Română"
        case .scottishGaelic:
            return "Gàidhlig"
        case .spanish:
            return "Castellano"
        case .swedish:
            return "Svenska"
        case .ukrainian:
            return "Українська"
        case .welsh:
            return "Cymraeg"
        }
    }

    var layoutDirection: LayoutDirection {
        switch self {
        case .arabic, .hebrew, .persian:
            return .rightToLeft
        default:
            return .leftToRight
        }
    }

    var menuSortKey: String {
        switch self {
        case .automatic:
            return ""
        case .arabic:
            return "arabic"
        case .breton:
            return "brezhoneg"
        case .chineseSimplified:
            return "chinese"
        case .cornish:
            return "kernewek"
        case .croatian:
            return "hrvatski"
        case .czech:
            return "cestina"
        case .danish:
            return "dansk"
        case .dutch:
            return "nederlands"
        case .english:
            return "english"
        case .estonian:
            return "eesti"
        case .finnish:
            return "suomi"
        case .french:
            return "francais"
        case .galician:
            return "galego"
        case .german:
            return "deutsch"
        case .greek:
            return "ellinika"
        case .hebrew:
            return "ivrit"
        case .hindi:
            return "hindi"
        case .irish:
            return "gaeilge"
        case .italian:
            return "italiano"
        case .japanese:
            return "japanese"
        case .korean:
            return "korean"
        case .lithuanian:
            return "lietuviu"
        case .latvian:
            return "latviesu"
        case .norwegianBokmal:
            return "norsk bokmal"
        case .persian:
            return "persian"
        case .polish:
            return "polski"
        case .portuguesePortugal:
            return "portugues"
        case .romanian:
            return "romana"
        case .scottishGaelic:
            return "gaidhlig"
        case .spanish:
            return "castellano"
        case .swedish:
            return "svenska"
        case .ukrainian:
            return "ukrainian"
        case .welsh:
            return "cymraeg"
        }
    }

    var appleLanguagesOverrideCodes: [String]? {
        switch self {
        case .automatic:
            return nil
        default:
            let code = languageCode
            if Self.isCompleteSystemMenuLanguageCode(code) {
                return Self.uniqueLanguageCodes([code, "en"])
            }

            return Self.preferredCompleteSystemLanguageCodes()
        }
    }

    var showsPartialSupportWarning: Bool {
        switch self {
        case .automatic:
            return false
        default:
            return !Self.isCompleteSystemMenuLanguageCode(languageCode)
        }
    }

    private nonisolated static func preferredCompleteSystemLanguageCodes() -> [String] {
        let preferredCodes = Locale.preferredLanguages
            .map(normalizedLanguageCode)
            .filter(isCompleteSystemMenuLanguageCode)

        let codes = preferredCodes.isEmpty ? ["en"] : preferredCodes
        return uniqueLanguageCodes(codes + ["en"])
    }

    private nonisolated static func normalizedLanguageCode(_ code: String) -> String {
        let normalized = code.replacingOccurrences(of: "_", with: "-").lowercased()

        if normalized.hasPrefix("zh-hans") || normalized.hasPrefix("zh-cn") || normalized.hasPrefix("zh-sg") {
            return "zh-Hans"
        }

        if normalized.hasPrefix("pt") {
            return "pt-PT"
        }

        if normalized.hasPrefix("nb") || normalized.hasPrefix("no") {
            return "nb"
        }

        return String(normalized.split(separator: "-").first ?? Substring(normalized))
    }

    private nonisolated static func isCompleteSystemMenuLanguageCode(_ code: String) -> Bool {
        completeSystemMenuLanguageCodes.contains(normalizedLanguageCode(code))
    }

    fileprivate nonisolated static func uniqueLanguageCodes(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }

    private nonisolated static let completeSystemMenuLanguageCodes: Set<String> = [
        "ar",
        "cs",
        "da",
        "de",
        "el",
        "en",
        "es",
        "fi",
        "fr",
        "he",
        "hi",
        "hr",
        "it",
        "ja",
        "ko",
        "nb",
        "nl",
        "pl",
        "pt-PT",
        "ro",
        "sv",
        "uk",
        "zh-Hans"
    ]

    static func detectSystemLanguageCode() -> String {
        let supportedSelections = allCases.filter { $0 != .automatic }

        for preferredLanguage in Locale.preferredLanguages {
            let normalizedPreferredLanguage = normalizedLanguageCode(preferredLanguage)

            if let selection = supportedSelections.first(where: {
                normalizedLanguageCode($0.languageCode) == normalizedPreferredLanguage
            }) {
                return selection.languageCode
            }
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
        for fallbackCode in fallbackCodes(for: languageCode) {
            let value = localizedString(forKey: key, languageCode: fallbackCode)
            if value != key {
                return value
            }
        }

        return key
    }

    private static func fallbackCodes(for languageCode: String) -> [String] {
        var codes = [languageCode]

        if languageCode == "gl" {
            codes.append("es")
        } else if languageCode == "br" {
            codes.append("fr")
        }

        codes.append("en")
        return AppLanguageSelection.uniqueLanguageCodes(codes)
    }

    private static func localizedString(forKey key: String, languageCode: String) -> String {
        if let bundle = localizedBundle(for: languageCode) {
            return bundle.localizedString(forKey: key, value: nil, table: nil)
        }

        return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    private static func localizedBundle(for languageCode: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}
