import Foundation

/// The board users see as the bundled onboarding canvas. The exact board is shipped in the app
/// bundle as `WelcomeBoard.json` (a serialized `[CardState]`). The mascot image card stores a
/// `bundle:` sentinel in the JSON because its real attachment filename is per-machine.
enum WelcomeBoard {
  static let title = "Welcome Canvas"

  private static let mascotSentinel = "bundle:welcome-companion.png"
  /// The welcome board's cards, with the mascot installed and its image card repointed at the
  /// attachment copy. Returns nil if the bundled resource is missing/unreadable — the caller then
  /// just falls back to a blank first board.
  static func seedCards() -> [CardState]? {
    guard let url = Bundle.appResources.url(forResource: "WelcomeBoard", withExtension: "json") else {
      UserFacingError.report("Composer’s bundled welcome board is missing. A blank board was created instead.")
      return nil
    }
    let cards: [CardState]
    do {
      let data = try Data(contentsOf: url)
      cards = try JSONDecoder().decode([CardState].self, from: data)
    } catch {
      UserFacingError.report(error, while: "Loading Composer’s bundled welcome board")
      return nil
    }
    guard !cards.isEmpty else {
      UserFacingError.report("Composer’s bundled welcome board contains no cards. A blank board was created instead.")
      return nil
    }

    let mascotPath = installMascot()
    return cards.map { card in
      guard card.elementKind == .image, card.imagePath == mascotSentinel else { return card }
      var resolved = card
      resolved.imagePath = mascotPath   // nil if the copy failed → renders a placeholder, board still loads
      return resolved
    }
  }

  /// Copy the bundled mascot into Attachments and return its stored filename.
  private static func installMascot() -> String? {
    guard let source = Bundle.appResources.url(forResource: "welcome-companion", withExtension: "png") else { return nil }
    return AssetStore.ingest(fileURL: source)
  }
}
