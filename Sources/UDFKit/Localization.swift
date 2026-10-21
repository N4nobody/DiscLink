import Foundation

/// Chinese or English, decided once per run.
///
/// Every user-facing string is written as `L("中文", "English")` next to the code that uses it.
/// That keeps the two languages together and needs no Xcode string catalogs, which this
/// project can't build with the Command Line Tools alone.
public enum Language {
    public static let isChinese: Bool = {
        // Override for testing: UDFDISC_LANG=en or UDFDISC_LANG=zh.
        if let forced = ProcessInfo.processInfo.environment["UDFDISC_LANG"] { return forced.hasPrefix("zh") }
        // In the app, follow the localization macOS chose from its .lproj folders, so our text
        // matches the system-provided menus. The command-line tool has none: use the user's list.
        let bundle = Bundle.main
        let languages = bundle.localizations.count > 1 ? bundle.preferredLocalizations : Locale.preferredLanguages
        return languages.first?.hasPrefix("zh") ?? false
    }()
}

/// Picks the Chinese or the English text for the current user.
@inline(__always)
public func L(_ zh: String, _ en: String) -> String {
    Language.isChinese ? zh : en
}
