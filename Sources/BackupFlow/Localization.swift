import Foundation

enum L10n {
    private static var resourceBundle: Bundle {
        if Bundle.main.path(forResource: "en", ofType: "lproj") != nil {
            return .main
        }
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = resourceBundle.localizedString(
            forKey: key,
            value: key,
            table: "Localizable"
        )
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: .current, arguments: arguments)
    }

    static func text(_ key: String, language: String) -> String {
        let localization = language.contains("-") ? language.lowercased() : language
        guard let path = resourceBundle.path(forResource: localization, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static let supportedLanguages = [
        "en", "ru", "de", "fr", "es", "pt-BR", "it", "zh-Hans", "ja", "ko"
    ]
}
