import Foundation

/// The board new users see on first launch. The exact board is shipped in the app bundle as
/// `WelcomeBoard.json` (a serialized `[CardState]`); `DumpStore` seeds it into the store once, on a
/// fresh install. The mascot image card stores a `bundle:` sentinel in the JSON because its real
/// path is per-machine — on seed we materialize the bundled PNG into Attachments (where user
/// images live) and point the card at that copy.
enum WelcomeBoard {
  private static let mascotSentinel = "bundle:welcome-companion.png"
  private static let mascotFileName = "welcome-companion.png"

  /// The welcome board's cards, with the mascot installed and its image card repointed at the
  /// on-disk copy. Returns nil if the bundled resource is missing/unreadable — the caller then
  /// just falls back to a blank first board.
  static func seedCards() -> [CardState]? {
    guard let url = Bundle.module.url(forResource: "WelcomeBoard", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let cards = try? JSONDecoder().decode([CardState].self, from: data),
          !cards.isEmpty
    else { return nil }

    let mascotPath = installMascot()
    return cards.map { card in
      guard card.elementKind == .image, card.imagePath == mascotSentinel else { return card }
      var resolved = card
      resolved.imagePath = mascotPath   // nil if the copy failed → renders a placeholder, board still loads
      return resolved
    }
  }

  /// Copy the bundled mascot into Attachments (idempotent) and return its on-disk path.
  private static func installMascot() -> String? {
    guard let source = Bundle.module.url(forResource: "welcome-companion", withExtension: "png") else { return nil }
    let directory = attachmentsDirectory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(mascotFileName)
    if !FileManager.default.fileExists(atPath: destination.path) {
      try? FileManager.default.copyItem(at: source, to: destination)
    }
    return FileManager.default.fileExists(atPath: destination.path) ? destination.path : nil
  }

  /// Same Attachments directory user-dropped images use (`Application Support/Composer/Attachments`).
  private static var attachmentsDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Composer/Attachments", isDirectory: true)
  }
}
