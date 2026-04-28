import Foundation
import SwiftUI

private let appSelectedLanguageStorageKey = "selectedLanguage"

@MainActor
final class AppLocalizationSettings: ObservableObject {
    static let shared = AppLocalizationSettings()

    enum LanguageOption: String, CaseIterable, Identifiable {
        case system
        case english
        case japanese

        var id: String { rawValue }

        var localeIdentifier: String {
            switch self {
            case .system:
                Locale.preferredLanguages.first ?? Locale.current.identifier
            case .english:
                "en"
            case .japanese:
                "ja"
            }
        }

        var bundleLanguageCode: String {
            switch self {
            case .system:
                let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
                if preferred.lowercased().hasPrefix("ja") {
                    return "ja"
                }
                return "en"
            case .english:
                return "en"
            case .japanese:
                return "ja"
            }
        }

        var labelKey: String {
            switch self {
            case .system:
                return "settings.language.system"
            case .english:
                return "settings.language.english"
            case .japanese:
                return "settings.language.japanese"
            }
        }
    }

    @Published var selectedLanguage: LanguageOption {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: appSelectedLanguageStorageKey)
            refreshID = UUID()
        }
    }

    @Published private(set) var refreshID = UUID()

    private init() {
        if let rawValue = UserDefaults.standard.string(forKey: appSelectedLanguageStorageKey),
           let option = LanguageOption(rawValue: rawValue) {
            selectedLanguage = option
        } else {
            selectedLanguage = .system
        }
    }

    var locale: Locale {
        Locale(identifier: selectedLanguage.localeIdentifier)
    }
}

enum L10n {
    private static func currentOption() -> AppLocalizationSettings.LanguageOption {
        if let rawValue = UserDefaults.standard.string(forKey: appSelectedLanguageStorageKey),
           let option = AppLocalizationSettings.LanguageOption(rawValue: rawValue) {
            return option
        }
        return .system
    }

    private static var currentBundle: Bundle {
        let code = currentOption().bundleLanguageCode
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    private static var currentLocale: Locale {
        Locale(identifier: currentOption().localeIdentifier)
    }

    static func text(_ key: String) -> String {
        currentBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: currentLocale, arguments: arguments)
    }
}
