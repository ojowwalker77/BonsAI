import Foundation

/// Which Claude model the in-canvas agent targets, persisted as a `ClaudeModel` rawValue in
/// UserDefaults so the picker in the Agent panel and the one in Settings ▸ Runtime stay
/// mirrored — both `@AppStorage`-bind the same key.
///
/// Refine and Compile deliberately stay on the CLI's own default model and are not covered here.
enum ModelPreferences {
  static let chatModelKey = "model.chat"

  static let defaultChatModel: ClaudeModel = .opus

  static var chatModel: ClaudeModel { stored(chatModelKey) ?? defaultChatModel }

  private static func stored(_ key: String) -> ClaudeModel? {
    UserDefaults.standard.string(forKey: key).flatMap(ClaudeModel.init(rawValue:))
  }
}
