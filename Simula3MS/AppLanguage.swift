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

    var usesAppleLanguagesOverride: Bool {
        appleLanguagesOverrideCodes != nil
    }

    var appleLanguagesOverrideCodes: [String]? {
        switch self {
        case .automatic:
            return nil
        case .english:
            return ["en"]
        default:
            return [languageCode, "en"]
        }
    }

    static func detectSystemLanguageCode() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let code = preferred.lowercased()

        if code.hasPrefix("ar") {
            return "ar"
        }
        if code.hasPrefix("br") {
            return "br"
        }
        if code.hasPrefix("zh-hans") || code.hasPrefix("zh-cn") || code.hasPrefix("zh-sg") {
            return "zh-Hans"
        }
        if code.hasPrefix("kw") {
            return "kw"
        }
        if code.hasPrefix("hr") {
            return "hr"
        }
        if code.hasPrefix("cs") {
            return "cs"
        }
        if code.hasPrefix("cy") {
            return "cy"
        }
        if code.hasPrefix("da") {
            return "da"
        }
        if code.hasPrefix("de") {
            return "de"
        }
        if code.hasPrefix("nl") {
            return "nl"
        }
        if code.hasPrefix("en") {
            return "en"
        }
        if code.hasPrefix("et") {
            return "et"
        }
        if code.hasPrefix("es") {
            return "es"
        }
        if code.hasPrefix("fa") {
            return "fa"
        }
        if code.hasPrefix("fi") {
            return "fi"
        }
        if code.hasPrefix("fr") {
            return "fr"
        }
        if code.hasPrefix("ga") {
            return "ga"
        }
        if code.hasPrefix("gd") {
            return "gd"
        }
        if code.hasPrefix("it") {
            return "it"
        }
        if code.hasPrefix("gl") {
            return "gl"
        }
        if code.hasPrefix("el") {
            return "el"
        }
        if code.hasPrefix("he") {
            return "he"
        }
        if code.hasPrefix("hi") {
            return "hi"
        }
        if code.hasPrefix("ja") {
            return "ja"
        }
        if code.hasPrefix("ko") {
            return "ko"
        }
        if code.hasPrefix("lt") {
            return "lt"
        }
        if code.hasPrefix("lv") {
            return "lv"
        }
        if code.hasPrefix("nb") || code.hasPrefix("no") {
            return "nb"
        }
        if code.hasPrefix("pl") {
            return "pl"
        }
        if code.hasPrefix("pt-pt") || code.hasPrefix("pt") {
            return "pt-PT"
        }
        if code.hasPrefix("ro") {
            return "ro"
        }
        if code.hasPrefix("sv") {
            return "sv"
        }
        if code.hasPrefix("uk") {
            return "uk"
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

        let fallbackOrder: [String]
        if languageCode == "gl" {
            fallbackOrder = ["es"]
        } else if languageCode == "br" {
            fallbackOrder = ["fr"]
        } else {
            fallbackOrder = ["en"]
        }

        for fallbackCode in fallbackOrder where fallbackCode != languageCode {
            if let bundle = localizedBundle(for: fallbackCode) {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                if value != key {
                    return value
                }
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
