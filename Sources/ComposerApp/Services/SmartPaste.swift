import Foundation

/// Turns a pasted string into a connector `@token` when it clearly matches a known shape.
enum SmartPaste {
  private static let gitHubIssuePattern = try! NSRegularExpression(
    pattern: #"https?://github\.com/[^/\s]+/[^/\s]+/(issues|pull)/\d+"#,
    options: .caseInsensitive)

  /// Synchronous resolution for URLs and local paths. Returns nil when the paste should stay plain text.
  static func syncToken(for pasted: String) -> String? {
    let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }

    if let url = gitHubURL(in: trimmed) {
      let kind = AppToken.gitHubKind(forURL: url)
      return AppToken.string(appID: "@github", selection: .github(kind: kind, url: url))
    }

    if let path = localPath(in: trimmed) {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
      return AppToken.string(
        appID: "@finder",
        selection: .finder(FinderReference(path: path, isDirectory: isDirectory.boolValue ? true : nil)))
    }

    return nil
  }

  /// True when the paste looks like a library name worth resolving through Context7 (not a URL/path).
  static func looksLikeLibraryQuery(_ pasted: String) -> Bool {
    let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (2...64).contains(trimmed.count),
          !trimmed.contains(where: \.isWhitespace),
          !trimmed.lowercased().hasPrefix("http"),
          !trimmed.hasPrefix("/"),
          !trimmed.hasPrefix("~"),
          !trimmed.lowercased().hasPrefix("file:"),
          gitHubURL(in: trimmed) == nil,
          localPath(in: trimmed) == nil
    else { return false }

    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._/-"))
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
    return trimmed.contains("/") || trimmed.contains(".")
  }

  /// Resolve a library query to the best Context7 `@token`, or nil when search finds nothing.
  static func context7Token(for query: String) async -> String? {
    let trimmed = query.trimmed
    guard looksLikeLibraryQuery(trimmed) else { return nil }
    let service = Context7Service()
    guard let results = try? await service.search(trimmed), let first = results.first else { return nil }
    guard case let .context7(libraryID, topic) = first.selection else { return nil }
    return AppToken.string(appID: "@context7", selection: .context7(libraryID: libraryID, query: topic))
  }

  // MARK: - Parsing

  private static func gitHubURL(in text: String) -> String? {
    let ns = text as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = gitHubIssuePattern.firstMatch(in: text, range: range) else { return nil }
    return ns.substring(with: match.range)
  }

  private static func localPath(in text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
      return url.path
    }
    if trimmed.hasPrefix("~/") {
      return NSString(string: trimmed).expandingTildeInPath
    }
    if trimmed.hasPrefix("/") {
      return trimmed
    }
    return nil
  }
}
