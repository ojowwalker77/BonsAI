import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
  case system
  case english
  case japanese
  case simplifiedChinese
  case korean

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System".localizedUI
    case .english: "English".localizedUI
    case .japanese: "Japanese".localizedUI
    case .simplifiedChinese: "Chinese (Simplified)".localizedUI
    case .korean: "Korean".localizedUI
    }
  }

  var localizationCode: String? {
    switch self {
    case .system: nil
    case .english: "en"
    case .japanese: "ja"
    case .simplifiedChinese: "zh-Hans"
    case .korean: "ko"
    }
  }
}

enum L10n {
  private static var selectedLanguage: AppLanguage {
    AppLanguage(rawValue: UserDefaults.standard.string(forKey: ComposerPreferences.languageKey) ?? "") ?? .system
  }

  private static var selectedBundle: Bundle {
    guard let code = selectedLanguage.localizationCode else { return Bundle.appResources }
    let candidates = [code, code.lowercased()]
    for candidate in candidates {
      if let path = Bundle.appResources.path(forResource: candidate, ofType: "lproj"),
         let bundle = Bundle(path: path) {
        return bundle
      }
    }
    return Bundle.appResources
  }

  static func string(_ key: String) -> String {
    selectedBundle.localizedString(forKey: key, value: key, table: nil)
  }

  static func string(_ key: String, _ arguments: CVarArg...) -> String {
    let format = string(key)
    guard !arguments.isEmpty else { return format }
    let locale = selectedLanguage.localizationCode.map(Locale.init(identifier:)) ?? Locale.current
    return String(format: format, locale: locale, arguments: arguments)
  }
}

extension String {
  var localizedUI: String { L10n.string(self) }

  func localizedUI(_ arguments: CVarArg...) -> String {
    L10n.string(self, arguments)
  }
}
